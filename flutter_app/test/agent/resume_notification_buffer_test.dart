import 'package:codex_remote/src/agent/codex_protocol.dart';
import 'package:codex_remote/src/agent/resume_notification_buffer.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ResumeNotificationBuffer', () {
    test('skips exact agent and command suffixes already in snapshot', () {
      final buffer = ResumeNotificationBuffer(threadId: 'thread', generation: 7)
        ..offer(_delta('item/agentMessage/delta', 'turn', 'agent', 'A'))
        ..offer(
          _delta('item/commandExecution/outputDelta', 'turn', 'command', 'X'),
        )
        ..offer(_delta('item/agentMessage/delta', 'turn', 'agent', 'B'))
        ..offer(
          _delta('item/commandExecution/outputDelta', 'turn', 'command', 'Y'),
        );

      final replay = buffer.drain(const <TimelineEntry>[
        TimelineEntry(
          id: 'agent',
          kind: TimelineKind.agentMessage,
          text: 'preAB',
          turnId: 'turn',
        ),
        TimelineEntry(
          id: 'command',
          kind: TimelineKind.command,
          output: 'preXY',
          turnId: 'turn',
        ),
      ]);

      expect(replay, isEmpty);
    });

    test('keeps plan authoritative and skips reasoning suffixes', () {
      final buffer = ResumeNotificationBuffer(threadId: 'thread', generation: 7)
        ..offer(_delta('item/plan/delta', 'turn', 'plan', 'P'))
        ..offer(_delta('item/plan/delta', 'turn', 'plan', 'Q'))
        ..offer(
          _indexedDelta(
            'item/reasoning/summaryTextDelta',
            'turn',
            'reason',
            'summaryIndex',
            0,
            'A',
          ),
        )
        ..offer(
          _indexedDelta(
            'item/reasoning/summaryTextDelta',
            'turn',
            'reason',
            'summaryIndex',
            0,
            'B',
          ),
        )
        ..offer(
          _indexedDelta(
            'item/reasoning/textDelta',
            'turn',
            'reason',
            'contentIndex',
            0,
            'X',
          ),
        )
        ..offer(
          _indexedDelta(
            'item/reasoning/textDelta',
            'turn',
            'reason',
            'contentIndex',
            0,
            'Y',
          ),
        );

      final replay = buffer.drain(const <TimelineEntry>[
        TimelineEntry(
          id: 'plan',
          kind: TimelineKind.plan,
          text: 'server formatted plan',
          turnId: 'turn',
        ),
        TimelineEntry(
          id: 'reason',
          kind: TimelineKind.reasoning,
          text: 'preAB',
          turnId: 'turn',
          reasoningSummary: <String>['preAB'],
          reasoningContent: <String>['rawXY'],
        ),
      ]);

      expect(replay, isEmpty);
    });

    test('keeps turn and kind identities separate', () {
      final buffer = ResumeNotificationBuffer(threadId: 'thread', generation: 7)
        ..offer(
          _delta('item/agentMessage/delta', 'turn-1', 'same', 'agent-one'),
        )
        ..offer(
          _delta(
            'item/commandExecution/outputDelta',
            'turn-1',
            'same',
            'command',
          ),
        )
        ..offer(
          _delta('item/agentMessage/delta', 'turn-2', 'same', 'agent-two'),
        );

      final replay = buffer.drain(const <TimelineEntry>[
        TimelineEntry(
          id: 'same',
          kind: TimelineKind.agentMessage,
          text: 'base',
          turnId: 'turn-1',
        ),
        TimelineEntry(
          id: 'same',
          kind: TimelineKind.command,
          output: 'base',
          turnId: 'turn-1',
        ),
        TimelineEntry(
          id: 'same',
          kind: TimelineKind.agentMessage,
          text: 'base',
          turnId: 'turn-2',
        ),
      ]);

      expect(replay.map((event) => event.params['delta']), <String>[
        'agent-one',
        'command',
        'agent-two',
      ]);
    });

    test('completed agent payload wins over buffered agent deltas', () {
      final buffer = ResumeNotificationBuffer(threadId: 'thread', generation: 7)
        ..offer(_delta('item/agentMessage/delta', 'turn', 'agent', 'duplicate'))
        ..offer(
          _notification('item/completed', <String, Object?>{
            'threadId': 'thread',
            'turnId': 'turn',
            'item': <String, Object?>{
              'id': 'agent',
              'type': 'agentMessage',
              'text': 'final',
            },
          }),
        );

      final replay = buffer.drain(const <TimelineEntry>[
        TimelineEntry(
          id: 'agent',
          kind: TimelineKind.agentMessage,
          text: 'snapshot',
          turnId: 'turn',
        ),
      ]);

      expect(replay.map((event) => event.method), <String>['item/completed']);
    });

    test('only intercepts matching thread and generation', () {
      final buffer = ResumeNotificationBuffer(
        threadId: 'target',
        generation: 7,
      );

      expect(
        buffer.offer(
          _notification('turn/started', <String, Object?>{'threadId': 'other'}),
        ),
        isFalse,
      );
      expect(
        buffer.offer(
          _notification('turn/started', <String, Object?>{
            'threadId': 'target',
          }, generation: 8),
        ),
        isFalse,
      );
      expect(
        buffer.offer(
          _notification('turn/started', <String, Object?>{
            'threadId': 'target',
          }),
        ),
        isTrue,
      );
    });

    test('bounded buffer preserves terminal payload after excess deltas', () {
      final buffer =
          ResumeNotificationBuffer(
              threadId: 'thread',
              generation: 7,
              maxEvents: 1,
              maxWeightChars: 256,
            )
            ..offer(
              _delta('item/agentMessage/delta', 'turn', 'agent', 'partial'),
            )
            ..offer(
              _delta('item/agentMessage/delta', 'turn', 'agent', 'dropped'),
            )
            ..offer(
              _notification('item/completed', <String, Object?>{
                'threadId': 'thread',
                'turnId': 'turn',
                'item': <String, Object?>{
                  'id': 'agent',
                  'type': 'agentMessage',
                  'text': 'final',
                },
              }),
            );

      final replay = buffer.drain(const <TimelineEntry>[]);

      expect(buffer.overflowed, isTrue);
      expect(replay.map((event) => event.method), <String>['item/completed']);
    });

    test('character budget also preserves a terminal payload', () {
      final buffer =
          ResumeNotificationBuffer(
              threadId: 'thread',
              generation: 7,
              maxEvents: 10,
              maxWeightChars: 80,
            )
            ..offer(
              _delta('item/agentMessage/delta', 'turn', 'agent', 'partial'),
            )
            ..offer(
              _notification('item/completed', <String, Object?>{
                'threadId': 'thread',
                'turnId': 'turn',
                'item': <String, Object?>{
                  'id': 'agent',
                  'type': 'agentMessage',
                  'text': 'final',
                },
              }),
            );

      final replay = buffer.drain(const <TimelineEntry>[]);

      expect(buffer.overflowed, isTrue);
      expect(replay.map((event) => event.method), <String>['item/completed']);
    });

    test('bounded buffer never exceeds event limit for full payloads', () {
      final buffer = ResumeNotificationBuffer(
        threadId: 'thread',
        generation: 7,
        maxEvents: 2,
        maxWeightChars: 4096,
      );
      for (var index = 0; index < 20; index += 1) {
        buffer.offer(
          _notification('turn/started', <String, Object?>{
            'threadId': 'thread',
            'turn': <String, Object?>{'id': '$index'},
          }),
        );
      }

      final replay = buffer.drain(const <TimelineEntry>[]);

      expect(buffer.overflowed, isTrue);
      expect(replay, hasLength(2));
    });

    test('adjacent deltas are coalesced before replay', () {
      final buffer = ResumeNotificationBuffer(
        threadId: 'thread',
        generation: 7,
      );
      for (var index = 0; index < 1000; index += 1) {
        buffer.offer(_delta('item/agentMessage/delta', 'turn', 'agent', 'x'));
      }

      final replay = buffer.drain(const <TimelineEntry>[]);

      expect(replay, hasLength(1));
      expect((replay.single.params['delta']! as String).length, 1000);
    });

    test('interleaved streams retain wire order', () {
      final buffer = ResumeNotificationBuffer(threadId: 'thread', generation: 7)
        ..offer(_delta('item/agentMessage/delta', 'turn', 'agent', 'A1'))
        ..offer(
          _delta('item/commandExecution/outputDelta', 'turn', 'command', 'C1'),
        )
        ..offer(_delta('item/agentMessage/delta', 'turn', 'agent', 'A2'));

      final replay = buffer.drain(const <TimelineEntry>[]);

      expect(replay.map((event) => event.method), <String>[
        'item/agentMessage/delta',
        'item/commandExecution/outputDelta',
        'item/agentMessage/delta',
      ]);
      expect(replay.map((event) => event.params['delta']), <String>[
        'A1',
        'C1',
        'A2',
      ]);
    });

    test('does not guess a fuzzy suffix overlap', () {
      final buffer = ResumeNotificationBuffer(threadId: 'thread', generation: 7)
        ..offer(_delta('item/agentMessage/delta', 'turn', 'agent', 'ABC'));

      final replay = buffer.drain(const <TimelineEntry>[
        TimelineEntry(
          id: 'agent',
          kind: TimelineKind.agentMessage,
          text: 'snapshot-BC',
          turnId: 'turn',
        ),
      ]);

      expect(replay, hasLength(1));
      expect(replay.single.params['delta'], 'ABC');
    });

    test('does not discard a plan delta after snapshot response', () {
      final buffer = ResumeNotificationBuffer(threadId: 'thread', generation: 7)
        ..offer(
          _delta('item/plan/delta', 'turn', 'plan', 'before', sequence: 9),
        )
        ..offer(
          _delta('item/plan/delta', 'turn', 'plan', 'after', sequence: 11),
        );

      final replay = buffer.drain(const <TimelineEntry>[
        TimelineEntry(
          id: 'plan',
          kind: TimelineKind.plan,
          text: 'authoritative snapshot',
          turnId: 'turn',
        ),
      ], snapshotSequence: 10);

      expect(replay, hasLength(1));
      expect(replay.single.params['delta'], 'after');
    });

    test('requires positive limits', () {
      expect(
        () => ResumeNotificationBuffer(
          threadId: 'thread',
          generation: 7,
          maxEvents: 0,
        ),
        throwsArgumentError,
      );
      expect(
        () => ResumeNotificationBuffer(
          threadId: 'thread',
          generation: 7,
          maxWeightChars: 0,
        ),
        throwsArgumentError,
      );
    });
  });
}

CodexRpcNotification _delta(
  String method,
  String turnId,
  String itemId,
  String delta, {
  int sequence = 0,
}) => _notification(method, <String, Object?>{
  'threadId': 'thread',
  'turnId': turnId,
  'itemId': itemId,
  'delta': delta,
}, sequence: sequence);

CodexRpcNotification _indexedDelta(
  String method,
  String turnId,
  String itemId,
  String indexName,
  int index,
  String delta,
) => _notification(method, <String, Object?>{
  'threadId': 'thread',
  'turnId': turnId,
  'itemId': itemId,
  indexName: index,
  'delta': delta,
});

CodexRpcNotification _notification(
  String method,
  Map<String, Object?> params, {
  int generation = 7,
  int sequence = 0,
}) => CodexRpcNotification(
  generation: generation,
  sequence: sequence,
  raw: <String, Object?>{'method': method, 'params': params},
  method: method,
  params: params,
  isKnown: true,
);
