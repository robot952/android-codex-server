import 'dart:async';

import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/ssh/server_connection_manager.dart';
import 'package:codex_remote/src/ssh/ssh_server_client.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeClient implements RemoteServerClient {
  _FakeClient({this.connectError, this.probeResult});

  final Object? connectError;
  final Future<String>? probeResult;
  final Completer<void> closed = Completer<void>();
  bool connected = false;
  bool wasClosed = false;
  int connectCount = 0;

  @override
  Future<void> connect(ServerProfile profile) async {
    connectCount++;
    if (connectError case final error?) throw error;
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
  Future<String> probeFingerprint(ServerProfile profile) async =>
      probeResult == null ? 'SHA256:test' : await probeResult!;

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
    wasClosed = true;
    connected = false;
    if (!closed.isCompleted) closed.complete();
  }
}

void main() {
  const first = ServerProfile(
    id: 'first',
    host: 'one.example',
    username: 'root',
    password: 'secret',
    authMode: AuthMode.password,
    hostFingerprint: 'SHA256:first',
  );

  test('normalizes OpenSSH SHA-256 fingerprints', () {
    expect(normalizeSshFingerprint(' abc== '), 'SHA256:abc');
    expect(normalizeSshFingerprint('sha256:abc='), 'SHA256:abc');
    expect(normalizeSshFingerprint(''), isEmpty);
  });

  test('reuses a client for display-only profile changes', () async {
    final created = <_FakeClient>[];
    final manager = ServerConnectionManager(
      clientFactory: () {
        final client = _FakeClient();
        created.add(client);
        return client;
      },
    );

    final original = manager.registerProfile(first);
    final renamed = manager.registerProfile(
      first.copyWith(name: 'Renamed', workspace: '/workspace'),
    );

    expect(identical(original, renamed), isTrue);
    expect(created, hasLength(1));
    await manager.close();
  });

  test(
    'replaces and closes a client when connection identity changes',
    () async {
      final created = <_FakeClient>[];
      final manager = ServerConnectionManager(
        clientFactory: () {
          final client = _FakeClient();
          created.add(client);
          return client;
        },
      );

      manager.registerProfile(first);
      manager.registerProfile(first.copyWith(host: 'two.example'));

      expect(created, hasLength(2));
      expect(created.first.wasClosed, isTrue);
      await manager.close();
    },
  );

  test('keeps multiple server states independent', () async {
    final manager = ServerConnectionManager(clientFactory: _FakeClient.new);
    const second = ServerProfile(
      id: 'second',
      host: 'two.example',
      username: 'root',
      password: 'secret',
      authMode: AuthMode.password,
      hostFingerprint: 'SHA256:second',
    );

    await Future.wait([manager.connect(first), manager.connect(second)]);

    expect(manager.states['first']?.phase, ConnectionPhase.connected);
    expect(manager.states['second']?.phase, ConnectionPhase.connected);
    await manager.disconnect('first');
    expect(manager.states['first']?.phase, ConnectionPhase.disconnected);
    expect(manager.states['second']?.phase, ConnectionPhase.connected);
    await manager.close();
  });

  test('stale close cannot overwrite a replacement connection', () async {
    final created = <_FakeClient>[];
    final manager = ServerConnectionManager(
      clientFactory: () {
        final client = _FakeClient();
        created.add(client);
        return client;
      },
    );
    await manager.connect(first);
    final replacement = first.copyWith(host: 'replacement.example');
    manager.registerProfile(replacement);
    await manager.connect(replacement);

    if (!created.first.closed.isCompleted) created.first.closed.complete();
    await Future<void>.delayed(Duration.zero);

    expect(manager.states['first']?.phase, ConnectionPhase.connected);
    await manager.close();
  });

  test('stale fingerprint probe cannot overwrite a replacement', () async {
    final oldFingerprint = Completer<String>();
    final clients = <_FakeClient>[
      _FakeClient(probeResult: oldFingerprint.future),
      _FakeClient(),
    ];
    final manager = ServerConnectionManager(
      clientFactory: () => clients.removeAt(0),
    );

    final staleProbe = manager.probeFingerprint(first);
    await Future<void>.delayed(Duration.zero);
    expect(manager.states['first']?.phase, ConnectionPhase.probing);

    final replacement = first.copyWith(host: 'replacement.example');
    manager.registerProfile(replacement);
    await manager.connect(replacement);
    oldFingerprint.complete('SHA256:old-host');

    await expectLater(staleProbe, throwsStateError);
    expect(manager.states['first']?.phase, ConnectionPhase.connected);
    await manager.close();
  });

  test('reports connection failures without affecting other entries', () async {
    final clients = <_FakeClient>[
      _FakeClient(connectError: StateError('认证失败')),
      _FakeClient(),
    ];
    final manager = ServerConnectionManager(
      clientFactory: () => clients.removeAt(0),
    );
    const second = ServerProfile(
      id: 'second',
      host: 'two.example',
      username: 'root',
      authMode: AuthMode.password,
      password: 'secret',
      hostFingerprint: 'SHA256:second',
    );

    await expectLater(manager.connect(first), throwsStateError);
    await manager.connect(second);

    expect(manager.states['first']?.phase, ConnectionPhase.failed);
    expect(manager.states['first']?.message, contains('认证失败'));
    expect(manager.states['second']?.phase, ConnectionPhase.connected);
    await manager.close();
  });
}
