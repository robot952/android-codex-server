import 'package:codex_remote/src/app/app_controller.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('reconcileResumedTimeline', () {
    test(
      'retains cached prefix and older cursor for same-revision overlap',
      () {
        TimelineEntry entry(String turnId) => TimelineEntry(
          id: turnId,
          kind: TimelineKind.agentMessage,
          text: turnId,
          turnId: turnId,
        );

        final cached = <TimelineEntry>[
          for (var index = 33; index <= 40; index += 1) entry('turn-$index'),
        ];
        final refreshed = <TimelineEntry>[
          for (var index = 37; index <= 40; index += 1) entry('turn-$index'),
        ];

        final result = reconcileResumedTimeline(
          cachedTimeline: cached,
          cachedNextCursor: 'after-turn-33',
          refreshedTimeline: refreshed,
          refreshedNextCursor: 'after-turn-37',
          cachedThreadUpdatedAt: 10,
          refreshedThreadUpdatedAt: 10,
        );

        expect(result.timeline, cached);
        expect(result.nextCursor, 'after-turn-33');
      },
    );

    test('drops cached pages when the thread revision changes', () {
      TimelineEntry entry(String turnId) => TimelineEntry(
        id: turnId,
        kind: TimelineKind.agentMessage,
        text: turnId,
        turnId: turnId,
      );

      final cached = <TimelineEntry>[entry('turn-1'), entry('turn-2')];
      final refreshed = <TimelineEntry>[entry('turn-2'), entry('turn-3')];

      final result = reconcileResumedTimeline(
        cachedTimeline: cached,
        cachedNextCursor: 'old-cursor',
        refreshedTimeline: refreshed,
        refreshedNextCursor: 'fresh-cursor',
        cachedThreadUpdatedAt: 10,
        refreshedThreadUpdatedAt: 11,
      );

      expect(result.timeline, refreshed);
      expect(result.nextCursor, 'fresh-cursor');
    });

    test('summary replaces only matching timeline identities', () {
      final cached = <TimelineEntry>[
        const TimelineEntry(
          id: 'user',
          kind: TimelineKind.userMessage,
          text: 'question',
          turnId: 'turn-1',
        ),
        const TimelineEntry(
          id: 'command',
          kind: TimelineKind.command,
          command: 'make test',
          turnId: 'turn-1',
        ),
        const TimelineEntry(
          id: 'agent',
          kind: TimelineKind.agentMessage,
          text: 'answer',
          turnId: 'turn-1',
        ),
      ];
      final summary = <TimelineEntry>[
        cached.first,
        cached.last.copyWith(text: 'updated answer'),
      ];

      final result = reconcileResumedTimeline(
        cachedTimeline: cached,
        cachedNextCursor: 'older',
        refreshedTimeline: summary,
        refreshedNextCursor: null,
        refreshedTurnIds: const <String>['turn-1'],
        cachedThreadUpdatedAt: 10,
        refreshedThreadUpdatedAt: 10,
        refreshedItemsView: 'summary',
      );

      expect(result.timeline.map((entry) => entry.text), <String>[
        'question',
        '',
        'updated answer',
      ]);
      expect(result.timeline[1].command, 'make test');
      expect(result.nextCursor, 'older');
    });

    test('notLoaded keeps cached details and cursor', () {
      final cached = <TimelineEntry>[
        const TimelineEntry(
          id: 'command',
          kind: TimelineKind.command,
          command: 'make test',
          turnId: 'turn-1',
        ),
      ];

      final result = reconcileResumedTimeline(
        cachedTimeline: cached,
        cachedNextCursor: 'older',
        refreshedTimeline: const <TimelineEntry>[],
        refreshedNextCursor: null,
        refreshedTurnIds: const <String>['turn-1'],
        cachedThreadUpdatedAt: 10,
        refreshedThreadUpdatedAt: 10,
        refreshedItemsView: 'notLoaded',
      );

      expect(result.timeline, cached);
      expect(result.nextCursor, 'older');
    });

    test(
      'does not merge entries with the same id but different turn or kind',
      () {
        final cached = <TimelineEntry>[
          const TimelineEntry(
            id: 'same-id',
            kind: TimelineKind.agentMessage,
            text: 'old agent',
            turnId: 'turn-1',
          ),
          const TimelineEntry(
            id: 'same-id',
            kind: TimelineKind.command,
            command: 'old command',
            turnId: 'turn-1',
          ),
          const TimelineEntry(
            id: 'anchor',
            kind: TimelineKind.agentMessage,
            text: 'old anchor',
            turnId: 'turn-2',
          ),
        ];
        final summary = <TimelineEntry>[
          const TimelineEntry(
            id: 'same-id',
            kind: TimelineKind.agentMessage,
            text: 'new agent',
            turnId: 'turn-2',
          ),
          const TimelineEntry(
            id: 'same-id',
            kind: TimelineKind.plan,
            text: 'new plan',
            turnId: 'turn-1',
          ),
          const TimelineEntry(
            id: 'anchor',
            kind: TimelineKind.agentMessage,
            text: 'new anchor',
            turnId: 'turn-2',
          ),
        ];

        final result = reconcileResumedTimeline(
          cachedTimeline: cached,
          cachedNextCursor: 'older',
          refreshedTimeline: summary,
          refreshedNextCursor: null,
          refreshedTurnIds: const <String>['turn-2'],
          cachedThreadUpdatedAt: 10,
          refreshedThreadUpdatedAt: 10,
          refreshedItemsView: 'summary',
        );

        expect(result.timeline.map((entry) => entry.text), <String>[
          'old agent',
          '',
          'new anchor',
          'new agent',
          'new plan',
        ]);
        expect(result.timeline[1].command, 'old command');
        expect(result.nextCursor, 'older');
      },
    );
  });
}
