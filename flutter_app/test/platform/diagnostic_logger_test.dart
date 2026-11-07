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
  }) {
    final settings = MemoryDiagnosticSettingsStore(enabled: enabled);
    return DiagnosticLogger(
      directoryProvider: () async => directory,
      exportDirectoryProvider: () async => exportDirectory,
      settingsProvider: () async => settings,
      shareHandler: shareHandler,
      clock: clock,
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

  test('current snapshot reads only the active 100 KiB segment', () async {
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
      for (var index = 0; index < 200; index++) {
        logger.info('Test', 'entry-$index ${'log payload ' * 325}');
      }
      await logger.share();

      final snapshot = await logger.snapshot();
      expect(snapshot.entries, hasLength(5));
      expect(snapshot.entries.first.isActive, isTrue);
      expect(snapshot.bytes, lessThanOrEqualTo(500 * 1024));
      expect(
        snapshot.entries.every((entry) => entry.sizeBytes <= 100 * 1024),
        isTrue,
      );
      expect(sharedFile, isNotNull);
      expect(await sharedFile!.exists(), isTrue);
      expect(
        await sharedFile!.readAsString(),
        contains('Agent diagnostic log'),
      );
      expect(await sharedFile!.readAsString(), isNot(contains('entry-0 ')));
      expect(snapshot.preview, contains('entry-199 '));
    },
  );

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
          if (enabled) 'session-1900000000000-000000.log',
          for (var index = 104; index >= (enabled ? 101 : 100); index--)
            'session-${1_800_000_000_000 + index}-000000.log',
        ];
        expect(snapshot.entries, hasLength(5));
        expect(snapshot.entries.map((entry) => entry.id), expectedIds);
        expect(snapshot.bytes, lessThanOrEqualTo(500 * 1024));
        expect(
          directory.listSync().whereType<File>().where(
            (file) => file.path.endsWith('.log'),
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
