import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/export.dart';
import 'package:synchronized/synchronized.dart';

import '../agent/thread_session_cache.dart';
import '../domain/models.dart';

abstract interface class ThreadSnapshotStore {
  Future<ThreadSessionSnapshot?> read(String scope, String threadId);
  Future<void> write(String scope, ThreadSessionSnapshot snapshot);
  Future<void> remove(String scope, String threadId);
  Future<void> removeScope(String scope);
}

class NoopThreadSnapshotStore implements ThreadSnapshotStore {
  const NoopThreadSnapshotStore();

  @override
  Future<ThreadSessionSnapshot?> read(String scope, String threadId) async =>
      null;
  @override
  Future<void> write(String scope, ThreadSessionSnapshot snapshot) async {}
  @override
  Future<void> remove(String scope, String threadId) async {}
  @override
  Future<void> removeScope(String scope) async {}
}

/// Disposable, encrypted previews; the server must still verify thread ownership.
/// Neither credentials nor encryption keys are stored alongside these files.
class EncryptedThreadSnapshotStore implements ThreadSnapshotStore {
  EncryptedThreadSnapshotStore({
    Future<Directory> Function()? directoryProvider,
    Future<Uint8List> Function()? keyProvider,
    int Function()? nowEpochMillis,
    this.maxPlainBytes = 4 * 1024 * 1024,
    this.maxFileBytes = 1024 * 1024,
    this.maxTotalBytes = 8 * 1024 * 1024,
    this.maxEntries = 16,
    this.ttl = const Duration(days: 7),
    this.writeDebounce = const Duration(milliseconds: 500),
  }) : _directoryProvider = directoryProvider ?? _defaultDirectory,
       _keyProvider = keyProvider ?? _defaultKey,
       _nowEpochMillis = nowEpochMillis ?? _now {
    if (maxPlainBytes < 1 ||
        maxFileBytes < 32 ||
        maxTotalBytes < 32 ||
        maxEntries < 1 ||
        ttl <= Duration.zero ||
        writeDebounce < Duration.zero) {
      throw ArgumentError('Invalid thread cache limits');
    }
  }

  final Future<Directory> Function() _directoryProvider;
  final Future<Uint8List> Function() _keyProvider;
  final int Function() _nowEpochMillis;
  final int maxPlainBytes;
  final int maxFileBytes;
  final int maxTotalBytes;
  final int maxEntries;
  final Duration ttl;
  final Duration writeDebounce;
  final _lock = Lock();
  final _pending = <String, _Save>{};
  int _pendingWeight = 0;
  final _reads = <_Operation>{};
  _Save? _activeSave;
  Timer? _timer;
  bool _draining = false;

  static Future<Uint8List>? _masterKey;
  static int _now() => DateTime.now().millisecondsSinceEpoch;
  static Future<Directory> _defaultDirectory() async => Directory(
    p.join((await getApplicationCacheDirectory()).path, 'thread_snapshots_v1'),
  );
  static Future<Uint8List> _defaultKey() {
    return _masterKey ??= _loadKey().onError((Object error, StackTrace stack) {
      _masterKey = null;
      Error.throwWithStackTrace(error, stack);
    });
  }

  static Future<Uint8List> _loadKey() async {
    const storage = FlutterSecureStorage(
      aOptions: AndroidOptions(storageNamespace: 'codex_remote'),
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
      ),
    );
    const storageKey = 'thread_snapshot_key_v1';
    final encoded = await storage.read(key: storageKey);
    if (encoded != null) {
      final key = base64Decode(encoded);
      if (key.length != 32) throw const FormatException('Invalid cache key');
      return key;
    }
    final key = _randomBytes(32);
    await storage.write(key: storageKey, value: base64Encode(key));
    return key;
  }

  @override
  Future<ThreadSessionSnapshot?> read(String scope, String threadId) async {
    // The retained file may predate a queued edit or deletion. Do not briefly
    // render it while a replacement is being prepared.
    if (_isWriting(scope, threadId)) return null;
    final operation = _Operation(scope, threadId);
    _reads.add(operation);
    try {
      return await _lock.synchronized(() async {
        if (operation.cancelled || _isWriting(scope, threadId)) return null;
        final directory = await _directoryProvider();
        final file = File(p.join(directory.path, _filename(scope, threadId)));
        final stat = await file.stat();
        if (stat.type != FileSystemEntityType.file ||
            stat.size > maxFileBytes ||
            _nowEpochMillis() - stat.modified.millisecondsSinceEpoch >
                ttl.inMilliseconds) {
          return null;
        }
        final sink = _BoundedBytesSink(maxFileBytes);
        await for (final chunk in file.openRead()) {
          sink.add(chunk);
        }
        final bytes = sink.takeBytes();
        final key = await _keyProvider();
        final plainLimit = maxPlainBytes;
        final now = _nowEpochMillis();
        final ttlMillis = ttl.inMilliseconds;
        final snapshot = await _decodeInWorker(
          bytes,
          key,
          scope,
          threadId,
          plainLimit,
          now,
          ttlMillis,
        );
        return operation.cancelled || _isWriting(scope, threadId)
            ? null
            : snapshot;
      });
    } catch (_) {
      // Caches are optional. Missing plugins, I/O errors and corrupt data are misses.
      return null;
    } finally {
      _reads.remove(operation);
    }
  }

  @override
  Future<void> write(String scope, ThreadSessionSnapshot snapshot) {
    final filename = _filename(scope, snapshot.thread.id);
    final weight = _snapshotWeight(snapshot, maxPlainBytes);
    // An oversized replacement must invalidate the old file even if later
    // writes fill the bounded queue before the next drain.
    if (weight > maxPlainBytes) return remove(scope, snapshot.thread.id);
    final queued = _pending[filename];
    if (queued != null) {
      _pendingWeight -= queued.weight;
      queued.snapshot = snapshot;
      queued.weight = weight;
      _pendingWeight += weight;
      _trimPending();
      return queued.completed.future;
    }
    final save = _Save(scope, snapshot, weight);
    _pending[filename] = save;
    _pendingWeight += weight;
    _trimPending();
    if (!_draining) _timer ??= Timer(writeDebounce, _drain);
    return save.completed.future;
  }

  bool _isWriting(String scope, String threadId) =>
      _pending.containsKey(_filename(scope, threadId)) ||
      (_activeSave?.scope == scope && _activeSave?.threadId == threadId);

  void _trimPending() {
    while (_pending.length > maxEntries || _pendingWeight > maxPlainBytes * 2) {
      final removed = _pending.remove(_pending.keys.first)!;
      _pendingWeight -= removed.weight;
      removed.completed.complete();
    }
  }

  Future<void> _drain() async {
    _timer = null;
    if (_draining) return;
    _draining = true;
    try {
      while (_pending.isNotEmpty) {
        final save = _pending.remove(_pending.keys.first)!;
        _pendingWeight -= save.weight;
        _activeSave = save;
        try {
          await _lock.synchronized(() => _save(save));
        } catch (_) {
          // A failed cache save must never interrupt streaming or navigation.
        } finally {
          save.completed.complete();
          _activeSave = null;
        }
      }
    } finally {
      _draining = false;
    }
  }

  Future<void> _save(_Save save) async {
    if (save.cancelled) return;
    final directory = await _directoryProvider();
    final path = p.join(directory.path, _filename(save.scope, save.threadId));
    final snapshot = save.snapshot;
    final key = await _keyProvider();
    final scope = save.scope;
    final plainLimit = maxPlainBytes;
    final fileLimit = min(maxFileBytes, maxTotalBytes);
    final bytes = await _encodeInWorker(
      snapshot,
      key,
      scope,
      plainLimit,
      fileLimit,
    );
    if (save.cancelled) return;
    if (bytes == null) {
      final file = File(path);
      if (await file.exists()) await file.delete();
      return;
    }
    await directory.create(recursive: true);
    final temporary = File('$path.${base64UrlEncode(_randomBytes(9))}.tmp');
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      if (save.cancelled) return;
      await temporary.rename(path);
      await _prune(directory);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  void _invalidate(String scope, [String? threadId]) {
    bool matches(_Operation operation) =>
        operation.scope == scope &&
        (threadId == null || operation.threadId == threadId);
    final active = _activeSave;
    if (active != null && matches(active)) active.cancelled = true;
    for (final read in _reads) {
      if (matches(read)) read.cancelled = true;
    }
    for (final entry in _pending.entries.toList()) {
      if (!matches(entry.value)) continue;
      _pending.remove(entry.key);
      _pendingWeight -= entry.value.weight;
      entry.value.completed.complete();
    }
    if (_pending.isEmpty) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  Future<void> remove(String scope, String threadId) async {
    _invalidate(scope, threadId);
    try {
      await _lock.synchronized(() async {
        final directory = await _directoryProvider();
        final file = File(p.join(directory.path, _filename(scope, threadId)));
        if (await file.exists()) await file.delete();
      });
    } catch (_) {}
  }

  @override
  Future<void> removeScope(String scope) async {
    _invalidate(scope);
    try {
      await _lock.synchronized(() async {
        final directory = await _directoryProvider();
        if (!await directory.exists()) return;
        final prefix = '${_hash(scope)}_';
        await for (final file in directory.list(followLinks: false)) {
          if (file is File && p.basename(file.path).startsWith(prefix)) {
            await file.delete();
          }
        }
      });
    } catch (_) {}
  }

  Future<void> _prune(Directory directory) async {
    final files = <(File, FileStat)>[];
    var total = 0;
    final now = _nowEpochMillis();
    await for (final file in directory.list(followLinks: false)) {
      if (file is! File || !file.path.endsWith('.snapshot')) continue;
      final stat = await file.stat();
      if (stat.size > maxFileBytes ||
          now - stat.modified.millisecondsSinceEpoch > ttl.inMilliseconds) {
        await file.delete();
      } else {
        files.add((file, stat));
        total += stat.size;
      }
    }
    files.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
    for (var i = 0; i < files.length; i++) {
      if (files.length - i <= maxEntries && total <= maxTotalBytes) break;
      total -= files[i].$2.size;
      await files[i].$1.delete();
    }
  }
}

class _Operation {
  _Operation(this.scope, this.threadId);
  final String scope;
  final String threadId;
  bool cancelled = false;
}

class _Save extends _Operation {
  _Save(String scope, this.snapshot, this.weight)
    : super(scope, snapshot.thread.id);
  ThreadSessionSnapshot snapshot;
  int weight;
  final completed = Completer<void>();
}

// Build worker closures in top-level functions so Dart cannot capture the
// store, its secure-storage plugin, pending Completers or UI callbacks.
Future<Uint8List?> _encodeInWorker(
  ThreadSessionSnapshot snapshot,
  Uint8List key,
  String scope,
  int plainLimit,
  int fileLimit,
) => Isolate.run(
  () => _encodeSnapshot(snapshot, key, scope, plainLimit, fileLimit),
);

Future<ThreadSessionSnapshot?> _decodeInWorker(
  Uint8List bytes,
  Uint8List key,
  String scope,
  String threadId,
  int plainLimit,
  int now,
  int ttlMillis,
) => Isolate.run(
  () =>
      _decodeSnapshot(bytes, key, scope, threadId, plainLimit, now, ttlMillis),
);

// A cheap lower bound on encoded size bounds retained object graphs before
// they enter the queue or are copied to an isolate. UTF-8/JSON limits are still
// enforced exactly by the worker's bounded sink.
int _snapshotWeight(ThreadSessionSnapshot snapshot, int limit) {
  final thread = snapshot.thread;
  var weight =
      256 +
      thread.id.length +
      thread.title.length +
      thread.preview.length +
      thread.cwd.length +
      thread.source.length +
      thread.modelProvider.length +
      thread.status.length +
      thread.cliVersion.length +
      (thread.activeTurnId?.length ?? 0) +
      (snapshot.nextTurnsCursor?.length ?? 0);
  for (final entry in snapshot.timeline) {
    if (weight > limit) return weight;
    weight +=
        256 +
        entry.id.length +
        entry.title.length +
        entry.text.length +
        entry.status.length +
        entry.command.length +
        entry.cwd.length +
        entry.output.length +
        entry.turnId.length +
        entry.subAgentPath.length +
        entry.subAgentThreadId.length +
        entry.subAgentActivity.length;
    for (final text in entry.reasoningSummary.followedBy(
      entry.reasoningContent,
    )) {
      weight += text.length + 3;
      if (weight > limit) return weight;
    }
    for (final change in entry.changes) {
      weight +=
          32 + change.path.length + change.kind.length + change.diff.length;
      if (weight > limit) return weight;
    }
    for (final attachment in entry.attachments) {
      weight +=
          40 +
          attachment.name.length +
          attachment.remotePath.length +
          attachment.mimeType.length;
      if (weight > limit) return weight;
    }
    for (final question in entry.questions) {
      weight +=
          80 +
          question.id.length +
          question.header.length +
          question.question.length;
      if (weight > limit) return weight;
      for (final option in question.options) {
        weight += 30 + option.label.length + option.description.length;
        if (weight > limit) return weight;
      }
    }
  }
  return weight;
}

String _hash(String value) => sha256.convert(utf8.encode(value)).toString();
String _filename(String scope, String threadId) =>
    '${_hash(scope)}_${_hash(threadId)}.snapshot';
Uint8List _randomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));
}

const _formatVersion = 1;
Uint8List? _encodeSnapshot(
  ThreadSessionSnapshot snapshot,
  Uint8List key,
  String scope,
  int plainLimit,
  int fileLimit,
) {
  try {
    if (key.length != 32) return null;
    final sink = _BoundedBytesSink(plainLimit);
    final encoder = json.encoder
        .fuse(utf8.encoder)
        .startChunkedConversion(sink);
    encoder.add(_snapshotJson(snapshot));
    encoder.close();
    final nonce = _randomBytes(12);
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        true,
        AEADParameters(
          KeyParameter(key),
          128,
          nonce,
          _aad(scope, snapshot.thread.id),
        ),
      );
    final encrypted = cipher.process(
      Uint8List.fromList(gzip.encode(sink.takeBytes())),
    );
    if (1 + nonce.length + encrypted.length > fileLimit) return null;
    return Uint8List.fromList([_formatVersion, ...nonce, ...encrypted]);
  } catch (_) {
    return null;
  }
}

ThreadSessionSnapshot? _decodeSnapshot(
  Uint8List bytes,
  Uint8List key,
  String scope,
  String threadId,
  int plainLimit,
  int now,
  int ttlMillis,
) {
  if (key.length != 32 || bytes.length < 29 || bytes.first != _formatVersion) {
    return null;
  }
  final cipher = GCMBlockCipher(AESEngine())
    ..init(
      false,
      AEADParameters(
        KeyParameter(key),
        128,
        bytes.sublist(1, 13),
        _aad(scope, threadId),
      ),
    );
  final compressed = cipher.process(bytes.sublist(13));
  final sink = _BoundedBytesSink(plainLimit);
  final decoder = gzip.decoder.startChunkedConversion(sink);
  // Chunked inflate enforces the expanded bound before collecting large content.
  for (var offset = 0; offset < compressed.length; offset += 4096) {
    decoder.add(
      compressed.sublist(offset, min(offset + 4096, compressed.length)),
    );
  }
  decoder.close();
  final value =
      jsonDecode(utf8.decode(sink.takeBytes())) as Map<String, dynamic>;
  if (value['version'] != _formatVersion) return null;
  final savedAt = value['savedAt'] as int;
  if (now - savedAt > ttlMillis ||
      savedAt > now + const Duration(minutes: 5).inMilliseconds) {
    return null;
  }
  final snapshot = _snapshotFromJson(value);
  return snapshot.thread.id == threadId ? snapshot : null;
}

Uint8List _aad(String scope, String threadId) => Uint8List.fromList(
  utf8.encode(jsonEncode([_formatVersion, scope, threadId])),
);

class _BoundedBytesSink implements Sink<List<int>> {
  _BoundedBytesSink(this.limit);
  final int limit;
  final _bytes = BytesBuilder(copy: false);
  @override
  void add(List<int> data) {
    if (_bytes.length + data.length > limit) {
      throw const FormatException('Cache size limit');
    }
    _bytes.add(data);
  }

  @override
  void close() {}
  Uint8List takeBytes() => _bytes.takeBytes();
}

Map<String, Object?> _snapshotJson(ThreadSessionSnapshot snapshot) => {
  'version': _formatVersion,
  'savedAt': snapshot.savedAtEpochMillis,
  'cursor': snapshot.nextTurnsCursor,
  'thread': {
    'id': snapshot.thread.id, 'title': snapshot.thread.title,
    'preview': snapshot.thread.preview, 'cwd': snapshot.thread.cwd,
    'source': snapshot.thread.source,
    'modelProvider': snapshot.thread.modelProvider,
    'status': snapshot.thread.status, 'createdAt': snapshot.thread.createdAt,
    'updatedAt': snapshot.thread.updatedAt,
    'cliVersion': snapshot.thread.cliVersion,
    'activeTurnId': snapshot.thread.activeTurnId,
    // Ownership is connection-local and deliberately not persisted.
  },
  'timeline': snapshot.timeline
      .map(
        (entry) => {
          'id': entry.id,
          'kind': entry.kind.name,
          'title': entry.title,
          'text': entry.text,
          'status': entry.status,
          'command': entry.command,
          'cwd': entry.cwd,
          'output': entry.output,
          'turnId': entry.turnId,
          'subAgentPath': entry.subAgentPath,
          'subAgentThreadId': entry.subAgentThreadId,
          'subAgentActivity': entry.subAgentActivity,
          'reasoningSummary': entry.reasoningSummary,
          'reasoningContent': entry.reasoningContent,
          'changes': entry.changes
              .map((c) => {'path': c.path, 'kind': c.kind, 'diff': c.diff})
              .toList(),
          'attachments': entry.attachments
              .map(
                (a) => {
                  'name': a.name,
                  'remotePath': a.remotePath,
                  'mimeType': a.mimeType,
                },
              )
              .toList(),
          'questions': entry.questions
              .map(
                (q) => {
                  'id': q.id,
                  'header': q.header,
                  'question': q.question,
                  'isOther': q.isOther,
                  'isSecret': q.isSecret,
                  'options': q.options
                      .map(
                        (o) => {'label': o.label, 'description': o.description},
                      )
                      .toList(),
                },
              )
              .toList(),
        },
      )
      .toList(),
  'usage': snapshot.tokenUsage == null
      ? null
      : {
          'last': _breakdownJson(snapshot.tokenUsage!.last),
          'total': _breakdownJson(snapshot.tokenUsage!.total),
          'window': snapshot.tokenUsage!.modelContextWindow,
        },
};

Map<String, int> _breakdownJson(TokenUsageBreakdown usage) => {
  'cachedInput': usage.cachedInputTokens,
  'input': usage.inputTokens,
  'output': usage.outputTokens,
  'reasoning': usage.reasoningOutputTokens,
  'total': usage.totalTokens,
};
TokenUsageBreakdown _breakdownFromJson(dynamic v) => TokenUsageBreakdown(
  cachedInputTokens: v['cachedInput'] as int,
  inputTokens: v['input'] as int,
  outputTokens: v['output'] as int,
  reasoningOutputTokens: v['reasoning'] as int,
  totalTokens: v['total'] as int,
);

ThreadSessionSnapshot _snapshotFromJson(Map<String, dynamic> value) {
  final t = value['thread'] as Map<String, dynamic>;
  final usage = value['usage'];
  return ThreadSessionSnapshot(
    savedAtEpochMillis: value['savedAt'] as int,
    nextTurnsCursor: value['cursor'] as String?,
    thread: AgentThread(
      id: t['id'] as String,
      title: t['title'] as String,
      preview: t['preview'] as String,
      cwd: t['cwd'] as String,
      source: t['source'] as String,
      modelProvider: t['modelProvider'] as String,
      status: t['status'] as String,
      createdAt: t['createdAt'] as int,
      updatedAt: t['updatedAt'] as int,
      cliVersion: t['cliVersion'] as String,
      activeTurnId: t['activeTurnId'] as String?,
    ),
    timeline: (value['timeline'] as List)
        .map(
          (v) => TimelineEntry(
            id: v['id'] as String,
            kind: TimelineKind.values.byName(v['kind'] as String),
            title: v['title'] as String,
            text: v['text'] as String,
            status: v['status'] as String,
            command: v['command'] as String,
            cwd: v['cwd'] as String,
            output: v['output'] as String,
            turnId: v['turnId'] as String,
            subAgentPath: v['subAgentPath'] as String,
            subAgentThreadId: v['subAgentThreadId'] as String,
            subAgentActivity: v['subAgentActivity'] as String,
            reasoningSummary: (v['reasoningSummary'] as List).cast<String>(),
            reasoningContent: (v['reasoningContent'] as List).cast<String>(),
            changes: (v['changes'] as List)
                .map(
                  (c) => FileChange(
                    path: c['path'] as String,
                    kind: c['kind'] as String,
                    diff: c['diff'] as String,
                  ),
                )
                .toList(),
            attachments: (v['attachments'] as List)
                .map(
                  (a) => MessageAttachment(
                    name: a['name'] as String,
                    remotePath: a['remotePath'] as String,
                    mimeType: a['mimeType'] as String,
                  ),
                )
                .toList(),
            questions: (v['questions'] as List)
                .map(
                  (q) => InputQuestion(
                    id: q['id'] as String,
                    header: q['header'] as String,
                    question: q['question'] as String,
                    isOther: q['isOther'] as bool,
                    isSecret: q['isSecret'] as bool,
                    options: (q['options'] as List)
                        .map(
                          (o) => InputOption(
                            label: o['label'] as String,
                            description: o['description'] as String,
                          ),
                        )
                        .toList(),
                  ),
                )
                .toList(),
          ),
        )
        .toList(),
    tokenUsage: usage == null
        ? null
        : TokenUsage(
            last: _breakdownFromJson(usage['last']),
            total: _breakdownFromJson(usage['total']),
            modelContextWindow: usage['window'] as int,
          ),
  );
}
