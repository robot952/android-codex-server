import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';

import '../domain/models.dart';
import '../ssh/ssh_server_client.dart';
import 'codex_global_settings.dart';
import 'codex_host_capabilities.dart';
import 'codex_protocol.dart';
import 'remote_agent_client.dart';
import 'remote_bootstrap.dart';

/// The small part of an SSH exec session used by the JSONL adapter.
///
/// Keeping this boundary separate from [SSHSession] makes teardown and stream
/// ordering testable without opening a real socket.
abstract interface class CodexSession {
  Stream<Uint8List> get stdout;
  Stream<Uint8List> get stderr;
  Future<void> get done;

  void write(Uint8List data);

  /// Immediately stops the channel and its local upload stream.
  void terminate();
}

typedef CodexSessionOpener =
    Future<CodexSession> Function(RemoteServerClient host, String command);

typedef CodexDedicatedHostFactory = RemoteServerClient Function();

final class _SshCodexSession implements CodexSession {
  _SshCodexSession(this._session);

  final SSHSession _session;

  @override
  Stream<Uint8List> get stdout => _session.stdout;

  @override
  Stream<Uint8List> get stderr => _session.stderr;

  @override
  Future<void> get done => _session.done;

  @override
  void write(Uint8List data) => _session.write(data);

  @override
  void terminate() {
    // A graceful SSHSession.close() waits for the remote peer and can send
    // EOF after the host transport has already gone away. Destruction is the
    // same teardown used by SSHClient.close() and is idempotent.
    try {
      _session.channel.destroy();
    } catch (_) {
      try {
        _session.close();
      } catch (_) {}
    }
  }
}

final class _RemoteProcessCodexSession implements CodexSession {
  _RemoteProcessCodexSession(this._session);

  final RemoteServerProcessSession _session;

  @override
  Stream<Uint8List> get stdout => _session.stdout;

  @override
  Stream<Uint8List> get stderr => _session.stderr;

  @override
  Future<void> get done => _session.done;

  @override
  void write(Uint8List data) => _session.write(data);

  @override
  void terminate() => _session.terminate();
}

final class _WebSocketCodexSession implements CodexSession {
  _WebSocketCodexSession(this._channel, this._webSocketKey) {
    _subscription = _channel.stream.listen(
      _consume,
      onError: _fail,
      onDone: _finish,
      cancelOnError: true,
    );
    unawaited(_channel.done.then<void>((_) => _finish(), onError: _fail));
  }

  static const _acceptSalt = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
  static const _maxFrameBytes = 16 * 1024 * 1024;

  final SSHSocket _channel;
  final String _webSocketKey;
  final StreamController<Uint8List> _stdout = StreamController<Uint8List>();
  final StreamController<Uint8List> _stderr = StreamController<Uint8List>();
  final Completer<void> _ready = Completer<void>();
  final Completer<void> _done = Completer<void>();
  final Random _random = Random.secure();
  final List<int> _buffer = <int>[];
  final BytesBuilder _fragment = BytesBuilder(copy: false);
  StreamSubscription<Uint8List>? _subscription;
  int? _fragmentOpcode;
  int _fragmentLength = 0;
  bool _handshakeComplete = false;
  bool _terminated = false;

  Future<void> get ready => _ready.future;

  @override
  Stream<Uint8List> get stdout => _stdout.stream;

  @override
  Stream<Uint8List> get stderr => _stderr.stream;

  @override
  Future<void> get done => _done.future;

  @override
  void write(Uint8List data) {
    if (_terminated || !_handshakeComplete) {
      throw StateError('Codex WebSocket 尚未连接');
    }
    final text = utf8.decode(data).trim();
    if (text.isEmpty) return;
    _sendFrame(0x1, utf8.encode(text));
  }

  @override
  void terminate() {
    if (_terminated) return;
    _terminated = true;
    try {
      _channel.destroy();
    } catch (_) {}
    unawaited(_subscription?.cancel());
    _closeControllers();
    if (!_ready.isCompleted) {
      _ready.completeError(StateError('Codex WebSocket 已关闭'));
    }
    if (!_done.isCompleted) _done.complete();
  }

  void _consume(Uint8List chunk) {
    if (_terminated || chunk.isEmpty) return;
    _buffer.addAll(chunk);
    try {
      if (!_handshakeComplete && !_consumeHandshake()) return;
      _consumeFrames();
    } catch (error, stack) {
      _fail(error, stack);
    }
  }

  bool _consumeHandshake() {
    final headerEnd = _indexOfHeaderEnd(_buffer);
    if (headerEnd < 0) {
      if (_buffer.length > 32 * 1024) {
        throw StateError('Codex WebSocket 握手响应过大');
      }
      return false;
    }
    final header = latin1.decode(_buffer.sublist(0, headerEnd));
    _buffer.removeRange(0, headerEnd + 4);
    final lines = header.split('\r\n');
    if (lines.isEmpty ||
        !RegExp(r'^HTTP/1\.[01] 101(?:\s|$)').hasMatch(lines[0])) {
      throw StateError('Codex WebSocket 握手失败：${lines.firstOrNull ?? '空响应'}');
    }
    final headers = <String, String>{};
    for (final line in lines.skip(1)) {
      final separator = line.indexOf(':');
      if (separator <= 0) continue;
      headers[line.substring(0, separator).trim().toLowerCase()] = line
          .substring(separator + 1)
          .trim();
    }
    final expected = base64.encode(
      sha1.convert(utf8.encode('$_webSocketKey$_acceptSalt')).bytes,
    );
    if (headers['sec-websocket-accept'] != expected) {
      throw StateError('Codex WebSocket 握手校验失败');
    }
    _handshakeComplete = true;
    if (!_ready.isCompleted) _ready.complete();
    return true;
  }

  void _consumeFrames() {
    while (_buffer.length >= 2) {
      final first = _buffer[0];
      final second = _buffer[1];
      if ((first & 0x70) != 0) throw StateError('不支持的 WebSocket 扩展帧');
      final finished = (first & 0x80) != 0;
      final opcode = first & 0x0f;
      final masked = (second & 0x80) != 0;
      var payloadLength = second & 0x7f;
      var offset = 2;
      if (payloadLength == 126) {
        if (_buffer.length < 4) return;
        payloadLength = (_buffer[2] << 8) | _buffer[3];
        offset = 4;
      } else if (payloadLength == 127) {
        if (_buffer.length < 10) return;
        var length = 0;
        for (var index = 2; index < 10; index++) {
          length = (length << 8) | _buffer[index];
        }
        payloadLength = length;
        offset = 10;
      }
      if (payloadLength > _maxFrameBytes) {
        throw StateError('Codex WebSocket 消息过大');
      }
      final maskBytes = masked ? 4 : 0;
      if (_buffer.length < offset + maskBytes + payloadLength) return;
      List<int>? mask;
      if (masked) {
        mask = _buffer.sublist(offset, offset + 4);
        offset += 4;
      }
      final payload = Uint8List.fromList(
        _buffer.sublist(offset, offset + payloadLength),
      );
      _buffer.removeRange(0, offset + payloadLength);
      if (mask != null) {
        for (var index = 0; index < payload.length; index++) {
          payload[index] ^= mask[index % 4];
        }
      }
      _handleFrame(opcode, finished, payload);
      if (_terminated) return;
    }
  }

  void _handleFrame(int opcode, bool finished, Uint8List payload) {
    if (opcode >= 0x8 && (!finished || payload.length > 125)) {
      throw StateError('无效的 WebSocket 控制帧');
    }
    switch (opcode) {
      case 0x0:
        if (_fragmentOpcode == null) throw StateError('意外的 WebSocket 延续帧');
        _fragmentLength += payload.length;
        if (_fragmentLength > _maxFrameBytes) {
          throw StateError('Codex WebSocket 分片消息过大');
        }
        _fragment.add(payload);
        if (finished) {
          final fragmentOpcode = _fragmentOpcode!;
          _fragmentOpcode = null;
          _fragmentLength = 0;
          final message = _fragment.takeBytes();
          if (fragmentOpcode != 0x1) {
            throw StateError('Codex WebSocket 返回了二进制消息');
          }
          _emitText(message);
        }
      case 0x1:
        if (_fragmentOpcode != null) throw StateError('WebSocket 分片尚未结束');
        if (finished) {
          _emitText(payload);
        } else {
          _fragmentOpcode = opcode;
          _fragmentLength = payload.length;
          _fragment.add(payload);
        }
      case 0x2:
        throw StateError('Codex WebSocket 返回了二进制消息');
      case 0x8:
        if (!_terminated) _sendFrame(0x8, payload);
        _finish();
      case 0x9:
        _sendFrame(0xA, payload);
      case 0xA:
        break;
      default:
        throw StateError('未知的 WebSocket 帧类型：$opcode');
    }
  }

  void _emitText(List<int> payload) {
    final text = utf8.decode(payload);
    if (!_stdout.isClosed) {
      _stdout.add(Uint8List.fromList(utf8.encode('$text\n')));
    }
  }

  void _sendFrame(int opcode, List<int> payload) {
    if (_terminated) return;
    final bytes = BytesBuilder(copy: false);
    bytes.addByte(0x80 | opcode);
    final length = payload.length;
    if (length <= 125) {
      bytes.addByte(0x80 | length);
    } else if (length <= 0xffff) {
      bytes.add(<int>[0x80 | 126, length >> 8, length & 0xff]);
    } else {
      bytes.addByte(0x80 | 127);
      for (var shift = 56; shift >= 0; shift -= 8) {
        bytes.addByte((length >> shift) & 0xff);
      }
    }
    final mask = List<int>.generate(4, (_) => _random.nextInt(256));
    bytes.add(mask);
    bytes.add(
      List<int>.generate(
        length,
        (index) => payload[index] ^ mask[index % mask.length],
        growable: false,
      ),
    );
    _channel.sink.add(bytes.takeBytes());
  }

  void _fail(Object error, [StackTrace? stack]) {
    if (_terminated) return;
    if (!_ready.isCompleted) {
      _ready.completeError(error, stack ?? StackTrace.current);
    } else if (!_stdout.isClosed) {
      _stdout.addError(error, stack ?? StackTrace.current);
    }
    terminate();
  }

  void _finish() {
    if (_terminated) return;
    _terminated = true;
    try {
      _channel.destroy();
    } catch (_) {}
    unawaited(_subscription?.cancel());
    _closeControllers();
    if (!_ready.isCompleted) {
      _ready.completeError(StateError('Codex WebSocket 握手前已关闭'));
    }
    if (!_done.isCompleted) _done.complete();
  }

  void _closeControllers() {
    if (!_stdout.isClosed) unawaited(_stdout.close());
    if (!_stderr.isClosed) unawaited(_stderr.close());
  }
}

int _indexOfHeaderEnd(List<int> bytes) {
  for (var index = 0; index + 3 < bytes.length; index++) {
    if (bytes[index] == 13 &&
        bytes[index + 1] == 10 &&
        bytes[index + 2] == 13 &&
        bytes[index + 3] == 10) {
      return index;
    }
  }
  return -1;
}

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
        RemoteAgentThreadPaginationClient,
        RemoteAgentTurnClient,
        RemoteAgentSteerClient,
        RemoteAgentThreadCreateClient,
        RemoteAgentApprovalClient,
        RemoteAgentThreadMutationClient,
        RemoteAgentGlobalSettingsClient,
        RemoteAgentApiModelClient,
        RemoteAgentRuntimeClient,
        RemoteAgentGenerationClient,
        RemoteAgentKeepAliveClient,
        RemoteAgentIndependentConnectionClient,
        RemoteAgentDurableSessionClient {
  CodexAgentClient({
    this.clientVersion = '1.8.0',
    this.requestTimeout = const Duration(seconds: 120),
    this.threadRequestTimeout = const Duration(seconds: 180),
    this.maxLineChars = 8 * 1024 * 1024,
    this.useDurableTransport = false,
    CodexSessionOpener? sessionOpener,
    this.dedicatedHostFactory,
    AgentKind processAgent = AgentKind.codex,
  }) : _sessionOpener =
           sessionOpener ??
           ((host, command) => _openSession(host, command, processAgent)),
       _usesDefaultSessionOpener = sessionOpener == null;

  static const _stderrLineLimit = 8 * 1024;
  static const _oversizedPrefixLimit = 64 * 1024;
  static const _goalReadTimeout = Duration(seconds: 6);

  final String clientVersion;
  final Duration requestTimeout;
  final Duration threadRequestTimeout;
  final int maxLineChars;

  /// Keep the default on the legacy SSH stdio path. It is the transport used
  /// by the old Android client and is required for reliable collaboration
  /// turns on hosts where the detached socket path is unavailable.
  final bool useDurableTransport;
  final CodexSessionOpener _sessionOpener;
  final bool _usesDefaultSessionOpener;
  final CodexDedicatedHostFactory? dedicatedHostFactory;

  final CodexProtocolSession _protocol = CodexProtocolSession();
  final Map<CodexRequestId, Completer<CodexRpcResponse>> _pending = {};
  final Map<CodexRequestId, CodexServerRequest> _serverRequests = {};
  final StreamController<RemoteAgentEvent> _eventController =
      StreamController<RemoteAgentEvent>.broadcast(sync: true);

  CodexSession? _session;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  CodexProtocolGeneration? _scope;
  Future<void> _writeTail = Future<void>.value();
  Future<void>? _keepAliveRequest;
  bool _closed = false;
  bool _connected = false;
  bool _lossEmitted = false;
  RemoteServerClient? _dedicatedHost;
  RemoteServerClient? _settingsHost;
  ServerProfile? _connectedProfile;
  String _stdoutBuffer = '';
  String _oversizedStdoutPrefix = '';
  bool _discardStdoutLine = false;
  String _stderrBuffer = '';
  bool _discardStderrLine = false;
  String? _durableStopCommand;
  bool _connectedHostIsLocal = false;
  String? _modelProvider;

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
  bool get usesIndependentConnection =>
      dedicatedHostFactory != null && !_connectedHostIsLocal;

  @override
  Stream<RemoteAgentEvent> get events => _eventController.stream;

  @override
  Future<AgentRuntimeInspection> inspectRuntime(
    ServerProfile profile,
    RemoteServerClient host,
  ) async {
    if (host is RemoteServerCodexRuntimeClient) {
      return (host as RemoteServerCodexRuntimeClient).inspectCodexRuntime(
        profile,
      );
    }
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
    if (host is RemoteServerCodexRuntimeClient) {
      return (host as RemoteServerCodexRuntimeClient).installCodexRuntime(
        profile,
        onProgress: onProgress,
      );
    }
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
    if (host is RemoteServerCodexRuntimeClient) {
      return (host as RemoteServerCodexRuntimeClient).uninstallCodexRuntime(
        profile,
      );
    }
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
    _connectedHostIsLocal = host is LocalRemoteServerClient;

    var sessionHost = host;
    RemoteServerClient? dedicatedHost;
    final dedicatedHostFactory = this.dedicatedHostFactory;
    if (dedicatedHostFactory != null && host is! LocalRemoteServerClient) {
      dedicatedHost = dedicatedHostFactory();
      try {
        await dedicatedHost.connect(profile);
      } catch (_) {
        dedicatedHost.close();
        rethrow;
      }
      _dedicatedHost = dedicatedHost;
      sessionHost = dedicatedHost;
    }

    final scope = _protocol.beginGeneration();
    final command = buildCodexAppServerCommand(profile);
    late CodexSession session;
    try {
      if (useDurableTransport &&
          _usesDefaultSessionOpener &&
          sessionHost is! LocalRemoteServerClient &&
          supportsDurableCodexAppServer(profile.remoteCommand)) {
        try {
          final durable = buildDurableCodexAppServerCommands(profile);
          session = await _openDurableSession(sessionHost, durable);
          _durableStopCommand = durable.stopCommand;
          _emitDiagnostic(
            '${kind.label} durable_transport=unix_socket state=reused_or_started',
            isTransport: true,
          );
        } catch (error) {
          final durable = buildDurableCodexAppServerCommands(profile);
          try {
            await sessionHost.run(
              durable.stopCommand,
              timeout: const Duration(seconds: 5),
              maxOutputBytes: 16 * 1024,
            );
          } catch (_) {}
          _durableStopCommand = null;
          _emitDiagnostic(
            '${kind.label} durable_transport=fallback_stdio detail=${_short(error)}',
            isTransport: true,
          );
          session = await _sessionOpener(sessionHost, command);
        }
      } else {
        _durableStopCommand = null;
        session = await _sessionOpener(sessionHost, command);
      }
    } catch (_) {
      _protocol.invalidateGeneration();
      await _disconnectDedicatedHost();
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
    if (dedicatedHost != null) {
      _watchDedicatedHost(dedicatedHost, scope);
    }
    _listen(session, scope);

    try {
      final initialize = await _request(
        scope.initialize(clientVersion: clientVersion),
        timeout: requestTimeout,
      );
      initialize.resultOrThrow();
      await _write(scope.initialized().encodeLine());
      _connected = true;
      // Settings and runtime operations remain on the host transport. The
      // dedicated connection is reserved for the long-lived Agent channel.
      _settingsHost = host;
      _connectedProfile = profile;
      if (kind == AgentKind.codex) {
        await _loadModelProviderBestEffort(profile);
      }
    } catch (_) {
      await disconnect();
      rethrow;
    }
  }

  /// Stops a durable remote app-server only for an explicit user disconnect.
  /// Transport-loss recovery calls [disconnect] directly and deliberately
  /// leaves the Unix-socket server running so an in-flight turn can continue.
  @override
  Future<void> stopDurableRemoteSession() async {
    final command = _durableStopCommand;
    final host = _settingsHost;
    _durableStopCommand = null;
    if (command == null || host == null || !host.isConnected) return;
    try {
      await host.run(
        command,
        timeout: const Duration(seconds: 8),
        maxOutputBytes: 16 * 1024,
      );
    } catch (_) {
      // Explicit local disconnect must still complete if the remote cleanup
      // races a network loss or the daemon has already exited.
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
    return listThreadsPage(searchTerm: searchTerm);
  }

  @override
  Future<AgentThreadPage> listThreadsPage({
    String? searchTerm,
    String? cursor,
  }) async {
    final scope = _requireScope();
    final response = await _request(
      scope.threadList(
        searchTerm: searchTerm,
        cursor: cursor,
        modelProviders: _modelProvider == null
            ? null
            : <String>[_modelProvider!],
      ),
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
    _modelProvider = null;
    _protocol.invalidateGeneration();
    _connected = false;
    _scope = null;
    _serverRequests.clear();
    _failPending(StateError('${kind.label} 通道已断开'));
    final session = _session;
    _session = null;
    await _cancelReaders();
    try {
      session?.terminate();
    } catch (_) {
      // A transport may already have closed while the host state propagated.
    }
    await _disconnectDedicatedHost();
    await session?.done.catchError((_) {});
  }

  Future<void> _loadModelProviderBestEffort(ServerProfile profile) async {
    try {
      final settings = await readGlobalSettings(
        profile,
      ).timeout(const Duration(seconds: 8));
      final provider = settings.modelProvider.trim();
      _modelProvider = provider.isEmpty ? 'openai' : provider;
    } catch (error) {
      // Older wrappers and lightweight test hosts may not expose the settings
      // script. Without a provider filter, the parser still retains the
      // server-provided identity and the list remains usable.
      _modelProvider = null;
      _emitDiagnostic(
        '${kind.label} provider_unavailable detail=${_short(error)}',
      );
    }
  }

  @override
  Future<void> keepAlive() {
    final host = _dedicatedHost;
    if (host == null ||
        host is! RemoteServerKeepAliveClient ||
        !host.isConnected) {
      return Future<void>.value();
    }
    final pending = _keepAliveRequest;
    if (pending != null) return pending;
    final keepAliveHost = host as RemoteServerKeepAliveClient;
    // Coordinate client-initiated JSONL writes with the SSH global request.
    // The host transport is separate, so metrics and file channels cannot
    // enter this queue.
    late final Future<void> request;
    final previous = _writeTail;
    request = previous
        .catchError((_) {})
        .then((_) => keepAliveHost.keepAlive())
        .whenComplete(() {
          if (identical(_keepAliveRequest, request)) {
            _keepAliveRequest = null;
          }
        });
    _writeTail = request;
    _keepAliveRequest = request;
    return request;
  }

  Future<void> _disconnectDedicatedHost() async {
    final host = _dedicatedHost;
    _dedicatedHost = null;
    if (host == null) return;
    try {
      await host.disconnect();
    } catch (_) {
      host.close();
    }
  }

  void _watchDedicatedHost(
    RemoteServerClient host,
    CodexProtocolGeneration scope,
  ) {
    unawaited(() async {
      try {
        await host.done;
        if (identical(_dedicatedHost, host) && scope.isCurrent) {
          _emitDiagnostic(
            '${kind.label} SSH transport_closed generation=${scope.value}',
            isTransport: true,
          );
        }
      } catch (error) {
        if (identical(_dedicatedHost, host) && scope.isCurrent) {
          _emitDiagnostic(
            '${kind.label} SSH transport_error generation=${scope.value} '
            'detail=${_short(error)}',
            isTransport: true,
          );
        }
      }
    }());
  }

  @override
  Future<AgentGlobalSettings> readGlobalSettings(ServerProfile profile) async {
    final connectedHost = _requireConnectedSettingsHost(profile);
    if (connectedHost is RemoteServerCodexSettingsClient) {
      return (connectedHost as RemoteServerCodexSettingsClient)
          .readCodexSettings(profile);
    }
    final host = _requireScriptSettingsHost(connectedHost);
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
    final connectedHost = _requireConnectedSettingsHost(profile);
    if (connectedHost is RemoteServerCodexSettingsClient) {
      return (connectedHost as RemoteServerCodexSettingsClient)
          .writeCodexSettings(
            profile,
            baseUrl: baseUrl,
            apiKey: apiKey,
            proxyUrl: proxyUrl,
            defaultModel: defaultModel,
            defaultReasoningEffort: defaultReasoningEffort,
            preserveCurrentProvider: preserveCurrentProvider,
          );
    }
    final host = _requireScriptSettingsHost(connectedHost);
    final output = await host.runShellScript(
      buildWriteCodexGlobalSettingsScript(
        baseUrl: baseUrl,
        apiKey: apiKey,
        proxyUrl: proxyUrl,
        defaultModel: defaultModel,
        defaultReasoningEffort: defaultReasoningEffort,
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
    final connectedHost = _requireConnectedSettingsHost(profile);
    if (connectedHost is RemoteServerCodexSettingsClient) {
      return (connectedHost as RemoteServerCodexSettingsClient)
          .testCodexSettings(
            profile,
            baseUrl: baseUrl,
            apiKey: apiKey,
            proxyUrl: proxyUrl,
            testModel: testModel,
            apiProtocol: apiProtocol,
          );
    }
    final host = _requireScriptSettingsHost(connectedHost);
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
    final connectedHost = _requireConnectedSettingsHost(profile);
    if (connectedHost is RemoteServerCodexSettingsClient) {
      return (connectedHost as RemoteServerCodexSettingsClient)
          .fetchCodexApiModels(
            profile,
            baseUrl: baseUrl,
            apiKey: apiKey,
            proxyUrl: proxyUrl,
          );
    }
    final host = _requireScriptSettingsHost(connectedHost);
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

  RemoteServerClient _requireConnectedSettingsHost(ServerProfile profile) {
    final host = _settingsHost;
    final connectedProfile = _connectedProfile;
    if (!isConnected || host == null || connectedProfile == null) {
      throw StateError('${kind.label} 尚未连接');
    }
    if (!connectedProfile.hasSameConnectionIdentity(profile)) {
      throw StateError('${kind.label} 连接配置已更新');
    }
    return host;
  }

  RemoteServerScriptClient _requireScriptSettingsHost(
    RemoteServerClient host,
  ) => host is RemoteServerScriptClient
      ? host as RemoteServerScriptClient
      : throw UnsupportedError('当前 Host 不支持安全执行配置操作');

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
      // Do not call SSHSession.flush() here. dartssh2 implements flush by
      // binding the raw Socket sink to a stream; the channel upload loop can
      // concurrently add the packet and raises "StreamSink is bound".
    });
    _writeTail = next;
    return next;
  }

  void _listen(CodexSession session, CodexProtocolGeneration scope) {
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

  void _emitDiagnostic(
    String message, {
    bool isStderr = false,
    bool isTransport = false,
  }) {
    final sanitized = sanitizeAgentDiagnostic(message);
    if (sanitized.isEmpty) return;
    _emit(
      RemoteAgentDiagnostic(
        _short(sanitized),
        isStderr: isStderr,
        isTransport: isTransport,
      ),
    );
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

String sanitizeAgentDiagnostic(String value) => value
    .replaceAll(
      RegExp(r'\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1B\\))'),
      '',
    )
    .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), '')
    .trim();

Future<CodexSession> _openSession(
  RemoteServerClient host,
  String command,
  AgentKind agent,
) async {
  if (host is RemoteServerAgentProcessClient) {
    final session = await (host as RemoteServerAgentProcessClient)
        .openAgentAppServer(agent);
    return _RemoteProcessCodexSession(session);
  }
  if (host is RemoteServerCodexProcessClient) {
    final session = await (host as RemoteServerCodexProcessClient)
        .openCodexAppServer();
    return _RemoteProcessCodexSession(session);
  }
  final session = await host.requireSshClient().execute(command);
  return _SshCodexSession(session);
}

Future<CodexSession> _openDurableSession(
  RemoteServerClient host,
  DurableCodexAppServerCommands commands,
) async {
  final output = await host.run(
    commands.startCommand,
    timeout: const Duration(seconds: 15),
    maxOutputBytes: 32 * 1024,
  );
  final socketLine = output
      .split(RegExp(r'\r?\n'))
      .lastWhere(
        (line) => line.startsWith(_durableSocketMarker),
        orElse: () => '',
      );
  final socketPath = socketLine.isEmpty
      ? ''
      : socketLine.substring(_durableSocketMarker.length).trim();
  if (!socketPath.startsWith('/') || socketPath.length > 4096) {
    throw StateError('远端 Codex app-server 没有返回有效的 Unix socket');
  }

  final channel = await host
      .requireSshClient()
      .forwardLocalUnix(socketPath)
      .timeout(const Duration(seconds: 8));
  return openCodexWebSocketSession(channel);
}

/// Performs an RFC 6455 client handshake over an already-forwarded SSH
/// stream. Exposed at the package boundary so the framing contract can be
/// tested without opening a real SSH connection.
Future<CodexSession> openCodexWebSocketSession(
  SSHSocket channel, {
  String? webSocketKey,
}) async {
  final random = Random.secure();
  final key =
      webSocketKey ??
      base64.encode(
        Uint8List.fromList(List<int>.generate(16, (_) => random.nextInt(256))),
      );
  final session = _WebSocketCodexSession(channel, key);
  channel.sink.add(
    ascii.encode(
      'GET / HTTP/1.1\r\n'
      'Host: localhost\r\n'
      'Upgrade: websocket\r\n'
      'Connection: Upgrade\r\n'
      'Sec-WebSocket-Key: $key\r\n'
      'Sec-WebSocket-Version: 13\r\n'
      '\r\n',
    ),
  );
  await channel.flush();
  try {
    await session.ready.timeout(const Duration(seconds: 8));
    return session;
  } catch (_) {
    session.terminate();
    rethrow;
  }
}

const _durableSocketMarker = '__CODEX_REMOTE_SOCKET=';

class DurableCodexAppServerCommands {
  const DurableCodexAppServerCommands({
    required this.startCommand,
    required this.stopCommand,
    required this.key,
  });

  final String startCommand;
  final String stopCommand;
  final String key;
}

bool supportsDurableCodexAppServer(String remoteCommand) {
  try {
    _durableRemoteCommand(remoteCommand);
    return true;
  } catch (_) {
    return false;
  }
}

DurableCodexAppServerCommands buildDurableCodexAppServerCommands(
  ServerProfile profile,
) {
  final durableRemoteCommand = _durableRemoteCommand(profile.remoteCommand);
  final keyMaterial = <String>[
    profile.id,
    profile.workspace.trim(),
    profile.remoteCommand.trim(),
  ].join('\u0000');
  final key = sha256
      .convert(utf8.encode(keyMaterial))
      .toString()
      .substring(0, 24);
  final workspace = profile.workspace.trim();
  final changeDirectory = workspace.isEmpty
      ? ''
      : 'cd -- ${_shellQuote(workspace)} && ';
  final daemonCommand =
      'if [ -r "\$HOME/.codex/codex-remote.env" ]; then '
      '. "\$HOME/.codex/codex-remote.env"; fi; '
      '$changeDirectory'
      'exec $durableRemoteCommand';
  final paths = _durablePathsScript(key);
  final startScript =
      '''
set -eu
umask 077
$paths
mkdir -p "\$dir"
pid_matches() {
  candidate=\$1
  [ -n "\$candidate" ] && kill -0 "\$candidate" 2>/dev/null || return 1
  if [ -r "/proc/\$candidate/cmdline" ]; then
    tr '\\000' ' ' <"/proc/\$candidate/cmdline" | grep -F -- "\$socket" >/dev/null 2>&1
  fi
}
attempt=0
while ! mkdir "\$lockdir" 2>/dev/null; do
  if [ -f "\$pidfile" ]; then
    pid=\$(cat "\$pidfile" 2>/dev/null || true)
    case "\$pid" in ''|*[!0-9]*) pid='' ;; esac
    if pid_matches "\$pid" && [ -S "\$socket" ]; then
      printf '%s%s\n' '$_durableSocketMarker' "\$socket"
      exit 0
    fi
  fi
  attempt=\$((attempt + 1))
  if [ "\$attempt" -ge 80 ]; then
    echo '等待 Codex app-server 启动锁超时' >&2
    exit 1
  fi
  sleep 0.1
done
trap 'rmdir "\$lockdir" 2>/dev/null || true' EXIT HUP INT TERM
if [ -f "\$pidfile" ]; then
  pid=\$(cat "\$pidfile" 2>/dev/null || true)
  case "\$pid" in ''|*[!0-9]*) pid='' ;; esac
  if pid_matches "\$pid" && [ -S "\$socket" ]; then
    printf '%s%s\n' '$_durableSocketMarker' "\$socket"
    exit 0
  fi
fi
rm -f "\$socket" "\$pidfile"
export CODEX_REMOTE_SOCKET="\$socket"
if command -v setsid >/dev/null 2>&1; then
  nohup setsid sh -c ${_shellQuote(daemonCommand)} </dev/null >"\$logfile" 2>&1 &
else
  nohup sh -c ${_shellQuote(daemonCommand)} </dev/null >"\$logfile" 2>&1 &
fi
pid=\$!
printf '%s\n' "\$pid" >"\$pidfile"
attempt=0
while [ ! -S "\$socket" ]; do
  if ! pid_matches "\$pid"; then
    tail -c 4096 "\$logfile" 2>/dev/null >&2 || true
    exit 1
  fi
  attempt=\$((attempt + 1))
  if [ "\$attempt" -ge 100 ]; then
    echo 'Codex app-server Unix socket 启动超时' >&2
    exit 1
  fi
  sleep 0.1
done
printf '%s%s\n' '$_durableSocketMarker' "\$socket"
''';
  final stopScript =
      '''
set -u
$paths
pid_matches() {
  candidate=\$1
  [ -n "\$candidate" ] && kill -0 "\$candidate" 2>/dev/null || return 1
  if [ -r "/proc/\$candidate/cmdline" ]; then
    tr '\\000' ' ' <"/proc/\$candidate/cmdline" | grep -F -- "\$socket" >/dev/null 2>&1
  fi
}
if [ -f "\$pidfile" ]; then
  pid=\$(cat "\$pidfile" 2>/dev/null || true)
  case "\$pid" in ''|*[!0-9]*) pid='' ;; esac
  if pid_matches "\$pid"; then
    kill "\$pid" 2>/dev/null || true
    attempt=0
    while pid_matches "\$pid" && [ "\$attempt" -lt 20 ]; do
      attempt=\$((attempt + 1))
      sleep 0.1
    done
    if pid_matches "\$pid"; then kill -9 "\$pid" 2>/dev/null || true; fi
  fi
fi
rm -f "\$socket" "\$pidfile"
rmdir "\$lockdir" 2>/dev/null || true
''';
  return DurableCodexAppServerCommands(
    startCommand: 'sh -c ${_shellQuote(startScript)}',
    stopCommand: 'sh -c ${_shellQuote(stopScript)}',
    key: key,
  );
}

String _durablePathsScript(String key) =>
    '''
base=\${XDG_RUNTIME_DIR:-/tmp/codex-remote-\$(id -u)}
dir="\$base/codex-remote"
socket="\$dir/$key.sock"
pidfile="\$dir/$key.pid"
lockdir="\$dir/$key.lock"
logfile="\$dir/$key.log"
''';

String _durableRemoteCommand(String value) {
  final command = value.trim();
  if (command.isEmpty ||
      !RegExp(r'(^|\s)app-server(?=\s|$)').hasMatch(command)) {
    throw StateError('远程命令不是 Codex app-server');
  }
  if (RegExp(
    r'''--listen(?:\s+|=)(?:"unix://[^\"]*"|'unix://[^']*'|unix://\S*)''',
  ).hasMatch(command)) {
    throw StateError('远程命令已经指定 Unix socket');
  }
  final stdioListen = RegExp(
    r'''--listen(?:\s+|=)(?:"stdio://"|'stdio://'|stdio://)''',
  );
  if (stdioListen.hasMatch(command)) {
    return command.replaceFirst(
      stdioListen,
      r'--listen "unix://$CODEX_REMOTE_SOCKET"',
    );
  }
  final stdioFlag = RegExp(r'(^|\s)--stdio(?=\s|$)');
  if (stdioFlag.hasMatch(command)) {
    return command.replaceFirstMapped(
      stdioFlag,
      (match) => '${match.group(1)}--listen "unix://\$CODEX_REMOTE_SOCKET"',
    );
  }
  if (RegExp(r'(^|\s)--listen(?=\s|=)').hasMatch(command)) {
    throw StateError('远程命令使用了非 stdio listener');
  }
  return '$command --listen "unix://\$CODEX_REMOTE_SOCKET"';
}

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
