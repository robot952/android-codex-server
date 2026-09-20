import 'package:codex_remote/src/agent/codex_event_reducer.dart';
import 'package:codex_remote/src/agent/codex_protocol.dart';
import 'package:codex_remote/src/agent/thread_session_cache.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'sub-agent metadata supplies its own name instead of inherited title',
    () {
      final thread = CodexPayloadParser.parseThread({
        'id': 'child',
        'title': 'Root task title',
        'source': {
          'subAgent': {
            'thread_spawn': {
              'parent_thread_id': 'parent',
              'agent_path': '/root/History audit',
            },
          },
        },
      })!;
      expect(thread.title, 'History audit');
      expect(thread.source, 'subAgent');
    },
  );

  test('parent-directed history is a message, not a child reference', () {
    final history = CodexPayloadParser.parseResumedThread({
      'thread': {
        'id': 'child',
        'parentThreadId': 'parent',
        'turns': [
          {
            'id': 'child-turn',
            'items': [
              {
                'id': 'message-to-parent',
                'type': 'collabAgentToolCall',
                'tool': 'sendMessage',
                'status': 'completed',
                'senderThreadId': 'child',
                'receiverThreadIds': ['parent'],
                'agentsStates': {},
              },
              {
                'id': 'message-to-other',
                'type': 'collabAgentToolCall',
                'tool': 'sendMessage',
                'status': 'completed',
                'senderThreadId': 'child',
                'receiverThreadIds': ['sibling'],
                'agentsStates': {},
              },
            ],
          },
        ],
      },
    })!;
    expect(history.timeline.first.subAgentActivity, 'sendMessageToParent');
    expect(history.timeline.first.subAgentThreadId, isEmpty);
    expect(history.timeline.last.subAgentThreadId, 'sibling');
  });

  // Both identifiers are in one second; createdAt's seconds precision cannot
  // distinguish the copied parent turn from the first local child turn.
  const childThreadId = '01a0b573-91cc-7ad3-ad41-72bd0b489c52';
  const parentTurnId = '01a0b573-9000-7c51-a2e0-4389f0c8c6b2';
  const childTurnId = '01a0b573-91f2-7523-b25d-4fd4bc1fdc8e';
  Map<String, Object?> historyTurn(String id, String text, {int? startedAt}) =>
      {
        'id': id,
        'startedAt': startedAt,
        'items': [
          {'id': '$text-message', 'type': 'agentMessage', 'text': text},
        ],
      };

  test(
    'child history excludes UUIDv7 parent turns with missing timestamps',
    () {
      final snapshot = CodexPayloadParser.parseResumedThread({
        'thread': {
          'id': childThreadId,
          'source': {'subAgent': {}},
          'createdAt': 1789750645,
        },
        'initialTurnsPage': {
          'nextCursor': 'inherited-page',
          'data': [
            historyTurn(childTurnId, 'child'),
            historyTurn(parentTurnId, 'parent'),
          ],
        },
      });
      expect(snapshot!.timeline.map((entry) => entry.text), ['child']);
      expect(snapshot.turnIds, [childTurnId]);
      expect(snapshot.nextTurnsCursor, isNull);
    },
  );

  test(
    'explicit parent metadata identifies a child even with ordinary source',
    () {
      final snapshot = CodexPayloadParser.parseResumedThread({
        'thread': {
          'id': childThreadId,
          'source': 'vscode',
          'parentThreadId': 'parent-thread',
          'turns': [
            historyTurn(parentTurnId, 'parent', startedAt: 1789750645),
            historyTurn(childTurnId, 'child', startedAt: 1789750645),
          ],
        },
      });
      expect(snapshot!.thread.source, 'subAgent');
      expect(snapshot.timeline.map((entry) => entry.text), ['child']);
    },
  );

  test(
    'paging preserves unknown child IDs and stops at inherited UUID turns',
    () {
      final page = CodexPayloadParser.parseTurnsPage({
        'nextCursor': 'parent-page',
        'data': [
          historyTurn(childTurnId, 'child'),
          historyTurn('legacy-child-turn', 'legacy-child'),
          historyTurn(parentTurnId, 'parent'),
        ],
      }, subAgentThreadId: childThreadId);
      expect(page.timeline.map((entry) => entry.text), [
        'legacy-child',
        'child',
      ]);
      expect(page.nextCursor, isNull);
    },
  );

  test('ordinary forks retain their original history', () {
    final snapshot = CodexPayloadParser.parseResumedThread({
      'thread': {
        'id': childThreadId,
        'source': 'vscode',
        'forkedFromId': 'parent-thread',
        'createdAt': 1789750645,
        'turns': [
          historyTurn(parentTurnId, 'parent'),
          historyTurn(childTurnId, 'child'),
        ],
      },
    });
    expect(snapshot!.timeline.map((entry) => entry.text), ['parent', 'child']);
    expect(snapshot.thread.source, 'vscode');
  });

  test(
    'known parent turn identities exclude legacy history without guessing',
    () {
      expect(
        CodexPayloadParser.isInheritedSubAgentTurn(
          'legacy-parent',
          subAgentThreadId: 'legacy-child',
          inheritedTurnIds: {'legacy-parent'},
        ),
        isTrue,
      );
      expect(
        CodexPayloadParser.isInheritedSubAgentTurn(
          'legacy-child-turn',
          subAgentThreadId: childThreadId,
        ),
        isFalse,
      );
      expect(
        CodexPayloadParser.isInheritedSubAgentTurn(
          // A UUIDv4-looking value must not be interpreted as a timestamp.
          '00000000-0000-4c51-a2e0-4389f0c8c6b2',
          subAgentThreadId: childThreadId,
        ),
        isFalse,
      );
    },
  );

  test('child history compares seconds and milliseconds in the same unit', () {
    final snapshot = CodexPayloadParser.parseResumedThread({
      'thread': {
        'id': 'child',
        'source': {'subAgent': {}},
        'createdAt': 1789750032,
        'turns': [
          {
            'id': 'parent',
            'startedAt': 1789750031000,
            'items': [
              {
                'id': 'parent-message',
                'type': 'agentMessage',
                'text': 'parent',
              },
            ],
          },
          {
            'id': 'child',
            'startedAt': 1789750033,
            'items': [
              {'id': 'child-message', 'type': 'agentMessage', 'text': 'child'},
            ],
          },
        ],
      },
    });
    expect(snapshot!.timeline.map((entry) => entry.text), ['child']);
  });

  Map<String, Object?> collab({
    String id = 'call',
    String tool = 'wait',
    String status = 'completed',
    List<String> receivers = const ['a', 'b'],
    Map<String, Object?> states = const {},
  }) => {
    'id': id,
    'type': 'collabAgentToolCall',
    'tool': tool,
    'status': status,
    'senderThreadId': 'parent',
    'receiverThreadIds': receivers,
    'agentsStates': states,
  };

  CodexRpcNotification item(
    Map<String, Object?> value, {
    bool completed = true,
  }) {
    final params = <String, Object?>{
      'threadId': 'parent',
      'turnId': 'parent-turn',
      'item': value,
    };
    return CodexRpcNotification(
      generation: 1,
      method: completed ? 'item/completed' : 'item/started',
      params: params,
      raw: const {},
      isKnown: true,
    );
  }

  AppUiState initial() => const AppUiState(
    activeThread: AgentThread(id: 'parent'),
    screen: AppScreen.work,
    running: true,
    activeTurnId: 'parent-turn',
  );

  test('standard collaboration maps all receivers and independent results', () {
    final parsed = CodexPayloadParser.parseItems(
      collab(
        receivers: ['a', 'b', 'a'],
        states: {
          'a': {'status': 'completed', 'message': 'first result'},
          'b': {'status': 'running'},
          'c': {'status': 'notFound'},
        },
      ),
      turnId: 'parent-turn',
    );

    expect(parsed.map((e) => e.subAgentThreadId), ['a', 'b', 'c']);
    expect(parsed.map((e) => e.status), ['completed', 'running', 'notFound']);
    expect(parsed.first.text, 'first result');
    expect(parsed.map((e) => e.id).toSet(), hasLength(3));
  });

  test(
    'real completed activity becomes terminal and empty wait adds no child',
    () {
      final completed = CodexPayloadParser.parseItem({
        'id': 'subagent-completed-child-turn',
        'type': 'subAgentActivity',
        'kind': 'completed',
        'agentThreadId': 'a',
        'agentPath': '/root/alpha',
      }, turnId: 'parent-turn');
      expect(completed!.status, 'completed');
      final waiting = CodexPayloadParser.parseItems(
        collab(receivers: []),
        turnId: 'parent-turn',
      );
      expect(
        waiting.where((entry) => entry.kind == TimelineKind.subAgent),
        isEmpty,
      );
    },
  );

  test('tool completion does not imply child completion or failure', () {
    for (final tool in ['spawnAgent', 'sendInput', 'resumeAgent', 'wait']) {
      final parsed = CodexPayloadParser.parseItems(
        collab(
          tool: tool,
          states: {
            'a': {'status': 'running'},
          },
        ),
        turnId: 'parent-turn',
      );
      expect(parsed.first.status, 'running', reason: tool);
      expect(parsed.last.status, isNot('completed'), reason: tool);
    }
    final failedSend = CodexPayloadParser.parseItems(
      collab(
        tool: 'sendInput',
        status: 'failed',
        receivers: ['a'],
        states: {
          'a': {'status': 'running'},
        },
      ),
      turnId: 'parent-turn',
    );
    expect(failedSend.single.status, 'running');
  });

  test('spawn resolves its placeholder without duplicates on replay', () {
    var state = reduceCodexNotification(
      initial(),
      item(
        collab(tool: 'spawnAgent', status: 'inProgress', receivers: []),
        completed: false,
      ),
    );
    expect(state.timeline.single.subAgentThreadId, isEmpty);
    final completed = item(
      collab(
        tool: 'spawnAgent',
        receivers: ['a'],
        states: {
          'a': {'status': 'running'},
        },
      ),
    );
    state = reduceCodexNotification(state, completed);
    state = reduceCodexNotification(state, completed);
    expect(state.timeline, hasLength(1));
    expect(state.timeline.single.subAgentThreadId, 'a');
    expect(state.timeline.single.status, 'running');
  });

  test(
    'failed creation remains unconfirmed and completed close is stopped',
    () {
      final failed = CodexPayloadParser.parseItems(
        collab(tool: 'spawnAgent', status: 'failed', receivers: []),
        turnId: 'parent-turn',
      );
      expect(failed.single.status, 'errored');
      expect(failed.single.subAgentThreadId, isEmpty);
      final closed = CodexPayloadParser.parseItems(
        collab(tool: 'closeAgent', receivers: ['a']),
        turnId: 'parent-turn',
      );
      expect(closed.single.status, 'shutdown');
    },
  );

  test('same parent turn followup retains a new running operation', () {
    var state = reduceCodexNotification(
      initial(),
      item(
        collab(
          id: 'wait-first',
          receivers: ['a'],
          states: {
            'a': {'status': 'completed'},
          },
        ),
      ),
    );
    state = reduceCodexNotification(
      state,
      item(
        collab(
          id: 'send-second',
          tool: 'sendInput',
          receivers: ['a'],
          states: {
            'a': {'status': 'running'},
          },
        ),
      ),
    );
    expect(state.timeline.map((e) => e.status), ['completed', 'running']);
    expect(state.timeline.last.subAgentActivity, 'sendInput');
    final settled = settleActiveTurnLocally(
      state,
      threadId: 'parent',
      turnId: 'parent-turn',
      stopped: false,
    );
    expect(settled.timeline.last.status, 'running');
  });

  test('historical parsing matches live independent child states', () {
    final calls = [
      collab(
        id: 'spawn',
        tool: 'spawnAgent',
        states: {
          'a': {'status': 'running'},
          'b': {'status': 'running'},
        },
      ),
      collab(
        id: 'wait',
        states: {
          'a': {'status': 'completed'},
          'b': {'status': 'errored'},
        },
      ),
      collab(
        id: 'resume',
        tool: 'resumeAgent',
        receivers: ['b'],
        states: {
          'b': {'status': 'running'},
        },
      ),
    ];
    var state = initial();
    for (final call in calls) {
      state = reduceCodexNotification(state, item(call));
    }
    final historical = CodexPayloadParser.parseTimeline({
      'turns': [
        {'id': 'parent-turn', 'status': 'completed', 'items': calls},
      ],
    });
    expect(historical, state.timeline);
    expect(historical.last.status, 'running');
  });

  test(
    'restoring history upgrades interrupted activity to explicit completion',
    () {
      final parsed = CodexPayloadParser.parseTimeline({
        'turns': [
          {
            'id': 'parent-turn',
            'items': [
              {
                'id': 'activity',
                'type': 'subAgentActivity',
                'kind': 'interrupted',
                'agentThreadId': 'a',
              },
              collab(
                receivers: ['a'],
                states: {
                  'a': {'status': 'completed'},
                },
              ),
            ],
          },
        ],
      });
      expect(parsed.map((e) => e.status), everyElement('completed'));
    },
  );

  test(
    'child updates preserve older parent tasks and can explicitly restart',
    () {
      final cache = ThreadSessionCache();
      cache.put(const AgentThread(id: 'parent'), const [
        TimelineEntry(
          id: 'old',
          kind: TimelineKind.subAgent,
          subAgentThreadId: 'a',
          turnId: 'old-parent-turn',
          status: 'interrupted',
        ),
        TimelineEntry(
          id: 'new',
          kind: TimelineKind.subAgent,
          subAgentThreadId: 'a',
          turnId: 'new-parent-turn',
          status: 'running',
        ),
      ]);
      cache.updateSubAgentStatus('a', 'completed');
      expect(cache.getStale('parent')!.timeline.map((e) => e.status), [
        'interrupted',
        'completed',
      ]);
      cache.updateSubAgentStatus('a', 'running', allowRestart: true);
      expect(cache.getStale('parent')!.timeline.map((e) => e.status), [
        'interrupted',
        'running',
      ]);
    },
  );
}
