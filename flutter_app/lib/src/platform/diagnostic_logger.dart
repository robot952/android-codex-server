import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The small persistence surface used by [DiagnosticLogger].  Keeping this
/// separate from SharedPreferences makes the logger usable in VM/widget tests
/// without loading a platform plugin.
abstract interface class DiagnosticSettingsStore {
  Future<bool> readEnabled();

  Future<void> writeEnabled(bool value);
}

class SharedPreferencesDiagnosticSettingsStore
    implements DiagnosticSettingsStore {
  SharedPreferencesDiagnosticSettingsStore(this._preferences);

  static const enabledKey = 'diagnostic_logging_enabled';

  final SharedPreferences _preferences;

  @override
  Future<bool> readEnabled() async => _preferences.getBool(enabledKey) ?? false;

  @override
  Future<void> writeEnabled(bool value) async {
    await _preferences.setBool(enabledKey, value);
  }
}

class MemoryDiagnosticSettingsStore implements DiagnosticSettingsStore {
  MemoryDiagnosticSettingsStore({this._enabled = false});

  bool _enabled;

  @override
  Future<bool> readEnabled() async => _enabled;

  @override
  Future<void> writeEnabled(bool value) async {
    _enabled = value;
  }
}

typedef DiagnosticDirectoryProvider = Future<Directory> Function();
typedef DiagnosticSettingsProvider = Future<DiagnosticSettingsStore> Function();
typedef DiagnosticShareHandler = Future<void> Function(File file);
typedef DiagnosticNativeControl =
    Future<void> Function(String method, bool? enabled);

class DiagnosticLogEntry {
  const DiagnosticLogEntry({
    required this.id,
    required this.fileName,
    required this.createdAt,
    required this.updatedAt,
    required this.sizeBytes,
    required this.isActive,
    required this.hasCrash,
  });

  final String id;
  final String fileName;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int sizeBytes;
  final bool isActive;
  final bool hasCrash;
}

class DiagnosticLogSnapshot {
  const DiagnosticLogSnapshot({
    required this.enabled,
    required this.bytes,
    required this.updatedAt,
    required this.preview,
    required this.entries,
  });

  const DiagnosticLogSnapshot.empty()
    : enabled = false,
      bytes = 0,
      updatedAt = null,
      preview = '',
      entries = const <DiagnosticLogEntry>[];

  final bool enabled;
  final int bytes;
  final DateTime? updatedAt;
  final String preview;
  final List<DiagnosticLogEntry> entries;
}

/// Counts rapid taps on the home Codex icon. The counter resets after a pause
/// so an accidental sequence of taps cannot silently enable diagnostics.
class DebugTapCounter {
  DebugTapCounter({
    this.requiredTaps = 10,
    this.maximumGap = const Duration(milliseconds: 1_500),
  });

  final int requiredTaps;
  final Duration maximumGap;
  int _count = 0;
  DateTime? _previousTap;

  bool registerTap([DateTime? now]) {
    final timestamp = now ?? DateTime.now();
    final previous = _previousTap;
    if (previous == null || timestamp.difference(previous) > maximumGap) {
      _count = 0;
    }
    _previousTap = timestamp;
    _count++;
    if (_count < requiredTaps) return false;
    _count = 0;
    _previousTap = null;
    return true;
  }
}

/// Persistent, bounded diagnostic logging for the Flutter client.
///
/// Logs are opt-in for ordinary application events. Flutter errors and
/// uncaught asynchronous errors are always retained so a crash can be
/// diagnosed after the next launch. Every message is sanitized before it is
/// written, and old segments are pruned automatically.
class DiagnosticLogger {
  DiagnosticLogger({
    DiagnosticDirectoryProvider? directoryProvider,
    DiagnosticDirectoryProvider? exportDirectoryProvider,
    DiagnosticSettingsProvider? settingsProvider,
    DiagnosticShareHandler? shareHandler,
    DiagnosticNativeControl? nativeControl,
    DateTime Function()? clock,
  }) : _directoryProvider = directoryProvider ?? _defaultDirectory,
       _exportDirectoryProvider =
           exportDirectoryProvider ?? _defaultExportDirectory,
       _settingsProvider = settingsProvider ?? _defaultSettings,
       _shareHandler = shareHandler ?? _defaultShare,
       _nativeControl = nativeControl ?? _defaultNativeControl,
       _clock = clock ?? DateTime.now;

  static final DiagnosticLogger instance = DiagnosticLogger();

  /// Limit the original UTF-8 bytes, independently of the compression ratio.
  static const maxSegmentBytes = 100 * 1024;
  static const maxSegments = 5;
  static const maxArchiveBytes = maxSegmentBytes + 1024;
  static const maxTotalBytes = maxSegments * maxArchiveBytes;
  static const maxMessageChars = 4_000;
  static const maxStackChars = 24_000;
  static const maxPreviewBytes = 64 * 1024;

  final DiagnosticDirectoryProvider _directoryProvider;
  final DiagnosticDirectoryProvider _exportDirectoryProvider;
  final DiagnosticSettingsProvider _settingsProvider;
  final DiagnosticShareHandler _shareHandler;
  final DiagnosticNativeControl _nativeControl;
  final DateTime Function() _clock;

  Future<void>? _initialization;
  final List<_LogBuffer> _buffers = [];
  Future<void>? _flushInFlight;
  DiagnosticSettingsStore? _settings;
  Directory? _directory;
  bool _enabled = false;
  bool _initialized = false;
  int _sessionStartedAt = 0;
  int _segment = 0;

  bool get isEnabled => _enabled;

  Future<bool> initialize() {
    final existing = _initialization;
    if (existing != null) return existing.then((_) => _enabled);
    final initialization = _initialize();
    _initialization = initialization;
    return initialization.then((_) => _enabled);
  }

  Future<void> _initialize() async {
    if (_initialized) return;
    try {
      _settings = await _settingsProvider();
    } catch (_) {
      // A logger must never prevent the app from starting when a platform
      // preferences plugin is unavailable (for example in a host-side test).
      _settings = MemoryDiagnosticSettingsStore();
    }
    try {
      _directory = await _directoryProvider();
      await _directory!.create(recursive: true);
    } catch (_) {
      _directory = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}agent-diagnostics',
      );
      await _directory!.create(recursive: true);
    }
    try {
      _enabled = await _settings!.readEnabled();
    } catch (_) {
      _enabled = false;
    }
    _initialized = true;
    // Apply the retention limit to existing logs even when Debug is disabled.
    try {
      _prune();
      _migrateLegacyLogs();
    } catch (_) {
      // Cleanup must not prevent startup or crash recording.
    }
    if (_enabled) {
      try {
        _startSession();
      } catch (_) {
        // The app can still run without a writable diagnostics directory.
        _enabled = false;
      }
    }
  }

  Future<void> setEnabled(bool value) async {
    await initialize();
    if (_enabled == value) return;
    try {
      await _nativeControl('setEnabled', value);
    } catch (_) {}
    if (value) {
      _enabled = true;
      try {
        _startSession();
      } catch (_) {
        _enabled = false;
        return;
      }
    } else {
      try {
        _append(
          'INFO',
          'Debug',
          'diagnostic_logging_disabled',
          null,
          force: true,
        );
      } catch (_) {
        // Continue disabling even if the final transition cannot be written.
      }
      _enabled = false;
    }
    await flushSafely();
    try {
      await _settings?.writeEnabled(value);
    } catch (_) {
      // Logging remains useful for this process even if preference persistence
      // is temporarily unavailable.
    }
  }

  void info(String tag, String message) {
    _append('INFO', tag, message, null);
  }

  void warn(String tag, String message, [Object? error, StackTrace? stack]) {
    _append('WARN', tag, message, error, stack: stack);
  }

  void error(String tag, String message, [Object? error, StackTrace? stack]) {
    _append('ERROR', tag, message, error, stack: stack);
  }

  /// Records an error regardless of whether Debug mode was enabled. This is
  /// used by Flutter's global error hooks and intentionally has a FATAL level.
  void recordError(
    Object error,
    StackTrace stack, {
    String tag = 'Crash',
    String message = 'uncaught_exception',
  }) {
    _append('FATAL', tag, message, error, stack: stack, force: true);
  }

  void recordFlutterError(Object error, StackTrace? stack, {String? context}) {
    final detail = context == null || context.trim().isEmpty
        ? 'flutter_error'
        : 'flutter_error context=${context.trim()}';
    recordError(error, stack ?? StackTrace.current, message: detail);
  }

  Future<List<DiagnosticLogEntry>> listLogs() async {
    await flush();
    return _listLogsSync();
  }

  Future<DiagnosticLogSnapshot> snapshot({
    int previewByteLimit = maxPreviewBytes,
  }) async {
    await flush();
    final entries = _listLogsSync();
    final files = entries.reversed
        .map(
          (entry) => File(
            '${_directory!.path}${Platform.pathSeparator}${entry.fileName}',
          ),
        )
        .toList(growable: false);
    final bytes = files.fold<int>(0, (sum, file) => sum + file.lengthSync());
    final updated = entries.isEmpty ? null : entries.first.updatedAt;
    final full = files.map(_readFileSafely).join();
    return DiagnosticLogSnapshot(
      enabled: _enabled,
      bytes: bytes,
      updatedAt: updated,
      preview: takeLastUtf8Bytes(full, previewByteLimit),
      entries: entries,
    );
  }

  /// Reads only the file receiving new records in this process. Historical
  /// segments remain available through [listLogs] for attachments and sharing.
  Future<DiagnosticLogSnapshot> currentSnapshot({
    int previewByteLimit = maxPreviewBytes,
  }) async {
    await flush();
    final directory = _directory;
    if (directory == null || _sessionStartedAt == 0) {
      return DiagnosticLogSnapshot(
        enabled: _enabled,
        bytes: 0,
        updatedAt: null,
        preview: '',
        entries: const <DiagnosticLogEntry>[],
      );
    }
    final file = _currentFile(directory);
    if (!file.existsSync()) {
      return DiagnosticLogSnapshot(
        enabled: _enabled,
        bytes: 0,
        updatedAt: null,
        preview: '',
        entries: const <DiagnosticLogEntry>[],
      );
    }
    final contents = _readFileSafely(file);
    final updatedMillis = file.lastModifiedSync().millisecondsSinceEpoch;
    final entry = DiagnosticLogEntry(
      id: file.basename,
      fileName: file.basename,
      createdAt: DateTime.fromMillisecondsSinceEpoch(_sessionStartedAt),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        updatedMillis > 0 ? updatedMillis : _sessionStartedAt,
      ),
      sizeBytes: file.lengthSync(),
      isActive: true,
      hasCrash: RegExp(r'(^|\n).*\sFATAL\s').hasMatch(contents),
    );
    return DiagnosticLogSnapshot(
      enabled: _enabled,
      bytes: entry.sizeBytes,
      updatedAt: entry.updatedAt,
      preview: takeLastUtf8Bytes(contents, previewByteLimit),
      entries: <DiagnosticLogEntry>[entry],
    );
  }

  Future<String?> readLog(String id) async {
    await flush();
    final file = _resolveFile(id);
    return file == null ? null : _readFileSafely(file);
  }

  /// Returns a redacted, bounded copy suitable for a text attachment. The
  /// file is read only after pending writes have drained so a crash record can
  /// be selected immediately after launch.
  Future<String?> attachmentText(String id, {int maxBytes = 512 * 1024}) async {
    if (maxBytes <= 0) throw ArgumentError.value(maxBytes, 'maxBytes');
    final text = await readLog(id);
    return text == null ? null : _boundUtf8(text, maxBytes);
  }

  Future<File> exportLog({Iterable<String>? ids}) async {
    await flush();
    final entries = _listLogsSync();
    final selected = ids == null
        ? entries
        : entries
              .where((entry) => ids.contains(entry.id))
              .toList(growable: false);
    final files = ids != null && selected.isEmpty
        ? const <File>[]
        : selected.isEmpty
        ? entries
              .map(
                (entry) => File(
                  '${_directory!.path}${Platform.pathSeparator}${entry.fileName}',
                ),
              )
              .toList(growable: false)
        : selected
              .map(
                (entry) => File(
                  '${_directory!.path}${Platform.pathSeparator}${entry.fileName}',
                ),
              )
              .toList(growable: false);
    final outputDirectory = await _exportDirectoryProvider();
    await outputDirectory.create(recursive: true);
    final file = File(
      '${outputDirectory.path}${Platform.pathSeparator}agent-diagnostic-${_timestampForFile(_clock())}.log.gz',
    );
    // A single selection is already a sanitized gzip archive. Share that exact
    // payload; never expand it into a plaintext temporary file.
    if (files.length == 1) {
      _decodeArchive(_archiveBytes(files.single));
      return files.single.copy(file.path);
    }
    final buffer = StringBuffer()
      ..writeln('Agent diagnostic log')
      ..writeln('Exported: ${_clock().toIso8601String()}')
      ..writeln('Debug enabled: $_enabled')
      ..writeln('Sensitive values are redacted.')
      ..writeln();
    if (files.isEmpty) {
      buffer.writeln('No retained diagnostic logs.');
    } else {
      for (final entryFile in files) {
        buffer
          ..writeln('----- ${entryFile.basename} -----')
          ..write(_readLogFile(entryFile));
        if (!buffer.toString().endsWith('\n')) buffer.writeln();
      }
    }
    await file.writeAsBytes(
      gzip.encode(utf8.encode(sanitizeDiagnosticText(buffer.toString()))),
      flush: true,
    );
    return file;
  }

  Future<void> share({Iterable<String>? ids}) async {
    info('Debug', 'diagnostic_log_share_requested');
    final file = await exportLog(ids: ids);
    await _shareHandler(file);
  }

  Future<void> clear() async {
    await flush();
    await _nativeControl('clear', null);
    _buffers.clear();
    for (final entry in _listLogsSync()) {
      try {
        await File(
          '${_directory!.path}${Platform.pathSeparator}${entry.fileName}',
        ).delete();
      } catch (_) {
        // The next refresh will simply omit files that were deleted.
      }
    }
    // Export files are temporary copies created for the system share sheet.
    // Only remove files owned by this logger; other app temporary files stay
    // untouched.
    try {
      final outputDirectory = await _exportDirectoryProvider();
      if (outputDirectory.existsSync()) {
        for (final file in outputDirectory.listSync().whereType<File>()) {
          if (file.basename.startsWith('agent-diagnostic-')) {
            try {
              await file.delete();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
    // Keep the monotonic name reservation. New events can arrive while the
    // asynchronous export cleanup runs; do not reset their active segment.
  }

  /// Attach the compressed bytes as a file, without injecting log text into a
  /// model prompt. Validate the archive before returning an immutable snapshot.
  Future<Uint8List?> attachmentBytes(String id) async {
    await flush();
    final file = _resolveFile(id);
    if (file == null) return null;
    final bytes = _archiveBytes(file);
    _decodeArchive(bytes);
    return bytes;
  }

  /// User actions await this; lifecycle/error hooks use [flushSafely]. Ordinary
  /// records never enqueue file writes or compression jobs.
  Future<void> flush() {
    return _flushInFlight ??= _flush().whenComplete(
      () => _flushInFlight = null,
    );
  }

  Future<void> _flush() async {
    await initialize();
    await _nativeControl('flush', null);
    _flushSync();
  }

  Future<void> flushSafely() async {
    try {
      await flush();
    } catch (_) {
      // A failed snapshot remains dirty for retry; never recurse into logging.
      try {
        _flushSync();
      } catch (_) {}
    }
  }

  void _append(
    String level,
    String tag,
    String message,
    Object? error, {
    StackTrace? stack,
    bool force = false,
  }) {
    if (!_initialized) {
      unawaited(
        initialize()
            .then((_) {
              _append(level, tag, message, error, stack: stack, force: force);
            })
            .catchError((_) {}),
      );
      return;
    }
    if (!_enabled && !force) return;
    try {
      final bytes = utf8.encode(
        _formatEntry(level, tag, message, error, stack),
      );
      if (_buffers.isEmpty ||
          _buffers.last.bytes.length + bytes.length > maxSegmentBytes) {
        _startSession();
      }
      _buffers.last.bytes.add(bytes);
      _buffers.last.dirty = true;
      if (level == 'FATAL') {
        // Flush synchronously before returning to the process's fatal handler.
        _flushSync();
        unawaited(flushSafely());
      }
    } catch (_) {
      // Diagnostics must never turn an IO/formatting failure into another crash.
    }
  }

  void _startSession() {
    final directory = _directory;
    if (directory == null) return;
    var started = _clock().millisecondsSinceEpoch;
    // Reserve names only in memory; no empty files are written per record or
    // rotation. Monotonic segment times keep Dart/native retention comparable.
    final existing = _sessionFiles(directory);
    for (final file in existing) {
      final timestamp = _parseFileName(file.basename)!.$1;
      if (timestamp >= started) started = timestamp + 1;
    }
    if (started <= _sessionStartedAt) started = _sessionStartedAt + 1;
    _sessionStartedAt = started;
    _segment = 0;
    _buffers.add(_LogBuffer(_currentFile(directory)));
    while (_buffers.length > maxSegments) {
      _buffers.removeAt(0);
    }
  }

  void _flushSync() {
    final directory = _directory;
    if (directory == null) return;
    directory.createSync(recursive: true);
    for (final buffer in _buffers) {
      if (!buffer.dirty) continue;
      _writeArchive(buffer.file, buffer.bytes.toBytes());
      buffer.dirty = false;
    }
    _prune();
  }

  void _writeArchive(File file, List<int> bytes) {
    final temporary = File('${file.path}.tmp');
    try {
      temporary.writeAsBytesSync(gzip.encode(bytes), flush: true);
      temporary.renameSync(file.path);
    } finally {
      if (temporary.existsSync()) temporary.deleteSync();
    }
  }

  void _migrateLegacyLogs() {
    for (final file in _sessionFiles(_directory!)) {
      if (!file.path.endsWith('.log')) continue;
      try {
        final modified = file.lastModifiedSync();
        final text = _readLogFile(file);
        final archive = File('${file.path}.gz');
        _writeArchive(archive, utf8.encode(text));
        archive.setLastModifiedSync(modified);
        file.deleteSync();
      } catch (_) {
        // Preserve the original if migration could not safely finish.
      }
    }
    _prune();
  }

  void _prune() {
    final directory = _directory;
    if (directory == null) return;
    final files = _sessionFiles(directory);
    var totalBytes = files.fold<int>(0, (sum, file) => sum + file.lengthSync());
    var remainingCount = files.length;
    for (final file in files) {
      if (remainingCount <= maxSegments && totalBytes <= maxTotalBytes) break;
      try {
        final size = file.lengthSync();
        file.deleteSync();
        totalBytes -= size;
        remainingCount--;
      } catch (_) {
        // A transient cleanup failure must not interrupt active logging.
      }
    }
  }

  List<DiagnosticLogEntry> _listLogsSync() {
    final directory = _directory;
    if (directory == null || !directory.existsSync()) return const [];
    final files = _sessionFiles(directory);
    return files.reversed
        .map((file) {
          final parsed = _parseFileName(file.basename);
          if (parsed == null) return null;
          final created = DateTime.fromMillisecondsSinceEpoch(parsed.$1);
          final updatedMillis = file.lastModifiedSync().millisecondsSinceEpoch;
          final contents = _readFileSafely(file);
          return DiagnosticLogEntry(
            id: file.basename,
            fileName: file.basename,
            createdAt: created,
            updatedAt: DateTime.fromMillisecondsSinceEpoch(
              updatedMillis > 0 ? updatedMillis : parsed.$1,
            ),
            sizeBytes: file.lengthSync(),
            isActive:
                _enabled &&
                parsed.$1 == _sessionStartedAt &&
                parsed.$2 == _segment,
            hasCrash: RegExp(r'(^|\n).*\sFATAL\s').hasMatch(contents),
          );
        })
        .whereType<DiagnosticLogEntry>()
        .toList(growable: false);
  }

  List<File> _sessionFiles(Directory directory) =>
      directory
          .listSync(followLinks: false)
          .whereType<File>()
          .where((file) => _parseFileName(file.basename) != null)
          .toList()
        ..sort((a, b) => a.basename.compareTo(b.basename));

  File? _resolveFile(String id) {
    if (_parseFileName(id) == null || _directory == null) return null;
    final name = id.endsWith('.log') ? '$id.gz' : id;
    final file = File('${_directory!.path}${Platform.pathSeparator}$name');
    return file.existsSync() ? file : null;
  }

  File _currentFile(Directory directory) => File(
    '${directory.path}${Platform.pathSeparator}session-'
    '${_sessionStartedAt.toString().padLeft(13, '0')}-'
    '${_segment.toString().padLeft(6, '0')}.log.gz',
  );

  String _formatEntry(
    String level,
    String tag,
    String message,
    Object? error,
    StackTrace? stack,
  ) {
    final safeTag = sanitizeDiagnosticText(
      tag,
    ).replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
    final safeMessage = sanitizeDiagnosticText(message).trim();
    final body = safeMessage.isEmpty ? '(empty)' : safeMessage;
    final output = StringBuffer()
      ..write(_clock().toIso8601String())
      ..write(' ')
      ..write(level)
      ..write(' ')
      ..write(safeTag.isEmpty ? 'App' : _truncateChars(safeTag, 48))
      ..write(' ')
      ..writeln(_truncateChars(body, maxMessageChars));
    if (error != null) {
      output.writeln(
        _truncateChars(
          sanitizeDiagnosticText(error.toString()),
          maxMessageChars,
        ),
      );
    }
    if (stack != null) {
      final safeStack = sanitizeDiagnosticText(stack.toString());
      output.writeln(_truncateChars(safeStack, maxStackChars));
    }
    return _boundUtf8(output.toString(), maxSegmentBytes);
  }

  String _readFileSafely(File file) {
    try {
      return _readLogFile(file);
    } catch (_) {
      return '';
    }
  }

  String _readLogFile(File file) {
    if (file.path.endsWith('.gz')) {
      return sanitizeDiagnosticText(
        utf8.decode(_decodeArchive(_archiveBytes(file)), allowMalformed: true),
      );
    }
    final handle = file.openSync();
    try {
      return _boundUtf8(
        sanitizeDiagnosticText(
          utf8.decode(handle.readSync(maxSegmentBytes), allowMalformed: true),
        ),
        maxSegmentBytes,
      );
    } finally {
      handle.closeSync();
    }
  }

  static Uint8List _archiveBytes(File file) {
    final handle = file.openSync();
    try {
      final bytes = handle.readSync(maxArchiveBytes + 1);
      if (bytes.length > maxArchiveBytes) {
        throw const FormatException('诊断日志超出大小限制');
      }
      return bytes;
    } finally {
      handle.closeSync();
    }
  }

  static Uint8List _decodeArchive(List<int> bytes) {
    if (bytes.length > maxArchiveBytes) {
      throw const FormatException('诊断日志超出大小限制');
    }
    final sink = _BoundedLogSink(maxSegmentBytes);
    final decoder = gzip.decoder.startChunkedConversion(sink);
    decoder.add(bytes);
    decoder.close();
    return sink.bytes.takeBytes();
  }

  static Future<void> _defaultNativeControl(
    String method,
    bool? enabled,
  ) async {
    if (!Platform.isAndroid) return;
    await const MethodChannel(
      'top.asdb.agent/diagnostics',
    ).invokeMethod<void>(method, enabled == null ? null : {'enabled': enabled});
  }

  static Future<Directory> _defaultDirectory() async {
    final root = await getApplicationSupportDirectory();
    return Directory('${root.path}${Platform.pathSeparator}diagnostics');
  }

  static Future<Directory> _defaultExportDirectory() => getTemporaryDirectory();

  static Future<DiagnosticSettingsStore> _defaultSettings() async {
    return SharedPreferencesDiagnosticSettingsStore(
      await SharedPreferences.getInstance(),
    );
  }

  static Future<void> _defaultShare(File file) async {
    final result = await SharePlus.instance.share(
      ShareParams(
        files: <XFile>[XFile(file.path, mimeType: 'application/gzip')],
        subject: 'Agent Debug 日志',
      ),
    );
    if (result.status == ShareResultStatus.unavailable) {
      throw StateError('系统没有可用的分享目标');
    }
  }
}

class _LogBuffer {
  _LogBuffer(this.file);
  final File file;
  final BytesBuilder bytes = BytesBuilder(copy: false);
  bool dirty = true;
}

class _BoundedLogSink implements Sink<List<int>> {
  _BoundedLogSink(this.limit);
  final int limit;
  final BytesBuilder bytes = BytesBuilder(copy: false);
  @override
  void add(List<int> data) {
    if (bytes.length + data.length > limit) {
      throw const FormatException('诊断日志解压超出大小限制');
    }
    bytes.add(data);
  }

  @override
  void close() {}
}

extension on FileSystemEntity {
  String get basename => path.split(Platform.pathSeparator).last;
}

String sanitizeDiagnosticText(String value) {
  var result = value.replaceAll(RegExp(r'\u001B\[[0-9;]*[A-Za-z]'), '');
  result = result.replaceAll(
    RegExp(
      r'-----BEGIN[^-]*PRIVATE KEY-----.*?-----END[^-]*PRIVATE KEY-----',
      caseSensitive: false,
      dotAll: true,
    ),
    '[REDACTED_PRIVATE_KEY]',
  );
  result = result.replaceAllMapped(
    RegExp(r'([a-z][a-z0-9+.-]*://)[^/@\s]+@', caseSensitive: false),
    (match) => '${match.group(1)}[REDACTED]@',
  );
  result = result.replaceAllMapped(
    RegExp(r'(bearer\s+)[a-z0-9._~+/=-]+', caseSensitive: false),
    (match) => '${match.group(1)}[REDACTED]',
  );
  result = result.replaceAll(
    RegExp(r'\bsk-[a-zA-Z0-9_-]{16,}\b'),
    '[REDACTED_API_KEY]',
  );
  result = result.replaceAllMapped(
    RegExp(
      r'''\b(password|passphrase|token|api[_-]?key|authorization|secret)'''
      r'''(\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s,;]+)''',
      caseSensitive: false,
    ),
    (match) => '${match.group(1)}${match.group(2)}[REDACTED]',
  );
  return result.replaceAll(
    RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]'),
    '',
  );
}

String takeLastUtf8Bytes(String value, int maxBytes) {
  if (maxBytes <= 0 || value.isEmpty) return '';
  final bytes = utf8.encode(value);
  if (bytes.length <= maxBytes) return value;
  var start = bytes.length - maxBytes;
  while (start < bytes.length && (bytes[start] & 0xC0) == 0x80) {
    start++;
  }
  return utf8.decode(bytes.sublist(start), allowMalformed: true);
}

String _boundUtf8(String value, int maxBytes) {
  final bytes = utf8.encode(value);
  if (bytes.length <= maxBytes) return value;
  final suffix = '\n[diagnostic entry truncated]\n';
  final suffixBytes = utf8.encode(suffix);
  final withSuffix = suffixBytes.length < maxBytes;
  var end = maxBytes - (withSuffix ? suffixBytes.length : 0);
  while (end > 0 && (bytes[end] & 0xC0) == 0x80) {
    end--;
  }
  return utf8.decode(bytes.sublist(0, end)) + (withSuffix ? suffix : '');
}

String _timestampForFile(DateTime value) =>
    value.millisecondsSinceEpoch.toString();

(int, int)? _parseFileName(String name) {
  final match = RegExp(r'^session-(\d+)-(\d+)\.log(?:\.gz)?$').firstMatch(name);
  if (match == null) return null;
  final started = int.tryParse(match.group(1)!);
  final segment = int.tryParse(match.group(2)!);
  return started == null || segment == null ? null : (started, segment);
}

String _truncateChars(String value, int maximum) =>
    value.length <= maximum ? value : value.substring(0, maximum);
