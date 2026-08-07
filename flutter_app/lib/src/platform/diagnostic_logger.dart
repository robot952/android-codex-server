import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
    DateTime Function()? clock,
  }) : _directoryProvider = directoryProvider ?? _defaultDirectory,
       _exportDirectoryProvider =
           exportDirectoryProvider ?? _defaultExportDirectory,
       _settingsProvider = settingsProvider ?? _defaultSettings,
       _shareHandler = shareHandler ?? _defaultShare,
       _clock = clock ?? DateTime.now;

  static final DiagnosticLogger instance = DiagnosticLogger();

  static const maxSegmentBytes = 128 * 1024;
  static const maxSegments = 32;
  static const maxMessageChars = 4_000;
  static const maxStackChars = 24_000;
  static const maxPreviewBytes = 64 * 1024;

  final DiagnosticDirectoryProvider _directoryProvider;
  final DiagnosticDirectoryProvider _exportDirectoryProvider;
  final DiagnosticSettingsProvider _settingsProvider;
  final DiagnosticShareHandler _shareHandler;
  final DateTime Function() _clock;

  Future<void>? _initialization;
  Future<void>? _writeTail;
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
    if (_enabled) {
      try {
        await _startSession();
      } catch (_) {
        // The app can still run without a writable diagnostics directory.
        _enabled = false;
      }
    }
  }

  Future<void> setEnabled(bool value) async {
    await initialize();
    if (_enabled == value) return;
    if (value) {
      _enabled = true;
      try {
        await _startSession();
      } catch (_) {
        _enabled = false;
        return;
      }
    } else {
      try {
        await _append(
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
    try {
      await _settings?.writeEnabled(value);
    } catch (_) {
      // Logging remains useful for this process even if preference persistence
      // is temporarily unavailable.
    }
  }

  void info(String tag, String message) {
    unawaited(_append('INFO', tag, message, null));
  }

  void warn(String tag, String message, [Object? error, StackTrace? stack]) {
    unawaited(_append('WARN', tag, message, error, stack: stack));
  }

  void error(String tag, String message, [Object? error, StackTrace? stack]) {
    unawaited(_append('ERROR', tag, message, error, stack: stack));
  }

  /// Records an error regardless of whether Debug mode was enabled. This is
  /// used by Flutter's global error hooks and intentionally has a FATAL level.
  void recordError(
    Object error,
    StackTrace stack, {
    String tag = 'Crash',
    String message = 'uncaught_exception',
  }) {
    unawaited(_append('FATAL', tag, message, error, stack: stack, force: true));
  }

  void recordFlutterError(Object error, StackTrace? stack, {String? context}) {
    final detail = context == null || context.trim().isEmpty
        ? 'flutter_error'
        : 'flutter_error context=${context.trim()}';
    recordError(error, stack ?? StackTrace.current, message: detail);
  }

  Future<List<DiagnosticLogEntry>> listLogs() async {
    await initialize();
    await _drainWrites();
    return _listLogsSync();
  }

  Future<DiagnosticLogSnapshot> snapshot({
    int previewByteLimit = maxPreviewBytes,
  }) async {
    await initialize();
    await _drainWrites();
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

  Future<String?> readLog(String id) async {
    await initialize();
    await _drainWrites();
    final file = _resolveFile(id);
    return file == null ? null : _readFileSafely(file);
  }

  Future<File> exportLog({Iterable<String>? ids}) async {
    await initialize();
    await _drainWrites();
    final entries = _listLogsSync();
    final selected = ids == null
        ? entries
        : entries
              .where((entry) => ids.contains(entry.id))
              .toList(growable: false);
    final files = selected.isEmpty
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
      '${outputDirectory.path}${Platform.pathSeparator}agent-diagnostic-${_timestampForFile(_clock())}.txt',
    );
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
          ..write(_readFileSafely(entryFile));
        if (!buffer.toString().endsWith('\n')) buffer.writeln();
      }
    }
    await file.writeAsString(sanitizeDiagnosticText(buffer.toString()));
    return file;
  }

  Future<void> share({Iterable<String>? ids}) async {
    final file = await exportLog(ids: ids);
    await _shareHandler(file);
    info('Debug', 'diagnostic_log_share_requested');
  }

  Future<void> clear() async {
    await initialize();
    await _drainWrites();
    for (final entry in _listLogsSync()) {
      try {
        await File(
          '${_directory!.path}${Platform.pathSeparator}${entry.fileName}',
        ).delete();
      } catch (_) {
        // The next refresh will simply omit files that were deleted.
      }
    }
    _sessionStartedAt = 0;
    _segment = 0;
  }

  Future<void> _append(
    String level,
    String tag,
    String message,
    Object? error, {
    StackTrace? stack,
    bool force = false,
  }) async {
    await initialize();
    if (!_enabled && !force) return;
    final entry = _formatEntry(level, tag, message, error, stack);
    final previous = _writeTail ?? Future<void>.value();
    final next = previous.then<void>(
      (_) => _writeEntry(entry),
      onError: (_, _) => _writeEntry(entry),
    );
    _writeTail = next;
    await next;
  }

  Future<void> _writeEntry(String entry) async {
    if (_sessionStartedAt == 0) await _startSession();
    final directory = _directory;
    if (directory == null) return;
    var file = _currentFile(directory);
    final bytes = utf8.encode(entry);
    if (file.existsSync() &&
        file.lengthSync() + bytes.length > maxSegmentBytes) {
      _segment++;
      file = _currentFile(directory);
      await file.create(recursive: true);
    }
    await file.writeAsString(entry, mode: FileMode.append, flush: true);
    await _prune();
  }

  Future<void> _startSession() async {
    final directory = _directory;
    if (directory == null) return;
    await directory.create(recursive: true);
    var started = _clock().millisecondsSinceEpoch;
    // Avoid collisions when several logger instances/processes start in one
    // millisecond.
    final existing = _sessionFiles(directory);
    while (existing.any((file) => file.path.contains('session-$started-'))) {
      started++;
    }
    _sessionStartedAt = started;
    _segment = 0;
    await _currentFile(directory).create(recursive: true);
    await _prune();
  }

  Future<void> _prune() async {
    final directory = _directory;
    if (directory == null) return;
    final files = _sessionFiles(directory);
    if (files.length <= maxSegments) return;
    for (final file in files.take(files.length - maxSegments)) {
      try {
        await file.delete();
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
            hasCrash: _readFileSafely(file).contains('FATAL Crash'),
          );
        })
        .whereType<DiagnosticLogEntry>()
        .toList(growable: false);
  }

  List<File> _sessionFiles(Directory directory) =>
      directory
          .listSync()
          .whereType<File>()
          .where((file) => _parseFileName(file.basename) != null)
          .toList()
        ..sort((a, b) => a.basename.compareTo(b.basename));

  File? _resolveFile(String id) {
    if (_parseFileName(id) == null || _directory == null) return null;
    final file = File('${_directory!.path}${Platform.pathSeparator}$id');
    return file.existsSync() ? file : null;
  }

  File _currentFile(Directory directory) => File(
    '${directory.path}${Platform.pathSeparator}session-'
    '${_sessionStartedAt.toString().padLeft(13, '0')}-'
    '${_segment.toString().padLeft(6, '0')}.log',
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
      return sanitizeDiagnosticText(file.readAsStringSync());
    } catch (_) {
      return '';
    }
  }

  Future<void> _drainWrites() async {
    final tail = _writeTail;
    if (tail != null) await tail.catchError((_) {});
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
        files: <XFile>[XFile(file.path, mimeType: 'text/plain')],
        subject: 'Agent Debug 日志',
      ),
    );
    if (result.status == ShareResultStatus.unavailable) {
      throw StateError('系统没有可用的分享目标');
    }
  }
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
  if (suffixBytes.length >= maxBytes) {
    return utf8.decode(bytes.take(maxBytes).toList(), allowMalformed: true);
  }
  return utf8.decode(
        bytes.take(maxBytes - suffixBytes.length).toList(),
        allowMalformed: true,
      ) +
      suffix;
}

String _timestampForFile(DateTime value) =>
    value.millisecondsSinceEpoch.toString();

(int, int)? _parseFileName(String name) {
  final match = RegExp(r'^session-(\d+)-(\d+)\.log$').firstMatch(name);
  if (match == null) return null;
  final started = int.tryParse(match.group(1)!);
  final segment = int.tryParse(match.group(2)!);
  return started == null || segment == null ? null : (started, segment);
}

String _truncateChars(String value, int maximum) =>
    value.length <= maximum ? value : value.substring(0, maximum);
