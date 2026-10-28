import 'package:codex_remote/src/agent/codex_protocol.dart';
import 'package:codex_remote/src/app/app_controller.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('reconcileResumedTimeline', () {
    test('restored user stays before cached work across repeated reopen', () {
      const user = TimelineEntry(
        id: 'user-before-work',
        kind: TimelineKind.userMessage,
        text: '提供安装包',
        turnId: 'turn-1',
      );
      const command = TimelineEntry(
        id: 'command',
        kind: TimelineKind.command,
        command: 'flutter test',
        turnId: 'turn-1',
      );
      const compact = TimelineEntry(
        id: 'compact',
        kind: TimelineKind.notice,
        status: 'completed',
        turnId: 'turn-1',
      );
      const fresh = [user, command, compact];
      var cached = <TimelineEntry>[command, compact];
      for (var reopen = 0; reopen < 3; reopen++) {
        final result = reconcileResumedTimeline(
          cachedTimeline: cached,
          cachedNextCursor: 'older',
          refreshedTimeline: fresh,
          refreshedNextCursor: 'older',
          cachedThreadUpdatedAt: 10,
          refreshedThreadUpdatedAt: 11,
        );
        expect(result.timeline, fresh);
        cached = result.timeline;
      }
    });

    test('repairs an already misplaced cached user using server order', () {
      const user = TimelineEntry(
        id: 'user',
        kind: TimelineKind.userMessage,
        text: '继续',
        turnId: 'turn-1',
      );
      const answer = TimelineEntry(
        id: 'answer',
        kind: TimelineKind.agentMessage,
        text: '处理中',
        turnId: 'turn-1',
      );
      final result = reconcileResumedTimeline(
        cachedTimeline: const [answer, user],
        cachedNextCursor: null,
        refreshedTimeline: const [user, answer],
        refreshedNextCursor: null,
      );
      expect(result.timeline, const [user, answer]);
    });

    test('keeps unmatched refreshed items between authoritative anchors', () {
      TimelineEntry item(
        String id, {
        TimelineKind kind = TimelineKind.agentMessage,
        String turn = 'turn-1',
      }) => TimelineEntry(id: id, kind: kind, text: id, turnId: turn);
      final user = item('user', kind: TimelineKind.userMessage);
      final answer = item('answer');
      final middle = item('middle', kind: TimelineKind.reasoning);
      final nextUser = user.copyWith(id: 'user-2', turnId: 'turn-2');
      final fresh = [user, middle, answer, nextUser];
      final result = reconcileResumedTimeline(
        cachedTimeline: [user, answer],
        cachedNextCursor: null,
        refreshedTimeline: fresh,
        refreshedNextCursor: null,
      );
      expect(result.timeline, fresh);
    });

    test(
      'fresh history corrects an old false running compaction without duplication',
      () {
        final fresh = CodexPayloadParser.parseTimeline({
          'turns': [
            {
              'id': 'turn-1',
              'status': 'inProgress',
              'items': [
                {'id': 'compact-1', 'type': 'contextCompaction'},
              ],
            },
          ],
        });
        final result = reconcileResumedTimeline(
          cachedTimeline: [
            fresh.single.copyWith(status: 'inProgress', text: '正在压缩上下文'),
          ],
          cachedNextCursor: null,
          refreshedTimeline: fresh,
          refreshedNextCursor: null,
          cachedThreadUpdatedAt: 10,
          refreshedThreadUpdatedAt: 10,
        );
        expect(result.timeline, fresh);
        expect(result.timeline.single.status, 'completed');
      },
    );

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

    test('keeps bounded cached history when the thread revision changes', () {
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

      expect(result.timeline, <TimelineEntry>[cached.first, ...refreshed]);
      expect(result.nextCursor, 'fresh-cursor');
    });

    test(
      'keeps a complete same-revision cache when the newest page is bounded',
      () {
        TimelineEntry entry(String turnId) => TimelineEntry(
          id: turnId,
          kind: TimelineKind.agentMessage,
          text: turnId,
          turnId: turnId,
        );
        final cached = <TimelineEntry>[entry('turn-1'), entry('turn-2')];

        final result = reconcileResumedTimeline(
          cachedTimeline: cached,
          cachedNextCursor: null,
          refreshedTimeline: <TimelineEntry>[cached.last],
          refreshedNextCursor: 'after-turn-2',
          refreshedTurnIds: const <String>['turn-2'],
          cachedThreadUpdatedAt: 10,
          refreshedThreadUpdatedAt: 10,
        );

        expect(result.timeline, cached);
        expect(result.nextCursor, isNull);
      },
    );

    test(
      'bounded rollback keeps the prefix but drops cached turns after it',
      () {
        TimelineEntry entry(String turnId) => TimelineEntry(
          id: turnId,
          kind: TimelineKind.agentMessage,
          text: turnId,
          turnId: turnId,
        );
        final cached = <TimelineEntry>[
          for (var index = 1; index <= 4; index += 1) entry('turn-$index'),
        ];
        final refreshed = cached[2].copyWith(text: 'remaining final answer');

        final result = reconcileResumedTimeline(
          cachedTimeline: cached,
          cachedNextCursor: 'old-before-turn-1',
          refreshedTimeline: <TimelineEntry>[refreshed],
          refreshedNextCursor: 'fresh-before-turn-3',
          refreshedTurnIds: const <String>['turn-3'],
          cachedThreadUpdatedAt: 10,
          refreshedThreadUpdatedAt: 11,
        );

        expect(result.timeline, <TimelineEntry>[
          cached[0],
          cached[1],
          refreshed,
        ]);
        expect(
          result.timeline.any((entry) => entry.turnId == 'turn-4'),
          isFalse,
        );
        expect(result.nextCursor, 'fresh-before-turn-3');
      },
    );

    test('changed full snapshot discards an absent cached prefix', () {
      const old = TimelineEntry(
        id: 'old-answer',
        kind: TimelineKind.agentMessage,
        text: 'removed old history',
        turnId: 'turn-1',
      );
      const retained = TimelineEntry(
        id: 'retained-answer',
        kind: TimelineKind.agentMessage,
        text: 'retained history',
        turnId: 'turn-2',
      );

      final result = reconcileResumedTimeline(
        cachedTimeline: const <TimelineEntry>[old, retained],
        cachedNextCursor: 'old-cursor',
        refreshedTimeline: const <TimelineEntry>[retained],
        refreshedNextCursor: null,
        refreshedTurnIds: const <String>['turn-2'],
        cachedThreadUpdatedAt: 10,
        refreshedThreadUpdatedAt: 11,
      );

      expect(result.timeline, const <TimelineEntry>[retained]);
      expect(result.nextCursor, isNull);
    });

    test(
      'does not append disjoint bounded pages without a verified overlap',
      () {
        const cached = <TimelineEntry>[
          TimelineEntry(
            id: 'cached-answer',
            kind: TimelineKind.agentMessage,
            text: 'unverified older history',
            turnId: 'turn-1',
          ),
        ];
        const refreshed = <TimelineEntry>[
          TimelineEntry(
            id: 'fresh-user',
            kind: TimelineKind.userMessage,
            text: 'latest question',
            turnId: 'turn-2',
          ),
        ];

        for (final refreshedRevision in <int>[10, 11]) {
          final result = reconcileResumedTimeline(
            cachedTimeline: cached,
            cachedNextCursor: 'old-cursor',
            refreshedTimeline: refreshed,
            refreshedNextCursor: 'fresh-cursor',
            refreshedTurnIds: const <String>['turn-2'],
            cachedThreadUpdatedAt: 10,
            refreshedThreadUpdatedAt: refreshedRevision,
          );

          expect(result.timeline, refreshed);
          expect(result.nextCursor, 'fresh-cursor');
        }
      },
    );

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

    test(
      'restores server order when a late cached command follows the final answer',
      () {
        const user = TimelineEntry(
          id: 'user-1',
          kind: TimelineKind.userMessage,
          text: '检查项目',
          turnId: 'turn-1',
        );
        const answer = TimelineEntry(
          id: 'answer-1',
          kind: TimelineKind.agentMessage,
          text: '检查完成',
          turnId: 'turn-1',
        );
        const command = TimelineEntry(
          id: 'command-1',
          kind: TimelineKind.command,
          command: 'git status',
          status: 'completed',
          turnId: 'turn-1',
        );

        final result = reconcileResumedTimeline(
          cachedTimeline: const <TimelineEntry>[user, answer, command],
          cachedNextCursor: null,
          refreshedTimeline: const <TimelineEntry>[user, command, answer],
          refreshedNextCursor: null,
          refreshedTurnIds: const <String>['turn-1'],
          cachedThreadUpdatedAt: 10,
          refreshedThreadUpdatedAt: 11,
        );

        expect(result.timeline, const <TimelineEntry>[user, command, answer]);
        expect(
          result.timeline.where((entry) => entry.id == 'command-1'),
          hasLength(1),
        );
      },
    );

    test('does not let moved commands hide a later refreshed answer', () {
      const first = TimelineEntry(
        id: 'answer-1',
        kind: TimelineKind.agentMessage,
        text: '开始',
        turnId: 'turn-1',
      );
      const firstCommand = TimelineEntry(
        id: 'command-1',
        kind: TimelineKind.command,
        command: 'git status',
        status: 'completed',
        turnId: 'turn-1',
      );
      const secondCommand = TimelineEntry(
        id: 'command-2',
        kind: TimelineKind.command,
        command: 'git diff',
        status: 'completed',
        turnId: 'turn-1',
      );
      const finalAnswer = TimelineEntry(
        id: 'answer-2',
        kind: TimelineKind.agentMessage,
        text: '完成',
        turnId: 'turn-1',
      );

      final result = reconcileResumedTimeline(
        cachedTimeline: const <TimelineEntry>[
          first,
          firstCommand,
          secondCommand,
          finalAnswer,
        ],
        cachedNextCursor: null,
        refreshedTimeline: const <TimelineEntry>[
          first,
          finalAnswer,
          firstCommand,
          secondCommand,
        ],
        refreshedNextCursor: null,
        refreshedTurnIds: const <String>['turn-1'],
        cachedThreadUpdatedAt: 10,
        refreshedThreadUpdatedAt: 11,
      );

      expect(result.timeline, const <TimelineEntry>[
        first,
        finalAnswer,
        firstCommand,
        secondCommand,
      ]);
    });

    test(
      'matches an OpenCode command across synthetic and server turn ids',
      () {
        const cachedAnchor = TimelineEntry(
          id: 'answer-1',
          kind: TimelineKind.agentMessage,
          text: '检查完成',
          turnId: 'turn-1',
        );
        const cachedCommand = TimelineEntry(
          id: 'command-1',
          kind: TimelineKind.command,
          command: 'git status',
          status: 'completed',
          turnId: 'opencode-turn-1',
        );
        const refreshedAnchor = TimelineEntry(
          id: 'answer-1',
          kind: TimelineKind.agentMessage,
          text: '检查完成',
          turnId: 'turn-1',
        );
        const refreshedCommand = TimelineEntry(
          id: 'command-1',
          kind: TimelineKind.command,
          command: 'git status',
          status: 'completed',
          turnId: 'server-turn-1',
        );

        final result = reconcileResumedTimeline(
          cachedTimeline: const <TimelineEntry>[cachedAnchor, cachedCommand],
          cachedNextCursor: null,
          refreshedTimeline: const <TimelineEntry>[
            refreshedAnchor,
            refreshedCommand,
          ],
          refreshedNextCursor: null,
          refreshedTurnIds: const <String>['turn-1', 'server-turn-1'],
          cachedThreadUpdatedAt: 10,
          refreshedThreadUpdatedAt: 11,
        );

        expect(result.timeline, const <TimelineEntry>[
          refreshedAnchor,
          refreshedCommand,
        ]);
        expect(
          result.timeline.where((entry) => entry.id == 'command-1'),
          hasLength(1),
        );
      },
    );

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

    test(
      'matches an inline text attachment with its uploaded optimistic row',
      () {
        const imagePath =
            '/root/.codex-mobile/uploads/96b2bf2f-scaled_1000154875.jpg';
        const logPath =
            '/root/.codex-mobile/uploads/agent-diagnostic-session-123.txt';
        const optimistic = TimelineEntry(
          id: 'local-user-1',
          kind: TimelineKind.userMessage,
          text: '这是怎么回事？',
          attachments: <MessageAttachment>[
            MessageAttachment(
              name: 'scaled_1000154875.jpg',
              remotePath: imagePath,
              mimeType: 'image/jpeg',
            ),
            MessageAttachment(
              name: 'agent-diagnostic-session-123.txt',
              remotePath: logPath,
              mimeType: 'text/plain',
            ),
          ],
          turnId: 'turn-1',
        );
        const refreshed = TimelineEntry(
          id: 'server-user-1',
          kind: TimelineKind.userMessage,
          text: '这是怎么回事？',
          attachments: <MessageAttachment>[
            MessageAttachment(
              name: '96b2bf2f-scaled_1000154875.jpg',
              remotePath: imagePath,
              mimeType: 'image/*',
            ),
            MessageAttachment(
              name: 'agent-diagnostic-session-123.txt',
              mimeType: 'text/plain',
            ),
          ],
          turnId: 'turn-1',
        );

        final result = reconcileResumedTimeline(
          cachedTimeline: const <TimelineEntry>[optimistic],
          cachedNextCursor: null,
          refreshedTimeline: const <TimelineEntry>[refreshed],
          refreshedNextCursor: null,
          refreshedTurnIds: const <String>['turn-1'],
        );

        expect(result.timeline, const <TimelineEntry>[refreshed]);
      },
    );

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
          'new agent',
          'new plan',
          'old agent',
          '',
          'new anchor',
        ]);
        expect(result.timeline[3].command, 'old command');
        expect(result.nextCursor, 'older');
      },
    );
  });
}
