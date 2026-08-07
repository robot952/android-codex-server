import 'dart:async';

import 'package:synchronized/synchronized.dart';

import '../domain/models.dart';
import '../ssh/server_connection_manager.dart';
import 'codex_agent_client.dart';
import 'opencode_agent_client.dart';
import 'remote_agent_client.dart';
import 'remote_bootstrap.dart';

typedef RemoteAgentClientFactory = RemoteAgentClient Function(AgentKind kind);

class AgentEventEnvelope {
  const AgentEventEnvelope({required this.key, required this.event});

  final AgentConnectionKey key;
  final RemoteAgentEvent event;
}

/// Owns one independent app-server lane for each `(profileId, AgentKind)`.
class AgentConnectionManager {
  AgentConnectionManager(this._hosts, {RemoteAgentClientFactory? clientFactory})
    : _clientFactory = clientFactory ?? _defaultClientFactory {
    _hostStateSubscription = _hosts.stateChanges.listen(_applyHostStates);
  }

  final ServerConnectionManager _hosts;
  final RemoteAgentClientFactory _clientFactory;
  final Map<AgentConnectionKey, _AgentEntry> _entries = {};
  final Map<AgentConnectionKey, ConnectionState> _states = {};
  final Map<String, Lock> _runtimeLocks = {};
  final StreamController<Map<AgentConnectionKey, ConnectionState>>
  _stateController =
      StreamController<Map<AgentConnectionKey, ConnectionState>>.broadcast(
        sync: true,
      );
  final StreamController<AgentEventEnvelope> _eventController =
      StreamController<AgentEventEnvelope>.broadcast(sync: true);
  late final StreamSubscription<Map<String, ConnectionState>>
  _hostStateSubscription;
  bool _closed = false;

  Map<AgentConnectionKey, ConnectionState> get states =>
      Map<AgentConnectionKey, ConnectionState>.unmodifiable(_states);

  Stream<Map<AgentConnectionKey, ConnectionState>> get stateChanges =>
      _stateController.stream;

  Stream<AgentEventEnvelope> get events => _eventController.stream;

  void registerProfile(ServerProfile profile) {
    _ensureOpen();
    for (final entry in _entries.entries.toList()) {
      if (entry.key.profileId != profile.id) continue;
      if (_sameLaneIdentity(entry.value.profile, profile, entry.key.agent)) {
        entry.value.profile = profile;
        continue;
      }
      _removeEntry(entry.key);
    }
  }

  int generation(AgentConnectionKey key) => _entries[key]?.generation ?? -1;

  bool isCurrentGeneration(AgentConnectionKey key, int generation) =>
      _entries[key]?.generation == generation;

  int? remoteGeneration(AgentConnectionKey key) {
    final client = _entries[key]?.client;
    if (client is! RemoteAgentGenerationClient) return null;
    return (client as RemoteAgentGenerationClient).currentGeneration;
  }

  AgentCapabilities capabilities(AgentConnectionKey key) =>
      _entries[key]?.client.capabilities ?? AgentCapabilities.none;

  Future<AgentRuntimeInspection> inspectRuntime(
    ServerProfile profile,
    AgentKind agent,
  ) async {
    _ensureOpen();
    final key = AgentConnectionKey(profileId: profile.id, agent: agent);
    final entry = _ensureEntry(key, profile);
    final runtimeClient = entry.client is RemoteAgentRuntimeClient
        ? entry.client as RemoteAgentRuntimeClient
        : null;
    if (runtimeClient == null) {
      final inspection = AgentRuntimeInspection.bypass(profile.remoteCommand);
      entry.runtimeCommand = inspection.compatibleCommand;
      return inspection;
    }
    final host = _requireConnectedHost(profile);
    final requestGeneration = entry.generation;
    final runtimeLock = _runtimeLocks.putIfAbsent(profile.id, Lock.new);
    return runtimeLock.synchronized(
      () => _runRuntimeOperation<AgentRuntimeInspection>(
        key: key,
        entry: entry,
        expectedGeneration: requestGeneration,
        isHostCurrent: () => _hosts.isLeaseCurrent(profile, host),
        inProgressState: ConnectionState(
          phase: ConnectionPhase.probing,
          message: '正在检测 ${agent.label}',
        ),
        successState: (_) => entry.client.isConnected
            ? ConnectionState(
                phase: ConnectionPhase.connected,
                message: '${agent.label} 已连接',
              )
            : const ConnectionState(),
        invalidMessage: 'Agent 运行时探测已失效',
        failureMessage: '${agent.label} 运行时探测失败',
        failureState: (error) => entry.client.isConnected
            ? ConnectionState(
                phase: ConnectionPhase.connected,
                message: '${agent.label} 已连接；运行时探测失败',
              )
            : ConnectionState(
                phase: ConnectionPhase.failed,
                message: _message(error, '${agent.label} 运行时探测失败'),
              ),
        operation: (_) => runtimeClient.inspectRuntime(profile, host.client),
        onSuccess: (inspection) {
          entry.runtimeCommand = inspection.compatibleCommand;
        },
      ),
    );
  }

  Future<void> installRuntime(
    ServerProfile profile,
    AgentKind agent, {
    required void Function(RemoteInstallProgress progress) onProgress,
  }) async {
    _ensureOpen();
    final key = AgentConnectionKey(profileId: profile.id, agent: agent);
    final entry = _ensureEntry(key, profile);
    final runtimeClient = entry.client is RemoteAgentRuntimeClient
        ? entry.client as RemoteAgentRuntimeClient
        : throw UnsupportedError('${agent.label} 适配器不支持自动安装');
    final host = _requireConnectedHost(profile);
    final requestGeneration = entry.generation;
    final runtimeLock = _runtimeLocks.putIfAbsent(profile.id, Lock.new);
    await runtimeLock.synchronized(
      () => _runRuntimeOperation<void>(
        key: key,
        entry: entry,
        expectedGeneration: requestGeneration,
        isHostCurrent: () => _hosts.isLeaseCurrent(profile, host),
        inProgressState: ConnectionState(
          phase: ConnectionPhase.installing,
          message: '正在安装 ${agent.label}',
        ),
        successState: (_) => ConnectionState(
          phase: ConnectionPhase.disconnected,
          message: '${agent.label} 安装完成',
        ),
        invalidMessage: 'Agent 安装任务已失效',
        failureMessage: '${agent.label} 安装失败',
        prepare: () async {
          entry.runtimeCommand = null;
          if (entry.client.isConnected) await _disconnectClient(entry);
        },
        operation: (generation) => runtimeClient.installRuntime(
          profile,
          host.client,
          onProgress: (progress) {
            if (_isRuntimeOperationCurrent(
              key,
              entry,
              generation,
              () => _hosts.isLeaseCurrent(profile, host),
            )) {
              onProgress(progress);
            }
          },
        ),
      ),
    );
  }

  Future<void> uninstallRuntime(ServerProfile profile, AgentKind agent) async {
    _ensureOpen();
    final key = AgentConnectionKey(profileId: profile.id, agent: agent);
    final entry = _ensureEntry(key, profile);
    final runtimeClient = entry.client is RemoteAgentRuntimeClient
        ? entry.client as RemoteAgentRuntimeClient
        : throw UnsupportedError('${agent.label} 适配器不支持卸载托管运行时');
    final host = _requireConnectedHost(profile);
    final requestGeneration = entry.generation;
    final runtimeLock = _runtimeLocks.putIfAbsent(profile.id, Lock.new);
    await runtimeLock.synchronized(
      () => _runRuntimeOperation<void>(
        key: key,
        entry: entry,
        expectedGeneration: requestGeneration,
        isHostCurrent: () => _hosts.isLeaseCurrent(profile, host),
        inProgressState: ConnectionState(
          phase: ConnectionPhase.installing,
          message: '正在卸载 ${agent.label}',
        ),
        successState: (_) => const ConnectionState(),
        invalidMessage: 'Agent 卸载任务已失效',
        failureMessage: '${agent.label} 卸载失败',
        prepare: () async {
          if (entry.client.isConnected) await _disconnectClient(entry);
        },
        operation: (_) => runtimeClient.uninstallRuntime(profile, host.client),
        onSuccess: (_) {
          entry.runtimeCommand = null;
        },
      ),
    );
  }

  Future<void> connect(ServerProfile profile, AgentKind agent) async {
    _ensureOpen();
    final key = AgentConnectionKey(profileId: profile.id, agent: agent);
    final entry = _ensureEntry(key, profile);
    await entry.lock.synchronized(() async {
      if (!_isCurrent(key, entry)) throw StateError('Agent 连接已失效');
      if (entry.runtimeOperationGeneration != null) {
        throw StateError('${agent.label} 运行时操作进行中');
      }
      final host = _hosts.client(profile.id);
      final hostState = _hosts.states[profile.id];
      if (host == null ||
          !host.isConnected ||
          hostState?.phase != ConnectionPhase.connected) {
        throw StateError('请先连接 SSH 服务器');
      }
      if (entry.client.isConnected) {
        _setState(
          key,
          ConnectionState(
            phase: ConnectionPhase.connected,
            message: '${agent.label} 已连接',
          ),
        );
        return;
      }

      final generation = ++entry.generation;
      _setState(
        key,
        ConnectionState(
          phase: ConnectionPhase.connecting,
          message: '正在连接 ${agent.label}',
        ),
      );
      try {
        final effectiveProfile = entry.runtimeCommand == null
            ? profile
            : profile.copyWith(remoteCommand: entry.runtimeCommand!);
        await entry.client.connect(effectiveProfile, host);
        if (!_isCurrent(key, entry) || entry.generation != generation) {
          entry.client.close();
          throw StateError('Agent 连接配置已更新');
        }
        _setState(
          key,
          ConnectionState(
            phase: ConnectionPhase.connected,
            message: '${agent.label} 已连接',
          ),
        );
      } catch (error) {
        if (_isCurrent(key, entry) && entry.generation == generation) {
          _setState(
            key,
            ConnectionState(
              phase: ConnectionPhase.failed,
              message: _message(error, '${agent.label} 连接失败'),
            ),
          );
        }
        rethrow;
      }
    });
  }

  Future<List<AgentModel>> listModels(AgentConnectionKey key) async {
    final entry = _requireConnected(key);
    final generation = entry.generation;
    final result = await entry.client.listModels();
    if (!_isCurrent(key, entry) || entry.generation != generation) {
      throw StateError('Agent 模型列表请求已失效');
    }
    return result;
  }

  Future<AgentThreadPage> listThreads(
    AgentConnectionKey key, {
    String? searchTerm,
  }) async {
    final entry = _requireConnected(key);
    final generation = entry.generation;
    final result = await entry.client.listThreads(searchTerm: searchTerm);
    if (!_isCurrent(key, entry) || entry.generation != generation) {
      throw StateError('Agent 会话列表请求已失效');
    }
    return result;
  }

  Future<AgentThreadPage> listMoreThreads(
    AgentConnectionKey key, {
    required String cursor,
    String? searchTerm,
  }) async {
    final entry = _requireConnected(key);
    final pagination = entry.client;
    if (pagination is! RemoteAgentThreadPaginationClient) {
      throw UnsupportedError('${key.agent.label} 不支持会话列表分页');
    }
    final paginatedClient = pagination as RemoteAgentThreadPaginationClient;
    final generation = entry.generation;
    final result = await paginatedClient.listThreadsPage(
      searchTerm: searchTerm,
      cursor: cursor,
    );
    if (!_isCurrent(key, entry) || entry.generation != generation) {
      throw StateError('Agent 会话列表分页请求已失效');
    }
    return result;
  }

  Future<AgentSession> resumeThread(
    AgentConnectionKey key,
    String threadId, {
    ApprovalMode approvalMode = ApprovalMode.requestApproval,
  }) async {
    final entry = _requireConnected(key);
    final generation = entry.generation;
    final result = await entry.client.resumeThread(
      threadId,
      approvalMode: approvalMode,
    );
    if (!_isCurrent(key, entry) || entry.generation != generation) {
      throw StateError('Agent 会话恢复请求已失效');
    }
    return result;
  }

  Future<AgentTurnsPage> loadOlderTurns(
    AgentConnectionKey key, {
    required String threadId,
    required String cursor,
    int? subAgentCreatedAt,
  }) async {
    final entry = _requireConnected(key);
    final generation = entry.generation;
    final result = await entry.client.loadOlderTurns(
      threadId: threadId,
      cursor: cursor,
      subAgentCreatedAt: subAgentCreatedAt,
    );
    if (!_isCurrent(key, entry) || entry.generation != generation) {
      throw StateError('Agent 历史请求已失效');
    }
    return result;
  }

  Future<String> startTurn(
    AgentConnectionKey key, {
    required String threadId,
    required String text,
    List<PendingAttachment> attachments = const <PendingAttachment>[],
    String? model,
    String? effort,
    ApprovalMode approvalMode = ApprovalMode.requestApproval,
    SandboxChoice? sandbox,
    String? cwd,
  }) async {
    final entry = _requireConnected(key);
    final generation = entry.generation;
    final turnClient = entry.client is RemoteAgentTurnClient
        ? entry.client as RemoteAgentTurnClient
        : null;
    if (turnClient == null) {
      throw UnsupportedError('${key.agent.label} 适配器不支持发送消息');
    }
    final turnId = await turnClient.startTurn(
      threadId: threadId,
      text: text,
      attachments: attachments,
      model: model,
      effort: effort,
      approvalMode: approvalMode,
      sandbox: sandbox,
      cwd: cwd,
    );
    if (!_isCurrent(key, entry) || entry.generation != generation) {
      throw StateError('Agent 消息请求已失效');
    }
    return turnId;
  }

  Future<AgentSession> startThread(
    AgentConnectionKey key, {
    String? cwd,
    String? model,
    ApprovalMode approvalMode = ApprovalMode.requestApproval,
    SandboxChoice? sandbox,
  }) async {
    final entry = _requireConnected(key);
    final generation = entry.generation;
    final createClient = entry.client is RemoteAgentThreadCreateClient
        ? entry.client as RemoteAgentThreadCreateClient
        : null;
    if (createClient == null) {
      throw UnsupportedError('${key.agent.label} 适配器不支持新建会话');
    }
    final session = await createClient.startThread(
      cwd: cwd,
      model: model,
      approvalMode: approvalMode,
      sandbox: sandbox,
    );
    if (!_isCurrent(key, entry) || entry.generation != generation) {
      throw StateError('Agent 新建会话请求已失效');
    }
    return session;
  }

  Future<void> interruptTurn(
    AgentConnectionKey key, {
    required String threadId,
    required String turnId,
  }) async {
    final entry = _requireConnected(key);
    final generation = entry.generation;
    final turnClient = entry.client is RemoteAgentTurnClient
        ? entry.client as RemoteAgentTurnClient
        : null;
    if (turnClient == null) {
      throw UnsupportedError('${key.agent.label} 适配器不支持停止消息');
    }
    await turnClient.interruptTurn(threadId: threadId, turnId: turnId);
    if (!_isCurrent(key, entry) || entry.generation != generation) {
      throw StateError('Agent 停止请求已失效');
    }
  }

  Future<void> steerTurn(
    AgentConnectionKey key, {
    required String threadId,
    required String turnId,
    required String text,
    List<PendingAttachment> attachments = const <PendingAttachment>[],
  }) async {
    final entry = _requireConnected(key);
    final generation = entry.generation;
    final client = entry.client;
    if (client is! RemoteAgentSteerClient) {
      throw UnsupportedError('${key.agent.label} 适配器不支持连续发送');
    }
    await (client as RemoteAgentSteerClient).steerTurn(
      threadId: threadId,
      turnId: turnId,
      text: text,
      attachments: attachments,
    );
    _requireCurrentRequest(key, entry, generation, 'Agent 连续发送请求已失效');
  }

  Future<void> answerApproval(
    AgentConnectionKey key,
    ApprovalPrompt prompt, {
    required bool accept,
    Map<String, String> answers = const <String, String>{},
  }) async {
    final entry = _requireConnected(key);
    final generation = entry.generation;
    final approvalClient = entry.client is RemoteAgentApprovalClient
        ? entry.client as RemoteAgentApprovalClient
        : null;
    if (approvalClient == null) {
      throw UnsupportedError('${key.agent.label} 适配器不支持审批');
    }
    await approvalClient.answerApproval(
      prompt,
      accept: accept,
      answers: answers,
    );
    if (!_isCurrent(key, entry) || entry.generation != generation) {
      throw StateError('Agent 审批请求已失效');
    }
  }

  Future<void> compactThread(
    AgentConnectionKey key, {
    required String threadId,
  }) async {
    final entry = _requireConnected(key);
    final generation = entry.generation;
    final client = _requireThreadMutationClient(key, entry);
    await client.compactThread(threadId);
    _requireCurrentRequest(key, entry, generation, 'Agent 压缩请求已失效');
  }

  Future<AgentSession> rollbackThread(
    AgentConnectionKey key, {
    required String threadId,
    ApprovalMode approvalMode = ApprovalMode.requestApproval,
    int turns = 1,
  }) async {
    final entry = _requireConnected(key);
    final generation = entry.generation;
    final client = _requireThreadMutationClient(key, entry);
    final session = await client.rollbackThread(
      threadId,
      approvalMode: approvalMode,
      turns: turns,
    );
    _requireCurrentRequest(key, entry, generation, 'Agent 回退请求已失效');
    return session;
  }

  Future<void> archiveThread(
    AgentConnectionKey key, {
    required String threadId,
  }) async {
    final entry = _requireConnected(key);
    final generation = entry.generation;
    final client = _requireThreadMutationClient(key, entry);
    await client.archiveThread(threadId);
    _requireCurrentRequest(key, entry, generation, 'Agent 归档请求已失效');
  }

  Future<void> setThreadName(
    AgentConnectionKey key, {
    required String threadId,
    required String name,
  }) async {
    final entry = _requireConnected(key);
    final generation = entry.generation;
    final client = _requireThreadMutationClient(key, entry);
    await client.setThreadName(threadId, name);
    _requireCurrentRequest(key, entry, generation, 'Agent 重命名请求已失效');
  }

  Future<void> startReview(
    AgentConnectionKey key, {
    required String threadId,
  }) async {
    final entry = _requireConnected(key);
    final generation = entry.generation;
    final client = _requireThreadMutationClient(key, entry);
    await client.startReview(threadId);
    _requireCurrentRequest(key, entry, generation, 'Agent 审查请求已失效');
  }

  Future<ThreadGoal?> getThreadGoal(
    AgentConnectionKey key, {
    required String threadId,
  }) async {
    final entry = _requireConnected(key);
    final generation = entry.generation;
    final client = _requireThreadMutationClient(key, entry);
    final goal = await client.getThreadGoal(threadId);
    _requireCurrentRequest(key, entry, generation, 'Agent 目标读取请求已失效');
    return goal;
  }

  Future<ThreadGoal> setThreadGoal(
    AgentConnectionKey key, {
    required String threadId,
    String? objective,
    ThreadGoalStatus? status,
    int? tokenBudget,
  }) async {
    final entry = _requireConnected(key);
    final generation = entry.generation;
    final client = _requireThreadMutationClient(key, entry);
    final goal = await client.setThreadGoal(
      threadId,
      objective: objective,
      status: status,
      tokenBudget: tokenBudget,
    );
    _requireCurrentRequest(key, entry, generation, 'Agent 目标更新请求已失效');
    return goal;
  }

  Future<void> clearThreadGoal(
    AgentConnectionKey key, {
    required String threadId,
  }) async {
    final entry = _requireConnected(key);
    final generation = entry.generation;
    final client = _requireThreadMutationClient(key, entry);
    await client.clearThreadGoal(threadId);
    _requireCurrentRequest(key, entry, generation, 'Agent 目标删除请求已失效');
  }

  Future<AgentGlobalSettings> readGlobalSettings(
    AgentConnectionKey key,
    ServerProfile profile,
  ) async {
    final entry = _requireConnected(key);
    final generation = entry.generation;
    final client = _requireGlobalSettingsClient(key, entry, profile);
    final settings = await client.readGlobalSettings(profile);
    _requireCurrentRequest(key, entry, generation, 'Agent 全局配置读取请求已失效');
    return settings;
  }

  Future<void> writeGlobalSettings(
    AgentConnectionKey key,
    ServerProfile profile, {
    required String baseUrl,
    required String apiKey,
    required String proxyUrl,
    required String defaultModel,
    required String defaultReasoningEffort,
    required bool preserveCurrentProvider,
  }) async {
    final entry = _requireConnected(key);
    final generation = entry.generation;
    final client = _requireGlobalSettingsClient(key, entry, profile);
    await client.writeGlobalSettings(
      profile,
      baseUrl: baseUrl,
      apiKey: apiKey,
      proxyUrl: proxyUrl,
      defaultModel: defaultModel,
      defaultReasoningEffort: defaultReasoningEffort,
      preserveCurrentProvider: preserveCurrentProvider,
    );
    _requireCurrentRequest(key, entry, generation, 'Agent 全局配置保存请求已失效');
  }

  Future<AgentConnectionTestResult> testGlobalSettings(
    AgentConnectionKey key,
    ServerProfile profile, {
    required String baseUrl,
    required String apiKey,
    required String proxyUrl,
    required String testModel,
  }) async {
    final entry = _requireConnected(key);
    final generation = entry.generation;
    final client = _requireGlobalSettingsClient(key, entry, profile);
    final result = await client.testGlobalSettings(
      profile,
      baseUrl: baseUrl,
      apiKey: apiKey,
      proxyUrl: proxyUrl,
      testModel: testModel,
    );
    _requireCurrentRequest(key, entry, generation, 'Agent API 测试请求已失效');
    return result;
  }

  Future<List<ApiModelOption>> fetchApiModels(
    AgentConnectionKey key,
    ServerProfile profile, {
    required String baseUrl,
    required String apiKey,
    required String proxyUrl,
  }) async {
    final entry = _requireConnected(key);
    final generation = entry.generation;
    if (!_sameLaneIdentity(entry.profile, profile, key.agent)) {
      throw StateError('Agent 连接配置已更新');
    }
    final client = entry.client;
    final apiModelClient = client is RemoteAgentApiModelClient
        ? client as RemoteAgentApiModelClient
        : throw UnsupportedError('${key.agent.label} 适配器不支持获取 API 模型');
    final result = await apiModelClient.fetchApiModels(
      profile,
      baseUrl: baseUrl,
      apiKey: apiKey,
      proxyUrl: proxyUrl,
    );
    _requireCurrentRequest(key, entry, generation, 'Agent 模型列表请求已失效');
    return result;
  }

  Future<void> ensureCustomModel(
    AgentConnectionKey key,
    ServerProfile profile,
    CustomModelDefinition definition,
  ) async {
    final entry = _requireConnected(key);
    final generation = entry.generation;
    final client = _requireCustomModelClient(key, entry, profile);
    await client.ensureCustomModel(profile, definition);
    _requireCurrentRequest(key, entry, generation, 'Agent 模型注册请求已失效');
  }

  Future<void> syncCustomModels(
    AgentConnectionKey key,
    ServerProfile profile, {
    required List<CustomModelDefinition> definitions,
    required List<String> removedModelIds,
  }) async {
    final entry = _requireConnected(key);
    final generation = entry.generation;
    final client = _requireCustomModelClient(key, entry, profile);
    await client.syncCustomModels(
      profile,
      definitions: definitions,
      removedModelIds: removedModelIds,
    );
    _requireCurrentRequest(key, entry, generation, 'Agent 模型同步请求已失效');
  }

  Future<void> disconnect(String profileId, {AgentKind? agent}) async {
    final targets = _entries.entries
        .where(
          (entry) =>
              entry.key.profileId == profileId &&
              (agent == null || entry.key.agent == agent),
        )
        .toList();
    for (final target in targets) {
      final key = target.key;
      final entry = target.value;
      await entry.lock.synchronized(() async {
        if (!_isCurrent(key, entry)) return;
        entry.generation++;
        await _disconnectClient(entry);
        if (_isCurrent(key, entry)) _setState(key, const ConnectionState());
      });
    }
  }

  void remove(String profileId) {
    for (final key
        in _entries.keys.where((key) => key.profileId == profileId).toList()) {
      _removeEntry(key);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _hostStateSubscription.cancel();
    final entries = _entries.values.toList();
    _entries.clear();
    _states.clear();
    _runtimeLocks.clear();
    for (final entry in entries) {
      entry.generation++;
      await entry.eventSubscription.cancel();
      entry.client.close();
    }
    await _stateController.close();
    await _eventController.close();
  }

  _AgentEntry _ensureEntry(AgentConnectionKey key, ServerProfile profile) {
    final current = _entries[key];
    if (current != null &&
        _sameLaneIdentity(current.profile, profile, key.agent)) {
      current.profile = profile;
      return current;
    }
    if (current != null) _removeEntry(key);

    final client = _clientFactory(key.agent);
    late final _AgentEntry entry;
    final subscription = client.events.listen((event) {
      if (_isCurrent(key, entry) && !_eventController.isClosed) {
        _eventController.add(AgentEventEnvelope(key: key, event: event));
        if (event is RemoteAgentConnectionLost) {
          _setState(
            key,
            ConnectionState(
              phase: ConnectionPhase.failed,
              message: event.message,
            ),
          );
        }
      }
    });
    entry = _AgentEntry(profile, client, subscription);
    _entries[key] = entry;
    _setState(key, const ConnectionState());
    return entry;
  }

  _AgentEntry _requireConnected(AgentConnectionKey key) {
    final entry = _entries[key];
    if (entry == null || !entry.client.isConnected) {
      throw StateError('${key.agent.label} 尚未连接');
    }
    return entry;
  }

  ServerConnectionLease _requireConnectedHost(ServerProfile profile) {
    final lease = _hosts.connectedLease(profile);
    if (lease == null) {
      throw StateError('请先连接 SSH 服务器');
    }
    return lease;
  }

  RemoteAgentThreadMutationClient _requireThreadMutationClient(
    AgentConnectionKey key,
    _AgentEntry entry,
  ) {
    final client = entry.client;
    if (client is! RemoteAgentThreadMutationClient) {
      throw UnsupportedError('${key.agent.label} 适配器不支持会话操作');
    }
    return client as RemoteAgentThreadMutationClient;
  }

  RemoteAgentGlobalSettingsClient _requireGlobalSettingsClient(
    AgentConnectionKey key,
    _AgentEntry entry,
    ServerProfile profile,
  ) {
    if (!_sameLaneIdentity(entry.profile, profile, key.agent)) {
      throw StateError('Agent 连接配置已更新');
    }
    final client = entry.client;
    if (client is! RemoteAgentGlobalSettingsClient) {
      throw UnsupportedError('${key.agent.label} 适配器不支持全局设置');
    }
    return client as RemoteAgentGlobalSettingsClient;
  }

  RemoteAgentCustomModelClient _requireCustomModelClient(
    AgentConnectionKey key,
    _AgentEntry entry,
    ServerProfile profile,
  ) {
    if (!_sameLaneIdentity(entry.profile, profile, key.agent)) {
      throw StateError('Agent 连接配置已更新');
    }
    final client = entry.client;
    if (client is! RemoteAgentCustomModelClient) {
      throw UnsupportedError('${key.agent.label} 适配器不支持同步自定义模型');
    }
    return client as RemoteAgentCustomModelClient;
  }

  void _requireCurrentRequest(
    AgentConnectionKey key,
    _AgentEntry entry,
    int generation,
    String message,
  ) {
    if (!_isCurrent(key, entry) || entry.generation != generation) {
      throw StateError(message);
    }
  }

  Future<T> _runRuntimeOperation<T>({
    required AgentConnectionKey key,
    required _AgentEntry entry,
    required int expectedGeneration,
    required bool Function() isHostCurrent,
    required ConnectionState inProgressState,
    required ConnectionState Function(T result) successState,
    required String invalidMessage,
    required String failureMessage,
    required Future<T> Function(int generation) operation,
    FutureOr<void> Function()? prepare,
    void Function(T result)? onSuccess,
    ConnectionState Function(Object error)? failureState,
  }) async {
    int? generation;
    try {
      await entry.lock.synchronized(() {
        if (!_isCurrent(key, entry) ||
            entry.generation != expectedGeneration ||
            !isHostCurrent()) {
          throw StateError(invalidMessage);
        }
        final operationGeneration = ++entry.generation;
        generation = operationGeneration;
        entry.runtimeOperationGeneration = operationGeneration;
        _setState(key, inProgressState);
      });

      final operationGeneration = generation!;
      if (prepare != null) await prepare();
      if (!_isRuntimeOperationCurrent(
        key,
        entry,
        operationGeneration,
        isHostCurrent,
      )) {
        throw StateError(invalidMessage);
      }
      final result = await operation(operationGeneration);
      await entry.lock.synchronized(() {
        if (!_isRuntimeOperationCurrent(
          key,
          entry,
          operationGeneration,
          isHostCurrent,
        )) {
          throw StateError(invalidMessage);
        }
        onSuccess?.call(result);
        if (entry.runtimeOperationGeneration == operationGeneration) {
          entry.runtimeOperationGeneration = null;
        }
        _setState(key, successState(result));
      });
      return result;
    } catch (error) {
      final operationGeneration = generation;
      await entry.lock.synchronized(() {
        if (entry.runtimeOperationGeneration == operationGeneration) {
          entry.runtimeOperationGeneration = null;
        }
        if (operationGeneration != null &&
            _isRuntimeOperationCurrent(
              key,
              entry,
              operationGeneration,
              isHostCurrent,
              requireMarker: false,
            )) {
          _setState(
            key,
            failureState?.call(error) ??
                ConnectionState(
                  phase: ConnectionPhase.failed,
                  message: _message(error, failureMessage),
                ),
          );
        }
      });
      rethrow;
    }
  }

  bool _isRuntimeOperationCurrent(
    AgentConnectionKey key,
    _AgentEntry entry,
    int generation,
    bool Function() isHostCurrent, {
    bool requireMarker = true,
  }) =>
      _isCurrent(key, entry) &&
      entry.generation == generation &&
      (!requireMarker || entry.runtimeOperationGeneration == generation) &&
      isHostCurrent();

  Future<void> _disconnectClient(_AgentEntry entry) {
    final pending = entry.disconnectRequest;
    if (pending != null) return pending;
    late final Future<void> request;
    request = Future<void>.sync(entry.client.disconnect).whenComplete(() {
      if (identical(entry.disconnectRequest, request)) {
        entry.disconnectRequest = null;
      }
    });
    entry.disconnectRequest = request;
    return request;
  }

  void _applyHostStates(Map<String, ConnectionState> hostStates) {
    for (final entry in _entries.entries.toList()) {
      if (hostStates[entry.key.profileId]?.phase == ConnectionPhase.connected) {
        continue;
      }
      if (entry.value.client.isConnected ||
          _states[entry.key]?.phase != ConnectionPhase.disconnected) {
        final generation = ++entry.value.generation;
        unawaited(
          entry.value.lock.synchronized(() async {
            if (_isCurrent(entry.key, entry.value) &&
                entry.value.generation == generation) {
              await _disconnectClient(entry.value);
            }
          }),
        );
        _setState(entry.key, const ConnectionState());
      }
    }
  }

  void _removeEntry(AgentConnectionKey key) {
    final entry = _entries.remove(key);
    if (entry == null) return;
    entry.generation++;
    unawaited(entry.eventSubscription.cancel());
    entry.client.close();
    if (_states.remove(key) != null) _emitStates();
  }

  void _setState(AgentConnectionKey key, ConnectionState state) {
    if (_closed || !_entries.containsKey(key)) return;
    _states[key] = state;
    _emitStates();
  }

  void _emitStates() {
    if (!_stateController.isClosed) {
      _stateController.add(
        Map<AgentConnectionKey, ConnectionState>.unmodifiable(_states),
      );
    }
  }

  bool _isCurrent(AgentConnectionKey key, _AgentEntry entry) =>
      identical(_entries[key], entry);

  void _ensureOpen() {
    if (_closed) throw StateError('Agent 连接管理器已经关闭');
  }
}

class _AgentEntry {
  _AgentEntry(this.profile, this.client, this.eventSubscription);

  ServerProfile profile;
  final RemoteAgentClient client;
  final StreamSubscription<RemoteAgentEvent> eventSubscription;
  final Lock lock = Lock();
  Future<void>? disconnectRequest;
  int generation = 0;
  int? runtimeOperationGeneration;
  String? runtimeCommand;
}

RemoteAgentClient _defaultClientFactory(AgentKind kind) => switch (kind) {
  AgentKind.codex => CodexAgentClient(),
  AgentKind.openCode => OpenCodeAgentClient(),
};

bool _sameLaneIdentity(
  ServerProfile left,
  ServerProfile right,
  AgentKind agent,
) =>
    left.hasSameConnectionIdentity(right) &&
    (agent != AgentKind.codex || left.remoteCommand == right.remoteCommand) &&
    (agent != AgentKind.openCode ||
        left.workspace.trim() == right.workspace.trim());

String _message(Object error, String fallback) {
  final message = error
      .toString()
      .replaceFirst(RegExp(r'^[^:]+:\s*'), '')
      .trim();
  return message.isEmpty ? fallback : message;
}
