import 'dart:async';
import 'dart:io';

import 'package:codex_remote/src/platform/diagnostic_logger.dart';
import 'package:codex_remote/src/platform/diagnostic_timing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'records a correlated start and finish without waiting for completion',
    () async {
      final lines = <String>[];
      final pending = Completer<String>();
      final timing = DiagnosticTiming.start(
        stage: 'thread/list',
        log: lines.add,
        profileId: 'server-a',
        agent: 'codex',
        threadId: 'thread-a',
        generation: 2,
      );
      final future = timing.run(() => pending.future);
      expect(lines, hasLength(1));
      expect(lines.single, contains('status=started elapsedMs=0'));
      pending.complete('unchanged result');
      expect(await future, 'unchanged result');
      expect(lines, hasLength(2));
      final identity = lines.first.split(' status=').first;
      expect(lines.last, startsWith(identity));
      expect(lines.last, contains('status=success elapsedMs='));
      expect(
        lines.last,
        contains('profile=server-a agent=codex thread=thread-a generation=2'),
      );
      expect(
        int.parse(lines.last.split('elapsedMs=').last),
        greaterThanOrEqualTo(0),
      );
    },
  );

  test(
    'failure and timeout preserve the error without logging its contents',
    () async {
      for (final error in <Object>[
        StateError('password=private-response'),
        TimeoutException('https://private.example/secret'),
      ]) {
        final lines = <String>[];
        final timing = DiagnosticTiming.start(
          stage: 'initialize',
          log: lines.add,
        );
        await expectLater(
          timing.run<Object>(() => throw error),
          throwsA(same(error)),
        );
        expect(
          lines.last,
          contains(
            'status=${error is TimeoutException ? 'timeout' : 'failed'}',
          ),
        );
        expect(lines.join(), isNot(contains('private')));
        expect(lines.join(), isNot(contains('secret')));
        expect(lines, hasLength(2));
      }
    },
  );

  test(
    'concurrent spans have separate identities and a single terminal record',
    () {
      final lines = <String>[];
      final a = DiagnosticTiming.start(
        stage: 'resume',
        log: lines.add,
        profileId: 'a',
      );
      final b = DiagnosticTiming.start(
        stage: 'resume',
        log: lines.add,
        profileId: 'b',
      );
      expect(lines[0].split(' ')[1], isNot(lines[1].split(' ')[1]));
      b.finish(count: 5, hasMore: true, cacheHit: false);
      a.finish(status: TimingStatus.stale);
      a.finish();
      b.fail(StateError('ignored'));
      expect(lines, hasLength(4));
      expect(lines[2], contains('count=5 hasMore=true cacheHit=false'));
      expect(lines.last, contains('profile=a status=stale'));
    },
  );

  test(
    'unsafe fields and throwing logging sinks do not affect the operation',
    () async {
      final lines = <String>[];
      DiagnosticTiming.start(
        stage: 'read\npassword=secret',
        log: lines.add,
        profileId: 'https://example.invalid/token',
        threadId: '/private/path',
      ).finish(status: TimingStatus.skipped);
      expect(lines.join(), isNot(contains('secret')));
      expect(lines.join(), isNot(contains('example.invalid')));
      expect(lines.join(), isNot(contains('/private/path')));
      final timing = DiagnosticTiming.start(
        stage: 'connect',
        log: (_) => throw StateError('logger'),
      );
      expect(await timing.run(() async => 7), 7);
    },
  );

  test(
    'Debug off remains silent and enabled timing uses existing log storage',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'timing-log-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final logger = DiagnosticLogger(
        directoryProvider: () async => directory,
        settingsProvider: () async => MemoryDiagnosticSettingsStore(),
      );
      await logger.initialize();
      void log(String line) => logger.info('Performance', line);
      DiagnosticTiming.start(stage: 'disabled', log: log).finish();
      expect((await logger.snapshot()).preview, isEmpty);
      await logger.setEnabled(true);
      DiagnosticTiming.start(stage: 'enabled', log: log).finish();
      final preview = (await logger.snapshot()).preview;
      expect(preview, contains('Performance timing'));
      expect(preview, contains('stage=enabled'));
      expect(preview, isNot(contains('stage=disabled')));
    },
  );
}
