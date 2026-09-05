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

    test(
      'keeps cached command details for refreshed turns after revision changes',
      () {
        const cachedCommand = TimelineEntry(
          id: 'command-1',
          kind: TimelineKind.command,
          command: 'flutter test',
          status: 'completed',
          output: 'All tests passed',
          turnId: 'turn-2',
        );
        const refreshedAgentMessage = TimelineEntry(
          id: 'agent-1',
          kind: TimelineKind.agentMessage,
          text: '测试完成',
          turnId: 'turn-2',
        );

        final result = reconcileResumedTimeline(
          cachedTimeline: const <TimelineEntry>[
            TimelineEntry(
              id: 'old-turn',
              kind: TimelineKind.agentMessage,
              text: '旧回合',
              turnId: 'turn-1',
            ),
            cachedCommand,
          ],
          cachedNextCursor: 'old-cursor',
          refreshedTimeline: const <TimelineEntry>[refreshedAgentMessage],
          refreshedNextCursor: null,
          refreshedTurnIds: const <String>['turn-2'],
          cachedThreadUpdatedAt: 10,
          refreshedThreadUpdatedAt: 11,
        );

        expect(result.timeline, <TimelineEntry>[
          cachedCommand,
          refreshedAgentMessage,
        ]);
        expect(result.nextCursor, isNull);
      },
    );

    test('deduplicates resumed turn rows without reordering its command', () {
      const optimisticUser = TimelineEntry(
        id: 'local-user-123',
        kind: TimelineKind.userMessage,
        text: '再运行一个20秒的命令',
        turnId: 'turn-2',
      );
      const command = TimelineEntry(
        id: 'command-1',
        kind: TimelineKind.command,
        command: 'sleep 20',
        status: 'inProgress',
        turnId: 'turn-2',
      );
      const serverUser = TimelineEntry(
        id: 'server-user-1',
        kind: TimelineKind.userMessage,
        text: '再运行一个20秒的命令',
        turnId: 'turn-2',
      );
      const agentMessage = TimelineEntry(
        id: 'live-agent-1',
        kind: TimelineKind.agentMessage,
        text: '开始运行 sleep 20',
        turnId: 'turn-2',
      );
      const serverAgentMessage = TimelineEntry(
        id: 'server-agent-1',
        kind: TimelineKind.agentMessage,
        text: '开始运行 sleep 20',
        turnId: 'turn-2',
      );
      const liveReasoning = TimelineEntry(
        id: 'live-reasoning-1',
        kind: TimelineKind.reasoning,
        reasoningSummary: <String>['正在等待命令完成'],
        turnId: 'turn-2',
      );
      const serverReasoning = TimelineEntry(
        id: 'server-reasoning-1',
        kind: TimelineKind.reasoning,
        reasoningSummary: <String>['正在等待命令完成'],
        turnId: 'turn-2',
      );

      final result = reconcileResumedTimeline(
        cachedTimeline: const <TimelineEntry>[
          optimisticUser,
          agentMessage,
          command,
          liveReasoning,
        ],
        cachedNextCursor: null,
        refreshedTimeline: const <TimelineEntry>[
          serverUser,
          serverAgentMessage,
          command,
          serverReasoning,
        ],
        refreshedNextCursor: null,
        refreshedTurnIds: const <String>['turn-2'],
        cachedThreadUpdatedAt: 10,
        refreshedThreadUpdatedAt: 11,
      );

      expect(result.timeline, const <TimelineEntry>[
        serverUser,
        serverAgentMessage,
        command,
        serverReasoning,
      ]);
      expect(
        result.timeline.where(
          (entry) => entry.kind == TimelineKind.userMessage,
        ),
        hasLength(1),
      );
    });

    test('does not collapse two real identical commands in one turn', () {
      const liveCommand = TimelineEntry(
        id: 'live-command',
        kind: TimelineKind.command,
        command: 'pwd',
        status: 'completed',
        turnId: 'turn-2',
      );
      const firstServerCommand = TimelineEntry(
        id: 'server-command-1',
        kind: TimelineKind.command,
        command: 'pwd',
        status: 'completed',
        turnId: 'turn-2',
      );
      const secondServerCommand = TimelineEntry(
        id: 'server-command-2',
        kind: TimelineKind.command,
        command: 'pwd',
        status: 'completed',
        turnId: 'turn-2',
      );

      final result = reconcileResumedTimeline(
        cachedTimeline: const <TimelineEntry>[liveCommand],
        cachedNextCursor: null,
        refreshedTimeline: const <TimelineEntry>[
          firstServerCommand,
          secondServerCommand,
        ],
        refreshedNextCursor: null,
        refreshedTurnIds: const <String>['turn-2'],
        cachedThreadUpdatedAt: 10,
        refreshedThreadUpdatedAt: 11,
      );

      expect(result.timeline, const <TimelineEntry>[
        firstServerCommand,
        secondServerCommand,
      ]);
    });

    test('collapses repeated formal user rows from a resumed snapshot', () {
      const first = TimelineEntry(
        id: 'server-user-1',
        kind: TimelineKind.userMessage,
        text: '再运行一个30秒的命令',
        turnId: 'turn-2',
      );
      const second = TimelineEntry(
        id: 'server-user-2',
        kind: TimelineKind.userMessage,
        text: '再运行一个30秒的命令',
        turnId: 'turn-2',
      );
      const third = TimelineEntry(
        id: 'server-user-3',
        kind: TimelineKind.userMessage,
        text: '再运行一个30秒的命令',
        turnId: 'turn-2',
      );

      final result = reconcileResumedTimeline(
        cachedTimeline: const <TimelineEntry>[],
        cachedNextCursor: null,
        refreshedTimeline: const <TimelineEntry>[first, second, third],
        refreshedNextCursor: null,
        refreshedTurnIds: const <String>['turn-2'],
      );

      expect(result.timeline, hasLength(1));
      expect(result.timeline.single.id, 'server-user-3');
      expect(result.timeline.single.text, first.text);
    });

    test('merges an image-only optimistic row after its server rename', () {
      const remotePath =
          '/root/.codex-mobile/uploads/'
          '9a94e845-fc5e-4ab1-9fcc-84fd6354-scaled_1000153437.jpg';
      const optimistic = TimelineEntry(
        id: 'local-user-123',
        kind: TimelineKind.userMessage,
        attachments: <MessageAttachment>[
          MessageAttachment(
            name: 'scaled_1000153437.jpg',
            remotePath: remotePath,
            mimeType: 'image/jpeg',
          ),
        ],
        turnId: 'turn-2',
      );
      const server = TimelineEntry(
        id: 'server-user-1',
        kind: TimelineKind.userMessage,
        attachments: <MessageAttachment>[
          MessageAttachment(
            name: '9a94e845-fc5e-4ab1-9fcc-84fd6354-scaled_1000153437.jpg',
            remotePath: remotePath,
            mimeType: 'image/*',
          ),
        ],
        turnId: 'turn-2',
      );

      final result = reconcileResumedTimeline(
        cachedTimeline: const <TimelineEntry>[optimistic],
        cachedNextCursor: null,
        refreshedTimeline: const <TimelineEntry>[server],
        refreshedNextCursor: null,
        refreshedTurnIds: const <String>['turn-2'],
        cachedThreadUpdatedAt: 10,
        refreshedThreadUpdatedAt: 11,
      );

      expect(result.timeline, const <TimelineEntry>[server]);
    });

    test('collapses renamed image-only rows inside one resumed snapshot', () {
      const remotePath = '/tmp/9a94e845-scaled_1000153437.jpg';
      const originalName = TimelineEntry(
        id: 'server-user-1',
        kind: TimelineKind.userMessage,
        attachments: <MessageAttachment>[
          MessageAttachment(
            name: 'scaled_1000153437.jpg',
            remotePath: remotePath,
            mimeType: 'image/jpeg',
          ),
        ],
        turnId: 'turn-2',
      );
      const generatedName = TimelineEntry(
        id: 'server-user-2',
        kind: TimelineKind.userMessage,
        attachments: <MessageAttachment>[
          MessageAttachment(
            name: '9a94e845-scaled_1000153437.jpg',
            remotePath: remotePath,
            mimeType: 'image/*',
          ),
        ],
        turnId: 'turn-2',
      );

      final result = reconcileResumedTimeline(
        cachedTimeline: const <TimelineEntry>[],
        cachedNextCursor: null,
        refreshedTimeline: const <TimelineEntry>[originalName, generatedName],
        refreshedNextCursor: null,
        refreshedTurnIds: const <String>['turn-2'],
      );

      expect(result.timeline, const <TimelineEntry>[generatedName]);
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
