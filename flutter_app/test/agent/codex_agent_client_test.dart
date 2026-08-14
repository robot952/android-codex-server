import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:codex_remote/src/agent/codex_agent_client.dart';
import 'package:codex_remote/src/agent/opencode_agent_client.dart';
import 'package:codex_remote/src/agent/remote_agent_client.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/ssh/ssh_server_client.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeCodexHost
    implements RemoteServerClient, RemoteServerKeepAliveClient {
  _FakeCodexHost({this.connected = true, this.keepAliveGate});

  bool connected;
  final Completer<void>? keepAliveGate;
  final Completer<void> closed = Completer<void>();
  int connectCount = 0;
  int disconnectCount = 0;
  int closeCount = 0;
  int runCount = 0;
  int keepAliveCount = 0;

  @override
  Future<void> connect(ServerProfile profile) async {
    connectCount++;
    connected = true;
  }

  @override
  Future<void> disconnect() async {
    disconnectCount++;
    connected = false;
    if (!closed.isCompleted) closed.complete();
  }

  @override
  Future<void> get done => closed.future;

  @override
  bool get isConnected => connected;

  @override
  Future<void> keepAlive() async {
    keepAliveCount++;
    await keepAliveGate?.future;
  }

  @override
  Future<ServerMetrics> readServerMetrics(ServerProfile profile) {
    throw UnimplementedError();
  }

  @override
  SSHClient requireSshClient() => throw UnimplementedError();

  @override
  Future<String> probeFingerprint(ServerProfile profile) {
    throw UnimplementedError();
  }

  @override
  Future<String> run(
    String command, {
    Duration timeout = const Duration(seconds: 15),
    int maxOutputBytes = 1024 * 1024,
  }) {
    runCount++;
    throw UnimplementedError();
  }

  @override
  void close() {
    closeCount++;
    connected = false;
    if (!closed.isCompleted) closed.complete();
  }

  void fail(Object error) {
    connected = false;
    if (!closed.isCompleted) closed.completeError(error);
  }
}

class _FakeCodexSession implements CodexSession, RemoteServerProcessSession {
  final StreamController<Uint8List> _stdout = StreamController<Uint8List>(
    sync: true,
  );
  final StreamController<Uint8List> _stderr = StreamController<Uint8List>(
    sync: true,
  );
  final List<String> writes = <String>[];
  final Completer<void> _done = Completer<void>();
  int flushCount = 0;
  bool terminated = false;

  @override
  Stream<Uint8List> get stdout => _stdout.stream;

  @override
  Stream<Uint8List> get stderr => _stderr.stream;

  @override
  Future<void> get done => _done.future;

  @override
  void write(Uint8List data) {
    final line = utf8.decode(data);
    writes.add(line);
    final payload = jsonDecode(line) as Map<String, Object?>;
    final id = payload['id'];
    if (id == null) return;
    scheduleMicrotask(() {
      if (!_stdout.isClosed) {
        _stdout.add(
          Uint8List.fromList(
            utf8.encode(
              '${jsonEncode(<String, Object?>{'id': id, 'result': {}})}\n',
            ),
          ),
        );
      }
    });
  }

  @override
  void terminate() {
    terminated = true;
    if (!_done.isCompleted) _done.complete();
    unawaited(_stdout.close());
    unawaited(_stderr.close());
  }
}

class _FakeLocalCodexHost extends _FakeCodexHost
    implements LocalRemoteServerClient, RemoteServerCodexProcessClient {
  _FakeLocalCodexHost(this.session);

  final RemoteServerProcessSession session;
  int openCount = 0;

  @override
  Future<RemoteServerProcessSession> openCodexAppServer() async {
    openCount++;
    return session;
  }
}

class _FakeLocalOpenCodeHost extends _FakeCodexHost
    implements LocalRemoteServerClient, RemoteServerAgentProcessClient {
  _FakeLocalOpenCodeHost(this.session);

  final RemoteServerProcessSession session;
  int openCount = 0;
  AgentKind? openedAgent;

  @override
  Future<RemoteServerProcessSession> openAgentAppServer(AgentKind agent) async {
    openCount++;
    openedAgent = agent;
    return session;
  }
}

class _FakeSshSocket implements SSHSocket {
  final StreamController<Uint8List> _incoming = StreamController<Uint8List>(
    sync: true,
  );
  final StreamController<List<int>> _outgoing = StreamController<List<int>>(
    sync: true,
  );
  final Completer<void> _done = Completer<void>();
  final List<Uint8List> writes = <Uint8List>[];

  _FakeSshSocket() {
    _outgoing.stream.listen((bytes) => writes.add(Uint8List.fromList(bytes)));
  }

  @override
  Stream<Uint8List> get stream => _incoming.stream;

  @override
  StreamSink<List<int>> get sink => _outgoing.sink;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() async => destroy();

  @override
  void destroy() {
    if (!_done.isCompleted) _done.complete();
    unawaited(_incoming.close());
    unawaited(_outgoing.close());
  }

  @override
  Future<void> flush() async {}

  void add(List<int> bytes) => _incoming.add(Uint8List.fromList(bytes));
}

void main() {
  test('builds the app-server command with env and a quoted workspace', () {
    const profile = ServerProfile(
      id: 'server',
      workspace: "/srv/team's app",
      remoteCommand: '~/.local/bin/codex-remote app-server --listen stdio://',
    );

    final command = buildCodexAppServerCommand(profile);

    expect(command, contains(r'. "$HOME/.codex/codex-remote.env"'));
    expect(command, contains("cd -- '/srv/team'\"'\"'s app' &&"));
    expect(
      command,
      endsWith('exec ~/.local/bin/codex-remote app-server --listen stdio://'),
    );
  });

  test('rejects an empty remote command', () {
    expect(
      () => buildCodexAppServerCommand(
        const ServerProfile(id: 'server', remoteCommand: '  '),
      ),
      throwsStateError,
    );
  });

  test('keeps legacy stdio as the default Agent transport', () async {
    final host = _FakeCodexHost();
    final client = CodexAgentClient();
    const profile = ServerProfile(
      id: 'server',
      host: 'example.com',
      username: 'root',
      hostFingerprint: 'SHA256:verified',
      remoteCommand: 'codex app-server --listen stdio://',
    );

    expect(client.useDurableTransport, isFalse);
    await expectLater(client.connect(profile, host), throwsA(anything));
    expect(host.runCount, 0);
    client.close();
  });

  test('builds a stable detached Unix-socket app-server command', () async {
    const profile = ServerProfile(
      id: 'server',
      workspace: "/srv/team's app",
      remoteCommand: 'codex app-server --listen stdio://',
    );

    final first = buildDurableCodexAppServerCommands(profile);
    final second = buildDurableCodexAppServerCommands(profile);

    expect(first.key, hasLength(24));
    expect(first.key, second.key);
    expect(first.startCommand, startsWith("sh -c '"));
    expect(first.startCommand, contains('nohup'));
    expect(first.startCommand, contains('setsid'));
    expect(first.startCommand, contains(r'CODEX_REMOTE_SOCKET'));
    expect(first.startCommand, isNot(contains('stdio://')));
    expect(first.stopCommand, contains('kill -9'));
    final syntax = await Process.run('sh', <String>[
      '-n',
      '-c',
      first.startCommand,
    ]);
    expect(syntax.exitCode, 0, reason: syntax.stderr.toString());
    expect(supportsDurableCodexAppServer(profile.remoteCommand), isTrue);
    expect(supportsDurableCodexAppServer('bridge --listen stdio://'), isFalse);
  });

  test('bridges JSONL over a masked WebSocket text frame', () async {
    const key = 'dGhlIHNhbXBsZSBub25jZQ==';
    final socket = _FakeSshSocket();
    final opening = openCodexWebSocketSession(socket, webSocketKey: key);
    await Future<void>.delayed(Duration.zero);

    expect(ascii.decode(socket.writes.single), contains('GET / HTTP/1.1'));
    socket.add(
      ascii.encode(
        'HTTP/1.1 101 Switching Protocols\r\n'
        'Upgrade: websocket\r\n'
        'Connection: Upgrade\r\n'
        'Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n'
        '\r\n',
      ),
    );
    final session = await opening;

    session.write(Uint8List.fromList(utf8.encode('{"id":1}\n')));
    final frame = socket.writes.last;
    expect(frame[0], 0x81);
    expect(frame[1] & 0x80, 0x80, reason: 'client frames must be masked');
    final payloadLength = frame[1] & 0x7f;
    final mask = frame.sublist(2, 6);
    final decoded = List<int>.generate(
      payloadLength,
      (index) => frame[6 + index] ^ mask[index % 4],
    );
    expect(utf8.decode(decoded), '{"id":1}');

    final response = utf8.encode('{"id":1,"result":{}}');
    final stdout = session.stdout.first;
    socket.add(<int>[0x81, response.length, ...response]);
    expect(utf8.decode(await stdout), '{"id":1,"result":{}}\n');

    session.terminate();
    await session.done;
  });

  test('writes JSONL without flushing the shared SSH socket', () async {
    final session = _FakeCodexSession();
    final client = CodexAgentClient(sessionOpener: (_, _) async => session);
    const profile = ServerProfile(
      id: 'server',
      host: 'example.com',
      username: 'root',
      hostFingerprint: 'SHA256:verified',
      remoteCommand: 'codex app-server --listen stdio://',
    );

    await client.connect(profile, _FakeCodexHost());
    await client.disconnect();

    expect(session.writes.length, 2);
    expect(session.flushCount, 0);
    expect(session.terminated, isTrue);
  });

  test('keeps the Agent on a dedicated SSH transport', () async {
    final session = _FakeCodexSession();
    final host = _FakeCodexHost();
    final dedicatedHost = _FakeCodexHost(connected: false);
    RemoteServerClient? openedHost;
    final client = CodexAgentClient(
      dedicatedHostFactory: () => dedicatedHost,
      sessionOpener: (sessionHost, _) async {
        openedHost = sessionHost;
        return session;
      },
    );
    const profile = ServerProfile(
      id: 'server',
      host: 'example.com',
      username: 'root',
      hostFingerprint: 'SHA256:verified',
      remoteCommand: 'codex app-server --listen stdio://',
    );

    await client.connect(profile, host);
    await client.keepAlive();

    expect(openedHost, same(dedicatedHost));
    expect(dedicatedHost.connectCount, 1);
    expect(dedicatedHost.keepAliveCount, 1);
    expect(host.connectCount, 0);
    expect(host.keepAliveCount, 0);

    await client.disconnect();

    expect(session.terminated, isTrue);
    expect(dedicatedHost.disconnectCount, 1);
    expect(host.disconnectCount, 0);
  });

  test('reuses JSONL protocol over a native Host process session', () async {
    final session = _FakeCodexSession();
    final host = _FakeLocalCodexHost(session);
    final dedicatedHost = _FakeCodexHost(connected: false);
    final client = CodexAgentClient(dedicatedHostFactory: () => dedicatedHost);
    const profile = ServerProfile(
      id: 'agent-local-windows',
      host: 'local-windows',
      port: 1,
      username: 'local',
      hostFingerprint: 'local-windows',
    );

    await client.connect(profile, host);

    expect(host.openCount, 1);
    expect(dedicatedHost.connectCount, 0);
    expect(client.usesIndependentConnection, isFalse);
    expect(session.writes, hasLength(2));
    expect(
      jsonDecode(session.writes.first),
      containsPair('method', 'initialize'),
    );
    expect(
      jsonDecode(session.writes.last),
      containsPair('method', 'initialized'),
    );

    await client.disconnect();
    expect(session.terminated, isTrue);
  });

  test(
    'OpenCode selects the native OpenCode process on a local Host',
    () async {
      final session = _FakeCodexSession();
      final host = _FakeLocalOpenCodeHost(session);
      final client = OpenCodeAgentClient(bridgeLoader: () async => 'bridge');
      const profile = ServerProfile(
        id: 'agent-local-windows',
        host: 'local-windows',
        port: 1,
        username: 'local',
        hostFingerprint: 'local-windows',
      );

      await client.connect(profile, host);

      expect(host.openCount, 1);
      expect(host.openedAgent, AgentKind.openCode);
      expect(session.writes, hasLength(2));

      await client.disconnect();
      client.close();
    },
  );

  test(
    'coalesces Agent heartbeats while the previous ping is pending',
    () async {
      final session = _FakeCodexSession();
      final gate = Completer<void>();
      final dedicatedHost = _FakeCodexHost(
        connected: false,
        keepAliveGate: gate,
      );
      final client = CodexAgentClient(
        dedicatedHostFactory: () => dedicatedHost,
        sessionOpener: (_, _) async => session,
      );
      const profile = ServerProfile(
        id: 'server',
        host: 'example.com',
        username: 'root',
        hostFingerprint: 'SHA256:verified',
        remoteCommand: 'codex app-server --listen stdio://',
      );

      await client.connect(profile, _FakeCodexHost());
      final first = client.keepAlive();
      final second = client.keepAlive();
      await Future<void>.delayed(Duration.zero);

      expect(dedicatedHost.keepAliveCount, 1);
      gate.complete();
      await Future.wait<void>([first, second]);
      expect(dedicatedHost.keepAliveCount, 1);

      await client.disconnect();
    },
  );

  test('sanitizes ANSI control sequences from Agent diagnostics', () {
    expect(
      sanitizeAgentDiagnostic(
        '\u001b[2m2026-08-10T10:45:20Z\u001b[0m '
        '\u001b[31mERROR\u001b[0m codex_app_server',
      ),
      '2026-08-10T10:45:20Z ERROR codex_app_server',
    );
  });

  test('reports the dedicated SSH transport close reason', () async {
    final session = _FakeCodexSession();
    final dedicatedHost = _FakeCodexHost(connected: false);
    final client = CodexAgentClient(
      dedicatedHostFactory: () => dedicatedHost,
      sessionOpener: (_, _) async => session,
    );
    const profile = ServerProfile(
      id: 'server',
      host: 'example.com',
      username: 'root',
      hostFingerprint: 'SHA256:verified',
      remoteCommand: 'codex app-server --listen stdio://',
    );

    await client.connect(profile, _FakeCodexHost());
    final diagnostic = client.events
        .where((event) => event is RemoteAgentDiagnostic)
        .cast<RemoteAgentDiagnostic>()
        .firstWhere((event) => event.isTransport);
    dedicatedHost.fail(StateError('socket aborted'));

    final event = await diagnostic;
    expect(event.message, contains('transport_error'));
    expect(event.message, contains('socket aborted'));

    await client.disconnect();
  });
}
