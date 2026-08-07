import 'dart:async';

import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/ssh/server_connection_manager.dart';
import 'package:codex_remote/src/ssh/ssh_server_client.dart';
import 'package:codex_remote/src/ssh/terminal_manager.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

class _HostOnlyClient implements RemoteServerClient {
  final Completer<void> _closed = Completer<void>();
  bool connected = false;

  @override
  Future<void> connect(ServerProfile profile) async {
    connected = true;
  }

  @override
  Future<void> disconnect() async {
    close();
  }

  @override
  Future<void> get done => _closed.future;

  @override
  bool get isConnected => connected;

  @override
  Future<String> probeFingerprint(ServerProfile profile) async => 'test';

  @override
  Future<ServerMetrics> readServerMetrics(ServerProfile profile) async =>
      const ServerMetrics();

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
    if (!_closed.isCompleted) _closed.complete();
  }
}

void main() {
  test('quotes workspace paths for a POSIX shell', () {
    expect(posixShellQuote('/tmp/a b'), "'/tmp/a b'");
    expect(posixShellQuote("a'b"), "'a'\"'\"'b'");
  });

  test('keeps terminal state immutable when copied', () {
    const original = TerminalSessionState(
      profileId: 'server',
      profileName: '主机',
      endpoint: 'root@example:22',
    );
    final connected = original.copyWith(
      phase: TerminalPhase.connected,
      generation: 4,
    );

    expect(original.phase, TerminalPhase.disconnected);
    expect(original.generation, 0);
    expect(connected.profileId, 'server');
    expect(connected.phase, TerminalPhase.connected);
    expect(connected.generation, 4);
  });

  test(
    'reports unsupported PTY without leaking a connecting session',
    () async {
      final client = _HostOnlyClient();
      final connections = ServerConnectionManager(clientFactory: () => client);
      final manager = TerminalManager(connections);
      final profile = ServerProfile.create().copyWith(
        host: 'example.test',
        hostFingerprint: 'test',
      );

      await connections.connect(profile);
      manager.open(profile);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final state = manager.stateFor(profile.id);
      expect(state?.phase, TerminalPhase.failed);
      expect(state?.generation, 1);
      expect(manager.historyFor(profile.id, 1), isNotNull);

      await manager.close();
      await connections.close();
    },
  );
}
