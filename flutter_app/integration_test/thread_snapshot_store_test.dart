import 'package:codex_remote/src/agent/thread_session_cache.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/persistence/thread_snapshot_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Android compressed cache round trips through secure storage', (
    tester,
  ) async {
    final scope =
        'cache-device-fixture-${DateTime.now().microsecondsSinceEpoch}';
    final store = EncryptedThreadSnapshotStore();
    try {
      final snapshot = ThreadSessionSnapshot(
        thread: const AgentThread(id: 'fixture', title: 'Cache fixture'),
        timeline: List.generate(
          140,
          (i) => TimelineEntry(
            id: 'message-$i',
            turnId: 'turn-$i',
            kind: TimelineKind.agentMessage,
            text: 'Test fixture $i\n${'Synthetic history 历史正文\n' * 100}',
          ),
        ),
        savedAtEpochMillis: DateTime.now().millisecondsSinceEpoch,
        nextTurnsCursor: 'older-fixture',
      );
      final save = Stopwatch()..start();
      await store.write(scope, snapshot);
      final saveMs = save.elapsedMilliseconds;
      final read = Stopwatch()..start();
      final restored = await EncryptedThreadSnapshotStore().read(
        scope,
        'fixture',
      );
      final readMs = read.elapsedMilliseconds;
      expect(restored?.timeline, snapshot.timeline);
      expect(restored?.nextTurnsCursor, snapshot.nextTurnsCursor);
      expect(restored?.thread.isExternallyOwned, isFalse);
      debugPrint(
        'CACHE_DEVICE_FIXTURE entries=140 saveMs=$saveMs readMs=$readMs',
      );
    } finally {
      await store.removeScope(scope);
    }
    expect(tester.takeException(), isNull);
  });
}
