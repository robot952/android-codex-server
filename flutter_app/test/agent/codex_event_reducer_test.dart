import 'package:codex_remote/src/agent/codex_event_reducer.dart';
import 'package:codex_remote/src/agent/codex_protocol.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

CodexRpcNotification _notification(
  String method,
  Map<String, Object?> params,
) => CodexRpcNotification(
  generation: 1,
  raw: <String, Object?>{'method': method, 'params': params},
  method: method,
  params: params,
  isKnown: true,
);

AppUiState _state() => AppUiState(
  screen: AppScreen.work,
  activeThread: const AgentThread(id: 'thread-1', title: '任务'),
  threads: const [
    AgentThread(id: 'thread-1', title: '任务'),
    AgentThread(id: 'thread-2', title: '后台任务'),
  ],
  tokenUsage: const TokenUsage(
    modelContextWindow: 1000,
    total: TokenUsageBreakdown(totalTokens: 120),
  ),
);

void main() {
  test('reduces turn lifecycle and streamed agent text', () {
    var state = _state();
    state = reduceCodexNotification(
      state,
      _notification('turn/started', {
        'threadId': 'thread-1',
        'turn': {'id': 'turn-1', 'status': 'inProgress'},
      }),
      nowMillis: 100,
    );
    expect(state.running, isTrue);
    expect(state.activeTurnId, 'turn-1');
    expect(state.turnTiming?.startedAtMillis, 100);

    state = reduceCodexNotification(
      state,
      _notification('item/agentMessage/delta', {
        'threadId': 'thread-1',
        'turnId': 'turn-1',
        'itemId': 'item-1',
        'delta': '你好',
      }),
    );
    state = reduceCodexNotification(
      state,
      _notification('item/agentMessage/delta', {
        'threadId': 'thread-1',
        'turnId': 'turn-1',
        'itemId': 'item-1',
        'delta': '，世界',
      }),
    );
    expect(state.timeline.single.text, '你好，世界');

    state = reduceCodexNotification(
      state,
      _notification('turn/completed', {
        'threadId': 'thread-1',
        'turn': {'id': 'turn-1', 'status': 'completed'},
      }),
      nowMillis: 200,
    );
    expect(state.running, isFalse);
    expect(state.activeTurnId, isNull);
    expect(state.turnTiming?.completedAtMillis, 200);
    expect(state.activeThread?.status, 'idle');
  });

  test('updates a background thread without changing active timeline', () {
    final state = _state();
    final next = reduceCodexNotification(
      state,
      _notification('thread/status/changed', {
        'threadId': 'thread-2',
        'status': {'type': 'active'},
        'activeTurnId': 'turn-2',
      }),
    );
    expect(next.timeline, isEmpty);
    expect(next.activeThread?.id, 'thread-1');
    expect(
      next.threads.firstWhere((thread) => thread.id == 'thread-1').status,
      'idle',
    );
    expect(
      next.threads.firstWhere((thread) => thread.id == 'thread-2').status,
      'active',
    );
  });

  test('keeps an explicit stop marker when completion reports completed', () {
    final state = _state().copyWith(
      running: true,
      activeTurnId: 'turn-1',
      turnTiming: const TurnTiming(
        threadId: 'thread-1',
        turnId: 'turn-1',
        startedAtMillis: 100,
        stopped: true,
      ),
    );

    final next = reduceCodexNotification(
      state,
      _notification('turn/completed', {
        'threadId': 'thread-1',
        'turn': {'id': 'turn-1', 'status': 'completed'},
      }),
      nowMillis: 200,
    );

    expect(next.running, isFalse);
    expect(next.turnTiming?.completedAtMillis, 200);
    expect(next.turnTiming?.stopped, isTrue);
  });

  test('settles a final answer when turn completion is missing', () {
    final state = _state().copyWith(
      running: true,
      activeTurnId: 'turn-1',
      activeThread: const AgentThread(
        id: 'thread-1',
        title: '任务',
        status: 'active',
        activeTurnId: 'turn-1',
      ),
      turnTiming: const TurnTiming(
        threadId: 'thread-1',
        turnId: 'turn-1',
        startedAtMillis: 100,
      ),
    );

    final next = reduceCodexNotification(
      state,
      _notification('item/completed', {
        'threadId': 'thread-1',
        'turnId': 'turn-1',
        'item': <String, Object?>{
          'id': 'answer-1',
          'type': 'agentMessage',
          'phase': 'final_answer',
          'text': '完成了',
        },
      }),
      nowMillis: 200,
    );

    expect(next.running, isFalse);
    expect(next.activeTurnId, isNull);
    expect(next.activeThread?.status, 'idle');
    expect(next.turnTiming?.completedAtMillis, 200);
    expect(next.timeline.single.text, '完成了');
  });

  test('ignores a late start after a locally settled turn', () {
    final state = _state().copyWith(
      running: false,
      activeTurnId: null,
      turnTiming: const TurnTiming(
        threadId: 'thread-1',
        turnId: 'turn-1',
        startedAtMillis: 100,
        completedAtMillis: 200,
        stopped: true,
      ),
    );

    final next = reduceCodexNotification(
      state,
      _notification('turn/started', {
        'threadId': 'thread-1',
        'turn': {'id': 'turn-1', 'status': 'inProgress'},
      }),
    );

    expect(next.running, isFalse);
    expect(next.activeTurnId, isNull);
    expect(next.turnTiming?.stopped, isTrue);
  });

  test('does not replace a known context window with incomplete usage', () {
    final state = _state();
    final next = reduceCodexNotification(
      state,
      _notification('thread/tokenUsage/updated', {
        'threadId': 'thread-1',
        'tokenUsage': {
          'total': {'totalTokens': 300},
        },
      }),
    );
    expect(next.tokenUsage?.modelContextWindow, 1000);
    expect(next.tokenUsage?.total.totalTokens, 120);
  });

  test('ignores a late completion from an older turn', () {
    final state = _state().copyWith(
      running: true,
      activeTurnId: 'turn-new',
      activeThread: const AgentThread(
        id: 'thread-1',
        title: '任务',
        status: 'active',
        activeTurnId: 'turn-new',
      ),
      threads: const [
        AgentThread(
          id: 'thread-1',
          title: '任务',
          status: 'active',
          activeTurnId: 'turn-new',
        ),
      ],
    );
    final next = reduceCodexNotification(
      state,
      _notification('turn/completed', {
        'threadId': 'thread-1',
        'turn': {'id': 'turn-old', 'status': 'completed'},
      }),
    );
    expect(next.running, isTrue);
    expect(next.activeTurnId, 'turn-new');
    expect(next.threads.single.status, 'active');
  });

  test('reconciles an optimistic user row with the server item id', () {
    final state = _state().copyWith(
      timeline: const <TimelineEntry>[
        TimelineEntry(
          id: 'local-user-123',
          kind: TimelineKind.userMessage,
          text: '查看截图',
          attachments: <MessageAttachment>[
            MessageAttachment(
              name: 'screen.png',
              remotePath: '/tmp/screen.png',
              mimeType: 'image/png',
            ),
          ],
        ),
      ],
    );

    final next = reduceCodexNotification(
      state,
      _notification('item/completed', {
        'threadId': 'thread-1',
        'turnId': 'turn-1',
        'item': <String, Object?>{
          'id': 'server-user-1',
          'type': 'userMessage',
          'content': <Object?>[
            <String, Object?>{'type': 'text', 'text': '查看截图'},
            <String, Object?>{'type': 'localImage', 'path': '/tmp/screen.png'},
          ],
        },
      }),
    );

    expect(next.timeline, hasLength(1));
    expect(next.timeline.single.id, 'server-user-1');
    expect(next.timeline.single.turnId, 'turn-1');
    expect(next.timeline.single.attachments.single.mimeType, 'image/*');
  });

  test('reconciles an uploaded image when the server changes its name', () {
    const remotePath =
        '/root/.codex-mobile/uploads/'
        '1f7f2263-6d39-41ba-9242-9187348b-camera-photo.jpg';
    final state = _state().copyWith(
      timeline: const <TimelineEntry>[
        TimelineEntry(
          id: 'local-user-123',
          kind: TimelineKind.userMessage,
          text: '这是啥？',
          attachments: <MessageAttachment>[
            MessageAttachment(
              name: 'camera-photo.jpg',
              remotePath: remotePath,
              mimeType: 'image/jpeg',
            ),
          ],
        ),
      ],
    );

    final next = reduceCodexNotification(
      state,
      _notification('item/completed', {
        'threadId': 'thread-1',
        'turnId': 'turn-1',
        'item': <String, Object?>{
          'id': 'server-user-1',
          'type': 'userMessage',
          'content': <Object?>[
            <String, Object?>{'type': 'text', 'text': '这是啥？'},
            <String, Object?>{'type': 'localImage', 'path': remotePath},
          ],
        },
      }),
    );

    expect(next.timeline, hasLength(1));
    expect(next.timeline.single.id, 'server-user-1');
    expect(
      next.timeline.single.attachments.single.name,
      '1f7f2263-6d39-41ba-9242-9187348b-camera-photo.jpg',
    );
  });

  test('does not reconcile images with different remote paths', () {
    final state = _state().copyWith(
      timeline: const <TimelineEntry>[
        TimelineEntry(
          id: 'local-user-123',
          kind: TimelineKind.userMessage,
          text: '这是啥？',
          attachments: <MessageAttachment>[
            MessageAttachment(
              name: 'camera-photo.jpg',
              remotePath: '/tmp/first-camera-photo.jpg',
              mimeType: 'image/jpeg',
            ),
          ],
        ),
      ],
    );

    final next = reduceCodexNotification(
      state,
      _notification('item/completed', {
        'threadId': 'thread-1',
        'turnId': 'turn-1',
        'item': <String, Object?>{
          'id': 'server-user-1',
          'type': 'userMessage',
          'content': <Object?>[
            <String, Object?>{'type': 'text', 'text': '这是啥？'},
            <String, Object?>{
              'type': 'localImage',
              'path': '/tmp/second-camera-photo.jpg',
            },
          ],
        },
      }),
    );

    expect(next.timeline, hasLength(2));
  });

  test('reconciles an empty started user item before completed content', () {
    final state = _state().copyWith(
      timeline: const <TimelineEntry>[
        TimelineEntry(
          id: 'local-user-123',
          kind: TimelineKind.userMessage,
          text: '再开个3分钟的',
        ),
      ],
    );

    final started = reduceCodexNotification(
      state,
      _notification('item/started', {
        'threadId': 'thread-1',
        'turnId': 'turn-1',
        'item': <String, Object?>{
          'id': 'server-user-1',
          'type': 'userMessage',
          'content': <Object?>[],
        },
      }),
    );
    expect(started.timeline, hasLength(1));
    expect(started.timeline.single.id, 'server-user-1');
    expect(started.timeline.single.text, '再开个3分钟的');

    final completed = reduceCodexNotification(
      started,
      _notification('item/completed', {
        'threadId': 'thread-1',
        'turnId': 'turn-1',
        'item': <String, Object?>{
          'id': 'server-user-1',
          'type': 'userMessage',
          'content': <Object?>[
            <String, Object?>{'type': 'text', 'text': '再开个3分钟的'},
          ],
        },
      }),
    );
    expect(completed.timeline, hasLength(1));
    expect(completed.timeline.single.id, 'server-user-1');
    expect(completed.timeline.single.text, '再开个3分钟的');
  });

  test('does not reconcile a different optimistic user message', () {
    final state = _state().copyWith(
      timeline: const <TimelineEntry>[
        TimelineEntry(
          id: 'local-user-123',
          kind: TimelineKind.userMessage,
          text: '第一条',
        ),
      ],
    );
    final next = reduceCodexNotification(
      state,
      _notification('item/started', {
        'threadId': 'thread-1',
        'turnId': 'turn-1',
        'item': <String, Object?>{
          'id': 'server-user-1',
          'type': 'userMessage',
          'content': <Object?>[
            <String, Object?>{'type': 'text', 'text': '第二条'},
          ],
        },
      }),
    );

    expect(next.timeline, hasLength(2));
  });

  test('folds repeated formal user item events into one row', () {
    var state = _state().copyWith(
      timeline: const <TimelineEntry>[
        TimelineEntry(
          id: 'server-user-1',
          kind: TimelineKind.userMessage,
          text: '再运行一个30秒的命令',
          turnId: 'turn-1',
        ),
      ],
    );
    for (final id in const [
      'server-user-2',
      'server-user-3',
      'server-user-4',
    ]) {
      state = reduceCodexNotification(
        state,
        _notification('item/completed', {
          'threadId': 'thread-1',
          'turnId': 'turn-1',
          'item': <String, Object?>{
            'id': id,
            'type': 'userMessage',
            'content': <Object?>[
              <String, Object?>{'type': 'text', 'text': '再运行一个30秒的命令'},
            ],
          },
        }),
      );
    }
    expect(state.timeline, hasLength(1));
    expect(state.timeline.single.id, 'server-user-4');
  });

  test('marks a command completed when the completion omits status', () {
    var state = reduceCodexNotification(
      _state(),
      _notification('item/started', {
        'threadId': 'thread-1',
        'turnId': 'turn-1',
        'item': <String, Object?>{
          'id': 'command-1',
          'type': 'commandExecution',
          'command': 'flutter test',
          'status': 'inProgress',
        },
      }),
    );

    expect(state.timeline.single.status, 'inProgress');

    state = reduceCodexNotification(
      state,
      _notification('item/completed', {
        'threadId': 'thread-1',
        'turnId': 'turn-1',
        'item': <String, Object?>{
          'id': 'command-1',
          'type': 'commandExecution',
          'command': 'flutter test',
        },
      }),
    );

    expect(state.timeline.single.status, 'completed');
  });

  test('keeps the same item id separate across turns and kinds', () {
    var state = _state().copyWith(
      timeline: const <TimelineEntry>[
        TimelineEntry(
          id: 'shared-item',
          kind: TimelineKind.agentMessage,
          text: 'older turn',
          turnId: 'turn-1',
        ),
        TimelineEntry(
          id: 'shared-item',
          kind: TimelineKind.command,
          output: 'command output',
          turnId: 'turn-2',
        ),
      ],
    );

    state = reduceCodexNotification(
      state,
      _notification('item/agentMessage/delta', {
        'threadId': 'thread-1',
        'turnId': 'turn-2',
        'itemId': 'shared-item',
        'delta': 'current turn',
      }),
    );
    state = reduceCodexNotification(
      state,
      _notification('item/completed', {
        'threadId': 'thread-1',
        'turnId': 'turn-2',
        'item': <String, Object?>{
          'id': 'shared-item',
          'type': 'agentMessage',
          'status': 'completed',
        },
      }),
    );

    expect(state.timeline, hasLength(3));
    expect(
      state.timeline
          .firstWhere(
            (entry) =>
                entry.turnId == 'turn-1' &&
                entry.kind == TimelineKind.agentMessage,
          )
          .text,
      'older turn',
    );
    expect(
      state.timeline
          .firstWhere(
            (entry) =>
                entry.turnId == 'turn-2' && entry.kind == TimelineKind.command,
          )
          .output,
      'command output',
    );
    final currentMessage = state.timeline.firstWhere(
      (entry) =>
          entry.turnId == 'turn-2' && entry.kind == TimelineKind.agentMessage,
    );
    expect(currentMessage.text, 'current turn');
    expect(currentMessage.status, 'completed');
  });

  test('rejects an unscoped late parent item on an AgentWork page', () {
    final child = _state().copyWith(screen: AppScreen.agentWork);
    final unscoped = reduceCodexNotification(
      child,
      _notification('item/agentMessage/delta', {
        'turnId': 'parent-turn',
        'itemId': 'parent-message',
        'delta': 'late parent text',
      }),
    );
    final scoped = reduceCodexNotification(
      child,
      _notification('item/agentMessage/delta', {
        'threadId': 'thread-1',
        'turnId': 'child-turn',
        'itemId': 'child-message',
        'delta': 'child text',
      }),
    );

    expect(unscoped.timeline, isEmpty);
    expect(scoped.timeline.single.text, 'child text');
  });

  test('does not resurrect a terminal sub-agent in the same turn', () {
    final completed = _state().copyWith(
      timeline: const <TimelineEntry>[
        TimelineEntry(
          id: 'agent-item',
          kind: TimelineKind.subAgent,
          status: 'completed',
          turnId: 'turn-1',
          subAgentThreadId: 'child-thread',
        ),
      ],
    );
    final sameTurn = reduceCodexNotification(
      completed,
      _notification('item/completed', {
        'threadId': 'thread-1',
        'turnId': 'turn-1',
        'item': <String, Object?>{
          'id': 'agent-item',
          'type': 'subAgentActivity',
          'kind': 'interacted',
          'agentThreadId': 'child-thread',
        },
      }),
    );
    final laterTurn = reduceCodexNotification(
      completed,
      _notification('item/completed', {
        'threadId': 'thread-1',
        'turnId': 'turn-2',
        'item': <String, Object?>{
          'id': 'agent-item',
          'type': 'subAgentActivity',
          'kind': 'interacted',
          'agentThreadId': 'child-thread',
        },
      }),
    );

    expect(sameTurn.timeline.single.status, 'completed');
    expect(laterTurn.timeline, hasLength(2));
    expect(laterTurn.timeline[0].status, 'completed');
    expect(laterTurn.timeline[1].status, 'running');
  });

  test('completes active sub-agents when their parent turn completes', () {
    final running = _state().copyWith(
      running: true,
      activeTurnId: 'turn-1',
      timeline: const <TimelineEntry>[
        TimelineEntry(
          id: 'agent-a',
          kind: TimelineKind.subAgent,
          status: 'running',
          turnId: 'turn-1',
          subAgentThreadId: 'child-a',
        ),
        TimelineEntry(
          id: 'agent-b',
          kind: TimelineKind.subAgent,
          status: 'completed',
          turnId: 'turn-1',
          subAgentThreadId: 'child-b',
        ),
      ],
    );

    final completed = reduceCodexNotification(
      running,
      _notification('turn/completed', {
        'threadId': 'thread-1',
        'turn': <String, Object?>{
          'id': 'turn-1',
          'status': <String, Object?>{'type': 'completed'},
        },
      }),
    );

    expect(completed.timeline.map((entry) => entry.status), <String>[
      'completed',
      'completed',
    ]);
  });

  test('applies collab agent states to all activities in the turn', () {
    final running = _state().copyWith(
      timeline: const <TimelineEntry>[
        TimelineEntry(
          id: 'agent-started',
          kind: TimelineKind.subAgent,
          status: 'running',
          turnId: 'turn-1',
          subAgentThreadId: 'child-a',
        ),
        TimelineEntry(
          id: 'agent-updated',
          kind: TimelineKind.subAgent,
          status: 'running',
          turnId: 'turn-1',
          subAgentThreadId: 'child-a',
        ),
      ],
    );

    final completed = reduceCodexNotification(
      running,
      _notification('item/completed', {
        'threadId': 'thread-1',
        'turnId': 'turn-1',
        'item': <String, Object?>{
          'id': 'collab-state',
          'type': 'collabAgentToolCall',
          'status': 'completed',
          'agentsStates': <String, Object?>{
            'child-a': <String, Object?>{'status': 'completed'},
          },
        },
      }),
    );

    expect(
      completed.timeline
          .where((entry) => entry.kind == TimelineKind.subAgent)
          .map((entry) => entry.status),
      everyElement('completed'),
    );
  });
}
