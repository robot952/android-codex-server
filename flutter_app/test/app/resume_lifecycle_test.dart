import 'dart:async';

import 'package:codex_remote/src/agent/agent_connection_manager.dart';
import 'package:codex_remote/src/agent/codex_protocol.dart';
import 'package:codex_remote/src/agent/remote_agent_client.dart';
import 'package:codex_remote/src/agent/remote_bootstrap.dart';
import 'package:codex_remote/src/agent/thread_session_cache.dart';
import 'package:codex_remote/src/app/app_controller.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/persistence/profile_store.dart';
import 'package:codex_remote/src/persistence/thread_snapshot_store.dart';
import 'package:codex_remote/src/platform/turn_completion_notifications.dart';
import 'package:codex_remote/src/ssh/server_connection_manager.dart';
import 'package:codex_remote/src/ssh/ssh_server_client.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

const _profile = ServerProfile(
  id: 'server',
  name: 'Server',
  host: 'server.example',
  username: 'root',
  authMode: AuthMode.password,
  password: 'secret',
  hostFingerprint: 'SHA256:test',
  workspacePromptShown: true,
);

const _threadA = AgentThread(
  id: 'thread-a',
  title: 'Thread A',
  source: 'appServer',
  status: 'idle',
  updatedAt: 10,
);
const _threadAActive = AgentThread(
  id: 'thread-a',
  title: 'Thread A',
  source: 'appServer',
  status: 'active',
  activeTurnId: 'turn-a',
  updatedAt: 10,
);
const _threadB = AgentThread(
  id: 'thread-b',
  title: 'Thread B',
  source: 'appServer',
  status: 'idle',
  updatedAt: 20,
);

void main() {
  test(
    'updated latest user-only page retains overlapping older context',
    () async {
      final agent = _ResumeAgent(threads: const [_threadA]);
      final harness = await _createHarness(agent);
      final first = agent.gateNextResume(_threadA.id);
      harness.controller.openThread(_threadA);
      await _waitUntil(() => agent.resumeCalls.length == 1);
      first.complete(
        const AgentSession(
          thread: _threadA,
          timeline: [
            TimelineEntry(
              id: 'earlier-answer',
              kind: TimelineKind.agentMessage,
              text: 'earlier context',
              turnId: 'turn-earlier',
            ),
            TimelineEntry(
              id: 'latest-question',
              kind: TimelineKind.userMessage,
              text: 'latest question',
              turnId: 'turn-a',
            ),
          ],
          nextTurnsCursor: 'before-earlier',
          turnIds: ['turn-earlier', 'turn-a'],
        ),
      );
      await _waitUntil(() => !harness.controller.state.loading);
      harness.controller.backToThreadList();

      final updated = _threadAActive.copyWith(updatedAt: 11);
      final latest = agent.gateNextResume(_threadA.id);
      harness.controller.openThread(updated);
      await _waitUntil(() => agent.resumeCalls.length == 2);
      latest.complete(
        AgentSession(
          thread: updated,
          timeline: const [
            TimelineEntry(
              id: 'latest-question',
              kind: TimelineKind.userMessage,
              text: 'latest question',
              turnId: 'turn-a',
            ),
          ],
          nextTurnsCursor: 'fresh-before-a',
          turnIds: const ['turn-a'],
        ),
      );
      await _waitUntil(() => !harness.controller.state.loading);
      await _drainAsyncWork();

      expect(harness.controller.state.timeline.map((entry) => entry.text), [
        'earlier context',
        'latest question',
      ]);
      expect(harness.controller.state.olderTurnsCursor, 'fresh-before-a');
      expect(harness.controller.state.running, isTrue);
      expect(agent.olderCalls, isEmpty);
    },
  );

  test(
    'cold user-only history opens before one automatic older page',
    () async {
      final agent = _ResumeAgent(threads: const [_threadAActive]);
      final harness = await _createHarness(agent);
      final first = agent.gateNextResume(_threadA.id);
      final older = agent.gateNextOlderTurns(_threadA.id);
      harness.controller.openThread(_threadAActive);
      await _waitUntil(() => agent.resumeCalls.length == 1);
      first.complete(
        const AgentSession(
          thread: _threadAActive,
          timeline: [
            TimelineEntry(
              id: 'latest-question',
              kind: TimelineKind.userMessage,
              text: 'latest question',
              turnId: 'turn-a',
            ),
          ],
          nextTurnsCursor: 'before-a',
          turnIds: ['turn-a'],
        ),
      );
      await _waitUntil(
        () => !harness.controller.state.loading && agent.olderCalls.length == 1,
      );

      expect(harness.controller.state.screen, AppScreen.work);
      expect(harness.controller.state.timeline.single.text, 'latest question');
      expect(harness.controller.state.olderTurnsLoading, isTrue);
      expect(harness.controller.state.running, isTrue);
      expect(agent.olderCalls.single, (
        threadId: _threadA.id,
        cursor: 'before-a',
      ));
      older.complete(
        const AgentTurnsPage(
          timeline: [
            TimelineEntry(
              id: 'earlier-question',
              kind: TimelineKind.userMessage,
              text: 'earlier question',
              turnId: 'turn-earlier',
            ),
          ],
          nextCursor: 'before-earlier',
          turnIds: ['turn-earlier'],
        ),
      );
      await _waitUntil(() => !harness.controller.state.olderTurnsLoading);
      await _drainAsyncWork();

      expect(harness.controller.state.timeline.map((entry) => entry.text), [
        'earlier question',
        'latest question',
      ]);
      expect(harness.controller.state.olderTurnsCursor, 'before-earlier');
      expect(
        agent.olderCalls,
        hasLength(1),
        reason:
            'automatic backfill must remain bounded even if all rows are users',
      );
    },
  );

  test(
    'automatic older-page failure keeps history and permits manual retry',
    () async {
      final agent = _ResumeAgent(threads: const [_threadAActive]);
      final harness = await _createHarness(agent);
      final first = agent.gateNextResume(_threadA.id);
      final older = agent.gateNextOlderTurns(_threadA.id);
      harness.controller.openThread(_threadAActive);
      await _waitUntil(() => agent.resumeCalls.length == 1);
      first.complete(
        const AgentSession(
          thread: _threadAActive,
          timeline: [
            TimelineEntry(
              id: 'latest-question',
              kind: TimelineKind.userMessage,
              text: 'latest question',
              turnId: 'turn-a',
            ),
          ],
          nextTurnsCursor: 'before-a',
          turnIds: ['turn-a'],
        ),
      );
      await _waitUntil(() => agent.olderCalls.length == 1);
      older.completeError(StateError('temporary history failure'));
      await _waitUntil(() => !harness.controller.state.olderTurnsLoading);
      await _drainAsyncWork();

      expect(harness.controller.state.loading, isFalse);
      expect(harness.controller.state.timeline.single.text, 'latest question');
      expect(harness.controller.state.olderTurnsCursor, 'before-a');
      expect(harness.controller.state.error, isNull);
      expect(agent.olderCalls, hasLength(1));

      final retry = agent.gateNextOlderTurns(_threadA.id);
      final retryFuture = harness.controller.loadOlderTurns();
      await _waitUntil(() => agent.olderCalls.length == 2);
      expect(agent.olderCalls.last, (
        threadId: _threadA.id,
        cursor: 'before-a',
      ));
      retry.complete(
        const AgentTurnsPage(
          timeline: [
            TimelineEntry(
              id: 'earlier-answer',
              kind: TimelineKind.agentMessage,
              text: 'earlier context',
              turnId: 'turn-earlier',
            ),
          ],
          turnIds: ['turn-earlier'],
        ),
      );
      await retryFuture;
      expect(harness.controller.state.timeline.map((entry) => entry.text), [
        'earlier context',
        'latest question',
      ]);
      expect(harness.controller.state.olderTurnsCursor, isNull);
      expect(harness.controller.state.olderTurnsLoading, isFalse);
    },
  );

  test(
    'same-thread reentry discards an earlier pending history backfill',
    () async {
      final agent = _ResumeAgent(threads: const [_threadAActive]);
      final harness = await _createHarness(agent);
      final first = agent.gateNextResume(_threadA.id);
      final oldPage = agent.gateNextOlderTurns(_threadA.id);
      harness.controller.openThread(_threadAActive);
      await _waitUntil(() => agent.resumeCalls.length == 1);
      first.complete(
        const AgentSession(
          thread: _threadAActive,
          timeline: [
            TimelineEntry(
              id: 'latest-question',
              kind: TimelineKind.userMessage,
              text: 'latest question',
              turnId: 'turn-a',
            ),
          ],
          nextTurnsCursor: 'before-a',
          turnIds: ['turn-a'],
        ),
      );
      await _waitUntil(() => agent.olderCalls.length == 1);
      harness.controller.backToThreadList();

      final second = agent.gateNextResume(_threadA.id);
      harness.controller.openThread(_threadAActive);
      await _waitUntil(() => agent.resumeCalls.length == 2);
      second.complete(
        AgentSession(
          thread: _threadAActive.copyWith(updatedAt: 11),
          timeline: const [
            TimelineEntry(
              id: 'latest-question',
              kind: TimelineKind.userMessage,
              text: 'latest question',
              turnId: 'turn-a',
            ),
            TimelineEntry(
              id: 'new-answer',
              kind: TimelineKind.agentMessage,
              text: 'new answer',
              turnId: 'turn-a',
            ),
          ],
          nextTurnsCursor: 'before-a',
          turnIds: const ['turn-a'],
        ),
      );
      await _waitUntil(() => !harness.controller.state.loading);
      expect(harness.controller.state.olderTurnsLoading, isFalse);
      final currentTimeline = harness.controller.state.timeline;

      oldPage.complete(
        const AgentTurnsPage(
          timeline: [
            TimelineEntry(
              id: 'obsolete-answer',
              kind: TimelineKind.agentMessage,
              text: 'obsolete history',
              turnId: 'turn-obsolete',
            ),
          ],
          nextCursor: 'obsolete-cursor',
          turnIds: ['turn-obsolete'],
        ),
      );
      await _drainAsyncWork();
      expect(harness.controller.state.timeline, currentTimeline);
      expect(harness.controller.state.olderTurnsCursor, 'before-a');
      expect(harness.controller.state.olderTurnsLoading, isFalse);

      harness.controller.backToThreadList();
      final inspectCache = agent.gateNextResume(_threadA.id);
      harness.controller.openThread(_threadAActive);
      await _waitUntil(() => agent.resumeCalls.length == 3);
      expect(harness.controller.state.timeline, currentTimeline);
      inspectCache.complete(
        AgentSession(
          thread: _threadAActive,
          timeline: currentTimeline,
          nextTurnsCursor: 'before-a',
          turnIds: const ['turn-a'],
        ),
      );
      await _waitUntil(() => !harness.controller.state.loading);
    },
  );

  test(
    'reconnect replaces pending history loading without stale completion',
    () async {
      final agent = _ResumeAgent(threads: const [_threadAActive]);
      final harness = await _createHarness(agent);
      final first = agent.gateNextResume(_threadA.id);
      final obsoletePage = agent.gateNextOlderTurns(_threadA.id);
      const latestSession = AgentSession(
        thread: _threadAActive,
        timeline: [
          TimelineEntry(
            id: 'latest-question',
            kind: TimelineKind.userMessage,
            text: 'latest question',
            turnId: 'turn-a',
          ),
        ],
        nextTurnsCursor: 'before-a',
        turnIds: ['turn-a'],
      );
      harness.controller.openThread(_threadAActive);
      await _waitUntil(() => agent.resumeCalls.length == 1);
      first.complete(latestSession);
      await _waitUntil(() => agent.olderCalls.length == 1);
      expect(harness.controller.state.olderTurnsLoading, isTrue);

      final reconnectResume = agent.gateNextResume(_threadA.id);
      final currentPage = agent.gateNextOlderTurns(_threadA.id);
      agent.emitLoss('Codex channel closed');
      await _waitUntil(() => agent.resumeCalls.length == 2);
      expect(harness.controller.state.screen, AppScreen.work);
      expect(harness.controller.state.loading, isTrue);
      expect(harness.controller.state.olderTurnsLoading, isFalse);
      reconnectResume.complete(latestSession);
      await _waitUntil(() => agent.olderCalls.length == 2);
      expect(harness.controller.state.loading, isFalse);
      expect(harness.controller.state.olderTurnsLoading, isTrue);

      obsoletePage.complete(
        const AgentTurnsPage(
          timeline: [
            TimelineEntry(
              id: 'obsolete-history',
              kind: TimelineKind.agentMessage,
              text: 'must not be applied',
              turnId: 'turn-obsolete',
            ),
          ],
          nextCursor: 'obsolete-cursor',
          turnIds: ['turn-obsolete'],
        ),
      );
      await _drainAsyncWork();
      expect(harness.controller.state.timeline, latestSession.timeline);
      expect(harness.controller.state.olderTurnsCursor, 'before-a');
      expect(harness.controller.state.olderTurnsLoading, isTrue);
      expect(harness.controller.state.error, isNull);

      currentPage.complete(
        const AgentTurnsPage(
          timeline: [
            TimelineEntry(
              id: 'earlier-answer',
              kind: TimelineKind.agentMessage,
              text: 'earlier context',
              turnId: 'turn-earlier',
            ),
          ],
          nextCursor: 'before-earlier',
          turnIds: ['turn-earlier'],
        ),
      );
      await _waitUntil(() => !harness.controller.state.olderTurnsLoading);
      expect(harness.controller.state.timeline.map((entry) => entry.text), [
        'earlier context',
        'latest question',
      ]);
      expect(harness.controller.state.olderTurnsCursor, 'before-earlier');
      expect(harness.controller.state.running, isTrue);
    },
  );

  test('live newer item wins an overlapping delayed older page', () async {
    final agent = _ResumeAgent(threads: const [_threadAActive]);
    final harness = await _createHarness(agent);
    final first = agent.gateNextResume(_threadA.id);
    harness.controller.openThread(_threadAActive);
    await _waitUntil(() => agent.resumeCalls.length == 1);
    first.complete(
      const AgentSession(
        thread: _threadAActive,
        timeline: [
          TimelineEntry(
            id: 'answer',
            kind: TimelineKind.agentMessage,
            text: 'initial',
            turnId: 'turn-a',
          ),
        ],
        nextTurnsCursor: 'before-a',
        turnIds: ['turn-a'],
      ),
    );
    await _waitUntil(() => !harness.controller.state.loading);
    final older = agent.gateNextOlderTurns(_threadA.id);
    final loading = harness.controller.loadOlderTurns();
    await _waitUntil(() => agent.olderCalls.length == 1);
    agent.emit(
      _notification(
        'item/agentMessage/delta',
        threadId: _threadA.id,
        turnId: 'turn-a',
        itemId: 'answer',
        delta: ' latest',
        sequence: 1,
      ),
    );
    await _waitUntil(
      () => harness.controller.state.timeline.single.text == 'initial latest',
    );
    older.complete(
      const AgentTurnsPage(
        timeline: [
          TimelineEntry(
            id: 'older-answer',
            kind: TimelineKind.agentMessage,
            text: 'older context',
            turnId: 'turn-earlier',
          ),
          TimelineEntry(
            id: 'answer',
            kind: TimelineKind.agentMessage,
            text: 'initial',
            turnId: 'turn-a',
          ),
        ],
        nextCursor: 'before-earlier',
        turnIds: ['turn-earlier', 'turn-a'],
      ),
    );
    await loading;
    expect(harness.controller.state.timeline.map((entry) => entry.text), [
      'older context',
      'initial latest',
    ]);
    expect(harness.controller.state.olderTurnsCursor, 'before-earlier');
    expect(harness.controller.state.running, isTrue);
  });

  test(
    'warm history preserves start time across another conversation',
    () async {
      final agent = _ReusableResumeAgent(
        threads: const [_threadAActive, _threadB],
      );
      final harness = await _createHarness(agent);
      final startedAt = DateTime.now().millisecondsSinceEpoch - 60000;
      final first = agent.gateNextResume(_threadA.id);
      harness.controller.openThread(_threadAActive);
      await _waitUntil(() => agent.resumeCalls.isNotEmpty);
      first.complete(
        AgentSession(
          thread: _threadAActive,
          timeline: const [
            TimelineEntry(
              id: 'm',
              kind: TimelineKind.agentMessage,
              text: 'running',
              turnId: 'turn-a',
            ),
          ],
          activeTurnStartedAtMillis: startedAt,
        ),
      );
      await _waitUntil(() => !harness.controller.state.loading);
      harness.controller.backToThreadList();
      harness.controller.openThread(_threadB);
      await _waitUntil(
        () =>
            harness.controller.state.activeThread?.id == _threadB.id &&
            !harness.controller.state.loading,
      );
      harness.controller.backToThreadList();
      harness.controller.openThread(_threadAActive);
      await _waitUntil(
        () =>
            harness.controller.state.activeThread?.id == _threadA.id &&
            !harness.controller.state.loading,
      );
      expect(harness.controller.state.turnTiming?.startedAtMillis, startedAt);
      expect(harness.controller.state.running, isTrue);
      expect(agent.resumeCalls.where((id) => id == _threadA.id).length, 1);
    },
  );

  test(
    'revalidation left mid-flight cannot revive an older reuse proof',
    () async {
      final agent = _ReusableResumeAgent(threads: const [_threadA]);
      final harness = await _createHarness(agent);
      final first = agent.gateNextResume(_threadA.id);
      harness.controller.openThread(_threadA);
      await _waitUntil(() => agent.resumeCalls.isNotEmpty);
      first.complete(
        const AgentSession(
          thread: _threadA,
          timeline: [
            TimelineEntry(
              id: 'm',
              kind: TimelineKind.agentMessage,
              text: 'old history',
            ),
          ],
        ),
      );
      await _waitUntil(() => !harness.controller.state.loading);
      harness.controller.backToThreadList();
      agent.reusable = false;
      final revalidation = agent.gateNextResume(_threadA.id);
      harness.controller.openThread(_threadA);
      await _waitUntil(() => agent.resumeCalls.length == 2);
      harness.controller.backToThreadList();
      agent.reusable = true;
      revalidation.complete(
        const AgentSession(
          thread: _threadA,
          timeline: [
            TimelineEntry(
              id: 'm',
              kind: TimelineKind.agentMessage,
              text: 'new history',
            ),
          ],
        ),
      );
      await _drainAsyncWork();
      final last = agent.gateNextResume(_threadA.id);
      harness.controller.openThread(_threadA);
      await _waitUntil(() => agent.resumeCalls.length == 3);
      last.complete(const AgentSession(thread: _threadA, timeline: []));
      await _waitUntil(() => !harness.controller.state.loading);
    },
  );

  for (final wrongThread in [false, true]) {
    test(
      'disk preview rejects ${wrongThread ? 'another thread' : 'another provider'}',
      () async {
        final snapshots = _SnapshotStore();
        final agent = _ResumeAgent(threads: const [_threadA]);
        final harness = await _createHarness(agent, snapshots: snapshots);
        final resume = agent.gateNextResume(_threadA.id);
        harness.controller.openThread(_threadA);
        await _waitUntil(() => snapshots.reads.isNotEmpty);
        snapshots.reads.first.complete(
          ThreadSessionSnapshot(
            thread: wrongThread
                ? _threadB
                : _threadA.copyWith(modelProvider: 'different'),
            timeline: const [
              TimelineEntry(
                id: 'old',
                kind: TimelineKind.agentMessage,
                text: 'must not leak',
              ),
            ],
            savedAtEpochMillis: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        await _drainAsyncWork();
        expect(harness.controller.state.timeline, isEmpty);
        expect(harness.controller.state.loading, isTrue);
        resume.complete(const AgentSession(thread: _threadA, timeline: []));
        await _waitUntil(() => !harness.controller.state.loading);
      },
    );
  }

  test(
    'memory snapshot after connection generation changes must resume',
    () async {
      final agent = _ReusableResumeAgent(threads: const [_threadA]);
      final harness = await _createHarness(agent);
      final first = agent.gateNextResume(_threadA.id);
      harness.controller.openThread(_threadA);
      await _waitUntil(() => agent.resumeCalls.isNotEmpty);
      first.complete(
        const AgentSession(
          thread: _threadA,
          timeline: [
            TimelineEntry(
              id: 'm',
              kind: TimelineKind.agentMessage,
              text: 'before reconnect',
            ),
          ],
        ),
      );
      await _waitUntil(() => !harness.controller.state.loading);
      harness.controller.backToThreadList();
      agent.remoteGeneration++;
      final second = agent.gateNextResume(_threadA.id);
      harness.controller.openThread(_threadA);
      await _waitUntil(() => agent.resumeCalls.length == 2);
      expect(harness.controller.state.loading, isTrue);
      expect(harness.controller.state.timeline.single.text, 'before reconnect');
      second.complete(const AgentSession(thread: _threadA, timeline: []));
      await _waitUntil(() => !harness.controller.state.loading);
    },
  );

  test(
    'rapid leave and reopen shares pending fetch and keeps latest route',
    () async {
      final agent = _ResumeAgent(threads: const [_threadA, _threadB]);
      final harness = await _createHarness(agent);
      final resume = agent.gateNextResume(_threadA.id);
      harness.controller.openThread(_threadA);
      await _waitUntil(() => agent.resumeCalls.length == 1);
      for (var i = 0; i < 3; i++) {
        harness.controller.backToThreadList();
        harness.controller.openThread(_threadA);
        await _drainAsyncWork();
      }
      expect(agent.resumeCalls, [_threadA.id]);
      resume.complete(
        const AgentSession(
          thread: _threadA,
          timeline: [
            TimelineEntry(
              id: 'answer',
              kind: TimelineKind.agentMessage,
              text: 'latest',
            ),
          ],
        ),
      );
      await _waitUntil(() => !harness.controller.state.loading);
      expect(harness.controller.state.screen, AppScreen.work);
      expect(harness.controller.state.timeline.single.text, 'latest');
    },
  );

  test(
    'live warm cache avoids another fetch and includes background output',
    () async {
      final agent = _ReusableResumeAgent(threads: const [_threadAActive]);
      final harness = await _createHarness(agent);
      final resume = agent.gateNextResume(_threadA.id);
      harness.controller.openThread(_threadAActive);
      await _waitUntil(() => agent.resumeCalls.isNotEmpty);
      resume.complete(
        const AgentSession(
          thread: _threadAActive,
          timeline: [
            TimelineEntry(
              id: 'answer',
              kind: TimelineKind.agentMessage,
              text: 'hello',
              turnId: 'turn-a',
            ),
          ],
        ),
      );
      await _waitUntil(() => !harness.controller.state.loading);
      harness.controller.backToThreadList();
      agent.emit(
        _notificationWithParams('item/agentMessage/delta', {
          'threadId': _threadA.id,
          'turnId': 'turn-a',
          'itemId': 'answer',
          'delta': ' world',
        }),
      );
      await _drainAsyncWork();
      harness.controller.openThread(_threadAActive);
      await _waitUntil(() => harness.controller.state.screen == AppScreen.work);
      await _waitUntil(() => !harness.controller.state.loading);
      expect(harness.controller.state.loading, isFalse);
      expect(agent.resumeCalls, [_threadA.id]);
      expect(harness.controller.state.timeline.single.text, 'hello world');
      expect(harness.controller.state.running, isTrue);
      // Loss of the actual subscription forces verification even with a snapshot.
      harness.controller.backToThreadList();
      agent.reusable = false;
      final recheck = agent.gateNextResume(_threadA.id);
      harness.controller.openThread(_threadAActive);
      await _waitUntil(() => agent.resumeCalls.length == 2);
      expect(harness.controller.state.loading, isTrue);
      recheck.complete(
        AgentSession(
          thread: _threadA.copyWith(isExternallyOwned: true),
          timeline: const [],
        ),
      );
      await _waitUntil(() => !harness.controller.state.loading);
      expect(harness.controller.state.isThreadReadOnly, isTrue);
    },
  );

  test(
    'disk snapshot paints before server but cannot unlock or replace fresh reply',
    () async {
      final snapshots = _SnapshotStore();
      final agent = _ResumeAgent(threads: const [_threadA, _threadB]);
      final harness = await _createHarness(agent, snapshots: snapshots);
      final resume = agent.gateNextResume(_threadA.id);
      harness.controller.openThread(_threadA);
      await _waitUntil(() => snapshots.reads.length == 1);
      snapshots.reads.single.complete(
        ThreadSessionSnapshot(
          thread: _threadA,
          timeline: const [
            TimelineEntry(
              id: 'saved',
              kind: TimelineKind.agentMessage,
              text: 'cached',
            ),
          ],
          savedAtEpochMillis: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      await _waitUntil(() => harness.controller.state.timeline.isNotEmpty);
      expect(harness.controller.state.loading, isTrue);
      expect(harness.controller.state.approvalQueue, isEmpty);
      resume.complete(
        AgentSession(
          thread: _threadA.copyWith(isExternallyOwned: true),
          timeline: const [
            TimelineEntry(
              id: 'saved',
              kind: TimelineKind.agentMessage,
              text: 'fresh',
            ),
          ],
        ),
      );
      await _waitUntil(() => !harness.controller.state.loading);
      expect(harness.controller.state.isThreadReadOnly, isTrue);
      expect(harness.controller.state.timeline.single.text, 'fresh');

      harness.controller.backToThreadList();
      final next = agent.gateNextResume(_threadB.id);
      harness.controller.openThread(_threadB);
      await _waitUntil(() => snapshots.reads.length == 2);
      next.complete(
        const AgentSession(
          thread: _threadB,
          timeline: [
            TimelineEntry(
              id: 'new',
              kind: TimelineKind.agentMessage,
              text: 'new server data',
            ),
          ],
        ),
      );
      await _waitUntil(() => !harness.controller.state.loading);
      snapshots.reads.last.complete(
        ThreadSessionSnapshot(
          thread: _threadB,
          timeline: const [
            TimelineEntry(
              id: 'old',
              kind: TimelineKind.agentMessage,
              text: 'old disk',
            ),
          ],
          savedAtEpochMillis: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      await _drainAsyncWork();
      expect(harness.controller.state.timeline.single.text, 'new server data');
    },
  );

  test(
    'disk read finishing after navigation cannot paint another thread',
    () async {
      final snapshots = _SnapshotStore();
      final agent = _ResumeAgent(threads: const [_threadA, _threadB]);
      final harness = await _createHarness(agent, snapshots: snapshots);
      final resume = agent.gateNextResume(_threadA.id);
      harness.controller.openThread(_threadA);
      await _waitUntil(() => snapshots.reads.isNotEmpty);
      harness.controller.backToThreadList();
      harness.controller.openThread(_threadB);
      await _waitUntil(
        () => harness.controller.state.activeThread?.id == _threadB.id,
      );
      snapshots.reads.first.complete(
        ThreadSessionSnapshot(
          thread: _threadA,
          timeline: const [
            TimelineEntry(
              id: 'old',
              kind: TimelineKind.agentMessage,
              text: 'wrong thread',
            ),
          ],
          savedAtEpochMillis: 0,
        ),
      );
      resume.complete(const AgentSession(thread: _threadA, timeline: []));
      await _drainAsyncWork();
      expect(harness.controller.state.activeThread?.id, _threadB.id);
      expect(
        harness.controller.state.timeline.any((e) => e.text == 'wrong thread'),
        isFalse,
      );
      for (final read in snapshots.reads) {
        if (!read.isCompleted) read.complete(null);
      }
    },
  );
  test('double tapping a conversation starts only one resume', () async {
    final agent = _ResumeAgent(threads: const [_threadA, _threadB]);
    final harness = await _createHarness(agent);
    final resume = agent.gateNextResume(_threadA.id);
    harness.controller.openThread(_threadA);
    harness.controller.openThread(_threadA);
    await _waitUntil(() => agent.resumeCalls.isNotEmpty);
    harness.controller.openThread(_threadA);
    await Future<void>.delayed(Duration.zero);
    expect(agent.resumeCalls, [_threadA.id]);
    expect(harness.controller.state.loading, isTrue);
    resume.complete(const AgentSession(thread: _threadA, timeline: []));
    await _waitUntil(() => !harness.controller.state.loading);
    expect(harness.controller.state.screen, AppScreen.work);
    expect(harness.controller.state.activeThread?.id, _threadA.id);
  });

  test(
    'opening during initial runtime preparation waits without failing',
    () async {
      final agent = _RuntimeResumeAgent(threads: const [_threadA, _threadB]);
      agent.inspectGate = Completer<void>();
      final harness = await _createHarness(agent, waitForAgent: false);
      await _waitUntil(() => agent.inspectCalls == 1);
      harness.controller.openThread(_threadA);
      await _waitUntil(() => harness.controller.state.screen == AppScreen.work);
      expect(harness.controller.state.loading, isTrue);
      expect(harness.controller.state.error, isNull);
      expect(agent.resumeCalls, isEmpty);
      agent.inspectGate!.complete();
      await _waitUntil(() => !harness.controller.state.loading);
      expect(harness.controller.state.screen, AppScreen.work);
      expect(harness.controller.state.activeThread?.id, _threadA.id);
      expect(harness.controller.state.error, isNull);
      expect(agent.resumeCalls, [_threadA.id]);
    },
  );

  test('rapid selection keeps only the latest navigation target', () async {
    final agent = _ResumeAgent(threads: const [_threadA, _threadB]);
    final harness = await _createHarness(agent);
    final resume = agent.gateNextResume(_threadB.id);
    harness.controller.openThread(_threadA);
    harness.controller.openThread(_threadB);
    await _waitUntil(() => agent.resumeCalls.isNotEmpty);
    expect(agent.resumeCalls, [_threadB.id]);
    expect(harness.controller.state.activeThread?.id, _threadB.id);
    expect(harness.controller.state.screen, AppScreen.work);
    resume.complete(const AgentSession(thread: _threadB, timeline: []));
    await _waitUntil(() => !harness.controller.state.loading);
    expect(harness.controller.state.screen, AppScreen.work);
    expect(harness.controller.state.activeThread?.id, _threadB.id);
  });

  test(
    'leaving before an open starts never reopens the conversation',
    () async {
      final agent = _ResumeAgent(threads: const [_threadA, _threadB]);
      final harness = await _createHarness(agent);
      harness.controller.openThread(_threadA);
      harness.controller.backToThreadList();
      await Future<void>.delayed(Duration.zero);
      expect(agent.resumeCalls, isEmpty);
      expect(harness.controller.state.screen, AppScreen.threads);
    },
  );

  for (final failList in [false, true]) {
    test(
      'list refresh does not block or unlock a pending resume; fail=$failList',
      () async {
        final agent = _RuntimeResumeAgent(threads: const [_threadA, _threadB]);
        final harness = await _createHarness(agent);
        expect(agent.inspectCalls, 1);
        harness.controller.openThread(_threadA);
        await _waitUntil(
          () =>
              harness.controller.state.screen == AppScreen.work &&
              !harness.controller.state.loading,
        );
        harness.controller.backToThreadList();
        if (failList) {
          await harness.controller.refreshThreads(silent: true);
        }
        agent.listGate = Completer<AgentThreadPage>();
        final refresh = harness.controller.refreshThreads();
        if (failList) {
          await _waitUntil(() => harness.controller.state.loading);
        }
        final resume = agent.gateNextResume(_threadB.id);
        harness.controller.openThread(_threadB);
        await _waitUntil(() => agent.resumeCalls.contains(_threadB.id));
        expect(
          agent.inspectCalls,
          1,
          reason: 'refresh must reuse the live runtime',
        );
        expect(harness.controller.state.loading, isTrue);
        if (failList) {
          agent.listGate!.completeError(StateError('list failed'));
        } else {
          agent.listGate!.complete(AgentThreadPage(threads: agent.threads));
        }
        await refresh;
        expect(
          harness.controller.state.loading,
          isTrue,
          reason: 'list completion must not enable the composer before resume',
        );
        expect(harness.controller.state.activeThread?.id, _threadB.id);
        expect(harness.controller.state.diagnostic, isNull);
        expect(harness.controller.state.error, isNull);
        resume.complete(const AgentSession(thread: _threadB, timeline: []));
        await _waitUntil(() => !harness.controller.state.loading);
        expect(harness.controller.state.screen, AppScreen.work);
        expect(harness.controller.state.error, isNull);
      },
    );
  }

  test(
    'confirmed ownership remains read only when history cannot be read',
    () async {
      final agent = _ResumeAgent(threads: const [_threadA, _threadB]);
      final harness = await _createHarness(agent);
      final first = agent.gateNextResume(_threadA.id);
      harness.controller.openThread(_threadA);
      await _waitUntil(() => harness.controller.state.loading);
      first.complete(
        const AgentSession(
          thread: _threadA,
          timeline: [
            TimelineEntry(
              id: 'cached',
              kind: TimelineKind.agentMessage,
              text: 'Cached history',
            ),
          ],
        ),
      );
      await _waitUntil(() => !harness.controller.state.loading);
      harness.controller.backToThreadList();
      final blocked = agent.gateNextResume(_threadA.id);
      harness.controller.openThread(_threadA);
      await _waitUntil(() => harness.controller.state.loading);
      blocked.completeError(
        CodexThreadOwnedException(
          threadId: _threadA.id,
          ownershipError: const CodexRpcException(
            id: CodexRequestId.number(42),
            generation: 1,
            error: CodexRpcError(
              code: -32600,
              message: 'thread thread-a already has an active writer',
            ),
          ),
          readError: StateError('history unavailable'),
        ),
      );
      await _waitUntil(() => !harness.controller.state.loading);
      expect(harness.controller.state.isThreadReadOnly, isTrue);
      expect(harness.controller.state.timeline.single.text, 'Cached history');
      expect(harness.controller.state.error, isNull);
      expect(harness.controller.state.diagnostic, contains('无法读取最新内容'));
    },
  );

  test(
    'occupied threads preserve history and reject all work mutations',
    () async {
      final occupied = _threadAActive.copyWith(isExternallyOwned: true);
      final agent = _ResumeAgent(threads: [occupied, _threadB]);
      final draftKey = threadPreferenceKey(
        _profile.id,
        AgentKind.codex,
        occupied.id,
      );
      final harness = await _createHarness(
        agent,
        storedProfiles: StoredProfiles(
          profiles: const [_profile],
          selectedProfileId: _profile.id,
          composerDrafts: {draftKey: 'Keep my draft'},
        ),
      );
      final resume = agent.gateNextResume(occupied.id);
      harness.controller.openThread(_threadA);
      await _waitUntil(() => harness.controller.state.loading);
      resume.complete(
        AgentSession(
          thread: occupied,
          timeline: const [
            TimelineEntry(
              id: 'answer',
              kind: TimelineKind.agentMessage,
              text: 'History from the other app',
              turnId: 'turn-a',
            ),
          ],
        ),
      );
      await _waitUntil(() => !harness.controller.state.loading);

      final controller = harness.controller;
      expect(controller.state.screen, AppScreen.work);
      expect(controller.state.isThreadReadOnly, isTrue);
      expect(controller.state.running, isTrue);
      expect(
        controller.state.timeline.single.text,
        'History from the other app',
      );
      controller.setComposerDraft('must not replace draft');
      controller.selectThreadModel('must-not-select');
      await controller.selectApprovalMode(ApprovalMode.fullAccess);
      await controller.sendMessage(text: 'must not send');
      await controller.stopMessage();
      await controller.compactActiveThread();
      await controller.rollbackActiveThread();
      await controller.archiveActiveThread();
      await controller.renameActiveThread('must not rename');
      await controller.reviewChanges();
      await controller.setActiveGoal('must not set goal');
      await controller.answerApproval(true);
      expect(controller.state.composerDraft, 'Keep my draft');
      expect(
        controller.state.timeline.single.text,
        'History from the other app',
      );
      expect(controller.state.selectedModel, isNull);
      expect(controller.state.approvalMode, ApprovalMode.requestApproval);
      expect(controller.state.error, isNull);
      expect(controller.state.running, isTrue);
      expect(controller.state.activeThread!.title, _threadA.title);
      expect(controller.state.submitting, isFalse);
    },
  );

  test(
    'occupied retry stays locked until a successful resume and preserves draft',
    () async {
      final occupied = _threadA.copyWith(isExternallyOwned: true);
      final agent = _ResumeAgent(threads: [occupied, _threadB]);
      final draftKey = threadPreferenceKey(
        _profile.id,
        AgentKind.codex,
        occupied.id,
      );
      final harness = await _createHarness(
        agent,
        storedProfiles: StoredProfiles(
          profiles: const [_profile],
          selectedProfileId: _profile.id,
          composerDrafts: {draftKey: 'Unsent draft'},
        ),
      );
      final controller = harness.controller;
      controller.openThread(_threadA);
      await _waitUntil(
        () =>
            controller.state.screen == AppScreen.work &&
            !controller.state.loading,
      );
      expect(controller.state.isThreadReadOnly, isTrue);
      final blocked = agent.gateNextResume(occupied.id);
      await controller.retryActiveThread();
      expect(controller.state.loading, isTrue);
      expect(controller.state.isThreadReadOnly, isTrue);
      blocked.complete(AgentSession(thread: occupied, timeline: const []));
      await _waitUntil(() => !controller.state.loading);
      expect(controller.state.isThreadReadOnly, isTrue);

      final released = agent.gateNextResume(occupied.id);
      await controller.retryActiveThread();
      await controller.retryActiveThread();
      expect(controller.state.isThreadReadOnly, isTrue);
      released.complete(const AgentSession(thread: _threadA, timeline: []));
      await _waitUntil(() => !controller.state.loading);
      expect(controller.state.isThreadReadOnly, isFalse);
      expect(controller.state.composerDraft, 'Unsent draft');
      controller.backToThreadList();
      final inspect = agent.gateNextResume(occupied.id);
      controller.openThread(_threadA);
      await _waitUntil(() => controller.state.loading);
      expect(controller.state.isThreadReadOnly, isFalse);
      inspect.complete(const AgentSession(thread: _threadA, timeline: []));
      await _waitUntil(() => !controller.state.loading);
    },
  );

  test(
    'occupied thread refreshes its read-only transcript while open',
    () async {
      final occupied = _threadAActive.copyWith(isExternallyOwned: true);
      final agent = _ResumeAgent(threads: [occupied, _threadB]);
      final harness = await _createHarness(agent);
      final resume = agent.gateNextResume(occupied.id);
      harness.controller.openThread(_threadA);
      await _waitUntil(() => harness.controller.state.loading);
      resume.complete(
        AgentSession(
          thread: occupied,
          timeline: [
            TimelineEntry(
              id: 'before-refresh',
              kind: TimelineKind.agentMessage,
              text: '旧进度',
            ),
          ],
        ),
      );
      await _waitUntil(() => !harness.controller.state.loading);
      expect(harness.controller.state.isThreadReadOnly, isTrue);

      agent.readSessions[occupied.id] = AgentSession(
        thread: occupied.copyWith(updatedAt: 11),
        timeline: [
          TimelineEntry(
            id: 'after-refresh',
            kind: TimelineKind.agentMessage,
            text: '新进度',
          ),
        ],
      );
      await Future<void>.delayed(const Duration(milliseconds: 2200));
      expect(harness.controller.state.timeline.single.text, '新进度');
    },
  );

  test('late occupied retry never locks the next conversation', () async {
    final occupied = _threadA.copyWith(isExternallyOwned: true);
    final agent = _ResumeAgent(threads: [occupied, _threadB]);
    final harness = await _createHarness(agent);
    final controller = harness.controller;
    controller.openThread(occupied);
    await _waitUntil(
      () =>
          controller.state.screen == AppScreen.work &&
          !controller.state.loading,
    );
    final retry = agent.gateNextResume(occupied.id);
    await controller.retryActiveThread();
    controller.backToThreadList();
    controller.openThread(_threadB);
    await _waitUntil(
      () =>
          controller.state.activeThread?.id == _threadB.id &&
          !controller.state.loading,
    );
    retry.complete(AgentSession(thread: occupied, timeline: const []));
    await _drainAsyncWork();
    expect(controller.state.activeThread!.id, _threadB.id);
    expect(controller.state.isThreadReadOnly, isFalse);
  });

  test('returning to the list silently refreshes thread recency', () async {
    final agent = _ResumeAgent(threads: const [_threadA, _threadB]);
    final harness = await _createHarness(agent);
    expect(agent.listThreadsCount, 1);

    harness.controller.openThread(_threadA);
    await _waitUntil(
      () =>
          harness.controller.state.screen == AppScreen.work &&
          !harness.controller.state.loading,
    );
    agent.threads = const [
      AgentThread(
        id: 'thread-a',
        title: 'Thread A',
        preview: 'Updated preview',
        source: 'appServer',
        status: 'idle',
        updatedAt: 30,
      ),
      _threadB,
    ];

    harness.controller.backToThreadList();

    expect(harness.controller.state.screen, AppScreen.threads);
    expect(harness.controller.state.loading, isFalse);
    expect(harness.controller.state.threads, isNotEmpty);
    await _waitUntil(
      () =>
          agent.listThreadsCount == 2 &&
          harness.controller.state.threads.first.updatedAt == 30,
    );
    expect(harness.controller.state.threads.first.preview, 'Updated preview');
  });

  test('connection loss replays a buffered terminal event', () async {
    final agent = _ResumeAgent(threads: const [_threadAActive, _threadB]);
    final harness = await _createHarness(agent);
    final resume = agent.gateNextResume(_threadA.id);

    harness.controller.openThread(_threadAActive);
    await _waitUntil(
      () =>
          harness.controller.state.activeThread?.id == _threadA.id &&
          harness.controller.state.loading,
    );
    agent.emit(
      _notification(
        'turn/completed',
        threadId: _threadA.id,
        turnId: 'turn-a',
        sequence: 11,
      ),
    );

    final reconnectResume = agent.gateNextResume(_threadA.id);
    resume.completeError(StateError('channel closed'));
    agent.emitLoss('Codex channel closed');
    await _waitUntil(
      () =>
          harness.controller.state.loading &&
          harness.controller.state.activeThread?.status == 'idle',
    );

    expect(harness.controller.state.running, isFalse);
    expect(harness.controller.state.activeTurnId, isNull);
    expect(harness.controller.state.activeThread?.status, 'idle');

    reconnectResume.complete(
      const AgentSession(
        thread: _threadA,
        timeline: <TimelineEntry>[],
        responseSequence: 11,
      ),
    );
    await _waitUntil(() => !harness.controller.state.loading);
    expect(harness.controller.state.running, isFalse);
  });

  test(
    'returning to the list replays and caches buffered completion',
    () async {
      final agent = _ResumeAgent(threads: const [_threadAActive, _threadB]);
      final harness = await _createHarness(agent);
      final firstResume = agent.gateNextResume(_threadA.id);

      harness.controller.openThread(_threadAActive);
      await _waitUntil(() => harness.controller.state.loading);
      agent.emit(
        _notification(
          'turn/completed',
          threadId: _threadA.id,
          turnId: 'turn-a',
          sequence: 8,
        ),
      );
      harness.controller.backToThreadList();

      expect(harness.controller.state.screen, AppScreen.threads);
      expect(
        harness.controller.state.threads
            .singleWhere((thread) => thread.id == _threadA.id)
            .status,
        'idle',
      );

      firstResume.complete(
        const AgentSession(
          thread: _threadAActive,
          timeline: <TimelineEntry>[],
          responseSequence: 7,
        ),
      );
      await _drainAsyncWork();

      final nextResume = agent.gateNextResume(_threadA.id);
      harness.controller.openThread(_threadA);
      await _waitUntil(
        () =>
            harness.controller.state.activeThread?.id == _threadA.id &&
            harness.controller.state.loading,
      );

      expect(harness.controller.state.activeThread?.status, 'idle');
      expect(harness.controller.state.running, isFalse);
      nextResume.complete(const AgentSession(thread: _threadA, timeline: []));
    },
  );

  test('an older A resume cannot overwrite a newer A cache entry', () async {
    final agent = _ResumeAgent(threads: const [_threadA, _threadB]);
    final harness = await _createHarness(agent);
    final oldA = agent.gateNextResume(_threadA.id);
    harness.controller.openThread(_threadA);
    await _waitUntil(() => harness.controller.state.loading);

    final pendingB = agent.gateNextResume(_threadB.id);
    harness.controller.openThread(_threadB);
    await _waitUntil(
      () =>
          harness.controller.state.activeThread?.id == _threadB.id &&
          harness.controller.state.loading,
    );

    final newA = agent.gateNextResume(_threadA.id);
    // Same-generation A requests are now shared. Simulate a replacement
    // transport to retain coverage for a truly obsolete A response.
    agent.remoteGeneration++;
    harness.controller.openThread(_threadA);
    await _waitUntil(
      () =>
          harness.controller.state.activeThread?.id == _threadA.id &&
          harness.controller.state.loading,
    );
    newA.complete(
      const AgentSession(
        thread: _threadA,
        timeline: <TimelineEntry>[
          TimelineEntry(
            id: 'new',
            kind: TimelineKind.agentMessage,
            text: 'new A response',
            turnId: 'turn-new',
          ),
        ],
      ),
    );
    await _waitUntil(() => !harness.controller.state.loading);

    oldA.complete(
      const AgentSession(
        thread: _threadA,
        timeline: <TimelineEntry>[
          TimelineEntry(
            id: 'old',
            kind: TimelineKind.agentMessage,
            text: 'old A response',
            turnId: 'turn-old',
          ),
        ],
      ),
    );
    pendingB.complete(const AgentSession(thread: _threadB, timeline: []));
    await _drainAsyncWork();

    harness.controller.backToThreadList();
    final inspectCache = agent.gateNextResume(_threadA.id);
    harness.controller.openThread(_threadA);
    await _waitUntil(
      () =>
          harness.controller.state.activeThread?.id == _threadA.id &&
          harness.controller.state.loading,
    );

    expect(harness.controller.state.timeline.single.text, 'new A response');
    inspectCache.complete(const AgentSession(thread: _threadA, timeline: []));
  });

  test('completion after a snapshot sequence is retained in cache', () async {
    final agent = _ResumeAgent(threads: const [_threadAActive, _threadB]);
    final harness = await _createHarness(agent);
    final resume = agent.gateNextResume(_threadA.id);
    harness.controller.openThread(_threadAActive);
    await _waitUntil(() => harness.controller.state.loading);

    agent.emit(
      _notification(
        'turn/completed',
        threadId: _threadA.id,
        turnId: 'turn-a',
        sequence: 11,
      ),
    );
    resume.complete(
      const AgentSession(
        thread: _threadAActive,
        timeline: <TimelineEntry>[],
        responseSequence: 10,
      ),
    );
    await _waitUntil(() => !harness.controller.state.loading);
    expect(harness.controller.state.running, isFalse);
    final completedTiming = harness.controller.state.turnTiming;
    expect(completedTiming?.completedAtMillis, isNotNull);

    harness.controller.backToThreadList();
    final inspectCache = agent.gateNextResume(_threadA.id);
    harness.controller.openThread(_threadA);
    await _waitUntil(() => harness.controller.state.loading);

    expect(harness.controller.state.activeThread?.status, 'idle');
    expect(harness.controller.state.running, isFalse);
    expect(harness.controller.state.turnTiming, completedTiming);
    inspectCache.complete(const AgentSession(thread: _threadA, timeline: []));
  });

  test('restores a completed stopped timing after a cold start', () async {
    final storageKey = threadPreferenceKey(
      _profile.id,
      AgentKind.codex,
      _threadA.id,
    );
    const stoppedTiming = TurnTiming(
      threadId: 'thread-a',
      turnId: 'turn-stopped',
      startedAtMillis: 100,
      completedAtMillis: 200,
      stopped: true,
    );
    final agent = _ResumeAgent(threads: const [_threadA, _threadB]);
    final harness = await _createHarness(
      agent,
      storedProfiles: StoredProfiles(
        profiles: const [_profile],
        selectedProfileId: _profile.id,
        completedTurnTimings: {storageKey: stoppedTiming},
      ),
    );
    final resume = agent.gateNextResume(_threadA.id);

    harness.controller.openThread(_threadA);
    await _waitUntil(
      () =>
          harness.controller.state.activeThread?.id == _threadA.id &&
          harness.controller.state.loading,
    );

    expect(harness.controller.state.running, isFalse);
    expect(harness.controller.state.turnTiming, stoppedTiming);
    resume.complete(const AgentSession(thread: _threadA, timeline: []));
  });

  test('active resume rejects completed retained turn timing', () async {
    final agent = _ResumeAgent(threads: const [_threadAActive, _threadB]);
    final harness = await _createHarness(agent);
    final firstResume = agent.gateNextResume(_threadA.id);
    harness.controller.openThread(_threadAActive);
    await _waitUntil(() => harness.controller.state.loading);
    firstResume.complete(
      const AgentSession(thread: _threadAActive, timeline: []),
    );
    await _waitUntil(() => !harness.controller.state.loading);

    agent.emit(
      _notification('turn/completed', threadId: _threadA.id, turnId: 'turn-a'),
    );
    await _waitUntil(
      () => harness.controller.state.turnTiming?.completedAtMillis != null,
    );
    final completedTiming = harness.controller.state.turnTiming!;
    harness.controller.backToThreadList();

    const newTurnThread = AgentThread(
      id: 'thread-a',
      title: 'Thread A',
      source: 'appServer',
      status: 'active',
      activeTurnId: 'turn-new',
      updatedAt: 11,
    );
    final secondResume = agent.gateNextResume(_threadA.id);
    harness.controller.openThread(newTurnThread);
    await _waitUntil(() => harness.controller.state.loading);
    secondResume.complete(
      const AgentSession(thread: newTurnThread, timeline: []),
    );
    await _waitUntil(() => !harness.controller.state.loading);

    final resumedTiming = harness.controller.state.turnTiming;
    expect(resumedTiming, isNotNull);
    expect(resumedTiming!.turnId, 'turn-new');
    expect(resumedTiming.completedAtMillis, isNull);
    expect(resumedTiming, isNot(completedTiming));
  });

  test(
    'active resume overrides a non-stopped completed timing for the same turn',
    () async {
      final storageKey = threadPreferenceKey(
        _profile.id,
        AgentKind.codex,
        _threadA.id,
      );
      const staleTiming = TurnTiming(
        threadId: 'thread-a',
        turnId: 'turn-a',
        startedAtMillis: 100,
        completedAtMillis: 200,
      );
      final agent = _ResumeAgent(threads: const [_threadAActive, _threadB]);
      final harness = await _createHarness(
        agent,
        storedProfiles: StoredProfiles(
          profiles: const [_profile],
          selectedProfileId: _profile.id,
          completedTurnTimings: {storageKey: staleTiming},
        ),
      );
      final resume = agent.gateNextResume(_threadA.id);

      harness.controller.openThread(_threadAActive);
      await _waitUntil(() => harness.controller.state.loading);
      resume.complete(
        const AgentSession(thread: _threadAActive, timeline: <TimelineEntry>[]),
      );
      await _waitUntil(() => !harness.controller.state.loading);

      expect(harness.controller.state.running, isTrue);
      expect(harness.controller.state.activeTurnId, 'turn-a');
      expect(harness.controller.state.turnTiming?.completedAtMillis, isNull);
      expect(harness.controller.state.turnTiming?.stopped, isFalse);
    },
  );

  test(
    'active resume keeps an explicitly stopped timing settled for the same turn',
    () async {
      final storageKey = threadPreferenceKey(
        _profile.id,
        AgentKind.codex,
        _threadA.id,
      );
      const stoppedTiming = TurnTiming(
        threadId: 'thread-a',
        turnId: 'turn-a',
        startedAtMillis: 100,
        completedAtMillis: 200,
        stopped: true,
      );
      final agent = _ResumeAgent(threads: const [_threadAActive, _threadB]);
      final harness = await _createHarness(
        agent,
        storedProfiles: StoredProfiles(
          profiles: const [_profile],
          selectedProfileId: _profile.id,
          completedTurnTimings: {storageKey: stoppedTiming},
        ),
      );
      final resume = agent.gateNextResume(_threadA.id);

      harness.controller.openThread(_threadAActive);
      await _waitUntil(() => harness.controller.state.loading);
      resume.complete(
        const AgentSession(thread: _threadAActive, timeline: <TimelineEntry>[]),
      );
      await _waitUntil(() => !harness.controller.state.loading);

      expect(harness.controller.state.running, isFalse);
      expect(harness.controller.state.activeTurnId, isNull);
      expect(harness.controller.state.activeThread?.status, 'idle');
      expect(harness.controller.state.turnTiming, stoppedTiming);
    },
  );

  test('active resume rejects mismatched incomplete turn timing', () async {
    final agent = _ResumeAgent(threads: const [_threadAActive, _threadB]);
    final harness = await _createHarness(agent);
    final firstResume = agent.gateNextResume(_threadA.id);
    harness.controller.openThread(_threadAActive);
    await _waitUntil(() => harness.controller.state.loading);
    firstResume.complete(
      const AgentSession(thread: _threadAActive, timeline: []),
    );
    await _waitUntil(() => !harness.controller.state.loading);
    expect(harness.controller.state.turnTiming?.turnId, 'turn-a');
    expect(harness.controller.state.turnTiming?.completedAtMillis, isNull);
    harness.controller.backToThreadList();

    const newTurnThread = AgentThread(
      id: 'thread-a',
      title: 'Thread A',
      source: 'appServer',
      status: 'active',
      activeTurnId: 'turn-new',
      updatedAt: 11,
    );
    final secondResume = agent.gateNextResume(_threadA.id);
    harness.controller.openThread(newTurnThread);
    await _waitUntil(() => harness.controller.state.loading);
    secondResume.complete(
      const AgentSession(thread: newTurnThread, timeline: []),
    );
    await _waitUntil(() => !harness.controller.state.loading);

    expect(harness.controller.state.turnTiming?.turnId, 'turn-new');
    expect(harness.controller.state.turnTiming?.completedAtMillis, isNull);
  });

  test(
    'notLoaded resume replays a plan delta against the raw snapshot',
    () async {
      final agent = _ResumeAgent(threads: const [_threadA, _threadB]);
      final harness = await _createHarness(agent);
      final seed = agent.gateNextResume(_threadA.id);
      harness.controller.openThread(_threadA);
      await _waitUntil(() => harness.controller.state.loading);
      seed.complete(
        const AgentSession(
          thread: _threadA,
          timeline: <TimelineEntry>[
            TimelineEntry(
              id: 'plan',
              kind: TimelineKind.plan,
              text: 'cached ',
              turnId: 'turn-plan',
            ),
          ],
        ),
      );
      await _waitUntil(() => !harness.controller.state.loading);
      harness.controller.backToThreadList();

      final resume = agent.gateNextResume(_threadA.id);
      harness.controller.openThread(_threadA);
      await _waitUntil(() => harness.controller.state.loading);
      agent.emit(
        _notification(
          'item/plan/delta',
          threadId: _threadA.id,
          turnId: 'turn-plan',
          itemId: 'plan',
          delta: 'live',
          sequence: 9,
        ),
      );
      resume.complete(
        const AgentSession(
          thread: _threadA,
          timeline: <TimelineEntry>[],
          responseSequence: 10,
          turnIds: <String>['turn-plan'],
          itemsView: 'notLoaded',
        ),
      );
      await _waitUntil(() => !harness.controller.state.loading);

      expect(harness.controller.state.timeline.single.text, 'cached live');
    },
  );

  test('buffered completion without a turn id is published once', () async {
    final agent = _ResumeAgent(
      threads: const [
        AgentThread(
          id: 'thread-a',
          title: 'Thread A',
          source: 'appServer',
          status: 'active',
          updatedAt: 10,
        ),
        _threadB,
      ],
    );
    final harness = await _createHarness(agent);
    final completions = <TurnCompletion>[];
    final subscription = harness.controller.turnCompletions.listen(
      completions.add,
    );
    addTearDown(subscription.cancel);
    final resume = agent.gateNextResume(_threadA.id);
    harness.controller.openThread(agent.threads.first);
    await _waitUntil(() => harness.controller.state.loading);

    agent.emit(
      _notification('turn/completed', threadId: _threadA.id, sequence: 2),
    );
    resume.complete(
      AgentSession(
        thread: agent.threads.first,
        timeline: const <TimelineEntry>[],
        responseSequence: 1,
      ),
    );
    await _waitUntil(() => !harness.controller.state.loading);
    await _drainAsyncWork();

    expect(completions, hasLength(1));
    expect(completions.single.turnId, isEmpty);
  });

  test(
    'notifications received on the thread list update the cached transcript',
    () async {
      final agent = _ResumeAgent(threads: const [_threadA, _threadB]);
      final harness = await _createHarness(agent);
      final firstResume = agent.gateNextResume(_threadA.id);

      harness.controller.openThread(_threadA);
      await _waitUntil(
        () =>
            harness.controller.state.activeThread?.id == _threadA.id &&
            harness.controller.state.loading,
      );
      firstResume.complete(
        const AgentSession(
          thread: _threadA,
          timeline: <TimelineEntry>[
            TimelineEntry(
              id: 'item-a',
              kind: TimelineKind.agentMessage,
              text: '旧内容',
              turnId: 'turn-a',
            ),
          ],
          tokenUsage: TokenUsage(
            modelContextWindow: 1_000,
            last: TokenUsageBreakdown(totalTokens: 100),
            total: TokenUsageBreakdown(totalTokens: 100),
          ),
        ),
      );
      await _waitUntil(() => !harness.controller.state.loading);
      harness.controller.backToThreadList();

      agent.emit(
        _notificationWithParams('item/agentMessage/delta', <String, Object?>{
          'threadId': _threadA.id,
          'turnId': 'turn-a',
          'itemId': 'item-a',
          'delta': '，新内容',
        }),
      );
      agent.emit(
        _notificationWithParams('thread/tokenUsage/updated', <String, Object?>{
          'threadId': _threadA.id,
          'tokenUsage': <String, Object?>{
            'modelContextWindow': 1_000,
            'last': <String, Object?>{'totalTokens': 240},
            'total': <String, Object?>{'totalTokens': 240},
          },
        }),
      );
      await _drainAsyncWork();

      final nextResume = agent.gateNextResume(_threadA.id);
      harness.controller.openThread(_threadA);
      await _waitUntil(
        () =>
            harness.controller.state.activeThread?.id == _threadA.id &&
            harness.controller.state.loading,
      );
      expect(harness.controller.state.timeline.single.text, '旧内容，新内容');
      expect(harness.controller.state.tokenUsage?.last.totalTokens, 240);
      nextResume.complete(const AgentSession(thread: _threadA, timeline: []));
    },
  );

  test(
    're-entering a revised thread keeps a command completed on the list',
    () async {
      final agent = _ResumeAgent(threads: const [_threadAActive, _threadB]);
      final harness = await _createHarness(agent);
      final firstResume = agent.gateNextResume(_threadA.id);

      harness.controller.openThread(_threadAActive);
      await _waitUntil(() => harness.controller.state.loading);
      firstResume.complete(
        const AgentSession(
          thread: _threadAActive,
          timeline: <TimelineEntry>[
            TimelineEntry(
              id: 'command-1',
              kind: TimelineKind.command,
              command: 'flutter test',
              status: 'inProgress',
              turnId: 'turn-a',
            ),
          ],
          turnIds: <String>['turn-a'],
        ),
      );
      await _waitUntil(() => !harness.controller.state.loading);
      harness.controller.backToThreadList();

      agent.emit(
        _notificationWithParams('item/completed', <String, Object?>{
          'threadId': _threadA.id,
          'turnId': 'turn-a',
          'item': <String, Object?>{
            'id': 'command-1',
            'type': 'commandExecution',
            'command': 'flutter test',
            'status': 'completed',
            'aggregatedOutput': 'All tests passed',
          },
        }),
      );
      agent.emit(
        _notification(
          'turn/completed',
          threadId: _threadA.id,
          turnId: 'turn-a',
        ),
      );
      await _drainAsyncWork();

      const refreshedThread = AgentThread(
        id: 'thread-a',
        title: 'Thread A',
        source: 'appServer',
        status: 'idle',
        updatedAt: 11,
      );
      agent.threads = const <AgentThread>[refreshedThread, _threadB];
      final secondResume = agent.gateNextResume(_threadA.id);
      harness.controller.openThread(refreshedThread);
      await _waitUntil(() => harness.controller.state.loading);
      expect(
        harness.controller.state.timeline.single.kind,
        TimelineKind.command,
      );

      secondResume.complete(
        const AgentSession(
          thread: refreshedThread,
          timeline: <TimelineEntry>[
            TimelineEntry(
              id: 'agent-1',
              kind: TimelineKind.agentMessage,
              text: '测试完成',
              turnId: 'turn-a',
            ),
          ],
          turnIds: <String>['turn-a'],
        ),
      );
      await _waitUntil(() => !harness.controller.state.loading);

      final command = harness.controller.state.timeline.singleWhere(
        (entry) => entry.kind == TimelineKind.command,
      );
      expect(command.command, 'flutter test');
      expect(command.status, 'completed');
      expect(command.output, 'All tests passed');
    },
  );

  test('re-entering keeps an active command on the list', () async {
    final agent = _ResumeAgent(threads: const [_threadAActive, _threadB]);
    final harness = await _createHarness(agent);
    final firstResume = agent.gateNextResume(_threadA.id);

    harness.controller.openThread(_threadAActive);
    await _waitUntil(() => harness.controller.state.loading);
    firstResume.complete(
      const AgentSession(
        thread: _threadAActive,
        timeline: <TimelineEntry>[
          TimelineEntry(
            id: 'command-running',
            kind: TimelineKind.command,
            command: 'flutter build apk',
            status: 'inProgress',
            turnId: 'turn-a',
          ),
        ],
        turnIds: <String>['turn-a'],
      ),
    );
    await _waitUntil(() => !harness.controller.state.loading);
    harness.controller.backToThreadList();

    const refreshedActiveThread = AgentThread(
      id: 'thread-a',
      title: 'Thread A',
      source: 'appServer',
      status: 'active',
      activeTurnId: 'turn-a',
      updatedAt: 11,
    );
    final secondResume = agent.gateNextResume(_threadA.id);
    harness.controller.openThread(refreshedActiveThread);
    await _waitUntil(() => harness.controller.state.loading);
    secondResume.complete(
      const AgentSession(
        thread: refreshedActiveThread,
        timeline: <TimelineEntry>[
          TimelineEntry(
            id: 'agent-running',
            kind: TimelineKind.agentMessage,
            text: '正在构建',
            turnId: 'turn-a',
          ),
        ],
        turnIds: <String>['turn-a'],
      ),
    );
    await _waitUntil(() => !harness.controller.state.loading);

    final command = harness.controller.state.timeline.singleWhere(
      (entry) => entry.kind == TimelineKind.command,
    );
    expect(command.status, 'inProgress');
    expect(harness.controller.state.running, isTrue);
    expect(harness.controller.state.activeTurnId, 'turn-a');
  });
}

class _Harness {
  const _Harness(this.controller);

  final AppController controller;
}

Future<_Harness> _createHarness(
  _ResumeAgent agent, {
  StoredProfiles? storedProfiles,
  bool waitForAgent = true,
  ThreadSnapshotStore? snapshots,
}) async {
  final store = _MemoryProfileStore(
    storedProfiles ??
        const StoredProfiles(profiles: [_profile], selectedProfileId: 'server'),
  );
  final connections = ServerConnectionManager(clientFactory: _Host.new);
  final agents = AgentConnectionManager(
    connections,
    clientFactory: (_) => agent,
  );
  final controller = AppController(
    store,
    connections,
    agents,
    null,
    null,
    null,
    null,
    null,
    snapshots,
  );
  addTearDown(() async {
    controller.dispose();
    await agents.close();
    await connections.close();
  });
  await _waitUntil(() => !controller.state.loading);
  await controller.requestConnect(_profile);
  if (!waitForAgent) return _Harness(controller);
  await controller.ensureActiveAgent();
  await _waitUntil(
    () => controller.state.threads.length == agent.threads.length,
  );
  return _Harness(controller);
}

class _SnapshotStore implements ThreadSnapshotStore {
  final reads = <Completer<ThreadSessionSnapshot?>>[];
  final writes = <ThreadSessionSnapshot>[];
  @override
  Future<ThreadSessionSnapshot?> read(String scope, String id) {
    final pending = Completer<ThreadSessionSnapshot?>();
    reads.add(pending);
    return pending.future;
  }

  @override
  Future<void> write(String scope, ThreadSessionSnapshot snapshot) async =>
      writes.add(snapshot);
  @override
  Future<void> remove(String scope, String id) async {}
  @override
  Future<void> removeScope(String scope) async {}
}

class _ReusableResumeAgent extends _ResumeAgent
    implements RemoteAgentThreadReuseClient {
  _ReusableResumeAgent({required super.threads});
  bool reusable = true;
  @override
  bool canReuseThread(String threadId, ApprovalMode mode) =>
      connected && reusable;
  @override
  Future<AgentSession> resumeCachedThread(
    AgentSession snapshot, {
    ApprovalMode approvalMode = ApprovalMode.requestApproval,
  }) async => AgentSession(
    thread: snapshot.thread,
    timeline: snapshot.timeline,
    nextTurnsCursor: snapshot.nextTurnsCursor,
    tokenUsage: snapshot.tokenUsage,
    activeTurnStartedAtMillis: snapshot.activeTurnStartedAtMillis,
    responseSequence: -1,
    itemsView: 'cached',
  );
}

class _MemoryProfileStore implements ProfileStore {
  _MemoryProfileStore(this.value);

  StoredProfiles value;

  @override
  Future<StoredProfiles> load() async => value;

  @override
  Future<void> save(StoredProfiles value) async {
    this.value = value;
  }
}

class _Host implements RemoteServerClient {
  bool connected = false;
  final Completer<void> _closed = Completer<void>();

  @override
  Future<void> connect(ServerProfile profile) async => connected = true;

  @override
  Future<void> disconnect() async {
    connected = false;
    if (!_closed.isCompleted) _closed.complete();
  }

  @override
  Future<void> get done => _closed.future;

  @override
  bool get isConnected => connected;

  @override
  Future<String> probeFingerprint(ServerProfile profile) async => 'SHA256:test';

  @override
  Future<ServerMetrics> readServerMetrics(ServerProfile profile) async =>
      const ServerMetrics();

  @override
  Future<String> run(
    String command, {
    Duration timeout = const Duration(seconds: 15),
    int maxOutputBytes = 1024 * 1024,
  }) async => '';

  @override
  SSHClient requireSshClient() => throw UnimplementedError();

  @override
  void close() {
    connected = false;
    if (!_closed.isCompleted) _closed.complete();
  }
}

class _ResumeAgent
    implements
        RemoteAgentClient,
        RemoteAgentGenerationClient,
        RemoteAgentThreadInspectionClient {
  _ResumeAgent({required this.threads});

  List<AgentThread> threads;
  int listThreadsCount = 0;
  Completer<AgentThreadPage>? listGate;
  final List<String> resumeCalls = [];
  final List<({String threadId, String cursor})> olderCalls = [];
  final StreamController<RemoteAgentEvent> _events =
      StreamController<RemoteAgentEvent>.broadcast(sync: true);
  final Map<String, List<Completer<AgentSession>>> _resumeGates = {};
  final Map<String, List<Completer<AgentTurnsPage>>> _olderGates = {};
  final Map<String, AgentSession> readSessions = {};
  bool connected = false;
  int remoteGeneration = 1;

  @override
  AgentKind get kind => AgentKind.codex;

  @override
  AgentCapabilities get capabilities => AgentCapabilities.codex;

  @override
  bool get isConnected => connected;

  @override
  int? get currentGeneration => connected ? remoteGeneration : null;

  @override
  Stream<RemoteAgentEvent> get events => _events.stream;

  Completer<AgentSession> gateNextResume(String threadId) {
    final result = Completer<AgentSession>();
    (_resumeGates[threadId] ??= <Completer<AgentSession>>[]).add(result);
    return result;
  }

  Completer<AgentTurnsPage> gateNextOlderTurns(String threadId) {
    final result = Completer<AgentTurnsPage>();
    (_olderGates[threadId] ??= <Completer<AgentTurnsPage>>[]).add(result);
    return result;
  }

  void emit(CodexRpcNotification notification) {
    _events.add(RemoteAgentNotification(notification));
  }

  void emitLoss(String message) {
    connected = false;
    _events.add(RemoteAgentConnectionLost(message));
  }

  @override
  Future<void> connect(ServerProfile profile, RemoteServerClient host) async {
    connected = true;
  }

  @override
  Future<List<AgentModel>> listModels() async => const <AgentModel>[];

  @override
  Future<AgentThreadPage> listThreads({String? searchTerm}) async {
    listThreadsCount += 1;
    if (listGate != null) return listGate!.future;
    return AgentThreadPage(threads: threads);
  }

  @override
  Future<AgentSession> resumeThread(
    String threadId, {
    ApprovalMode approvalMode = ApprovalMode.requestApproval,
  }) async {
    resumeCalls.add(threadId);
    final gates = _resumeGates[threadId];
    if (gates != null && gates.isNotEmpty) {
      return gates.removeAt(0).future;
    }
    final thread = threads.firstWhere((candidate) => candidate.id == threadId);
    return AgentSession(thread: thread, timeline: const <TimelineEntry>[]);
  }

  @override
  Future<AgentSession> readThread(String threadId) async {
    final session = readSessions[threadId];
    if (session == null) throw UnsupportedError('test read not configured');
    return session;
  }

  @override
  Future<AgentTurnsPage> loadOlderTurns({
    required String threadId,
    required String cursor,
    int? subAgentCreatedAt,
  }) async {
    olderCalls.add((threadId: threadId, cursor: cursor));
    final gates = _olderGates[threadId];
    if (gates != null && gates.isNotEmpty) {
      return gates.removeAt(0).future;
    }
    return const AgentTurnsPage(timeline: <TimelineEntry>[]);
  }

  @override
  Future<void> disconnect() async => connected = false;

  @override
  void close() {
    connected = false;
    for (final gates in _resumeGates.values) {
      for (final gate in gates) {
        if (!gate.isCompleted) {
          gate.completeError(StateError('closed'));
        }
      }
    }
    if (!_events.isClosed) unawaited(_events.close());
  }
}

class _RuntimeResumeAgent extends _ResumeAgent
    implements RemoteAgentRuntimeClient {
  _RuntimeResumeAgent({required super.threads});
  int inspectCalls = 0;
  Completer<void>? inspectGate;

  @override
  Future<AgentRuntimeInspection> inspectRuntime(
    ServerProfile profile,
    RemoteServerClient host,
  ) async {
    inspectCalls++;
    await inspectGate?.future;
    return AgentRuntimeInspection.bypass(profile.remoteCommand);
  }

  @override
  Future<void> installRuntime(
    ServerProfile profile,
    RemoteServerClient host, {
    required void Function(RemoteInstallProgress progress) onProgress,
  }) async => throw UnsupportedError('not used');

  @override
  Future<void> uninstallRuntime(
    ServerProfile profile,
    RemoteServerClient host,
  ) async => throw UnsupportedError('not used');
}

CodexRpcNotification _notification(
  String method, {
  required String threadId,
  String turnId = '',
  String itemId = '',
  String delta = '',
  int sequence = 0,
}) {
  final turn = <String, Object?>{
    if (turnId.isNotEmpty) 'id': turnId,
    'status': 'completed',
  };
  final params = <String, Object?>{
    'threadId': threadId,
    if (turnId.isNotEmpty) 'turnId': turnId,
    if (method == 'turn/completed') 'turn': turn,
    if (itemId.isNotEmpty) 'itemId': itemId,
    if (delta.isNotEmpty) 'delta': delta,
  };
  return CodexRpcNotification(
    generation: 1,
    sequence: sequence,
    raw: <String, Object?>{'method': method, 'params': params},
    method: method,
    params: params,
    isKnown: true,
  );
}

CodexRpcNotification _notificationWithParams(
  String method,
  Map<String, Object?> params,
) => CodexRpcNotification(
  generation: 1,
  sequence: 0,
  raw: <String, Object?>{'method': method, 'params': params},
  method: method,
  params: params,
  isKnown: true,
);

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 300; attempt += 1) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('condition was not met');
}

Future<void> _drainAsyncWork() async {
  for (var attempt = 0; attempt < 20; attempt += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}
