import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/ui/sub_agent_presentation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'activity rows keep start, finish and message in chronological order',
    () {
      final entries = <TimelineEntry>[
        _agent(
          'start',
          'child',
          'turn',
          'completed',
          activity: 'started',
          path: '/root/Check loading placement',
        ),
        _agent(
          'finish',
          'child',
          'turn',
          'completed',
          activity: 'completed',
          path: '',
        ),
        _agent(
          'message',
          'child',
          'turn',
          'running',
          activity: 'sendInput',
          path: '',
        ),
      ];
      final row =
          entries.toTimelineRenderRows().single as SubAgentTimelineRenderRow;
      final activities = row.entries.toSubAgentActivityPresentations();
      expect(
        activities.map((agent) => agent.name),
        everyElement('Check loading placement'),
      );
      expect(activities.map((agent) => agent.activityLabel), [
        '开始工作',
        '已完成',
        '发送消息',
      ]);
      expect(activities.map((agent) => agent.isMessageActivity), [
        false,
        false,
        true,
      ]);
      expect(entries.toBackgroundSubAgentPresentations(), hasLength(1));
    },
  );

  test('activity names survive separating messages and missing paths', () {
    final rows = <TimelineEntry>[
      _agent('start', 'child', 'turn', 'running', path: '/root/review'),
      _entry('answer', TimelineKind.agentMessage, turnId: 'turn'),
      _agent('finish', 'child', 'turn', 'completed', path: ''),
    ].toTimelineRenderRows();
    final activity = (rows.last as SubAgentTimelineRenderRow).entries
        .toSubAgentActivityPresentations()
        .single;
    expect(activity.name, 'review');
  });

  test(
    'parent messages remain informational and are not child index entries',
    () {
      final entries = [
        _agent(
          'parent-message',
          'parent',
          'turn',
          'completed',
          activity: 'sendMessageToParent',
          path: '/root',
        ),
      ];
      final activity = entries.toSubAgentActivityPresentations().single;
      expect(activity.activityLabel, '已向父代理发送消息');
      expect(activity.isMessageActivity, isTrue);
      expect(activity.isOpenable, isFalse);
      expect(entries.toBackgroundSubAgentPresentations(), isEmpty);
    },
  );

  test('avatar color uses deterministic identity hashing', () {
    expect(subAgentAvatarColorIndex('', 7), 2);
    expect(subAgentAvatarColorIndex('child', 7), 0);
  });

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
    'formats generated snake case names for display without changing paths',
    () {
      final agent = <TimelineEntry>[
        _agent(
          'agent',
          'child-thread',
          'turn',
          'running',
          path: 'team/force_takeover__design',
        ),
      ].toSubAgentPresentations().single;

      expect(agent.name, 'force takeover design');
      expect(agent.path, 'team/force_takeover__design');
    },
  );

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

  test('a late interrupted terminal update cannot replace completed', () {
    final agent = <TimelineEntry>[
      _agent('completed', 'thread', 'turn', 'completed'),
      _agent('late-interrupted', 'thread', 'turn', 'interrupted'),
    ].toSubAgentPresentations().single;

    expect(agent.status, SubAgentDisplayStatus.completed);
    expect(agent.status.label, '已完成');
  });

  test('a later turn can reactivate a completed agent', () {
    final agent = <TimelineEntry>[
      _agent('completed', 'thread', 'turn-1', 'completed'),
      _agent('resumed', 'thread', 'turn-2', 'running', activity: 'started'),
    ].toSubAgentPresentations().single;

    expect(agent.status, SubAgentDisplayStatus.started);
    expect(agent.status.label, '已开始工作');
    expect(agent.turnId, 'turn-2');
  });

  test(
    'explicit follow-up and resume restart completed work in the same parent turn',
    () {
      for (final tool in ['sendInput', 'resumeAgent']) {
        final agent = <TimelineEntry>[
          _agent('completed', 'thread', 'turn', 'completed'),
          _agent('new-task', 'thread', 'turn', 'running', activity: tool),
        ].toSubAgentPresentations().single;
        expect(agent.status, SubAgentDisplayStatus.working, reason: tool);
        expect(agent.showsProgressIndicator, isTrue, reason: tool);
      }
    },
  );

  test('accumulates composer agents across parent turns', () {
    final entries = <TimelineEntry>[
      _agent('old-a', 'old-a', 'turn-old', 'completed'),
      _agent('old-b', 'old-b', 'turn-old', 'completed'),
      _agent('old-c', 'old-c', 'turn-old', 'completed'),
      _agent('current-a', 'current-a', 'turn-current', 'running'),
      _agent('current-b', 'current-b', 'turn-current', 'running'),
      _agent('current-c', 'current-c', 'turn-current', 'running'),
    ];

    final agents = entries.toBackgroundSubAgentPresentations();

    expect(agents, hasLength(6));
    expect(agents.map((agent) => agent.threadId).toSet(), <String>{
      'old-a',
      'old-b',
      'old-c',
      'current-a',
      'current-b',
      'current-c',
    });
  });

  test('keeps completed agents visible while the next turn starts', () {
    final agents = <TimelineEntry>[
      _agent('old-a', 'old-a', 'turn-old', 'completed'),
      _agent('old-b', 'old-b', 'turn-old', 'completed'),
    ].toBackgroundSubAgentPresentations();

    expect(agents.map((agent) => agent.threadId).toSet(), <String>{
      'old-a',
      'old-b',
    });
  });

  test('does not count unconfirmed creation attempts as background agents', () {
    final agents = <TimelineEntry>[
      _agent('attempt-a', '', 'turn-current', 'running', activity: 'started'),
      _agent('attempt-b', '', 'turn-current', 'running', activity: 'started'),
      _agent('confirmed', 'child-thread', 'turn-current', 'running'),
    ].toBackgroundSubAgentPresentations();

    expect(agents.map((agent) => agent.threadId), <String>['child-thread']);
  });

  test('deduplicates the same child thread across parent turns', () {
    final agents = <TimelineEntry>[
      _agent('old', 'shared', 'turn-old', 'completed'),
      _agent('latest', 'shared', 'turn-latest', 'running'),
    ].toBackgroundSubAgentPresentations();

    expect(agents, hasLength(1));
    expect(agents.single.threadId, 'shared');
    expect(agents.single.turnId, 'turn-latest');
    expect(agents.single.status, SubAgentDisplayStatus.working);
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

  test('status-only updates preserve the collaborator name and path', () {
    final agent = <TimelineEntry>[
      _agent(
        'created',
        'thread-with-id',
        'turn',
        'running',
        path: '/root/review',
      ),
      _agent('finished', 'thread-with-id', 'turn', 'completed', path: ''),
    ].toSubAgentPresentations().single;
    expect(agent.name, 'review');
    expect(agent.path, '/root/review');
    expect(agent.status, SubAgentDisplayStatus.completed);
  });

  test('failed creation is reported as failed and remains unopenable', () {
    final group = <TimelineEntry>[
      _agent('failed-attempt', '', 'turn', 'errored'),
    ].toSubAgentActivityGroupPresentation();
    expect(group.status, SubAgentDisplayStatus.failed);
    expect(group.isActive, isFalse);
    expect(group.agents.single.isOpenable, isFalse);
    expect(group.agents.single.showsProgressIndicator, isFalse);
  });

  test('same display name never merges different thread identities', () {
    final agents = <TimelineEntry>[
      _agent('one', 'thread-one', 'turn', 'completed', path: '/root/a/review'),
      _agent('two', 'thread-two', 'turn', 'running', path: '/root/b/review'),
    ].toSubAgentPresentations();
    expect(agents, hasLength(2));
    expect(agents.map((agent) => agent.name), ['review', 'review']);
    expect(agents.map((agent) => agent.threadId).toSet(), {
      'thread-one',
      'thread-two',
    });
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
