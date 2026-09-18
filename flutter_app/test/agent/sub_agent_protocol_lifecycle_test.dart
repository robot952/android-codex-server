import 'package:codex_remote/src/agent/codex_event_reducer.dart';
import 'package:codex_remote/src/agent/codex_protocol.dart';
import 'package:codex_remote/src/agent/thread_session_cache.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
