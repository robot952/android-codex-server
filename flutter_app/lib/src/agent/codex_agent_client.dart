import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../domain/models.dart';
import '../ssh/ssh_server_client.dart';
import 'codex_global_settings.dart';
import 'codex_protocol.dart';
import 'remote_agent_client.dart';
import 'remote_bootstrap.dart';

typedef CodexSessionOpener =
    Future<SSHSession> Function(SSHClient client, String command);

final class CodexResponseTooLargeException implements Exception {
  const CodexResponseTooLargeException(this.message, {this.id});

  final String message;
  final CodexRequestId? id;

  @override
  String toString() => message;
}

/// The Codex app-server adapter. It uses one no-PTY SSH exec channel and
/// speaks newline-delimited JSON on stdin/stdout; stderr is diagnostics only.
class CodexAgentClient
    implements
        RemoteAgentClient,
        RemoteAgentTurnClient,
        RemoteAgentSteerClient,
        RemoteAgentThreadCreateClient,
        RemoteAgentApprovalClient,
        RemoteAgentThreadMutationClient,
        RemoteAgentGlobalSettingsClient,
        RemoteAgentApiModelClient,
        RemoteAgentRuntimeClient,
        RemoteAgentGenerationClient {
  CodexAgentClient({
    this.clientVersion = '1.8.0',
    this.requestTimeout = const Duration(seconds: 120),
    this.threadRequestTimeout = const Duration(seconds: 180),
    this.maxLineChars = 8 * 1024 * 1024,
    CodexSessionOpener? sessionOpener,
  }) : _sessionOpener = sessionOpener ?? _openSession;

  static const _stderrLineLimit = 8 * 1024;
  static const _oversizedPrefixLimit = 64 * 1024;
  static const _goalReadTimeout = Duration(seconds: 6);

  final String clientVersion;
  final Duration requestTimeout;
  final Duration threadRequestTimeout;
  final int maxLineChars;
  final CodexSessionOpener _sessionOpener;

  final CodexProtocolSession _protocol = CodexProtocolSession();
  final Map<CodexRequestId, Completer<CodexRpcResponse>> _pending = {};
  final Map<CodexRequestId, CodexServerRequest> _serverRequests = {};
  final StreamController<RemoteAgentEvent> _eventController =
      StreamController<RemoteAgentEvent>.broadcast(sync: true);

  SSHSession? _session;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  CodexProtocolGeneration? _scope;
  Future<void> _writeTail = Future<void>.value();
  bool _closed = false;
  bool _connected = false;
  bool _lossEmitted = false;
  RemoteServerClient? _settingsHost;
  ServerProfile? _connectedProfile;
  String _stdoutBuffer = '';
  String _oversizedStdoutPrefix = '';
  bool _discardStdoutLine = false;
  String _stderrBuffer = '';
  bool _discardStderrLine = false;

  @override
  AgentKind get kind => AgentKind.codex;

  @override
  AgentCapabilities get capabilities => AgentCapabilities.codex;

  @override
  bool get isConnected => _connected && _session != null;

  @override
  int? get currentGeneration {
    final scope = _scope;
    return scope?.isCurrent == true ? scope!.value : null;
  }

  @override
  Stream<RemoteAgentEvent> get events => _eventController.stream;

  @override
  Future<AgentRuntimeInspection> inspectRuntime(
    ServerProfile profile,
    RemoteServerClient host,
  ) async {
    final scriptHost = host is RemoteServerScriptClient
        ? host as RemoteServerScriptClient
        : throw UnsupportedError('当前 SSH 客户端不支持安全执行探测脚本');
    final output = await scriptHost.runShellScript(
      RemoteBootstrap.probeScript,
      timeout: const Duration(seconds: 30),
      maxOutputBytes: 64 * 1024,
    );
    return RemoteBootstrap.parseProbe(output);
  }

  @override
  Future<void> installRuntime(
    ServerProfile profile,
    RemoteServerClient host, {
    required void Function(RemoteInstallProgress progress) onProgress,
  }) async {
    final scriptHost = host is RemoteServerStreamingScriptClient
        ? host as RemoteServerStreamingScriptClient
        : throw UnsupportedError('当前 SSH 客户端不支持流式执行安装脚本');
    await scriptHost.runStreamingShellScript(
      RemoteBootstrap.installScript(proxyUrl: profile.proxyUrl),
      command: remoteInstallCommand,
      timeout: const Duration(minutes: 30),
      maxOutputBytes: 8 * 1024 * 1024,
      onStdoutLine: (line) {
        final progress = parseRemoteInstallProgressLine(line);
        if (progress != null) onProgress(progress);
      },
    );
  }

  @override
  Future<void> uninstallRuntime(
    ServerProfile profile,
    RemoteServerClient host,
  ) async {
    await disconnect();
    final scriptHost = host is RemoteServerScriptClient
        ? host as RemoteServerScriptClient
        : throw UnsupportedError('当前 SSH 客户端不支持安全执行卸载脚本');
    await scriptHost.runShellScript(
      RemoteBootstrap.uninstallScript,
      timeout: const Duration(minutes: 1),
      maxOutputBytes: 64 * 1024,
    );
  }

  @override
  Future<void> connect(ServerProfile profile, RemoteServerClient host) async {
    if (_closed) throw StateError('${kind.label} 通道已经关闭');
    await disconnect();

    final scope = _protocol.beginGeneration();
    final command = buildCodexAppServerCommand(profile);
    final SSHSession session;
    try {
      session = await _sessionOpener(host.requireSshClient(), command);
    } catch (_) {
      _protocol.invalidateGeneration();
      rethrow;
    }
    _scope = scope;
    _session = session;
    _connected = false;
    _serverRequests.clear();
    _lossEmitted = false;
    _stdoutBuffer = '';
    _oversizedStdoutPrefix = '';
    _stderrBuffer = '';
    _discardStdoutLine = false;
    _discardStderrLine = false;
    _listen(session, scope);

    try {
      final initialize = await _request(
        scope.initialize(clientVersion: clientVersion),
        timeout: requestTimeout,
      );
      initialize.resultOrThrow();
      await _write(scope.initialized().encodeLine());
      _connected = true;
      _settingsHost = host;
      _connectedProfile = profile;
    } catch (_) {
      await disconnect();
      rethrow;
    }
  }

  @override
  Future<List<AgentModel>> listModels() async {
    final scope = _requireScope();
    final response = await _request(
      scope.request(
        'model/list',
        params: const <String, Object?>{'limit': 100},
      ),
      timeout: requestTimeout,
    );
    return CodexPayloadParser.parseModels(response.resultOrThrow());
  }

  @override
  Future<AgentThreadPage> listThreads({String? searchTerm}) async {
    final scope = _requireScope();
    final response = await _request(
      scope.threadList(searchTerm: searchTerm),
      timeout: threadRequestTimeout,
    );
    final result = response.resultOrThrow();
    final page = CodexPayloadParser.parseThreadList(result);
    return AgentThreadPage(
      threads: page.threads,
      nextCursor: page.nextCursor,
      previousCursor: page.backwardsCursor,
    );
  }

  @override
  Future<AgentSession> resumeThread(
    String threadId, {
    ApprovalMode approvalMode = ApprovalMode.requestApproval,
  }) async {
    final scope = _requireScope();
    final attempts = <({String itemsView, int limit})>[
      (itemsView: 'full', limit: 4),
      (itemsView: 'full', limit: 1),
      (itemsView: 'summary', limit: 1),
      (itemsView: 'notLoaded', limit: 1),
    ];
    CodexRpcResponse? response;
    var itemsView = 'full';
    for (var index = 0; index < attempts.length; index += 1) {
      final attempt = attempts[index];
      try {
        response = await _request(
          scope.threadResume(
            threadId: threadId,
            approvalMode: approvalMode,
            itemsView: attempt.itemsView,
            limit: attempt.limit,
          ),
          timeout: threadRequestTimeout,
        );
        itemsView = attempt.itemsView;
        break;
      } on CodexResponseTooLargeException {
        if (index == attempts.length - 1) rethrow;
      }
    }
    final resolvedResponse = response!;
    final snapshot = CodexPayloadParser.parseResumedThread(
      resolvedResponse.resultOrThrow(),
    );
    if (snapshot == null) throw StateError('${kind.label} 返回的会话内容无效');
    return AgentSession(
      thread: snapshot.thread,
      timeline: snapshot.timeline,
      nextTurnsCursor: _nonEmpty(snapshot.nextTurnsCursor),
      tokenUsage: snapshot.tokenUsage,
      responseSequence: resolvedResponse.sequence,
      activeTurnStartedAtMillis: snapshot.activeTurnStartedAtMillis,
      turnIds: snapshot.turnIds,
      itemsView: itemsView,
    );
  }

  @override
  Future<AgentTurnsPage> loadOlderTurns({
    required String threadId,
    required String cursor,
    int? subAgentCreatedAt,
  }) async {
    final scope = _requireScope();
    final attempts = <({String itemsView, int limit})>[
      (itemsView: 'full', limit: 4),
      (itemsView: 'full', limit: 1),
      (itemsView: 'summary', limit: 1),
      (itemsView: 'notLoaded', limit: 1),
    ];
    CodexRpcResponse? response;
    var itemsView = 'full';
    for (var index = 0; index < attempts.length; index += 1) {
      final attempt = attempts[index];
      try {
        response = await _request(
          scope.threadTurnsList(
            threadId: threadId,
            cursor: cursor,
            itemsView: attempt.itemsView,
            limit: attempt.limit,
          ),
          timeout: threadRequestTimeout,
        );
        itemsView = attempt.itemsView;
        break;
      } on CodexResponseTooLargeException {
        if (index == attempts.length - 1) rethrow;
      }
    }
    final resolvedResponse = response!;
    final page = CodexPayloadParser.parseTurnsPage(
      resolvedResponse.resultOrThrow(),
      subAgentCreatedAt: subAgentCreatedAt,
    );
    return AgentTurnsPage(
      timeline: page.timeline,
      nextCursor: _nonEmpty(page.nextCursor),
      turnIds: page.turnIds,
      itemsView: itemsView,
    );
  }

  @override
  Future<AgentSession> startThread({
    String? cwd,
    String? model,
    ApprovalMode approvalMode = ApprovalMode.requestApproval,
    SandboxChoice? sandbox,
  }) async {
    final scope = _requireScope();
    final response = await _request(
      scope.threadStart(
        cwd: cwd,
        model: model,
        approvalMode: approvalMode,
        sandbox: sandbox,
      ),
      timeout: threadRequestTimeout,
    );
    final snapshot = CodexPayloadParser.parseThreadPayload(
      response.resultOrThrow(),
    );
    if (snapshot == null) throw StateError('${kind.label} 返回的新会话内容无效');
    return AgentSession(
      thread: snapshot.thread,
      timeline: snapshot.timeline,
      tokenUsage: snapshot.tokenUsage,
    );
  }

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
    final scope = _requireScope();
    final response = await _request(
      scope.turnStart(
        threadId: threadId,
        text: text,
        attachments: attachments,
        model: model,
        effort: effort,
        approvalMode: approvalMode,
        sandbox: sandbox,
        cwd: cwd,
      ),
      timeout: requestTimeout,
    );
    final result = response.resultOrThrow();
    final root = result is Map ? result : const <String, Object?>{};
    final turn = root['turn'];
    final id = turn is Map ? turn['id'] : null;
    if (id is! String || id.trim().isEmpty) {
      throw StateError('${kind.label} turn/start 响应缺少 turn.id');
    }
    return id.trim();
  }

  @override
  Future<void> interruptTurn({
    required String threadId,
    required String turnId,
  }) async {
    final scope = _requireScope();
    final response = await _request(
      scope.turnInterrupt(threadId: threadId, turnId: turnId),
      timeout: requestTimeout,
    );
    response.resultOrThrow();
  }

  @override
  Future<void> steerTurn({
    required String threadId,
    required String turnId,
    required String text,
    List<PendingAttachment> attachments = const <PendingAttachment>[],
  }) async {
    final scope = _requireScope();
    final response = await _request(
      scope.turnSteer(
        threadId: threadId,
        turnId: turnId,
        text: text,
        attachments: attachments,
      ),
      timeout: requestTimeout,
    );
    response.resultOrThrow();
  }

  @override
  Future<void> answerApproval(
    ApprovalPrompt prompt, {
    required bool accept,
    Map<String, String> answers = const <String, String>{},
  }) async {
    final id = prompt.requestIdIsString
        ? CodexRequestId.string(prompt.requestId)
        : CodexRequestId.number(
            num.tryParse(prompt.requestId) ?? (throw StateError('审批请求编号无效')),
          );
    final request = _serverRequests.remove(id);
    if (request == null || request.generation != _scope?.value) {
      throw StateError('审批请求已经失效');
    }
    final result = _approvalResult(
      request,
      prompt,
      accept: accept,
      answers: answers,
    );
    try {
      await _write(
        '${jsonEncode(<String, Object?>{'id': request.id.wireValue, 'result': result})}\n',
      );
    } catch (_) {
      if (_scope?.isCurrent == true) _serverRequests[id] = request;
      rethrow;
    }
  }

  @override
  Future<void> compactThread(String threadId) async {
    final scope = _requireScope();
    final response = await _request(
      scope.threadCompactStart(threadId: threadId),
      timeout: threadRequestTimeout,
    );
    response.resultOrThrow();
  }

  @override
  Future<AgentSession> rollbackThread(
    String threadId, {
    ApprovalMode approvalMode = ApprovalMode.requestApproval,
    int turns = 1,
  }) async {
    // The mutation response contains the bounded, post-rollback snapshot. The
    // approval mode is accepted by the adapter contract for parity with the
    // native client; the app-server rollback RPC itself only needs the id and
    // turn count.
    final _ = approvalMode;
    final scope = _requireScope();
    final response = await _request(
      scope.threadRollback(threadId: threadId, numTurns: turns),
      timeout: threadRequestTimeout,
    );
    final snapshot = CodexPayloadParser.parseResumedThread(
      response.resultOrThrow(),
    );
    if (snapshot == null) {
      throw StateError('${kind.label} 回退响应中的会话内容无效');
    }
    return AgentSession(
      thread: snapshot.thread,
      timeline: snapshot.timeline,
      nextTurnsCursor: _nonEmpty(snapshot.nextTurnsCursor),
      tokenUsage: snapshot.tokenUsage,
    );
  }

  @override
  Future<void> archiveThread(String threadId) async {
    final scope = _requireScope();
    final response = await _request(
      scope.threadArchive(threadId: threadId),
      timeout: threadRequestTimeout,
    );
    response.resultOrThrow();
  }

  @override
  Future<void> setThreadName(String threadId, String name) async {
    final scope = _requireScope();
    final response = await _request(
      scope.threadNameSet(threadId: threadId, name: name),
      timeout: requestTimeout,
    );
    response.resultOrThrow();
  }

  @override
  Future<void> startReview(String threadId) async {
    final scope = _requireScope();
    final response = await _request(
      scope.reviewStart(threadId: threadId),
      timeout: threadRequestTimeout,
    );
    response.resultOrThrow();
  }

  @override
  Future<ThreadGoal?> getThreadGoal(String threadId) async {
    final scope = _requireScope();
    final response = await _request(
      scope.threadGoalGet(threadId: threadId),
      timeout: _goalReadTimeout,
    );
    final result = response.resultOrThrow();
    final root = result is Map ? result : const <String, Object?>{};
    return CodexPayloadParser.parseThreadGoal(
      root['goal'],
      fallbackThreadId: threadId,
    );
  }

  @override
  Future<ThreadGoal> setThreadGoal(
    String threadId, {
    String? objective,
    ThreadGoalStatus? status,
    int? tokenBudget,
  }) async {
    final scope = _requireScope();
    final response = await _request(
      scope.threadGoalSet(
        threadId: threadId,
        objective: objective,
        status: status,
        tokenBudget: tokenBudget,
      ),
      timeout: threadRequestTimeout,
    );
    final result = response.resultOrThrow();
    final root = result is Map ? result : const <String, Object?>{};
    final goal = CodexPayloadParser.parseThreadGoal(
      root['goal'],
      fallbackThreadId: threadId,
    );
    if (goal == null) {
      throw StateError('${kind.label} thread/goal/set 响应缺少 goal');
    }
    return goal;
  }

  @override
  Future<void> clearThreadGoal(String threadId) async {
    final scope = _requireScope();
    final response = await _request(
      scope.threadGoalClear(threadId: threadId),
      timeout: threadRequestTimeout,
    );
    response.resultOrThrow();
  }

  /// Sends one adapter-owned extension request over this connection's current
  /// JSONL generation. Extensions stay under `agent/*`; callers cannot write
  /// arbitrary protocol records or bypass pending-request cleanup.
  Future<Object?> requestAdapterExtension(
    String method, {
    Map<String, Object?> params = const <String, Object?>{},
    Duration? timeout,
  }) async {
    final normalizedMethod = method.trim();
    if (!normalizedMethod.startsWith('agent/') ||
        normalizedMethod.length > 160) {
      throw ArgumentError.value(
        method,
        'method',
        'Agent 扩展方法必须位于 agent/* 命名空间',
      );
    }
    final scope = _requireScope();
    final response = await _request(
      scope.request(normalizedMethod, params: params),
      timeout: timeout ?? requestTimeout,
    );
    return response.resultOrThrow();
  }

  @override
  Future<void> disconnect() async {
    _settingsHost = null;
    _connectedProfile = null;
    _protocol.invalidateGeneration();
    _connected = false;
    _scope = null;
    _serverRequests.clear();
    _failPending(StateError('${kind.label} 通道已断开'));
    final session = _session;
    _session = null;
    await _cancelReaders();
    session?.close();
    await session?.done.catchError((_) {});
  }

  @override
  Future<AgentGlobalSettings> readGlobalSettings(ServerProfile profile) async {
    final host = _requireSettingsHost(profile);
    final output = await host.runShellScript(
      readCodexGlobalSettingsScript,
      timeout: const Duration(seconds: 30),
      maxOutputBytes: 64 * 1024,
    );
    return parseCodexGlobalSettings(output);
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
    final host = _requireSettingsHost(profile);
    final output = await host.runShellScript(
      buildWriteCodexGlobalSettingsScript(
        baseUrl: baseUrl,
        apiKey: apiKey,
        proxyUrl: proxyUrl,
        defaultModel: defaultModel,
        defaultReasoningEffort: defaultReasoningEffort,
        preserveCurrentProvider: preserveCurrentProvider,
      ),
      timeout: const Duration(seconds: 30),
      maxOutputBytes: 64 * 1024,
    );
    if (!output.split(RegExp(r'\r?\n')).contains('__CODEX_GLOBAL_UPDATED=1')) {
      throw StateError('${kind.label} 全局配置没有返回保存确认');
    }
  }

  @override
  Future<AgentConnectionTestResult> testGlobalSettings(
    ServerProfile profile, {
    required String baseUrl,
    required String apiKey,
    required String proxyUrl,
    required String testModel,
    ModelApiProtocol? apiProtocol,
  }) async {
    final host = _requireSettingsHost(profile);
    final output = await host.runShellScript(
      buildTestCodexGlobalSettingsScript(
        baseUrl: baseUrl,
        apiKey: apiKey,
        proxyUrl: proxyUrl,
        testModel: testModel,
        apiProtocol: apiProtocol,
      ),
      timeout: const Duration(seconds: 30),
      maxOutputBytes: 64 * 1024,
    );
    return parseCodexConnectionTest(output);
  }

  @override
  Future<List<ApiModelOption>> fetchApiModels(
    ServerProfile profile, {
    required String baseUrl,
    required String apiKey,
    required String proxyUrl,
  }) async {
    final host = _requireSettingsHost(profile);
    final output = await host.runShellScript(
      buildFetchCodexApiModelsScript(
        baseUrl: baseUrl,
        apiKey: apiKey,
        proxyUrl: proxyUrl,
      ),
      timeout: const Duration(seconds: 45),
      maxOutputBytes: 512 * 1024,
    );
    return parseCodexApiModels(output);
  }

  RemoteServerScriptClient _requireSettingsHost(ServerProfile profile) {
    final host = _settingsHost;
    final connectedProfile = _connectedProfile;
    if (!isConnected || host == null || connectedProfile == null) {
      throw StateError('${kind.label} 尚未连接');
    }
    if (!connectedProfile.hasSameConnectionIdentity(profile)) {
      throw StateError('${kind.label} 连接配置已更新');
    }
    if (host is! RemoteServerScriptClient) {
      throw UnsupportedError('当前 SSH 客户端不支持安全执行配置脚本');
    }
    return host as RemoteServerScriptClient;
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    unawaited(disconnect());
    unawaited(_eventController.close());
  }

  Future<CodexRpcResponse> _request(
    CodexRpcRequest request, {
    required Duration timeout,
  }) async {
    final scope = _scope;
    if (scope == null || !scope.isCurrent) {
      throw StateError('${kind.label} 通道尚未连接');
    }
    final completer = Completer<CodexRpcResponse>();
    _pending[request.id] = completer;
    try {
      await _write(request.encodeLine());
      return await completer.future.timeout(
        timeout,
        onTimeout: () => throw TimeoutException(
          '${kind.label} 请求 ${request.method} 超时',
          timeout,
        ),
      );
    } finally {
      if (identical(_pending[request.id], completer)) {
        _pending.remove(request.id);
      }
    }
  }

  Future<void> _write(String line) {
    final previous = _writeTail;
    final next = previous.catchError((_) {}).then((_) async {
      final session = _session;
      final scope = _scope;
      if (session == null || scope == null || !scope.isCurrent) {
        throw StateError('${kind.label} 通道已断开');
      }
      session.write(Uint8List.fromList(utf8.encode(line)));
      await session.flush();
    });
    _writeTail = next;
    return next;
  }

  void _listen(SSHSession session, CodexProtocolGeneration scope) {
    final decodedStdout = utf8.decoder.bind(session.stdout);
    final decodedStderr = utf8.decoder.bind(session.stderr);
    _stdoutSubscription = decodedStdout.listen(
      (chunk) => _consumeStdout(chunk, scope),
      onError: (Object error, StackTrace stack) {
        _emitDiagnostic('${kind.label} 标准输出读取失败：${_short(error)}');
      },
    );
    _stderrSubscription = decodedStderr.listen(
      _consumeStderr,
      onError: (Object error, StackTrace stack) {
        _emitDiagnostic(
          '${kind.label} 诊断流读取失败：${_short(error)}',
          isStderr: true,
        );
      },
    );
    unawaited(
      session.done
          .then((_) {
            if (identical(_session, session) && scope.isCurrent) {
              _connected = false;
              _failPending(StateError('${kind.label} 服务已退出'));
              _emitDiagnostic('${kind.label} 服务已退出');
              _emitConnectionLost('${kind.label} 服务已退出');
            }
          })
          .catchError((Object error, StackTrace stack) {
            if (identical(_session, session) && scope.isCurrent) {
              _connected = false;
              _failPending(error);
              _emitDiagnostic('${kind.label} 通道已关闭：${_short(error)}');
              _emitConnectionLost('${kind.label} 通道已关闭');
            }
          }),
    );
  }

  void _consumeStdout(String chunk, CodexProtocolGeneration scope) {
    if (!scope.isCurrent) return;
    var remaining = chunk;
    while (true) {
      final newline = remaining.indexOf('\n');
      final segment = newline < 0 ? remaining : remaining.substring(0, newline);
      if (_discardStdoutLine) {
        if (newline < 0) return;
        _finishOversizedStdoutLine(scope);
        remaining = remaining.substring(newline + 1);
        if (remaining.isEmpty) return;
        continue;
      }

      if (_stdoutBuffer.length + segment.length > maxLineChars) {
        _oversizedStdoutPrefix = _boundedOversizedPrefix(
          _stdoutBuffer,
          segment,
        );
        _stdoutBuffer = '';
        _discardStdoutLine = true;
        if (newline < 0) return;
        _finishOversizedStdoutLine(scope);
        remaining = remaining.substring(newline + 1);
        if (remaining.isEmpty) return;
        continue;
      }

      _stdoutBuffer += segment;
      if (newline < 0) return;
      final line = _stdoutBuffer;
      _stdoutBuffer = '';
      remaining = remaining.substring(newline + 1);
      if (line.trim().isNotEmpty) {
        _handleInbound(scope, line);
      }
      if (remaining.isEmpty) return;
    }
  }

  String _boundedOversizedPrefix(String buffered, String segment) {
    if (buffered.length >= _oversizedPrefixLimit) {
      return buffered.substring(0, _oversizedPrefixLimit);
    }
    final remaining = _oversizedPrefixLimit - buffered.length;
    final suffix = segment.length <= remaining
        ? segment
        : segment.substring(0, remaining);
    return '$buffered$suffix';
  }

  void _finishOversizedStdoutLine(CodexProtocolGeneration scope) {
    final prefix = _oversizedStdoutPrefix.trimRight();
    _oversizedStdoutPrefix = '';
    _discardStdoutLine = false;
    final hint = inspectCodexJsonRpcEnvelopePrefix(prefix);
    final id = hint.id;
    if (id == null) {
      _emitDiagnostic('${kind.label} 返回了超过 8 MiB 的通知，已丢弃');
      return;
    }
    if (hint.hasMethod) {
      _emitDiagnostic('${kind.label} 服务端请求过大，已拒绝该请求以避免回合卡住');
      unawaited(_replyOversizedServerRequest(id));
      return;
    }
    final error = CodexResponseTooLargeException(
      '${kind.label} 响应超过移动端 8 MiB 限制，正在改用精简响应',
      id: id,
    );
    final pending = _pending[id];
    if (pending == null) {
      _emitDiagnostic('收到未匹配的超大 ${kind.label} 响应（id=${id.wireValue}）');
    } else if (!pending.isCompleted) {
      pending.completeError(error);
    }
    _emitDiagnostic(error.message);
  }

  Future<void> _replyOversizedServerRequest(CodexRequestId id) async {
    final response = <String, Object?>{
      'id': id.wireValue,
      'error': const <String, Object?>{
        'code': -32600,
        'message': 'Agent server request exceeded the mobile response limit',
      },
    };
    try {
      await _write('${jsonEncode(response)}\n');
    } catch (error) {
      _emitDiagnostic('无法拒绝超大 ${kind.label} 请求：${_short(error)}');
    }
  }

  void _consumeStderr(String chunk) {
    _stderrBuffer += chunk;
    while (true) {
      final newline = _stderrBuffer.indexOf('\n');
      if (newline < 0) {
        if (_stderrBuffer.length > _stderrLineLimit) {
          _stderrBuffer = '';
          _discardStderrLine = true;
        }
        return;
      }
      final line = _stderrBuffer.substring(0, newline);
      _stderrBuffer = _stderrBuffer.substring(newline + 1);
      if (_discardStderrLine || line.length > _stderrLineLimit) {
        _discardStderrLine = false;
        _emitDiagnostic('${kind.label} 诊断信息过长，已截断', isStderr: true);
      } else if (line.trim().isNotEmpty) {
        _emitDiagnostic(line.trim(), isStderr: true);
      }
    }
  }

  void _handleInbound(CodexProtocolGeneration scope, String line) {
    final message = scope.decodeLine(line);
    if (message == null) return;
    switch (message) {
      case CodexRpcResponse():
        final pending = _pending[message.id];
        if (pending == null) {
          _emitDiagnostic(
            '收到未匹配的 ${kind.label} 响应（id=${message.id.wireValue}）',
          );
        } else if (!pending.isCompleted) {
          pending.complete(message);
        }
      case CodexRpcNotification():
        _emit(RemoteAgentNotification(message));
      case CodexServerRequest():
        if (_isApprovalRequest(message.method)) {
          if (_serverRequests.length >= 64) {
            _emitDiagnostic('待审批请求过多，新的请求已拒绝');
            unawaited(_replyUnknownRequest(message));
          } else {
            _serverRequests[message.id] = message;
            _emit(RemoteAgentServerRequest(message));
          }
        } else {
          _emit(RemoteAgentServerRequest(message));
          unawaited(_replyUnknownRequest(message));
        }
      case CodexParseError():
        _emitDiagnostic('${kind.label} 返回格式异常：${message.message}');
    }
  }

  Future<void> _replyUnknownRequest(CodexServerRequest request) async {
    final response = <String, Object?>{
      'id': request.id.wireValue,
      'error': <String, Object?>{
        'code': -32601,
        'message': 'Method not supported by mobile client',
      },
    };
    try {
      await _write('${jsonEncode(response)}\n');
    } catch (error) {
      _emitDiagnostic('无法回复 ${kind.label} 请求：${_short(error)}');
    }
  }

  CodexProtocolGeneration _requireScope() {
    final scope = _scope;
    if (!_connected || scope == null || !scope.isCurrent) {
      throw StateError('${kind.label} 尚未连接');
    }
    return scope;
  }

  Future<void> _cancelReaders() async {
    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    _stdoutSubscription = null;
    _stderrSubscription = null;
  }

  void _failPending(Object error) {
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.completeError(error);
    }
    _pending.clear();
  }

  void _emit(RemoteAgentEvent event) {
    if (!_eventController.isClosed) _eventController.add(event);
  }

  void _emitDiagnostic(String message, {bool isStderr = false}) {
    _emit(RemoteAgentDiagnostic(_short(message), isStderr: isStderr));
  }

  void _emitConnectionLost(String message) {
    if (_lossEmitted) return;
    _lossEmitted = true;
    _emit(RemoteAgentConnectionLost(message));
  }

  String _short(Object value) {
    final text = value.toString().trim();
    if (text.length <= 240) return text;
    return '${text.substring(0, 240)}…';
  }
}

Future<SSHSession> _openSession(SSHClient client, String command) =>
    client.execute(command);

String buildCodexAppServerCommand(ServerProfile profile) {
  final remoteCommand = profile.remoteCommand.trim();
  if (remoteCommand.isEmpty) {
    throw StateError('Codex 远程启动命令不能为空');
  }
  final workspace = profile.workspace.trim();
  final changeDirectory = workspace.isEmpty
      ? ''
      : 'cd -- ${_shellQuote(workspace)} && ';
  return 'if [ -r "\$HOME/.codex/codex-remote.env" ]; then '
      '. "\$HOME/.codex/codex-remote.env"; fi; '
      '$changeDirectory'
      'exec $remoteCommand';
}

String _shellQuote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";

String? _nonEmpty(String? value) =>
    value?.trim().isNotEmpty == true ? value : null;

bool _isApprovalRequest(String method) => switch (method) {
  'item/commandExecution/requestApproval' ||
  'item/fileChange/requestApproval' ||
  'execCommandApproval' ||
  'applyPatchApproval' ||
  'item/permissions/requestApproval' ||
  'permissions/requestApproval' ||
  'item/tool/requestUserInput' ||
  'tool/requestUserInput' => true,
  _ => false,
};

Map<String, Object?> _approvalResult(
  CodexServerRequest request,
  ApprovalPrompt prompt, {
  required bool accept,
  required Map<String, String> answers,
}) => switch (request.method) {
  'item/commandExecution/requestApproval' ||
  'item/fileChange/requestApproval' => <String, Object?>{
    'decision': accept ? 'accept' : 'decline',
  },
  'execCommandApproval' || 'applyPatchApproval' => <String, Object?>{
    'decision': accept ? 'approved' : 'denied',
  },
  'item/permissions/requestApproval' ||
  'permissions/requestApproval' => <String, Object?>{
    'permissions': accept
        ? request.params['permissions'] ?? const <String, Object?>{}
        : const <String, Object?>{},
    'scope': 'turn',
  },
  'item/tool/requestUserInput' || 'tool/requestUserInput' => <String, Object?>{
    'answers': <String, Object?>{
      for (final question in prompt.questions)
        question.id: <String, Object?>{
          'answers': <String>[answers[question.id] ?? ''],
        },
    },
  },
  _ => throw StateError('不支持的审批类型: ${request.method}'),
};
