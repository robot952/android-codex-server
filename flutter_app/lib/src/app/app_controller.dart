import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:synchronized/synchronized.dart';

import '../agent/agent_connection_manager.dart';
import '../agent/codex_global_settings.dart';
import '../agent/codex_event_reducer.dart';
import '../agent/codex_protocol.dart';
import '../agent/remote_agent_client.dart';
import '../agent/remote_bootstrap.dart';
import '../agent/resume_notification_buffer.dart';
import '../agent/thread_session_cache.dart';
import '../domain/model_catalog.dart';
import '../domain/models.dart';
import 'profile_scoped_back_stack.dart';
import '../persistence/profile_store.dart';
import '../platform/background_connection_bridge.dart';
import '../platform/diagnostic_logger.dart';
import '../platform/local_linux_manager.dart';
import '../platform/turn_completion_notifications.dart';
import '../platform/windows_local_server_client.dart';
import '../ssh/server_connection_manager.dart';
import '../ssh/ssh_server_client.dart';
import '../ssh/terminal_manager.dart';

final profileStoreProvider = Provider<ProfileStore>((ref) {
  return SecureProfileStore();
});

final serverConnectionManagerProvider = Provider<ServerConnectionManager>((
  ref,
) {
  final manager = ServerConnectionManager(
    profiledClientFactory: (profile) =>
        Platform.isWindows && isLocalWindowsProfile(profile)
        ? WindowsLocalServerClient()
        : DartSshServerClient(),
  );
  ref.onDispose(() => unawaited(manager.close()));
  return manager;
});

final terminalManagerProvider = Provider<TerminalManager>((ref) {
  final manager = TerminalManager(ref.watch(serverConnectionManagerProvider));
  ref.onDispose(() => unawaited(manager.close()));
  return manager;
});

final agentConnectionManagerProvider = Provider<AgentConnectionManager>((ref) {
  final manager = AgentConnectionManager(
    ref.watch(serverConnectionManagerProvider),
  );
  ref.onDispose(() => unawaited(manager.close()));
  return manager;
});

final appControllerProvider = StateNotifierProvider<AppController, AppUiState>((
  ref,
) {
  return AppController(
    ref.watch(profileStoreProvider),
    ref.watch(serverConnectionManagerProvider),
    ref.watch(agentConnectionManagerProvider),
    ref.watch(diagnosticLoggerProvider),
    null,
    ref.watch(backgroundRestoreIntentProvider),
    ref.watch(localLinuxControllerProvider.notifier),
  );
});

final diagnosticLoggerProvider = Provider<DiagnosticLogger>((ref) {
  return DiagnosticLogger.instance;
});

final backgroundRestoreIntentProvider = Provider<BackgroundConnectionIntent>((
  ref,
) {
  return const BackgroundConnectionIntent();
});

class AppController extends StateNotifier<AppUiState> {
  AppController(
    this._store,
    this._connections, [
    AgentConnectionManager? agentConnections,
    DiagnosticLogger? diagnosticLogger,
    List<Duration>? reconnectDelays,
    BackgroundConnectionIntent? backgroundRestoreIntent,
    LocalLinuxRuntime? localLinuxRuntime,
  ]) : _agents = agentConnections ?? AgentConnectionManager(_connections),
       _diagnostics = diagnosticLogger ?? DiagnosticLogger.instance,
       _reconnectDelays = List<Duration>.unmodifiable(
         reconnectDelays ?? _defaultReconnectDelays,
       ),
       _backgroundRestoreIntent =
           backgroundRestoreIntent ?? const BackgroundConnectionIntent(),
       _localLinuxRuntime =
           localLinuxRuntime ?? const UnsupportedLocalLinuxRuntime(),
       _ownsAgentConnections = agentConnections == null,
       super(const AppUiState(loading: true)) {
    _connectionSubscription = _connections.stateChanges.listen(
      _applyConnectionStates,
    );
    _serverMetricsSubscription = _connections.serverMetricChanges.listen(
      _applyServerMetrics,
    );
    _agentConnectionSubscription = _agents.stateChanges.listen(
      _applyAgentConnectionStates,
    );
    _agentEventSubscription = _agents.events.listen(_applyAgentEvent);
    _initialization = _initialize();
    unawaited(_initialization);
    unawaited(_syncDiagnosticMode());
  }

  final ProfileStore _store;
  final ServerConnectionManager _connections;
  final AgentConnectionManager _agents;
  final DiagnosticLogger _diagnostics;
  final List<Duration> _reconnectDelays;
  final BackgroundConnectionIntent _backgroundRestoreIntent;
  final LocalLinuxRuntime _localLinuxRuntime;
  final bool _ownsAgentConnections;
  late final StreamSubscription<Map<String, ConnectionState>>
  _connectionSubscription;
  late final StreamSubscription<Map<String, ServerMetrics>>
  _serverMetricsSubscription;
  late final StreamSubscription<Map<AgentConnectionKey, ConnectionState>>
  _agentConnectionSubscription;
  late final StreamSubscription<AgentEventEnvelope> _agentEventSubscription;
  late final Future<void> _initialization;
  final Lock _persistenceLock = Lock();
  final StreamController<TurnCompletion> _turnCompletionController =
      StreamController<TurnCompletion>.broadcast(sync: true);
  final TurnCompletionDeduplicator _turnCompletionDeduplicator =
      TurnCompletionDeduplicator();
  final SubAgentThreadRegistry _subAgentThreadRegistry =
      SubAgentThreadRegistry();
  final Map<AgentConnectionKey, Future<void>> _agentLoadRequests = {};
  final Map<AgentConnectionKey, int> _agentLoadRevisions = {};
  final Set<String> _retainedHostConnections = <String>{};
  final Set<AgentConnectionKey> _retainedAgentConnections =
      <AgentConnectionKey>{};
  final Map<String, int> _connectionRecoveryRevisions = <String, int>{};
  final Map<String, Future<void>> _connectionRecoveryRequests =
      <String, Future<void>>{};
  final Map<AgentConnectionKey, String?> _agentThreadNextCursors = {};
  final Map<AgentConnectionKey, String> _agentThreadCursorSearches = {};
  final Map<AgentConnectionKey, Future<void>> _agentThreadPageRequests = {};
  final Map<AgentConnectionKey, List<AgentModel>> _remoteModelsByLane = {};
  final Map<AgentConnectionKey, Timer> _customModelSyncTimers = {};
  final Map<AgentConnectionKey, int> _customModelSyncRevisions = {};
  final Map<AgentConnectionKey, Lock> _customModelSyncLocks = {};
  final Map<AgentConnectionKey, ThreadSessionCache> _threadCaches = {};
  final Map<AgentConnectionKey, ResumeNotificationBuffer>
  _resumeNotificationBuffers = {};
  final Map<String, _ThreadOpenRequest> _threadOpenRequests = {};
  final ProfileScopedBackStack<_SubAgentNavigationFrame>
  _subAgentNavigationStacks = ProfileScopedBackStack();
  final Map<AgentConnectionKey, int> _sessionNavigationGenerations = {};
  final Set<AgentConnectionKey> _subAgentOpenStarting = {};
  final Set<AgentConnectionKey> _threadMutationLanes = {};
  final Map<String, ThreadGoal> _threadGoals = {};
  int _localHeartbeatSequence = 0;

  /// Pending server requests are retained per `(lane, threadId)`.  A Codex
  /// app-server channel is shared by all threads in a lane, so filtering only
  /// by the lane lets a late request from another conversation replace the
  /// approval currently shown on screen.
  final Map<AgentConnectionKey, Map<String, List<ApprovalPrompt>>>
  _pendingApprovalsByThread = {};
  Timer? _threadSearchTimer;
  Timer? _draftPersistTimer;
  String? _pendingDraftKey;
  String? _pendingDraftValue;
  int _workspaceRequestId = 0;
  String? _workspaceStateProfileId;
  int _fileManagerListRequestId = 0;
  int _fileManagerOperationRequestId = 0;
  int _agentSettingsRequestId = 0;
  int _apiModelOptionsRequestId = 0;
  String? _agentSettingsProfileId;
  AgentKind? _agentSettingsAgent;
  StoredProfiles _stored = const StoredProfiles();
  ServerProfile? _pendingFingerprintProfile;
  final Map<AgentConnectionKey, Future<void>> _setupRequests = {};
  final Set<AgentConnectionKey> _setupStarting = {};
  final Map<AgentConnectionKey, ServerProfile> _setupProfiles = {};

  /// Completes once for each non-child turn.  The root widget consumes this
  /// stream and decides whether a system notification is needed based on the
  /// current app lifecycle.
  Stream<TurnCompletion> get turnCompletions =>
      _turnCompletionController.stream;

  BackgroundConnectionIntent get backgroundConnectionIntent {
    final hosts = _retainedHostConnections.toList()..sort();
    final agents =
        _retainedAgentConnections
            .map(
              (key) =>
                  backgroundAgentConnectionKey(key.profileId, key.agent.name),
            )
            .toList()
          ..sort();
    return BackgroundConnectionIntent(
      hostProfileIds: List<String>.unmodifiable(hosts),
      agentConnectionKeys: List<String>.unmodifiable(agents),
    );
  }

  Future<void> _initialize() async {
    try {
      _stored = await _store.load();
      if (Platform.isWindows) {
        final existing = _stored.profiles.firstWhereOrNull(
          isLocalWindowsProfile,
        );
        final local = localWindowsProfile(existing: existing);
        final profiles =
            _stored.profiles
                .where((profile) => !isLocalWindowsProfile(profile))
                .toList(growable: true)
              ..insert(0, local);
        _stored = _stored.copyWith(
          profiles: profiles,
          selectedProfileId: _stored.selectedProfileId ?? local.id,
        );
        await _store.save(_stored);
      }
      for (final profile in _stored.profiles) {
        _connections.registerProfile(profile);
        _agents.registerProfile(profile);
      }
      _restoreRetainedConnectionIntent(_stored.profiles);
      if (!mounted) return;
      final selected =
          _stored.selectedProfileId ?? _stored.profiles.firstOrNull?.id;
      final connections = _connections.states;
      final selectedProfile = _stored.profiles.firstWhereOrNull(
        (profile) => profile.id == selected,
      );
      final activeAgent = selectedProfile?.activeAgent ?? AgentKind.codex;
      final activeKey = selected == null
          ? null
          : AgentConnectionKey(profileId: selected, agent: activeAgent);
      state = state.copyWith(
        profiles: _stored.profiles,
        selectedProfileId: selected,
        activeAgent: activeAgent,
        activeAgentCapabilities: activeKey == null
            ? AgentCapabilities.none
            : _connectedCapabilities(activeKey),
        approvalMode:
            selectedProfile?.approvalMode ?? ApprovalMode.requestApproval,
        sandbox:
            selectedProfile?.approvalMode.sandbox ??
            SandboxChoice.workspaceWrite,
        connectionStates: connections,
        connection: selected == null
            ? const ConnectionState()
            : connections[selected] ?? const ConnectionState(),
        serverMetrics: _connectedServerMetrics(
          _connections.serverMetrics,
          connections,
          _retainedHostConnections,
        ),
        agentConnectionStates: _agents.states,
        threads: activeKey == null
            ? const <AgentThread>[]
            : state.agentThreadLists[activeKey] ?? const <AgentThread>[],
        models: activeKey == null
            ? const <AgentModel>[]
            : state.agentModelLists[activeKey] ?? const <AgentModel>[],
        loading: false,
      );
      if (_retainedHostConnections.isNotEmpty) {
        _diagnostics.info(
          'SSH',
          'background_restore_requested profiles=${_retainedHostConnections.length} '
              'agents=${_retainedAgentConnections.length}',
        );
        for (final profileId in _retainedHostConnections) {
          _scheduleConnectionRecovery(profileId, source: 'process_restart');
        }
      }
    } catch (error) {
      if (!mounted) return;
      state = state.copyWith(loading: false, error: _message(error, '读取配置失败'));
    }
  }

  void _restoreRetainedConnectionIntent(List<ServerProfile> profiles) {
    if (_backgroundRestoreIntent.isEmpty) return;
    final validProfileIds = profiles.map((profile) => profile.id).toSet();
    _retainedHostConnections.addAll(
      _backgroundRestoreIntent.hostProfileIds.where(validProfileIds.contains),
    );
    for (final encoded in _backgroundRestoreIntent.agentConnectionKeys) {
      final decoded = decodeBackgroundAgentConnectionKey(encoded);
      if (decoded == null || !validProfileIds.contains(decoded.profileId)) {
        continue;
      }
      final agent = AgentKind.values.firstWhereOrNull(
        (candidate) => candidate.name == decoded.agent,
      );
      if (agent == null) continue;
      _retainedHostConnections.add(decoded.profileId);
      _retainedAgentConnections.add(
        AgentConnectionKey(profileId: decoded.profileId, agent: agent),
      );
    }
  }

  ServerProfile newProfile() => ServerProfile.create();

  Future<ServerProfile> prepareLocalLinux() async {
    await _ensureInitialized();
    _diagnostics.info('LocalLinux', 'prepare_requested');
    try {
      final instance = await _localLinuxRuntime.ensureStarted();
      final existing = state.profiles.firstWhereOrNull(
        (profile) => profile.id == localLinuxProfileId,
      );
      final profile = await _saveLocalLinuxProfile(
        localLinuxProfile(instance, existing: existing),
      );
      _diagnostics.info(
        'LocalLinux',
        'prepare_success port=${instance.port} arch=${instance.architecture}',
      );
      return profile;
    } catch (error, stack) {
      _diagnostics.warn('LocalLinux', 'prepare_failed', error, stack);
      rethrow;
    }
  }

  Future<void> connectLocalLinux() async {
    final profile = await prepareLocalLinux();
    await _requestConnect(profile, localLinuxPrepared: true);
  }

  Future<ServerProfile> _saveLocalLinuxProfile(ServerProfile profile) async {
    final retainHost = _retainedHostConnections.contains(profile.id);
    final retainedAgents = _retainedAgentConnections
        .where((key) => key.profileId == profile.id)
        .toList(growable: false);
    try {
      return await saveProfile(profile);
    } finally {
      if (retainHost) {
        _retainedHostConnections.add(profile.id);
        _retainedAgentConnections.addAll(retainedAgents);
      }
    }
  }

  Future<void> uninstallLocalLinux() async {
    await _ensureInitialized();
    final existing = state.profiles.firstWhereOrNull(
      (profile) => profile.id == localLinuxProfileId,
    );
    if (existing != null) await disconnectProfile(existing.id);
    await _localLinuxRuntime.uninstall();
    if (existing != null) await deleteProfile(existing.id);
    _diagnostics.info('LocalLinux', 'uninstall_success');
  }

  Future<ServerProfile> saveProfile(ServerProfile profile) async {
    await _ensureInitialized();
    var normalized = _normalizeProfile(profile);
    final existing = state.profiles.firstWhereOrNull(
      (candidate) => candidate.id == normalized.id,
    );
    final connectionIdentityChanged =
        existing != null && !existing.hasSameConnectionIdentity(normalized);
    final agentLaunchIdentityChanged =
        existing != null &&
        (existing.remoteCommand.trim() != normalized.remoteCommand.trim() ||
            existing.workspace.trim() != normalized.workspace.trim());
    if (connectionIdentityChanged) {
      _forgetRetainedConnection(normalized.id);
      _clearSetupStates(normalized.id);
    } else if (agentLaunchIdentityChanged) {
      _retainedAgentConnections.removeWhere(
        (key) => key.profileId == normalized.id,
      );
    }
    if (existing != null &&
        !connectionIdentityChanged &&
        existing.workspacePromptShown &&
        !normalized.workspacePromptShown) {
      normalized = normalized.copyWith(workspacePromptShown: true);
    }
    if (existing != null &&
        (existing.host.trim() != normalized.host.trim() ||
            existing.port != normalized.port)) {
      normalized = normalized.copyWith(hostFingerprint: '');
    }

    final profiles = [...state.profiles];
    final index = profiles.indexWhere(
      (candidate) => candidate.id == normalized.id,
    );
    if (index < 0) {
      profiles.add(normalized);
    } else {
      profiles[index] = normalized;
    }
    if (connectionIdentityChanged || agentLaunchIdentityChanged) {
      try {
        await _agents.disconnect(normalized.id);
      } catch (error, stack) {
        _diagnostics.warn(
          'Agent',
          'profile_cleanup_failed profile=${normalized.id}',
          error,
          stack,
        );
      }
    }
    if (connectionIdentityChanged) {
      try {
        await _connections.disconnect(normalized.id);
      } catch (error, stack) {
        _diagnostics.warn(
          'SSH',
          'profile_cleanup_failed profile=${normalized.id}',
          error,
          stack,
        );
      }
    }
    _connections.registerProfile(normalized);
    _agents.registerProfile(normalized);
    if (connectionIdentityChanged) {
      _clearSubAgentNavigationForProfile(normalized.id);
      if (_agentSettingsProfileId == normalized.id) _closeAgentSettings();
      if (state.fileManagerProfileId == normalized.id) {
        _invalidateFileManagerRequests();
      }
      if (_workspaceStateProfileId == normalized.id) {
        _workspaceRequestId++;
        _workspaceStateProfileId = null;
      }
      _threadCaches.removeWhere((key, _) => key.profileId == normalized.id);
      _resumeNotificationBuffers.removeWhere(
        (key, _) => key.profileId == normalized.id,
      );
      _remoteModelsByLane.removeWhere(
        (key, _) => key.profileId == normalized.id,
      );
      _clearAgentThreadPaginationForProfile(normalized.id);
      _threadGoals.removeWhere(
        (key, _) => key.startsWith('${normalized.id}\u0000'),
      );
    }
    final agentData = connectionIdentityChanged
        ? _withoutAgentProfileData(state, normalized.id)
        : null;
    final activeKey = AgentConnectionKey(
      profileId: normalized.id,
      agent: normalized.activeAgent,
    );
    final threadLists = agentData?.threadLists ?? state.agentThreadLists;
    final modelLists = agentData?.modelLists ?? state.agentModelLists;
    state = state.copyWith(
      profiles: profiles,
      selectedProfileId: normalized.id,
      connection: _connections.states[normalized.id] ?? const ConnectionState(),
      agentConnectionStates: _agents.states,
      activeAgent: normalized.activeAgent,
      activeAgentCapabilities: _connectedCapabilities(activeKey),
      approvalMode: normalized.approvalMode,
      sandbox: normalized.approvalMode.sandbox,
      agentThreadLists: threadLists,
      agentModelLists: modelLists,
      agentLoadingStates: agentData?.loadingStates ?? state.agentLoadingStates,
      threads: threadLists[activeKey] ?? const <AgentThread>[],
      models: modelLists[activeKey] ?? const <AgentModel>[],
      workspacePickerVisible: connectionIdentityChanged
          ? false
          : state.workspacePickerVisible,
      workspaceLoading: connectionIdentityChanged
          ? false
          : state.workspaceLoading,
      workspaceCurrentPath: connectionIdentityChanged
          ? ''
          : state.workspaceCurrentPath,
      workspaceParentPath: connectionIdentityChanged
          ? null
          : state.workspaceParentPath,
      workspaceDirectories: connectionIdentityChanged
          ? const <RemoteDirectory>[]
          : state.workspaceDirectories,
      workspaceError: connectionIdentityChanged ? null : state.workspaceError,
    );
    if (connectionIdentityChanged &&
        state.fileManagerProfileId == normalized.id) {
      state = _resetFileManagerState(state, screen: AppScreen.servers);
    }
    await _persist((stored) {
      var next = stored.copyWith(
        profiles: profiles,
        selectedProfileId: normalized.id,
      );
      if (connectionIdentityChanged) {
        next = _removeProfileScopedData(next, normalized.id);
      }
      return next;
    });
    return normalized;
  }

  Future<void> deleteProfile(String profileId) async {
    await _ensureInitialized();
    _forgetRetainedConnection(profileId);
    _cancelCustomModelSync(profileId);
    _clearSubAgentNavigationForProfile(profileId);
    _clearSetupStates(profileId);
    if (_agentSettingsProfileId == profileId) _closeAgentSettings();
    if (_workspaceStateProfileId == profileId) {
      _workspaceRequestId++;
      _workspaceStateProfileId = null;
    }
    if (state.fileManagerProfileId == profileId) {
      _invalidateFileManagerRequests();
    }
    try {
      await _agents.disconnect(profileId);
    } catch (error, stack) {
      _diagnostics.warn(
        'Agent',
        'profile_delete_cleanup_failed profile=$profileId',
        error,
        stack,
      );
    }
    try {
      await _connections.disconnect(profileId);
    } catch (error, stack) {
      _diagnostics.warn(
        'SSH',
        'profile_delete_cleanup_failed profile=$profileId',
        error,
        stack,
      );
    }
    _agents.remove(profileId);
    _connections.remove(profileId);
    final profiles = state.profiles
        .where((profile) => profile.id != profileId)
        .toList();
    final selected = state.selectedProfileId == profileId
        ? profiles.firstOrNull?.id
        : state.selectedProfileId;
    final agentData = _withoutAgentProfileData(state, profileId);
    _threadCaches.removeWhere((key, _) => key.profileId == profileId);
    _resumeNotificationBuffers.removeWhere(
      (key, _) => key.profileId == profileId,
    );
    _remoteModelsByLane.removeWhere((key, _) => key.profileId == profileId);
    _clearAgentThreadPaginationForProfile(profileId);
    _pendingApprovalsByThread.removeWhere(
      (key, _) => key.profileId == profileId,
    );
    _threadOpenRequests.removeWhere(
      (key, _) => key.startsWith('$profileId\u0000'),
    );
    _threadMutationLanes.removeWhere((key) => key.profileId == profileId);
    _threadGoals.removeWhere((key, _) => key.startsWith('$profileId\u0000'));
    state = state.copyWith(
      profiles: profiles,
      selectedProfileId: selected,
      connectionStates: _connections.states,
      connection: selected == null
          ? const ConnectionState()
          : _connections.states[selected] ?? const ConnectionState(),
      serverMetrics: _withoutServerMetrics(state.serverMetrics, profileId),
      agentConnectionStates: _agents.states,
      agentThreadLists: agentData.threadLists,
      agentModelLists: agentData.modelLists,
      agentLoadingStates: agentData.loadingStates,
      threads: const <AgentThread>[],
      models: const <AgentModel>[],
      approvalQueue: const <ApprovalPrompt>[],
      approval: null,
      workspacePickerVisible: false,
      workspaceLoading: false,
      workspaceCurrentPath: '',
      workspaceParentPath: null,
      workspaceDirectories: const <RemoteDirectory>[],
      workspaceError: null,
      screen: AppScreen.servers,
    );
    if (state.fileManagerProfileId == profileId) {
      state = _resetFileManagerState(state, screen: AppScreen.servers);
    }
    await _persist(
      (stored) => _removeProfileScopedData(
        stored.copyWith(profiles: profiles, selectedProfileId: selected),
        profileId,
      ),
    );
  }

  void selectProfile(String profileId) {
    unawaited(_selectProfile(profileId));
  }

  Future<void> _selectProfile(String profileId) async {
    await _initialization;
    if (!mounted) return;
    final profile = state.profiles.firstWhereOrNull(
      (candidate) => candidate.id == profileId,
    );
    if (profile == null) return;
    if (state.selectedProfileId != profileId) {
      _clearAllSubAgentNavigation();
    }
    if (state.agentSettingsVisible && state.selectedProfileId != profileId) {
      _closeAgentSettings();
    }
    if (state.fileManagerProfileId != null &&
        state.fileManagerProfileId != profileId) {
      _invalidateFileManagerRequests();
      state = _resetFileManagerState(state);
    }
    final connection =
        _connections.states[profileId] ?? const ConnectionState();
    final agent = profile.activeAgent;
    final key = AgentConnectionKey(profileId: profileId, agent: agent);
    final preserveActiveThread = state.selectedProfileId == profileId;
    if (_workspaceStateProfileId != profileId) {
      _workspaceRequestId++;
      _workspaceStateProfileId = null;
    }
    state = state.copyWith(
      selectedProfileId: profileId,
      connection: connection,
      activeAgent: agent,
      activeAgentCapabilities: _connectedCapabilities(key),
      approvalMode: profile.approvalMode,
      sandbox: profile.approvalMode.sandbox,
      threads: state.agentThreadLists[key] ?? const <AgentThread>[],
      models: state.agentModelLists[key] ?? const <AgentModel>[],
      approvalQueue: preserveActiveThread
          ? _approvalQueueFor(key, state.activeThread?.id)
          : const <ApprovalPrompt>[],
      approval: preserveActiveThread
          ? _approvalQueueFor(key, state.activeThread?.id).firstOrNull
          : null,
      workspacePickerVisible: false,
      workspaceLoading: false,
      workspaceCurrentPath: _workspaceStateProfileId == profileId
          ? state.workspaceCurrentPath
          : '',
      workspaceParentPath: _workspaceStateProfileId == profileId
          ? state.workspaceParentPath
          : null,
      workspaceDirectories: _workspaceStateProfileId == profileId
          ? state.workspaceDirectories
          : const <RemoteDirectory>[],
      workspaceError: null,
      apiModelOptions: const <ApiModelOption>[],
      apiModelOptionsProfileId: null,
      apiModelOptionsLoading: false,
      apiModelOptionsError: null,
      screen: connection.phase == ConnectionPhase.connected
          ? AppScreen.threads
          : AppScreen.servers,
    );
    await _persist((stored) => stored.copyWith(selectedProfileId: profileId));
    if (connection.phase == ConnectionPhase.connected) {
      unawaited(ensureActiveAgent());
    }
  }

  Future<void> requestConnect(ServerProfile profile) =>
      _requestConnect(profile);

  Future<void> _requestConnect(
    ServerProfile profile, {
    bool localLinuxPrepared = false,
  }) async {
    await _ensureInitialized();
    if (isLocalWindowsProfile(profile) && !Platform.isWindows) {
      _setError(
        UnsupportedError('本机 Windows 仅支持 Windows EXE'),
        '本机 Windows 不可用',
      );
      return;
    }
    if (isLocalLinuxProfile(profile) && !localLinuxPrepared) {
      try {
        profile = await prepareLocalLinux();
        localLinuxPrepared = true;
      } catch (error) {
        _setError(error, '本机 Linux 启动失败');
        return;
      }
    }
    state = state.copyWith(
      selectedProfileId: profile.id,
      activeAgent: profile.activeAgent,
      activeAgentCapabilities: AgentCapabilities.none,
      approvalMode: profile.approvalMode,
      sandbox: profile.approvalMode.sandbox,
      error: null,
    );
    await _persist((stored) => stored.copyWith(selectedProfileId: profile.id));
    if (isLocalWindowsProfile(profile)) {
      await _connectVerified(profile);
      return;
    }
    if (profile.hostFingerprint.trim().isEmpty) {
      try {
        final fingerprint = await _connections.probeFingerprint(profile);
        if (!mounted || state.selectedProfileId != profile.id) return;
        final current = state.profiles.firstWhereOrNull(
          (candidate) => candidate.id == profile.id,
        );
        if (current == null || !current.hasSameConnectionIdentity(profile)) {
          return;
        }
        _pendingFingerprintProfile = current;
        state = state.copyWith(pendingFingerprint: fingerprint);
      } catch (error) {
        _setError(error, '读取 SSH 指纹失败');
      }
      return;
    }
    await _connectVerified(profile, localLinuxPrepared: localLinuxPrepared);
  }

  Future<void> confirmFingerprint() async {
    final profile = _pendingFingerprintProfile;
    final fingerprint = state.pendingFingerprint;
    if (profile == null || fingerprint == null) return;
    _pendingFingerprintProfile = null;
    state = state.copyWith(pendingFingerprint: null);
    final current = state.profiles.firstWhereOrNull(
      (candidate) => candidate.id == profile.id,
    );
    if (current == null || !current.hasSameConnectionIdentity(profile)) {
      state = state.copyWith(error: '服务器配置已更新，请重新连接并核对指纹');
      return;
    }
    final saved = await saveProfile(
      current.copyWith(hostFingerprint: fingerprint),
    );
    await _connectVerified(
      saved,
      localLinuxPrepared: isLocalLinuxProfile(saved),
    );
  }

  void cancelFingerprint() {
    _pendingFingerprintProfile = null;
    state = state.copyWith(pendingFingerprint: null);
  }

  Future<void> _connectVerified(
    ServerProfile profile, {
    bool localLinuxPrepared = false,
  }) async {
    if (isLocalLinuxProfile(profile) && !localLinuxPrepared) {
      try {
        final instance = await _localLinuxRuntime.ensureStarted();
        final refreshed = localLinuxProfile(instance, existing: profile);
        if (!profile.hasSameConnectionIdentity(refreshed)) {
          profile = await _saveLocalLinuxProfile(refreshed);
        }
      } catch (error) {
        _setError(error, '本机 Linux 启动失败');
        return;
      }
    }
    _invalidateConnectionRecovery(profile.id);
    _clearSubAgentNavigationForProfile(profile.id);
    final connectionKind = isLocalWindowsProfile(profile) ? 'Host' : 'SSH';
    _diagnostics.info(
      connectionKind,
      'connect_requested profile=${profile.id}',
    );
    state = state.copyWith(loading: true, error: null);
    try {
      await _connections.connect(profile);
      if (!mounted) return;
      _retainedHostConnections.add(profile.id);
      _diagnostics.info(
        connectionKind,
        'connect_success profile=${profile.id}',
      );
      state = state.copyWith(
        selectedProfileId: profile.id,
        connection:
            _connections.states[profile.id] ??
            ConnectionState(
              phase: ConnectionPhase.connected,
              message: isLocalWindowsProfile(profile)
                  ? '本机 Host 已连接'
                  : 'SSH 已连接',
            ),
        screen: AppScreen.threads,
        activeAgent: profile.activeAgent,
        activeAgentCapabilities: AgentCapabilities.none,
        approvalMode: profile.approvalMode,
        sandbox: profile.approvalMode.sandbox,
        approvalQueue: const <ApprovalPrompt>[],
        approval: null,
        loading: false,
        error: null,
      );
      unawaited(ensureActiveAgent());
    } catch (error, stack) {
      _diagnostics.warn(
        connectionKind,
        'connect_failed profile=${profile.id}',
        error,
        stack,
      );
      _setError(
        error,
        isLocalWindowsProfile(profile) ? '本机 Host 连接失败' : 'SSH 连接失败',
      );
    }
  }

  Future<void> disconnectProfile(String profileId) async {
    _forgetRetainedConnection(profileId);
    _diagnostics.info('SSH', 'disconnect_requested profile=$profileId');
    _clearSubAgentNavigationForProfile(profileId);
    if (_agentSettingsProfileId == profileId) _closeAgentSettings();
    if (state.fileManagerProfileId == profileId) {
      _invalidateFileManagerRequests();
    }
    try {
      try {
        Object? agentError;
        StackTrace? agentErrorStack;
        final agentDisconnect = _agents
            .disconnect(profileId)
            .then<void>(
              (_) {},
              onError: (Object error, StackTrace stack) {
                agentError = error;
                agentErrorStack = stack;
              },
            );
        // Give the app-server channel a short chance to stop while the host
        // socket is still usable. A hung remote process is unblocked by closing
        // SSH below, then its cleanup is bounded as well.
        await Future.any<void>([
          agentDisconnect,
          Future<void>.delayed(const Duration(milliseconds: 300)),
        ]);
        try {
          await _connections.disconnect(profileId);
        } finally {
          await agentDisconnect.timeout(
            const Duration(seconds: 2),
            onTimeout: () {},
          );
        }
        if (agentError != null) {
          Error.throwWithStackTrace(agentError!, agentErrorStack!);
        }
      } finally {
        if (profileId == localLinuxProfileId) {
          await _localLinuxRuntime.stop();
        }
      }
      if (mounted) _clearSetupStates(profileId);
      _pendingApprovalsByThread.removeWhere(
        (key, _) => key.profileId == profileId,
      );
      if (!mounted) return;
      _diagnostics.info('SSH', 'disconnect_success profile=$profileId');
      if (state.selectedProfileId == profileId &&
          state.screen != AppScreen.servers) {
        state = _resetFileManagerState(state, screen: AppScreen.servers);
      }
    } catch (error, stack) {
      _diagnostics.warn(
        'SSH',
        'disconnect_failed profile=$profileId',
        error,
        stack,
      );
      _setError(error, '断开服务器失败');
    }
  }

  Future<void> refreshServerMetrics(String profileId) async {
    await _initialization;
    if (!mounted) return;
    final connection = _connections.states[profileId];
    if (connection?.phase != ConnectionPhase.connected) {
      // A transport recovery briefly reports disconnected/connecting. Keep
      // the last sample visible until the user explicitly disconnects.
      if (_retainedHostConnections.contains(profileId)) return;
      final metrics = _withoutServerMetrics(state.serverMetrics, profileId);
      if (metrics.length != state.serverMetrics.length) {
        state = state.copyWith(serverMetrics: metrics);
      }
      return;
    }
    await _connections.refreshServerMetrics(profileId);
  }

  /// Called by the Android foreground service while the Activity is paused.
  /// Host features and Agent lanes own separate SSH transports, matching the
  /// original Android architecture, so their heartbeats cannot disrupt an
  /// active app-server exec channel through metrics or file operations.
  Future<void> keepAliveRetainedConnections({int? heartbeatSequence}) async {
    await _initialization;
    if (!mounted) return;
    final sequence = heartbeatSequence != null && heartbeatSequence > 0
        ? heartbeatSequence
        : ++_localHeartbeatSequence;
    final profileIds = _retainedHostConnections.toList()..sort();
    final agentKeys = _retainedAgentConnections.toList()
      ..sort((left, right) {
        final profile = left.profileId.compareTo(right.profileId);
        return profile != 0
            ? profile
            : left.agent.name.compareTo(right.agent.name);
      });
    await Future.wait<void>([
      for (final profileId in profileIds)
        _traceHeartbeatLane(
          sequence: sequence,
          lane: 'host',
          profileId: profileId,
          agent: null,
          phase: _connections.states[profileId]?.phase,
          operation: () => _connections.keepAlive(profileId),
        ),
      for (final key in agentKeys)
        _traceHeartbeatLane(
          sequence: sequence,
          lane: 'agent',
          profileId: key.profileId,
          agent: key.agent.name,
          phase: _agents.states[key]?.phase,
          operation: () => _agents.keepAlive(key),
        ),
    ]);
  }

  Future<void> _traceHeartbeatLane({
    required int sequence,
    required String lane,
    required String profileId,
    required String? agent,
    required ConnectionPhase? phase,
    required Future<void> Function() operation,
  }) async {
    final agentDetail = agent == null ? '' : ' agent=$agent';
    final startedAt = Stopwatch()..start();
    try {
      await operation();
      if (startedAt.elapsed > const Duration(seconds: 5)) {
        _diagnostics.warn(
          'Heartbeat',
          'lane_slow sequence=$sequence lane=$lane profile=$profileId$agentDetail '
              'phase=${phase?.name ?? 'none'} '
              'elapsedMs=${startedAt.elapsedMilliseconds}',
        );
      }
    } catch (error, stack) {
      _diagnostics.warn(
        'Heartbeat',
        'lane_failed sequence=$sequence lane=$lane profile=$profileId$agentDetail '
            'elapsedMs=${startedAt.elapsedMilliseconds}',
        error,
        stack,
      );
      rethrow;
    }
  }

  void selectAgent(AgentKind agent) {
    unawaited(_selectAgent(agent));
  }

  Future<void> _selectAgent(AgentKind agent) async {
    await _ensureInitialized();
    final profileId = state.selectedProfileId;
    if (profileId == null) return;
    final profile = state.profiles.firstWhereOrNull(
      (candidate) => candidate.id == profileId,
    );
    if (profile == null) return;
    final key = AgentConnectionKey(profileId: profileId, agent: agent);
    final changingAgent = state.activeAgent != agent;
    if (changingAgent) {
      _clearSubAgentNavigationForProfile(profileId);
      _workspaceRequestId++;
      if (state.agentSettingsVisible) _closeAgentSettings();
      _apiModelOptionsRequestId++;
    }
    final profiles = state.profiles
        .map(
          (candidate) => candidate.id == profileId
              ? candidate.copyWith(activeAgent: agent)
              : candidate,
        )
        .toList(growable: false);
    final updatedProfile = profiles.firstWhere(
      (candidate) => candidate.id == profileId,
    );
    _agents.registerProfile(updatedProfile);
    state = state.copyWith(
      profiles: profiles,
      activeAgent: agent,
      activeAgentCapabilities: _connectedCapabilities(key),
      approvalMode: updatedProfile.approvalMode,
      sandbox: updatedProfile.approvalMode.sandbox,
      threads: state.agentThreadLists[key] ?? const <AgentThread>[],
      models: state.agentModelLists[key] ?? const <AgentModel>[],
      threadSearch: '',
      diagnostic: null,
      approvalQueue: changingAgent
          ? const <ApprovalPrompt>[]
          : _approvalQueueFor(key, state.activeThread?.id),
      approval: changingAgent
          ? null
          : _approvalQueueFor(key, state.activeThread?.id).firstOrNull,
      workspacePickerVisible: changingAgent
          ? false
          : state.workspacePickerVisible,
      workspaceLoading: changingAgent ? false : state.workspaceLoading,
      workspaceError: changingAgent ? null : state.workspaceError,
      apiModelOptions: changingAgent
          ? const <ApiModelOption>[]
          : state.apiModelOptions,
      apiModelOptionsProfileId: changingAgent
          ? null
          : state.apiModelOptionsProfileId,
      apiModelOptionsLoading: changingAgent
          ? false
          : state.apiModelOptionsLoading,
      apiModelOptionsError: changingAgent ? null : state.apiModelOptionsError,
    );
    await _persist((stored) => stored.copyWith(profiles: profiles));
    await ensureActiveAgent();
  }

  Future<void> selectApprovalMode(ApprovalMode mode) async {
    await _ensureInitialized();
    final profileId = state.selectedProfileId;
    if (profileId == null || state.approvalMode == mode) return;
    final profiles = state.profiles
        .map(
          (profile) => profile.id == profileId
              ? profile.copyWith(approvalMode: mode)
              : profile,
        )
        .toList(growable: false);
    final updated = profiles.firstWhereOrNull(
      (profile) => profile.id == profileId,
    );
    if (updated == null) return;
    _agents.registerProfile(updated);
    state = state.copyWith(
      profiles: profiles,
      approvalMode: mode,
      sandbox: mode.sandbox,
      error: null,
    );
    await _persist((stored) => stored.copyWith(profiles: profiles));
  }

  Future<void> ensureActiveAgent() async {
    await _initialization;
    if (!mounted) return;
    final profileId = state.selectedProfileId;
    if (profileId == null ||
        _connections.states[profileId]?.phase != ConnectionPhase.connected) {
      return;
    }
    final profile = state.profiles.firstWhereOrNull(
      (candidate) => candidate.id == profileId,
    );
    if (profile == null) return;
    final key = AgentConnectionKey(
      profileId: profileId,
      agent: state.activeAgent,
    );
    // Returning from the server list should reuse the live lane and its last
    // snapshot. Explicit refresh/search paths still call _loadAgentData.
    final agentState = _agents.states[key];
    if (agentState?.phase == ConnectionPhase.connected &&
        state.agentThreadLists.containsKey(key) &&
        state.agentModelLists.containsKey(key)) {
      return;
    }
    await _loadAgentData(key, profile, includeModels: true);
  }

  Future<void> installRemoteSetup(String proxyUrl) async {
    await _ensureInitialized();
    final prompt = state.remoteSetup;
    final profileId = state.selectedProfileId;
    if (prompt == null || profileId == null) return;
    final key = AgentConnectionKey(profileId: profileId, agent: prompt.agent);
    if (_setupRequests.containsKey(key) || !_setupStarting.add(key)) return;

    try {
      late final String normalizedProxy;
      try {
        normalizedProxy = RemoteBootstrap.validateProxyUrl(proxyUrl);
      } catch (error) {
        _setError(error, '代理地址无效');
        return;
      }
      final sourceProfile =
          _setupProfiles[key] ??
          state.profiles.firstWhereOrNull(
            (candidate) => candidate.id == profileId,
          );
      if (sourceProfile == null) return;
      final profile = sourceProfile.copyWith(proxyUrl: normalizedProxy);
      _setupProfiles[key] = profile;
      final profiles = state.profiles
          .map(
            (candidate) => candidate.id == profileId
                ? candidate.copyWith(proxyUrl: normalizedProxy)
                : candidate,
          )
          .toList(growable: false);
      state = state.copyWith(profiles: profiles, error: null);
      _connections.registerProfile(profile);
      _agents.registerProfile(profile);
      await _persist(
        (stored) => stored.copyWith(
          profiles: stored.profiles
              .map(
                (candidate) => candidate.id == profileId
                    ? candidate.copyWith(proxyUrl: normalizedProxy)
                    : candidate,
              )
              .toList(growable: false),
        ),
      );
      if (!mounted || !_setupProfiles.containsKey(key)) return;

      _updateSetupState(
        key,
        (current) => current.copyWith(
          inProgress: true,
          progress: '准备安装',
          percent: 0,
          detail: '',
          downloadPercent: null,
          minimized: false,
        ),
      );
      late final Future<void> request;
      request = _runRemoteSetup(key, profile).whenComplete(() {
        if (identical(_setupRequests[key], request)) {
          _setupRequests.remove(key);
        }
      });
      _setupRequests[key] = request;
      await request;
    } finally {
      _setupStarting.remove(key);
    }
  }

  Future<void> _runRemoteSetup(
    AgentConnectionKey key,
    ServerProfile profile,
  ) async {
    try {
      await _agents.installRuntime(
        profile,
        key.agent,
        onProgress: (progress) {
          if (!mounted || !_setupProfiles.containsKey(key)) return;
          _updateSetupState(
            key,
            (current) => current.copyWith(
              inProgress: true,
              progress: progress.message,
              percent: progress.percent.clamp(0, 100).toInt(),
              detail: progress.detail,
              downloadPercent: progress.downloadPercent,
              downloadedBytes: progress.downloadedBytes,
              totalBytes: progress.totalBytes,
              bytesPerSecond: progress.bytesPerSecond,
              elapsedSeconds: progress.elapsedSeconds,
              progressIndeterminate: progress.indeterminate,
            ),
          );
        },
      );
      final inspection = await _agents.inspectRuntime(profile, key.agent);
      if (inspection.compatibleCommand == null) {
        throw StateError('安装完成，但未检测到兼容的 ${key.agent.label}');
      }
      if (!mounted || !_isCurrentSetupProfile(key, profile)) return;
      _removeSetupState(key);
      if (_connections.states[key.profileId]?.phase ==
          ConnectionPhase.connected) {
        await _loadAgentData(
          key,
          profile,
          includeModels: true,
          runtimePrepared: true,
        );
      }
    } catch (error) {
      if (!mounted || !_isCurrentSetupProfile(key, profile)) return;
      final message = _message(error, '远程 Agent 安装失败');
      _updateSetupState(
        key,
        (current) => current.copyWith(
          inProgress: false,
          progress: '安装失败',
          detail: message,
          downloadPercent: null,
        ),
      );
      if (_isActiveKey(key)) state = state.copyWith(error: message);
    }
  }

  void cancelRemoteSetup() {
    final prompt = state.remoteSetup;
    final profileId = state.selectedProfileId;
    if (prompt == null || profileId == null) return;
    final key = AgentConnectionKey(profileId: profileId, agent: prompt.agent);
    if (state.agentSetupStates[key]?.inProgress == true) return;
    _removeSetupState(key);
    unawaited(_agents.disconnect(profileId, agent: key.agent));
  }

  void minimizeRemoteSetup() {
    final prompt = state.remoteSetup;
    final profileId = state.selectedProfileId;
    if (prompt == null || profileId == null) return;
    final key = AgentConnectionKey(profileId: profileId, agent: prompt.agent);
    final setup = state.agentSetupStates[key];
    if (setup == null) return;
    state = state.copyWith(
      remoteSetup: null,
      setupInProgress: false,
      setupProgress: '',
      setupProgressPercent: 0,
      setupProgressDetail: '',
      setupDownloadPercent: null,
      setupDownloadedBytes: null,
      setupTotalBytes: null,
      setupBytesPerSecond: null,
      setupElapsedSeconds: null,
      setupProgressIndeterminate: false,
      agentSetupStates: Map.unmodifiable({
        ...state.agentSetupStates,
        key: setup.copyWith(minimized: true),
      }),
    );
  }

  /// Reopens a minimized remote runtime installation for the active lane.
  ///
  /// The installation task remains owned by [agentSetupStates], so restoring
  /// the dialog never starts a second download request.
  void resumeRemoteSetup() {
    final profileId = state.selectedProfileId;
    if (profileId == null) return;
    final key = AgentConnectionKey(
      profileId: profileId,
      agent: state.activeAgent,
    );
    final setup = state.agentSetupStates[key];
    if (setup?.prompt == null) return;
    _showRemoteSetup(key);
  }

  Future<void> uninstallRemoteRuntime(String profileId) async {
    await _ensureInitialized();
    final profile = state.profiles.firstWhereOrNull(
      (candidate) => candidate.id == profileId,
    );
    if (profile == null) throw StateError('服务器配置不存在');
    if (_connections.states[profileId]?.phase != ConnectionPhase.connected) {
      throw StateError('请先连接 SSH 服务器');
    }
    final agent = state.selectedProfileId == profileId
        ? state.activeAgent
        : profile.activeAgent;
    final key = AgentConnectionKey(profileId: profileId, agent: agent);
    _clearSubAgentNavigation(key);
    _clearSetupStates(profileId);
    await _agents.uninstallRuntime(profile, agent);
    if (!mounted ||
        !state.profiles.any((candidate) => candidate.id == profileId)) {
      return;
    }
    final threadLists = Map<AgentConnectionKey, List<AgentThread>>.of(
      state.agentThreadLists,
    )..remove(key);
    final modelLists = Map<AgentConnectionKey, List<AgentModel>>.of(
      state.agentModelLists,
    )..remove(key);
    _clearAgentThreadPagination(key);
    _threadCaches.remove(key);
    _resumeNotificationBuffers.remove(key);
    _remoteModelsByLane.remove(key);
    state = state.copyWith(
      agentThreadLists: Map.unmodifiable(threadLists),
      agentModelLists: Map.unmodifiable(modelLists),
      threads: _isActiveKey(key) ? const <AgentThread>[] : state.threads,
      models: _isActiveKey(key) ? const <AgentModel>[] : state.models,
      activeAgentCapabilities: _isActiveKey(key)
          ? AgentCapabilities.none
          : state.activeAgentCapabilities,
      diagnostic: _isActiveKey(key)
          ? '托管 ${agent.label} 已卸载'
          : state.diagnostic,
    );
  }

  Future<void> refreshThreads({bool silent = false}) async {
    await _initialization;
    if (!mounted) return;
    final profileId = state.selectedProfileId;
    if (profileId == null) return;
    final profile = state.profiles.firstWhereOrNull(
      (candidate) => candidate.id == profileId,
    );
    if (profile == null) return;
    final key = AgentConnectionKey(
      profileId: profileId,
      agent: state.activeAgent,
    );
    await _loadAgentData(key, profile, silent: silent);
  }

  bool get activeThreadListHasMore {
    final profileId = state.selectedProfileId;
    if (profileId == null) return false;
    final key = AgentConnectionKey(
      profileId: profileId,
      agent: state.activeAgent,
    );
    if (_agentThreadCursorSearches[key] != state.threadSearch) return false;
    final cursor = _agentThreadNextCursors[key];
    return cursor?.trim().isNotEmpty ?? false;
  }

  /// Loads the next server-provided thread-list page for the active lane.
  /// Requests are deduplicated and an old cursor cannot append into a newer
  /// search/refresh result.
  Future<void> loadMoreThreads() async {
    await _initialization;
    if (!mounted) return;
    final profileId = state.selectedProfileId;
    if (profileId == null) return;
    final profile = state.profiles.firstWhereOrNull(
      (candidate) => candidate.id == profileId,
    );
    if (profile == null) return;
    final key = AgentConnectionKey(
      profileId: profileId,
      agent: state.activeAgent,
    );
    final activeLoad = _agentLoadRequests[key];
    if (activeLoad != null) await activeLoad;
    if (!mounted || !_isActiveKey(key)) return;
    final cursor = _agentThreadNextCursors[key]?.trim();
    if (cursor == null ||
        cursor.isEmpty ||
        _agentThreadCursorSearches[key] != state.threadSearch) {
      return;
    }
    final pending = _agentThreadPageRequests[key];
    if (pending != null) return pending;
    final search = state.threadSearch;
    late final Future<void> request;
    request = _loadMoreThreadsPage(key, cursor: cursor, searchTerm: search)
        .whenComplete(() {
          if (identical(_agentThreadPageRequests[key], request)) {
            _agentThreadPageRequests.remove(key);
          }
        });
    _agentThreadPageRequests[key] = request;
    return request;
  }

  Future<void> _loadMoreThreadsPage(
    AgentConnectionKey key, {
    required String cursor,
    required String searchTerm,
  }) async {
    try {
      final page = await _agents.listMoreThreads(
        key,
        cursor: cursor,
        searchTerm: searchTerm,
      );
      if (!mounted ||
          !_isActiveKey(key) ||
          state.threadSearch != searchTerm ||
          _agentThreadCursorSearches[key] != searchTerm ||
          _agentThreadNextCursors[key] != cursor) {
        return;
      }
      final current = state.agentThreadLists[key] ?? const <AgentThread>[];
      final merged = _mergeListedThreads(current, page.threads);
      final lists = Map<AgentConnectionKey, List<AgentThread>>.of(
        state.agentThreadLists,
      )..[key] = merged;
      _agentThreadNextCursors[key] = page.nextCursor;
      _rememberSubAgentReferences(key, page.threads, const <TimelineEntry>[]);
      state = state.copyWith(
        agentThreadLists: Map.unmodifiable(lists),
        threads: merged,
        diagnostic: null,
      );
    } catch (error) {
      if (mounted &&
          _isActiveKey(key) &&
          state.threadSearch == searchTerm &&
          _agentThreadCursorSearches[key] == searchTerm &&
          _agentThreadNextCursors[key] == cursor) {
        state = state.copyWith(
          error: _message(error, '读取更多会话失败'),
          diagnostic: _message(error, '读取更多会话失败'),
        );
      }
    }
  }

  Future<void> showAgentSettings() async {
    await _ensureInitialized();
    if (state.agentSettingsVisible ||
        state.agentSettingsSaving ||
        state.agentSettingsTesting) {
      return;
    }
    if (!state.activeAgentCapabilities.globalSettings) return;
    final profileId = state.selectedProfileId;
    final agent = state.activeAgent;
    final profile = profileId == null
        ? null
        : state.profiles.firstWhereOrNull(
            (candidate) => candidate.id == profileId,
          );
    if (profile == null) return;
    final key = AgentConnectionKey(profileId: profile.id, agent: agent);
    if (_agents.states[key]?.phase != ConnectionPhase.connected) {
      state = state.copyWith(error: '服务器未连接，无法读取 ${agent.label} 配置');
      return;
    }

    final requestId = ++_agentSettingsRequestId;
    final generation = _agents.generation(key);
    _workspaceRequestId++;
    _workspaceStateProfileId = null;
    _agentSettingsProfileId = profile.id;
    _agentSettingsAgent = agent;
    state = state.copyWith(
      agentSettingsVisible: true,
      agentSettingsLoading: true,
      agentSettingsSaving: false,
      agentSettingsTesting: false,
      agentSettings: null,
      agentSettingsTestResult: null,
      agentSettingsError: null,
      workspacePickerVisible: false,
      workspaceLoading: false,
      workspaceCurrentPath: '',
      workspaceParentPath: null,
      workspaceDirectories: const <RemoteDirectory>[],
      workspaceError: null,
    );
    try {
      final settings = await _agents.readGlobalSettings(key, profile);
      if (!_isAgentSettingsRequestCurrent(
        requestId,
        profile,
        agent,
        generation,
      )) {
        return;
      }
      state = state.copyWith(
        agentSettingsLoading: false,
        agentSettings: settings,
        agentSettingsError: null,
      );
    } catch (error) {
      if (!_isAgentSettingsRequestCurrent(
        requestId,
        profile,
        agent,
        generation,
      )) {
        return;
      }
      state = state.copyWith(
        agentSettingsLoading: false,
        agentSettingsError: _message(error, '无法读取 ${agent.label} 全局配置'),
      );
    }
  }

  void dismissAgentSettings() {
    if (state.agentSettingsSaving || state.agentSettingsTesting) return;
    _closeAgentSettings();
  }

  Future<void> testAgentSettings({
    required String baseUrl,
    required String apiKey,
    required String proxyUrl,
    required String testModel,
  }) async {
    await _ensureInitialized();
    if (!state.agentSettingsVisible ||
        state.agentSettings == null ||
        state.agentSettingsLoading ||
        state.agentSettingsSaving ||
        state.agentSettingsTesting ||
        !state.activeAgentCapabilities.globalSettings) {
      return;
    }
    final profileId = state.selectedProfileId;
    final agent = state.activeAgent;
    final profile = profileId == null
        ? null
        : state.profiles.firstWhereOrNull(
            (candidate) => candidate.id == profileId,
          );
    if (profile == null) return;
    final key = AgentConnectionKey(profileId: profile.id, agent: agent);
    if (_agents.states[key]?.phase != ConnectionPhase.connected) {
      state = state.copyWith(
        agentSettingsError: '服务器未连接，无法测试 ${agent.label} API',
      );
      return;
    }

    final requestId = ++_agentSettingsRequestId;
    final generation = _agents.generation(key);
    _agentSettingsProfileId = profile.id;
    _agentSettingsAgent = agent;
    _diagnostics.info(
      'AgentSettings',
      'test_requested profile=${profile.id} agent=${agent.name} '
          'baseUrl=${baseUrl.trim().isNotEmpty ? 'configured' : 'default'} '
          'apiKey=${apiKey.trim().isNotEmpty ? 'configured' : 'missing'} '
          'proxy=${proxyUrl.trim().isNotEmpty ? 'configured' : 'none'} '
          'model=${testModel.trim().isNotEmpty ? 'configured' : 'missing'}',
    );
    state = state.copyWith(
      agentSettingsTesting: true,
      agentSettingsTestResult: null,
      agentSettingsError: null,
    );
    try {
      final result = await _agents.testGlobalSettings(
        key,
        profile,
        baseUrl: baseUrl,
        apiKey: apiKey,
        proxyUrl: proxyUrl,
        testModel: testModel,
      );
      if (!_isAgentSettingsRequestCurrent(
        requestId,
        profile,
        agent,
        generation,
      )) {
        return;
      }
      state = state.copyWith(
        agentSettingsTesting: false,
        agentSettingsTestResult: result,
        agentSettingsError: null,
      );
      _diagnostics.info(
        'AgentSettings',
        'test_completed profile=${profile.id} agent=${agent.name} '
            'successful=${result.successful} '
            'reason=${_agentSettingsTestReason(result)}',
      );
    } catch (error) {
      if (!_isAgentSettingsRequestCurrent(
        requestId,
        profile,
        agent,
        generation,
      )) {
        return;
      }
      final message = _message(error, '无法测试 ${agent.label} API 连接');
      state = state.copyWith(
        agentSettingsTesting: false,
        agentSettingsTestResult: null,
        agentSettingsError: message,
      );
      _diagnostics.warn(
        'AgentSettings',
        'test_failed profile=${profile.id} agent=${agent.name} '
            'error=${error.runtimeType}',
      );
    }
  }

  Future<void> saveAgentSettings({
    required String baseUrl,
    required String apiKey,
    required String proxyUrl,
    required String defaultModel,
    required String defaultReasoningEffort,
    required String testModel,
    required bool preserveCurrentProvider,
  }) async {
    await _ensureInitialized();
    if (!state.agentSettingsVisible ||
        state.agentSettings == null ||
        state.agentSettingsLoading ||
        state.agentSettingsSaving ||
        state.agentSettingsTesting ||
        !state.activeAgentCapabilities.globalSettings) {
      return;
    }
    final profileId = state.selectedProfileId;
    final agent = state.activeAgent;
    final profile = profileId == null
        ? null
        : state.profiles.firstWhereOrNull(
            (candidate) => candidate.id == profileId,
          );
    if (profile == null) return;

    late final String normalizedDefaultModel;
    late final String normalizedDefaultEffort;
    late final String normalizedTestModel;
    try {
      normalizedDefaultModel = normalizeAgentModelId(agent, defaultModel);
      normalizedDefaultEffort = state.activeAgentCapabilities.reasoningEffort
          ? normalizeCodexReasoningEffort(defaultReasoningEffort)
          : '';
      normalizedTestModel = normalizeAgentModelId(agent, testModel);
    } catch (error) {
      state = state.copyWith(
        agentSettingsError: _message(error, '${agent.label} 配置格式错误'),
      );
      return;
    }

    final key = AgentConnectionKey(profileId: profile.id, agent: agent);
    if (_agents.states[key]?.phase != ConnectionPhase.connected) {
      state = state.copyWith(
        agentSettingsError: '服务器未连接，无法保存 ${agent.label} 配置',
      );
      return;
    }
    final effectivePreserveCurrentProvider =
        agent == AgentKind.codex || preserveCurrentProvider;
    final preserveExistingThreads = _preserveThreadsAfterSettingsSave(
      agent: agent,
      currentSettings: state.agentSettings!,
      preserveCurrentProvider: effectivePreserveCurrentProvider,
    );
    final requestId = ++_agentSettingsRequestId;
    final generation = _agents.generation(key);
    _agentSettingsProfileId = profile.id;
    _agentSettingsAgent = agent;
    _diagnostics.info(
      'AgentSettings',
      'save_requested profile=${profile.id} agent=${agent.name} '
          'baseUrl=${baseUrl.trim().isNotEmpty ? 'configured' : 'default'} '
          'apiKey=${apiKey.trim().isNotEmpty ? 'provided' : 'unchanged'} '
          'proxy=${proxyUrl.trim().isNotEmpty ? 'configured' : 'none'} '
          'defaultModel=${normalizedDefaultModel.isNotEmpty ? 'configured' : 'none'} '
          'testModel=${normalizedTestModel.isNotEmpty ? 'configured' : 'none'}',
    );
    state = state.copyWith(
      agentSettingsSaving: true,
      agentSettingsTestResult: null,
      agentSettingsError: null,
    );

    var saved = false;
    var stage = 'remote_write';
    try {
      await _agents.writeGlobalSettings(
        key,
        profile,
        baseUrl: baseUrl,
        apiKey: apiKey,
        proxyUrl: proxyUrl,
        defaultModel: normalizedDefaultModel,
        defaultReasoningEffort: normalizedDefaultEffort,
        preserveCurrentProvider: effectivePreserveCurrentProvider,
      );
      stage = 'profile_persist';
      await _updateProfileAgentDefaults(
        profileId: profile.id,
        agent: agent,
        defaultModel: normalizedDefaultModel,
        defaultEffort: normalizedDefaultEffort,
        testModel: normalizedTestModel,
      );
      saved = true;
      if (_isAgentSettingsRequestCurrent(
        requestId,
        profile,
        agent,
        generation,
      )) {
        _closeAgentSettings();
      }
    } catch (error) {
      _diagnostics.warn(
        'AgentSettings',
        'save_failed profile=${profile.id} agent=${agent.name} '
            'stage=$stage error=${error.runtimeType}',
      );
      if (_isAgentSettingsRequestCurrent(
        requestId,
        profile,
        agent,
        generation,
      )) {
        state = state.copyWith(
          agentSettingsSaving: false,
          agentSettingsError: _message(error, '无法保存 ${agent.label} 全局配置'),
        );
      }
    }
    if (!saved || !mounted) return;

    final updatedProfile = state.profiles.firstWhereOrNull(
      (candidate) => candidate.id == profile.id,
    );
    if (updatedProfile == null) return;
    try {
      await _restartAgentAfterSettingsSave(
        key,
        updatedProfile,
        preserveExistingThreads: preserveExistingThreads,
      );
      _diagnostics.info(
        'AgentSettings',
        'save_completed profile=${profile.id} agent=${agent.name} '
            'restart=success',
      );
    } catch (error) {
      _diagnostics.warn(
        'AgentSettings',
        'save_restart_failed profile=${profile.id} agent=${agent.name} '
            'error=${error.runtimeType}',
      );
      if (mounted) {
        state = state.copyWith(
          error:
              '${agent.label} 配置已保存，但重新连接失败：'
              '${_message(error, '请手动重新连接')}',
        );
      }
    }
  }

  Future<Uint8List> loadImagePreview(
    String path, {
    void Function(int receivedBytes, int totalBytes)? onProgress,
  }) async {
    await _ensureInitialized();
    final profileId = state.selectedProfileId;
    if (profileId == null) throw StateError('未选择服务器');
    return _connections.readRemoteImage(
      profileId,
      path,
      onProgress: onProgress,
    );
  }

  Future<void> showWorkspacePicker() async {
    await _ensureInitialized();
    if (state.agentSettingsVisible) return;
    final profile = _activeWorkspaceProfile();
    if (profile == null) return;
    final cachedPath = _workspaceStateProfileId == profile.id
        ? state.workspaceCurrentPath.trim()
        : '';
    final path = profile.workspace.trim().isNotEmpty
        ? profile.workspace.trim()
        : cachedPath.isNotEmpty
        ? cachedPath
        : '/';
    await _browseWorkspace(profile, state.activeAgent, path);
  }

  Future<void> browseWorkspace(String? path) async {
    await _ensureInitialized();
    final profile = _activeWorkspaceProfile();
    if (profile == null) return;
    await _browseWorkspace(profile, state.activeAgent, path);
  }

  Future<void> confirmWorkspace() async {
    await _ensureInitialized();
    final profile = _activeWorkspaceProfile();
    final path = state.workspaceCurrentPath.trim();
    if (profile == null ||
        state.workspaceLoading ||
        _workspaceStateProfileId != profile.id ||
        path.isEmpty) {
      return;
    }
    _workspaceRequestId++;
    state = state.copyWith(
      workspacePickerVisible: false,
      workspaceLoading: false,
      workspaceError: null,
    );
    await saveProfile(
      profile.copyWith(workspace: path, workspacePromptShown: true),
    );
  }

  void dismissWorkspacePicker() {
    _workspaceRequestId++;
    state = state.copyWith(
      workspacePickerVisible: false,
      workspaceLoading: false,
      workspaceError: null,
    );
  }

  ServerProfile? _activeWorkspaceProfile() {
    final profileId = state.selectedProfileId;
    if (profileId == null ||
        _connections.states[profileId]?.phase != ConnectionPhase.connected) {
      return null;
    }
    final key = AgentConnectionKey(
      profileId: profileId,
      agent: state.activeAgent,
    );
    if (_agents.states[key]?.phase != ConnectionPhase.connected) return null;
    return state.profiles.firstWhereOrNull(
      (candidate) => candidate.id == profileId,
    );
  }

  Future<void> _browseWorkspace(
    ServerProfile profile,
    AgentKind agent,
    String? path,
  ) async {
    final requestId = ++_workspaceRequestId;
    _workspaceStateProfileId = profile.id;
    state = state.copyWith(
      workspacePickerVisible: true,
      workspaceLoading: true,
      workspaceError: null,
    );
    try {
      final listing = await _connections.listDirectories(profile, path);
      if (!_isWorkspaceRequestCurrent(requestId, profile, agent)) return;
      _workspaceStateProfileId = profile.id;
      state = state.copyWith(
        workspaceLoading: false,
        workspaceCurrentPath: listing.currentPath,
        workspaceParentPath: listing.parentPath,
        workspaceDirectories: listing.directories,
        workspaceError: null,
      );
    } catch (error) {
      if (!_isWorkspaceRequestCurrent(requestId, profile, agent)) return;
      state = state.copyWith(
        workspaceLoading: false,
        workspaceError: _message(error, '无法读取目录'),
      );
    }
  }

  bool _isWorkspaceRequestCurrent(
    int requestId,
    ServerProfile profile,
    AgentKind agent,
  ) {
    if (!mounted ||
        requestId != _workspaceRequestId ||
        !state.workspacePickerVisible ||
        state.selectedProfileId != profile.id ||
        state.activeAgent != agent) {
      return false;
    }
    final current = state.profiles.firstWhereOrNull(
      (candidate) => candidate.id == profile.id,
    );
    final key = AgentConnectionKey(profileId: profile.id, agent: agent);
    return current != null &&
        current.hasSameConnectionIdentity(profile) &&
        _connections.states[profile.id]?.phase == ConnectionPhase.connected &&
        _agents.states[key]?.phase == ConnectionPhase.connected;
  }

  void _showInitialWorkspacePickerIfNeeded(
    AgentConnectionKey key,
    ServerProfile connectedProfile,
  ) {
    if (!mounted || !_isActiveKey(key)) return;
    final profile = state.profiles.firstWhereOrNull(
      (candidate) => candidate.id == key.profileId,
    );
    if (profile == null ||
        !profile.hasSameConnectionIdentity(connectedProfile) ||
        profile.workspacePromptShown) {
      return;
    }

    final updated = profile.copyWith(workspacePromptShown: true);
    final profiles = state.profiles
        .map((candidate) => candidate.id == updated.id ? updated : candidate)
        .toList(growable: false);
    _connections.registerProfile(updated);
    _agents.registerProfile(updated);
    state = state.copyWith(profiles: profiles);
    unawaited(
      _persist(
        (stored) => stored.copyWith(
          profiles: stored.profiles
              .map(
                (candidate) => candidate.id == updated.id ? updated : candidate,
              )
              .toList(growable: false),
        ),
      ),
    );
    if (updated.workspace.trim().isNotEmpty) return;

    _workspaceStateProfileId = updated.id;
    state = state.copyWith(
      workspacePickerVisible: true,
      workspaceLoading: true,
      workspaceCurrentPath: '/',
      workspaceParentPath: null,
      workspaceDirectories: const <RemoteDirectory>[],
      workspaceError: null,
    );
    unawaited(_browseWorkspace(updated, key.agent, null));
  }

  void showFileManager() {
    unawaited(_showFileManager());
  }

  Future<void> _showFileManager() async {
    await _ensureInitialized();
    final profile = _activeHostProfile();
    if (profile == null) {
      state = state.copyWith(error: '服务器未连接，无法打开文件管理');
      return;
    }
    final initialPath =
        state.fileManagerProfileId == profile.id &&
            state.fileManagerCurrentPath.trim().isNotEmpty
        ? state.fileManagerCurrentPath
        : profile.workspace.trim().isEmpty
        ? '.'
        : profile.workspace;
    _fileManagerListRequestId++;
    _fileManagerOperationRequestId++;
    state = state.copyWith(
      screen: AppScreen.fileManager,
      fileManagerProfileId: profile.id,
      fileManagerLoading: true,
      fileManagerCurrentPath: initialPath,
      fileManagerParentPath: null,
      fileManagerEntries: const <RemoteFileEntry>[],
      fileManagerClipboard: null,
      fileManagerOperation: null,
      fileManagerError: null,
    );
    await _browseFileManager(profile, initialPath);
  }

  void closeFileManager() {
    _invalidateFileManagerRequests();
    final connected =
        state.selectedProfileId != null &&
        _connections.states[state.selectedProfileId]?.phase ==
            ConnectionPhase.connected;
    state = _resetFileManagerState(
      state,
      screen: connected ? AppScreen.threads : AppScreen.servers,
    );
  }

  void refreshFileManager() {
    final path = state.fileManagerCurrentPath.trim();
    if (path.isNotEmpty) browseFileManager(path);
  }

  void browseFileManager(String path) {
    final profile = _activeFileManagerProfile();
    if (profile == null || state.fileManagerOperation != null) return;
    unawaited(_browseFileManager(profile, path));
  }

  Future<void> _browseFileManager(ServerProfile profile, String path) async {
    final requestId = ++_fileManagerListRequestId;
    state = state.copyWith(fileManagerLoading: true, fileManagerError: null);
    try {
      final listing = await _connections.listRemoteFiles(profile, path);
      if (!_isFileManagerRequestCurrent(requestId, profile)) return;
      state = state.copyWith(
        fileManagerLoading: false,
        fileManagerCurrentPath: listing.currentPath,
        fileManagerParentPath: listing.parentPath,
        fileManagerEntries: listing.entries,
        fileManagerError: null,
      );
    } catch (error) {
      if (!_isFileManagerRequestCurrent(requestId, profile)) return;
      state = state.copyWith(
        fileManagerLoading: false,
        fileManagerError: _message(error, '无法读取目录'),
      );
    }
  }

  Future<void> uploadRemoteFiles(
    Iterable<LocalRemoteFileUpload> uploads,
  ) async {
    final files = uploads.toList(growable: false);
    if (files.isEmpty) return;
    await _runFileManagerOperation(
      label: '正在上传 ${files.length} 个文件',
      successMessage: '已上传 ${files.length} 个文件',
      action: (profile, directory) async {
        for (final file in files) {
          await _connections.uploadRemoteFile(
            profile,
            directory,
            file.name,
            file.chunks,
            declaredSize: file.sizeBytes,
          );
        }
      },
    );
  }

  Future<void> downloadFileManagerFile(
    String path, {
    required Future<void> Function(Uint8List chunk) writeChunk,
  }) async {
    if (path.trim().isEmpty) return;
    await _runFileManagerOperation(
      label: '正在下载文件',
      successMessage: '已保存到本地',
      rethrowError: true,
      action: (profile, _) => _connections.downloadRemoteFile(
        profile,
        path,
        writeChunk: writeChunk,
      ),
    );
  }

  Future<void> renameRemoteFile(RemoteFileEntry entry, String newName) =>
      _runFileManagerOperation(
        label: '正在重命名',
        successMessage: '已重命名',
        action: (profile, _) =>
            _connections.renameRemoteFile(profile, entry.path, newName),
      );

  Future<void> deleteRemoteFiles(Iterable<RemoteFileEntry> entries) {
    final paths = entries.map((entry) => entry.path).toSet().toList();
    if (paths.isEmpty) return Future<void>.value();
    return _runFileManagerOperation(
      label: '正在删除 ${paths.length} 项',
      successMessage: '已删除 ${paths.length} 项',
      action: (profile, _) => _connections.deleteRemoteFiles(profile, paths),
    );
  }

  void copyRemoteFiles(Iterable<RemoteFileEntry> entries) {
    _setRemoteFileClipboard(entries, RemoteFileTransferMode.copy);
  }

  void cutRemoteFiles(Iterable<RemoteFileEntry> entries) {
    _setRemoteFileClipboard(entries, RemoteFileTransferMode.move);
  }

  void _setRemoteFileClipboard(
    Iterable<RemoteFileEntry> entries,
    RemoteFileTransferMode mode,
  ) {
    if (_activeFileManagerProfile() == null ||
        state.fileManagerOperation != null) {
      return;
    }
    final selected = <String, RemoteFileEntry>{};
    for (final entry in entries) {
      if (entry.path.trim().isNotEmpty) selected[entry.path] = entry;
    }
    if (selected.isEmpty) return;
    state = state.copyWith(
      fileManagerClipboard: RemoteFileClipboard(
        entries: selected.values.toList(growable: false),
        mode: mode,
      ),
      fileManagerError: null,
    );
  }

  Future<void> pasteRemoteFiles() async {
    final clipboard = state.fileManagerClipboard;
    if (clipboard == null || clipboard.entries.isEmpty) return;
    await _runFileManagerOperation(
      label: clipboard.mode == RemoteFileTransferMode.copy
          ? '正在复制 ${clipboard.entries.length} 项'
          : '正在移动 ${clipboard.entries.length} 项',
      successMessage: clipboard.mode == RemoteFileTransferMode.copy
          ? '已复制 ${clipboard.entries.length} 项'
          : '已移动 ${clipboard.entries.length} 项',
      clearClipboardOnSuccess: clipboard.mode == RemoteFileTransferMode.move,
      action: (profile, directory) => _connections.transferRemoteFiles(
        profile,
        clipboard.entries.map((entry) => entry.path).toList(growable: false),
        directory,
        clipboard.mode,
      ),
    );
  }

  Future<void> _runFileManagerOperation({
    required String label,
    required String successMessage,
    required Future<void> Function(ServerProfile profile, String directory)
    action,
    bool clearClipboardOnSuccess = false,
    bool rethrowError = false,
  }) async {
    final profile = _activeFileManagerProfile();
    final directory = state.fileManagerCurrentPath.trim();
    if (profile == null ||
        directory.isEmpty ||
        state.fileManagerOperation != null) {
      return;
    }
    final requestId = ++_fileManagerOperationRequestId;
    _fileManagerListRequestId++;
    state = state.copyWith(
      fileManagerLoading: false,
      fileManagerOperation: label,
      fileManagerError: null,
    );
    try {
      await action(profile, directory);
      final listing = await _connections.listRemoteFiles(profile, directory);
      if (!_isFileManagerOperationCurrent(requestId, profile)) return;
      state = state.copyWith(
        fileManagerLoading: false,
        fileManagerCurrentPath: listing.currentPath,
        fileManagerParentPath: listing.parentPath,
        fileManagerEntries: listing.entries,
        fileManagerClipboard: clearClipboardOnSuccess
            ? null
            : state.fileManagerClipboard,
        fileManagerOperation: null,
        fileManagerError: null,
        diagnostic: successMessage,
      );
    } catch (error, stackTrace) {
      if (_isFileManagerOperationCurrent(requestId, profile)) {
        state = state.copyWith(
          fileManagerLoading: false,
          fileManagerOperation: null,
          fileManagerError: _message(error, '文件操作失败'),
        );
      }
      if (rethrowError) Error.throwWithStackTrace(error, stackTrace);
    }
  }

  ServerProfile? _activeHostProfile() {
    final profileId = state.selectedProfileId;
    if (profileId == null ||
        _connections.states[profileId]?.phase != ConnectionPhase.connected) {
      return null;
    }
    return state.profiles.firstWhereOrNull(
      (candidate) => candidate.id == profileId,
    );
  }

  ServerProfile? _activeFileManagerProfile() {
    if (state.screen != AppScreen.fileManager ||
        state.fileManagerProfileId == null ||
        state.fileManagerProfileId != state.selectedProfileId) {
      return null;
    }
    return _activeHostProfile();
  }

  bool _isFileManagerRequestCurrent(int requestId, ServerProfile profile) =>
      mounted &&
      requestId == _fileManagerListRequestId &&
      _isFileManagerProfileCurrent(profile);

  bool _isFileManagerOperationCurrent(int requestId, ServerProfile profile) =>
      mounted &&
      requestId == _fileManagerOperationRequestId &&
      _isFileManagerProfileCurrent(profile);

  bool _isFileManagerProfileCurrent(ServerProfile profile) {
    final current = _activeFileManagerProfile();
    return current != null && current.hasSameConnectionIdentity(profile);
  }

  void _invalidateFileManagerRequests() {
    _fileManagerListRequestId++;
    _fileManagerOperationRequestId++;
  }

  AppUiState _resetFileManagerState(AppUiState current, {AppScreen? screen}) =>
      current.copyWith(
        screen: screen ?? current.screen,
        fileManagerProfileId: null,
        fileManagerLoading: false,
        fileManagerCurrentPath: '',
        fileManagerParentPath: null,
        fileManagerEntries: const <RemoteFileEntry>[],
        fileManagerClipboard: null,
        fileManagerOperation: null,
        fileManagerError: null,
      );

  Future<int> downloadRemoteFile(
    String path, {
    required Future<void> Function(Uint8List chunk) writeChunk,
  }) async {
    await _ensureInitialized();
    final profileId = state.selectedProfileId;
    if (profileId == null) throw StateError('未选择服务器');
    final profile = state.profiles.firstWhereOrNull(
      (candidate) => candidate.id == profileId,
    );
    if (profile == null) throw StateError('未选择服务器');
    return _connections.downloadRemoteFile(
      profile,
      path,
      writeChunk: writeChunk,
    );
  }

  /// Stages bounded local files through the active SSH connection. The
  /// profile/thread guard prevents a picker result from being attached to a
  /// different conversation after navigation while it is uploading.
  Future<void> uploadAttachments(
    Iterable<LocalAttachmentUpload> uploads,
  ) async {
    await _ensureInitialized();
    final items = uploads.toList(growable: false);
    final profileId = state.selectedProfileId;
    final threadId = state.activeThread?.id;
    if (items.isEmpty ||
        profileId == null ||
        threadId == null ||
        threadId.isEmpty ||
        state.attachmentUploading) {
      return;
    }
    final profile = state.profiles.firstWhereOrNull(
      (candidate) => candidate.id == profileId,
    );
    if (profile == null) return;
    final key = AgentConnectionKey(
      profileId: profileId,
      agent: state.activeAgent,
    );
    state = state.copyWith(attachmentUploading: true, error: null);
    Object? firstError;
    try {
      for (final item in items) {
        if (!mounted || !_isActiveThread(key, threadId)) return;
        try {
          final isText = item.textContent != null;
          final maxBytes = isText
              ? maxInlineTextAttachmentBytes
              : maxLocalAttachmentBytes;
          if (item.bytes.isEmpty) throw StateError('附件不能为空');
          if (item.bytes.length > maxBytes) {
            throw StateError(isText ? '文本附件不能超过 512 KB' : '附件不能超过 20 MB');
          }
          final remotePath = await _connections.uploadAttachment(
            profile,
            item.name,
            item.bytes,
            maxBytes: maxBytes,
          );
          if (!mounted || !_isActiveThread(key, threadId)) return;
          state = state.copyWith(
            attachments: [
              ...state.attachments,
              PendingAttachment(
                name: item.name,
                remotePath: remotePath,
                mimeType: item.mimeType,
                textContent: item.textContent,
              ),
            ],
          );
        } catch (error) {
          firstError ??= error;
        }
      }
    } finally {
      if (mounted && _isActiveThread(key, threadId)) {
        state = state.copyWith(
          attachmentUploading: false,
          error: firstError == null
              ? state.error
              : _message(firstError, '上传附件失败'),
        );
      }
    }
  }

  /// Stages selected local diagnostic sessions as ordinary text attachments.
  /// Nothing is sent here; the existing composer send action remains the only
  /// operation that submits them to the active conversation.
  Future<void> addDebugLogAttachments(Iterable<String> logIds) async {
    await _ensureInitialized();
    final ids = logIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (ids.isEmpty) return;
    final availableSlots = maxPendingAttachmentCount - state.attachments.length;
    if (availableSlots <= 0) {
      state = state.copyWith(error: '输入框最多保留 $maxPendingAttachmentCount 个附件');
      return;
    }
    final uploads = <LocalAttachmentUpload>[];
    Object? firstError;
    for (final id in ids.take(availableSlots)) {
      try {
        final text = await _diagnostics.attachmentText(id);
        if (text == null || text.trim().isEmpty) {
          throw StateError('所选 Debug 日志已不可用');
        }
        uploads.add(
          LocalAttachmentUpload(
            name: 'agent-diagnostic-$id.txt',
            bytes: Uint8List.fromList(utf8.encode(text)),
            mimeType: 'text/plain',
            textContent: text,
          ),
        );
      } catch (error) {
        firstError ??= error;
      }
    }
    if (uploads.isNotEmpty) await uploadAttachments(uploads);
    if (firstError != null && mounted) {
      state = state.copyWith(error: _message(firstError, '添加 Debug 日志失败'));
    }
  }

  void removeAttachment(String remotePath) {
    if (!mounted || remotePath.trim().isEmpty) return;
    state = state.copyWith(
      attachments: state.attachments
          .where((attachment) => attachment.remotePath != remotePath)
          .toList(growable: false),
    );
  }

  Future<void> createThread() async {
    await _ensureInitialized();
    final profileId = state.selectedProfileId;
    if (profileId == null || state.loading || state.submitting) return;
    final profile = state.profiles.firstWhereOrNull(
      (candidate) => candidate.id == profileId,
    );
    if (profile == null) return;
    final key = AgentConnectionKey(
      profileId: profileId,
      agent: state.activeAgent,
    );
    _clearSubAgentNavigation(key);
    final settings = profile.modelSettings(key.agent);
    state = state.copyWith(submitting: true, error: null);
    try {
      await _agents.connect(profile, key.agent);
      final session = await _agents.startThread(
        key,
        cwd: profile.workspace.trim().isEmpty ? null : profile.workspace.trim(),
        model: settings.preferredModel.trim().isEmpty
            ? null
            : settings.preferredModel.trim(),
        approvalMode: profile.approvalMode,
        sandbox: profile.approvalMode.sandbox,
      );
      if (!mounted || !_isActiveKey(key)) return;
      final threads = <AgentThread>[
        session.thread,
        ...state.threads.where((thread) => thread.id != session.thread.id),
      ];
      final lists = Map<AgentConnectionKey, List<AgentThread>>.of(
        state.agentThreadLists,
      )..[key] = List<AgentThread>.unmodifiable(threads);
      state = state.copyWith(
        agentThreadLists: Map.unmodifiable(lists),
        threads: threads,
        submitting: false,
      );
      final cache = _threadCaches.putIfAbsent(key, ThreadSessionCache.new);
      cache.put(
        session.thread,
        session.timeline,
        nextTurnsCursor: session.nextTurnsCursor,
        tokenUsage: session.tokenUsage,
      );
      _threadGoals.remove(
        threadPreferenceKey(key.profileId, key.agent, session.thread.id),
      );
      _showThreadSnapshot(key, session, loading: false, activeGoal: null);
    } catch (error) {
      if (mounted && _isActiveKey(key)) {
        state = state.copyWith(
          submitting: false,
          loading: false,
          error: _message(error, '新建会话失败'),
        );
      }
    }
  }

  void openThread(AgentThread thread) {
    final profileId = state.selectedProfileId;
    if (profileId != null) {
      _clearSubAgentNavigation(
        AgentConnectionKey(profileId: profileId, agent: state.activeAgent),
      );
    }
    unawaited(_openThread(thread));
  }

  /// Opens a thread referenced by a completion-notification payload.  The
  /// notification may arrive for an inactive server/agent lane, so selection
  /// and data hydration are serialized before the normal thread opener runs.
  Future<void> openCompletedThread(
    String profileId,
    AgentKind agent,
    String threadId,
  ) async {
    final normalizedProfileId = profileId.trim();
    final normalizedThreadId = threadId.trim();
    if (normalizedProfileId.isEmpty || normalizedThreadId.isEmpty) return;
    await _ensureInitialized();
    final profile = state.profiles.firstWhereOrNull(
      (candidate) => candidate.id == normalizedProfileId,
    );
    if (profile == null || !mounted) return;

    await _selectProfile(normalizedProfileId);
    if (!mounted || state.selectedProfileId != normalizedProfileId) return;
    if (state.activeAgent != agent) {
      await _selectAgent(agent);
      if (!mounted || state.activeAgent != agent) return;
    }

    final key = AgentConnectionKey(
      profileId: normalizedProfileId,
      agent: agent,
    );
    if (_connections.states[normalizedProfileId]?.phase !=
        ConnectionPhase.connected) {
      state = state.copyWith(error: '服务器连接已断开，请重新连接后打开会话');
      return;
    }

    var thread = state.agentThreadLists[key]?.firstWhereOrNull(
      (candidate) => candidate.id == normalizedThreadId,
    );
    if (thread == null) {
      // A completion can race the initial thread-list request.  Reuse the
      // existing bounded loader before falling back to a lightweight stub.
      await _loadAgentData(key, profile, includeModels: false);
      if (!mounted || state.selectedProfileId != normalizedProfileId) return;
      thread = state.agentThreadLists[key]?.firstWhereOrNull(
        (candidate) => candidate.id == normalizedThreadId,
      );
    }
    thread ??= AgentThread(
      id: normalizedThreadId,
      title: '已完成的会话',
      cwd: profile.workspace,
      source: 'appServer',
      status: 'idle',
    );
    openThread(thread);
  }

  /// Opens a collaborator as a real, independently resumable conversation.
  /// The parent frame is kept until the child navigation has been accepted so
  /// a failed start cannot strand the user on an empty child page.
  void openSubAgentThread(String threadId, String agentName) {
    final current = state;
    final profileId = current.selectedProfileId;
    if (!current.activeAgentCapabilities.subAgents ||
        profileId == null ||
        threadId.trim().isEmpty ||
        threadId.trim() == current.activeThread?.id ||
        current.loading) {
      return;
    }
    if (current.submitting) {
      state = state.copyWith(error: '当前操作尚未完成，请稍后打开智能体');
      return;
    }
    if (current.approvalQueue.isNotEmpty) {
      state = state.copyWith(error: '请先处理当前审批请求');
      return;
    }
    if (current.screen != AppScreen.work &&
        current.screen != AppScreen.agentWork) {
      return;
    }
    final key = AgentConnectionKey(
      profileId: profileId,
      agent: current.activeAgent,
    );
    if ((_subAgentNavigationStacks.size(_subAgentNavigationScope(key))) >=
        maxSubAgentNavigationDepth) {
      state = state.copyWith(error: '智能体嵌套层级过深，请先返回上一级');
      return;
    }
    if (!_isHostAndAgentConnected(key)) {
      state = state.copyWith(error: 'Agent 连接已断开，请重新连接后打开智能体');
      return;
    }
    final parent = current.activeThread;
    if (parent == null) return;
    if (!_subAgentOpenStarting.add(key)) return;
    unawaited(
      _startSubAgentNavigation(
        key: key,
        parent: parent,
        threadId: threadId.trim(),
        agentName: agentName.trim(),
      ),
    );
  }

  Future<void> _startSubAgentNavigation({
    required AgentConnectionKey key,
    required AgentThread parent,
    required String threadId,
    required String agentName,
  }) async {
    try {
      await _openSubAgentThread(
        key: key,
        parent: parent,
        threadId: threadId,
        agentName: agentName,
      );
    } catch (error) {
      if (mounted && _isActiveKey(key)) {
        state = state.copyWith(error: _message(error, '无法打开智能体'));
      }
    } finally {
      _subAgentOpenStarting.remove(key);
    }
  }

  Future<void> _openSubAgentThread({
    required AgentConnectionKey key,
    required AgentThread parent,
    required String threadId,
    required String agentName,
  }) async {
    await _ensureInitialized();
    if (!mounted || !_isActiveKey(key) || state.activeThread?.id != parent.id) {
      return;
    }
    final scope = _subAgentNavigationScope(key);
    if (_subAgentNavigationStacks.size(scope) >= maxSubAgentNavigationDepth) {
      state = state.copyWith(error: '智能体嵌套层级过深，请先返回上一级');
      return;
    }
    _flushPendingDraft();
    final parentSnapshot = _SessionSnapshot.capture(state);
    final cache = _threadCaches.putIfAbsent(key, ThreadSessionCache.new);
    cache.put(
      parent,
      parentSnapshot.timeline,
      nextTurnsCursor: parentSnapshot.olderTurnsCursor,
      tokenUsage: parentSnapshot.tokenUsage,
    );
    final frame = _SubAgentNavigationFrame(
      snapshot: parentSnapshot,
      screen: state.screen,
    );
    _subAgentNavigationStacks.push(scope, frame);

    final childSnapshot = cache.get(threadId) ?? cache.getStale(threadId);
    final child =
        childSnapshot?.thread ??
        AgentThread(
          id: threadId,
          title: agentName.isEmpty ? '智能体' : agentName,
          cwd: parent.cwd,
          source: 'appServer',
          status: 'idle',
          cliVersion: state.agentConnectionStates[key]?.cliVersion ?? '',
        );
    final generation = _advanceSessionNavigation(key);
    final requestKey = threadPreferenceKey(key.profileId, key.agent, threadId);
    final accepted = await _openThreadInternal(
      thread: child,
      targetScreen: AppScreen.agentWork,
      agentName: agentName.isEmpty ? null : agentName,
      navigationGeneration: generation,
      requestKey: requestKey,
    );
    if (!accepted && mounted) {
      _subAgentNavigationStacks.popIfTop(scope, frame);
    }
  }

  /// Returns to the parent frame. Repeated back presses while the parent
  /// resume is in flight are intentionally idempotent.
  void backFromSubAgentThread() {
    final current = state;
    final profileId = current.selectedProfileId;
    if (profileId == null) return;
    if (current.submitting) {
      state = state.copyWith(error: '当前操作尚未完成，请稍后返回');
      return;
    }
    if (current.approvalQueue.isNotEmpty) {
      state = state.copyWith(error: '请先处理当前审批请求');
      return;
    }
    final key = AgentConnectionKey(
      profileId: profileId,
      agent: current.activeAgent,
    );
    final scope = _subAgentNavigationScope(key);
    if (_subAgentNavigationStacks.isPopPending(scope)) return;
    final frame = _subAgentNavigationStacks.beginPendingPop(scope);
    if (frame == null) {
      backToThreadList();
      return;
    }
    final parent = frame.snapshot.activeThread;
    if (parent == null) {
      _subAgentNavigationStacks.completePendingPop(scope, frame);
      backToThreadList();
      return;
    }

    _flushPendingDraft();
    final childSnapshot = _SessionSnapshot.capture(current);
    final cache = _threadCaches.putIfAbsent(key, ThreadSessionCache.new);
    if (current.activeThread != null) {
      cache.put(
        current.activeThread!,
        childSnapshot.timeline,
        nextTurnsCursor: childSnapshot.olderTurnsCursor,
        tokenUsage: childSnapshot.tokenUsage,
      );
    }
    final generation = _advanceSessionNavigation(key);
    if (!_isHostAndAgentConnected(key)) {
      _restoreParentAfterLocalReturn(key, scope, frame);
      return;
    }
    final requestKey = threadPreferenceKey(key.profileId, key.agent, parent.id);
    unawaited(() async {
      final accepted = await _openThreadInternal(
        thread: parent,
        targetScreen: frame.screen,
        agentName: frame.snapshot.activeAgentName,
        initialSnapshot: frame.snapshot,
        subAgentBackNavigation: true,
        navigationGeneration: generation,
        requestKey: requestKey,
        onResumed: () {
          _subAgentNavigationStacks.completePendingPop(scope, frame);
        },
        onResumeFailure: (error) {
          if (!_subAgentNavigationStacks.cancelPendingPop(scope, frame)) {
            return true;
          }
          if (mounted && _isActiveKey(key)) {
            state = childSnapshot
                .restore(state)
                .copyWith(
                  screen: AppScreen.agentWork,
                  subAgentBackNavigation: false,
                  loading: false,
                  submitting: false,
                  error: _message(error, '无法返回上级智能体'),
                );
          }
          return true;
        },
      );
      if (!accepted &&
          mounted &&
          _subAgentNavigationStacks.isPopPending(scope)) {
        _restoreParentAfterLocalReturn(key, scope, frame);
      }
    }());
  }

  void _restoreParentAfterLocalReturn(
    AgentConnectionKey key,
    String scope,
    _SubAgentNavigationFrame frame,
  ) {
    if (_subAgentNavigationStacks.completePendingPop(scope, frame) == null ||
        !mounted ||
        !_isActiveKey(key)) {
      return;
    }
    state = frame.snapshot
        .restore(state)
        .copyWith(
          screen: frame.screen,
          subAgentBackNavigation: true,
          loading: false,
          submitting: false,
          error: '服务器连接已断开，已返回上级会话；重连后请重新打开会话',
        );
  }

  Future<void> _openThread(AgentThread thread) async {
    await _ensureInitialized();
    _flushPendingDraft();
    final profileId = state.selectedProfileId;
    if (profileId == null) return;
    final profile = state.profiles.firstWhereOrNull(
      (candidate) => candidate.id == profileId,
    );
    if (profile == null) return;
    final key = AgentConnectionKey(
      profileId: profileId,
      agent: state.activeAgent,
    );
    final requestKey = threadPreferenceKey(
      profileId,
      state.activeAgent,
      thread.id,
    );
    final currentGeneration = _sessionNavigationGenerations[key] ?? 0;
    final pending = _threadOpenRequests[requestKey];
    if (pending != null && pending.generation == currentGeneration) {
      await pending.future;
      return;
    }
    final generation = _advanceSessionNavigation(key);
    final accepted = await _openThreadInternal(
      thread: thread,
      targetScreen: AppScreen.work,
      agentName: null,
      navigationGeneration: generation,
      requestKey: requestKey,
    );
    if (!accepted && mounted && _isActiveKey(key)) {
      state = state.copyWith(
        screen: AppScreen.threads,
        activeThread: null,
        loading: false,
        subAgentBackNavigation: false,
      );
    }
  }

  void backToThreadList() {
    _flushPendingDraft();
    final profileId = state.selectedProfileId;
    if (profileId != null) {
      final key = AgentConnectionKey(
        profileId: profileId,
        agent: state.activeAgent,
      );
      _advanceSessionNavigation(key);
      _cacheActiveThreadSession(key);
      _subAgentNavigationStacks.clear(_subAgentNavigationScope(key));
    }
    state = state.copyWith(
      screen: AppScreen.threads,
      subAgentBackNavigation: false,
      activeThread: null,
      activeGoal: null,
      timeline: const <TimelineEntry>[],
      olderTurnsCursor: null,
      olderTurnsLoading: false,
      activeTurnId: null,
      running: false,
      tokenUsage: null,
      aggregateDiff: '',
      approval: null,
      approvalQueue: const <ApprovalPrompt>[],
      submitting: false,
      attachments: const <PendingAttachment>[],
      attachmentUploading: false,
      loading: false,
      diagnostic: null,
    );
    // Match the original Android behavior: show the retained list immediately,
    // then reconcile recency, preview, status, and ordering in the background.
    unawaited(refreshThreads(silent: true));
  }

  /// Shows the interactive SSH terminal for the selected server. The PTY is
  /// kept alive by [TerminalManager] when this screen is hidden.
  void openTerminal() {
    final profileId = state.selectedProfileId;
    if (profileId == null ||
        state.connectionStates[profileId]?.phase != ConnectionPhase.connected) {
      return;
    }
    state = state.copyWith(screen: AppScreen.terminal);
  }

  void closeTerminal() {
    if (!mounted) return;
    state = state.copyWith(screen: AppScreen.threads);
  }

  Future<void> loadOlderTurns() async {
    await _ensureInitialized();
    final profileId = state.selectedProfileId;
    final thread = state.activeThread;
    final cursor = state.olderTurnsCursor;
    if (profileId == null ||
        thread == null ||
        cursor == null ||
        state.olderTurnsLoading) {
      return;
    }
    final key = AgentConnectionKey(
      profileId: profileId,
      agent: state.activeAgent,
    );
    final profile = state.profiles.firstWhereOrNull(
      (candidate) => candidate.id == profileId,
    );
    if (profile == null) return;
    state = state.copyWith(olderTurnsLoading: true);
    try {
      final page = await _agents.loadOlderTurns(
        key,
        threadId: thread.id,
        cursor: cursor,
        subAgentCreatedAt: _subAgentThreadCreatedAt(thread),
      );
      if (!mounted || !_isActiveThread(key, thread.id)) return;
      final merged = _mergeTimeline(page.timeline, state.timeline);
      state = state.copyWith(
        timeline: merged,
        olderTurnsCursor: page.nextCursor,
        olderTurnsLoading: false,
      );
      final cache = _threadCaches.putIfAbsent(key, ThreadSessionCache.new);
      cache.put(
        state.activeThread ?? thread,
        merged,
        nextTurnsCursor: page.nextCursor,
        tokenUsage: state.tokenUsage,
      );
    } catch (error) {
      if (mounted && _isActiveThread(key, thread.id)) {
        state = state.copyWith(
          olderTurnsLoading: false,
          error: _message(error, '读取更早历史失败'),
        );
      }
    }
  }

  /// Keeps the draft in memory immediately and persists it with a short
  /// debounce so rotating the screen or leaving the thread does not lose
  /// partially typed input without issuing a storage write for every key.
  void setComposerDraft(String value) {
    if (!mounted || state.composerDraft == value) return;
    state = state.copyWith(composerDraft: value);
    final profileId = state.selectedProfileId;
    final threadId = state.activeThread?.id;
    if (profileId == null || threadId == null || threadId.isEmpty) return;
    _pendingDraftKey = threadPreferenceKey(
      profileId,
      state.activeAgent,
      threadId,
    );
    _pendingDraftValue = value;
    _draftPersistTimer?.cancel();
    _draftPersistTimer = Timer(const Duration(milliseconds: 260), () {
      final key = _pendingDraftKey;
      final draft = _pendingDraftValue;
      _pendingDraftKey = null;
      _pendingDraftValue = null;
      if (key == null || draft == null || !mounted) return;
      unawaited(
        _persist(
          (stored) => stored.copyWith(
            composerDrafts: {...stored.composerDrafts, key: draft},
          ),
        ),
      );
    });
  }

  void _flushPendingDraft() {
    _draftPersistTimer?.cancel();
    _draftPersistTimer = null;
    final key = _pendingDraftKey;
    final draft = _pendingDraftValue;
    _pendingDraftKey = null;
    _pendingDraftValue = null;
    if (key == null || draft == null || !mounted) return;
    unawaited(
      _persist(
        (stored) => stored.copyWith(
          composerDrafts: {...stored.composerDrafts, key: draft},
        ),
      ),
    );
  }

  Future<void> sendMessage({String? text}) async {
    await _ensureInitialized();
    final profileId = state.selectedProfileId;
    final thread = state.activeThread;
    if (profileId == null ||
        thread == null ||
        state.submitting ||
        state.attachmentUploading) {
      return;
    }
    final profile = state.profiles.firstWhereOrNull(
      (candidate) => candidate.id == profileId,
    );
    if (profile == null) return;
    final draftBeforeSend = text ?? state.composerDraft;
    final content = draftBeforeSend.trimRight();
    if (content.trim().isEmpty && state.attachments.isEmpty) return;
    final steeringTurnId = state.running ? state.activeTurnId?.trim() : null;
    if (state.running && (steeringTurnId == null || steeringTurnId.isEmpty)) {
      state = state.copyWith(error: '当前回合仍在运行，尚未收到回合 ID，请稍后再试');
      return;
    }
    if (steeringTurnId?.isNotEmpty == true &&
        !state.activeAgentCapabilities.steerTurn) {
      state = state.copyWith(error: '${state.activeAgent.label} 不支持连续发送');
      return;
    }
    final key = AgentConnectionKey(
      profileId: profileId,
      agent: state.activeAgent,
    );
    final modelSettings = profile.modelSettings(state.activeAgent);
    final model = state.selectedModel?.trim().isNotEmpty == true
        ? state.selectedModel
        : modelSettings.preferredModel.trim().isEmpty
        ? null
        : modelSettings.preferredModel.trim();
    final effort = state.selectedEffort?.trim().isNotEmpty == true
        ? state.selectedEffort
        : modelSettings.preferredEffort.trim().isEmpty
        ? null
        : modelSettings.preferredEffort.trim();
    final attachments = List<PendingAttachment>.unmodifiable(state.attachments);
    _diagnostics.info(
      'Message',
      'send_requested profile=$profileId agent=${state.activeAgent.name} '
          'thread=${thread.id} bytes=${utf8.encode(content).length} '
          'attachments=${attachments.length} steering=${steeringTurnId?.isNotEmpty == true}',
    );
    final optimisticId =
        'local-user-${DateTime.now().microsecondsSinceEpoch.toString()}';
    final optimistic = TimelineEntry(
      id: optimisticId,
      kind: TimelineKind.userMessage,
      text: content,
      attachments: attachments
          .map(
            (attachment) => MessageAttachment(
              name: attachment.name,
              remotePath: attachment.remotePath,
              mimeType: attachment.mimeType,
            ),
          )
          .toList(growable: false),
      turnId: state.activeTurnId ?? '',
    );
    state = state.copyWith(
      timeline: [...state.timeline, optimistic],
      composerDraft: '',
      attachments: const <PendingAttachment>[],
      composerClearNonce: state.composerClearNonce + 1,
      submitting: true,
      running: true,
      error: null,
    );
    final draftKey = threadPreferenceKey(
      profileId,
      state.activeAgent,
      thread.id,
    );
    unawaited(
      _persist(
        (stored) => stored.copyWith(
          composerDrafts: {...stored.composerDrafts, draftKey: ''},
        ),
      ),
    );
    try {
      await _agents.connect(profile, key.agent);
      late final String turnId;
      final steering = steeringTurnId?.isNotEmpty == true;
      if (steering) {
        await _agents.steerTurn(
          key,
          threadId: thread.id,
          turnId: steeringTurnId!,
          text: content,
          attachments: attachments,
        );
        turnId = steeringTurnId;
      } else {
        final selectedCustomModel = model == null
            ? null
            : modelSettings.customModels.firstWhereOrNull(
                (definition) => definition.modelId == model,
              );
        final pendingModelRemovals = _pendingManagedModelRemovals(
          modelSettings,
        );
        if (key.agent == AgentKind.openCode &&
            (selectedCustomModel != null || pendingModelRemovals.isNotEmpty)) {
          await _syncCustomModelsNow(
            profileId,
            key.agent,
            requireConnected: true,
          );
        }
        turnId = await _agents.startTurn(
          key,
          threadId: thread.id,
          text: content,
          attachments: attachments,
          model: model,
          effort: effort,
          approvalMode: state.approvalMode,
          sandbox: state.sandbox,
          cwd: profile.workspace.trim().isEmpty
              ? thread.cwd
              : profile.workspace,
        );
      }
      if (mounted && _isActiveThread(key, thread.id)) {
        _diagnostics.info(
          'Message',
          'send_accepted profile=$profileId agent=${key.agent.name} '
              'thread=${thread.id} turn=$turnId',
        );
        final startedAt = DateTime.now().millisecondsSinceEpoch;
        state = state.copyWith(
          submitting: false,
          running: true,
          activeTurnId: turnId,
          timeline: state.timeline
              .map(
                (entry) => entry.id == optimisticId
                    ? entry.copyWith(turnId: turnId)
                    : entry,
              )
              .toList(growable: false),
          activeThread: state.activeThread?.copyWith(
            status: 'active',
            activeTurnId: turnId,
          ),
          turnTiming: steering
              ? state.turnTiming
              : TurnTiming(
                  threadId: thread.id,
                  turnId: turnId,
                  startedAtMillis: startedAt,
                ),
        );
      }
    } catch (error, stack) {
      _diagnostics.warn(
        'Message',
        'send_failed profile=$profileId agent=${key.agent.name} thread=${thread.id}',
        error,
        stack,
      );
      if (mounted && _isActiveThread(key, thread.id)) {
        state = state.copyWith(
          submitting: false,
          running: steeringTurnId?.isNotEmpty == true,
          timeline: state.timeline
              .where((entry) => entry.id != optimisticId)
              .toList(growable: false),
          composerDraft: draftBeforeSend,
          attachments: attachments,
          composerClearNonce: state.composerClearNonce + 1,
          error: _message(error, '发送消息失败'),
        );
        unawaited(
          _persist(
            (stored) => stored.copyWith(
              composerDrafts: {
                ...stored.composerDrafts,
                draftKey: draftBeforeSend,
              },
            ),
          ),
        );
      }
    }
  }

  Future<void> stopMessage() async {
    await _ensureInitialized();
    final profileId = state.selectedProfileId;
    final thread = state.activeThread;
    final turnId = state.activeTurnId;
    if (profileId == null ||
        thread == null ||
        turnId == null ||
        turnId.isEmpty) {
      return;
    }
    final key = AgentConnectionKey(
      profileId: profileId,
      agent: state.activeAgent,
    );
    _settleVisibleTurnLocally(key, thread.id, turnId, stopped: true);
    try {
      await _agents.interruptTurn(key, threadId: thread.id, turnId: turnId);
    } catch (error, stack) {
      _diagnostics.warn(
        'Message',
        'interrupt_failed profile=$profileId agent=${key.agent.name} '
            'thread=${thread.id} turn=$turnId',
        error,
        stack,
      );
      // A completed turn can race the stop request. The server has already
      // done the requested work, so the local settlement is final.
      if (_isNoActiveTurnInterruptError(error)) return;
      final timing = state.turnTiming;
      if (mounted &&
          _isActiveThread(key, thread.id) &&
          !state.running &&
          state.activeTurnId == null &&
          timing?.threadId == thread.id &&
          timing?.turnId == turnId &&
          timing?.completedAtMillis != null) {
        state = state.copyWith(
          error: '已结束本地处理状态；远端停止失败：${_message(error, '请求失败')}',
        );
      }
    }
  }

  void _settleVisibleTurnLocally(
    AgentConnectionKey key,
    String threadId,
    String turnId, {
    required bool stopped,
  }) {
    if (!mounted || !_isActiveThread(key, threadId)) return;
    final before = state;
    final reduced = settleActiveTurnLocally(
      before,
      threadId: threadId,
      turnId: turnId,
      stopped: stopped,
    );
    if (identical(before, reduced)) return;
    final lists = Map<AgentConnectionKey, List<AgentThread>>.of(
      before.agentThreadLists,
    );
    if (reduced.threads != before.threads) lists[key] = reduced.threads;
    final pending = _pendingApprovalsByThread[key];
    pending?.remove(threadId);
    if (pending?.isEmpty == true) _pendingApprovalsByThread.remove(key);
    state = reduced.copyWith(
      agentThreadLists: Map.unmodifiable(lists),
      approvalQueue: const <ApprovalPrompt>[],
      approval: null,
    );
    final activeThread = state.activeThread;
    if (activeThread != null) {
      _threadCaches
          .putIfAbsent(key, ThreadSessionCache.new)
          .put(
            activeThread,
            state.timeline,
            nextTurnsCursor: state.olderTurnsCursor,
            tokenUsage: state.tokenUsage,
          );
    }
    final timing = state.turnTiming;
    if (timing != null) {
      unawaited(
        _persist(
          (stored) => stored.copyWith(
            completedTurnTimings: {
              ...stored.completedTurnTimings,
              threadPreferenceKey(key.profileId, key.agent, threadId): timing,
            },
          ),
        ),
      );
    }
  }

  Future<void> compactActiveThread() async {
    await _ensureInitialized();
    final thread = state.activeThread;
    final profileId = state.selectedProfileId;
    if (!state.activeAgentCapabilities.compactThread ||
        thread == null ||
        profileId == null) {
      return;
    }
    if (state.running) {
      state = state.copyWith(error: '当前回合运行中，完成或停止后才能压缩会话');
      return;
    }
    final key = AgentConnectionKey(
      profileId: profileId,
      agent: state.activeAgent,
    );
    if (!_beginThreadMutation(key, thread.id)) return;
    try {
      await _agents.compactThread(key, threadId: thread.id);
      if (mounted && _isActiveThread(key, thread.id)) {
        state = state.copyWith(diagnostic: '已开始压缩会话上下文');
      }
    } catch (error) {
      _setThreadMutationError(key, thread.id, error, '压缩会话失败');
    } finally {
      _finishThreadMutation(key, thread.id);
    }
  }

  Future<void> reviewChanges() async {
    await _ensureInitialized();
    final thread = state.activeThread;
    final profileId = state.selectedProfileId;
    if (!state.activeAgentCapabilities.reviewChanges ||
        thread == null ||
        profileId == null ||
        state.running) {
      return;
    }
    final key = AgentConnectionKey(
      profileId: profileId,
      agent: state.activeAgent,
    );
    if (!_beginThreadMutation(key, thread.id)) return;
    try {
      await _agents.startReview(key, threadId: thread.id);
    } catch (error) {
      _setThreadMutationError(key, thread.id, error, '启动代码审查失败');
    } finally {
      _finishThreadMutation(key, thread.id);
    }
  }

  Future<void> rollbackActiveThread() async {
    await _ensureInitialized();
    final thread = state.activeThread;
    final profileId = state.selectedProfileId;
    if (!state.activeAgentCapabilities.rollbackThread ||
        thread == null ||
        profileId == null) {
      return;
    }
    if (state.running) {
      state = state.copyWith(error: '回合运行中，完成或停止后才能回退会话历史');
      return;
    }
    final key = AgentConnectionKey(
      profileId: profileId,
      agent: state.activeAgent,
    );
    if (!_beginThreadMutation(key, thread.id)) return;
    try {
      final session = await _agents.rollbackThread(
        key,
        threadId: thread.id,
        approvalMode: state.approvalMode,
      );
      if (!mounted || !_isActiveThread(key, thread.id)) return;
      final cache = _threadCaches.putIfAbsent(key, ThreadSessionCache.new);
      cache
        ..remove(thread.id)
        ..put(
          session.thread,
          session.timeline,
          nextTurnsCursor: session.nextTurnsCursor,
          tokenUsage: session.tokenUsage,
        );
      final lists = _replaceLaneThread(
        state.agentThreadLists,
        key,
        session.thread,
      );
      state = state.copyWith(
        agentThreadLists: lists,
        threads: lists[key] ?? state.threads,
        activeThread: session.thread,
        timeline: session.timeline,
        olderTurnsCursor: session.nextTurnsCursor,
        olderTurnsLoading: false,
        activeTurnId: session.thread.activeTurnId,
        running: _threadIsRunning(session.thread),
        aggregateDiff: '',
        tokenUsage: session.tokenUsage,
      );
    } catch (error) {
      _setThreadMutationError(key, thread.id, error, '回退会话失败');
    } finally {
      _finishThreadMutation(key, thread.id);
    }
  }

  Future<void> archiveActiveThread() async {
    await _ensureInitialized();
    final thread = state.activeThread;
    final profileId = state.selectedProfileId;
    if (!state.activeAgentCapabilities.archiveThread ||
        thread == null ||
        profileId == null) {
      return;
    }
    if (state.running) {
      state = state.copyWith(error: '回合运行中，完成或停止后才能归档');
      return;
    }
    final key = AgentConnectionKey(
      profileId: profileId,
      agent: state.activeAgent,
    );
    _clearSubAgentNavigation(key);
    if (!_beginThreadMutation(key, thread.id)) return;
    try {
      await _agents.archiveThread(key, threadId: thread.id);
      if (!mounted || !_isActiveThread(key, thread.id)) return;
      final storageKey = threadPreferenceKey(
        key.profileId,
        key.agent,
        thread.id,
      );
      _threadCaches[key]?.remove(thread.id);
      _threadGoals.remove(storageKey);
      final approvalBuckets = _pendingApprovalsByThread[key];
      approvalBuckets?.remove(_approvalThreadId(thread.id));
      if (approvalBuckets?.isEmpty == true) {
        _pendingApprovalsByThread.remove(key);
      }
      final laneThreads =
          state.agentThreadLists[key]
              ?.where((candidate) => candidate.id != thread.id)
              .toList(growable: false) ??
          const <AgentThread>[];
      final lists = Map<AgentConnectionKey, List<AgentThread>>.of(
        state.agentThreadLists,
      )..[key] = List<AgentThread>.unmodifiable(laneThreads);
      state = state.copyWith(
        screen: AppScreen.threads,
        agentThreadLists: Map.unmodifiable(lists),
        threads: laneThreads,
        activeThread: null,
        activeGoal: null,
        timeline: const <TimelineEntry>[],
        olderTurnsCursor: null,
        olderTurnsLoading: false,
        activeTurnId: null,
        running: false,
        approval: null,
        approvalQueue: const <ApprovalPrompt>[],
        aggregateDiff: '',
        tokenUsage: null,
        composerDraft: '',
        attachments: const <PendingAttachment>[],
        attachmentUploading: false,
        submitting: false,
      );
      await _persist(
        (stored) => stored.copyWith(
          composerDrafts: _withoutMapKey(stored.composerDrafts, storageKey),
          threadModelPreferences: _withoutMapKey(
            stored.threadModelPreferences,
            storageKey,
          ),
          completedTurnTimings: _withoutMapKey(
            stored.completedTurnTimings,
            storageKey,
          ),
        ),
      );
      if (mounted && _isActiveKey(key)) unawaited(refreshThreads());
    } catch (error) {
      _setThreadMutationError(key, thread.id, error, '归档会话失败');
    } finally {
      _finishThreadMutation(key, thread.id);
    }
  }

  Future<void> renameActiveThread(String name) async {
    await _ensureInitialized();
    final clean = name.trim();
    final thread = state.activeThread;
    final profileId = state.selectedProfileId;
    if (!state.activeAgentCapabilities.renameThread ||
        clean.isEmpty ||
        thread == null ||
        profileId == null) {
      return;
    }
    final key = AgentConnectionKey(
      profileId: profileId,
      agent: state.activeAgent,
    );
    if (!_beginThreadMutation(key, thread.id)) return;
    try {
      await _agents.setThreadName(key, threadId: thread.id, name: clean);
      if (!mounted || !_isActiveThread(key, thread.id)) return;
      final renamed = (state.activeThread ?? thread).copyWith(title: clean);
      final cache = _threadCaches[key];
      final cached = cache?.getStale(thread.id);
      if (cached != null) {
        cache!.put(
          cached.thread.copyWith(title: clean),
          cached.timeline,
          nextTurnsCursor: cached.nextTurnsCursor,
          tokenUsage: cached.tokenUsage,
        );
      }
      final lists = _replaceLaneThread(state.agentThreadLists, key, renamed);
      state = state.copyWith(
        activeThread: renamed,
        agentThreadLists: lists,
        threads: lists[key] ?? state.threads,
      );
    } catch (error) {
      _setThreadMutationError(key, thread.id, error, '重命名会话失败');
    } finally {
      _finishThreadMutation(key, thread.id);
    }
  }

  Future<void> setActiveGoal(String objective) async {
    final trimmed = objective.trim();
    if (trimmed.isEmpty) {
      await clearActiveGoal();
      return;
    }
    final clean = trimmed.length <= 4000 ? trimmed : trimmed.substring(0, 4000);
    final currentStatus = state.activeGoal?.status;
    final status =
        currentStatus == ThreadGoalStatus.active ||
            currentStatus == ThreadGoalStatus.paused
        ? currentStatus!
        : ThreadGoalStatus.active;
    await _mutateActiveGoal(
      (key, threadId) => _agents.setThreadGoal(
        key,
        threadId: threadId,
        objective: clean,
        status: status,
      ),
    );
  }

  Future<void> toggleActiveGoalPause() async {
    final status = state.activeGoal?.status;
    final next = switch (status) {
      ThreadGoalStatus.active => ThreadGoalStatus.paused,
      ThreadGoalStatus.paused => ThreadGoalStatus.active,
      _ => null,
    };
    if (next == null) return;
    await _mutateActiveGoal(
      (key, threadId) =>
          _agents.setThreadGoal(key, threadId: threadId, status: next),
    );
  }

  Future<void> clearActiveGoal() async {
    if (state.activeGoal == null) return;
    await _mutateActiveGoal((key, threadId) async {
      await _agents.clearThreadGoal(key, threadId: threadId);
      return null;
    });
  }

  Future<void> _mutateActiveGoal(
    Future<ThreadGoal?> Function(AgentConnectionKey key, String threadId)
    mutation,
  ) async {
    await _ensureInitialized();
    final thread = state.activeThread;
    final profileId = state.selectedProfileId;
    if (!state.activeAgentCapabilities.threadGoals ||
        thread == null ||
        profileId == null) {
      return;
    }
    final key = AgentConnectionKey(
      profileId: profileId,
      agent: state.activeAgent,
    );
    if (!_beginThreadMutation(key, thread.id)) return;
    try {
      final goal = await mutation(key, thread.id);
      final storageKey = threadPreferenceKey(
        key.profileId,
        key.agent,
        thread.id,
      );
      if (goal == null) {
        _threadGoals.remove(storageKey);
      } else {
        _threadGoals[storageKey] = goal;
      }
      if (mounted && _isActiveThread(key, thread.id)) {
        state = state.copyWith(activeGoal: goal);
      }
    } catch (error) {
      final detail = _message(error, '更新目标失败');
      final display =
          detail.toLowerCase().contains('method not found') ||
              detail.contains('-32601')
          ? '远程 Codex 版本不支持目标模式，请升级 Codex CLI 后重试'
          : detail;
      _setThreadMutationError(key, thread.id, display, '更新目标失败');
    } finally {
      _finishThreadMutation(key, thread.id);
    }
  }

  bool _beginThreadMutation(AgentConnectionKey key, String threadId) {
    if (state.loading ||
        state.submitting ||
        !_isActiveThread(key, threadId) ||
        !_threadMutationLanes.add(key)) {
      return false;
    }
    state = state.copyWith(submitting: true, error: null);
    return true;
  }

  void _finishThreadMutation(AgentConnectionKey key, String threadId) {
    _threadMutationLanes.remove(key);
    if (mounted && _isActiveThread(key, threadId) && state.submitting) {
      state = state.copyWith(submitting: false);
    }
  }

  void _setThreadMutationError(
    AgentConnectionKey key,
    String threadId,
    Object error,
    String fallback,
  ) {
    if (mounted && _isActiveThread(key, threadId)) {
      state = state.copyWith(error: _message(error, fallback));
    }
  }

  Future<void> answerApproval(
    bool accept, {
    Map<String, String> answers = const <String, String>{},
  }) async {
    await _ensureInitialized();
    final profileId = state.selectedProfileId;
    final prompt = state.approval;
    final activeThreadId = _approvalThreadId(state.activeThread?.id);
    if (profileId == null ||
        prompt == null ||
        state.submitting ||
        (_approvalThreadId(prompt.threadId).isNotEmpty &&
            _approvalThreadId(prompt.threadId) != activeThreadId)) {
      return;
    }
    final key = AgentConnectionKey(
      profileId: profileId,
      agent: state.activeAgent,
    );
    state = state.copyWith(submitting: true, error: null);
    try {
      await _agents.answerApproval(
        key,
        prompt,
        accept: accept,
        answers: answers,
      );
      _removeApproval(key, prompt);
      if (!mounted ||
          !_isActiveKey(key) ||
          _approvalThreadId(state.activeThread?.id) != activeThreadId) {
        return;
      }
      final remaining = _approvalQueueFor(key, activeThreadId);
      state = state.copyWith(
        approvalQueue: remaining,
        approval: remaining.firstOrNull,
        submitting: false,
      );
    } catch (error) {
      if (mounted && _isActiveKey(key)) {
        state = state.copyWith(
          submitting: false,
          error: _message(error, '回复审批失败'),
        );
      }
    }
  }

  Future<void> fetchApiModelOptions() async {
    await _ensureInitialized();
    if (!state.activeAgentCapabilities.globalSettings ||
        state.apiModelOptionsLoading) {
      return;
    }
    final profileId = state.selectedProfileId;
    final agent = state.activeAgent;
    final profile = state.profiles.firstWhereOrNull(
      (candidate) => candidate.id == profileId,
    );
    if (profileId == null || profile == null) return;
    final key = AgentConnectionKey(profileId: profileId, agent: agent);
    if (_agents.states[key]?.phase != ConnectionPhase.connected) {
      state = state.copyWith(
        apiModelOptions: const <ApiModelOption>[],
        apiModelOptionsProfileId: profileId,
        apiModelOptionsLoading: false,
        apiModelOptionsError: '服务器未连接，无法获取模型列表',
      );
      return;
    }

    final requestId = ++_apiModelOptionsRequestId;
    final generation = _agents.generation(key);
    state = state.copyWith(
      apiModelOptions: const <ApiModelOption>[],
      apiModelOptionsProfileId: profileId,
      apiModelOptionsLoading: true,
      apiModelOptionsError: null,
    );
    try {
      final settings = await _agents.readGlobalSettings(key, profile);
      _diagnostics.info(
        'ApiModels',
        'fetch_start profile=$profileId agent=${agent.label} '
            'provider=${settings.modelProvider} '
            'base_url_configured=${settings.baseUrl.trim().isNotEmpty} '
            'api_key_configured=${settings.apiKey.trim().isNotEmpty} '
            'proxy_configured=${settings.proxyUrl.trim().isNotEmpty}',
      );
      final models = await _agents.fetchApiModels(
        key,
        profile,
        baseUrl: settings.baseUrl,
        apiKey: settings.apiKey,
        proxyUrl: settings.proxyUrl,
      );
      if (!_isApiModelOptionsRequestCurrent(requestId, key, generation)) {
        return;
      }
      _diagnostics.info(
        'ApiModels',
        'fetch_success profile=$profileId agent=${agent.label} '
            'models=${models.length}',
      );
      state = state.copyWith(
        apiModelOptions: models,
        apiModelOptionsProfileId: profileId,
        apiModelOptionsLoading: false,
        apiModelOptionsError: null,
      );
    } catch (error, stack) {
      _diagnostics.warn(
        'ApiModels',
        'fetch_failed profile=$profileId agent=${agent.label}',
        error,
        stack,
      );
      if (!_isApiModelOptionsRequestCurrent(requestId, key, generation)) {
        return;
      }
      state = state.copyWith(
        apiModelOptions: const <ApiModelOption>[],
        apiModelOptionsProfileId: profileId,
        apiModelOptionsLoading: false,
        apiModelOptionsError: _message(error, '无法获取 API 模型列表'),
      );
    }
  }

  void saveCustomModel(
    String? originalModelId,
    CustomModelDefinition definition,
  ) {
    final profileId = state.selectedProfileId;
    if (profileId == null || !state.activeAgentCapabilities.models) return;
    final agent = state.activeAgent;
    late final CustomModelDefinition normalized;
    try {
      normalized = normalizeCustomModelDefinitionForAgent(agent, definition);
    } catch (error) {
      state = state.copyWith(error: _message(error, '自定义模型格式错误'));
      return;
    }
    final profile = state.profiles.firstWhereOrNull(
      (candidate) => candidate.id == profileId,
    );
    if (profile == null) return;
    final settings = profile.modelSettings(agent);
    String? originalId;
    try {
      originalId = originalModelId?.trim().isNotEmpty == true
          ? normalizeAgentModelId(agent, originalModelId!)
          : null;
    } on ArgumentError {
      originalId = null;
    }
    final originalIndex = originalId?.isNotEmpty == true
        ? settings.customModels.indexWhere(
            (model) => model.modelId.trim() == originalId,
          )
        : -1;
    final duplicateIndex = settings.customModels.indexWhere(
      (model) => model.modelId.trim() == normalized.modelId,
    );
    if (duplicateIndex >= 0 && duplicateIndex != originalIndex) {
      state = state.copyWith(error: '已有相同的自定义模型 ID');
      return;
    }
    if (originalIndex < 0 && settings.customModels.length >= maxCustomModels) {
      state = state.copyWith(error: '自定义模型最多可添加 $maxCustomModels 个');
      return;
    }

    _updateProfileModelCatalog(profileId, agent, (current) {
      final replacementIndex = originalId?.isNotEmpty == true
          ? current.customModels.indexWhere(
              (model) => model.modelId.trim() == originalId,
            )
          : current.customModels.indexWhere(
              (model) => model.modelId.trim() == normalized.modelId,
            );
      final customModels = [...current.customModels];
      if (replacementIndex >= 0) {
        customModels[replacementIndex] = normalized;
      } else {
        customModels.add(normalized);
      }
      return current.copyWith(
        customModels: customModels,
        managedModelIds: <String>{
          ...current.managedModelIds,
          if (originalId?.isNotEmpty == true) originalId!,
          normalized.modelId,
        }.toList(growable: false),
      );
    });
  }

  void deleteCustomModel(String modelId) {
    final profileId = state.selectedProfileId;
    final agent = state.activeAgent;
    late final String normalizedId;
    try {
      normalizedId = normalizeAgentModelId(agent, modelId);
    } on ArgumentError {
      return;
    }
    if (profileId == null || normalizedId.isEmpty) return;
    final key = AgentConnectionKey(profileId: profileId, agent: agent);
    final profile = state.profiles.firstWhereOrNull(
      (candidate) => candidate.id == profileId,
    );
    if (profile == null) return;
    final settings = profile.modelSettings(agent);
    final discovered = (state.agentModelLists[key] ?? const <AgentModel>[]).any(
      (model) =>
          model.isCustom &&
          (model.id.trim() == normalizedId ||
              modelWireName(model) == normalizedId),
    );
    if (!discovered &&
        settings.customModels.every(
          (model) => model.modelId.trim() != normalizedId,
        )) {
      return;
    }
    _updateProfileModelCatalog(
      profileId,
      agent,
      (current) => current.copyWith(
        preferredModel: current.preferredModel == normalizedId
            ? ''
            : current.preferredModel,
        testModel: current.testModel == normalizedId ? '' : current.testModel,
        customModels: current.customModels
            .where((model) => model.modelId.trim() != normalizedId)
            .toList(growable: false),
        managedModelIds: <String>{
          ...current.managedModelIds,
          normalizedId,
        }.toList(growable: false),
      ),
    );
  }

  void setModelHidden(String modelId, bool hidden) {
    final profileId = state.selectedProfileId;
    final agent = state.activeAgent;
    late final String normalizedId;
    try {
      normalizedId = normalizeAgentModelId(agent, modelId);
    } on ArgumentError {
      return;
    }
    if (profileId == null || normalizedId.isEmpty) return;
    _updateProfileModelCatalog(profileId, agent, (current) {
      final hiddenIds = <String>{...current.hiddenModelIds};
      if (hidden) {
        hiddenIds.add(normalizedId);
      } else {
        hiddenIds.remove(normalizedId);
      }
      return current.copyWith(
        hiddenModelIds: hiddenIds.toList(growable: false),
      );
    });
  }

  void selectThreadModel(String model, {String? effort}) {
    if (!state.activeAgentCapabilities.models) return;
    final profileId = state.selectedProfileId;
    final threadId = state.activeThread?.id;
    if (profileId == null || threadId == null || model.trim().isEmpty) return;
    late final String normalizedModel;
    try {
      normalizedModel = normalizeAgentModelId(state.activeAgent, model);
    } catch (error) {
      state = state.copyWith(error: _message(error, '模型格式错误'));
      return;
    }
    final normalizedEffort = effort?.trim() ?? state.selectedEffort ?? '';
    state = state.copyWith(
      selectedModel: normalizedModel,
      selectedEffort: normalizedEffort.isEmpty ? null : normalizedEffort,
    );
    final key = threadPreferenceKey(profileId, state.activeAgent, threadId);
    unawaited(
      _persist(
        (stored) => stored.copyWith(
          threadModelPreferences: {
            ...stored.threadModelPreferences,
            key: ThreadModelPreference(
              model: normalizedModel,
              effort: normalizedEffort,
            ),
          },
        ),
      ),
    );
  }

  void selectThreadEffort(String effort) {
    if (!state.activeAgentCapabilities.reasoningEffort) return;
    final model = state.selectedModel;
    if (model == null || model.trim().isEmpty) return;
    selectThreadModel(model, effort: effort);
  }

  void _showThreadSnapshot(
    AgentConnectionKey key,
    AgentSession snapshot, {
    required bool loading,
    required ThreadGoal? activeGoal,
    AppScreen targetScreen = AppScreen.work,
    String? activeAgentName,
    bool subAgentBackNavigation = false,
    _SessionSnapshot? initialSnapshot,
  }) {
    _rememberSubAgentReferences(key, <AgentThread>[
      snapshot.thread,
    ], snapshot.timeline);
    final active = _isActiveKey(key);
    final preference = active && snapshot.thread.id.isNotEmpty
        ? _stored.threadModelPreferences[threadPreferenceKey(
            key.profileId,
            key.agent,
            snapshot.thread.id,
          )]
        : null;
    final profile = active
        ? state.profiles.firstWhereOrNull(
            (candidate) => candidate.id == key.profileId,
          )
        : null;
    final defaults = profile?.modelSettings(key.agent);
    final sameInitialThread =
        initialSnapshot?.activeThread?.id == snapshot.thread.id;
    final approvalQueue = sameInitialThread
        ? initialSnapshot!.approvalQueue
        : _approvalQueueFor(key, snapshot.thread.id);
    final draft = sameInitialThread
        ? initialSnapshot!.composerDraft
        : active && snapshot.thread.id.isNotEmpty
        ? _stored.composerDrafts[threadPreferenceKey(
            key.profileId,
            key.agent,
            snapshot.thread.id,
          )]
        : null;
    final configuredModel = preference?.model.isNotEmpty == true
        ? preference!.model
        : defaults?.preferredModel ?? '';
    final configuredEffort = preference?.effort.isNotEmpty == true
        ? preference!.effort
        : defaults?.preferredEffort ?? '';
    final resolvedModel = resolveModelSelection(
      state.models,
      configuredModel,
      configuredEffort,
    );
    final selectedModel =
        sameInitialThread && initialSnapshot!.selectedModel != null
        ? initialSnapshot.selectedModel
        : resolvedModel.model;
    final selectedEffort =
        sameInitialThread && initialSnapshot!.selectedEffort != null
        ? initialSnapshot.selectedEffort
        : resolvedModel.effort;
    final threadHasActiveTurn =
        snapshot.thread.activeTurnId?.trim().isNotEmpty == true;
    final threadStatusRunning = _threadStatusIndicatesRunning(
      snapshot.thread.status,
    );
    final timelineTurnId = threadHasActiveTurn || threadStatusRunning
        ? _activeTimelineTurnId(snapshot.timeline)
        : null;
    final serverActiveTurnId = threadHasActiveTurn
        ? snapshot.thread.activeTurnId
        : timelineTurnId;
    final currentTiming = sameInitialThread
        ? initialSnapshot!.turnTiming
        : state.turnTiming?.threadId == snapshot.thread.id
        ? state.turnTiming
        : null;
    final storedTiming = active && snapshot.thread.id.isNotEmpty
        ? _stored.completedTurnTimings[threadPreferenceKey(
            key.profileId,
            key.agent,
            snapshot.thread.id,
          )]
        : null;
    final completedTiming = currentTiming?.completedAtMillis != null
        ? currentTiming
        : storedTiming?.threadId == snapshot.thread.id &&
              storedTiming?.completedAtMillis != null
        ? storedTiming
        : null;
    final locallySettled = _completedTimingMatchesTurn(
      completedTiming,
      snapshot.thread.id,
      serverActiveTurnId,
    );
    final activeTurnId = locallySettled ? null : serverActiveTurnId;
    final running =
        !locallySettled &&
        (_threadIsRunning(snapshot.thread) || activeTurnId != null);
    final resolvedThread = locallySettled
        ? snapshot.thread.copyWith(status: 'idle', activeTurnId: null)
        : snapshot.thread;
    final reusableTiming =
        _canReuseTurnTiming(currentTiming, snapshot.thread.id, activeTurnId)
        ? currentTiming
        : null;
    final resolvedReusableTiming =
        reusableTiming != null &&
            (reusableTiming.turnId?.trim().isEmpty ?? true) &&
            activeTurnId?.trim().isNotEmpty == true
        ? reusableTiming.copyWith(turnId: activeTurnId)
        : reusableTiming;
    final serverStartedAt = snapshot.activeTurnStartedAtMillis;
    final turnTiming = running
        ? serverStartedAt != null &&
                  resolvedReusableTiming?.startedAtMillis != serverStartedAt
              ? TurnTiming(
                  threadId: snapshot.thread.id,
                  turnId: activeTurnId,
                  startedAtMillis: serverStartedAt,
                )
              : resolvedReusableTiming ??
                    TurnTiming(
                      threadId: snapshot.thread.id,
                      turnId: activeTurnId,
                      startedAtMillis: DateTime.now().millisecondsSinceEpoch,
                    )
        : completedTiming;
    state = state.copyWith(
      screen: targetScreen,
      subAgentBackNavigation: subAgentBackNavigation,
      activeThread: resolvedThread,
      activeAgentName: activeAgentName,
      activeGoal: sameInitialThread ? initialSnapshot!.activeGoal : activeGoal,
      timeline: snapshot.timeline,
      olderTurnsCursor: snapshot.nextTurnsCursor,
      tokenUsage: snapshot.tokenUsage,
      loading: active ? loading : state.loading,
      activeTurnId: activeTurnId,
      running: running,
      turnTiming: turnTiming,
      submitting: false,
      composerDraft: draft ?? '',
      composerClearNonce: sameInitialThread
          ? initialSnapshot!.composerClearNonce
          : state.composerClearNonce,
      attachments: sameInitialThread
          ? initialSnapshot!.attachments
          : const <PendingAttachment>[],
      attachmentUploading: false,
      selectedModel: selectedModel,
      selectedEffort: selectedEffort,
      approvalQueue: approvalQueue,
      approval: approvalQueue.firstOrNull,
      error: null,
    );
  }

  Future<bool> _openThreadInternal({
    required AgentThread thread,
    required AppScreen targetScreen,
    required String? agentName,
    required int navigationGeneration,
    String? requestKey,
    _SessionSnapshot? initialSnapshot,
    bool subAgentBackNavigation = false,
    void Function()? onResumed,
    bool Function(Object error)? onResumeFailure,
  }) async {
    try {
      await _ensureInitialized();
    } catch (_) {
      return false;
    }
    final profileId = state.selectedProfileId;
    if (profileId == null) return false;
    final key = AgentConnectionKey(
      profileId: profileId,
      agent: state.activeAgent,
    );
    if ((_sessionNavigationGenerations[key] ?? 0) != navigationGeneration) {
      return false;
    }
    final profile = state.profiles.firstWhereOrNull(
      (candidate) => candidate.id == profileId,
    );
    if (profile == null) return false;
    final effectiveRequestKey =
        requestKey ?? threadPreferenceKey(profileId, key.agent, thread.id);
    final cache = _threadCaches.putIfAbsent(key, ThreadSessionCache.new);
    final cached = cache.get(thread.id) ?? cache.getStale(thread.id);
    final rememberedTokenUsage =
        cache.contextUsage(thread.id) ??
        cached?.tokenUsage ??
        initialSnapshot?.tokenUsage;
    final displaySession = cached == null
        ? initialSnapshot == null
              ? AgentSession(thread: thread, timeline: const <TimelineEntry>[])
              : AgentSession(
                  thread: initialSnapshot.activeThread ?? thread,
                  timeline: initialSnapshot.timeline,
                  nextTurnsCursor: initialSnapshot.olderTurnsCursor,
                  tokenUsage: initialSnapshot.tokenUsage,
                )
        : AgentSession(
            thread: cached.thread,
            timeline: cached.timeline,
            nextTurnsCursor: cached.nextTurnsCursor,
            tokenUsage: rememberedTokenUsage,
          );
    _showThreadSnapshot(
      key,
      displaySession,
      loading: true,
      activeGoal: _threadGoals[effectiveRequestKey],
      targetScreen: targetScreen,
      activeAgentName: agentName,
      subAgentBackNavigation: subAgentBackNavigation,
      initialSnapshot: initialSnapshot,
    );
    final pending = _threadOpenRequests[effectiveRequestKey];
    if (pending != null && pending.generation == navigationGeneration) {
      return true;
    }
    late final _ThreadOpenRequest request;
    final future =
        _resumeThread(
          key,
          profile,
          thread,
          cache,
          navigationGeneration: navigationGeneration,
          targetScreen: targetScreen,
          activeAgentName: agentName,
          subAgentBackNavigation: subAgentBackNavigation,
          initialSnapshot: initialSnapshot,
          onResumed: onResumed,
          onResumeFailure: onResumeFailure,
        ).whenComplete(() {
          if (identical(_threadOpenRequests[effectiveRequestKey], request)) {
            _threadOpenRequests.remove(effectiveRequestKey);
          }
        });
    request = _ThreadOpenRequest(navigationGeneration, future);
    _threadOpenRequests[effectiveRequestKey] = request;
    return true;
  }

  Future<void> _resumeThread(
    AgentConnectionKey key,
    ServerProfile profile,
    AgentThread thread,
    ThreadSessionCache cache, {
    required int navigationGeneration,
    required AppScreen targetScreen,
    required String? activeAgentName,
    required bool subAgentBackNavigation,
    required _SessionSnapshot? initialSnapshot,
    void Function()? onResumed,
    bool Function(Object error)? onResumeFailure,
  }) async {
    ResumeNotificationBuffer? resumeBuffer;
    try {
      final initialRemoteGeneration = _agents.remoteGeneration(key);
      if (initialRemoteGeneration != null) {
        resumeBuffer = _installResumeNotificationBuffer(
          key,
          thread.id,
          initialRemoteGeneration,
        );
      }
      await _agents.connect(profile, key.agent);
      final remoteGeneration = _agents.remoteGeneration(key);
      if (remoteGeneration != null &&
          (resumeBuffer == null ||
              resumeBuffer.generation != remoteGeneration)) {
        resumeBuffer = _installResumeNotificationBuffer(
          key,
          thread.id,
          remoteGeneration,
        );
      }
      final session = await _resumeExpectedThread(key, thread.id);
      final cachedSnapshot = cache.getStale(thread.id);
      final reconciled = reconcileResumedTimeline(
        cachedTimeline: cachedSnapshot?.timeline,
        cachedNextCursor: cachedSnapshot?.nextTurnsCursor,
        refreshedTimeline: session.timeline,
        refreshedNextCursor: session.nextTurnsCursor,
        refreshedTurnIds: session.turnIds,
        cachedThreadUpdatedAt: _knownRevision(cachedSnapshot?.thread.updatedAt),
        refreshedThreadUpdatedAt: _knownRevision(session.thread.updatedAt),
        refreshedItemsView: session.itemsView,
      );
      final liveTokenUsage =
          _isActiveThread(key, thread.id) &&
              state.tokenUsage?.hasKnownContextWindow == true
          ? state.tokenUsage
          : null;
      final tokenUsage =
          liveTokenUsage ??
          (session.tokenUsage?.hasKnownContextWindow == true
              ? session.tokenUsage
              : cachedSnapshot?.tokenUsage ?? session.tokenUsage);
      final resolvedSession = AgentSession(
        thread: session.thread,
        timeline: reconciled.timeline,
        nextTurnsCursor: reconciled.nextCursor,
        tokenUsage: tokenUsage,
        responseSequence: session.responseSequence,
        activeTurnStartedAtMillis: session.activeTurnStartedAtMillis,
        turnIds: session.turnIds,
        itemsView: session.itemsView,
      );
      if (mounted &&
          _isCurrentSessionNavigation(key, navigationGeneration, thread.id)) {
        _showThreadSnapshot(
          key,
          resolvedSession,
          loading: false,
          activeGoal:
              _threadGoals[threadPreferenceKey(
                key.profileId,
                key.agent,
                thread.id,
              )],
          targetScreen: targetScreen,
          activeAgentName: activeAgentName,
          subAgentBackNavigation: subAgentBackNavigation,
          initialSnapshot: initialSnapshot,
        );
        if (session.itemsView == 'notLoaded') {
          state = state.copyWith(diagnostic: '最近一个回合内容过大，已跳过详情；会话仍可继续使用');
        }
        if (resumeBuffer != null) {
          _releaseResumeNotifications(
            key,
            resumeBuffer,
            session.timeline,
            replay: true,
            snapshotSequence: resolvedSession.responseSequence,
          );
        }
        _cacheActiveThreadSession(key, expectedThreadId: thread.id);
        onResumed?.call();
      } else if (resumeBuffer != null) {
        _releaseResumeNotifications(
          key,
          resumeBuffer,
          session.timeline,
          replay: false,
        );
      }
      if (_agents.capabilities(key).threadGoals) {
        unawaited(_hydrateThreadGoal(key, thread.id));
      }
    } catch (error) {
      if (mounted &&
          _isCurrentSessionNavigation(key, navigationGeneration, thread.id)) {
        if (resumeBuffer != null) {
          _releaseResumeNotifications(
            key,
            resumeBuffer,
            state.timeline,
            replay: true,
            snapshotSequence: -1,
          );
          _cacheActiveThreadSession(key, expectedThreadId: thread.id);
        }
        final handled = onResumeFailure?.call(error) ?? false;
        if (!handled && mounted) {
          state = state.copyWith(
            loading: false,
            error: _message(error, '恢复会话失败'),
          );
        }
      } else if (resumeBuffer != null) {
        _releaseResumeNotifications(
          key,
          resumeBuffer,
          const <TimelineEntry>[],
          replay: false,
        );
      }
    } finally {
      if (resumeBuffer != null &&
          identical(_resumeNotificationBuffers[key], resumeBuffer)) {
        _resumeNotificationBuffers.remove(key);
      }
    }
  }

  Future<AgentSession> _resumeExpectedThread(
    AgentConnectionKey key,
    String threadId,
  ) async {
    final first = await _agents.resumeThread(
      key,
      threadId,
      approvalMode: state.approvalMode,
    );
    if (first.thread.id == threadId) return first;
    final retry = await _agents.resumeThread(
      key,
      threadId,
      approvalMode: state.approvalMode,
    );
    if (retry.thread.id == threadId) return retry;
    throw StateError('服务器返回了其他会话，已阻止显示父会话内容');
  }

  ResumeNotificationBuffer _installResumeNotificationBuffer(
    AgentConnectionKey key,
    String threadId,
    int generation,
  ) {
    final previous = _resumeNotificationBuffers[key];
    if (previous != null) {
      _releaseResumeNotifications(
        key,
        previous,
        _isActiveKey(key) ? state.timeline : const <TimelineEntry>[],
        replay: true,
        snapshotSequence: -1,
      );
    }
    final buffer = ResumeNotificationBuffer(
      threadId: threadId,
      generation: generation,
    );
    _resumeNotificationBuffers[key] = buffer;
    return buffer;
  }

  void _releaseResumeNotifications(
    AgentConnectionKey key,
    ResumeNotificationBuffer buffer,
    List<TimelineEntry> snapshot, {
    required bool replay,
    int snapshotSequence = 0x7fffffffffffffff,
  }) {
    if (!identical(_resumeNotificationBuffers[key], buffer)) return;
    _resumeNotificationBuffers.remove(key);
    if (!replay) return;
    final notifications = buffer.drain(
      snapshot,
      snapshotSequence: snapshotSequence,
    );
    for (final notification in notifications) {
      if (!mounted) return;
      _applyAgentEvent(
        AgentEventEnvelope(
          key: key,
          event: RemoteAgentNotification(notification),
        ),
        publishCompletion: false,
      );
    }
    _cacheActiveThreadSession(key, expectedThreadId: buffer.threadId);
    if (buffer.overflowed && mounted && _isActiveKey(key)) {
      state = state.copyWith(diagnostic: '恢复期间消息过多，已保留完整结果并丢弃部分片段');
    }
  }

  void _cacheActiveThreadSession(
    AgentConnectionKey key, {
    String? expectedThreadId,
  }) {
    if (!mounted || !_isActiveKey(key)) return;
    final activeThread = state.activeThread;
    if (activeThread == null ||
        (expectedThreadId != null && activeThread.id != expectedThreadId)) {
      return;
    }
    final cache = _threadCaches.putIfAbsent(key, ThreadSessionCache.new);
    cache.put(
      activeThread,
      state.timeline,
      nextTurnsCursor: state.olderTurnsCursor,
      tokenUsage: state.tokenUsage,
    );
  }

  Future<void> _hydrateThreadGoal(
    AgentConnectionKey key,
    String threadId,
  ) async {
    try {
      final goal = await _agents.getThreadGoal(key, threadId: threadId);
      final storageKey = threadPreferenceKey(
        key.profileId,
        key.agent,
        threadId,
      );
      if (goal == null) {
        _threadGoals.remove(storageKey);
      } else {
        _threadGoals[storageKey] = goal;
      }
      if (mounted && _isActiveThread(key, threadId)) {
        state = state.copyWith(activeGoal: goal);
      }
    } catch (_) {
      // Goal support was introduced after the core app-server protocol. A
      // missing/older endpoint must not turn a successfully resumed thread
      // into an error screen.
    }
  }

  bool _isActiveThread(AgentConnectionKey key, String threadId) =>
      _isActiveKey(key) && state.activeThread?.id == threadId;

  String _approvalThreadId(String? threadId) => threadId?.trim() ?? '';

  List<ApprovalPrompt> _approvalQueueForScope(
    AgentConnectionKey key,
    String? threadId,
  ) {
    final buckets = _pendingApprovalsByThread[key];
    if (buckets == null) return const <ApprovalPrompt>[];
    final scoped =
        buckets[_approvalThreadId(threadId)] ?? const <ApprovalPrompt>[];
    return List<ApprovalPrompt>.unmodifiable(scoped);
  }

  /// Returns the active thread's approvals and, for older adapters that omit
  /// `threadId`, the lane-level fallback bucket.  Requests with a real thread
  /// id never leak into another thread.
  List<ApprovalPrompt> _approvalQueueFor(
    AgentConnectionKey key,
    String? threadId,
  ) {
    final normalizedThreadId = _approvalThreadId(threadId);
    final scoped = _approvalQueueForScope(key, normalizedThreadId);
    if (normalizedThreadId.isEmpty) return scoped;
    final unscoped = _approvalQueueForScope(key, null);
    if (unscoped.isEmpty) return scoped;
    return List<ApprovalPrompt>.unmodifiable(<ApprovalPrompt>[
      ...scoped,
      ...unscoped,
    ]);
  }

  bool _sameApprovalRequest(ApprovalPrompt left, ApprovalPrompt right) =>
      left.requestId == right.requestId &&
      _approvalThreadId(left.threadId) == _approvalThreadId(right.threadId);

  void _enqueueApproval(AgentConnectionKey key, ApprovalPrompt prompt) {
    final threadId = _approvalThreadId(prompt.threadId);
    final buckets = _pendingApprovalsByThread.putIfAbsent(
      key,
      () => <String, List<ApprovalPrompt>>{},
    );
    final current = buckets[threadId] ?? const <ApprovalPrompt>[];
    buckets[threadId] = List<ApprovalPrompt>.unmodifiable(<ApprovalPrompt>[
      ...current.where((item) => !_sameApprovalRequest(item, prompt)),
      prompt,
    ]);
  }

  void _removeApproval(AgentConnectionKey key, ApprovalPrompt prompt) {
    final buckets = _pendingApprovalsByThread[key];
    if (buckets == null) return;
    final threadId = _approvalThreadId(prompt.threadId);
    final current = buckets[threadId];
    if (current == null) return;
    final remaining = current
        .where((item) => !_sameApprovalRequest(item, prompt))
        .toList(growable: false);
    if (remaining.isEmpty) {
      buckets.remove(threadId);
    } else {
      buckets[threadId] = List<ApprovalPrompt>.unmodifiable(remaining);
    }
    if (buckets.isEmpty) _pendingApprovalsByThread.remove(key);
  }

  ApprovalPrompt _bindApprovalToActiveThread(
    AgentConnectionKey key,
    ApprovalPrompt prompt,
  ) {
    if (_approvalThreadId(prompt.threadId).isNotEmpty || !_isActiveKey(key)) {
      return prompt;
    }
    final activeThreadId = _approvalThreadId(state.activeThread?.id);
    return activeThreadId.isEmpty
        ? prompt
        : prompt.copyWith(threadId: activeThreadId);
  }

  bool _approvalBelongsToActiveThread(
    AgentConnectionKey key,
    ApprovalPrompt prompt,
  ) {
    if (!_isActiveKey(key)) return false;
    final promptThreadId = _approvalThreadId(prompt.threadId);
    final activeThreadId = _approvalThreadId(state.activeThread?.id);
    return promptThreadId.isEmpty ||
        activeThreadId.isEmpty ||
        promptThreadId == activeThreadId;
  }

  void _syncVisibleApprovals(AgentConnectionKey key, {String? threadId}) {
    if (!_isActiveKey(key)) return;
    final queue = _approvalQueueFor(key, threadId ?? state.activeThread?.id);
    state = state.copyWith(approvalQueue: queue, approval: queue.firstOrNull);
  }

  String _subAgentNavigationScope(AgentConnectionKey key) =>
      sessionKey(key.profileId, key.agent);

  int _advanceSessionNavigation(AgentConnectionKey key) {
    final resumeBuffer = _resumeNotificationBuffers[key];
    if (resumeBuffer != null) {
      _releaseResumeNotifications(
        key,
        resumeBuffer,
        _isActiveKey(key) ? state.timeline : const <TimelineEntry>[],
        replay: true,
        snapshotSequence: -1,
      );
    }
    final next = (_sessionNavigationGenerations[key] ?? 0) + 1;
    _sessionNavigationGenerations[key] = next;
    return next;
  }

  bool _isCurrentSessionNavigation(
    AgentConnectionKey key,
    int generation,
    String threadId,
  ) =>
      mounted &&
      (_sessionNavigationGenerations[key] ?? 0) == generation &&
      _isActiveThread(key, threadId);

  bool _isHostAndAgentConnected(AgentConnectionKey key) =>
      _connections.states[key.profileId]?.phase == ConnectionPhase.connected &&
      _agents.states[key]?.phase == ConnectionPhase.connected;

  void _clearSubAgentNavigation(AgentConnectionKey key) {
    _subAgentNavigationStacks.clear(_subAgentNavigationScope(key));
    _advanceSessionNavigation(key);
  }

  void _clearSubAgentNavigationForProfile(String profileId) {
    final keys = <AgentConnectionKey>{
      ..._sessionNavigationGenerations.keys.where(
        (key) => key.profileId == profileId,
      ),
      ..._subAgentNavigationKeysForProfile(profileId),
    };
    for (final key in keys) {
      _clearSubAgentNavigation(key);
    }
  }

  Iterable<AgentConnectionKey> _subAgentNavigationKeysForProfile(
    String profileId,
  ) sync* {
    for (final key in state.agentConnectionStates.keys) {
      if (key.profileId == profileId) yield key;
    }
    for (final key in _threadCaches.keys) {
      if (key.profileId == profileId) yield key;
    }
  }

  void _clearAllSubAgentNavigation() {
    final keys = <AgentConnectionKey>{
      ..._sessionNavigationGenerations.keys,
      ...state.agentConnectionStates.keys,
      ..._threadCaches.keys,
    };
    for (final key in keys) {
      _clearSubAgentNavigation(key);
    }
  }

  void setThreadSearch(String value) {
    if (state.threadSearch == value) return;
    state = state.copyWith(threadSearch: value);
    _threadSearchTimer?.cancel();
    final profileId = state.selectedProfileId;
    if (profileId == null ||
        _connections.states[profileId]?.phase != ConnectionPhase.connected) {
      return;
    }
    final agent = state.activeAgent;
    final key = AgentConnectionKey(profileId: profileId, agent: agent);
    _threadSearchTimer = Timer(const Duration(milliseconds: 350), () async {
      final pending = _agentLoadRequests[key];
      if (pending != null) await pending;
      if (!mounted ||
          state.selectedProfileId != profileId ||
          state.activeAgent != agent ||
          state.threadSearch != value) {
        return;
      }
      await refreshThreads();
    });
  }

  Future<void> _loadAgentData(
    AgentConnectionKey key,
    ServerProfile profile, {
    bool includeModels = false,
    bool runtimePrepared = false,
    bool silent = false,
    bool preserveExistingThreads = false,
  }) {
    final pending = _agentLoadRequests[key];
    if (pending != null) return pending;
    final loadRevision = (_agentLoadRevisions[key] ?? 0) + 1;
    _agentLoadRevisions[key] = loadRevision;
    late final Future<void> request;
    request =
        _performAgentLoad(
          key,
          profile,
          includeModels: includeModels,
          runtimePrepared: runtimePrepared,
          silent: silent,
          preserveExistingThreads: preserveExistingThreads,
          loadRevision: loadRevision,
        ).whenComplete(() {
          if (identical(_agentLoadRequests[key], request)) {
            _agentLoadRequests.remove(key);
          }
        });
    _agentLoadRequests[key] = request;
    return request;
  }

  Future<void> _performAgentLoad(
    AgentConnectionKey key,
    ServerProfile profile, {
    required bool includeModels,
    required bool runtimePrepared,
    required bool silent,
    required bool preserveExistingThreads,
    required int loadRevision,
  }) async {
    if (!_isAgentLoadCurrent(key, loadRevision)) return;
    _agentThreadCursorSearches[key] = '';
    _agentThreadNextCursors[key] = null;
    if (!silent) _setAgentLoading(key, true);
    try {
      final effectiveProfile = runtimePrepared
          ? profile
          : await _prepareRemoteRuntime(key, profile);
      if (effectiveProfile == null || !_isAgentLoadCurrent(key, loadRevision)) {
        return;
      }
      await _agents.connect(effectiveProfile, key.agent);
      if (!_isAgentLoadCurrent(key, loadRevision)) return;
      _showInitialWorkspacePickerIfNeeded(key, effectiveProfile);
      final generation = _agents.generation(key);
      AgentThreadPage? threadPage;
      List<AgentModel>? models;
      Object? threadError;
      Object? modelError;
      await Future.wait<void>([
        () async {
          try {
            threadPage = await _agents.listThreads(
              key,
              searchTerm: _isActiveKey(key) ? state.threadSearch : null,
            );
          } catch (error) {
            threadError = error;
          }
        }(),
        if (includeModels || !state.agentModelLists.containsKey(key))
          () async {
            try {
              models = await _agents.listModels(key);
            } catch (error) {
              modelError = error;
            }
          }(),
      ]);
      if (!_isAgentLoadCurrent(key, loadRevision) ||
          !_agents.isCurrentGeneration(key, generation)) {
        return;
      }

      final threadLists = Map<AgentConnectionKey, List<AgentThread>>.of(
        state.agentThreadLists,
      );
      if (threadPage != null) {
        threadLists[key] = preserveExistingThreads
            ? _mergeListedThreads(
                threadLists[key] ?? const <AgentThread>[],
                threadPage!.threads,
              )
            : threadPage!.threads;
        _agentThreadNextCursors[key] = threadPage!.nextCursor;
        _agentThreadCursorSearches[key] = _isActiveKey(key)
            ? state.threadSearch
            : '';
        _rememberSubAgentReferences(
          key,
          threadPage!.threads,
          const <TimelineEntry>[],
        );
      }
      final modelLists = Map<AgentConnectionKey, List<AgentModel>>.of(
        state.agentModelLists,
      );
      if (models != null) {
        final remoteModels = List<AgentModel>.unmodifiable(models!);
        _remoteModelsByLane[key] = remoteModels;
        final settings = profile.modelSettings(key.agent);
        modelLists[key] = buildModelCatalog(
          remoteModels,
          settings.customModels,
          <String>{
            ...settings.hiddenModelIds,
            ..._pendingManagedModelRemovals(settings),
          },
          customReasoningEfforts: key.agent == AgentKind.openCode
              ? openCodeReasoningEfforts
              : _noModelReasoningEfforts,
        );
      }
      final active = _isActiveKey(key);
      state = state.copyWith(
        agentThreadLists: Map.unmodifiable(threadLists),
        agentModelLists: Map.unmodifiable(modelLists),
        threads: active
            ? threadLists[key] ?? const <AgentThread>[]
            : state.threads,
        models: active ? modelLists[key] ?? const <AgentModel>[] : state.models,
        activeAgentCapabilities: active
            ? _agents.capabilities(key)
            : state.activeAgentCapabilities,
        diagnostic: _agentLoadDiagnostic(threadError, modelError),
      );
      if (!silent && threadError != null && threadPage == null) {
        state = state.copyWith(error: _message(threadError!, '读取会话失败'));
      }
      _scheduleCustomModelSync(key.profileId, key.agent, immediate: true);
    } catch (error) {
      if (_isAgentLoadCurrent(key, loadRevision) && _isActiveKey(key)) {
        final message = _message(error, '${key.agent.label} 连接失败');
        state = silent
            ? state.copyWith(diagnostic: message)
            : state.copyWith(error: message);
      }
    } finally {
      if (!silent && _isAgentLoadCurrent(key, loadRevision)) {
        _setAgentLoading(key, false);
      }
    }
  }

  bool _isAgentLoadCurrent(AgentConnectionKey key, int revision) =>
      mounted &&
      _agentLoadRevisions[key] == revision &&
      _connections.states[key.profileId]?.phase == ConnectionPhase.connected;

  Future<ServerProfile?> _prepareRemoteRuntime(
    AgentConnectionKey key,
    ServerProfile profile,
  ) async {
    if (key.agent == AgentKind.codex &&
        profile.remoteCommand.trim() != managedCodexRemoteCommand) {
      return profile;
    }
    final existingSetup = state.agentSetupStates[key];
    if (existingSetup?.prompt != null) {
      if (_isActiveKey(key)) _showRemoteSetup(key);
      return null;
    }
    final inspection = await _agents.inspectRuntime(profile, key.agent);
    final problem = inspection.installationProblem;
    if (problem != null) throw StateError(problem);
    if (inspection.compatibleCommand != null) return profile;

    final localWindows = isLocalWindowsProfile(profile);
    final detail = inspection.detectedVersion == null
        ? localWindows
              ? '${key.agent.label} 尚未安装，将在当前 Windows 用户目录安装。'
              : '${key.agent.label} 尚未安装，将在当前 SSH 用户目录安装。'
        : '${key.agent.label} 检测到 ${inspection.detectedVersion}，需要安装兼容版本。';
    final prompt = RemoteSetupPrompt(
      title: localWindows
          ? '安装 Windows 原生 ${key.agent.label}'
          : '安装远程 ${key.agent.label}',
      detail: detail,
      os: inspection.os,
      architecture: inspection.architecture,
      home: inspection.home,
      detectedVersion: inspection.detectedVersion,
      agent: key.agent,
    );
    _setupProfiles[key] = profile;
    _updateSetupState(key, (current) => current.copyWith(prompt: prompt));
    if (_isActiveKey(key)) _showRemoteSetup(key);
    return null;
  }

  void _setAgentLoading(AgentConnectionKey key, bool loading) {
    final values = Map<AgentConnectionKey, bool>.of(state.agentLoadingStates);
    // Keep the completed state observable so callers can distinguish an idle
    // lane from one that has never finished its initial load.
    values[key] = loading;
    state = state.copyWith(
      agentLoadingStates: Map.unmodifiable(values),
      loading: _isActiveKey(key) ? loading : state.loading,
    );
  }

  void _clearAgentThreadPagination(AgentConnectionKey key) {
    _agentThreadNextCursors.remove(key);
    _agentThreadCursorSearches.remove(key);
    _agentThreadPageRequests.remove(key);
  }

  void _clearAgentThreadPaginationForProfile(String profileId) {
    _agentThreadNextCursors.removeWhere((key, _) => key.profileId == profileId);
    _agentThreadCursorSearches.removeWhere(
      (key, _) => key.profileId == profileId,
    );
    _agentThreadPageRequests.removeWhere(
      (key, _) => key.profileId == profileId,
    );
  }

  void _updateSetupState(
    AgentConnectionKey key,
    AgentSetupState Function(AgentSetupState current) update,
  ) {
    if (!mounted) return;
    final next = update(state.agentSetupStates[key] ?? const AgentSetupState());
    final visible =
        state.selectedProfileId == key.profileId &&
        state.remoteSetup?.agent == key.agent &&
        !next.minimized;
    state = state.copyWith(
      agentSetupStates: Map.unmodifiable({
        ...state.agentSetupStates,
        key: next,
      }),
      remoteSetup: visible ? next.prompt : state.remoteSetup,
      setupInProgress: visible ? next.inProgress : state.setupInProgress,
      setupProgress: visible ? next.progress : state.setupProgress,
      setupProgressPercent: visible ? next.percent : state.setupProgressPercent,
      setupProgressDetail: visible ? next.detail : state.setupProgressDetail,
      setupDownloadPercent: visible
          ? next.downloadPercent
          : state.setupDownloadPercent,
      setupDownloadedBytes: visible
          ? next.downloadedBytes
          : state.setupDownloadedBytes,
      setupTotalBytes: visible ? next.totalBytes : state.setupTotalBytes,
      setupBytesPerSecond: visible
          ? next.bytesPerSecond
          : state.setupBytesPerSecond,
      setupElapsedSeconds: visible
          ? next.elapsedSeconds
          : state.setupElapsedSeconds,
      setupProgressIndeterminate: visible
          ? next.progressIndeterminate
          : state.setupProgressIndeterminate,
    );
  }

  void _showRemoteSetup(AgentConnectionKey key) {
    final setup = state.agentSetupStates[key];
    final prompt = setup?.prompt;
    if (setup == null ||
        prompt == null ||
        state.selectedProfileId != key.profileId ||
        state.activeAgent != key.agent) {
      return;
    }
    final visible = setup.copyWith(minimized: false);
    state = state.copyWith(
      remoteSetup: prompt,
      setupInProgress: visible.inProgress,
      setupProgress: visible.progress,
      setupProgressPercent: visible.percent,
      setupProgressDetail: visible.detail,
      setupDownloadPercent: visible.downloadPercent,
      setupDownloadedBytes: visible.downloadedBytes,
      setupTotalBytes: visible.totalBytes,
      setupBytesPerSecond: visible.bytesPerSecond,
      setupElapsedSeconds: visible.elapsedSeconds,
      setupProgressIndeterminate: visible.progressIndeterminate,
      agentSetupStates: Map.unmodifiable({
        ...state.agentSetupStates,
        key: visible,
      }),
      loading: false,
    );
  }

  void _removeSetupState(AgentConnectionKey key) {
    _setupProfiles.remove(key);
    final states = Map<AgentConnectionKey, AgentSetupState>.of(
      state.agentSetupStates,
    )..remove(key);
    final visible =
        state.selectedProfileId == key.profileId &&
        state.remoteSetup?.agent == key.agent;
    state = state.copyWith(
      agentSetupStates: Map.unmodifiable(states),
      remoteSetup: visible ? null : state.remoteSetup,
      setupInProgress: visible ? false : state.setupInProgress,
      setupProgress: visible ? '' : state.setupProgress,
      setupProgressPercent: visible ? 0 : state.setupProgressPercent,
      setupProgressDetail: visible ? '' : state.setupProgressDetail,
      setupDownloadPercent: visible ? null : state.setupDownloadPercent,
      setupDownloadedBytes: visible ? null : state.setupDownloadedBytes,
      setupTotalBytes: visible ? null : state.setupTotalBytes,
      setupBytesPerSecond: visible ? null : state.setupBytesPerSecond,
      setupElapsedSeconds: visible ? null : state.setupElapsedSeconds,
      setupProgressIndeterminate: visible
          ? false
          : state.setupProgressIndeterminate,
    );
  }

  void _clearSetupStates(String profileId) {
    _setupProfiles.removeWhere((key, _) => key.profileId == profileId);
    final states = Map<AgentConnectionKey, AgentSetupState>.of(
      state.agentSetupStates,
    )..removeWhere((key, _) => key.profileId == profileId);
    final visible =
        state.selectedProfileId == profileId && state.remoteSetup != null;
    state = state.copyWith(
      agentSetupStates: Map.unmodifiable(states),
      remoteSetup: visible ? null : state.remoteSetup,
      setupInProgress: visible ? false : state.setupInProgress,
      setupProgress: visible ? '' : state.setupProgress,
      setupProgressPercent: visible ? 0 : state.setupProgressPercent,
      setupProgressDetail: visible ? '' : state.setupProgressDetail,
      setupDownloadPercent: visible ? null : state.setupDownloadPercent,
      setupDownloadedBytes: visible ? null : state.setupDownloadedBytes,
      setupTotalBytes: visible ? null : state.setupTotalBytes,
      setupBytesPerSecond: visible ? null : state.setupBytesPerSecond,
      setupElapsedSeconds: visible ? null : state.setupElapsedSeconds,
      setupProgressIndeterminate: visible
          ? false
          : state.setupProgressIndeterminate,
    );
  }

  bool _isCurrentSetupProfile(AgentConnectionKey key, ServerProfile profile) {
    final setupProfile = _setupProfiles[key];
    final current = state.profiles.firstWhereOrNull(
      (candidate) => candidate.id == key.profileId,
    );
    return setupProfile != null &&
        current != null &&
        setupProfile.hasSameConnectionIdentity(profile) &&
        current.hasSameConnectionIdentity(profile) &&
        setupProfile.proxyUrl == profile.proxyUrl &&
        current.proxyUrl == profile.proxyUrl;
  }

  bool _isActiveKey(AgentConnectionKey key) =>
      state.selectedProfileId == key.profileId &&
      state.activeAgent == key.agent;

  bool _isAgentSettingsRequestCurrent(
    int requestId,
    ServerProfile profile,
    AgentKind agent,
    int generation,
  ) {
    if (!mounted ||
        requestId != _agentSettingsRequestId ||
        !state.agentSettingsVisible ||
        _agentSettingsProfileId != profile.id ||
        _agentSettingsAgent != agent ||
        state.selectedProfileId != profile.id ||
        state.activeAgent != agent) {
      return false;
    }
    final current = state.profiles.firstWhereOrNull(
      (candidate) => candidate.id == profile.id,
    );
    final key = AgentConnectionKey(profileId: profile.id, agent: agent);
    return current != null &&
        current.hasSameConnectionIdentity(profile) &&
        _agents.generation(key) == generation &&
        _agents.states[key]?.phase == ConnectionPhase.connected;
  }

  void _closeAgentSettings() {
    _agentSettingsRequestId++;
    _agentSettingsProfileId = null;
    _agentSettingsAgent = null;
    state = state.copyWith(
      agentSettingsVisible: false,
      agentSettingsLoading: false,
      agentSettingsSaving: false,
      agentSettingsTesting: false,
      agentSettings: null,
      agentSettingsTestResult: null,
      agentSettingsError: null,
    );
  }

  Future<void> _updateProfileAgentDefaults({
    required String profileId,
    required AgentKind agent,
    required String defaultModel,
    required String defaultEffort,
    required String testModel,
  }) async {
    final profiles = state.profiles
        .map((profile) {
          if (profile.id != profileId) return profile;
          return profile.withModelSettings(
            agent,
            profile
                .modelSettings(agent)
                .copyWith(
                  preferredModel: defaultModel,
                  preferredEffort: defaultEffort,
                  testModel: testModel,
                ),
          );
        })
        .toList(growable: false);
    state = state.copyWith(profiles: profiles);
    await _persist(
      (stored) => stored.copyWith(
        profiles: stored.profiles
            .map((profile) {
              if (profile.id != profileId) return profile;
              return profile.withModelSettings(
                agent,
                profile
                    .modelSettings(agent)
                    .copyWith(
                      preferredModel: defaultModel,
                      preferredEffort: defaultEffort,
                      testModel: testModel,
                    ),
              );
            })
            .toList(growable: false),
      ),
    );
  }

  Future<void> _restartAgentAfterSettingsSave(
    AgentConnectionKey key,
    ServerProfile profile, {
    required bool preserveExistingThreads,
  }) async {
    _diagnostics.info(
      'AgentSettings',
      'restart_requested profile=${key.profileId} agent=${key.agent.name}',
    );
    _agentLoadRevisions[key] = (_agentLoadRevisions[key] ?? 0) + 1;
    _agentLoadRequests.remove(key);
    if (!preserveExistingThreads) {
      // A Provider switch changes the server's thread namespace. Do not let a
      // stale transcript be used when the new Provider reuses a thread ID.
      _threadCaches[key]?.clear();
    }
    final retained = _retainedAgentConnections.remove(key);
    try {
      await _agents.disconnect(key.profileId, agent: key.agent);
      if (!mounted ||
          _connections.states[key.profileId]?.phase !=
              ConnectionPhase.connected) {
        return;
      }
      if (retained && _retainedHostConnections.contains(key.profileId)) {
        _retainedAgentConnections.add(key);
      }
      await _agents.connect(profile, key.agent);
      // Reconnecting after a global settings update must not discard older
      // pages already visible in the lane while the server is reloading.
      await _loadAgentData(
        key,
        profile,
        includeModels: true,
        silent: true,
        preserveExistingThreads: preserveExistingThreads,
      );
    } finally {
      if (retained &&
          mounted &&
          _retainedHostConnections.contains(key.profileId)) {
        _retainedAgentConnections.add(key);
        if (_connectionNeedsRecovery(key.profileId)) {
          _scheduleConnectionRecovery(
            key.profileId,
            source: 'agent_settings_restart',
          );
        }
      }
    }
  }

  void backToServers() {
    _clearAllSubAgentNavigation();
    _workspaceRequestId++;
    _invalidateFileManagerRequests();
    if (state.agentSettingsVisible) _closeAgentSettings();
    state = _resetFileManagerState(
      state.copyWith(
        screen: AppScreen.servers,
        workspacePickerVisible: false,
        workspaceLoading: false,
        workspaceError: null,
      ),
      screen: AppScreen.servers,
    );
  }

  void enableDebugMode() {
    state = state.copyWith(debugModeEnabled: true);
    unawaited(_setDiagnosticMode(true));
  }

  void disableDebugMode() {
    state = state.copyWith(debugModeEnabled: false);
    unawaited(_setDiagnosticMode(false));
  }

  DiagnosticLogger get diagnosticLogger => _diagnostics;

  Future<void> _syncDiagnosticMode() async {
    try {
      final enabled = await _diagnostics.initialize();
      if (mounted && enabled && !state.debugModeEnabled) {
        state = state.copyWith(debugModeEnabled: true);
      }
    } catch (_) {
      // Diagnostics are optional and must never block normal app startup.
    }
  }

  Future<void> _setDiagnosticMode(bool enabled) async {
    try {
      await _diagnostics.setEnabled(enabled);
    } catch (error, stack) {
      _diagnostics.recordError(
        error,
        stack,
        tag: 'Debug',
        message: 'diagnostic_mode_change_failed',
      );
    }
  }

  void clearError() {
    if (state.error != null) state = state.copyWith(error: null);
  }

  void _invalidateConnectionRecovery(String profileId) {
    _connectionRecoveryRevisions[profileId] =
        (_connectionRecoveryRevisions[profileId] ?? 0) + 1;
  }

  void _forgetRetainedConnection(String profileId) {
    _retainedHostConnections.remove(profileId);
    _retainedAgentConnections.removeWhere((key) => key.profileId == profileId);
    _invalidateConnectionRecovery(profileId);
  }

  bool _isConnectionRecoveryCurrent(String profileId, int revision) =>
      mounted &&
      _retainedHostConnections.contains(profileId) &&
      (_connectionRecoveryRevisions[profileId] ?? 0) == revision;

  void _scheduleConnectionRecovery(String profileId, {required String source}) {
    if (!_retainedHostConnections.contains(profileId) ||
        _connectionRecoveryRequests.containsKey(profileId)) {
      return;
    }
    final revision = _connectionRecoveryRevisions[profileId] ?? 0;
    _diagnostics.info(
      'SSH',
      'reconnect_scheduled profile=$profileId source=$source',
    );
    _showConnectionRecoveryPending(profileId, attempt: 1);
    late final Future<void> request;
    request = _recoverConnection(profileId, revision).whenComplete(() {
      if (identical(_connectionRecoveryRequests[profileId], request)) {
        _connectionRecoveryRequests.remove(profileId);
        if (_connectionNeedsRecovery(profileId)) {
          _scheduleConnectionRecovery(profileId, source: 'recovery_completion');
        }
      }
    });
    _connectionRecoveryRequests[profileId] = request;
  }

  Future<void> _recoverConnection(String profileId, int revision) async {
    var attempt = 0;
    while (_isConnectionRecoveryCurrent(profileId, revision)) {
      final delay = _reconnectDelay(attempt);
      // Always yield once so a synchronous host -> Agent state cascade can
      // finish publishing its disconnected snapshot before reconnect emits.
      await Future<void>.delayed(delay);
      if (!_isConnectionRecoveryCurrent(profileId, revision)) return;
      var profile = state.profiles.firstWhereOrNull(
        (candidate) => candidate.id == profileId,
      );
      if (profile == null) {
        _forgetRetainedConnection(profileId);
        return;
      }

      attempt++;
      _showConnectionRecoveryPending(profileId, attempt: attempt);
      _diagnostics.info(
        'SSH',
        'reconnect_attempt profile=$profileId attempt=$attempt',
      );
      try {
        if (isLocalLinuxProfile(profile)) {
          final instance = await _localLinuxRuntime.ensureStarted();
          final refreshed = localLinuxProfile(instance, existing: profile);
          if (!profile.hasSameConnectionIdentity(refreshed)) {
            profile = await _saveLocalLinuxProfile(refreshed);
          }
          if (!_isConnectionRecoveryCurrent(profileId, revision)) return;
        }
        await _connections.connect(profile);
        if (!_isConnectionRecoveryCurrent(profileId, revision)) return;

        final agentKeys = _retainedAgentConnections
            .where((key) => key.profileId == profileId)
            .toList(growable: false);
        for (final key in agentKeys) {
          await _agents.connect(profile, key.agent);
          if (!_isConnectionRecoveryCurrent(profileId, revision)) return;
        }
        await _restoreActiveConnectionView(profile, agentKeys);
        if (!_isConnectionRecoveryCurrent(profileId, revision)) return;
        if (_connections.states[profileId]?.phase !=
                ConnectionPhase.connected ||
            agentKeys.any(
              (key) => _agents.states[key]?.phase != ConnectionPhase.connected,
            )) {
          throw StateError('恢复期间连接再次断开');
        }
        _diagnostics.info(
          'SSH',
          'reconnect_success profile=$profileId attempt=$attempt '
              'agents=${agentKeys.length}',
        );
        return;
      } catch (error, stack) {
        if (!_isConnectionRecoveryCurrent(profileId, revision)) return;
        _diagnostics.warn(
          'SSH',
          'reconnect_failed profile=$profileId attempt=$attempt',
          error,
          stack,
        );
        _showConnectionRecoveryPending(profileId, attempt: attempt + 1);
      }
    }
  }

  bool _connectionNeedsRecovery(String profileId) {
    if (!mounted || !_retainedHostConnections.contains(profileId)) return false;
    final hostPhase = _connections.states[profileId]?.phase;
    if (hostPhase == ConnectionPhase.disconnected ||
        hostPhase == ConnectionPhase.failed) {
      return true;
    }
    if (hostPhase != ConnectionPhase.connected) return false;
    return _retainedAgentConnections
        .where((key) => key.profileId == profileId)
        .any(
          (key) =>
              _agents.states[key]?.phase == ConnectionPhase.disconnected ||
              _agents.states[key]?.phase == ConnectionPhase.failed,
        );
  }

  Duration _reconnectDelay(int attempt) {
    if (_reconnectDelays.isEmpty) return const Duration(seconds: 30);
    final index = attempt < _reconnectDelays.length
        ? attempt
        : _reconnectDelays.length - 1;
    return _reconnectDelays[index];
  }

  void _showConnectionRecoveryPending(
    String profileId, {
    required int attempt,
  }) {
    if (!mounted || !_retainedHostConnections.contains(profileId)) return;
    if (_connections.states[profileId]?.phase == ConnectionPhase.connected) {
      return;
    }
    final reconnecting = ConnectionState(
      phase: ConnectionPhase.connecting,
      message: 'SSH 意外断开，正在重连（第 $attempt 次）',
    );
    final connections = Map<String, ConnectionState>.of(state.connectionStates)
      ..[profileId] = reconnecting;
    state = state.copyWith(
      connectionStates: Map.unmodifiable(connections),
      connection: state.selectedProfileId == profileId
          ? reconnecting
          : state.connection,
    );
  }

  Future<void> _restoreActiveConnectionView(
    ServerProfile profile,
    List<AgentConnectionKey> restoredAgents,
  ) async {
    if (!mounted || state.selectedProfileId != profile.id) return;
    final key = AgentConnectionKey(
      profileId: profile.id,
      agent: state.activeAgent,
    );
    if (!restoredAgents.contains(key) ||
        _agents.states[key]?.phase != ConnectionPhase.connected) {
      return;
    }
    final thread = state.activeThread;
    final targetScreen = state.screen;
    if (thread != null &&
        (targetScreen == AppScreen.work ||
            targetScreen == AppScreen.agentWork)) {
      final requestKey = threadPreferenceKey(profile.id, key.agent, thread.id);
      final snapshot = _SessionSnapshot.capture(state);
      final generation = _advanceSessionNavigation(key);
      final accepted = await _openThreadInternal(
        thread: thread,
        targetScreen: targetScreen,
        agentName: state.activeAgentName,
        navigationGeneration: generation,
        requestKey: requestKey,
        initialSnapshot: snapshot,
        subAgentBackNavigation: state.subAgentBackNavigation,
      );
      if (accepted) await _threadOpenRequests[requestKey]?.future;
      return;
    }
    // The thread list already owns a lane-scoped cache. Connection recovery
    // must not replace it with a full-screen loading state or issue an
    // automatic thread/list request merely because Android resumed the app.
    // A process restart or an interrupted first load has no cache and still
    // needs the normal initial request.
    if (targetScreen == AppScreen.threads &&
        !state.agentThreadLists.containsKey(key)) {
      await _loadAgentData(
        key,
        profile,
        includeModels: false,
        runtimePrepared: true,
      );
    }
  }

  void _applyConnectionStates(Map<String, ConnectionState> connections) {
    if (!mounted) return;
    final recoverProfiles = <String>{};
    for (final profileId in <String>{
      ...state.connectionStates.keys,
      ...connections.keys,
    }) {
      final previous = state.connectionStates[profileId]?.phase;
      final nextState = connections[profileId];
      final next = nextState?.phase;
      if (previous != next) {
        final detail = nextState?.message.trim();
        _diagnostics.info(
          'SSH',
          'state profile=$profileId from=${previous?.name ?? 'none'} '
              'to=${next?.name ?? 'none'}'
              '${detail == null || detail.isEmpty ? '' : ' detail=$detail'}',
        );
      }
      if (_retainedHostConnections.contains(profileId) &&
          (next == ConnectionPhase.disconnected ||
              next == ConnectionPhase.failed) &&
          previous != next) {
        recoverProfiles.add(profileId);
      }
    }
    final selected = state.selectedProfileId;
    final loadingStates = Map<AgentConnectionKey, bool>.of(
      state.agentLoadingStates,
    );
    var activeAgentLoadInvalidated = false;
    final invalidLoads =
        <AgentConnectionKey>{
          ..._agentLoadRequests.keys,
          ...loadingStates.entries
              .where((entry) => entry.value)
              .map((entry) => entry.key),
        }.where(
          (key) =>
              connections[key.profileId]?.phase != ConnectionPhase.connected,
        );
    for (final key in invalidLoads) {
      _agentLoadRevisions[key] = (_agentLoadRevisions[key] ?? 0) + 1;
      _agentLoadRequests.remove(key);
      loadingStates[key] = false;
      if (key.profileId == selected && key.agent == state.activeAgent) {
        activeAgentLoadInvalidated = true;
      }
    }
    final settingsDisconnected =
        state.agentSettingsVisible &&
        selected != null &&
        connections[selected]?.phase != ConnectionPhase.connected;
    final workspaceDisconnected =
        state.workspacePickerVisible &&
        selected != null &&
        connections[selected]?.phase != ConnectionPhase.connected;
    final fileManagerDisconnected =
        state.screen == AppScreen.fileManager &&
        state.fileManagerProfileId != null &&
        connections[state.fileManagerProfileId]?.phase !=
            ConnectionPhase.connected;
    if (settingsDisconnected) _closeAgentSettings();
    if (workspaceDisconnected) _workspaceRequestId++;
    if (fileManagerDisconnected) _invalidateFileManagerRequests();
    state = state.copyWith(
      connectionStates: connections,
      connection: selected == null
          ? const ConnectionState()
          : connections[selected] ?? const ConnectionState(),
      agentLoadingStates: Map.unmodifiable(loadingStates),
      loading: activeAgentLoadInvalidated ? false : state.loading,
      serverMetrics: _connectedServerMetrics(
        state.serverMetrics,
        connections,
        _retainedHostConnections,
      ),
      workspacePickerVisible: workspaceDisconnected
          ? false
          : state.workspacePickerVisible,
      workspaceLoading: workspaceDisconnected ? false : state.workspaceLoading,
      workspaceError: workspaceDisconnected ? null : state.workspaceError,
    );
    if (fileManagerDisconnected) {
      state = _resetFileManagerState(state, screen: AppScreen.servers);
    }
    for (final profileId in recoverProfiles) {
      _scheduleConnectionRecovery(profileId, source: 'ssh_state');
    }
  }

  void _applyServerMetrics(Map<String, ServerMetrics> metrics) {
    if (!mounted) return;
    state = state.copyWith(
      serverMetrics: _connectedServerMetrics(
        metrics,
        _connections.states,
        _retainedHostConnections,
      ),
    );
  }

  void _applyAgentConnectionStates(
    Map<AgentConnectionKey, ConnectionState> connections,
  ) {
    if (!mounted) return;
    final previousConnections = state.agentConnectionStates;
    final profileId = state.selectedProfileId;
    final activeKey = profileId == null
        ? null
        : AgentConnectionKey(profileId: profileId, agent: state.activeAgent);
    var clearVisibleApprovals = false;
    final recoverProfiles = <String>{};
    for (final key in <AgentConnectionKey>{
      ...previousConnections.keys,
      ...connections.keys,
    }) {
      final previousPhase = previousConnections[key]?.phase;
      final nextPhase = connections[key]?.phase;
      if (previousPhase == nextPhase) continue;
      _diagnostics.info(
        'Agent',
        'state profile=${key.profileId} agent=${key.agent.name} '
            'from=${previousPhase?.name ?? 'none'} to=${nextPhase?.name ?? 'none'}',
      );
      if (nextPhase == ConnectionPhase.connected &&
          _retainedHostConnections.contains(key.profileId)) {
        _retainedAgentConnections.add(key);
      }
      final recoverableLoss =
          _retainedHostConnections.contains(key.profileId) &&
          _retainedAgentConnections.contains(key) &&
          (nextPhase == ConnectionPhase.disconnected ||
              nextPhase == ConnectionPhase.failed);
      if (previousPhase == ConnectionPhase.connected &&
          nextPhase != ConnectionPhase.connected &&
          !recoverableLoss) {
        _clearSubAgentNavigation(key);
      }
      if (recoverableLoss) recoverProfiles.add(key.profileId);
      if (nextPhase != ConnectionPhase.connected &&
          _pendingApprovalsByThread.remove(key) != null &&
          key == activeKey) {
        clearVisibleApprovals = true;
      }
    }
    final workspaceDisconnected =
        state.workspacePickerVisible &&
        activeKey != null &&
        connections[activeKey]?.phase != ConnectionPhase.connected;
    final settingsDisconnected =
        state.agentSettingsVisible &&
        activeKey != null &&
        connections[activeKey]?.phase != ConnectionPhase.connected;
    if (settingsDisconnected) _closeAgentSettings();
    if (workspaceDisconnected) _workspaceRequestId++;
    state = state.copyWith(
      agentConnectionStates: connections,
      activeAgentCapabilities:
          activeKey != null &&
              connections[activeKey]?.phase == ConnectionPhase.connected
          ? _agents.capabilities(activeKey)
          : AgentCapabilities.none,
      approvalQueue: clearVisibleApprovals
          ? const <ApprovalPrompt>[]
          : state.approvalQueue,
      approval: clearVisibleApprovals ? null : state.approval,
      workspacePickerVisible: workspaceDisconnected
          ? false
          : state.workspacePickerVisible,
      workspaceLoading: workspaceDisconnected ? false : state.workspaceLoading,
      workspaceError: workspaceDisconnected ? null : state.workspaceError,
    );
    for (final profileId in recoverProfiles) {
      _scheduleConnectionRecovery(profileId, source: 'agent_state');
    }
  }

  void _applyAgentEvent(
    AgentEventEnvelope envelope, {
    bool publishCompletion = true,
  }) {
    if (!mounted) return;
    final active = _isActiveKey(envelope.key);
    switch (envelope.event) {
      case RemoteAgentDiagnostic(
        :final message,
        :final isStderr,
        :final isTransport,
      ):
        if (isTransport) {
          _diagnostics.info(
            'AgentTransport',
            'profile=${envelope.key.profileId} '
                'agent=${envelope.key.agent.name} detail=$message',
          );
        } else if (isStderr) {
          _diagnostics.info(
            'AgentStderr',
            'profile=${envelope.key.profileId} '
                'agent=${envelope.key.agent.name} detail=$message',
          );
        } else if (active) {
          state = state.copyWith(diagnostic: message);
        }
      case RemoteAgentConnectionLost(:final message):
        _diagnostics.info(
          'Agent',
          'connection_lost profile=${envelope.key.profileId} '
              'agent=${envelope.key.agent.name} detail=$message',
        );
        final resumeBuffer = _resumeNotificationBuffers[envelope.key];
        if (resumeBuffer != null) {
          _releaseResumeNotifications(
            envelope.key,
            resumeBuffer,
            active && state.activeThread?.id == resumeBuffer.threadId
                ? state.timeline
                : const <TimelineEntry>[],
            replay: true,
            snapshotSequence: -1,
          );
        }
        final recoverable =
            _retainedHostConnections.contains(envelope.key.profileId) &&
            _retainedAgentConnections.contains(envelope.key);
        if (recoverable) {
          _scheduleConnectionRecovery(
            envelope.key.profileId,
            source: 'agent_event',
          );
        } else {
          _clearSubAgentNavigation(envelope.key);
        }
        _pendingApprovalsByThread.remove(envelope.key);
        if (active) {
          state = state.copyWith(
            diagnostic: message,
            approvalQueue: const <ApprovalPrompt>[],
            approval: null,
          );
        }
      case RemoteAgentNotification(:final message):
        final before = state;
        final routedMessage = _withResolvedNotificationThreadId(message);
        _rememberSubAgentReferences(
          envelope.key,
          before.agentThreadLists[envelope.key] ?? const <AgentThread>[],
          before.activeThread != null && _isActiveKey(envelope.key)
              ? before.timeline
              : const <TimelineEntry>[],
        );
        final resumeBuffer = _resumeNotificationBuffers[envelope.key];
        final buffered = resumeBuffer?.offer(routedMessage) ?? false;
        if (publishCompletion) {
          _publishTurnCompletionIfNeeded(envelope.key, routedMessage, before);
        }
        _applyChildSubAgentCompletion(envelope.key, routedMessage);
        if (buffered) return;
        if (!_notificationTargetsVisibleThread(envelope.key, routedMessage)) {
          _applyBackgroundAgentNotification(envelope.key, routedMessage);
          return;
        }
        final reduced = reduceCodexNotification(state, routedMessage);
        if (identical(before, reduced)) return;
        final lists = Map<AgentConnectionKey, List<AgentThread>>.of(
          state.agentThreadLists,
        );
        if (reduced.threads != before.threads) {
          lists[envelope.key] = reduced.threads;
        }
        state = reduced.copyWith(
          agentThreadLists: Map.unmodifiable(lists),
          threads: _isActiveKey(envelope.key) ? reduced.threads : state.threads,
          submitting: reduced.running ? false : reduced.submitting,
        );
        final activeThread = state.activeThread;
        if (activeThread != null &&
            (routedMessage.method == 'thread/goal/updated' ||
                routedMessage.method == 'thread/goal/cleared')) {
          final storageKey = threadPreferenceKey(
            envelope.key.profileId,
            envelope.key.agent,
            activeThread.id,
          );
          final goal = state.activeGoal;
          if (goal == null) {
            _threadGoals.remove(storageKey);
          } else {
            _threadGoals[storageKey] = goal;
          }
        }
        if (activeThread != null &&
            (reduced.timeline != before.timeline ||
                reduced.activeThread != before.activeThread ||
                reduced.activeTurnId != before.activeTurnId ||
                reduced.running != before.running ||
                reduced.tokenUsage != before.tokenUsage)) {
          final cache = _threadCaches.putIfAbsent(
            envelope.key,
            ThreadSessionCache.new,
          );
          cache.put(
            activeThread,
            state.timeline,
            nextTurnsCursor: state.olderTurnsCursor,
            tokenUsage: state.tokenUsage,
          );
        }
        if (routedMessage.method == 'turn/started' ||
            routedMessage.method == 'turn/completed' ||
            routedMessage.method == 'thread/status/changed' ||
            isTerminalAgentMessageNotification(routedMessage)) {
          final timing = state.turnTiming;
          if (timing != null) {
            unawaited(
              _persist(
                (stored) => stored.copyWith(
                  completedTurnTimings: {
                    ...stored.completedTurnTimings,
                    threadPreferenceKey(
                      envelope.key.profileId,
                      envelope.key.agent,
                      timing.threadId,
                    ): timing,
                  },
                ),
              ),
            );
          }
        }
      case RemoteAgentServerRequest(:final message):
        final parsedPrompt = _approvalPromptFromRequest(message);
        if (parsedPrompt == null) {
          if (active) {
            state = state.copyWith(
              diagnostic: '${envelope.key.agent.label} 请求了移动端暂不支持的操作',
            );
          }
          return;
        }
        final prompt = _bindApprovalToActiveThread(envelope.key, parsedPrompt);
        _enqueueApproval(envelope.key, prompt);
        if (_approvalBelongsToActiveThread(envelope.key, prompt)) {
          _syncVisibleApprovals(envelope.key, threadId: state.activeThread?.id);
        }
    }
  }

  void _publishTurnCompletionIfNeeded(
    AgentConnectionKey key,
    CodexRpcNotification message,
    AppUiState before,
  ) {
    if (!_isCompletionNotification(message)) return;
    final params = message.params;
    final turn = _notificationMap(params['turn']);
    final threadObject = _notificationMap(params['thread']);
    final threadId =
        _notificationString(params, const ['threadId', 'thread_id'])
            .ifEmpty(
              () => _notificationString(turn, const ['threadId', 'thread_id']),
            )
            .ifEmpty(
              () => _notificationString(threadObject, const [
                'id',
                'threadId',
                'thread_id',
              ]),
            );
    if (threadId.isEmpty) return;

    final listedThread = before.agentThreadLists[key]?.firstWhereOrNull(
      (thread) => thread.id == threadId,
    );
    final activeCandidate = before.activeThread;
    final activeThread = _isActiveKey(key) && activeCandidate?.id == threadId
        ? activeCandidate
        : null;
    final thread = listedThread ?? activeThread;
    final source = thread?.source.isNotEmpty == true
        ? thread!.source
        : _notificationString(threadObject, const ['source']);
    if (isSubAgentThreadSource(source) ||
        _subAgentThreadRegistry.contains(key, threadId)) {
      return;
    }

    final profile = before.profiles.firstWhereOrNull(
      (candidate) => candidate.id == key.profileId,
    );
    if (profile == null) return;
    final listedTurnId = thread?.activeTurnId ?? '';
    final turnId = _notificationString(turn, const ['id', 'turnId', 'turn_id'])
        .ifEmpty(() => _notificationString(params, const ['turnId', 'turn_id']))
        .ifEmpty(() => listedTurnId)
        .ifEmpty(() => _isActiveKey(key) ? before.activeTurnId ?? '' : '');
    final completion = TurnCompletion(
      profileId: key.profileId,
      agent: key.agent,
      profileName: profile.name.trim().isEmpty ? profile.host : profile.name,
      threadId: threadId,
      turnId: turnId,
      threadTitle:
          thread?.title ??
          _notificationString(threadObject, const ['title', 'name']),
      threadPreview: thread?.preview ?? '',
    );
    if (_turnCompletionDeduplicator.shouldPublish(completion) &&
        !_turnCompletionController.isClosed) {
      _turnCompletionController.add(completion);
    }
  }

  void _rememberSubAgentReferences(
    AgentConnectionKey key,
    List<AgentThread> threads,
    List<TimelineEntry> timeline,
  ) {
    for (final thread in threads) {
      if (isSubAgentThreadSource(thread.source)) {
        _subAgentThreadRegistry.remember(key, thread.id);
      }
    }
    for (final entry in timeline) {
      if (entry.subAgentThreadId.isNotEmpty) {
        _subAgentThreadRegistry.remember(key, entry.subAgentThreadId);
      }
    }
  }

  void _applyBackgroundAgentNotification(
    AgentConnectionKey key,
    CodexRpcNotification message,
  ) {
    final laneThreads = state.agentThreadLists[key] ?? const <AgentThread>[];
    final threadId = _notificationThreadId(message);
    if (threadId.isEmpty) return;
    final cache = _threadCaches[key];
    final cached = cache?.getStale(threadId);
    final listedThread = laneThreads.firstWhereOrNull(
      (thread) => thread.id == threadId,
    );
    final seedThread = cached?.thread ?? listedThread;
    if (seedThread == null) return;
    final base = AppUiState(
      // Supplying a work surface makes the pure reducer apply timeline and
      // token updates to the cached thread while leaving the visible lane
      // state untouched below.
      screen: AppScreen.work,
      threads: laneThreads,
      activeThread: seedThread,
      timeline: cached?.timeline ?? const <TimelineEntry>[],
      olderTurnsCursor: cached?.nextTurnsCursor,
      activeTurnId: seedThread.activeTurnId,
      running: _threadIsRunning(seedThread),
      tokenUsage: cache?.contextUsage(threadId) ?? cached?.tokenUsage,
    );
    final reduced = reduceCodexNotification(base, message);
    final changedThreads = !identical(reduced.threads, laneThreads);
    final changedSession =
        reduced.activeThread != base.activeThread ||
        !identical(reduced.timeline, base.timeline) ||
        reduced.olderTurnsCursor != base.olderTurnsCursor ||
        reduced.tokenUsage != base.tokenUsage;
    final goalEvent =
        message.method == 'thread/goal/updated' ||
        message.method == 'thread/goal/cleared';
    if (!changedThreads && !changedSession && !goalEvent) return;
    final reducedThread =
        reduced.activeThread ??
        reduced.threads.firstWhereOrNull((thread) => thread.id == threadId);
    if (changedThreads) {
      final lists = Map<AgentConnectionKey, List<AgentThread>>.of(
        state.agentThreadLists,
      )..[key] = reduced.threads;
      state = state.copyWith(
        agentThreadLists: Map.unmodifiable(lists),
        threads: _isActiveKey(key) ? reduced.threads : state.threads,
      );
    }
    if (changedSession && reducedThread != null) {
      final nextCache =
          cache ?? _threadCaches.putIfAbsent(key, ThreadSessionCache.new);
      nextCache.put(
        reducedThread,
        reduced.timeline,
        nextTurnsCursor: reduced.olderTurnsCursor,
        tokenUsage: reduced.tokenUsage,
      );
    }
    if (message.method == 'thread/goal/updated') {
      final goal = reduced.activeGoal;
      if (goal != null) {
        _threadGoals[threadPreferenceKey(key.profileId, key.agent, threadId)] =
            goal;
      }
    } else if (message.method == 'thread/goal/cleared') {
      _threadGoals.remove(
        threadPreferenceKey(key.profileId, key.agent, threadId),
      );
    }
    _rememberSubAgentReferences(key, reduced.threads, reduced.timeline);
  }

  void _applyChildSubAgentCompletion(
    AgentConnectionKey key,
    CodexRpcNotification message,
  ) {
    final childThreadId = _notificationThreadId(message);
    final terminalStatus = _subAgentTerminalStatusFromCompletion(message);
    if (childThreadId.isEmpty ||
        terminalStatus == null ||
        !_subAgentThreadRegistry.contains(key, childThreadId)) {
      return;
    }

    var visibleTimelineChanged = false;
    if (_isActiveKey(key)) {
      final timeline = _withSubAgentTerminalStatus(
        state.timeline,
        childThreadId,
        terminalStatus,
      );
      if (!identical(timeline, state.timeline)) {
        visibleTimelineChanged = true;
        state = state.copyWith(timeline: timeline);
      }
    }

    final cache = _threadCaches[key];
    cache?.updateSubAgentStatus(childThreadId, terminalStatus);
    if (visibleTimelineChanged && state.activeThread != null) {
      (cache ?? _threadCaches.putIfAbsent(key, ThreadSessionCache.new)).put(
        state.activeThread!,
        state.timeline,
        nextTurnsCursor: state.olderTurnsCursor,
        tokenUsage: state.tokenUsage,
      );
    }
  }

  bool _notificationTargetsVisibleThread(
    AgentConnectionKey key,
    CodexRpcNotification message,
  ) {
    if (!_isActiveKey(key) ||
        (state.screen != AppScreen.work &&
            state.screen != AppScreen.agentWork)) {
      return false;
    }
    final activeThreadId = state.activeThread?.id.trim() ?? '';
    if (activeThreadId.isEmpty) return false;
    final threadId = _notificationThreadId(message);
    return threadId.isEmpty || threadId == activeThreadId;
  }

  bool _isApiModelOptionsRequestCurrent(
    int requestId,
    AgentConnectionKey key,
    int generation,
  ) =>
      mounted &&
      _apiModelOptionsRequestId == requestId &&
      _isActiveKey(key) &&
      _agents.isCurrentGeneration(key, generation);

  void _updateProfileModelCatalog(
    String profileId,
    AgentKind agent,
    AgentModelSettings Function(AgentModelSettings current) transform, {
    bool scheduleSync = true,
  }) {
    final profile = state.profiles.firstWhereOrNull(
      (candidate) => candidate.id == profileId,
    );
    if (profile == null) return;
    final key = AgentConnectionKey(profileId: profileId, agent: agent);
    final previousSettings = normalizeAgentModelSettings(
      agent,
      profile.modelSettings(agent),
    );
    final updatedSettings = normalizeAgentModelSettings(
      agent,
      transform(previousSettings),
    );
    final updatedProfile = profile.withModelSettings(agent, updatedSettings);
    final remoteModels =
        _remoteModelsByLane[key] ??
        (state.agentModelLists[key] ?? const <AgentModel>[])
            .where((model) => !model.isCustom)
            .toList(growable: false);
    final catalog = buildModelCatalog(
      remoteModels,
      updatedSettings.customModels,
      <String>{
        ...updatedSettings.hiddenModelIds,
        ..._pendingManagedModelRemovals(updatedSettings),
      },
      customReasoningEfforts: agent == AgentKind.openCode
          ? openCodeReasoningEfforts
          : _noModelReasoningEfforts,
    );
    final profiles = state.profiles
        .map(
          (candidate) => candidate.id == profileId ? updatedProfile : candidate,
        )
        .toList(growable: false);
    final modelLists = Map<AgentConnectionKey, List<AgentModel>>.of(
      state.agentModelLists,
    )..[key] = catalog;
    final active = _isActiveKey(key);
    final selectedIsAvailable =
        state.selectedModel?.trim().isNotEmpty == true &&
        catalog.any(
          (model) =>
              model.id.trim() == state.selectedModel!.trim() ||
              modelWireName(model) == state.selectedModel!.trim(),
        );
    final fallback = resolveModelSelection(
      catalog,
      updatedSettings.preferredModel,
      updatedSettings.preferredEffort,
    );
    state = state.copyWith(
      profiles: profiles,
      agentModelLists: Map<AgentConnectionKey, List<AgentModel>>.unmodifiable(
        modelLists,
      ),
      models: active ? catalog : state.models,
      selectedModel: active && !selectedIsAvailable
          ? fallback.model
          : state.selectedModel,
      selectedEffort: active && !selectedIsAvailable
          ? fallback.effort
          : state.selectedEffort,
      error: null,
    );
    _connections.registerProfile(updatedProfile);
    _agents.registerProfile(updatedProfile);
    unawaited(
      _persist(
        (stored) => stored.copyWith(
          profiles: stored.profiles
              .map(
                (candidate) =>
                    candidate.id == profileId ? updatedProfile : candidate,
              )
              .toList(growable: false),
        ),
      ),
    );
    if (scheduleSync &&
        agent == AgentKind.openCode &&
        (previousSettings.customModels != updatedSettings.customModels ||
            previousSettings.managedModelIds !=
                updatedSettings.managedModelIds)) {
      _scheduleCustomModelSync(profileId, agent);
    }
  }

  List<String> _pendingManagedModelRemovals(AgentModelSettings settings) {
    final currentIds = settings.customModels
        .map((model) => model.modelId.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    return settings.managedModelIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty && !currentIds.contains(id))
        .toSet()
        .toList(growable: false);
  }

  void _scheduleCustomModelSync(
    String profileId,
    AgentKind agent, {
    bool immediate = false,
  }) {
    if (!mounted || agent != AgentKind.openCode) return;
    final key = AgentConnectionKey(profileId: profileId, agent: agent);
    final revision = (_customModelSyncRevisions[key] ?? 0) + 1;
    _customModelSyncRevisions[key] = revision;
    _customModelSyncTimers.remove(key)?.cancel();
    late final Timer timer;
    timer = Timer(immediate ? Duration.zero : _customModelSyncDebounce, () {
      if (identical(_customModelSyncTimers[key], timer)) {
        _customModelSyncTimers.remove(key);
      }
      unawaited(
        _syncCustomModelsNow(
          profileId,
          agent,
          expectedRevision: revision,
          requireConnected: false,
        ).catchError((Object error, StackTrace stack) {
          _diagnostics.warn(
            'Models',
            'sync_failed profile=$profileId agent=${agent.label}',
            error,
            stack,
          );
        }),
      );
    });
    _customModelSyncTimers[key] = timer;
  }

  Future<void> _syncCustomModelsNow(
    String profileId,
    AgentKind agent, {
    int? expectedRevision,
    required bool requireConnected,
  }) async {
    if (!mounted || agent != AgentKind.openCode) return;
    final key = AgentConnectionKey(profileId: profileId, agent: agent);
    final lock = _customModelSyncLocks.putIfAbsent(key, Lock.new);
    await lock.synchronized(() async {
      final profile = state.profiles.firstWhereOrNull(
        (candidate) => candidate.id == profileId,
      );
      if (profile == null) return;
      final settings = normalizeAgentModelSettings(
        agent,
        profile.modelSettings(agent),
      );
      final removals = _pendingManagedModelRemovals(settings);
      if (settings.customModels.isEmpty && removals.isEmpty) return;
      if (_agents.states[key]?.phase != ConnectionPhase.connected) {
        if (requireConnected) {
          throw StateError('OpenCode 连接已断开，无法同步模型');
        }
        return;
      }
      _diagnostics.info(
        'Models',
        'sync_start profile=$profileId agent=${agent.label} '
            'models=${settings.customModels.length} removals=${removals.length}',
      );
      await _agents.syncCustomModels(
        key,
        profile,
        definitions: settings.customModels,
        removedModelIds: removals,
      );
      if (!mounted ||
          (expectedRevision != null &&
              _customModelSyncRevisions[key] != expectedRevision)) {
        return;
      }
      _clearSyncedModelTombstones(profileId, agent, removals);
      _diagnostics.info(
        'Models',
        'sync_success profile=$profileId agent=${agent.label}',
      );
    });
  }

  void _clearSyncedModelTombstones(
    String profileId,
    AgentKind agent,
    List<String> syncedIds,
  ) {
    if (!mounted || syncedIds.isEmpty) return;
    final key = AgentConnectionKey(profileId: profileId, agent: agent);
    final synced = syncedIds.toSet();
    final remoteModels = _remoteModelsByLane[key];
    if (remoteModels != null) {
      _remoteModelsByLane[key] = List<AgentModel>.unmodifiable(
        remoteModels.where(
          (model) =>
              !synced.contains(model.id) &&
              !synced.contains(modelWireName(model)),
        ),
      );
    }
    _updateProfileModelCatalog(profileId, agent, (settings) {
      final currentIds = settings.customModels
          .map((model) => model.modelId)
          .toSet();
      return settings.copyWith(
        managedModelIds: settings.managedModelIds
            .where((id) => !synced.contains(id) || currentIds.contains(id))
            .toList(growable: false),
      );
    }, scheduleSync: false);
  }

  void _cancelCustomModelSync(String profileId) {
    final keys = _customModelSyncTimers.keys
        .where((key) => key.profileId == profileId)
        .toList(growable: false);
    for (final key in keys) {
      _customModelSyncTimers.remove(key)?.cancel();
      _customModelSyncRevisions.remove(key);
    }
  }

  Future<void> _persist(
    StoredProfiles Function(StoredProfiles stored) update,
  ) async {
    await _initialization;
    await _persistenceLock.synchronized(() async {
      final next = normalizeStoredProfiles(update(_stored));
      _stored = next;
      try {
        await _store.save(next);
      } catch (error) {
        _setError(error, '保存配置失败');
      }
    });
  }

  Future<void> _ensureInitialized() async {
    await _initialization;
    if (!mounted) throw StateError('应用控制器已经关闭');
  }

  AgentCapabilities _connectedCapabilities(AgentConnectionKey key) =>
      _agents.states[key]?.phase == ConnectionPhase.connected
      ? _agents.capabilities(key)
      : AgentCapabilities.none;

  ServerProfile _normalizeProfile(ServerProfile profile) {
    if (isLocalWindowsProfile(profile)) {
      return localWindowsProfile(existing: profile);
    }
    if (profile.host.trim().isEmpty) throw StateError('服务器地址不能为空');
    if (profile.port < 1 || profile.port > 65535) {
      throw StateError('SSH 端口必须在 1 到 65535 之间');
    }
    return profile.copyWith(
      id: profile.id.trim().isEmpty ? newProfile().id : profile.id.trim(),
      name: profile.name.trim().isEmpty ? '我的服务器' : profile.name.trim(),
      host: profile.host.trim(),
      username: profile.username.trim().isEmpty
          ? 'root'
          : profile.username.trim(),
    );
  }

  void _setError(Object error, String fallback) {
    if (!mounted) return;
    _diagnostics.warn('AppError', 'operation_failed fallback=$fallback', error);
    state = state.copyWith(loading: false, error: _message(error, fallback));
  }

  @override
  void dispose() {
    for (final profileId in _retainedHostConnections.toList()) {
      _invalidateConnectionRecovery(profileId);
    }
    _retainedHostConnections.clear();
    _retainedAgentConnections.clear();
    _threadSearchTimer?.cancel();
    _draftPersistTimer?.cancel();
    _agentThreadNextCursors.clear();
    _agentThreadCursorSearches.clear();
    _agentThreadPageRequests.clear();
    _agentLoadRevisions.clear();
    for (final timer in _customModelSyncTimers.values) {
      timer.cancel();
    }
    _customModelSyncTimers.clear();
    _resumeNotificationBuffers.clear();
    unawaited(_connectionSubscription.cancel());
    unawaited(_serverMetricsSubscription.cancel());
    unawaited(_agentConnectionSubscription.cancel());
    unawaited(_agentEventSubscription.cancel());
    unawaited(_turnCompletionController.close());
    if (_ownsAgentConnections) unawaited(_agents.close());
    super.dispose();
  }
}

const int maxSubAgentNavigationDepth = 8;
const List<Duration> _defaultReconnectDelays = <Duration>[
  Duration.zero,
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 5),
  Duration(seconds: 10),
  Duration(seconds: 30),
  Duration(seconds: 60),
];
const int _maxSessionSnapshotEntries = 512;
const int _maxSessionSnapshotWeightChars = 2 * 1024 * 1024;
const Duration _customModelSyncDebounce = Duration(milliseconds: 350);

List<String> _noModelReasoningEfforts(String _) => const <String>[];

class _ThreadOpenRequest {
  const _ThreadOpenRequest(this.generation, this.future);

  final int generation;
  final Future<void> future;
}

class _SubAgentNavigationFrame {
  const _SubAgentNavigationFrame({
    required this.snapshot,
    required this.screen,
  });

  final _SessionSnapshot snapshot;
  final AppScreen screen;
}

class _SessionSnapshot {
  const _SessionSnapshot({
    required this.threads,
    required this.threadSearch,
    required this.models,
    required this.selectedModel,
    required this.selectedEffort,
    required this.activeThread,
    required this.activeAgentName,
    required this.activeGoal,
    required this.timeline,
    required this.olderTurnsCursor,
    required this.activeTurnId,
    required this.running,
    required this.turnTiming,
    required this.submitting,
    required this.loading,
    required this.aggregateDiff,
    required this.tokenUsage,
    required this.attachments,
    required this.composerClearNonce,
    required this.composerDraft,
    required this.workspaceCurrentPath,
    required this.workspaceParentPath,
    required this.workspaceDirectories,
    required this.workspaceError,
    required this.approval,
    required this.approvalQueue,
    required this.error,
    required this.diagnostic,
  });

  final List<AgentThread> threads;
  final String threadSearch;
  final List<AgentModel> models;
  final String? selectedModel;
  final String? selectedEffort;
  final AgentThread? activeThread;
  final String? activeAgentName;
  final ThreadGoal? activeGoal;
  final List<TimelineEntry> timeline;
  final String? olderTurnsCursor;
  final String? activeTurnId;
  final bool running;
  final TurnTiming? turnTiming;
  final bool submitting;
  final bool loading;
  final String aggregateDiff;
  final TokenUsage? tokenUsage;
  final List<PendingAttachment> attachments;
  final int composerClearNonce;
  final String composerDraft;
  final String workspaceCurrentPath;
  final String? workspaceParentPath;
  final List<RemoteDirectory> workspaceDirectories;
  final String? workspaceError;
  final ApprovalPrompt? approval;
  final List<ApprovalPrompt> approvalQueue;
  final String? error;
  final String? diagnostic;

  factory _SessionSnapshot.capture(AppUiState state) {
    final bounded = _boundSessionTimeline(state.timeline);
    return _SessionSnapshot(
      threads: state.threads,
      threadSearch: state.threadSearch,
      models: state.models,
      selectedModel: state.selectedModel,
      selectedEffort: state.selectedEffort,
      activeThread: state.activeThread,
      activeAgentName: state.activeAgentName,
      activeGoal: state.activeGoal,
      timeline: bounded.timeline,
      olderTurnsCursor: bounded.truncated ? null : state.olderTurnsCursor,
      activeTurnId: state.activeTurnId,
      running: state.running,
      turnTiming: state.turnTiming,
      submitting: false,
      loading: false,
      aggregateDiff: state.aggregateDiff,
      tokenUsage: state.tokenUsage,
      attachments: List<PendingAttachment>.unmodifiable(state.attachments),
      composerClearNonce: state.composerClearNonce,
      composerDraft: state.composerDraft,
      workspaceCurrentPath: state.workspaceCurrentPath,
      workspaceParentPath: state.workspaceParentPath,
      workspaceDirectories: List<RemoteDirectory>.unmodifiable(
        state.workspaceDirectories,
      ),
      workspaceError: state.workspaceError,
      approval: state.approval,
      approvalQueue: List<ApprovalPrompt>.unmodifiable(state.approvalQueue),
      error: state.error,
      diagnostic: state.diagnostic,
    );
  }

  AppUiState restore(AppUiState base) => base.copyWith(
    threads: threads,
    threadSearch: threadSearch,
    models: models,
    selectedModel: selectedModel,
    selectedEffort: selectedEffort,
    activeThread: activeThread,
    activeAgentName: activeAgentName,
    activeGoal: activeGoal,
    timeline: timeline,
    olderTurnsCursor: olderTurnsCursor,
    olderTurnsLoading: false,
    activeTurnId: activeTurnId,
    running: running,
    turnTiming: turnTiming,
    submitting: submitting,
    loading: loading,
    aggregateDiff: aggregateDiff,
    tokenUsage: tokenUsage,
    attachments: attachments,
    attachmentUploading: false,
    composerClearNonce: composerClearNonce,
    composerDraft: composerDraft,
    workspaceCurrentPath: workspaceCurrentPath,
    workspaceParentPath: workspaceParentPath,
    workspaceDirectories: workspaceDirectories,
    workspaceError: workspaceError,
    approval: approval,
    approvalQueue: approvalQueue,
    error: error,
    diagnostic: diagnostic,
  );
}

class _BoundedSessionTimeline {
  const _BoundedSessionTimeline(this.timeline, this.truncated);

  final List<TimelineEntry> timeline;
  final bool truncated;
}

_BoundedSessionTimeline _boundSessionTimeline(List<TimelineEntry> timeline) {
  if (timeline.length <= _maxSessionSnapshotEntries &&
      estimateTimelineWeightChars(timeline) <= _maxSessionSnapshotWeightChars) {
    return _BoundedSessionTimeline(
      List<TimelineEntry>.unmodifiable(timeline),
      false,
    );
  }
  final newest = <TimelineEntry>[];
  var weight = 0;
  for (
    var index = timeline.length - 1;
    index >= 0 && newest.length < _maxSessionSnapshotEntries;
    index--
  ) {
    final entry = timeline[index];
    final entryWeight = estimateTimelineWeightChars([entry]);
    if (entryWeight > _maxSessionSnapshotWeightChars - weight) break;
    newest.add(entry);
    weight += entryWeight;
  }
  return _BoundedSessionTimeline(
    List<TimelineEntry>.unmodifiable(newest.reversed),
    true,
  );
}

int? _subAgentThreadCreatedAt(AgentThread thread) {
  if (!isSubAgentThreadSource(thread.source) || thread.createdAt <= 0) {
    return null;
  }
  return thread.createdAt;
}

Map<String, ServerMetrics> _connectedServerMetrics(
  Map<String, ServerMetrics> metrics,
  Map<String, ConnectionState> connections, [
  Set<String>? retainedProfileIds,
]) => Map.unmodifiable(
  Map.fromEntries(
    metrics.entries.where(
      (entry) =>
          connections[entry.key]?.phase == ConnectionPhase.connected ||
          retainedProfileIds?.contains(entry.key) == true,
    ),
  ),
);

List<AgentThread> _mergeListedThreads(
  List<AgentThread> current,
  List<AgentThread> nextPage,
) {
  final providers = nextPage
      .map((thread) => thread.modelProvider.trim())
      .where((provider) => provider.isNotEmpty)
      .toSet();
  final retainedCurrent = providers.isEmpty
      ? current
      : current.where(
          (thread) => providers.contains(thread.modelProvider.trim()),
        );
  final merged = <AgentThread>[];
  final indexes = <String, int>{};
  for (final thread in retainedCurrent) {
    final id = thread.id.trim();
    final identity = id.isNotEmpty
        ? id
        : '${thread.title}\u0000${thread.cwd}\u0000${thread.createdAt}';
    if (indexes.containsKey(identity)) continue;
    indexes[identity] = merged.length;
    merged.add(thread);
  }
  for (final thread in nextPage) {
    final id = thread.id.trim();
    final identity = id.isNotEmpty
        ? id
        : '${thread.title}\u0000${thread.cwd}\u0000${thread.createdAt}';
    final existingIndex = indexes[identity];
    if (existingIndex == null) {
      indexes[identity] = merged.length;
      merged.add(thread);
    } else {
      // Keep the existing page's position while preferring fresh metadata.
      merged[existingIndex] = thread;
    }
  }
  return List<AgentThread>.unmodifiable(merged);
}

String _defaultAgentProvider(AgentKind agent) => switch (agent) {
  AgentKind.codex => 'openai',
  AgentKind.openCode => openCodeManagedProviderId,
};

bool _preserveThreadsAfterSettingsSave({
  required AgentKind agent,
  required AgentGlobalSettings currentSettings,
  required bool preserveCurrentProvider,
}) {
  final defaultProvider = _defaultAgentProvider(agent);
  final currentProvider = currentSettings.modelProvider.trim().isEmpty
      ? defaultProvider
      : currentSettings.modelProvider.trim();
  final nextProvider = preserveCurrentProvider
      ? currentProvider
      : defaultProvider;
  return currentProvider == nextProvider;
}

Map<String, ServerMetrics> _withoutServerMetrics(
  Map<String, ServerMetrics> metrics,
  String profileId,
) => Map.unmodifiable(
  Map.fromEntries(metrics.entries.where((entry) => entry.key != profileId)),
);

class _AgentProfileData {
  const _AgentProfileData({
    required this.threadLists,
    required this.modelLists,
    required this.loadingStates,
  });

  final Map<AgentConnectionKey, List<AgentThread>> threadLists;
  final Map<AgentConnectionKey, List<AgentModel>> modelLists;
  final Map<AgentConnectionKey, bool> loadingStates;
}

_AgentProfileData _withoutAgentProfileData(
  AppUiState state,
  String profileId,
) => _AgentProfileData(
  threadLists: Map.unmodifiable(
    Map.fromEntries(
      state.agentThreadLists.entries.where(
        (entry) => entry.key.profileId != profileId,
      ),
    ),
  ),
  modelLists: Map.unmodifiable(
    Map.fromEntries(
      state.agentModelLists.entries.where(
        (entry) => entry.key.profileId != profileId,
      ),
    ),
  ),
  loadingStates: Map.unmodifiable(
    Map.fromEntries(
      state.agentLoadingStates.entries.where(
        (entry) => entry.key.profileId != profileId,
      ),
    ),
  ),
);

String? _agentLoadDiagnostic(Object? threadError, Object? modelError) {
  final messages = <String>[
    if (threadError != null) _message(threadError, '读取会话失败'),
    if (modelError != null) _message(modelError, '读取模型失败'),
  ];
  return messages.isEmpty ? null : messages.join('；');
}

bool _threadIsRunning(AgentThread thread) {
  if (thread.activeTurnId?.trim().isNotEmpty ?? false) return true;
  return _threadStatusIndicatesRunning(thread.status);
}

bool _threadStatusIndicatesRunning(String status) {
  return switch (status.trim().toLowerCase()) {
    'active' || 'running' || 'working' || 'inprogress' || 'in_progress' => true,
    _ => false,
  };
}

bool _isNoActiveTurnInterruptError(Object error) {
  final message = error is CodexRpcException ? error.message : error.toString();
  return message.toLowerCase().contains('no active turn to interrupt');
}

String? _activeTimelineTurnId(List<TimelineEntry> timeline) {
  for (final entry in timeline.reversed) {
    if (entry.status == 'inProgress' && entry.turnId.isNotEmpty) {
      return entry.turnId;
    }
  }
  return null;
}

bool _canReuseTurnTiming(
  TurnTiming? timing,
  String threadId,
  String? activeTurnId,
) {
  if (timing == null ||
      timing.threadId != threadId ||
      timing.completedAtMillis != null) {
    return false;
  }
  final retainedTurnId = timing.turnId?.trim() ?? '';
  if (retainedTurnId.isEmpty) return true;
  final resumedTurnId = activeTurnId?.trim() ?? '';
  return resumedTurnId.isNotEmpty && retainedTurnId == resumedTurnId;
}

bool _completedTimingMatchesTurn(
  TurnTiming? timing,
  String threadId,
  String? activeTurnId,
) {
  if (timing == null ||
      timing.completedAtMillis == null ||
      timing.threadId != threadId) {
    return false;
  }
  final completedTurnId = timing.turnId?.trim() ?? '';
  final resumedTurnId = activeTurnId?.trim() ?? '';
  return completedTurnId.isNotEmpty && completedTurnId == resumedTurnId;
}

bool _isCompletionNotification(CodexRpcNotification message) {
  if (message.method == 'turn/completed' ||
      isTerminalAgentMessageNotification(message)) {
    return true;
  }
  if (message.method != 'thread/status/changed') return false;
  final status = _notificationString(message.params, const [
    'status',
  ]).toLowerCase();
  return switch (status) {
    'idle' ||
    'completed' ||
    'complete' ||
    'failed' ||
    'error' ||
    'stopped' ||
    'interrupted' ||
    'cancelled' ||
    'canceled' => true,
    _ => false,
  };
}

String? _subAgentTerminalStatusFromCompletion(CodexRpcNotification message) {
  final method = message.method;
  final params = message.params;
  final turn = _notificationMap(params['turn']);
  final status = _notificationStatus(
    method == 'turn/completed'
        ? (turn == null ? null : turn['status'])
        : params['status'],
  ).toLowerCase();
  if (method == 'turn/completed') {
    return switch (status) {
      'interrupted' ||
      'stopped' ||
      'aborted' ||
      'cancelled' ||
      'canceled' => 'interrupted',
      'failed' || 'error' || 'systemerror' => 'errored',
      _ => 'completed',
    };
  }
  if (method != 'thread/status/changed') return null;
  return switch (status) {
    'idle' || 'completed' || 'complete' || 'done' => 'completed',
    'interrupted' ||
    'stopped' ||
    'aborted' ||
    'cancelled' ||
    'canceled' => 'interrupted',
    'failed' || 'error' || 'systemerror' => 'errored',
    _ => null,
  };
}

String _notificationStatus(Object? value) {
  if (value is String) return value.trim();
  return _notificationString(_notificationMap(value), const ['type', 'status']);
}

List<TimelineEntry> _withSubAgentTerminalStatus(
  List<TimelineEntry> timeline,
  String childThreadId,
  String terminalStatus,
) {
  var changed = false;
  final result = timeline
      .map((entry) {
        if (entry.kind != TimelineKind.subAgent ||
            entry.subAgentThreadId != childThreadId ||
            !_isActiveSubAgentTimelineStatus(entry.status)) {
          return entry;
        }
        changed = true;
        return entry.copyWith(status: terminalStatus);
      })
      .toList(growable: false);
  return changed ? List<TimelineEntry>.unmodifiable(result) : timeline;
}

bool _isActiveSubAgentTimelineStatus(String status) => const <String>{
  'pendingInit',
  'running',
  'inProgress',
  'started',
  'interacted',
  'unknown',
}.contains(status);

Map<String, Object?>? _notificationMap(Object? value) {
  if (value is! Map) return null;
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is String) result[entry.key as String] = entry.value;
  }
  return result;
}

String _notificationThreadId(CodexRpcNotification message) {
  final params = message.params;
  return _notificationString(params, const ['threadId', 'thread_id'])
      .ifEmpty(
        () => _notificationString(_notificationMap(params['turn']), const [
          'threadId',
          'thread_id',
        ]),
      )
      .ifEmpty(
        () => _notificationString(_notificationMap(params['thread']), const [
          'id',
          'threadId',
          'thread_id',
        ]),
      );
}

CodexRpcNotification _withResolvedNotificationThreadId(
  CodexRpcNotification message,
) {
  final threadId = _notificationThreadId(message);
  if (threadId.isEmpty) return message;
  if (message.params['threadId'] == threadId) return message;
  final params = Map<String, Object?>.unmodifiable(<String, Object?>{
    ...message.params,
    'threadId': threadId,
  });
  return CodexRpcNotification(
    generation: message.generation,
    sequence: message.sequence,
    raw: Map<String, Object?>.unmodifiable(<String, Object?>{
      ...message.raw,
      'params': params,
    }),
    method: message.method,
    params: params,
    isKnown: message.isKnown,
  );
}

String _notificationString(Map<String, Object?>? value, List<String> keys) {
  if (value == null) return '';
  for (final key in keys) {
    final candidate = value[key];
    if (candidate is String && candidate.trim().isNotEmpty) {
      return candidate.trim();
    }
    if (candidate is num || candidate is bool) return candidate.toString();
  }
  return '';
}

List<TimelineEntry> _mergeTimeline(
  List<TimelineEntry> older,
  List<TimelineEntry> newer,
) {
  final result = <TimelineEntry>[];
  final ids = <(String, TimelineKind, String)>{};
  for (final entry in [...older, ...newer]) {
    if (ids.add(_timelineIdentity(entry))) result.add(entry);
  }
  return List<TimelineEntry>.unmodifiable(result);
}

final class ResumedTimelineMerge {
  const ResumedTimelineMerge({required this.timeline, this.nextCursor});

  final List<TimelineEntry> timeline;
  final String? nextCursor;
}

ResumedTimelineMerge reconcileResumedTimeline({
  required List<TimelineEntry>? cachedTimeline,
  required String? cachedNextCursor,
  required List<TimelineEntry> refreshedTimeline,
  required String? refreshedNextCursor,
  List<String>? refreshedTurnIds,
  int? cachedThreadUpdatedAt,
  int? refreshedThreadUpdatedAt,
  String refreshedItemsView = 'full',
}) {
  // A resumed snapshot can contain the same user item more than once when a
  // connection is recovered while the previous snapshot is still being
  // replayed. Normalize both sides before matching; otherwise every formal
  // item id is treated as a new bubble and the cached copies accumulate.
  final normalizedCachedTimeline = cachedTimeline == null
      ? null
      : _normalizeResumedTimeline(cachedTimeline);
  final normalizedRefreshedTimeline = _normalizeResumedTimeline(
    refreshedTimeline,
  );
  final refreshedTurns =
      (refreshedTurnIds ??
              normalizedRefreshedTimeline
                  .map((entry) => entry.turnId)
                  .where((id) => id.isNotEmpty))
          .toSet();
  final overlapIndex =
      normalizedCachedTimeline?.indexWhere(
        (entry) => refreshedTurns.contains(entry.turnId),
      ) ??
      -1;
  final retainedPrefix = overlapIndex < 0
      ? const <TimelineEntry>[]
      : normalizedCachedTimeline!.take(overlapIndex).toList(growable: false);
  final refreshedDetails = overlapIndex < 0
      ? normalizedRefreshedTimeline
      : _mergeRefreshedTimeline(
          normalizedCachedTimeline!
              .skip(overlapIndex)
              .where((entry) => refreshedTurns.contains(entry.turnId))
              .toList(growable: false),
          normalizedRefreshedTimeline,
        );
  final revisionUnchanged =
      cachedThreadUpdatedAt != null &&
      refreshedThreadUpdatedAt != null &&
      cachedThreadUpdatedAt == refreshedThreadUpdatedAt;
  final cachedBoundaryUsable =
      cachedNextCursor != null || refreshedNextCursor == null;
  final hasVerifiedOverlap =
      overlapIndex >= 0 && revisionUnchanged && cachedBoundaryUsable;
  final unchangedSummary =
      normalizedCachedTimeline != null &&
      revisionUnchanged &&
      cachedBoundaryUsable &&
      refreshedItemsView == 'summary';
  final unchangedNotLoaded =
      cachedTimeline != null &&
      revisionUnchanged &&
      cachedBoundaryUsable &&
      refreshedItemsView == 'notLoaded';
  final unchangedEmptyPage =
      normalizedCachedTimeline != null &&
      normalizedRefreshedTimeline.isEmpty &&
      cachedNextCursor == refreshedNextCursor &&
      revisionUnchanged;

  final List<TimelineEntry> timeline;
  if (unchangedNotLoaded || unchangedEmptyPage) {
    timeline = normalizedCachedTimeline!;
  } else if (unchangedSummary) {
    timeline = _mergeRefreshedTimeline(
      normalizedCachedTimeline,
      normalizedRefreshedTimeline,
    );
  } else if (hasVerifiedOverlap) {
    timeline = <TimelineEntry>[...retainedPrefix, ...refreshedDetails];
  } else if (overlapIndex >= 0) {
    timeline = refreshedDetails;
  } else {
    timeline = normalizedRefreshedTimeline;
  }
  final retainCursor =
      hasVerifiedOverlap ||
      unchangedSummary ||
      unchangedNotLoaded ||
      unchangedEmptyPage;
  return ResumedTimelineMerge(
    timeline: List<TimelineEntry>.unmodifiable(
      _normalizeResumedTimeline(timeline),
    ),
    nextCursor: retainCursor ? cachedNextCursor : refreshedNextCursor,
  );
}

List<TimelineEntry> _normalizeResumedTimeline(List<TimelineEntry> entries) {
  final result = <TimelineEntry>[];
  final identityIndexes = <(String, TimelineKind, String), int>{};
  final userIndexes = <(String, String, String), int>{};
  for (final entry in entries) {
    final identity = _timelineIdentity(entry);
    final existingIdentityIndex = identityIndexes[identity];
    if (existingIdentityIndex != null) {
      result[existingIdentityIndex] = mergeCodexTimelineEntry(
        result[existingIdentityIndex],
        entry,
      );
      continue;
    }
    if (entry.kind == TimelineKind.userMessage) {
      final semanticKey = (
        entry.turnId,
        entry.text.trim(),
        _timelineAttachmentKey(entry),
      );
      final existingUserIndex = _findResumedUserIndex(
        result,
        entry,
        userIndexes,
      );
      if (existingUserIndex != null) {
        final merged = mergeCodexTimelineEntry(
          result[existingUserIndex],
          entry,
        );
        // Prefer the authoritative server id over a local optimistic id.
        result[existingUserIndex] = merged;
        identityIndexes[identity] = existingUserIndex;
        continue;
      }
      userIndexes[semanticKey] = result.length;
    }
    identityIndexes[identity] = result.length;
    result.add(entry);
  }
  return List<TimelineEntry>.unmodifiable(result);
}

int? _findResumedUserIndex(
  List<TimelineEntry> entries,
  TimelineEntry incoming,
  Map<(String, String, String), int> indexed,
) {
  final key = (
    incoming.turnId,
    incoming.text.trim(),
    _timelineAttachmentKey(incoming),
  );
  final exact = indexed[key];
  if (exact != null) return exact;
  for (var index = entries.length - 1; index >= 0; index -= 1) {
    final candidate = entries[index];
    if (candidate.kind != TimelineKind.userMessage ||
        candidate.text.trim() != incoming.text.trim() ||
        _timelineAttachmentKey(candidate) != _timelineAttachmentKey(incoming)) {
      continue;
    }
    final sameTurn =
        candidate.turnId.isNotEmpty &&
        incoming.turnId.isNotEmpty &&
        candidate.turnId == incoming.turnId;
    final unresolvedTurn = candidate.turnId.isEmpty && incoming.turnId.isEmpty;
    final optimisticPair =
        candidate.id.startsWith('local-user-') ||
        incoming.id.startsWith('local-user-');
    if (sameTurn || unresolvedTurn || optimisticPair) return index;
  }
  return null;
}

String _timelineAttachmentKey(TimelineEntry entry) => entry.attachments
    .map(
      (attachment) =>
          '${attachment.name}|${attachment.remotePath}|${attachment.mimeType}',
    )
    .toList(growable: false)
    .join(';;');

List<TimelineEntry> _mergeRefreshedTimeline(
  List<TimelineEntry> cached,
  List<TimelineEntry> refreshed,
) {
  final matches = <int, int>{};
  final consumed = <int>{};
  var minimumRefreshedIndex = 0;
  for (var cachedIndex = 0; cachedIndex < cached.length; cachedIndex += 1) {
    final cachedEntry = cached[cachedIndex];
    var refreshedIndex = -1;
    for (
      var index = minimumRefreshedIndex;
      index < refreshed.length;
      index += 1
    ) {
      if (!consumed.contains(index) &&
          _timelineIdentity(refreshed[index]) ==
              _timelineIdentity(cachedEntry)) {
        refreshedIndex = index;
        break;
      }
    }
    if (refreshedIndex < 0) {
      for (
        var index = minimumRefreshedIndex;
        index < refreshed.length;
        index += 1
      ) {
        if (!consumed.contains(index) &&
            _sameResumedTimelineItem(cachedEntry, refreshed[index])) {
          refreshedIndex = index;
          break;
        }
      }
    }
    if (refreshedIndex < 0) continue;
    matches[cachedIndex] = refreshedIndex;
    consumed.add(refreshedIndex);
    minimumRefreshedIndex = refreshedIndex + 1;
  }

  final result = <TimelineEntry>[];
  for (var cachedIndex = 0; cachedIndex < cached.length; cachedIndex += 1) {
    final cachedEntry = cached[cachedIndex];
    final refreshedIndex = matches[cachedIndex];
    if (refreshedIndex == null) {
      result.add(cachedEntry);
      continue;
    }
    result.add(mergeCodexTimelineEntry(cachedEntry, refreshed[refreshedIndex]));
  }
  for (var index = 0; index < refreshed.length; index += 1) {
    if (!consumed.contains(index)) result.add(refreshed[index]);
  }
  return result;
}

bool _sameResumedTimelineItem(TimelineEntry cached, TimelineEntry refreshed) {
  if (cached.kind != refreshed.kind ||
      (cached.turnId.isNotEmpty &&
          refreshed.turnId.isNotEmpty &&
          cached.turnId != refreshed.turnId)) {
    return false;
  }
  if (cached.kind == TimelineKind.userMessage &&
      cached.id.startsWith('local-user-')) {
    return findMatchingOptimisticUserTimelineEntry(
          <TimelineEntry>[cached],
          refreshed,
          allowEmptyContent: false,
        ) ==
        0;
  }
  return switch (cached.kind) {
    TimelineKind.agentMessage || TimelineKind.plan =>
      cached.text.trim().isNotEmpty &&
          cached.text.trim() == refreshed.text.trim(),
    TimelineKind.reasoning =>
      cached.reasoningSummary.isNotEmpty || cached.reasoningContent.isNotEmpty
          ? _sameStringList(
                  cached.reasoningSummary,
                  refreshed.reasoningSummary,
                ) &&
                _sameStringList(
                  cached.reasoningContent,
                  refreshed.reasoningContent,
                )
          : cached.text.trim().isNotEmpty &&
                cached.text.trim() == refreshed.text.trim(),
    TimelineKind.command =>
      cached.command.trim().isNotEmpty &&
          cached.command.trim() == refreshed.command.trim() &&
          (cached.cwd.trim().isEmpty ||
              refreshed.cwd.trim().isEmpty ||
              cached.cwd.trim() == refreshed.cwd.trim()),
    _ => false,
  };
}

bool _sameStringList(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index].trim() != right[index].trim()) return false;
  }
  return true;
}

(String, TimelineKind, String) _timelineIdentity(TimelineEntry entry) =>
    (entry.turnId, entry.kind, entry.id);

int? _knownRevision(int? value) => value != null && value > 0 ? value : null;

Map<AgentConnectionKey, List<AgentThread>> _replaceLaneThread(
  Map<AgentConnectionKey, List<AgentThread>> source,
  AgentConnectionKey key,
  AgentThread thread,
) {
  final lane = source[key] ?? const <AgentThread>[];
  final index = lane.indexWhere((candidate) => candidate.id == thread.id);
  final updated = index < 0
      ? <AgentThread>[thread, ...lane]
      : <AgentThread>[...lane.take(index), thread, ...lane.skip(index + 1)];
  final result = Map<AgentConnectionKey, List<AgentThread>>.of(source)
    ..[key] = List<AgentThread>.unmodifiable(updated);
  return Map<AgentConnectionKey, List<AgentThread>>.unmodifiable(result);
}

Map<String, V> _withoutMapKey<V>(Map<String, V> source, String key) {
  if (!source.containsKey(key)) return source;
  final result = Map<String, V>.of(source)..remove(key);
  return Map<String, V>.unmodifiable(result);
}

StoredProfiles _removeProfileScopedData(
  StoredProfiles stored,
  String profileId,
) => stored.copyWith(
  composerDrafts: _withoutProfileEntries(stored.composerDrafts, profileId),
  threadModelPreferences: _withoutProfileEntries(
    stored.threadModelPreferences,
    profileId,
  ),
  completedTurnTimings: _withoutProfileEntries(
    stored.completedTurnTimings,
    profileId,
  ),
);

Map<String, V> _withoutProfileEntries<V>(
  Map<String, V> values,
  String profileId,
) {
  final prefix = '$profileId\u0000';
  return Map<String, V>.unmodifiable(
    Map<String, V>.fromEntries(
      values.entries.where((entry) => !entry.key.startsWith(prefix)),
    ),
  );
}

String _message(Object error, String fallback) {
  final message = error
      .toString()
      .replaceFirst(RegExp(r'^[^:]+:\s*'), '')
      .trim();
  return message.isEmpty ? fallback : message;
}

String _agentSettingsTestReason(AgentConnectionTestResult result) {
  if (result.successful) return 'success';
  final message = result.message;
  if (message.contains('API 密钥后再测试')) return 'missing_api_key';
  if (message.contains('测试模型后再测试')) return 'missing_test_model';
  if (message.contains('无法解析 API 域名')) return 'dns';
  if (message.contains('无法连接 API 服务端口')) return 'connect';
  if (message.contains('连接 API 服务超时')) return 'timeout';
  if (message.contains('TLS')) return 'tls';
  if (message.contains('API 密钥无效')) return 'unauthorized';
  if (message.contains('API 服务返回异常')) return 'http_error';
  if (message.contains('未安装 curl')) return 'curl_unavailable';
  return 'rejected';
}

extension _StringFallback on String {
  String ifEmpty(String Function() fallback) => isEmpty ? fallback() : this;
}

ApprovalPrompt? _approvalPromptFromRequest(CodexServerRequest request) {
  final params = request.params;
  final method = request.method;
  final kind = switch (method) {
    'item/commandExecution/requestApproval' ||
    'execCommandApproval' => ApprovalKind.command,
    'item/fileChange/requestApproval' ||
    'applyPatchApproval' => ApprovalKind.fileChange,
    'item/permissions/requestApproval' ||
    'permissions/requestApproval' => ApprovalKind.permission,
    'item/tool/requestUserInput' ||
    'tool/requestUserInput' => ApprovalKind.userInput,
    _ => null,
  };
  if (kind == null) return null;
  final rawQuestions = _requestList(params['questions'], 16);
  final questions = rawQuestions
      .map(_requestMap)
      .whereType<Map<String, Object?>>()
      .map((question) {
        final options = _requestList(question['options'], 24)
            .map((value) {
              final object = _requestMap(value);
              final label = object == null
                  ? value is String
                        ? value
                        : ''
                  : _requestString(object, const ['label']);
              return label.trim().isEmpty
                  ? null
                  : InputOption(
                      label: _boundedRequest(label, 4096),
                      description: object == null
                          ? ''
                          : _boundedRequest(
                              _requestString(object, const ['description']),
                              16384,
                            ),
                    );
            })
            .whereType<InputOption>()
            .toList(growable: false);
        return InputQuestion(
          id: _boundedRequest(_requestString(question, const ['id']), 4096),
          header: _boundedRequest(
            _requestString(question, const ['header']),
            4096,
          ),
          question: _boundedRequest(
            _requestString(question, const ['question']),
            16384,
          ),
          options: options,
          isSecret: question['isSecret'] == true,
        );
      })
      .where((question) => question.id.isNotEmpty)
      .toList(growable: false);
  final firstQuestion = questions.firstOrNull;
  final rawDetail = _requestString(params, const ['reason', 'message']);
  final detail = kind == ApprovalKind.userInput
      ? firstQuestion?.question ?? rawDetail
      : rawDetail;
  return ApprovalPrompt(
    requestId: request.id.wireValue.toString(),
    requestIdIsString: request.id.isString,
    kind: kind,
    threadId: _requestString(params, const ['threadId', 'thread_id']),
    turnId: _requestString(params, const ['turnId', 'turn_id']),
    itemId: _requestString(params, const ['itemId', 'item_id']),
    title: switch (kind) {
      ApprovalKind.command => '批准执行命令',
      ApprovalKind.fileChange => '批准文件修改',
      ApprovalKind.permission => '批准额外权限',
      ApprovalKind.userInput =>
        firstQuestion?.header.isNotEmpty == true
            ? firstQuestion!.header
            : 'Codex 需要信息',
    },
    detail: detail.isNotEmpty
        ? detail
        : switch (kind) {
            ApprovalKind.command => 'Codex 请求执行以下命令',
            ApprovalKind.fileChange => 'Codex 请求写入工作区文件',
            ApprovalKind.permission => 'Codex 请求额外权限',
            ApprovalKind.userInput => 'Codex 需要你提供信息',
          },
    command: _requestString(params, const ['command']),
    cwd: _requestString(params, const ['cwd']),
    questions: questions,
  );
}

Map<String, Object?>? _requestMap(Object? value) {
  if (value is! Map) return null;
  final result = <String, Object?>{};
  for (final entry in value.entries.take(128)) {
    if (entry.key is String) result[entry.key as String] = entry.value;
  }
  return result;
}

List<Object?> _requestList(Object? value, int limit) {
  if (value is! List || limit < 1) return const <Object?>[];
  return value.take(limit).cast<Object?>().toList(growable: false);
}

String _boundedRequest(String value, int limit) =>
    value.length <= limit ? value : '${value.substring(0, limit - 8)}\n[已截断]';

String _requestString(Map<String, Object?> value, List<String> keys) {
  for (final key in keys) {
    final candidate = value[key];
    if (candidate is String) return candidate;
    if (candidate is num || candidate is bool) return candidate.toString();
  }
  return '';
}

extension _FirstWhereOrNull<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T value) test) {
    for (final value in this) {
      if (test(value)) return value;
    }
    return null;
  }
}
