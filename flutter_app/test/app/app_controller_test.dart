import 'dart:async';
import 'dart:typed_data';

import 'package:codex_remote/src/agent/agent_connection_manager.dart';
import 'package:codex_remote/src/agent/codex_protocol.dart';
import 'package:codex_remote/src/agent/remote_agent_client.dart';
import 'package:codex_remote/src/agent/remote_bootstrap.dart';
import 'package:codex_remote/src/app/app_controller.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/persistence/profile_store.dart';
import 'package:codex_remote/src/platform/background_connection_bridge.dart';
import 'package:codex_remote/src/platform/diagnostic_logger.dart';
import 'package:codex_remote/src/platform/local_linux_manager.dart';
import 'package:codex_remote/src/ssh/server_connection_manager.dart';
import 'package:codex_remote/src/ssh/ssh_server_client.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryProfileStore implements ProfileStore {
  _MemoryProfileStore(this.value);

  StoredProfiles value;
  final List<StoredProfiles> writes = [];

  @override
  Future<StoredProfiles> load() async => value;

  @override
  Future<void> save(StoredProfiles value) async {
    this.value = value;
    writes.add(value);
  }
}

class _RecordingDiagnosticLogger extends DiagnosticLogger {
  final records = <String>[];

  @override
  bool get isEnabled => true;

  @override
  Future<bool> initialize() async => true;

  @override
  void info(String tag, String message) {
    records.add('INFO $tag $message');
  }

  @override
  void warn(String tag, String message, [Object? error, StackTrace? stack]) {
    records.add('WARN $tag $message');
  }
}

class _GatedLoadProfileStore extends _MemoryProfileStore {
  _GatedLoadProfileStore() : super(const StoredProfiles());

  final Completer<StoredProfiles> loadResult = Completer<StoredProfiles>();

  @override
  Future<StoredProfiles> load() => loadResult.future;
}

class _BlockingFirstSaveProfileStore extends _MemoryProfileStore {
  _BlockingFirstSaveProfileStore(super.value);

  final Completer<void> firstSaveStarted = Completer<void>();
  final Completer<void> releaseFirstSave = Completer<void>();
  int saveCalls = 0;
  int activeSaves = 0;
  int maximumActiveSaves = 0;

  @override
  Future<void> save(StoredProfiles value) async {
    final call = ++saveCalls;
    activeSaves++;
    maximumActiveSaves = maximumActiveSaves < activeSaves
        ? activeSaves
        : maximumActiveSaves;
    try {
      if (call == 1) {
        firstSaveStarted.complete();
        await releaseFirstSave.future;
      }
      await super.save(value);
    } finally {
      activeSaves--;
    }
  }
}

class _FingerprintClient
    implements RemoteServerClient, RemoteServerKeepAliveClient {
  _FingerprintClient({
    this.metrics = const ServerMetrics(),
    this.metricsError,
    this.keepAliveError,
  });

  final Completer<String> fingerprint = Completer<String>();
  final Completer<void> closed = Completer<void>();
  final ServerMetrics metrics;
  final Object? metricsError;
  final Object? keepAliveError;
  bool connected = false;
  int metricsReadCount = 0;
  int keepAliveCount = 0;

  @override
  Future<void> connect(ServerProfile profile) async {
    connected = true;
  }

  @override
  Future<void> disconnect() async {
    connected = false;
    if (!closed.isCompleted) closed.complete();
  }

  @override
  Future<void> get done => closed.future;

  @override
  bool get isConnected => connected;

  @override
  Future<void> keepAlive() async {
    if (!connected) return;
    keepAliveCount++;
    if (keepAliveError case final error?) throw error;
  }

  @override
  Future<String> probeFingerprint(ServerProfile profile) => fingerprint.future;

  @override
  Future<ServerMetrics> readServerMetrics(ServerProfile profile) async {
    metricsReadCount++;
    if (metricsError case final error?) throw error;
    return metrics;
  }

  @override
  SSHClient requireSshClient() => throw UnimplementedError();

  @override
  Future<String> run(
    String command, {
    Duration timeout = const Duration(seconds: 15),
    int maxOutputBytes = 1024 * 1024,
  }) async => '';

  @override
  void close() {
    connected = false;
    if (!closed.isCompleted) closed.complete();
  }
}

class _ReconnectableHost extends _FingerprintClient {
  _ReconnectableHost({super.metrics});

  Completer<void> _connectionDone = Completer<void>();
  int connectCount = 0;

  @override
  Future<void> connect(ServerProfile profile) async {
    connectCount++;
    if (_connectionDone.isCompleted) {
      _connectionDone = Completer<void>();
    }
    connected = true;
  }

  void drop([Object? error]) {
    connected = false;
    if (_connectionDone.isCompleted) return;
    if (error == null) {
      _connectionDone.complete();
    } else {
      _connectionDone.completeError(error, StackTrace.current);
    }
  }

  @override
  Future<void> disconnect() async {
    connected = false;
    if (!_connectionDone.isCompleted) _connectionDone.complete();
  }

  @override
  Future<void> get done => _connectionDone.future;

  @override
  void close() {
    connected = false;
    if (!_connectionDone.isCompleted) _connectionDone.complete();
  }
}

class _AttachmentHost extends _FingerprintClient
    implements RemoteServerAttachmentClient {
  static const remotePath = '/tmp/codex-remote/uploads/notes.txt';

  String? uploadedName;
  Uint8List? uploadedBytes;
  int? uploadedMaxBytes;

  @override
  Future<String> uploadAttachment(
    String name,
    Uint8List bytes, {
    int maxBytes = maxRemoteAttachmentBytes,
  }) async {
    uploadedName = name;
    uploadedBytes = Uint8List.fromList(bytes);
    uploadedMaxBytes = maxBytes;
    return remotePath;
  }
}

class _WorkspaceDirectoryRequest {
  _WorkspaceDirectoryRequest(this.path);

  final String? path;
  final Completer<RemoteDirectoryListing> result =
      Completer<RemoteDirectoryListing>();
}

class _WorkspaceHost extends _FingerprintClient
    implements RemoteServerDirectoryClient {
  final List<_WorkspaceDirectoryRequest> directoryRequests =
      <_WorkspaceDirectoryRequest>[];

  @override
  Future<RemoteDirectoryListing> listDirectories(String? path) {
    final request = _WorkspaceDirectoryRequest(path);
    directoryRequests.add(request);
    return request.result.future;
  }
}

class _FakeLocalLinuxRuntime implements LocalLinuxRuntime {
  int startCalls = 0;
  int stopCalls = 0;
  int uninstallCalls = 0;

  @override
  Future<LocalLinuxInstance> ensureStarted() async {
    startCalls++;
    return _localLinuxInstance;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<void> uninstall() async {
    uninstallCalls++;
  }
}

class _FileManagerListRequest {
  _FileManagerListRequest(this.path);

  final String? path;
  final Completer<RemoteFileListing> result = Completer<RemoteFileListing>();
}

class _FileManagerHost extends _FingerprintClient
    implements RemoteServerFileManagerClient, RemoteServerFileClient {
  final List<_FileManagerListRequest> listRequests =
      <_FileManagerListRequest>[];
  final List<int> uploadedBytes = <int>[];
  String? uploadedDirectory;
  String? uploadedName;
  String? renamedPath;
  String? renamedName;
  List<String>? deletedPaths;
  List<String>? transferredPaths;
  String? transferDestination;
  RemoteFileTransferMode? transferMode;
  List<Uint8List> downloadChunks = <Uint8List>[];

  @override
  Future<RemoteFileListing> listRemoteFiles(String? path) {
    final request = _FileManagerListRequest(path);
    listRequests.add(request);
    return request.result.future;
  }

  @override
  Future<void> uploadRemoteFile(
    String directory,
    String name,
    Stream<List<int>> chunks, {
    int? declaredSize,
    int maxBytes = maxRemoteFileBytes,
  }) async {
    uploadedDirectory = directory;
    uploadedName = name;
    await for (final chunk in chunks) {
      uploadedBytes.addAll(chunk);
    }
  }

  @override
  Future<int> downloadRemoteFile(
    String path, {
    required Future<void> Function(Uint8List chunk) writeChunk,
    int maxBytes = maxRemoteFileBytes,
  }) async {
    var total = 0;
    for (final chunk in downloadChunks) {
      await writeChunk(chunk);
      total += chunk.length;
    }
    return total;
  }

  @override
  Future<void> renameRemoteFile(String path, String newName) async {
    renamedPath = path;
    renamedName = newName;
  }

  @override
  Future<void> deleteRemoteFiles(List<String> paths) async {
    deletedPaths = List<String>.of(paths);
  }

  @override
  Future<void> transferRemoteFiles(
    List<String> paths,
    String destinationDirectory,
    RemoteFileTransferMode mode,
  ) async {
    transferredPaths = List<String>.of(paths);
    transferDestination = destinationDirectory;
    transferMode = mode;
  }
}

class _FailingTurnAgent
    implements
        RemoteAgentClient,
        RemoteAgentTurnClient,
        RemoteAgentKeepAliveClient {
  static const thread = AgentThread(
    id: 'attachment-thread',
    title: 'Attachment test',
    cwd: '/workspace/project',
  );
  static const initialTimeline = <TimelineEntry>[
    TimelineEntry(
      id: 'existing-message',
      kind: TimelineKind.agentMessage,
      text: 'Existing response',
    ),
  ];

  bool connected = false;
  int connectCount = 0;
  int disconnectCount = 0;
  int listModelsCount = 0;
  int listThreadsCount = 0;
  int keepAliveCount = 0;
  int resumeCalls = 0;
  String? startedThreadId;
  String? startedText;
  List<PendingAttachment>? startedAttachments;
  String? startedModel;
  String? startedEffort;
  ApprovalMode? startedApprovalMode;
  SandboxChoice? startedSandbox;
  String? startedCwd;
  String? interruptedThreadId;
  String? interruptedTurnId;

  @override
  AgentCapabilities get capabilities => const AgentCapabilities(
    models: false,
    archiveThread: false,
    renameThread: false,
    interruptTurn: true,
  );

  @override
  Stream<RemoteAgentEvent> get events => const Stream<RemoteAgentEvent>.empty();

  @override
  bool get isConnected => connected;

  @override
  Future<void> keepAlive() async {
    if (connected) keepAliveCount++;
  }

  @override
  AgentKind get kind => AgentKind.codex;

  @override
  Future<void> connect(ServerProfile profile, RemoteServerClient host) async {
    connectCount++;
    connected = true;
  }

  @override
  Future<void> disconnect() async {
    disconnectCount++;
    connected = false;
  }

  @override
  void close() {
    connected = false;
  }

  @override
  Future<List<AgentModel>> listModels() async {
    listModelsCount++;
    return const <AgentModel>[];
  }

  @override
  Future<AgentThreadPage> listThreads({String? searchTerm}) async {
    listThreadsCount++;
    return const AgentThreadPage(threads: <AgentThread>[thread]);
  }

  @override
  Future<AgentSession> resumeThread(
    String threadId, {
    ApprovalMode approvalMode = ApprovalMode.requestApproval,
  }) async {
    resumeCalls++;
    return const AgentSession(thread: thread, timeline: initialTimeline);
  }

  @override
  Future<AgentTurnsPage> loadOlderTurns({
    required String threadId,
    required String cursor,
    int? subAgentCreatedAt,
  }) async => const AgentTurnsPage(timeline: <TimelineEntry>[]);

  @override
  Future<String> startTurn({
    required String threadId,
    required String text,
    List<PendingAttachment> attachments = const <PendingAttachment>[],
    String? model,
    String? effort,
    ApprovalMode approvalMode = ApprovalMode.requestApproval,
    SandboxChoice? sandbox,
    String? cwd,
  }) async {
    startedThreadId = threadId;
    startedText = text;
    startedAttachments = List<PendingAttachment>.unmodifiable(attachments);
    startedModel = model;
    startedEffort = effort;
    startedApprovalMode = approvalMode;
    startedSandbox = sandbox;
    startedCwd = cwd;
    throw StateError('模型暂时不可用');
  }

  @override
  Future<void> interruptTurn({
    required String threadId,
    required String turnId,
  }) async {
    interruptedThreadId = threadId;
    interruptedTurnId = turnId;
  }
}

class _EventAgent extends _FailingTurnAgent {
  final StreamController<RemoteAgentEvent> eventController =
      StreamController<RemoteAgentEvent>.broadcast(sync: true);

  @override
  Stream<RemoteAgentEvent> get events => eventController.stream;

  void emit(RemoteAgentEvent event) => eventController.add(event);

  @override
  void close() {
    super.close();
    unawaited(eventController.close());
  }
}

class _SteeringAgent extends _FailingTurnAgent
    implements RemoteAgentSteerClient {
  static const activeThread = AgentThread(
    id: 'active-thread',
    title: 'Active turn',
    cwd: '/workspace/project',
    status: 'active',
    activeTurnId: 'turn-running',
  );

  String? steeredThreadId;
  String? steeredTurnId;
  String? steeredText;
  List<PendingAttachment>? steeredAttachments;

  @override
  AgentCapabilities get capabilities => const AgentCapabilities(
    models: false,
    steerTurn: true,
    archiveThread: false,
    renameThread: false,
    interruptTurn: true,
  );

  @override
  Future<AgentThreadPage> listThreads({String? searchTerm}) async =>
      const AgentThreadPage(threads: <AgentThread>[activeThread]);

  @override
  Future<AgentSession> resumeThread(
    String threadId, {
    ApprovalMode approvalMode = ApprovalMode.requestApproval,
  }) async => const AgentSession(
    thread: activeThread,
    timeline: <TimelineEntry>[
      TimelineEntry(
        id: 'existing-active-message',
        kind: TimelineKind.agentMessage,
        text: 'Working',
        turnId: 'turn-running',
      ),
    ],
  );

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
    steeredAttachments = List<PendingAttachment>.of(attachments);
  }
}

class _SubAgentNavigationAgent extends _FailingTurnAgent {
  _SubAgentNavigationAgent({this.agentKind = AgentKind.codex});

  static const rootThread = AgentThread(
    id: 'root-thread',
    title: 'Root thread',
    cwd: '/workspace/root',
    source: 'appServer',
  );
  static const childThread = AgentThread(
    id: 'child-thread',
    title: 'Child agent',
    cwd: '/workspace/root',
    source: 'subagent',
    createdAt: 100,
  );
  static const grandchildThread = AgentThread(
    id: 'grandchild-thread',
    title: 'Grandchild agent',
    cwd: '/workspace/root',
    source: 'subagent',
    createdAt: 200,
  );
  static const rootTimeline = <TimelineEntry>[
    TimelineEntry(
      id: 'root-message',
      kind: TimelineKind.agentMessage,
      text: 'Root response',
    ),
  ];
  static const childTimeline = <TimelineEntry>[
    TimelineEntry(
      id: 'child-message',
      kind: TimelineKind.agentMessage,
      text: 'Child response',
    ),
  ];
  static const grandchildTimeline = <TimelineEntry>[
    TimelineEntry(
      id: 'grandchild-message',
      kind: TimelineKind.agentMessage,
      text: 'Grandchild response',
    ),
  ];
  static const rootUsage = TokenUsage(
    last: TokenUsageBreakdown(totalTokens: 110),
    modelContextWindow: 1000,
  );
  static const childUsage = TokenUsage(
    last: TokenUsageBreakdown(totalTokens: 220),
    modelContextWindow: 2000,
  );
  static const grandchildUsage = TokenUsage(
    last: TokenUsageBreakdown(totalTokens: 330),
    modelContextWindow: 3000,
  );
  static const sessions = <String, AgentSession>{
    'root-thread': AgentSession(
      thread: rootThread,
      timeline: rootTimeline,
      tokenUsage: rootUsage,
    ),
    'child-thread': AgentSession(
      thread: childThread,
      timeline: childTimeline,
      tokenUsage: childUsage,
    ),
    'grandchild-thread': AgentSession(
      thread: grandchildThread,
      timeline: grandchildTimeline,
      tokenUsage: grandchildUsage,
    ),
  };

  final AgentKind agentKind;
  final Map<String, List<Completer<AgentSession>>> _resumeGates =
      <String, List<Completer<AgentSession>>>{};
  final List<String> resumedThreadIds = <String>[];
  final List<String> completedThreadIds = <String>[];

  @override
  AgentKind get kind => agentKind;

  @override
  AgentCapabilities get capabilities => switch (agentKind) {
    AgentKind.codex => AgentCapabilities.codex,
    AgentKind.openCode => AgentCapabilities.openCode,
  };

  Completer<AgentSession> gateNextResume(String threadId) {
    final gate = Completer<AgentSession>();
    (_resumeGates[threadId] ??= <Completer<AgentSession>>[]).add(gate);
    return gate;
  }

  int resumeCount(String threadId) =>
      resumedThreadIds.where((id) => id == threadId).length;

  int completedResumeCount(String threadId) =>
      completedThreadIds.where((id) => id == threadId).length;

  @override
  Future<AgentThreadPage> listThreads({String? searchTerm}) async =>
      const AgentThreadPage(threads: <AgentThread>[rootThread]);

  @override
  Future<AgentSession> resumeThread(
    String threadId, {
    ApprovalMode approvalMode = ApprovalMode.requestApproval,
  }) async {
    resumedThreadIds.add(threadId);
    try {
      final gates = _resumeGates[threadId];
      if (gates != null && gates.isNotEmpty) {
        return await gates.removeAt(0).future;
      }
      final session = sessions[threadId];
      if (session == null) throw StateError('Unknown thread: $threadId');
      return session;
    } finally {
      completedThreadIds.add(threadId);
    }
  }
}

class _PaginatedThreadAgent extends _SubAgentNavigationAgent
    implements RemoteAgentThreadPaginationClient {
  @override
  Future<AgentThreadPage> listThreads({String? searchTerm}) async =>
      const AgentThreadPage(
        threads: <AgentThread>[_SubAgentNavigationAgent.rootThread],
        nextCursor: 'page-2',
      );

  @override
  Future<AgentThreadPage> listThreadsPage({
    String? searchTerm,
    String? cursor,
  }) async {
    if (cursor != 'page-2') throw StateError('分页游标错误');
    return const AgentThreadPage(
      threads: <AgentThread>[_SubAgentNavigationAgent.childThread],
    );
  }
}

class _ConnectFailingAgent extends _FailingTurnAgent {
  @override
  Future<void> connect(ServerProfile profile, RemoteServerClient host) async {
    throw StateError('Agent 启动失败');
  }
}

class _BlockingThreadListAgent extends _FailingTurnAgent {
  final Completer<AgentThreadPage> firstThreadList =
      Completer<AgentThreadPage>();
  int threadListCalls = 0;

  @override
  Future<AgentThreadPage> listThreads({String? searchTerm}) {
    threadListCalls++;
    if (threadListCalls == 1) return firstThreadList.future;
    return super.listThreads(searchTerm: searchTerm);
  }
}

class _HostBoundDisconnectAgent extends _FailingTurnAgent {
  RemoteServerClient? connectedHost;
  bool hostWasConnectedWhenDisconnectStarted = false;

  @override
  Future<void> connect(ServerProfile profile, RemoteServerClient host) async {
    connectedHost = host;
    await super.connect(profile, host);
  }

  @override
  Future<void> disconnect() async {
    hostWasConnectedWhenDisconnectStarted = connectedHost?.isConnected ?? false;
    connected = false;
    await connectedHost?.done;
  }
}

class _SettingsAgent extends _FailingTurnAgent
    implements RemoteAgentGlobalSettingsClient, RemoteAgentApiModelClient {
  AgentGlobalSettings readValue = const AgentGlobalSettings(
    baseUrl: 'https://models.example/v1',
    model: 'gpt-test',
    reasoningEffort: 'high',
    modelProvider: 'custom-provider',
    hasStoredAuthentication: true,
    apiKey: 'sk-server-value',
    proxyUrl: 'http://127.0.0.1:7890',
  );
  Completer<AgentGlobalSettings>? readCompleter;
  AgentConnectionTestResult testValue = const AgentConnectionTestResult(
    successful: true,
    message: '模型可用',
  );
  int readCalls = 0;
  int testCalls = 0;
  int writeCalls = 0;
  int fetchApiModelsCalls = 0;
  int? failConnectAttempt;
  List<AgentModel> modelList = const <AgentModel>[];
  List<ApiModelOption> apiModelList = const <ApiModelOption>[
    ApiModelOption(modelId: 'gpt-api-model'),
  ];
  String? testedBaseUrl;
  String? testedApiKey;
  String? testedProxyUrl;
  String? testedModel;
  String? writtenBaseUrl;
  String? writtenApiKey;
  String? writtenProxyUrl;
  String? writtenDefaultModel;
  String? writtenDefaultEffort;
  bool? writtenPreserveProvider;
  String? fetchedBaseUrl;
  String? fetchedApiKey;
  String? fetchedProxyUrl;

  @override
  AgentCapabilities get capabilities => AgentCapabilities.codex;

  @override
  Future<void> connect(ServerProfile profile, RemoteServerClient host) async {
    if (connectCount + 1 == failConnectAttempt) {
      connectCount++;
      connected = false;
      throw StateError('settings restart rejected');
    }
    await super.connect(profile, host);
  }

  @override
  Future<List<AgentModel>> listModels() async => modelList;

  @override
  Future<AgentGlobalSettings> readGlobalSettings(ServerProfile profile) {
    readCalls++;
    return readCompleter?.future ?? Future.value(readValue);
  }

  @override
  Future<AgentConnectionTestResult> testGlobalSettings(
    ServerProfile profile, {
    required String baseUrl,
    required String apiKey,
    required String proxyUrl,
    required String testModel,
  }) async {
    testCalls++;
    testedBaseUrl = baseUrl;
    testedApiKey = apiKey;
    testedProxyUrl = proxyUrl;
    testedModel = testModel;
    return testValue;
  }

  @override
  Future<void> writeGlobalSettings(
    ServerProfile profile, {
    required String baseUrl,
    required String apiKey,
    required String proxyUrl,
    required String defaultModel,
    required String defaultReasoningEffort,
    required bool preserveCurrentProvider,
  }) async {
    writeCalls++;
    writtenBaseUrl = baseUrl;
    writtenApiKey = apiKey;
    writtenProxyUrl = proxyUrl;
    writtenDefaultModel = defaultModel;
    writtenDefaultEffort = defaultReasoningEffort;
    writtenPreserveProvider = preserveCurrentProvider;
  }

  @override
  Future<List<ApiModelOption>> fetchApiModels(
    ServerProfile profile, {
    required String baseUrl,
    required String apiKey,
    required String proxyUrl,
  }) async {
    fetchApiModelsCalls++;
    fetchedBaseUrl = baseUrl;
    fetchedApiKey = apiKey;
    fetchedProxyUrl = proxyUrl;
    return apiModelList;
  }
}

class _RuntimeAgent extends _FailingTurnAgent
    implements RemoteAgentRuntimeClient {
  bool installed = false;
  bool failNextInstall = false;
  Completer<void>? installGate;
  int inspectCalls = 0;
  int installCalls = 0;
  String? installedProxy;
  String? connectedRemoteCommand;

  @override
  Future<void> connect(ServerProfile profile, RemoteServerClient host) async {
    connectedRemoteCommand = profile.remoteCommand;
    await super.connect(profile, host);
  }

  @override
  Future<AgentRuntimeInspection> inspectRuntime(
    ServerProfile profile,
    RemoteServerClient host,
  ) async {
    inspectCalls++;
    return AgentRuntimeInspection(
      os: 'Linux',
      architecture: 'x86_64',
      home: '/root',
      libc: 'glibc',
      managedVersion: installed ? 'codex-cli $pinnedCodexVersion' : null,
      managedPath: installed ? '/root/.local/bin/codex-remote' : null,
      hasShell: true,
      hasTar: true,
      hasSha256: true,
      hasFlock: true,
      hasSetsidWait: true,
      downloader: 'curl',
    );
  }

  @override
  Future<void> installRuntime(
    ServerProfile profile,
    RemoteServerClient host, {
    required void Function(RemoteInstallProgress progress) onProgress,
  }) async {
    installCalls++;
    installedProxy = profile.proxyUrl;
    onProgress(
      const RemoteInstallProgress(
        percent: 38,
        message: '下载独立 Node.js 运行时',
        detail: '12 MB / 32 MB',
        downloadPercent: 37,
      ),
    );
    await installGate?.future;
    if (failNextInstall) {
      failNextInstall = false;
      throw StateError('模拟下载失败');
    }
    installed = true;
    onProgress(
      const RemoteInstallProgress(
        percent: 100,
        message: '安装完成',
        detail: 'Codex app-server 已就绪',
      ),
    );
  }

  @override
  Future<void> uninstallRuntime(
    ServerProfile profile,
    RemoteServerClient host,
  ) async {
    installed = false;
  }
}

class _ApprovalAgent extends _SubAgentNavigationAgent
    implements RemoteAgentApprovalClient {
  final StreamController<RemoteAgentEvent> _eventController =
      StreamController<RemoteAgentEvent>.broadcast(sync: true);
  final List<ApprovalPrompt> answeredPrompts = <ApprovalPrompt>[];
  Completer<void>? answerStarted;
  Completer<void>? answerGate;

  @override
  AgentCapabilities get capabilities => AgentCapabilities.codex;

  @override
  Stream<RemoteAgentEvent> get events => _eventController.stream;

  void emitApproval({
    required String requestId,
    required String threadId,
    String reason = '需要执行命令',
  }) {
    _eventController.add(
      RemoteAgentServerRequest(
        CodexServerRequest(
          generation: 1,
          raw: const <String, Object?>{},
          id: CodexRequestId.string(requestId),
          method: 'item/commandExecution/requestApproval',
          params: <String, Object?>{
            'threadId': threadId,
            'turnId': 'turn-$threadId',
            'itemId': 'item-$requestId',
            'reason': reason,
            'command': 'echo approval',
            'cwd': '/workspace',
          },
        ),
      ),
    );
  }

  @override
  Future<void> answerApproval(
    ApprovalPrompt prompt, {
    required bool accept,
    Map<String, String> answers = const <String, String>{},
  }) async {
    answeredPrompts.add(prompt);
    final started = answerStarted;
    if (started != null && !started.isCompleted) started.complete();
    await answerGate?.future;
  }

  @override
  void close() {
    super.close();
    unawaited(_eventController.close());
  }
}

const _firstProfile = ServerProfile(
  id: 'first',
  name: 'First',
  host: 'first.example',
  username: 'root',
  authMode: AuthMode.password,
  password: 'secret',
  hostFingerprint: 'SHA256:first',
);

const _secondProfile = ServerProfile(
  id: 'second',
  name: 'Second',
  host: 'second.example',
  username: 'root',
  authMode: AuthMode.password,
  password: 'secret',
  hostFingerprint: 'SHA256:second',
);

const _localLinuxInstance = LocalLinuxInstance(
  port: 41234,
  password: 'generated-password',
  architecture: 'arm64-v8a',
  rootfsVersion: 'debian-test',
);

class _SubAgentHarness {
  const _SubAgentHarness({
    required this.store,
    required this.connections,
    required this.agents,
    required this.controller,
    required this.agent,
    required this.profile,
  });

  final _MemoryProfileStore store;
  final ServerConnectionManager connections;
  final AgentConnectionManager agents;
  final AppController controller;
  final _SubAgentNavigationAgent agent;
  final ServerProfile profile;
}

Future<_SubAgentHarness> _createSubAgentHarness({
  StoredProfiles? storedProfiles,
  _SubAgentNavigationAgent? agent,
  RemoteAgentClientFactory? clientFactory,
}) async {
  final primaryAgent = agent ?? _SubAgentNavigationAgent();
  final initial =
      storedProfiles ??
      StoredProfiles(
        profiles: [_firstProfile.copyWith(workspacePromptShown: true)],
        selectedProfileId: _firstProfile.id,
      );
  final profile = initial.profiles.firstWhere(
    (candidate) => candidate.id == _firstProfile.id,
  );
  final store = _MemoryProfileStore(initial);
  final host = _FingerprintClient();
  final connections = ServerConnectionManager(clientFactory: () => host);
  final agents = AgentConnectionManager(
    connections,
    clientFactory: clientFactory ?? (kind) => primaryAgent,
  );
  final controller = AppController(store, connections, agents);
  addTearDown(() async {
    controller.dispose();
    await agents.close();
    await connections.close();
  });

  await _waitUntilInitialized(controller);
  await controller.requestConnect(profile);
  await controller.ensureActiveAgent();
  await _waitUntil(
    () =>
        controller.state.activeAgentCapabilities.subAgents &&
        controller.state.threads.any(
          (thread) => thread.id == _SubAgentNavigationAgent.rootThread.id,
        ),
  );
  controller.openThread(_SubAgentNavigationAgent.rootThread);
  await _waitUntil(
    () =>
        controller.state.activeThread?.id ==
            _SubAgentNavigationAgent.rootThread.id &&
        !controller.state.loading,
  );
  return _SubAgentHarness(
    store: store,
    connections: connections,
    agents: agents,
    controller: controller,
    agent: primaryAgent,
    profile: profile,
  );
}

Future<void> _openSubAgent(
  _SubAgentHarness harness,
  AgentThread thread,
  String name,
) async {
  harness.controller.openSubAgentThread(thread.id, name);
  await _waitUntil(
    () =>
        harness.controller.state.activeThread?.id == thread.id &&
        !harness.controller.state.loading,
  );
}

void main() {
  test(
    'local Linux connect starts once and persists the fixed profile',
    () async {
      final store = _MemoryProfileStore(const StoredProfiles());
      final host = _FingerprintClient();
      final connections = ServerConnectionManager(clientFactory: () => host);
      final agent = _FailingTurnAgent();
      final agents = AgentConnectionManager(
        connections,
        clientFactory: (kind) => agent,
      );
      final runtime = _FakeLocalLinuxRuntime();
      final controller = AppController(
        store,
        connections,
        agents,
        null,
        null,
        null,
        runtime,
      );
      addTearDown(() async {
        controller.dispose();
        await agents.close();
        await connections.close();
      });
      await _waitUntilInitialized(controller);

      final connect = controller.connectLocalLinux();
      await _waitUntil(
        () => controller.state.connection.phase == ConnectionPhase.probing,
      );

      expect(runtime.startCalls, 1);
      expect(controller.state.connection.phase, ConnectionPhase.probing);
      expect(controller.state.pendingFingerprint, isNull);
      expect(store.value.profiles.single.id, localLinuxProfileId);
      expect(store.value.profiles.single.approvalMode, ApprovalMode.fullAccess);
      host.fingerprint.complete('SHA256:local');
      await connect;
      expect(controller.state.pendingFingerprint, 'SHA256:local');
    },
  );

  test('disconnecting local Linux also stops the embedded runtime', () async {
    final profile = localLinuxProfile(
      _localLinuxInstance,
    ).copyWith(hostFingerprint: 'SHA256:local');
    final store = _MemoryProfileStore(
      StoredProfiles(profiles: [profile], selectedProfileId: profile.id),
    );
    final host = _FingerprintClient();
    final connections = ServerConnectionManager(clientFactory: () => host);
    final agent = _FailingTurnAgent();
    final agents = AgentConnectionManager(
      connections,
      clientFactory: (kind) => agent,
    );
    final runtime = _FakeLocalLinuxRuntime();
    final controller = AppController(
      store,
      connections,
      agents,
      null,
      null,
      null,
      runtime,
    );
    addTearDown(() async {
      controller.dispose();
      await agents.close();
      await connections.close();
    });
    await _waitUntilInitialized(controller);
    await controller.requestConnect(profile);
    await controller.disconnectProfile(profile.id);

    expect(runtime.startCalls, 1);
    expect(runtime.stopCalls, 1);
    expect(controller.state.connection.phase, ConnectionPhase.disconnected);
  });

  test(
    'reuses the connected Agent snapshot when re-entering a server',
    () async {
      final profile = _firstProfile.copyWith(workspacePromptShown: true);
      final store = _MemoryProfileStore(
        StoredProfiles(profiles: [profile], selectedProfileId: profile.id),
      );
      final host = _FingerprintClient();
      final connections = ServerConnectionManager(clientFactory: () => host);
      final agent = _FailingTurnAgent();
      final agents = AgentConnectionManager(
        connections,
        clientFactory: (kind) => agent,
      );
      final controller = AppController(store, connections, agents);
      addTearDown(() async {
        controller.dispose();
        await agents.close();
        await connections.close();
      });

      await _waitUntilInitialized(controller);
      await controller.requestConnect(profile);
      await controller.ensureActiveAgent();

      expect(agent.connectCount, 1);
      expect(agent.listThreadsCount, 1);
      expect(agent.listModelsCount, 1);

      controller.backToServers();
      controller.selectProfile(profile.id);
      await _waitUntil(() => controller.state.screen == AppScreen.threads);
      await _drainAsyncWork();

      expect(agent.connectCount, 1);
      expect(agent.listThreadsCount, 1);
      expect(agent.listModelsCount, 1);
      expect(controller.state.threads, contains(_FailingTurnAgent.thread));
    },
  );

  test(
    'background heartbeat keeps retained host and Agent lanes alive',
    () async {
      final profile = _firstProfile.copyWith(workspacePromptShown: true);
      final store = _MemoryProfileStore(
        StoredProfiles(profiles: [profile], selectedProfileId: profile.id),
      );
      final host = _FingerprintClient();
      final connections = ServerConnectionManager(clientFactory: () => host);
      final agent = _FailingTurnAgent();
      final diagnostics = _RecordingDiagnosticLogger();
      final agents = AgentConnectionManager(
        connections,
        clientFactory: (kind) => agent,
      );
      final controller = AppController(store, connections, agents, diagnostics);
      addTearDown(() async {
        controller.dispose();
        await agents.close();
        await connections.close();
      });

      await _waitUntilInitialized(controller);
      await controller.requestConnect(profile);
      await controller.ensureActiveAgent();
      diagnostics.records.clear();
      await controller.keepAliveRetainedConnections();

      expect(host.keepAliveCount, 1);
      expect(agent.keepAliveCount, 1);
      expect(
        diagnostics.records.where((record) => record.contains(' Heartbeat ')),
        isEmpty,
      );
    },
  );

  test(
    'background heartbeat propagates a lane failure for native logs',
    () async {
      final profile = _firstProfile.copyWith(workspacePromptShown: true);
      final store = _MemoryProfileStore(
        StoredProfiles(profiles: [profile], selectedProfileId: profile.id),
      );
      final host = _FingerprintClient(
        keepAliveError: StateError('socket aborted'),
      );
      final connections = ServerConnectionManager(clientFactory: () => host);
      final agent = _FailingTurnAgent();
      final diagnostics = _RecordingDiagnosticLogger();
      final agents = AgentConnectionManager(
        connections,
        clientFactory: (kind) => agent,
      );
      final controller = AppController(store, connections, agents, diagnostics);
      addTearDown(() async {
        controller.dispose();
        await agents.close();
        await connections.close();
      });

      await _waitUntilInitialized(controller);
      await controller.requestConnect(profile);
      await controller.ensureActiveAgent();
      diagnostics.records.clear();

      await expectLater(
        controller.keepAliveRetainedConnections(heartbeatSequence: 42),
        throwsA(isA<StateError>()),
      );
      expect(host.keepAliveCount, 1);
      expect(agent.keepAliveCount, 1);
      expect(
        diagnostics.records,
        contains(contains('WARN Heartbeat lane_failed sequence=42 lane=host')),
      );
    },
  );

  test(
    'Agent stderr is logged without replacing the thread-page status',
    () async {
      final profile = _firstProfile.copyWith(workspacePromptShown: true);
      final store = _MemoryProfileStore(
        StoredProfiles(profiles: [profile], selectedProfileId: profile.id),
      );
      final host = _FingerprintClient();
      final connections = ServerConnectionManager(clientFactory: () => host);
      final agent = _EventAgent();
      final agents = AgentConnectionManager(
        connections,
        clientFactory: (kind) => agent,
      );
      final controller = AppController(store, connections, agents);
      addTearDown(() async {
        controller.dispose();
        await agents.close();
        await connections.close();
      });

      await _waitUntilInitialized(controller);
      await controller.requestConnect(profile);
      await controller.ensureActiveAgent();

      agent.emit(
        const RemoteAgentDiagnostic(
          '2026-08-10 ERROR codex_app_server',
          isStderr: true,
        ),
      );
      await _drainAsyncWork();
      expect(controller.state.diagnostic, isNull);

      agent.emit(
        const RemoteAgentDiagnostic(
          'Codex SSH transport_error detail=socket aborted',
          isTransport: true,
        ),
      );
      await _drainAsyncWork();
      expect(controller.state.diagnostic, isNull);

      agent.emit(const RemoteAgentDiagnostic('Agent status changed'));
      await _drainAsyncWork();
      expect(controller.state.diagnostic, 'Agent status changed');
    },
  );

  test(
    'loads and merges the next thread-list page for the active lane',
    () async {
      final harness = await _createSubAgentHarness(
        agent: _PaginatedThreadAgent(),
      );
      harness.controller.backToThreadList();
      await _waitUntil(
        () => harness.controller.state.screen == AppScreen.threads,
      );

      await harness.controller.loadMoreThreads();

      expect(
        harness.controller.state.agentThreadLists.values.single.map(
          (thread) => thread.id,
        ),
        <String>['root-thread', 'child-thread'],
      );
      expect(harness.controller.activeThreadListHasMore, isFalse);
    },
  );

  test('waits for initialization before applying a profile save', () async {
    final store = _GatedLoadProfileStore();
    final connections = ServerConnectionManager();
    final controller = AppController(store, connections);
    addTearDown(() async {
      controller.dispose();
      await connections.close();
    });

    final pendingSave = controller.saveProfile(_secondProfile);
    await Future<void>.delayed(Duration.zero);
    expect(store.writes, isEmpty);

    store.loadResult.complete(
      const StoredProfiles(
        profiles: [_firstProfile],
        selectedProfileId: 'first',
      ),
    );
    await pendingSave;

    expect(store.value.profiles.map((profile) => profile.id), [
      'first',
      'second',
    ]);
    expect(controller.state.profiles, hasLength(2));
  });

  test('serializes writes so an older snapshot cannot finish last', () async {
    final store = _BlockingFirstSaveProfileStore(const StoredProfiles());
    final connections = ServerConnectionManager();
    final controller = AppController(store, connections);
    addTearDown(() async {
      controller.dispose();
      await connections.close();
    });
    await _waitUntilInitialized(controller);

    final firstSave = controller.saveProfile(_firstProfile);
    await store.firstSaveStarted.future;
    final secondSave = controller.saveProfile(_secondProfile);
    await Future<void>.delayed(Duration.zero);

    expect(store.saveCalls, 1);
    expect(store.maximumActiveSaves, 1);

    store.releaseFirstSave.complete();
    await Future.wait([firstSave, secondSave]);

    expect(store.saveCalls, 2);
    expect(store.maximumActiveSaves, 1);
    expect(store.value.profiles.map((profile) => profile.id), [
      'first',
      'second',
    ]);
  });

  test('deleting a profile removes only its scoped persisted data', () async {
    final store = _MemoryProfileStore(
      StoredProfiles(
        profiles: const [_firstProfile, _secondProfile],
        selectedProfileId: 'first',
        composerDrafts: {
          threadPreferenceKey('first', AgentKind.codex, 'thread'): 'first',
          'first\u0000legacy-thread': 'legacy',
          threadPreferenceKey('second', AgentKind.codex, 'thread'): 'second',
        },
        threadModelPreferences: {
          threadPreferenceKey('first', AgentKind.openCode, 'thread'):
              const ThreadModelPreference(model: 'first-model'),
          threadPreferenceKey('second', AgentKind.openCode, 'thread'):
              const ThreadModelPreference(model: 'second-model'),
        },
        completedTurnTimings: {
          threadPreferenceKey(
            'first',
            AgentKind.codex,
            'thread',
          ): const TurnTiming(
            threadId: 'thread',
            startedAtMillis: 1,
            completedAtMillis: 2,
          ),
          threadPreferenceKey(
            'second',
            AgentKind.codex,
            'thread',
          ): const TurnTiming(
            threadId: 'thread',
            startedAtMillis: 3,
            completedAtMillis: 4,
          ),
        },
      ),
    );
    final connections = ServerConnectionManager();
    final controller = AppController(store, connections);
    addTearDown(() async {
      controller.dispose();
      await connections.close();
    });
    await _waitUntilInitialized(controller);

    await controller.deleteProfile('first');

    final expectedSecond = normalizeStoredProfiles(
      StoredProfiles(profiles: const [_secondProfile]),
    ).profiles.single;
    expect(store.value.profiles, [expectedSecond]);
    _expectNoProfileData(store.value, 'first');
    expect(
      store.value.composerDrafts.keys.any(
        (key) => key.startsWith('second\u0000'),
      ),
      isTrue,
    );
    expect(
      store.value.threadModelPreferences.keys.any(
        (key) => key.startsWith('second\u0000'),
      ),
      isTrue,
    );
    expect(
      store.value.completedTurnTimings.keys.any(
        (key) => key.startsWith('second\u0000'),
      ),
      isTrue,
    );
  });

  test('connection identity changes clear scoped data atomically', () async {
    final draftKey = threadPreferenceKey('first', AgentKind.codex, 'thread');
    final store = _MemoryProfileStore(
      StoredProfiles(
        profiles: const [_firstProfile],
        selectedProfileId: 'first',
        composerDrafts: {draftKey: 'draft'},
        threadModelPreferences: {
          draftKey: const ThreadModelPreference(model: 'model'),
        },
        completedTurnTimings: {
          draftKey: const TurnTiming(
            threadId: 'thread',
            startedAtMillis: 1,
            completedAtMillis: 2,
          ),
        },
      ),
    );
    final connections = ServerConnectionManager();
    final controller = AppController(store, connections);
    addTearDown(() async {
      controller.dispose();
      await connections.close();
    });
    await _waitUntilInitialized(controller);

    await controller.saveProfile(_firstProfile.copyWith(name: 'Renamed'));
    expect(store.value.composerDrafts[draftKey], 'draft');

    await controller.saveProfile(
      _firstProfile.copyWith(host: 'replacement.example'),
    );

    expect(store.writes.last.profiles.single.host, 'replacement.example');
    expect(store.writes.last.profiles.single.hostFingerprint, isEmpty);
    _expectNoProfileData(store.writes.last, 'first');
  });

  test('fingerprint confirmation keeps newer display-only edits', () async {
    final profile = _firstProfile.copyWith(hostFingerprint: '');
    final store = _MemoryProfileStore(
      StoredProfiles(profiles: [profile], selectedProfileId: profile.id),
    );
    final client = _FingerprintClient();
    final connections = ServerConnectionManager(clientFactory: () => client);
    final controller = AppController(store, connections);
    addTearDown(() async {
      controller.dispose();
      await connections.close();
    });
    await _waitUntilInitialized(controller);

    final pendingConnect = controller.requestConnect(profile);
    await Future<void>.delayed(Duration.zero);
    await controller.saveProfile(profile.copyWith(name: 'Renamed'));
    client.fingerprint.complete('SHA256:verified');
    await pendingConnect;

    expect(controller.state.pendingFingerprint, 'SHA256:verified');
    await controller.confirmFingerprint();

    expect(store.value.profiles.single.name, 'Renamed');
    expect(store.value.profiles.single.hostFingerprint, 'SHA256:verified');
    expect(controller.state.connection.phase, ConnectionPhase.connected);
  });

  test('reflects server metrics and clears them after disconnect', () async {
    const metrics = ServerMetrics(
      cpuPercent: 28,
      memoryPercent: 46,
      diskPercent: 64,
      sampledAtEpochMillis: 123,
    );
    final store = _MemoryProfileStore(
      const StoredProfiles(
        profiles: [_firstProfile],
        selectedProfileId: 'first',
      ),
    );
    final client = _FingerprintClient(metrics: metrics);
    final connections = ServerConnectionManager(clientFactory: () => client);
    final controller = AppController(store, connections);
    addTearDown(() async {
      controller.dispose();
      await connections.close();
    });
    await _waitUntilInitialized(controller);
    await controller.requestConnect(_firstProfile);

    await controller.refreshServerMetrics(_firstProfile.id);

    expect(client.metricsReadCount, 1);
    expect(controller.state.serverMetrics[_firstProfile.id], metrics);

    await controller.disconnectProfile(_firstProfile.id);
    expect(controller.state.serverMetrics, isNot(contains(_firstProfile.id)));
  });

  test('retains server metrics across an automatic reconnect', () async {
    const metrics = ServerMetrics(
      cpuPercent: 31,
      memoryPercent: 52,
      diskPercent: 67,
      sampledAtEpochMillis: 456,
    );
    final store = _MemoryProfileStore(
      const StoredProfiles(
        profiles: [_firstProfile],
        selectedProfileId: 'first',
      ),
    );
    final host = _ReconnectableHost(metrics: metrics);
    final connections = ServerConnectionManager(clientFactory: () => host);
    final agent = _FailingTurnAgent();
    final agents = AgentConnectionManager(
      connections,
      clientFactory: (kind) => agent,
    );
    final controller = AppController(
      store,
      connections,
      agents,
      null,
      const <Duration>[Duration.zero],
    );
    addTearDown(() async {
      controller.dispose();
      await agents.close();
      await connections.close();
    });
    await _waitUntilInitialized(controller);
    await controller.requestConnect(_firstProfile);
    await _waitUntil(
      () =>
          agent.listThreadsCount == 1 &&
          controller.state.agentLoadingStates[const AgentConnectionKey(
                profileId: 'first',
                agent: AgentKind.codex,
              )] ==
              false,
    );
    await controller.refreshServerMetrics(_firstProfile.id);
    expect(controller.state.serverMetrics[_firstProfile.id], metrics);

    host.drop(StateError('network switched'));
    await _waitUntil(
      () =>
          host.connectCount == 2 &&
          controller.state.connectionStates[_firstProfile.id]?.phase ==
              ConnectionPhase.connected,
    );
    expect(controller.state.serverMetrics[_firstProfile.id], metrics);
    expect(
      agent.listThreadsCount,
      1,
      reason: 'a cached thread list must not reload after background recovery',
    );

    await controller.disconnectProfile(_firstProfile.id);
    expect(controller.state.serverMetrics, isNot(contains(_firstProfile.id)));
  });

  test('keeps metrics failures out of the app-level error', () async {
    final store = _MemoryProfileStore(
      const StoredProfiles(
        profiles: [_firstProfile],
        selectedProfileId: 'first',
      ),
    );
    final client = _FingerprintClient(metricsError: StateError('资源采样失败'));
    final connections = ServerConnectionManager(clientFactory: () => client);
    final controller = AppController(store, connections);
    addTearDown(() async {
      controller.dispose();
      await connections.close();
    });
    await _waitUntilInitialized(controller);
    await controller.requestConnect(_firstProfile);

    await controller.refreshServerMetrics(_firstProfile.id);

    expect(controller.state.connection.phase, ConnectionPhase.connected);
    expect(controller.state.error, isNull);
    expect(
      controller.state.serverMetrics[_firstProfile.id]?.error,
      contains('资源采样失败'),
    );
  });

  test('stops Agent before SSH and unblocks a host-bound Agent', () async {
    final store = _MemoryProfileStore(
      const StoredProfiles(
        profiles: [_firstProfile],
        selectedProfileId: 'first',
      ),
    );
    final host = _FingerprintClient();
    final connections = ServerConnectionManager(clientFactory: () => host);
    final agent = _HostBoundDisconnectAgent();
    final agents = AgentConnectionManager(
      connections,
      clientFactory: (kind) => agent,
    );
    final controller = AppController(store, connections, agents);
    addTearDown(() async {
      controller.dispose();
      await agents.close();
      await connections.close();
    });
    await _waitUntilInitialized(controller);
    await controller.requestConnect(_firstProfile);
    await agents.connect(_firstProfile, AgentKind.codex);

    await controller
        .disconnectProfile(_firstProfile.id)
        .timeout(const Duration(seconds: 1));

    expect(agent.hostWasConnectedWhenDisconnectStarted, isTrue);
    expect(host.isConnected, isFalse);
    expect(agent.isConnected, isFalse);
    expect(
      controller.state.connectionStates[_firstProfile.id]?.phase,
      ConnectionPhase.disconnected,
    );
  });

  test(
    'host loss automatically reconnects and ignores the stale Agent load',
    () async {
      final store = _MemoryProfileStore(
        const StoredProfiles(
          profiles: [_firstProfile],
          selectedProfileId: 'first',
        ),
      );
      final host = _ReconnectableHost();
      final connections = ServerConnectionManager(clientFactory: () => host);
      final agent = _BlockingThreadListAgent();
      final agents = AgentConnectionManager(
        connections,
        clientFactory: (kind) => agent,
      );
      final controller = AppController(store, connections, agents);
      addTearDown(() async {
        controller.dispose();
        await agents.close();
        await connections.close();
      });
      await _waitUntilInitialized(controller);

      await controller.requestConnect(_firstProfile);
      final key = const AgentConnectionKey(
        profileId: 'first',
        agent: AgentKind.codex,
      );
      await _waitUntil(
        () =>
            agent.threadListCalls == 1 &&
            controller.state.agentLoadingStates[key] == true,
      );

      host.drop(StateError('network switched'));
      await _waitUntil(
        () =>
            host.connectCount == 2 &&
            agent.connectCount == 2 &&
            agent.threadListCalls == 2 &&
            controller.state.connectionStates[_firstProfile.id]?.phase ==
                ConnectionPhase.connected &&
            controller.state.agentLoadingStates[key] == false &&
            !controller.state.loading,
      );

      expect(agent.disconnectCount, greaterThanOrEqualTo(1));
      expect(controller.state.agentLoadingStates[key], isFalse);
      expect(controller.state.threads, [_FailingTurnAgent.thread]);
      expect(controller.state.error, isNull);

      agent.firstThreadList.complete(
        const AgentThreadPage(
          threads: <AgentThread>[
            AgentThread(id: 'stale', title: 'Stale result'),
          ],
        ),
      );
      await _drainAsyncWork();

      expect(controller.state.threads, [_FailingTurnAgent.thread]);
      expect(controller.state.agentLoadingStates[key], isFalse);
      expect(controller.state.error, isNull);
    },
  );

  test(
    'sticky service restart restores SSH and Agent while headless',
    () async {
      final store = _MemoryProfileStore(
        const StoredProfiles(
          profiles: [_firstProfile],
          selectedProfileId: 'first',
        ),
      );
      final host = _ReconnectableHost();
      final connections = ServerConnectionManager(clientFactory: () => host);
      final agent = _FailingTurnAgent();
      final agents = AgentConnectionManager(
        connections,
        clientFactory: (kind) => agent,
      );
      final controller = AppController(
        store,
        connections,
        agents,
        null,
        const <Duration>[Duration.zero],
        const BackgroundConnectionIntent(
          hostProfileIds: <String>['first'],
          agentConnectionKeys: <String>['first\u0000codex'],
        ),
      );
      addTearDown(() async {
        controller.dispose();
        await agents.close();
        await connections.close();
      });

      await _waitUntil(
        () =>
            host.connectCount == 1 &&
            agent.connectCount == 1 &&
            controller.state.connectionStates['first']?.phase ==
                ConnectionPhase.connected &&
            controller
                    .state
                    .agentConnectionStates[const AgentConnectionKey(
                      profileId: 'first',
                      agent: AgentKind.codex,
                    )]
                    ?.phase ==
                ConnectionPhase.connected,
      );

      expect(controller.state.screen, AppScreen.servers);
      expect(controller.backgroundConnectionIntent.hostProfileIds, ['first']);
      expect(controller.backgroundConnectionIntent.agentConnectionKeys, [
        'first\u0000codex',
      ]);

      await controller.disconnectProfile('first');
      expect(controller.backgroundConnectionIntent.isEmpty, isTrue);
    },
  );

  test(
    'host loss reconnects the Agent and resumes the visible thread',
    () async {
      final store = _MemoryProfileStore(
        const StoredProfiles(
          profiles: [_firstProfile],
          selectedProfileId: 'first',
        ),
      );
      final host = _ReconnectableHost();
      final connections = ServerConnectionManager(clientFactory: () => host);
      final agent = _FailingTurnAgent();
      final agents = AgentConnectionManager(
        connections,
        clientFactory: (kind) => agent,
      );
      final controller = AppController(
        store,
        connections,
        agents,
        null,
        const <Duration>[Duration.zero],
      );
      addTearDown(() async {
        controller.dispose();
        await agents.close();
        await connections.close();
      });
      await _waitUntilInitialized(controller);

      await controller.requestConnect(_firstProfile);
      final key = const AgentConnectionKey(
        profileId: 'first',
        agent: AgentKind.codex,
      );
      await _waitUntil(
        () =>
            controller.state.agentConnectionStates[key]?.phase ==
                ConnectionPhase.connected &&
            controller.state.agentLoadingStates[key] == false,
      );
      controller.openThread(_FailingTurnAgent.thread);
      await _waitUntil(
        () =>
            controller.state.screen == AppScreen.work &&
            controller.state.activeThread?.id == _FailingTurnAgent.thread.id &&
            agent.resumeCalls == 1 &&
            !controller.state.loading,
      );

      host.drop(StateError('mobile network changed'));

      await _waitUntil(
        () =>
            host.connectCount == 2 &&
            agent.connectCount == 2 &&
            agent.resumeCalls == 2 &&
            controller.state.connectionStates[_firstProfile.id]?.phase ==
                ConnectionPhase.connected &&
            controller.state.agentConnectionStates[key]?.phase ==
                ConnectionPhase.connected &&
            !controller.state.loading,
      );
      expect(controller.state.screen, AppScreen.work);
      expect(controller.state.activeThread?.id, _FailingTurnAgent.thread.id);
      expect(controller.state.timeline, _FailingTurnAgent.initialTimeline);
      expect(controller.state.error, isNull);

      await controller.disconnectProfile(_firstProfile.id);
      await _drainAsyncWork();
      expect(
        host.connectCount,
        2,
        reason: 'explicit disconnect must cancel recovery',
      );
      expect(
        controller.state.connectionStates[_firstProfile.id]?.phase,
        ConnectionPhase.disconnected,
      );
    },
  );

  test(
    'restores draft and uploaded attachment when starting a turn fails',
    () async {
      final store = _MemoryProfileStore(
        const StoredProfiles(
          profiles: [_firstProfile],
          selectedProfileId: 'first',
        ),
      );
      final host = _AttachmentHost();
      final connections = ServerConnectionManager(clientFactory: () => host);
      final agent = _FailingTurnAgent();
      final agents = AgentConnectionManager(
        connections,
        clientFactory: (kind) => agent,
      );
      final controller = AppController(store, connections, agents);
      addTearDown(() async {
        controller.dispose();
        await agents.close();
        await connections.close();
      });
      await _waitUntilInitialized(controller);
      await controller.requestConnect(_firstProfile);
      await controller.ensureActiveAgent();

      controller.openThread(_FailingTurnAgent.thread);
      await _waitUntil(
        () =>
            controller.state.activeThread?.id == _FailingTurnAgent.thread.id &&
            !controller.state.loading,
      );

      const attachmentText = 'alpha\nbeta';
      final attachmentBytes = Uint8List.fromList(attachmentText.codeUnits);
      await controller.uploadAttachments([
        LocalAttachmentUpload(
          name: 'notes.txt',
          bytes: attachmentBytes,
          mimeType: 'text/plain',
          textContent: attachmentText,
        ),
      ]);

      expect(host.uploadedName, 'notes.txt');
      expect(host.uploadedBytes, orderedEquals(attachmentBytes));
      expect(host.uploadedMaxBytes, maxInlineTextAttachmentBytes);
      expect(controller.state.attachmentUploading, isFalse);
      expect(controller.state.attachments, const <PendingAttachment>[
        PendingAttachment(
          name: 'notes.txt',
          remotePath: _AttachmentHost.remotePath,
          mimeType: 'text/plain',
          textContent: attachmentText,
        ),
      ]);

      const draft = 'Inspect the attachment   ';
      controller.setComposerDraft(draft);
      await controller.sendMessage();

      expect(agent.startedThreadId, _FailingTurnAgent.thread.id);
      expect(agent.startedText, 'Inspect the attachment');
      expect(agent.startedAttachments, controller.state.attachments);
      expect(
        agent.startedAttachments?.single.remotePath,
        _AttachmentHost.remotePath,
      );
      expect(agent.startedAttachments?.single.textContent, attachmentText);
      expect(agent.startedModel, isNull);
      expect(agent.startedEffort, isNull);
      expect(agent.startedApprovalMode, ApprovalMode.requestApproval);
      expect(agent.startedSandbox, SandboxChoice.workspaceWrite);
      expect(agent.startedCwd, _FailingTurnAgent.thread.cwd);

      expect(controller.state.attachmentUploading, isFalse);
      expect(controller.state.submitting, isFalse);
      expect(controller.state.running, isFalse);
      expect(controller.state.composerDraft, draft);
      expect(controller.state.attachments, hasLength(1));
      expect(controller.state.timeline, _FailingTurnAgent.initialTimeline);
      expect(
        controller.state.timeline.where(
          (entry) => entry.id.startsWith('local-user-'),
        ),
        isEmpty,
      );
      expect(controller.state.error, contains('模型暂时不可用'));

      final draftKey = threadPreferenceKey(
        _firstProfile.id,
        AgentKind.codex,
        _FailingTurnAgent.thread.id,
      );
      await _waitUntil(() => store.value.composerDrafts[draftKey] == draft);
    },
  );

  test('steers an active turn without starting a replacement turn', () async {
    final store = _MemoryProfileStore(
      const StoredProfiles(
        profiles: [_firstProfile],
        selectedProfileId: 'first',
      ),
    );
    final host = _AttachmentHost();
    final connections = ServerConnectionManager(clientFactory: () => host);
    final agent = _SteeringAgent();
    final agents = AgentConnectionManager(
      connections,
      clientFactory: (kind) => agent,
    );
    final controller = AppController(store, connections, agents);
    addTearDown(() async {
      controller.dispose();
      await agents.close();
      await connections.close();
    });
    await _waitUntilInitialized(controller);
    await controller.requestConnect(_firstProfile);
    await controller.ensureActiveAgent();

    controller.openThread(_SteeringAgent.activeThread);
    await _waitUntil(
      () =>
          controller.state.activeThread?.id == _SteeringAgent.activeThread.id &&
          !controller.state.loading,
    );
    expect(controller.state.running, isTrue);
    expect(controller.state.activeTurnId, 'turn-running');

    controller.setComposerDraft('Continue with tests');
    await controller.sendMessage();

    expect(agent.steeredThreadId, _SteeringAgent.activeThread.id);
    expect(agent.steeredTurnId, 'turn-running');
    expect(agent.steeredText, 'Continue with tests');
    expect(agent.steeredAttachments, isEmpty);
    expect(agent.startedThreadId, isNull);
    expect(controller.state.submitting, isFalse);
    expect(controller.state.running, isTrue);
    expect(controller.state.activeTurnId, 'turn-running');
    expect(controller.state.timeline.last.text, 'Continue with tests');
  });

  test('marks the active turn as stopped after interrupt succeeds', () async {
    final store = _MemoryProfileStore(
      const StoredProfiles(
        profiles: [_firstProfile],
        selectedProfileId: 'first',
      ),
    );
    final host = _AttachmentHost();
    final connections = ServerConnectionManager(clientFactory: () => host);
    final agent = _SteeringAgent();
    final agents = AgentConnectionManager(
      connections,
      clientFactory: (kind) => agent,
    );
    final controller = AppController(store, connections, agents);
    addTearDown(() async {
      controller.dispose();
      await agents.close();
      await connections.close();
    });
    await _waitUntilInitialized(controller);
    await controller.requestConnect(_firstProfile);
    await controller.ensureActiveAgent();

    controller.openThread(_SteeringAgent.activeThread);
    await _waitUntil(
      () =>
          controller.state.activeThread?.id == _SteeringAgent.activeThread.id &&
          !controller.state.loading,
    );

    await controller.stopMessage();

    expect(agent.interruptedThreadId, _SteeringAgent.activeThread.id);
    expect(agent.interruptedTurnId, 'turn-running');
    expect(controller.state.turnTiming?.stopped, isTrue);
    expect(controller.state.turnTiming?.completedAtMillis, isNull);
  });

  test(
    'shows the workspace picker once after connect and persists the prompt flag',
    () async {
      final store = _MemoryProfileStore(
        const StoredProfiles(
          profiles: [_firstProfile],
          selectedProfileId: 'first',
        ),
      );
      final host = _WorkspaceHost();
      final connections = ServerConnectionManager(clientFactory: () => host);
      final agents = AgentConnectionManager(
        connections,
        clientFactory: (kind) => _FailingTurnAgent(),
      );
      final controller = AppController(store, connections, agents);
      addTearDown(() async {
        controller.dispose();
        await agents.close();
        await connections.close();
      });
      await _waitUntilInitialized(controller);

      await controller.requestConnect(_firstProfile);
      await _waitUntil(() => host.directoryRequests.isNotEmpty);

      expect(host.directoryRequests.single.path, isNull);
      expect(controller.state.workspacePickerVisible, isTrue);
      expect(controller.state.workspaceLoading, isTrue);
      expect(controller.state.profiles.single.workspacePromptShown, isTrue);
      await _waitUntil(() => store.value.profiles.single.workspacePromptShown);
      expect(store.value.profiles.single.workspacePromptShown, isTrue);

      host.directoryRequests.single.result.complete(
        const RemoteDirectoryListing(
          currentPath: '/home/root',
          parentPath: '/home',
        ),
      );
      await _waitUntil(() => !controller.state.workspaceLoading);
      controller.dismissWorkspacePicker();
      await _waitUntil(() => !controller.state.workspacePickerVisible);

      expect(store.value.profiles.single.workspacePromptShown, isTrue);
      await controller.ensureActiveAgent();
      await Future<void>.delayed(Duration.zero);
      expect(host.directoryRequests, hasLength(1));
    },
  );

  test(
    'does not consume the workspace prompt when Agent connect fails',
    () async {
      final store = _MemoryProfileStore(
        const StoredProfiles(
          profiles: [_firstProfile],
          selectedProfileId: 'first',
        ),
      );
      final host = _WorkspaceHost();
      final connections = ServerConnectionManager(clientFactory: () => host);
      final agents = AgentConnectionManager(
        connections,
        clientFactory: (kind) => _ConnectFailingAgent(),
      );
      final controller = AppController(store, connections, agents);
      addTearDown(() async {
        controller.dispose();
        await agents.close();
        await connections.close();
      });
      await _waitUntilInitialized(controller);

      await controller.requestConnect(_firstProfile);
      await controller.ensureActiveAgent();

      expect(controller.state.profiles.single.workspacePromptShown, isFalse);
      expect(store.value.profiles.single.workspacePromptShown, isFalse);
      expect(controller.state.workspacePickerVisible, isFalse);
      expect(host.directoryRequests, isEmpty);
    },
  );

  test(
    'configured workspace consumes the prompt flag without opening',
    () async {
      final profile = _firstProfile.copyWith(workspace: '/srv/project');
      final store = _MemoryProfileStore(
        StoredProfiles(profiles: [profile], selectedProfileId: profile.id),
      );
      final host = _WorkspaceHost();
      final connections = ServerConnectionManager(clientFactory: () => host);
      final agents = AgentConnectionManager(
        connections,
        clientFactory: (kind) => _FailingTurnAgent(),
      );
      final controller = AppController(store, connections, agents);
      addTearDown(() async {
        controller.dispose();
        await agents.close();
        await connections.close();
      });
      await _waitUntilInitialized(controller);

      await controller.requestConnect(profile);
      await controller.ensureActiveAgent();
      await _waitUntil(() => store.value.profiles.single.workspacePromptShown);

      expect(controller.state.workspacePickerVisible, isFalse);
      expect(controller.state.workspaceLoading, isFalse);
      expect(host.directoryRequests, isEmpty);
    },
  );

  test(
    'workspace listing failure consumes the prompt and exposes the error',
    () async {
      final store = _MemoryProfileStore(
        const StoredProfiles(
          profiles: [_firstProfile],
          selectedProfileId: 'first',
        ),
      );
      final host = _WorkspaceHost();
      final connections = ServerConnectionManager(clientFactory: () => host);
      final agents = AgentConnectionManager(
        connections,
        clientFactory: (kind) => _FailingTurnAgent(),
      );
      final controller = AppController(store, connections, agents);
      addTearDown(() async {
        controller.dispose();
        await agents.close();
        await connections.close();
      });
      await _waitUntilInitialized(controller);

      await controller.requestConnect(_firstProfile);
      await _waitUntil(() => host.directoryRequests.isNotEmpty);
      host.directoryRequests.single.result.completeError(StateError('目录读取失败'));
      await _waitUntil(() => !controller.state.workspaceLoading);

      expect(controller.state.workspacePickerVisible, isTrue);
      expect(controller.state.workspaceError, contains('目录读取失败'));
      expect(controller.state.profiles.single.workspacePromptShown, isTrue);
      await _waitUntil(() => store.value.profiles.single.workspacePromptShown);
    },
  );

  test('does not roll back a persisted workspace prompt flag', () async {
    final profile = _firstProfile.copyWith(workspacePromptShown: true);
    final store = _MemoryProfileStore(
      StoredProfiles(profiles: [profile], selectedProfileId: profile.id),
    );
    final connections = ServerConnectionManager();
    final controller = AppController(store, connections);
    addTearDown(() async {
      controller.dispose();
      await connections.close();
    });
    await _waitUntilInitialized(controller);

    final saved = await controller.saveProfile(
      profile.copyWith(name: 'Renamed', workspacePromptShown: false),
    );

    expect(saved.workspacePromptShown, isTrue);
    expect(controller.state.profiles.single.workspacePromptShown, isTrue);
    expect(store.value.profiles.single.workspacePromptShown, isTrue);
  });

  test(
    'consumes the prompt flag without opening when workspace is saved',
    () async {
      final profile = _firstProfile.copyWith(workspace: '/srv/project');
      final store = _MemoryProfileStore(
        StoredProfiles(profiles: [profile], selectedProfileId: profile.id),
      );
      final host = _WorkspaceHost();
      final connections = ServerConnectionManager(clientFactory: () => host);
      final agents = AgentConnectionManager(
        connections,
        clientFactory: (kind) => _FailingTurnAgent(),
      );
      final controller = AppController(store, connections, agents);
      addTearDown(() async {
        controller.dispose();
        await agents.close();
        await connections.close();
      });
      await _waitUntilInitialized(controller);

      await controller.requestConnect(profile);
      await controller.ensureActiveAgent();
      await _waitUntil(() => store.value.profiles.single.workspacePromptShown);

      expect(controller.state.workspacePickerVisible, isFalse);
      expect(controller.state.profiles.single.workspacePromptShown, isTrue);
      expect(host.directoryRequests, isEmpty);
    },
  );

  test('only applies the latest workspace browse result', () async {
    final profile = _firstProfile.copyWith(workspacePromptShown: true);
    final store = _MemoryProfileStore(
      StoredProfiles(profiles: [profile], selectedProfileId: profile.id),
    );
    final host = _WorkspaceHost();
    final connections = ServerConnectionManager(clientFactory: () => host);
    final agents = AgentConnectionManager(
      connections,
      clientFactory: (kind) => _FailingTurnAgent(),
    );
    final controller = AppController(store, connections, agents);
    addTearDown(() async {
      controller.dispose();
      await agents.close();
      await connections.close();
    });
    await _waitUntilInitialized(controller);
    await controller.requestConnect(profile);
    await controller.ensureActiveAgent();

    final firstBrowse = controller.browseWorkspace('/srv/first');
    await _waitUntil(() => host.directoryRequests.length == 1);
    final secondBrowse = controller.browseWorkspace('/srv/second');
    await _waitUntil(() => host.directoryRequests.length == 2);
    host.directoryRequests[1].result.complete(
      const RemoteDirectoryListing(
        currentPath: '/srv/second',
        directories: <RemoteDirectory>[
          RemoteDirectory(name: 'latest', path: '/srv/second/latest'),
        ],
      ),
    );
    await secondBrowse;
    host.directoryRequests[0].result.complete(
      const RemoteDirectoryListing(
        currentPath: '/srv/first',
        directories: <RemoteDirectory>[
          RemoteDirectory(name: 'stale', path: '/srv/first/stale'),
        ],
      ),
    );
    await firstBrowse;

    expect(controller.state.workspaceCurrentPath, '/srv/second');
    expect(controller.state.workspaceDirectories.single.name, 'latest');
  });

  test('drops a workspace listing after switching profiles', () async {
    final first = _firstProfile.copyWith(workspacePromptShown: true);
    final second = _secondProfile.copyWith(workspacePromptShown: true);
    final store = _MemoryProfileStore(
      StoredProfiles(profiles: [first, second], selectedProfileId: first.id),
    );
    final firstHost = _WorkspaceHost();
    final secondHost = _WorkspaceHost();
    final hosts = <_WorkspaceHost>[firstHost, secondHost];
    var hostIndex = 0;
    final connections = ServerConnectionManager(
      clientFactory: () => hosts[hostIndex++],
    );
    final agents = AgentConnectionManager(
      connections,
      clientFactory: (kind) => _FailingTurnAgent(),
    );
    final controller = AppController(store, connections, agents);
    addTearDown(() async {
      controller.dispose();
      await agents.close();
      await connections.close();
    });
    await _waitUntilInitialized(controller);
    await controller.requestConnect(first);
    await controller.ensureActiveAgent();

    final pendingBrowse = controller.browseWorkspace('/stale-request');
    await _waitUntil(() => firstHost.directoryRequests.isNotEmpty);
    controller.selectProfile(second.id);
    await _waitUntil(() => controller.state.selectedProfileId == second.id);

    firstHost.directoryRequests.single.result.complete(
      const RemoteDirectoryListing(
        currentPath: '/stale-result',
        directories: <RemoteDirectory>[
          RemoteDirectory(name: 'old', path: '/stale-result/old'),
        ],
      ),
    );
    await pendingBrowse;

    expect(controller.state.selectedProfileId, second.id);
    expect(controller.state.workspacePickerVisible, isFalse);
    expect(controller.state.workspaceCurrentPath, isNot('/stale-result'));
    expect(controller.state.workspaceDirectories, isEmpty);
  });

  test('drops a workspace listing after dismissing the picker', () async {
    final profile = _firstProfile.copyWith(workspacePromptShown: true);
    final store = _MemoryProfileStore(
      StoredProfiles(profiles: [profile], selectedProfileId: profile.id),
    );
    final host = _WorkspaceHost();
    final connections = ServerConnectionManager(clientFactory: () => host);
    final agents = AgentConnectionManager(
      connections,
      clientFactory: (kind) => _FailingTurnAgent(),
    );
    final controller = AppController(store, connections, agents);
    addTearDown(() async {
      controller.dispose();
      await agents.close();
      await connections.close();
    });
    await _waitUntilInitialized(controller);
    await controller.requestConnect(profile);
    await controller.ensureActiveAgent();

    final pendingBrowse = controller.browseWorkspace(null);
    await _waitUntil(() => host.directoryRequests.isNotEmpty);
    expect(host.directoryRequests.single.path, isNull);
    expect(controller.state.workspacePickerVisible, isTrue);

    controller.dismissWorkspacePicker();
    expect(controller.state.workspacePickerVisible, isFalse);
    expect(controller.state.workspaceLoading, isFalse);
    host.directoryRequests.single.result.complete(
      const RemoteDirectoryListing(
        currentPath: '/late-result',
        directories: <RemoteDirectory>[
          RemoteDirectory(name: 'late', path: '/late-result/late'),
        ],
      ),
    );
    await pendingBrowse;

    expect(controller.state.workspacePickerVisible, isFalse);
    expect(controller.state.workspaceCurrentPath, isNot('/late-result'));
    expect(controller.state.workspaceDirectories, isEmpty);
  });

  test('only applies the latest workspace browse result', () async {
    final profile = _firstProfile.copyWith(workspacePromptShown: true);
    final store = _MemoryProfileStore(
      StoredProfiles(profiles: [profile], selectedProfileId: profile.id),
    );
    final host = _WorkspaceHost();
    final connections = ServerConnectionManager(clientFactory: () => host);
    final agents = AgentConnectionManager(
      connections,
      clientFactory: (kind) => _FailingTurnAgent(),
    );
    final controller = AppController(store, connections, agents);
    addTearDown(() async {
      controller.dispose();
      await agents.close();
      await connections.close();
    });
    await _waitUntilInitialized(controller);
    await controller.requestConnect(profile);
    await controller.ensureActiveAgent();

    final firstBrowse = controller.browseWorkspace('/first');
    await _waitUntil(() => host.directoryRequests.length == 1);
    final secondBrowse = controller.browseWorkspace('/second');
    await _waitUntil(() => host.directoryRequests.length == 2);
    host.directoryRequests[1].result.complete(
      const RemoteDirectoryListing(currentPath: '/second-result'),
    );
    await secondBrowse;
    host.directoryRequests[0].result.complete(
      const RemoteDirectoryListing(currentPath: '/stale-first-result'),
    );
    await firstBrowse;

    expect(controller.state.workspaceCurrentPath, '/second-result');
    expect(controller.state.workspaceLoading, isFalse);
  });

  test('does not confirm a workspace while its listing is loading', () async {
    final store = _MemoryProfileStore(
      const StoredProfiles(
        profiles: [_firstProfile],
        selectedProfileId: 'first',
      ),
    );
    final host = _WorkspaceHost();
    final connections = ServerConnectionManager(clientFactory: () => host);
    final agents = AgentConnectionManager(
      connections,
      clientFactory: (kind) => _FailingTurnAgent(),
    );
    final controller = AppController(store, connections, agents);
    addTearDown(() async {
      controller.dispose();
      await agents.close();
      await connections.close();
    });
    await _waitUntilInitialized(controller);

    await controller.requestConnect(_firstProfile);
    await _waitUntil(() => host.directoryRequests.isNotEmpty);
    await controller.confirmWorkspace();

    expect(controller.state.workspacePickerVisible, isTrue);
    expect(controller.state.workspaceLoading, isTrue);
    expect(store.value.profiles.single.workspace, isEmpty);
    host.directoryRequests.single.result.complete(
      const RemoteDirectoryListing(currentPath: '/home/root'),
    );
    await _waitUntil(() => !controller.state.workspaceLoading);
  });

  test('confirms the listed workspace and closes the picker', () async {
    final profile = _firstProfile.copyWith(
      workspace: '/srv/original',
      workspacePromptShown: true,
    );
    final store = _MemoryProfileStore(
      StoredProfiles(profiles: [profile], selectedProfileId: profile.id),
    );
    final host = _WorkspaceHost();
    final connections = ServerConnectionManager(clientFactory: () => host);
    final agents = AgentConnectionManager(
      connections,
      clientFactory: (kind) => _FailingTurnAgent(),
    );
    final controller = AppController(store, connections, agents);
    addTearDown(() async {
      controller.dispose();
      await agents.close();
      await connections.close();
    });
    await _waitUntilInitialized(controller);
    await controller.requestConnect(profile);
    await controller.ensureActiveAgent();

    final pendingPicker = controller.showWorkspacePicker();
    await _waitUntil(() => host.directoryRequests.isNotEmpty);
    expect(host.directoryRequests.single.path, '/srv/original');
    host.directoryRequests.single.result.complete(
      const RemoteDirectoryListing(
        currentPath: '/srv/project',
        parentPath: '/srv',
        directories: <RemoteDirectory>[
          RemoteDirectory(name: 'lib', path: '/srv/project/lib'),
        ],
      ),
    );
    await pendingPicker;

    expect(controller.state.workspaceCurrentPath, '/srv/project');
    expect(controller.state.workspaceDirectories.single.name, 'lib');
    controller.confirmWorkspace();
    await _waitUntil(
      () => store.value.profiles.single.workspace == '/srv/project',
    );

    expect(controller.state.workspacePickerVisible, isFalse);
    expect(controller.state.profiles.single.workspace, '/srv/project');
    expect(store.value.profiles.single.workspacePromptShown, isTrue);
  });

  test(
    'opens and browses the SFTP file manager for the connected profile',
    () async {
      final profile = _firstProfile.copyWith(
        workspace: '/srv/project',
        workspacePromptShown: true,
      );
      final store = _MemoryProfileStore(
        StoredProfiles(profiles: [profile], selectedProfileId: profile.id),
      );
      final host = _FileManagerHost();
      final connections = ServerConnectionManager(clientFactory: () => host);
      final controller = AppController(store, connections);
      addTearDown(() async {
        controller.dispose();
        await connections.close();
      });
      await _waitUntilInitialized(controller);
      await controller.requestConnect(profile);

      controller.showFileManager();
      await _waitUntil(() => host.listRequests.isNotEmpty);
      expect(controller.state.screen, AppScreen.fileManager);
      expect(host.listRequests.single.path, '/srv/project');
      host.listRequests.single.result.complete(
        const RemoteFileListing(
          currentPath: '/srv/project',
          parentPath: '/srv',
          entries: <RemoteFileEntry>[
            RemoteFileEntry(
              name: 'lib',
              path: '/srv/project/lib',
              kind: RemoteFileKind.directory,
            ),
          ],
        ),
      );
      await _waitUntil(() => !controller.state.fileManagerLoading);

      expect(controller.state.fileManagerCurrentPath, '/srv/project');
      expect(controller.state.fileManagerEntries.single.name, 'lib');
      controller.closeFileManager();
      expect(controller.state.screen, AppScreen.threads);
      expect(controller.state.fileManagerProfileId, isNull);
      expect(controller.state.fileManagerEntries, isEmpty);
    },
  );

  test('drops a late file-manager listing after the page closes', () async {
    final profile = _firstProfile.copyWith(workspacePromptShown: true);
    final store = _MemoryProfileStore(
      StoredProfiles(profiles: [profile], selectedProfileId: profile.id),
    );
    final host = _FileManagerHost();
    final connections = ServerConnectionManager(clientFactory: () => host);
    final controller = AppController(store, connections);
    addTearDown(() async {
      controller.dispose();
      await connections.close();
    });
    await _waitUntilInitialized(controller);
    await controller.requestConnect(profile);

    controller.showFileManager();
    await _waitUntil(() => host.listRequests.isNotEmpty);
    controller.closeFileManager();
    host.listRequests.single.result.complete(
      const RemoteFileListing(
        currentPath: '/stale',
        entries: <RemoteFileEntry>[
          RemoteFileEntry(
            name: 'stale.txt',
            path: '/stale/stale.txt',
            kind: RemoteFileKind.file,
          ),
        ],
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.screen, AppScreen.threads);
    expect(controller.state.fileManagerEntries, isEmpty);
    expect(controller.state.fileManagerCurrentPath, isEmpty);
  });

  test(
    'uploads, copies, moves and downloads through file-manager state',
    () async {
      final profile = _firstProfile.copyWith(
        workspace: '/srv',
        workspacePromptShown: true,
      );
      final store = _MemoryProfileStore(
        StoredProfiles(profiles: [profile], selectedProfileId: profile.id),
      );
      final host = _FileManagerHost();
      final connections = ServerConnectionManager(clientFactory: () => host);
      final controller = AppController(store, connections);
      addTearDown(() async {
        controller.dispose();
        await connections.close();
      });
      await _waitUntilInitialized(controller);
      await controller.requestConnect(profile);
      controller.showFileManager();
      await _waitUntil(() => host.listRequests.length == 1);
      const file = RemoteFileEntry(
        name: 'notes.txt',
        path: '/srv/notes.txt',
        kind: RemoteFileKind.file,
        sizeBytes: 3,
      );
      const listing = RemoteFileListing(
        currentPath: '/srv',
        parentPath: '/',
        entries: <RemoteFileEntry>[file],
      );
      host.listRequests[0].result.complete(listing);
      await _waitUntil(() => !controller.state.fileManagerLoading);

      final upload = controller.uploadRemoteFiles(<LocalRemoteFileUpload>[
        LocalRemoteFileUpload(
          name: 'upload.txt',
          sizeBytes: 3,
          chunks: Stream<List<int>>.value(const <int>[1, 2, 3]),
        ),
      ]);
      await _waitUntil(() => host.listRequests.length == 2);
      host.listRequests[1].result.complete(listing);
      await upload;
      expect(host.uploadedDirectory, '/srv');
      expect(host.uploadedName, 'upload.txt');
      expect(host.uploadedBytes, <int>[1, 2, 3]);
      expect(controller.state.diagnostic, '已上传 1 个文件');

      controller.cutRemoteFiles(const <RemoteFileEntry>[file]);
      expect(
        controller.state.fileManagerClipboard?.mode,
        RemoteFileTransferMode.move,
      );
      final paste = controller.pasteRemoteFiles();
      await _waitUntil(() => host.listRequests.length == 3);
      host.listRequests[2].result.complete(listing);
      await paste;
      expect(host.transferredPaths, <String>['/srv/notes.txt']);
      expect(host.transferDestination, '/srv');
      expect(host.transferMode, RemoteFileTransferMode.move);
      expect(controller.state.fileManagerClipboard, isNull);

      host.downloadChunks = <Uint8List>[
        Uint8List.fromList(const <int>[7, 8]),
        Uint8List.fromList(const <int>[9]),
      ];
      final received = <int>[];
      final download = controller.downloadFileManagerFile(
        file.path,
        writeChunk: (chunk) async => received.addAll(chunk),
      );
      await _waitUntil(() => host.listRequests.length == 4);
      host.listRequests[3].result.complete(listing);
      await download;
      expect(received, <int>[7, 8, 9]);
      expect(controller.state.diagnostic, '已保存到本地');
    },
  );

  test('reads global settings including the real server API key', () async {
    final profile = _firstProfile.copyWith(workspacePromptShown: true);
    final store = _MemoryProfileStore(
      StoredProfiles(profiles: [profile], selectedProfileId: profile.id),
    );
    final host = _FingerprintClient();
    final connections = ServerConnectionManager(clientFactory: () => host);
    final agent = _SettingsAgent();
    final agents = AgentConnectionManager(
      connections,
      clientFactory: (kind) => agent,
    );
    final controller = AppController(store, connections, agents);
    addTearDown(() async {
      controller.dispose();
      await agents.close();
      await connections.close();
    });
    await _waitUntilInitialized(controller);
    await controller.requestConnect(profile);
    await controller.ensureActiveAgent();

    await controller.showAgentSettings();

    expect(agent.readCalls, 1);
    expect(controller.state.agentSettingsVisible, isTrue);
    expect(controller.state.agentSettingsLoading, isFalse);
    expect(controller.state.agentSettings?.apiKey, 'sk-server-value');
    expect(controller.state.agentSettings?.modelProvider, 'custom-provider');
  });

  test('fetches API models with the connected server settings', () async {
    final profile = _firstProfile.copyWith(workspacePromptShown: true);
    final store = _MemoryProfileStore(
      StoredProfiles(profiles: [profile], selectedProfileId: profile.id),
    );
    final host = _FingerprintClient();
    final connections = ServerConnectionManager(clientFactory: () => host);
    final agent = _SettingsAgent()
      ..apiModelList = const <ApiModelOption>[
        ApiModelOption(modelId: 'gpt-api-model', contextWindowTokens: 128000),
      ];
    final agents = AgentConnectionManager(
      connections,
      clientFactory: (kind) => agent,
    );
    final controller = AppController(store, connections, agents);
    addTearDown(() async {
      controller.dispose();
      await agents.close();
      await connections.close();
    });
    await _waitUntilInitialized(controller);
    await controller.requestConnect(profile);
    await controller.ensureActiveAgent();

    await controller.fetchApiModelOptions();

    expect(agent.readCalls, 1);
    expect(agent.fetchApiModelsCalls, 1);
    expect(agent.fetchedBaseUrl, agent.readValue.baseUrl);
    expect(agent.fetchedApiKey, 'sk-server-value');
    expect(agent.fetchedProxyUrl, 'http://127.0.0.1:7890');
    expect(controller.state.apiModelOptions.single.modelId, 'gpt-api-model');
    expect(controller.state.apiModelOptionsLoading, isFalse);
    expect(controller.state.apiModelOptionsError, isNull);
  });

  test('persists custom models and rebuilds the visible catalog', () async {
    final profile = _firstProfile.copyWith(workspacePromptShown: true);
    final store = _MemoryProfileStore(
      StoredProfiles(profiles: [profile], selectedProfileId: profile.id),
    );
    final host = _FingerprintClient();
    final connections = ServerConnectionManager(clientFactory: () => host);
    final agent = _SettingsAgent()
      ..modelList = const <AgentModel>[
        AgentModel(id: 'remote-a', model: 'remote-a', displayName: 'Remote A'),
        AgentModel(id: 'remote-b', model: 'remote-b', displayName: 'Remote B'),
      ];
    final agents = AgentConnectionManager(
      connections,
      clientFactory: (kind) => agent,
    );
    final controller = AppController(store, connections, agents);
    addTearDown(() async {
      controller.dispose();
      await agents.close();
      await connections.close();
    });
    await _waitUntilInitialized(controller);
    await controller.requestConnect(profile);
    await controller.ensureActiveAgent();
    await _waitUntil(() => controller.state.models.length == 2);

    controller.saveCustomModel(
      null,
      const CustomModelDefinition(
        modelId: 'remote-a',
        displayName: 'Custom A',
        contextWindowTokens: 200000,
        maxOutputTokens: 32000,
        apiProtocol: ModelApiProtocol.responses,
      ),
    );
    await _waitUntil(
      () => store.value.profiles.single
          .modelSettings(AgentKind.codex)
          .customModels
          .isNotEmpty,
    );

    final custom = controller.state.models.firstWhere(
      (model) => model.model == 'remote-a',
    );
    expect(custom.isCustom, isTrue);
    expect(custom.displayName, 'Custom A');
    expect(custom.contextWindowTokens, 200000);
    expect(custom.apiProtocol, ModelApiProtocol.responses);

    controller.setModelHidden('remote-b', true);
    await _waitUntil(
      () => store.value.profiles.single
          .modelSettings(AgentKind.codex)
          .hiddenModelIds
          .contains('remote-b'),
    );
    expect(
      controller.state.models.any((model) => model.model == 'remote-b'),
      isFalse,
    );

    controller.setModelHidden('remote-b', false);
    await _waitUntil(
      () => !store.value.profiles.single
          .modelSettings(AgentKind.codex)
          .hiddenModelIds
          .contains('remote-b'),
    );
    expect(
      controller.state.models.any((model) => model.model == 'remote-b'),
      isTrue,
    );

    controller.deleteCustomModel('remote-a');
    await _waitUntil(
      () => store.value.profiles.single
          .modelSettings(AgentKind.codex)
          .customModels
          .isEmpty,
    );
    final settings = store.value.profiles.single.modelSettings(AgentKind.codex);
    expect(settings.managedModelIds, contains('remote-a'));
    expect(
      controller.state.models.any((model) => model.model == 'remote-a'),
      isFalse,
    );
  });

  test('tests global settings without saving or disconnecting', () async {
    final profile = _firstProfile.copyWith(workspacePromptShown: true);
    final store = _MemoryProfileStore(
      StoredProfiles(profiles: [profile], selectedProfileId: profile.id),
    );
    final host = _FingerprintClient();
    final connections = ServerConnectionManager(clientFactory: () => host);
    final agent = _SettingsAgent();
    final agents = AgentConnectionManager(
      connections,
      clientFactory: (kind) => agent,
    );
    final diagnostics = _RecordingDiagnosticLogger();
    final controller = AppController(store, connections, agents, diagnostics);
    addTearDown(() async {
      controller.dispose();
      await agents.close();
      await connections.close();
    });
    await _waitUntilInitialized(controller);
    await controller.requestConnect(profile);
    await controller.ensureActiveAgent();
    await controller.showAgentSettings();

    await controller.testAgentSettings(
      baseUrl: 'https://candidate.example/v1',
      apiKey: 'sk-candidate',
      proxyUrl: 'http://proxy.example:7890',
      testModel: 'gpt-candidate',
    );

    expect(agent.testCalls, 1);
    expect(agent.testedBaseUrl, 'https://candidate.example/v1');
    expect(agent.testedApiKey, 'sk-candidate');
    expect(agent.testedProxyUrl, 'http://proxy.example:7890');
    expect(agent.testedModel, 'gpt-candidate');
    expect(controller.state.agentSettingsTestResult?.successful, isTrue);
    expect(
      diagnostics.records,
      contains(
        contains(
          'INFO AgentSettings test_requested profile=${profile.id} '
          'agent=codex baseUrl=configured apiKey=configured '
          'proxy=configured model=configured',
        ),
      ),
    );
    expect(
      diagnostics.records,
      contains(
        contains(
          'INFO AgentSettings test_completed profile=${profile.id} '
          'agent=codex successful=true reason=success',
        ),
      ),
    );
    expect(diagnostics.records.join('\n'), isNot(contains('sk-candidate')));
    expect(controller.state.agentSettingsVisible, isTrue);
    expect(host.connected, isTrue);
    expect(agent.connected, isTrue);
    expect(
      store.value.profiles.single.modelSettings(AgentKind.codex).testModel,
      isEmpty,
    );
  });

  test('saves per-agent defaults and restarts only the active Agent', () async {
    final profile = localLinuxProfile(
      _localLinuxInstance,
    ).copyWith(hostFingerprint: 'SHA256:local', workspacePromptShown: true);
    final store = _MemoryProfileStore(
      StoredProfiles(profiles: [profile], selectedProfileId: profile.id),
    );
    final host = _FingerprintClient();
    final connections = ServerConnectionManager(clientFactory: () => host);
    final agent = _SettingsAgent();
    final agents = AgentConnectionManager(
      connections,
      clientFactory: (kind) => agent,
    );
    final diagnostics = _RecordingDiagnosticLogger();
    final runtime = _FakeLocalLinuxRuntime();
    final controller = AppController(
      store,
      connections,
      agents,
      diagnostics,
      null,
      null,
      runtime,
    );
    addTearDown(() async {
      controller.dispose();
      await agents.close();
      await connections.close();
    });
    await _waitUntilInitialized(controller);
    await controller.requestConnect(profile);
    await controller.ensureActiveAgent();
    await controller.showAgentSettings();

    await controller.saveAgentSettings(
      baseUrl: 'https://models.example/v1',
      apiKey: '',
      proxyUrl: 'http://127.0.0.1:7890',
      defaultModel: '  gpt-saved  ',
      defaultReasoningEffort: 'HIGH',
      testModel: '  gpt-test-saved  ',
      preserveCurrentProvider: true,
    );

    expect(agent.writeCalls, 1);
    expect(agent.writtenApiKey, isEmpty);
    expect(agent.writtenDefaultModel, 'gpt-saved');
    expect(agent.writtenDefaultEffort, 'high');
    expect(agent.writtenPreserveProvider, isTrue);
    final saved = store.value.profiles.single.modelSettings(AgentKind.codex);
    expect(saved.preferredModel, 'gpt-saved');
    expect(saved.preferredEffort, 'high');
    expect(saved.testModel, 'gpt-test-saved');
    expect(controller.state.agentSettingsVisible, isFalse);
    expect(controller.state.screen, AppScreen.threads);
    expect(host.connected, isTrue);
    expect(agent.connected, isTrue);
    expect(agent.disconnectCount, 1);
    expect(agent.connectCount, 2);
    expect(runtime.stopCalls, 0);
    expect(
      diagnostics.records,
      contains(
        contains(
          'INFO AgentSettings save_completed profile=${profile.id} '
          'agent=codex restart=success',
        ),
      ),
    );
    final diagnosticText = diagnostics.records.join('\n');
    expect(diagnosticText, isNot(contains('https://models.example/v1')));
    expect(diagnosticText, isNot(contains('http://127.0.0.1:7890')));
    expect(diagnosticText, isNot(contains('gpt-saved')));
  });

  test('recovers the retained Agent when its settings restart fails', () async {
    final profile = localLinuxProfile(
      _localLinuxInstance,
    ).copyWith(hostFingerprint: 'SHA256:local', workspacePromptShown: true);
    final store = _MemoryProfileStore(
      StoredProfiles(profiles: [profile], selectedProfileId: profile.id),
    );
    final host = _FingerprintClient();
    final connections = ServerConnectionManager(clientFactory: () => host);
    final agent = _SettingsAgent()..failConnectAttempt = 2;
    final agents = AgentConnectionManager(
      connections,
      clientFactory: (kind) => agent,
    );
    final diagnostics = _RecordingDiagnosticLogger();
    final runtime = _FakeLocalLinuxRuntime();
    final controller = AppController(
      store,
      connections,
      agents,
      diagnostics,
      const <Duration>[Duration.zero],
      null,
      runtime,
    );
    addTearDown(() async {
      controller.dispose();
      await agents.close();
      await connections.close();
    });
    await _waitUntilInitialized(controller);
    await controller.requestConnect(profile);
    await controller.ensureActiveAgent();
    await controller.showAgentSettings();

    await controller.saveAgentSettings(
      baseUrl: 'https://models.example/v1',
      apiKey: '',
      proxyUrl: '',
      defaultModel: 'gpt-saved',
      defaultReasoningEffort: 'high',
      testModel: 'gpt-test-saved',
      preserveCurrentProvider: true,
    );
    await _waitUntil(
      () =>
          agent.connectCount == 3 &&
          controller
                  .state
                  .agentConnectionStates[AgentConnectionKey(
                    profileId: profile.id,
                    agent: AgentKind.codex,
                  )]
                  ?.phase ==
              ConnectionPhase.connected,
    );

    expect(host.connected, isTrue);
    expect(agent.connected, isTrue);
    expect(runtime.stopCalls, 0);
    expect(controller.state.error, contains('配置已保存，但重新连接失败'));
    expect(controller.backgroundConnectionIntent.hostProfileIds, [profile.id]);
    expect(controller.backgroundConnectionIntent.agentConnectionKeys, [
      '${profile.id}\u0000codex',
    ]);
    expect(
      diagnostics.records,
      contains(
        contains(
          'WARN AgentSettings save_restart_failed profile=${profile.id} '
          'agent=codex error=StateError',
        ),
      ),
    );
  });

  test('drops a global settings read after the dialog is dismissed', () async {
    final profile = _firstProfile.copyWith(workspacePromptShown: true);
    final store = _MemoryProfileStore(
      StoredProfiles(profiles: [profile], selectedProfileId: profile.id),
    );
    final host = _FingerprintClient();
    final connections = ServerConnectionManager(clientFactory: () => host);
    final agent = _SettingsAgent()
      ..readCompleter = Completer<AgentGlobalSettings>();
    final agents = AgentConnectionManager(
      connections,
      clientFactory: (kind) => agent,
    );
    final controller = AppController(store, connections, agents);
    addTearDown(() async {
      controller.dispose();
      await agents.close();
      await connections.close();
    });
    await _waitUntilInitialized(controller);
    await controller.requestConnect(profile);
    await controller.ensureActiveAgent();

    final pending = controller.showAgentSettings();
    await _waitUntil(() => controller.state.agentSettingsLoading);
    controller.dismissAgentSettings();
    agent.readCompleter!.complete(agent.readValue);
    await pending;

    expect(controller.state.agentSettingsVisible, isFalse);
    expect(controller.state.agentSettings, isNull);
    expect(controller.state.agentSettingsError, isNull);
  });

  test(
    'probes, installs, verifies, and connects the managed runtime',
    () async {
      final profile = _firstProfile.copyWith(workspacePromptShown: true);
      final store = _MemoryProfileStore(
        StoredProfiles(profiles: [profile], selectedProfileId: profile.id),
      );
      final host = _FingerprintClient();
      final connections = ServerConnectionManager(clientFactory: () => host);
      final agent = _RuntimeAgent();
      final agents = AgentConnectionManager(
        connections,
        clientFactory: (kind) => agent,
      );
      final controller = AppController(store, connections, agents);
      addTearDown(() async {
        controller.dispose();
        await agents.close();
        await connections.close();
      });
      await _waitUntilInitialized(controller);

      await controller.requestConnect(profile);
      await _waitUntil(() => controller.state.remoteSetup != null);

      expect(controller.state.remoteSetup?.home, '/root');
      expect(controller.state.remoteSetup?.architecture, 'x86_64');
      expect(controller.state.setupInProgress, isFalse);
      expect(agent.inspectCalls, 1);
      expect(agent.connected, isFalse);

      await controller.installRemoteSetup('http://127.0.0.1:7890');

      expect(agent.installCalls, 1);
      expect(agent.inspectCalls, 2);
      expect(agent.installedProxy, 'http://127.0.0.1:7890');
      expect(
        agent.connectedRemoteCommand,
        "'/root/.local/bin/codex-remote' app-server --listen stdio://",
      );
      expect(agent.connected, isTrue);
      expect(controller.state.remoteSetup, isNull);
      expect(controller.state.agentSetupStates, isEmpty);
      expect(controller.state.threads, isNotEmpty);
      expect(store.value.profiles.single.proxyUrl, 'http://127.0.0.1:7890');
    },
  );

  test(
    'minimizes an active install and keeps failure available for retry',
    () async {
      final profile = _firstProfile.copyWith(workspacePromptShown: true);
      final store = _MemoryProfileStore(
        StoredProfiles(profiles: [profile], selectedProfileId: profile.id),
      );
      final host = _FingerprintClient();
      final connections = ServerConnectionManager(clientFactory: () => host);
      final agent = _RuntimeAgent()..installGate = Completer<void>();
      final agents = AgentConnectionManager(
        connections,
        clientFactory: (kind) => agent,
      );
      final controller = AppController(store, connections, agents);
      addTearDown(() async {
        controller.dispose();
        await agents.close();
        await connections.close();
      });
      await _waitUntilInitialized(controller);
      await controller.requestConnect(profile);
      await _waitUntil(() => controller.state.remoteSetup != null);

      agent.failNextInstall = true;
      final install = controller.installRemoteSetup(
        'https://proxy.example:8443',
      );
      await _waitUntil(() => controller.state.setupInProgress);
      expect(controller.state.setupProgressPercent, 38);
      expect(controller.state.setupDownloadPercent, 37);

      controller.minimizeRemoteSetup();
      expect(controller.state.remoteSetup, isNull);
      expect(controller.state.agentSetupStates.values.single.minimized, isTrue);
      expect(controller.state.agentSetupStates.values.single.percent, 38);
      expect(
        controller.state.agentSetupStates.values.single.downloadPercent,
        37,
      );
      controller.resumeRemoteSetup();
      expect(controller.state.remoteSetup, isNotNull);
      expect(controller.state.setupInProgress, isTrue);
      expect(controller.state.setupProgressPercent, 38);
      expect(controller.state.setupDownloadPercent, 37);
      controller.minimizeRemoteSetup();
      await controller.ensureActiveAgent();
      expect(controller.state.remoteSetup, isNotNull);
      expect(controller.state.setupInProgress, isTrue);

      agent.installGate!.complete();
      await install;
      expect(controller.state.setupInProgress, isFalse);
      expect(controller.state.setupProgress, '安装失败');
      expect(controller.state.setupProgressDetail, contains('模拟下载失败'));

      agent.installGate = null;
      await controller.installRemoteSetup('https://proxy.example:8443');
      expect(agent.installCalls, 2);
      expect(agent.connected, isTrue);
      expect(controller.state.remoteSetup, isNull);
    },
  );

  test('opens a child Agent from a root conversation', () async {
    final harness = await _createSubAgentHarness();

    await _openSubAgent(
      harness,
      _SubAgentNavigationAgent.childThread,
      'Worker',
    );

    expect(harness.controller.state.screen, AppScreen.agentWork);
    expect(harness.controller.state.activeAgentName, 'Worker');
    expect(
      harness.controller.state.timeline,
      _SubAgentNavigationAgent.childTimeline,
    );
    expect(
      harness.controller.state.tokenUsage,
      _SubAgentNavigationAgent.childUsage,
    );
    expect(
      harness.agent.resumeCount(_SubAgentNavigationAgent.childThread.id),
      1,
    );
  });

  test('persists model and reasoning effort for the active thread', () async {
    final harness = await _createSubAgentHarness();
    final preferenceKey = threadPreferenceKey(
      harness.profile.id,
      AgentKind.codex,
      _SubAgentNavigationAgent.rootThread.id,
    );

    harness.controller.selectThreadModel('gpt-5.2-codex', effort: 'medium');
    await _waitUntil(
      () =>
          harness.store.value.threadModelPreferences[preferenceKey] ==
          const ThreadModelPreference(model: 'gpt-5.2-codex', effort: 'medium'),
    );
    expect(harness.controller.state.selectedModel, 'gpt-5.2-codex');
    expect(harness.controller.state.selectedEffort, 'medium');

    harness.controller.selectThreadEffort('high');
    await _waitUntil(
      () =>
          harness.store.value.threadModelPreferences[preferenceKey]?.effort ==
          'high',
    );
    expect(harness.controller.state.selectedModel, 'gpt-5.2-codex');
    expect(harness.controller.state.selectedEffort, 'high');
  });

  test(
    'returns through two nested Agent conversations one level at a time',
    () async {
      final harness = await _createSubAgentHarness();
      await _openSubAgent(
        harness,
        _SubAgentNavigationAgent.childThread,
        'Worker',
      );
      await _openSubAgent(
        harness,
        _SubAgentNavigationAgent.grandchildThread,
        'Reviewer',
      );

      harness.controller.backFromSubAgentThread();
      await _waitUntil(
        () =>
            harness.controller.state.activeThread?.id ==
                _SubAgentNavigationAgent.childThread.id &&
            !harness.controller.state.loading,
      );

      expect(harness.controller.state.screen, AppScreen.agentWork);
      expect(harness.controller.state.activeAgentName, 'Worker');
      expect(
        harness.controller.state.timeline,
        _SubAgentNavigationAgent.childTimeline,
      );
      expect(
        harness.controller.state.tokenUsage,
        _SubAgentNavigationAgent.childUsage,
      );

      harness.controller.backFromSubAgentThread();
      await _waitUntil(
        () =>
            harness.controller.state.activeThread?.id ==
                _SubAgentNavigationAgent.rootThread.id &&
            !harness.controller.state.loading,
      );

      expect(harness.controller.state.screen, AppScreen.work);
      expect(harness.controller.state.activeAgentName, isNull);
      expect(
        harness.controller.state.timeline,
        _SubAgentNavigationAgent.rootTimeline,
      );
      expect(
        harness.controller.state.tokenUsage,
        _SubAgentNavigationAgent.rootUsage,
      );
    },
  );

  test('returns to the parent while the child is still loading', () async {
    final harness = await _createSubAgentHarness();
    final childGate = harness.agent.gateNextResume(
      _SubAgentNavigationAgent.childThread.id,
    );

    harness.controller.openSubAgentThread(
      _SubAgentNavigationAgent.childThread.id,
      'Worker',
    );
    await _waitUntil(
      () =>
          harness.controller.state.activeThread?.id ==
              _SubAgentNavigationAgent.childThread.id &&
          harness.controller.state.loading &&
          harness.agent.resumeCount(_SubAgentNavigationAgent.childThread.id) ==
              1,
    );

    harness.controller.backFromSubAgentThread();
    await _waitUntil(
      () =>
          harness.controller.state.activeThread?.id ==
              _SubAgentNavigationAgent.rootThread.id &&
          !harness.controller.state.loading,
    );

    childGate.complete(
      _SubAgentNavigationAgent.sessions[_SubAgentNavigationAgent
          .childThread
          .id]!,
    );
    await _waitUntil(
      () =>
          harness.agent.completedResumeCount(
            _SubAgentNavigationAgent.childThread.id,
          ) ==
          1,
    );
    await _drainAsyncWork();

    expect(
      harness.controller.state.activeThread?.id,
      _SubAgentNavigationAgent.rootThread.id,
    );
    expect(
      harness.controller.state.timeline,
      _SubAgentNavigationAgent.rootTimeline,
    );
    expect(
      harness.controller.state.tokenUsage,
      _SubAgentNavigationAgent.rootUsage,
    );
  });

  test('coalesces repeated parent returns while resume is pending', () async {
    final harness = await _createSubAgentHarness();
    await _openSubAgent(
      harness,
      _SubAgentNavigationAgent.childThread,
      'Worker',
    );
    final rootGate = harness.agent.gateNextResume(
      _SubAgentNavigationAgent.rootThread.id,
    );
    final priorRootResumes = harness.agent.resumeCount(
      _SubAgentNavigationAgent.rootThread.id,
    );

    harness.controller.backFromSubAgentThread();
    await _waitUntil(
      () =>
          harness.agent.resumeCount(_SubAgentNavigationAgent.rootThread.id) ==
          priorRootResumes + 1,
    );
    harness.controller.backFromSubAgentThread();
    await _drainAsyncWork();

    expect(
      harness.agent.resumeCount(_SubAgentNavigationAgent.rootThread.id),
      priorRootResumes + 1,
    );

    rootGate.complete(
      _SubAgentNavigationAgent.sessions[_SubAgentNavigationAgent
          .rootThread
          .id]!,
    );
    await _waitUntil(
      () =>
          harness.controller.state.activeThread?.id ==
              _SubAgentNavigationAgent.rootThread.id &&
          !harness.controller.state.loading,
    );
    expect(harness.controller.state.screen, AppScreen.work);
  });

  test(
    'restores the child after parent resume fails and allows retry',
    () async {
      final harness = await _createSubAgentHarness();
      await _openSubAgent(
        harness,
        _SubAgentNavigationAgent.childThread,
        'Worker',
      );
      final rootGate = harness.agent.gateNextResume(
        _SubAgentNavigationAgent.rootThread.id,
      );
      final priorRootResumes = harness.agent.resumeCount(
        _SubAgentNavigationAgent.rootThread.id,
      );

      harness.controller.backFromSubAgentThread();
      await _waitUntil(
        () =>
            harness.agent.resumeCount(_SubAgentNavigationAgent.rootThread.id) ==
            priorRootResumes + 1,
      );
      rootGate.completeError(StateError('parent resume failed'));
      await _waitUntil(
        () =>
            harness.controller.state.activeThread?.id ==
                _SubAgentNavigationAgent.childThread.id &&
            !harness.controller.state.loading &&
            harness.controller.state.error?.contains('parent resume failed') ==
                true,
      );

      expect(harness.controller.state.screen, AppScreen.agentWork);
      expect(harness.controller.state.activeAgentName, 'Worker');
      expect(
        harness.controller.state.timeline,
        _SubAgentNavigationAgent.childTimeline,
      );

      await _drainAsyncWork();
      harness.controller.backFromSubAgentThread();
      await _waitUntil(
        () =>
            harness.controller.state.activeThread?.id ==
                _SubAgentNavigationAgent.rootThread.id &&
            !harness.controller.state.loading &&
            harness.agent.resumeCount(_SubAgentNavigationAgent.rootThread.id) ==
                priorRootResumes + 2,
      );

      expect(harness.controller.state.screen, AppScreen.work);
      expect(
        harness.controller.state.timeline,
        _SubAgentNavigationAgent.rootTimeline,
      );
      expect(harness.controller.state.error, isNull);
    },
  );

  test('never presents two consecutive mismatched resume responses', () async {
    final harness = await _createSubAgentHarness();
    await _openSubAgent(
      harness,
      _SubAgentNavigationAgent.childThread,
      'Worker',
    );
    final firstGate = harness.agent.gateNextResume(
      _SubAgentNavigationAgent.rootThread.id,
    );
    final secondGate = harness.agent.gateNextResume(
      _SubAgentNavigationAgent.rootThread.id,
    );
    final priorRootResumes = harness.agent.resumeCount(
      _SubAgentNavigationAgent.rootThread.id,
    );
    const firstWrong = AgentSession(
      thread: AgentThread(id: 'wrong-one', title: 'Wrong one'),
      timeline: <TimelineEntry>[
        TimelineEntry(
          id: 'wrong-one-message',
          kind: TimelineKind.agentMessage,
          text: 'Wrong one content',
        ),
      ],
    );
    const secondWrong = AgentSession(
      thread: AgentThread(id: 'wrong-two', title: 'Wrong two'),
      timeline: <TimelineEntry>[
        TimelineEntry(
          id: 'wrong-two-message',
          kind: TimelineKind.agentMessage,
          text: 'Wrong two content',
        ),
      ],
    );

    harness.controller.backFromSubAgentThread();
    await _waitUntil(
      () =>
          harness.agent.resumeCount(_SubAgentNavigationAgent.rootThread.id) ==
          priorRootResumes + 1,
    );
    firstGate.complete(firstWrong);
    await _waitUntil(
      () =>
          harness.agent.resumeCount(_SubAgentNavigationAgent.rootThread.id) ==
          priorRootResumes + 2,
    );

    expect(
      harness.controller.state.activeThread?.id,
      _SubAgentNavigationAgent.rootThread.id,
    );
    expect(
      harness.controller.state.timeline,
      _SubAgentNavigationAgent.rootTimeline,
    );

    secondGate.complete(secondWrong);
    await _waitUntil(
      () =>
          harness.controller.state.activeThread?.id ==
              _SubAgentNavigationAgent.childThread.id &&
          !harness.controller.state.loading &&
          harness.controller.state.error?.contains('服务器返回了其他会话') == true,
    );

    expect(
      harness.controller.state.timeline,
      _SubAgentNavigationAgent.childTimeline,
    );
    expect(
      harness.controller.state.timeline.map((entry) => entry.text),
      isNot(contains('Wrong one content')),
    );
    expect(
      harness.controller.state.timeline.map((entry) => entry.text),
      isNot(contains('Wrong two content')),
    );
  });

  test('keeps draft model effort and token usage isolated by thread', () async {
    final profile = _firstProfile.copyWith(workspacePromptShown: true);
    final rootKey = threadPreferenceKey(
      profile.id,
      AgentKind.codex,
      _SubAgentNavigationAgent.rootThread.id,
    );
    final childKey = threadPreferenceKey(
      profile.id,
      AgentKind.codex,
      _SubAgentNavigationAgent.childThread.id,
    );
    final harness = await _createSubAgentHarness(
      storedProfiles:
          StoredProfiles(
            profiles: [profile],
            selectedProfileId: profile.id,
            composerDrafts: const <String, String>{
              // Filled below with the profile-scoped keys.
            },
            threadModelPreferences: const <String, ThreadModelPreference>{},
          ).copyWith(
            composerDrafts: <String, String>{
              rootKey: 'root draft',
              childKey: 'child draft',
            },
            threadModelPreferences: <String, ThreadModelPreference>{
              rootKey: const ThreadModelPreference(
                model: 'root-model',
                effort: 'high',
              ),
              childKey: const ThreadModelPreference(
                model: 'child-model',
                effort: 'low',
              ),
            },
          ),
    );

    expect(harness.controller.state.composerDraft, 'root draft');
    expect(harness.controller.state.selectedModel, 'root-model');
    expect(harness.controller.state.selectedEffort, 'high');
    expect(
      harness.controller.state.tokenUsage,
      _SubAgentNavigationAgent.rootUsage,
    );

    await _openSubAgent(
      harness,
      _SubAgentNavigationAgent.childThread,
      'Worker',
    );
    expect(harness.controller.state.composerDraft, 'child draft');
    expect(harness.controller.state.selectedModel, 'child-model');
    expect(harness.controller.state.selectedEffort, 'low');
    expect(
      harness.controller.state.tokenUsage,
      _SubAgentNavigationAgent.childUsage,
    );

    harness.controller.backFromSubAgentThread();
    await _waitUntil(
      () =>
          harness.controller.state.activeThread?.id ==
              _SubAgentNavigationAgent.rootThread.id &&
          !harness.controller.state.loading,
    );
    expect(harness.controller.state.composerDraft, 'root draft');
    expect(harness.controller.state.selectedModel, 'root-model');
    expect(harness.controller.state.selectedEffort, 'high');
    expect(
      harness.controller.state.tokenUsage,
      _SubAgentNavigationAgent.rootUsage,
    );

    await _openSubAgent(
      harness,
      _SubAgentNavigationAgent.childThread,
      'Worker',
    );
    expect(harness.controller.state.composerDraft, 'child draft');
    expect(harness.controller.state.selectedModel, 'child-model');
    expect(harness.controller.state.selectedEffort, 'low');
    expect(
      harness.controller.state.tokenUsage,
      _SubAgentNavigationAgent.childUsage,
    );
  });

  test(
    'flushes debounced drafts before entering and leaving a child',
    () async {
      final harness = await _createSubAgentHarness();
      final rootKey = threadPreferenceKey(
        harness.profile.id,
        AgentKind.codex,
        _SubAgentNavigationAgent.rootThread.id,
      );
      final childKey = threadPreferenceKey(
        harness.profile.id,
        AgentKind.codex,
        _SubAgentNavigationAgent.childThread.id,
      );

      harness.controller.setComposerDraft('unsaved root draft');
      await _openSubAgent(
        harness,
        _SubAgentNavigationAgent.childThread,
        'Worker',
      );
      harness.controller.setComposerDraft('unsaved child draft');
      harness.controller.backFromSubAgentThread();
      await _waitUntil(
        () =>
            harness.controller.state.activeThread?.id ==
                _SubAgentNavigationAgent.rootThread.id &&
            !harness.controller.state.loading,
      );
      await _waitUntil(
        () =>
            harness.store.value.composerDrafts[rootKey] ==
                'unsaved root draft' &&
            harness.store.value.composerDrafts[childKey] ==
                'unsaved child draft',
      );

      expect(harness.controller.state.composerDraft, 'unsaved root draft');
      await _openSubAgent(
        harness,
        _SubAgentNavigationAgent.childThread,
        'Worker',
      );
      expect(harness.controller.state.composerDraft, 'unsaved child draft');
    },
  );

  test('drops a child resume that completes after switching servers', () async {
    final first = _firstProfile.copyWith(workspacePromptShown: true);
    final second = _secondProfile.copyWith(workspacePromptShown: true);
    final harness = await _createSubAgentHarness(
      storedProfiles: StoredProfiles(
        profiles: [first, second],
        selectedProfileId: first.id,
      ),
    );
    final childGate = harness.agent.gateNextResume(
      _SubAgentNavigationAgent.childThread.id,
    );
    harness.controller.openSubAgentThread(
      _SubAgentNavigationAgent.childThread.id,
      'Worker',
    );
    await _waitUntil(
      () =>
          harness.controller.state.activeThread?.id ==
              _SubAgentNavigationAgent.childThread.id &&
          harness.controller.state.loading,
    );

    harness.controller.selectProfile(second.id);
    await _waitUntil(
      () =>
          harness.controller.state.selectedProfileId == second.id &&
          harness.controller.state.screen == AppScreen.servers,
    );
    final destinationTimeline = harness.controller.state.timeline;
    final destinationThreadId = harness.controller.state.activeThread?.id;

    childGate.complete(
      _SubAgentNavigationAgent.sessions[_SubAgentNavigationAgent
          .childThread
          .id]!,
    );
    await _waitUntil(
      () =>
          harness.agent.completedResumeCount(
            _SubAgentNavigationAgent.childThread.id,
          ) ==
          1,
    );
    await _drainAsyncWork();

    expect(harness.controller.state.selectedProfileId, second.id);
    expect(harness.controller.state.screen, AppScreen.servers);
    expect(harness.controller.state.activeThread?.id, destinationThreadId);
    expect(harness.controller.state.timeline, equals(destinationTimeline));
  });

  test('drops a child resume that completes after switching Agents', () async {
    final codexAgent = _SubAgentNavigationAgent();
    final openCodeAgent = _SubAgentNavigationAgent(
      agentKind: AgentKind.openCode,
    );
    final harness = await _createSubAgentHarness(
      agent: codexAgent,
      clientFactory: (kind) => switch (kind) {
        AgentKind.codex => codexAgent,
        AgentKind.openCode => openCodeAgent,
      },
    );
    final childGate = codexAgent.gateNextResume(
      _SubAgentNavigationAgent.childThread.id,
    );
    harness.controller.openSubAgentThread(
      _SubAgentNavigationAgent.childThread.id,
      'Worker',
    );
    await _waitUntil(
      () =>
          harness.controller.state.activeThread?.id ==
              _SubAgentNavigationAgent.childThread.id &&
          harness.controller.state.loading,
    );

    harness.controller.selectAgent(AgentKind.openCode);
    final openCodeKey = AgentConnectionKey(
      profileId: harness.profile.id,
      agent: AgentKind.openCode,
    );
    await _waitUntil(
      () =>
          harness.controller.state.activeAgent == AgentKind.openCode &&
          harness.controller.state.agentConnectionStates[openCodeKey]?.phase ==
              ConnectionPhase.connected &&
          harness.controller.state.agentLoadingStates[openCodeKey] == false,
    );
    final destinationTimeline = harness.controller.state.timeline;
    final destinationThreadId = harness.controller.state.activeThread?.id;

    childGate.complete(
      _SubAgentNavigationAgent.sessions[_SubAgentNavigationAgent
          .childThread
          .id]!,
    );
    await _waitUntil(
      () =>
          codexAgent.completedResumeCount(
            _SubAgentNavigationAgent.childThread.id,
          ) ==
          1,
    );
    await _drainAsyncWork();

    expect(harness.controller.state.activeAgent, AgentKind.openCode);
    expect(harness.controller.state.activeThread?.id, destinationThreadId);
    expect(harness.controller.state.timeline, equals(destinationTimeline));
  });

  test('drops a child resume that completes after disconnect', () async {
    final harness = await _createSubAgentHarness();
    final childGate = harness.agent.gateNextResume(
      _SubAgentNavigationAgent.childThread.id,
    );
    harness.controller.openSubAgentThread(
      _SubAgentNavigationAgent.childThread.id,
      'Worker',
    );
    await _waitUntil(
      () =>
          harness.controller.state.activeThread?.id ==
              _SubAgentNavigationAgent.childThread.id &&
          harness.controller.state.loading,
    );

    await harness.controller.disconnectProfile(harness.profile.id);
    expect(harness.controller.state.screen, AppScreen.servers);
    expect(
      harness.controller.state.connectionStates[harness.profile.id]?.phase,
      ConnectionPhase.disconnected,
    );
    final destinationTimeline = harness.controller.state.timeline;
    final destinationThreadId = harness.controller.state.activeThread?.id;

    childGate.complete(
      _SubAgentNavigationAgent.sessions[_SubAgentNavigationAgent
          .childThread
          .id]!,
    );
    await _waitUntil(
      () =>
          harness.agent.completedResumeCount(
            _SubAgentNavigationAgent.childThread.id,
          ) ==
          1,
    );
    await _drainAsyncWork();

    expect(harness.controller.state.screen, AppScreen.servers);
    expect(harness.controller.state.activeThread?.id, destinationThreadId);
    expect(harness.controller.state.timeline, equals(destinationTimeline));
  });

  test(
    'isolates approval requests by thread when a late request arrives',
    () async {
      final agent = _ApprovalAgent();
      final harness = await _createSubAgentHarness(agent: agent);
      final rootId = _SubAgentNavigationAgent.rootThread.id;
      final childId = _SubAgentNavigationAgent.childThread.id;

      agent.emitApproval(requestId: 'root-1', threadId: rootId);
      await _waitUntil(
        () => harness.controller.state.approvalQueue
            .map((prompt) => prompt.requestId)
            .contains('root-1'),
      );

      harness.controller.openThread(_SubAgentNavigationAgent.childThread);
      await _waitUntil(
        () =>
            harness.controller.state.activeThread?.id == childId &&
            !harness.controller.state.loading,
      );
      expect(harness.controller.state.approvalQueue, isEmpty);

      // This request belongs to the parent, but it arrives while the child is
      // visible.  It must stay queued without changing the child UI.
      agent.emitApproval(requestId: 'root-2', threadId: rootId);
      await _drainAsyncWork();
      expect(harness.controller.state.activeThread?.id, childId);
      expect(harness.controller.state.approvalQueue, isEmpty);

      agent.emitApproval(requestId: 'child-1', threadId: childId);
      await _waitUntil(
        () => harness.controller.state.approvalQueue
            .map((prompt) => prompt.requestId)
            .contains('child-1'),
      );
      expect(
        harness.controller.state.approvalQueue.map(
          (prompt) => prompt.requestId,
        ),
        ['child-1'],
      );

      harness.controller.openThread(_SubAgentNavigationAgent.rootThread);
      await _waitUntil(
        () =>
            harness.controller.state.activeThread?.id == rootId &&
            !harness.controller.state.loading,
      );
      expect(
        harness.controller.state.approvalQueue.map(
          (prompt) => prompt.requestId,
        ),
        ['root-1', 'root-2'],
      );
    },
  );

  test(
    'answering an approval removes only the matching thread request',
    () async {
      final agent = _ApprovalAgent();
      final harness = await _createSubAgentHarness(agent: agent);
      final rootId = _SubAgentNavigationAgent.rootThread.id;
      final childId = _SubAgentNavigationAgent.childThread.id;

      agent.emitApproval(requestId: 'shared', threadId: rootId);
      await _waitUntil(() => harness.controller.state.approval != null);
      harness.controller.openThread(_SubAgentNavigationAgent.childThread);
      await _waitUntil(
        () =>
            harness.controller.state.activeThread?.id == childId &&
            !harness.controller.state.loading,
      );
      agent.emitApproval(requestId: 'shared', threadId: childId);
      await _waitUntil(
        () => harness.controller.state.approvalQueue
            .map((prompt) => prompt.requestId)
            .contains('shared'),
      );

      harness.controller.openThread(_SubAgentNavigationAgent.rootThread);
      await _waitUntil(
        () =>
            harness.controller.state.activeThread?.id == rootId &&
            !harness.controller.state.loading,
      );
      await harness.controller.answerApproval(true);
      await _waitUntil(() => agent.answeredPrompts.length == 1);

      expect(agent.answeredPrompts.single.threadId, rootId);
      expect(harness.controller.state.approvalQueue, isEmpty);

      harness.controller.openThread(_SubAgentNavigationAgent.childThread);
      await _waitUntil(
        () =>
            harness.controller.state.activeThread?.id == childId &&
            !harness.controller.state.loading,
      );
      expect(
        harness.controller.state.approvalQueue.map((prompt) => prompt.threadId),
        [childId],
      );
    },
  );
}

Future<void> _waitUntilInitialized(AppController controller) async {
  while (controller.state.loading) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('condition was not met');
}

Future<void> _drainAsyncWork() async {
  for (var attempt = 0; attempt < 10; attempt++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void _expectNoProfileData(StoredProfiles stored, String profileId) {
  final prefix = '$profileId\u0000';
  expect(
    stored.composerDrafts.keys.where((key) => key.startsWith(prefix)),
    isEmpty,
  );
  expect(
    stored.threadModelPreferences.keys.where((key) => key.startsWith(prefix)),
    isEmpty,
  );
  expect(
    stored.completedTurnTimings.keys.where((key) => key.startsWith(prefix)),
    isEmpty,
  );
}
