import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:codex_remote/src/agent/codex_agent_client.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/ssh/ssh_server_client.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeCodexHost implements RemoteServerClient {
  @override
  Future<void> connect(ServerProfile profile) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> get done => Future<void>.value();

  @override
  bool get isConnected => true;

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
    throw UnimplementedError();
  }

  @override
  void close() {}
}

class _FakeCodexSession implements CodexSession {
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
}
