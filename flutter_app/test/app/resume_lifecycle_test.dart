import 'dart:async';

import 'package:codex_remote/src/agent/agent_connection_manager.dart';
import 'package:codex_remote/src/agent/codex_protocol.dart';
import 'package:codex_remote/src/agent/remote_agent_client.dart';
import 'package:codex_remote/src/app/app_controller.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/persistence/profile_store.dart';
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
}

class _Harness {
  const _Harness(this.controller);

  final AppController controller;
}

Future<_Harness> _createHarness(
  _ResumeAgent agent, {
  StoredProfiles? storedProfiles,
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
  final controller = AppController(store, connections, agents);
  addTearDown(() async {
    controller.dispose();
    await agents.close();
    await connections.close();
  });
  await _waitUntil(() => !controller.state.loading);
  await controller.requestConnect(_profile);
  await controller.ensureActiveAgent();
  await _waitUntil(
    () => controller.state.threads.length == agent.threads.length,
  );
  return _Harness(controller);
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

class _ResumeAgent implements RemoteAgentClient, RemoteAgentGenerationClient {
  _ResumeAgent({required this.threads});

  List<AgentThread> threads;
  int listThreadsCount = 0;
  final StreamController<RemoteAgentEvent> _events =
      StreamController<RemoteAgentEvent>.broadcast(sync: true);
  final Map<String, List<Completer<AgentSession>>> _resumeGates = {};
  bool connected = false;

  @override
  AgentKind get kind => AgentKind.codex;

  @override
  AgentCapabilities get capabilities => AgentCapabilities.codex;

  @override
  bool get isConnected => connected;

  @override
  int? get currentGeneration => connected ? 1 : null;

  @override
  Stream<RemoteAgentEvent> get events => _events.stream;

  Completer<AgentSession> gateNextResume(String threadId) {
    final result = Completer<AgentSession>();
    (_resumeGates[threadId] ??= <Completer<AgentSession>>[]).add(result);
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
    return AgentThreadPage(threads: threads);
  }

  @override
  Future<AgentSession> resumeThread(
    String threadId, {
    ApprovalMode approvalMode = ApprovalMode.requestApproval,
  }) async {
    final gates = _resumeGates[threadId];
    if (gates != null && gates.isNotEmpty) {
      return gates.removeAt(0).future;
    }
    final thread = threads.firstWhere((candidate) => candidate.id == threadId);
    return AgentSession(thread: thread, timeline: const <TimelineEntry>[]);
  }

  @override
  Future<AgentTurnsPage> loadOlderTurns({
    required String threadId,
    required String cursor,
    int? subAgentCreatedAt,
  }) async => const AgentTurnsPage(timeline: <TimelineEntry>[]);

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
