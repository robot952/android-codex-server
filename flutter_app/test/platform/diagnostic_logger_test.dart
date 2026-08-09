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
  }) {
    final settings = MemoryDiagnosticSettingsStore(enabled: enabled);
    return DiagnosticLogger(
      directoryProvider: () async => directory,
      exportDirectoryProvider: () async => exportDirectory,
      settingsProvider: () async => settings,
      shareHandler: shareHandler,
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

  test(
    'rotates segments and exports through the injected share handler',
    () async {
      File? sharedFile;
      final logger = createLogger(
        enabled: true,
        shareHandler: (file) async {
          sharedFile = file;
        },
      );
      await logger.initialize();
      for (var index = 0; index < 2_000; index++) {
        logger.info('Test', 'entry-$index ${'x' * 100}');
      }
      await logger.share();

      final snapshot = await logger.snapshot();
      expect(snapshot.entries, isNotEmpty);
      expect(
        snapshot.entries.length,
        lessThanOrEqualTo(DiagnosticLogger.maxSegments),
      );
      expect(sharedFile, isNotNull);
      expect(await sharedFile!.exists(), isTrue);
      expect(
        await sharedFile!.readAsString(),
        contains('Agent diagnostic log'),
      );
    },
  );

  test('retains at most one hundred newest log files', () async {
    for (var index = 0; index < 105; index++) {
      final started = (1_800_000_000_000 + index).toString();
      await File(
        '${directory.path}/session-$started-000000.log',
      ).writeAsString('2026-01-01T00:00:00Z INFO Test entry-$index\n');
    }
    final logger = createLogger(enabled: true);
    await logger.initialize();

    final snapshot = await logger.snapshot();
    expect(snapshot.entries, hasLength(DiagnosticLogger.maxSegments));
    expect(snapshot.bytes, lessThanOrEqualTo(DiagnosticLogger.maxTotalBytes));
    expect(snapshot.preview, isNot(contains('entry-0\n')));
    expect(snapshot.preview, contains('entry-104'));
  });

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
    final exportText = await exported.readAsString();
    expect(exportText, contains('second-session'));
    expect(exportText, isNot(contains('first-session')));
    expect(exportText, isNot(contains('top-secret')));

    final attachment = await logger.attachmentText(newest.id, maxBytes: 256);
    expect(attachment, contains('[REDACTED]'));
    expect(attachment, isNot(contains('top-secret')));
    expect(attachment!.length, lessThanOrEqualTo(256));
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
