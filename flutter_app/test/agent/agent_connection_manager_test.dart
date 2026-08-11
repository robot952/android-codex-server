import 'dart:async';

import 'package:codex_remote/src/agent/agent_connection_manager.dart';
import 'package:codex_remote/src/agent/remote_agent_client.dart';
import 'package:codex_remote/src/agent/remote_bootstrap.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/ssh/server_connection_manager.dart';
import 'package:codex_remote/src/ssh/ssh_server_client.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAgent implements RemoteAgentClient {
  _FakeAgent(this.kind);

  @override
  final AgentKind kind;
  final StreamController<RemoteAgentEvent> _events =
      StreamController<RemoteAgentEvent>.broadcast(sync: true);
  bool connected = false;
  bool closed = false;
  int connectCount = 0;
  int disconnectCount = 0;

  @override
  AgentCapabilities get capabilities => kind == AgentKind.codex
      ? AgentCapabilities.codex
      : AgentCapabilities.openCode;

  @override
  bool get isConnected => connected;

  @override
  Stream<RemoteAgentEvent> get events => _events.stream;

  @override
  Future<void> connect(ServerProfile profile, RemoteServerClient host) async {
    if (closed) throw StateError('closed');
    connectCount++;
    connected = true;
  }

  @override
  Future<List<AgentModel>> listModels() async => [
    AgentModel(id: '${kind.name}-model'),
  ];

  @override
  Future<AgentThreadPage> listThreads({String? searchTerm}) async =>
      AgentThreadPage(
        threads: [
          AgentThread(
            id: '${kind.name}-thread',
            title: searchTerm ?? kind.name,
          ),
        ],
      );

  @override
  Future<AgentSession> resumeThread(
    String threadId, {
    ApprovalMode approvalMode = ApprovalMode.requestApproval,
  }) async => AgentSession(
    thread: AgentThread(id: threadId, title: 'resumed'),
    timeline: const <TimelineEntry>[],
  );

  @override
  Future<AgentTurnsPage> loadOlderTurns({
    required String threadId,
    required String cursor,
    int? subAgentCreatedAt,
  }) async => const AgentTurnsPage(timeline: <TimelineEntry>[]);

  @override
  Future<void> disconnect() async {
    disconnectCount++;
    connected = false;
  }

  @override
  void close() {
    closed = true;
    connected = false;
    unawaited(_events.close());
  }
}

class _IndependentFakeAgent extends _FakeAgent
    implements RemoteAgentIndependentConnectionClient {
  _IndependentFakeAgent(super.kind);

  @override
  bool get usesIndependentConnection => true;
}

class _DurableFakeAgent extends _FakeAgent
    implements RemoteAgentDurableSessionClient {
  _DurableFakeAgent(super.kind);

  int stopCount = 0;

  @override
  Future<void> stopDurableRemoteSession() async {
    stopCount++;
  }
}

class _FakeMutationAgent extends _FakeAgent
    implements RemoteAgentThreadMutationClient {
  _FakeMutationAgent(super.kind);

  final List<String> calls = <String>[];
  Completer<void>? compactCompleter;
  String? rollbackThreadId;
  ApprovalMode? rollbackApprovalMode;
  int? rollbackTurns;
  String? renamedThreadId;
  String? renamedValue;
  String? goalThreadId;
  String? goalObjective;
  ThreadGoalStatus? goalStatus;
  int? goalTokenBudget;
  ThreadGoal? readGoal;

  @override
  Future<void> compactThread(String threadId) async {
    calls.add('compact:$threadId');
    await compactCompleter?.future;
  }

  @override
  Future<AgentSession> rollbackThread(
    String threadId, {
    ApprovalMode approvalMode = ApprovalMode.requestApproval,
    int turns = 1,
  }) async {
    calls.add('rollback:$threadId');
    rollbackThreadId = threadId;
    rollbackApprovalMode = approvalMode;
    rollbackTurns = turns;
    return AgentSession(
      thread: AgentThread(id: threadId, title: 'rolled back'),
      timeline: const <TimelineEntry>[],
    );
  }

  @override
  Future<void> archiveThread(String threadId) async {
    calls.add('archive:$threadId');
  }

  @override
  Future<void> setThreadName(String threadId, String name) async {
    calls.add('name:$threadId');
    renamedThreadId = threadId;
    renamedValue = name;
  }

  @override
  Future<void> startReview(String threadId) async {
    calls.add('review:$threadId');
  }

  @override
  Future<ThreadGoal?> getThreadGoal(String threadId) async {
    calls.add('goal-get:$threadId');
    return readGoal;
  }

  @override
  Future<ThreadGoal> setThreadGoal(
    String threadId, {
    String? objective,
    ThreadGoalStatus? status,
    int? tokenBudget,
  }) async {
    calls.add('goal-set:$threadId');
    goalThreadId = threadId;
    goalObjective = objective;
    goalStatus = status;
    goalTokenBudget = tokenBudget;
    return ThreadGoal(
      threadId: threadId,
      objective: objective ?? '',
      status: status ?? ThreadGoalStatus.unknown,
      tokenBudget: tokenBudget,
    );
  }

  @override
  Future<void> clearThreadGoal(String threadId) async {
    calls.add('goal-clear:$threadId');
  }
}

class _FakeRuntimeAgent extends _FakeAgent implements RemoteAgentRuntimeClient {
  _FakeRuntimeAgent(super.kind);

  final Completer<void> installStarted = Completer<void>();
  final Completer<void> finishInstall = Completer<void>();
  final Completer<void> firstDisconnectStarted = Completer<void>();
  Completer<void>? firstDisconnectGate;
  Object? inspectError;
  int inspectCount = 0;
  int installCount = 0;
  int uninstallCount = 0;
  int activeDisconnects = 0;
  int maximumActiveDisconnects = 0;

  @override
  Future<AgentRuntimeInspection> inspectRuntime(
    ServerProfile profile,
    RemoteServerClient host,
  ) async {
    inspectCount++;
    if (inspectError case final error?) throw error;
    return const AgentRuntimeInspection.bypass(
      '~/.local/bin/codex-remote app-server --listen stdio://',
    );
  }

  @override
  Future<void> installRuntime(
    ServerProfile profile,
    RemoteServerClient host, {
    required void Function(RemoteInstallProgress progress) onProgress,
  }) async {
    installCount++;
    if (!installStarted.isCompleted) installStarted.complete();
    await finishInstall.future;
  }

  @override
  Future<void> uninstallRuntime(
    ServerProfile profile,
    RemoteServerClient host,
  ) async {
    uninstallCount++;
  }

  @override
  Future<void> disconnect() async {
    disconnectCount++;
    connected = false;
    activeDisconnects++;
    maximumActiveDisconnects = maximumActiveDisconnects < activeDisconnects
        ? activeDisconnects
        : maximumActiveDisconnects;
    try {
      final gate = firstDisconnectGate;
      if (disconnectCount == 1 && gate != null) {
        if (!firstDisconnectStarted.isCompleted) {
          firstDisconnectStarted.complete();
        }
        await gate.future;
      }
    } finally {
      activeDisconnects--;
    }
  }
}

class _FakeAdvancedAgent extends _FakeAgent
    implements RemoteAgentSteerClient, RemoteAgentCustomModelClient {
  _FakeAdvancedAgent(super.kind);

  Completer<void>? syncGate;
  String? steeredThreadId;
  String? steeredTurnId;
  String? steeredText;
  List<CustomModelDefinition>? syncedDefinitions;
  List<String>? syncedRemovedIds;

  @override
  Future<void> steerTurn({
    required String threadId,
    required String turnId,
    required String text,
    List<PendingAttachment> attachments = const <PendingAttachment>[],
  }) async {
    steeredThreadId = threadId;
    steeredTurnId = turnId;
    steeredText = text;
  }

  @override
  Future<void> ensureCustomModel(
    ServerProfile profile,
    CustomModelDefinition definition,
  ) async {}

  @override
  Future<void> syncCustomModels(
    ServerProfile profile, {
    required List<CustomModelDefinition> definitions,
    required List<String> removedModelIds,
  }) async {
    syncedDefinitions = List<CustomModelDefinition>.of(definitions);
    syncedRemovedIds = List<String>.of(removedModelIds);
    await syncGate?.future;
  }
}

class _FakeHost implements RemoteServerClient {
  bool connected = false;
  final Completer<void> closed = Completer<void>();
  void Function()? onDisconnect;

  @override
  Future<void> connect(ServerProfile profile) async => connected = true;

  @override
  Future<void> disconnect() async {
    connected = false;
    onDisconnect?.call();
    if (!closed.isCompleted) closed.complete();
  }

  @override
  Future<void> get done => closed.future;

  @override
  bool get isConnected => connected;

  @override
  Future<String> probeFingerprint(ServerProfile profile) async => 'SHA256:test';

  @override
  Future<String> run(
    String command, {
    Duration timeout = const Duration(seconds: 15),
    int maxOutputBytes = 1024 * 1024,
  }) async => '';

  @override
  Future<ServerMetrics> readServerMetrics(ServerProfile profile) async =>
      const ServerMetrics();

  @override
  SSHClient requireSshClient() => throw UnimplementedError();

  @override
  void close() {
    connected = false;
    if (!closed.isCompleted) closed.complete();
  }
}

const _first = ServerProfile(
  id: 'first',
  host: 'first.example',
  username: 'root',
  authMode: AuthMode.password,
  password: 'secret',
  hostFingerprint: 'SHA256:first',
);

const _second = ServerProfile(
  id: 'second',
  host: 'second.example',
  username: 'root',
  authMode: AuthMode.password,
  password: 'secret',
  hostFingerprint: 'SHA256:second',
);

void main() {
  test('does not advertise capabilities before an Agent client exists', () {
    final hostManager = ServerConnectionManager(clientFactory: _FakeHost.new);
    final manager = AgentConnectionManager(hostManager);
    addTearDown(() async {
      await manager.close();
      await hostManager.close();
    });

    expect(
      manager.capabilities(
        const AgentConnectionKey(profileId: 'first', agent: AgentKind.openCode),
      ),
      AgentCapabilities.none,
    );
  });

  test('keeps profile and agent lanes independent', () async {
    final hosts = <_FakeHost>[];
    final hostManager = ServerConnectionManager(
      clientFactory: () {
        final host = _FakeHost();
        hosts.add(host);
        return host;
      },
    );
    final agents = <String, _FakeAgent>{};
    final manager = AgentConnectionManager(
      hostManager,
      clientFactory: (kind) {
        final agent = _FakeAgent(kind);
        agents['${agents.length}:${kind.name}'] = agent;
        return agent;
      },
    );
    addTearDown(() async {
      await manager.close();
      await hostManager.close();
    });

    await Future.wait([
      hostManager.connect(_first),
      hostManager.connect(_second),
    ]);
    await Future.wait([
      manager.connect(_first, AgentKind.codex),
      manager.connect(_first, AgentKind.openCode),
      manager.connect(_second, AgentKind.codex),
    ]);

    expect(manager.states.values, everyElement(isA<ConnectionState>()));
    expect(
      manager
          .states[const AgentConnectionKey(
            profileId: 'first',
            agent: AgentKind.codex,
          )]
          ?.phase,
      ConnectionPhase.connected,
    );
    expect(
      manager
          .states[const AgentConnectionKey(
            profileId: 'first',
            agent: AgentKind.openCode,
          )]
          ?.phase,
      ConnectionPhase.connected,
    );
    expect(
      (await manager.listThreads(
        const AgentConnectionKey(profileId: 'second', agent: AgentKind.codex),
      )).threads.single.id,
      'codex-thread',
    );
  });

  test('forwards steer requests through the active lane', () async {
    final hostManager = ServerConnectionManager(clientFactory: _FakeHost.new);
    late final _FakeAdvancedAgent client;
    final manager = AgentConnectionManager(
      hostManager,
      clientFactory: (kind) => client = _FakeAdvancedAgent(kind),
    );
    addTearDown(() async {
      await manager.close();
      await hostManager.close();
    });

    await hostManager.connect(_first);
    await manager.connect(_first, AgentKind.openCode);
    const key = AgentConnectionKey(
      profileId: 'first',
      agent: AgentKind.openCode,
    );
    await manager.steerTurn(
      key,
      threadId: 'thread-1',
      turnId: 'turn-1',
      text: 'continue',
    );

    expect(client.steeredThreadId, 'thread-1');
    expect(client.steeredTurnId, 'turn-1');
    expect(client.steeredText, 'continue');
  });

  test('rejects a custom-model sync after lane replacement', () async {
    final hostManager = ServerConnectionManager(clientFactory: _FakeHost.new);
    late final _FakeAdvancedAgent client;
    final manager = AgentConnectionManager(
      hostManager,
      clientFactory: (kind) => client = _FakeAdvancedAgent(kind),
    );
    addTearDown(() async {
      await manager.close();
      await hostManager.close();
    });

    await hostManager.connect(_first);
    await manager.connect(_first, AgentKind.openCode);
    client.syncGate = Completer<void>();
    const key = AgentConnectionKey(
      profileId: 'first',
      agent: AgentKind.openCode,
    );
    final request = manager.syncCustomModels(
      key,
      _first,
      definitions: const <CustomModelDefinition>[
        CustomModelDefinition(modelId: 'custom-api/gpt-5.2'),
      ],
      removedModelIds: const <String>['custom-api/old'],
    );
    await Future<void>.delayed(Duration.zero);
    manager.registerProfile(_first.copyWith(host: 'replacement.example'));
    client.syncGate!.complete();

    await expectLater(request, throwsA(isA<StateError>()));
    expect(client.syncedDefinitions?.single.modelId, 'custom-api/gpt-5.2');
    expect(client.syncedRemovedIds, const <String>['custom-api/old']);
  });

  test(
    'host disconnect invalidates all lanes without affecting another host',
    () async {
      final created = <_FakeHost>[];
      final hostManager = ServerConnectionManager(
        clientFactory: () {
          final host = _FakeHost();
          created.add(host);
          return host;
        },
      );
      final createdAgents = <_FakeAgent>[];
      final manager = AgentConnectionManager(
        hostManager,
        clientFactory: (kind) {
          final agent = _FakeAgent(kind);
          createdAgents.add(agent);
          return agent;
        },
      );
      addTearDown(() async {
        await manager.close();
        await hostManager.close();
      });

      await hostManager.connect(_first);
      await hostManager.connect(_second);
      await manager.connect(_first, AgentKind.codex);
      await manager.connect(_second, AgentKind.codex);
      await hostManager.disconnect(_first.id);
      await Future<void>.delayed(Duration.zero);

      expect(
        manager
            .states[const AgentConnectionKey(
              profileId: 'first',
              agent: AgentKind.codex,
            )]
            ?.phase,
        ConnectionPhase.disconnected,
      );
      expect(
        manager
            .states[const AgentConnectionKey(
              profileId: 'second',
              agent: AgentKind.codex,
            )]
            ?.phase,
        ConnectionPhase.connected,
      );
      expect(createdAgents.first.isConnected, isFalse);
    },
  );

  test('host loss preserves an Agent with an independent SSH lane', () async {
    final hostManager = ServerConnectionManager(clientFactory: _FakeHost.new);
    final agent = _IndependentFakeAgent(AgentKind.codex);
    final manager = AgentConnectionManager(
      hostManager,
      clientFactory: (kind) => agent,
    );
    addTearDown(() async {
      await manager.close();
      await hostManager.close();
    });

    await hostManager.connect(_first);
    await manager.connect(_first, AgentKind.codex);
    await hostManager.disconnect(_first.id);
    await Future<void>.delayed(Duration.zero);

    expect(agent.isConnected, isTrue);
    expect(agent.disconnectCount, 0);
    expect(
      manager
          .states[const AgentConnectionKey(
            profileId: 'first',
            agent: AgentKind.codex,
          )]
          ?.phase,
      ConnectionPhase.connected,
    );
  });

  test('remote command changes replace only the Codex lane', () async {
    final hostManager = ServerConnectionManager(clientFactory: _FakeHost.new);
    final created = <_FakeAgent>[];
    final manager = AgentConnectionManager(
      hostManager,
      clientFactory: (kind) {
        final agent = _FakeAgent(kind);
        created.add(agent);
        return agent;
      },
    );
    addTearDown(() async {
      await manager.close();
      await hostManager.close();
    });

    await hostManager.connect(_first);
    await manager.connect(_first, AgentKind.codex);
    await manager.connect(_first, AgentKind.openCode);
    final oldCodex = created.first;
    manager.registerProfile(
      _first.copyWith(remoteCommand: 'codex --listen stdio://'),
    );

    expect(oldCodex.closed, isTrue);
    expect(
      manager.states.containsKey(
        const AgentConnectionKey(profileId: 'first', agent: AgentKind.openCode),
      ),
      isTrue,
    );
  });

  test('reuses the OpenCode lane when the workspace is unchanged', () async {
    final hostManager = ServerConnectionManager(clientFactory: _FakeHost.new);
    final created = <_FakeAgent>[];
    final manager = AgentConnectionManager(
      hostManager,
      clientFactory: (kind) {
        final agent = _FakeAgent(kind);
        created.add(agent);
        return agent;
      },
    );
    addTearDown(() async {
      await manager.close();
      await hostManager.close();
    });
    final profile = _first.copyWith(workspace: ' /srv/project ');

    await hostManager.connect(profile);
    await manager.connect(profile, AgentKind.openCode);
    final original = created.single;
    final updated = profile.copyWith(
      name: 'renamed',
      workspace: '/srv/project',
    );
    manager.registerProfile(updated);
    await manager.connect(updated, AgentKind.openCode);

    expect(created, hasLength(1));
    expect(original.closed, isFalse);
    expect(original.connectCount, 1);
  });

  test('replaces the OpenCode lane when the workspace changes', () async {
    final hostManager = ServerConnectionManager(clientFactory: _FakeHost.new);
    final created = <_FakeAgent>[];
    final manager = AgentConnectionManager(
      hostManager,
      clientFactory: (kind) {
        final agent = _FakeAgent(kind);
        created.add(agent);
        return agent;
      },
    );
    addTearDown(() async {
      await manager.close();
      await hostManager.close();
    });
    final originalProfile = _first.copyWith(workspace: '/srv/old');

    await hostManager.connect(originalProfile);
    await manager.connect(originalProfile, AgentKind.openCode);
    final original = created.single;
    final updated = originalProfile.copyWith(workspace: '/srv/new');
    manager.registerProfile(updated);
    await manager.connect(updated, AgentKind.openCode);

    expect(created, hasLength(2));
    expect(original.closed, isTrue);
    expect(created.last.connectCount, 1);
  });

  test('reuses the Codex lane when only the workspace changes', () async {
    final hostManager = ServerConnectionManager(clientFactory: _FakeHost.new);
    final created = <_FakeAgent>[];
    final manager = AgentConnectionManager(
      hostManager,
      clientFactory: (kind) {
        final agent = _FakeAgent(kind);
        created.add(agent);
        return agent;
      },
    );
    addTearDown(() async {
      await manager.close();
      await hostManager.close();
    });
    final originalProfile = _first.copyWith(workspace: '/srv/old');

    await hostManager.connect(originalProfile);
    await manager.connect(originalProfile, AgentKind.codex);
    final original = created.single;
    final updated = originalProfile.copyWith(workspace: '/srv/new');
    manager.registerProfile(updated);
    await manager.connect(updated, AgentKind.codex);

    expect(created, hasLength(1));
    expect(original.closed, isFalse);
    expect(original.connectCount, 1);
  });

  test(
    'forwards all thread mutations to the connected mutation client',
    () async {
      final hostManager = ServerConnectionManager(clientFactory: _FakeHost.new);
      late _FakeMutationAgent client;
      final manager = AgentConnectionManager(
        hostManager,
        clientFactory: (kind) => client = _FakeMutationAgent(kind),
      );
      addTearDown(() async {
        await manager.close();
        await hostManager.close();
      });
      const key = AgentConnectionKey(
        profileId: 'first',
        agent: AgentKind.codex,
      );
      const expectedGoal = ThreadGoal(
        threadId: 'thread-1',
        objective: '已有目标',
        status: ThreadGoalStatus.active,
        tokenBudget: 400,
      );

      await hostManager.connect(_first);
      await manager.connect(_first, AgentKind.codex);
      client.readGoal = expectedGoal;

      await manager.compactThread(key, threadId: 'thread-1');
      final rollback = await manager.rollbackThread(
        key,
        threadId: 'thread-1',
        approvalMode: ApprovalMode.autoApprove,
        turns: 2,
      );
      await manager.archiveThread(key, threadId: 'thread-1');
      await manager.setThreadName(key, threadId: 'thread-1', name: '新名称');
      await manager.startReview(key, threadId: 'thread-1');
      final readGoal = await manager.getThreadGoal(key, threadId: 'thread-1');
      final updatedGoal = await manager.setThreadGoal(
        key,
        threadId: 'thread-1',
        objective: '新目标',
        status: ThreadGoalStatus.paused,
        tokenBudget: 800,
      );
      await manager.clearThreadGoal(key, threadId: 'thread-1');

      expect(client.calls, <String>[
        'compact:thread-1',
        'rollback:thread-1',
        'archive:thread-1',
        'name:thread-1',
        'review:thread-1',
        'goal-get:thread-1',
        'goal-set:thread-1',
        'goal-clear:thread-1',
      ]);
      expect(rollback.thread.title, 'rolled back');
      expect(client.rollbackThreadId, 'thread-1');
      expect(client.rollbackApprovalMode, ApprovalMode.autoApprove);
      expect(client.rollbackTurns, 2);
      expect(client.renamedThreadId, 'thread-1');
      expect(client.renamedValue, '新名称');
      expect(readGoal, expectedGoal);
      expect(
        updatedGoal,
        const ThreadGoal(
          threadId: 'thread-1',
          objective: '新目标',
          status: ThreadGoalStatus.paused,
          tokenBudget: 800,
        ),
      );
      expect(client.goalThreadId, 'thread-1');
      expect(client.goalObjective, '新目标');
      expect(client.goalStatus, ThreadGoalStatus.paused);
      expect(client.goalTokenBudget, 800);
    },
  );

  test(
    'rejects a thread mutation result after its lane generation changes',
    () async {
      final hostManager = ServerConnectionManager(clientFactory: _FakeHost.new);
      late _FakeMutationAgent client;
      final manager = AgentConnectionManager(
        hostManager,
        clientFactory: (kind) => client = _FakeMutationAgent(kind),
      );
      addTearDown(() async {
        await manager.close();
        await hostManager.close();
      });
      const key = AgentConnectionKey(
        profileId: 'first',
        agent: AgentKind.codex,
      );

      await hostManager.connect(_first);
      await manager.connect(_first, AgentKind.codex);
      client.compactCompleter = Completer<void>();
      final pending = manager.compactThread(key, threadId: 'thread-1');
      expect(client.calls, <String>['compact:thread-1']);

      await manager.disconnect(_first.id, agent: AgentKind.codex);
      client.compactCompleter!.complete();

      await expectLater(
        pending,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Agent 压缩请求已失效',
          ),
        ),
      );
    },
  );

  test('explicit disconnect stops a durable remote Agent session', () async {
    final hostManager = ServerConnectionManager(clientFactory: _FakeHost.new);
    late _DurableFakeAgent client;
    final manager = AgentConnectionManager(
      hostManager,
      clientFactory: (kind) => client = _DurableFakeAgent(kind),
    );
    addTearDown(() async {
      await manager.close();
      await hostManager.close();
    });

    await hostManager.connect(_first);
    await manager.connect(_first, AgentKind.codex);
    await manager.disconnect(_first.id, agent: AgentKind.codex);

    expect(client.stopCount, 1);
    expect(client.disconnectCount, 1);
  });

  test('disconnect does not wait for an active runtime installation', () async {
    final hostManager = ServerConnectionManager(clientFactory: _FakeHost.new);
    late _FakeRuntimeAgent client;
    final manager = AgentConnectionManager(
      hostManager,
      clientFactory: (kind) => client = _FakeRuntimeAgent(kind),
    );
    addTearDown(() async {
      if (!client.finishInstall.isCompleted) client.finishInstall.complete();
      await manager.close();
      await hostManager.close();
    });
    const key = AgentConnectionKey(profileId: 'first', agent: AgentKind.codex);

    await hostManager.connect(_first);
    final install = manager.installRuntime(
      _first,
      AgentKind.codex,
      onProgress: (_) {},
    );
    await client.installStarted.future;
    expect(manager.states[key]?.phase, ConnectionPhase.installing);

    await manager
        .disconnect(_first.id, agent: AgentKind.codex)
        .timeout(const Duration(seconds: 1));
    expect(manager.states[key]?.phase, ConnectionPhase.disconnected);

    client.finishInstall.complete();
    await expectLater(
      install,
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Agent 安装任务已失效',
        ),
      ),
    );

    await manager.installRuntime(_first, AgentKind.codex, onProgress: (_) {});
    expect(client.installCount, 2);
  });

  test('runtime prepare coalesces disconnect until the host closes', () async {
    late _FakeHost host;
    final hostManager = ServerConnectionManager(
      clientFactory: () => host = _FakeHost(),
    );
    late _FakeRuntimeAgent client;
    final manager = AgentConnectionManager(
      hostManager,
      clientFactory: (kind) => client = _FakeRuntimeAgent(kind),
    );
    addTearDown(() async {
      final disconnectGate = client.firstDisconnectGate;
      if (disconnectGate != null && !disconnectGate.isCompleted) {
        disconnectGate.complete();
      }
      if (!client.finishInstall.isCompleted) client.finishInstall.complete();
      await manager.close();
      await hostManager.close();
    });

    await hostManager.connect(_first);
    await manager.connect(_first, AgentKind.codex);
    client.firstDisconnectGate = Completer<void>();
    host.onDisconnect = () {
      final gate = client.firstDisconnectGate;
      if (gate != null && !gate.isCompleted) gate.complete();
    };
    final install = manager.installRuntime(
      _first,
      AgentKind.codex,
      onProgress: (_) {},
    );
    final installExpectation = expectLater(
      install,
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Agent 安装任务已失效',
        ),
      ),
    );
    await client.firstDisconnectStarted.future;

    final laneDisconnect = manager.disconnect(
      _first.id,
      agent: AgentKind.codex,
    );
    await Future<void>.delayed(Duration.zero);
    expect(client.disconnectCount, 1);
    expect(client.maximumActiveDisconnects, 1);

    await hostManager.disconnect(_first.id).timeout(const Duration(seconds: 1));
    await laneDisconnect.timeout(const Duration(seconds: 1));
    expect(client.maximumActiveDisconnects, 1);
    expect(client.installCount, 0);

    await installExpectation;
  });

  test(
    'disconnect rejects a runtime operation queued behind an install',
    () async {
      final hostManager = ServerConnectionManager(clientFactory: _FakeHost.new);
      late _FakeRuntimeAgent client;
      final manager = AgentConnectionManager(
        hostManager,
        clientFactory: (kind) => client = _FakeRuntimeAgent(kind),
      );
      addTearDown(() async {
        if (!client.finishInstall.isCompleted) client.finishInstall.complete();
        await manager.close();
        await hostManager.close();
      });

      await hostManager.connect(_first);
      final install = manager.installRuntime(
        _first,
        AgentKind.codex,
        onProgress: (_) {},
      );
      await client.installStarted.future;
      final inspect = manager.inspectRuntime(_first, AgentKind.codex);
      final installExpectation = expectLater(
        install,
        throwsA(isA<StateError>()),
      );
      final inspectExpectation = expectLater(
        inspect,
        throwsA(isA<StateError>()),
      );

      await manager.disconnect(_first.id, agent: AgentKind.codex);
      client.finishInstall.complete();

      await installExpectation;
      await inspectExpectation;
      expect(client.inspectCount, 0);
      expect(
        manager
            .states[const AgentConnectionKey(
              profileId: 'first',
              agent: AgentKind.codex,
            )]
            ?.phase,
        ConnectionPhase.disconnected,
      );
    },
  );

  test(
    'profile runtime lock survives remove and same-id registration',
    () async {
      final hostManager = ServerConnectionManager(clientFactory: _FakeHost.new);
      final clients = <_FakeRuntimeAgent>[];
      final manager = AgentConnectionManager(
        hostManager,
        clientFactory: (kind) {
          final client = _FakeRuntimeAgent(kind);
          clients.add(client);
          return client;
        },
      );
      addTearDown(() async {
        for (final client in clients) {
          if (!client.finishInstall.isCompleted) {
            client.finishInstall.complete();
          }
        }
        await manager.close();
        await hostManager.close();
      });

      await hostManager.connect(_first);
      final first = manager.installRuntime(
        _first,
        AgentKind.codex,
        onProgress: (_) {},
      );
      await clients.single.installStarted.future;
      final firstExpectation = expectLater(first, throwsA(isA<StateError>()));

      manager.remove(_first.id);
      final second = manager.installRuntime(
        _first,
        AgentKind.codex,
        onProgress: (_) {},
      );
      await Future<void>.delayed(Duration.zero);
      expect(clients, hasLength(2));
      expect(clients.last.installStarted.isCompleted, isFalse);

      clients.first.finishInstall.complete();
      await firstExpectation;
      await clients.last.installStarted.future;
      clients.last.finishInstall.complete();
      await second;
      expect(clients.last.installCount, 1);
    },
  );

  test(
    'runtime inspection preserves connection and uninstall disconnects',
    () async {
      final hostManager = ServerConnectionManager(clientFactory: _FakeHost.new);
      late _FakeRuntimeAgent client;
      final manager = AgentConnectionManager(
        hostManager,
        clientFactory: (kind) => client = _FakeRuntimeAgent(kind),
      );
      addTearDown(() async {
        if (!client.finishInstall.isCompleted) client.finishInstall.complete();
        await manager.close();
        await hostManager.close();
      });
      const key = AgentConnectionKey(
        profileId: 'first',
        agent: AgentKind.codex,
      );

      await hostManager.connect(_first);
      await manager.connect(_first, AgentKind.codex);
      await manager.inspectRuntime(_first, AgentKind.codex);

      expect(client.isConnected, isTrue);
      expect(manager.states[key]?.phase, ConnectionPhase.connected);

      client.inspectError = StateError('probe failed');
      await expectLater(
        manager.inspectRuntime(_first, AgentKind.codex),
        throwsA(isA<StateError>()),
      );
      expect(client.isConnected, isTrue);
      expect(manager.states[key]?.phase, ConnectionPhase.connected);

      await manager.uninstallRuntime(_first, AgentKind.codex);
      expect(client.isConnected, isFalse);
      expect(client.uninstallCount, 1);
      expect(manager.states[key]?.phase, ConnectionPhase.disconnected);
    },
  );

  test('runtime provisioning rejects a stale profile identity', () async {
    final hostManager = ServerConnectionManager(clientFactory: _FakeHost.new);
    final clients = <_FakeRuntimeAgent>[];
    final manager = AgentConnectionManager(
      hostManager,
      clientFactory: (kind) {
        final client = _FakeRuntimeAgent(kind);
        clients.add(client);
        return client;
      },
    );
    addTearDown(() async {
      for (final client in clients) {
        if (!client.finishInstall.isCompleted) {
          client.finishInstall.complete();
        }
      }
      await manager.close();
      await hostManager.close();
    });

    await hostManager.connect(_first);
    final stale = _first.copyWith(host: 'replacement.example');

    await expectLater(
      manager.installRuntime(stale, AgentKind.codex, onProgress: (_) {}),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          '请先连接 SSH 服务器',
        ),
      ),
    );
    expect(clients.single.installCount, 0);
  });
}
