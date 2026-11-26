import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codex_remote/src/platform/diagnostic_logger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late Directory exportDirectory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('agent-diagnostic-test-');
    exportDirectory = await Directory.systemTemp.createTemp(
      'agent-diagnostic-export-',
    );
  });

  tearDown(() async {
    await directory.delete(recursive: true);
    await exportDirectory.delete(recursive: true);
  });

  DiagnosticLogger createLogger({
    bool enabled = false,
    DiagnosticShareHandler? shareHandler,
    DateTime Function()? clock,
    DiagnosticNativeControl? nativeControl,
  }) {
    final settings = MemoryDiagnosticSettingsStore(enabled: enabled);
    return DiagnosticLogger(
      directoryProvider: () async => directory,
      exportDirectoryProvider: () async => exportDirectory,
      settingsProvider: () async => settings,
      shareHandler: shareHandler,
      clock: clock,
      nativeControl: nativeControl,
    );
  }

  test('persists enabled state and sanitizes ordinary log records', () async {
    final settings = MemoryDiagnosticSettingsStore();
    final first = DiagnosticLogger(
      directoryProvider: () async => directory,
      exportDirectoryProvider: () async => exportDirectory,
      settingsProvider: () async => settings,
    );

    await first.setEnabled(true);
    first.info(
      'SSH',
      'password=super-secret token: abc123 '
          'https://user:pass@example.com sk-12345678901234567890',
    );
    final snapshot = await first.snapshot();
    expect(snapshot.enabled, isTrue);
    expect(snapshot.preview, contains('password=[REDACTED]'));
    expect(snapshot.preview, contains('token: [REDACTED]'));
    expect(snapshot.preview, contains('https://[REDACTED]@example.com'));
    expect(snapshot.preview, contains('[REDACTED_API_KEY]'));
    expect(snapshot.preview, isNot(contains('super-secret')));

    final second = DiagnosticLogger(
      directoryProvider: () async => directory,
      exportDirectoryProvider: () async => exportDirectory,
      settingsProvider: () async => settings,
    );
    expect(await second.initialize(), isTrue);
  });

  test('retains crash records while ordinary logging is disabled', () async {
    final logger = createLogger();
    await logger.initialize();
    logger.recordError(
      StateError('secret=do-not-write'),
      StackTrace.fromString('at test secret=also-hidden'),
    );

    final snapshot = await logger.snapshot();
    expect(snapshot.preview, contains('FATAL Crash uncaught_exception'));
    expect(snapshot.preview, isNot(contains('do-not-write')));
    expect(snapshot.preview, isNot(contains('also-hidden')));
  });

  test('current snapshot reads only the active segment', () async {
    await File(
      '${directory.path}/session-1800000000000-000000.log',
    ).writeAsString('2026-01-01T00:00:00Z INFO Test historical-entry\n');
    final logger = createLogger(
      enabled: true,
      clock: () => DateTime.fromMillisecondsSinceEpoch(1_900_000_000_000),
    );
    await logger.initialize();
    logger.info('Test', 'current-entry');

    final current = await logger.currentSnapshot();

    expect(current.entries, hasLength(1));
    expect(current.entries.single.isActive, isTrue);
    expect(current.preview, contains('current-entry'));
    expect(current.preview, isNot(contains('historical-entry')));
    expect(current.bytes, lessThanOrEqualTo(DiagnosticLogger.maxSegmentBytes));
    expect(await logger.listLogs(), hasLength(2));
  });

  test('shares multiple sessions through the injected share handler', () async {
    File? sharedFile;
    final logger = createLogger(
      enabled: true,
      shareHandler: (file) async {
        sharedFile = file;
      },
    );
    await logger.initialize();
    logger.info('Test', 'first-session');
    await logger.setEnabled(false);
    await logger.setEnabled(true);
    logger.info('Test', 'second-session');
    await logger.share();

    final snapshot = await logger.snapshot();
    expect(snapshot.entries, hasLength(2));
    expect(snapshot.entries.first.isActive, isTrue);
    expect(snapshot.bytes, lessThanOrEqualTo(DiagnosticLogger.maxTotalBytes));
    expect(
      snapshot.entries.every(
        (entry) => entry.sizeBytes <= DiagnosticLogger.maxArchiveBytes,
      ),
      isTrue,
    );
    expect(sharedFile, isNotNull);
    expect(await sharedFile!.exists(), isTrue);
    expect(
      utf8.decode(gzip.decode(await sharedFile!.readAsBytes())),
      contains('Agent diagnostic log'),
    );
    expect(
      utf8.decode(gzip.decode(await sharedFile!.readAsBytes())),
      contains('first-session'),
    );
    expect(snapshot.preview, contains('second-session'));
  });

  for (final enabled in [false, true]) {
    test(
      'startup retains only five newest files with Debug=$enabled',
      () async {
        for (var index = 0; index < 105; index++) {
          final started = 1_800_000_000_000 + index;
          await File(
            '${directory.path}/session-$started-000000.log',
          ).writeAsString('2026-01-01T00:00:00Z INFO Test entry-$index\n');
        }
        final marker = File('${directory.path}/.agent-process-marker');
        await marker.writeAsString('keep');
        final unrelated = File('${directory.path}/unrelated.txt');
        await unrelated.writeAsString('keep');
        final logger = createLogger(
          enabled: enabled,
          clock: () => DateTime.fromMillisecondsSinceEpoch(1_900_000_000_000),
        );
        expect(await logger.initialize(), enabled);

        final snapshot = await logger.snapshot();
        final expectedIds = [
          if (enabled) 'session-1900000000000-000000.log.gz',
          for (var index = 104; index >= (enabled ? 101 : 100); index--)
            'session-${1_800_000_000_000 + index}-000000.log.gz',
        ];
        expect(snapshot.entries, hasLength(5));
        expect(snapshot.entries.map((entry) => entry.id), expectedIds);
        expect(
          snapshot.bytes,
          lessThanOrEqualTo(DiagnosticLogger.maxTotalBytes),
        );
        expect(
          directory.listSync().whereType<File>().where(
            (file) => file.path.endsWith('.log.gz'),
          ),
          hasLength(5),
        );
        expect(await marker.readAsString(), 'keep');
        expect(await unrelated.readAsString(), 'keep');
      },
    );
  }

  test('clear removes share copies but keeps Debug enabled', () async {
    final logger = createLogger(enabled: true);
    await logger.initialize();
    logger.info('Test', 'before-clear');
    final exported = await logger.exportLog();
    final unrelated = File('${exportDirectory.path}/unrelated.tmp');
    await unrelated.writeAsString('keep');

    await logger.clear();
    expect(await exported.exists(), isFalse);
    expect(await unrelated.exists(), isTrue);
    expect(logger.isEnabled, isTrue);
    expect((await logger.snapshot()).entries, isEmpty);

    logger.info('Test', 'after-clear');
    final restarted = await logger.snapshot();
    expect(restarted.entries, hasLength(1));
    expect(restarted.preview, contains('after-clear'));
  });

  test('selected export and attachment are independently redacted', () async {
    final logger = createLogger(enabled: true);
    await logger.initialize();
    logger.info('Test', 'first-session');
    await logger.setEnabled(false);
    await logger.setEnabled(true);
    logger.info('Test', 'second-session api_key=top-secret');
    final entries = await logger.listLogs();
    expect(entries.length, greaterThanOrEqualTo(2));

    final newest = entries.first;
    final exported = await logger.exportLog(ids: [newest.id]);
    final exportText = utf8.decode(gzip.decode(await exported.readAsBytes()));
    expect(exportText, contains('second-session'));
    expect(exportText, isNot(contains('first-session')));
    expect(exportText, isNot(contains('top-secret')));

    final attachment = await logger.attachmentText(newest.id, maxBytes: 256);
    expect(attachment, contains('[REDACTED]'));
    expect(attachment, isNot(contains('top-secret')));
    expect(attachment!.length, lessThanOrEqualTo(256));
  });

  test(
    'ordinary records stay in memory until flush and share exact gzip bytes',
    () async {
      final logger = createLogger(enabled: true);
      await logger.initialize();
      logger.info('Test', '中文日志 password=hidden-value');
      await Future<void>.delayed(Duration.zero);
      expect(directory.listSync(), isEmpty);
      await logger.flush();
      final file = directory.listSync().whereType<File>().single;
      expect(file.path, endsWith('.log.gz'));
      final before = file.readAsBytesSync();
      expect(
        utf8.decode(gzip.decode(before)),
        contains('中文日志 password=[REDACTED]'),
      );
      final modified = file.lastModifiedSync();
      await logger.flush();
      expect(file.lastModifiedSync(), modified);
      logger.info('Test', 'second-record');
      expect(file.readAsBytesSync(), before);
      final entry = (await logger.listLogs()).single;
      expect(
        utf8.decode(gzip.decode(file.readAsBytesSync())),
        contains('second-record'),
      );
      expect(await logger.attachmentBytes(entry.id), file.readAsBytesSync());
      final exported = await logger.exportLog(ids: [entry.id]);
      expect(exported.path, endsWith('.log.gz'));
      expect(exported.readAsBytesSync(), file.readAsBytesSync());
      expect(directory.listSync().any((f) => f.path.endsWith('.tmp')), isFalse);
    },
  );

  test(
    'a long foreground session rotates only in memory and keeps five recent segments',
    () async {
      final logger = createLogger(enabled: true);
      await logger.initialize();
      for (var i = 0; i < 680; i++) {
        logger.info('Test', 'record-$i ${'正文😀' * 800}');
      }
      expect(directory.listSync(), isEmpty);
      final entries = await logger.listLogs();
      expect(entries, hasLength(5));
      final contents = <String>[];
      for (final file in directory.listSync().whereType<File>()) {
        final original = gzip.decode(file.readAsBytesSync());
        expect(original.length, lessThanOrEqualTo(1024 * 1024));
        contents.add(utf8.decode(original));
      }
      expect(contents.join(), isNot(contains('record-0 ')));
      expect(contents.join(), contains('record-679 '));
      expect(
        contents.any((text) => utf8.encode(text).length > 100 * 1024),
        isTrue,
      );
    },
  );

  test(
    'fatal capture persists immediately even without awaiting any logger action',
    () async {
      final logger = createLogger();
      await logger.initialize();
      logger.recordError(
        StateError('fatal secret=hidden'),
        StackTrace.fromString('crash-stack'),
      );
      final file = directory.listSync().whereType<File>().single;
      final contents = utf8.decode(gzip.decode(file.readAsBytesSync()));
      expect(contents, contains('FATAL'));
      expect(contents, contains('crash-stack'));
      expect(contents, isNot(contains('hidden')));
      await logger.flush();
    },
  );

  test(
    'disable flushes final records and clear cannot resurrect buffered history',
    () async {
      final logger = createLogger(enabled: true);
      await logger.initialize();
      logger.info('Test', 'last-before-disable');
      await logger.setEnabled(false);
      final file = directory.listSync().whereType<File>().single;
      final text = utf8.decode(gzip.decode(file.readAsBytesSync()));
      expect(text, contains('last-before-disable'));
      expect(text, contains('diagnostic_logging_disabled'));
      logger.info('Test', 'must-not-record');
      await logger.flush();
      expect(utf8.decode(gzip.decode(file.readAsBytesSync())), text);
      await logger.clear();
      await logger.flush();
      expect(directory.listSync(), isEmpty);
    },
  );

  test(
    'failed atomic save retains both old gzip and dirty memory for retry',
    () async {
      final logger = createLogger(enabled: true);
      await logger.initialize();
      logger.info('Test', 'before');
      final entry = (await logger.listLogs()).single;
      final file = File('${directory.path}/${entry.id}');
      final original = file.readAsBytesSync();
      final blocker = Directory('${file.path}.tmp')..createSync();
      logger.info('Test', 'retry-me');
      await expectLater(logger.flush(), throwsA(isA<FileSystemException>()));
      expect(file.readAsBytesSync(), original);
      blocker.deleteSync();
      await logger.flush();
      expect(
        utf8.decode(gzip.decode(file.readAsBytesSync())),
        contains('retry-me'),
      );
    },
  );

  test('events arriving during clear keep their active segment', () async {
    final cleanupStarted = Completer<void>();
    final finishCleanup = Completer<void>();
    final logger = DiagnosticLogger(
      directoryProvider: () async => directory,
      exportDirectoryProvider: () async {
        cleanupStarted.complete();
        await finishCleanup.future;
        return exportDirectory;
      },
      settingsProvider: () async =>
          MemoryDiagnosticSettingsStore(enabled: true),
      clock: () => DateTime.fromMillisecondsSinceEpoch(1_900_000_000_000),
    );
    await logger.initialize();
    logger.info('Test', 'old-record');
    final oldId = (await logger.listLogs()).single.id;
    final clearing = logger.clear();
    await cleanupStarted.future;
    logger.info('Test', 'after-clear-record');
    finishCleanup.complete();
    await clearing;
    final current = await logger.currentSnapshot();
    expect(current.entries.single.id, isNot(oldId));
    expect(current.entries.single.isActive, isTrue);
    expect(current.preview, contains('after-clear-record'));
    expect(current.preview, isNot(contains('old-record')));
    expect(await logger.attachmentBytes(oldId), isNull);
  });

  test(
    'flush waits for native logs and includes records appended during the wait',
    () async {
      final nativeReady = Completer<void>();
      var calls = 0;
      final logger = createLogger(
        enabled: true,
        nativeControl: (method, _) async {
          if (method == 'flush') {
            calls++;
            await nativeReady.future;
          }
        },
      );
      await logger.initialize();
      logger.info('Test', 'before');
      final first = logger.flush();
      final second = logger.flush();
      await Future<void>.delayed(Duration.zero);
      logger.info('Test', 'during');
      expect(directory.listSync(), isEmpty);
      nativeReady.complete();
      await Future.wait([first, second]);
      expect(calls, 1);
      expect(
        utf8.decode(
          gzip.decode(
            directory.listSync().whereType<File>().single.readAsBytesSync(),
          ),
        ),
        contains('during'),
      );
    },
  );

  test('legacy files migrate with timestamps and redaction intact', () async {
    final legacy = File('${directory.path}/session-1800000000000-000000.log');
    legacy.writeAsStringSync(
      '2026-01-01T00:00:00Z FATAL Crash password=private-value\n原始正文\n',
    );
    final modified = DateTime(2026, 1, 1);
    legacy.setLastModifiedSync(modified);
    final logger = createLogger();
    await logger.initialize();
    expect(legacy.existsSync(), isFalse);
    final archive = File('${legacy.path}.gz');
    expect(archive.lastModifiedSync(), modified);
    final entry = (await logger.listLogs()).single;
    expect(entry.hasCrash, isTrue);
    expect(entry.sizeBytes, archive.lengthSync());
    final text = utf8.decode(
      gzip.decode((await logger.attachmentBytes(entry.id))!),
    );
    expect(text, contains('原始正文'));
    expect(text, isNot(contains('private-value')));
  });

  test(
    'corrupt and oversized archives fail attachment export within bounds',
    () async {
      final logger = createLogger();
      await logger.initialize();
      final file = File(
        '${directory.path}/session-1800000000000-000000.log.gz',
      );
      file.writeAsBytesSync([1, 2, 3]);
      await expectLater(
        logger.attachmentBytes('session-1800000000000-000000.log.gz'),
        throwsA(isA<FormatException>()),
      );
      file.writeAsBytesSync(gzip.encode(List.filled(1024 * 1024 + 1, 65)));
      await expectLater(
        logger.attachmentBytes('session-1800000000000-000000.log.gz'),
        throwsA(isA<FormatException>()),
      );
      expect(await logger.attachmentBytes('../not-a-log.gz'), isNull);
    },
  );

  test('a full 1 MiB segment plus gzip framing can be attached', () async {
    final logger = createLogger();
    await logger.initialize();
    const id = 'session-1800000000000-000000.log.gz';
    final file = File('${directory.path}/$id');
    final archive = GZipCodec(level: 0).encode(List.filled(1024 * 1024, 65));
    expect(archive.length, greaterThan(1024 * 1024));
    await file.writeAsBytes(archive);
    expect(await logger.attachmentBytes(id), archive);
  });

  test('rapid tap counter enables exactly on the tenth tap', () {
    final counter = DebugTapCounter();
    final start = DateTime(2026, 1, 1);
    for (var index = 0; index < 9; index++) {
      expect(
        counter.registerTap(start.add(Duration(milliseconds: index * 100))),
        isFalse,
      );
    }
    expect(
      counter.registerTap(start.add(const Duration(milliseconds: 900))),
      isTrue,
    );
    expect(counter.registerTap(start.add(const Duration(seconds: 5))), isFalse);
  });
}
