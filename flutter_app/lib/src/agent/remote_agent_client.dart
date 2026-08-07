import '../domain/models.dart';
import '../ssh/ssh_server_client.dart';
import 'codex_protocol.dart';
import 'remote_bootstrap.dart';

/// A page returned by an agent's thread-list endpoint.
class AgentThreadPage {
  const AgentThreadPage({
    required this.threads,
    this.nextCursor,
    this.previousCursor,
  });

  final List<AgentThread> threads;
  final String? nextCursor;
  final String? previousCursor;
}

class AgentSession {
  const AgentSession({
    required this.thread,
    required this.timeline,
    this.nextTurnsCursor,
    this.tokenUsage,
    this.responseSequence = 0,
    this.activeTurnStartedAtMillis,
    this.turnIds = const <String>[],
    this.itemsView = 'full',
  });

  final AgentThread thread;
  final List<TimelineEntry> timeline;
  final String? nextTurnsCursor;
  final TokenUsage? tokenUsage;
  final int responseSequence;
  final int? activeTurnStartedAtMillis;
  final List<String> turnIds;
  final String itemsView;
}

class AgentTurnsPage {
  const AgentTurnsPage({
    required this.timeline,
    this.nextCursor,
    this.turnIds = const <String>[],
    this.itemsView = 'full',
  });

  final List<TimelineEntry> timeline;
  final String? nextCursor;
  final List<String> turnIds;
  final String itemsView;
}

/// Optional capability used to bind resume-time buffering to the concrete
/// app-server generation without source-breaking lightweight test adapters.
abstract interface class RemoteAgentGenerationClient {
  int? get currentGeneration;
}

/// Events that are safe for the controller to consume without knowing the
/// wire format of a particular agent adapter.
sealed class RemoteAgentEvent {
  const RemoteAgentEvent();
}

class RemoteAgentNotification extends RemoteAgentEvent {
  const RemoteAgentNotification(this.message);

  final CodexRpcNotification message;
}

class RemoteAgentServerRequest extends RemoteAgentEvent {
  const RemoteAgentServerRequest(this.message);

  final CodexServerRequest message;
}

class RemoteAgentDiagnostic extends RemoteAgentEvent {
  const RemoteAgentDiagnostic(this.message, {this.isStderr = false});

  final String message;
  final bool isStderr;
}

class RemoteAgentConnectionLost extends RemoteAgentEvent {
  const RemoteAgentConnectionLost(this.message);

  final String message;
}

/// Adapter contract shared by Codex and future OpenCode implementations.
///
/// A client is bound to one `(profileId, AgentKind)` lane by
/// [AgentConnectionManager]. It must never share its app-server channel with
/// another lane.
abstract interface class RemoteAgentClient {
  AgentKind get kind;

  AgentCapabilities get capabilities;

  bool get isConnected;

  Stream<RemoteAgentEvent> get events;

  Future<void> connect(ServerProfile profile, RemoteServerClient host);

  Future<List<AgentModel>> listModels();

  Future<AgentThreadPage> listThreads({String? searchTerm});

  Future<AgentSession> resumeThread(
    String threadId, {
    ApprovalMode approvalMode = ApprovalMode.requestApproval,
  });

  Future<AgentTurnsPage> loadOlderTurns({
    required String threadId,
    required String cursor,
    int? subAgentCreatedAt,
  });

  Future<void> disconnect();

  void close();
}

/// Optional pagination capability for adapters whose thread/list endpoint
/// exposes a continuation cursor. Keeping this separate preserves the small
/// base contract for lightweight read-only adapters and test fakes.
abstract interface class RemoteAgentThreadPaginationClient {
  Future<AgentThreadPage> listThreadsPage({String? searchTerm, String? cursor});
}

/// Optional capability implemented by agents that can execute turns. Keeping
/// this separate lets read-only adapters and third-party test fakes continue
/// implementing [RemoteAgentClient] without a source-breaking change.
abstract interface class RemoteAgentTurnClient {
  Future<String> startTurn({
    required String threadId,
    required String text,
    List<PendingAttachment> attachments = const <PendingAttachment>[],
    String? model,
    String? effort,
    ApprovalMode approvalMode = ApprovalMode.requestApproval,
    SandboxChoice? sandbox,
    String? cwd,
  });

  /// Interrupts the active turn. Read-only adapters may leave this disabled.
  Future<void> interruptTurn({
    required String threadId,
    required String turnId,
  });
}

/// Optional capability for adding input to a turn that is already running.
abstract interface class RemoteAgentSteerClient {
  Future<void> steerTurn({
    required String threadId,
    required String turnId,
    required String text,
    List<PendingAttachment> attachments = const <PendingAttachment>[],
  });
}

abstract interface class RemoteAgentThreadCreateClient {
  Future<AgentSession> startThread({
    String? cwd,
    String? model,
    ApprovalMode approvalMode = ApprovalMode.requestApproval,
    SandboxChoice? sandbox,
  });
}

/// Optional capability for app-server initiated approvals and user input.
abstract interface class RemoteAgentApprovalClient {
  Future<void> answerApproval(
    ApprovalPrompt prompt, {
    required bool accept,
    Map<String, String> answers = const <String, String>{},
  });
}

/// Optional thread mutations shared by the Codex work-screen actions. Keeping
/// this capability separate means an adapter can still provide read-only
/// history without pretending to support destructive operations.
abstract interface class RemoteAgentThreadMutationClient {
  Future<void> compactThread(String threadId);

  Future<AgentSession> rollbackThread(
    String threadId, {
    ApprovalMode approvalMode = ApprovalMode.requestApproval,
    int turns = 1,
  });

  Future<void> archiveThread(String threadId);

  Future<void> setThreadName(String threadId, String name);

  Future<void> startReview(String threadId);

  Future<ThreadGoal?> getThreadGoal(String threadId);

  Future<ThreadGoal> setThreadGoal(
    String threadId, {
    String? objective,
    ThreadGoalStatus? status,
    int? tokenBudget,
  });

  Future<void> clearThreadGoal(String threadId);
}

/// Optional per-user configuration capability. Implementations must edit the
/// Agent's global user files, never a repository-local configuration.
abstract interface class RemoteAgentGlobalSettingsClient {
  Future<AgentGlobalSettings> readGlobalSettings(ServerProfile profile);

  Future<void> writeGlobalSettings(
    ServerProfile profile, {
    required String baseUrl,
    required String apiKey,
    required String proxyUrl,
    required String defaultModel,
    required String defaultReasoningEffort,
    required bool preserveCurrentProvider,
  });

  Future<AgentConnectionTestResult> testGlobalSettings(
    ServerProfile profile, {
    required String baseUrl,
    required String apiKey,
    required String proxyUrl,
    required String testModel,
  });
}

/// Optional capability for listing models exposed by the configured HTTP API.
/// The request runs through the connected server so its network and proxy
/// settings match the Agent runtime.
abstract interface class RemoteAgentApiModelClient {
  Future<List<ApiModelOption>> fetchApiModels(
    ServerProfile profile, {
    required String baseUrl,
    required String apiKey,
    required String proxyUrl,
  });
}

/// Optional lifecycle for adapters that must register app-defined models in
/// the remote provider before those model IDs can be used by a turn.
abstract interface class RemoteAgentCustomModelClient {
  Future<void> ensureCustomModel(
    ServerProfile profile,
    CustomModelDefinition definition,
  );

  Future<void> syncCustomModels(
    ServerProfile profile, {
    required List<CustomModelDefinition> definitions,
    required List<String> removedModelIds,
  });
}

/// Optional capability for agents whose pinned runtime can be provisioned in
/// the current SSH user's home directory.
abstract interface class RemoteAgentRuntimeClient {
  Future<AgentRuntimeInspection> inspectRuntime(
    ServerProfile profile,
    RemoteServerClient host,
  );

  Future<void> installRuntime(
    ServerProfile profile,
    RemoteServerClient host, {
    required void Function(RemoteInstallProgress progress) onProgress,
  });

  Future<void> uninstallRuntime(ServerProfile profile, RemoteServerClient host);
}

/// A deliberately small adapter for agents that have not been migrated yet.
class UnsupportedRemoteAgentClient implements RemoteAgentClient {
  UnsupportedRemoteAgentClient(this.kind);

  @override
  final AgentKind kind;

  @override
  AgentCapabilities get capabilities => AgentCapabilities.none;

  @override
  bool get isConnected => false;

  @override
  Stream<RemoteAgentEvent> get events => const Stream<RemoteAgentEvent>.empty();

  @override
  Future<void> connect(ServerProfile profile, RemoteServerClient host) async {
    throw StateError('${kind.label} 适配器尚未启用');
  }

  @override
  Future<List<AgentModel>> listModels() async => const <AgentModel>[];

  @override
  Future<AgentThreadPage> listThreads({String? searchTerm}) async =>
      const AgentThreadPage(threads: <AgentThread>[]);

  @override
  Future<AgentSession> resumeThread(
    String threadId, {
    ApprovalMode approvalMode = ApprovalMode.requestApproval,
  }) async => throw StateError('${kind.label} 适配器尚未启用');

  @override
  Future<AgentTurnsPage> loadOlderTurns({
    required String threadId,
    required String cursor,
    int? subAgentCreatedAt,
  }) async => throw StateError('${kind.label} 适配器尚未启用');

  @override
  Future<void> disconnect() async {}

  @override
  void close() {}
}
