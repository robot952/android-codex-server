import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/ui/sub_agent_presentation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('groups adjacent sub-agent activities from the same turn', () {
    final rows = <TimelineEntry>[
      _entry('user', TimelineKind.userMessage, turnId: 'turn-1'),
      _agent('agent-a', 'thread-a', 'turn-1', 'started'),
      _agent('agent-b', 'thread-b', 'turn-1', 'started'),
      _entry('answer', TimelineKind.agentMessage, turnId: 'turn-1'),
      _agent('agent-c', 'thread-c', 'turn-2', 'started'),
    ].toTimelineRenderRows();

    expect(rows, hasLength(4));
    expect(rows[0], isA<TimelineEntryRenderRow>());
    expect((rows[1] as SubAgentTimelineRenderRow).entries, hasLength(2));
    expect(rows[2], isA<TimelineEntryRenderRow>());
    expect((rows[3] as SubAgentTimelineRenderRow).entries, hasLength(1));
  });

  test('uses the path leaf as its name and requires a thread id to open', () {
    final agent = <TimelineEntry>[
      _agent('agent', '', 'turn', 'started', path: 'team/review-agent'),
    ].toSubAgentPresentations().single;

    expect(agent.name, 'review-agent');
    expect(agent.path, 'team/review-agent');
    expect(agent.threadId, isEmpty);
    expect(agent.isConfirmed, isFalse);
    expect(agent.isOpenable, isFalse);
    expect(agent.status, SubAgentDisplayStatus.preparing);
    expect(agent.showsProgressIndicator, isFalse);
  });

  test(
    'a later active update cannot revive a terminal state in the same turn',
    () {
      final agent = <TimelineEntry>[
        _agent(
          'completed',
          'thread',
          'turn',
          'completed',
          activity: 'completed',
        ),
        _agent('late', 'thread', 'turn', 'running', activity: 'started'),
      ].toSubAgentPresentations().single;

      expect(agent.status, SubAgentDisplayStatus.completed);
      expect(agent.status.label, '已完成');
      expect(agent.timelineIndex, 1);
    },
  );

  test('a later turn can reactivate a completed agent', () {
    final agent = <TimelineEntry>[
      _agent('completed', 'thread', 'turn-1', 'completed'),
      _agent('resumed', 'thread', 'turn-2', 'running', activity: 'started'),
    ].toSubAgentPresentations().single;

    expect(agent.status, SubAgentDisplayStatus.started);
    expect(agent.status.label, '已开始工作');
    expect(agent.turnId, 'turn-2');
  });

  test('limits composer agents to the active turn while a task is running', () {
    final entries = <TimelineEntry>[
      _agent('old-a', 'old-a', 'turn-old', 'completed'),
      _agent('old-b', 'old-b', 'turn-old', 'completed'),
      _agent('old-c', 'old-c', 'turn-old', 'completed'),
      _agent('current-a', 'current-a', 'turn-current', 'running'),
      _agent('current-b', 'current-b', 'turn-current', 'running'),
    ];

    final agents = entries.toBackgroundSubAgentPresentations(
      running: true,
      activeTurnId: 'turn-current',
    );

    expect(agents.map((agent) => agent.threadId), <String>[
      'current-b',
      'current-a',
    ]);
  });

  test('does not show historical agents before a running turn has an id', () {
    final agents = <TimelineEntry>[
      _agent('old-a', 'old-a', 'turn-old', 'completed'),
      _agent('old-b', 'old-b', 'turn-old', 'completed'),
    ].toBackgroundSubAgentPresentations(running: true);

    expect(agents, isEmpty);
  });

  test('does not count unconfirmed creation attempts as background agents', () {
    final agents =
        <TimelineEntry>[
          _agent(
            'attempt-a',
            '',
            'turn-current',
            'running',
            activity: 'started',
          ),
          _agent(
            'attempt-b',
            '',
            'turn-current',
            'running',
            activity: 'started',
          ),
          _agent('confirmed', 'child-thread', 'turn-current', 'running'),
        ].toBackgroundSubAgentPresentations(
          running: true,
          activeTurnId: 'turn-current',
        );

    expect(agents.map((agent) => agent.threadId), <String>['child-thread']);
  });

  test('uses the latest sub-agent turn after the task has finished', () {
    final agents = <TimelineEntry>[
      _agent('old', 'old', 'turn-old', 'completed'),
      _agent('latest', 'latest', 'turn-latest', 'completed'),
    ].toBackgroundSubAgentPresentations(running: false);

    expect(agents.single.threadId, 'latest');
  });

  test('does not fall back to an older turn after one without agents', () {
    final agents =
        <TimelineEntry>[
          _agent('old', 'old', 'turn-old', 'completed'),
        ].toBackgroundSubAgentPresentations(
          running: false,
          activeTurnId: 'turn-without-agents',
        );

    expect(agents, isEmpty);
  });

  test(
    'maps activities and mixed terminal groups to Chinese display statuses',
    () {
      final started = <TimelineEntry>[
        _agent('started', 'thread-a', 'turn', 'running', activity: 'started'),
      ].toSubAgentActivityGroupPresentation();
      final updated = <TimelineEntry>[
        _agent(
          'updated',
          'thread-b',
          'turn',
          'running',
          activity: 'interacted',
        ),
      ].toSubAgentActivityGroupPresentation();
      final failed = <TimelineEntry>[
        _agent('complete', 'thread-c', 'turn', 'completed'),
        _agent('failed', 'thread-d', 'turn', 'failed'),
      ].toSubAgentActivityGroupPresentation();

      expect(started.statusLabel, '已开始工作');
      expect(started.isActive, isTrue);
      expect(updated.statusLabel, '已更新');
      expect(updated.isActive, isTrue);
      expect(failed.status, SubAgentDisplayStatus.failed);
      expect(failed.statusLabel, '失败');
      expect(failed.isActive, isFalse);
    },
  );

  test(
    'marks unconfirmed activity as preparing without treating it as running',
    () {
      final group = <TimelineEntry>[
        _agent('attempt', '', 'turn', 'running', activity: 'started'),
      ].toSubAgentActivityGroupPresentation();

      expect(group.agents.single.status, SubAgentDisplayStatus.preparing);
      expect(group.status, SubAgentDisplayStatus.preparing);
      expect(group.statusLabel, '准备中');
      expect(group.isActive, isFalse);
    },
  );

  test('avatar identity and color stay stable across status changes', () {
    final running = <TimelineEntry>[
      _agent('running', 'shared-thread', 'turn', 'running'),
    ].toSubAgentPresentations().single;
    final completed = <TimelineEntry>[
      _agent('completed', 'shared-thread', 'turn', 'completed'),
    ].toSubAgentPresentations().single;
    final pathFallback = <TimelineEntry>[
      _agent('review', '', 'turn', 'running', path: 'team/review-agent'),
    ].toSubAgentPresentations().single;

    expect(running.avatarIdentityKey, 'shared-thread');
    expect(running.avatarColorIndex(7), completed.avatarColorIndex(7));
    expect(pathFallback.avatarIdentityKey, 'team/review-agent');
    expect(pathFallback.avatarColorIndex(7), inInclusiveRange(0, 6));
    expect(() => running.avatarColorIndex(0), throwsArgumentError);
  });
}

TimelineEntry _entry(String id, TimelineKind kind, {String turnId = ''}) {
  return TimelineEntry(id: id, kind: kind, turnId: turnId);
}

TimelineEntry _agent(
  String id,
  String threadId,
  String turnId,
  String status, {
  String? activity,
  String? path,
}) {
  return TimelineEntry(
    id: id,
    kind: TimelineKind.subAgent,
    status: status,
    turnId: turnId,
    subAgentPath: path ?? 'team/$id',
    subAgentThreadId: threadId,
    subAgentActivity: activity ?? status,
  );
}
