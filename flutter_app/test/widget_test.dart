import 'dart:async';

import 'package:codex_remote/src/app/codex_remote_app.dart';
import 'package:codex_remote/src/app/app_controller.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/persistence/profile_store.dart';
import 'package:codex_remote/src/platform/local_linux_manager.dart';
import 'package:codex_remote/src/ssh/server_connection_manager.dart';
import 'package:codex_remote/src/ssh/ssh_server_client.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryStore implements ProfileStore {
  _MemoryStore([this.value = const StoredProfiles()]);

  StoredProfiles value;

  @override
  Future<StoredProfiles> load() async => value;

  @override
  Future<void> save(StoredProfiles value) async {
    this.value = value;
  }
}

class _BlockingClient implements RemoteServerClient {
  final Completer<void> connectGate = Completer<void>();
  final Completer<void> closed = Completer<void>();
  bool connected = false;

  @override
  Future<void> connect(ServerProfile profile) async {
    await connectGate.future;
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
  Future<String> probeFingerprint(ServerProfile profile) async => 'SHA256:test';

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
    if (!connectGate.isCompleted) {
      connectGate.completeError(StateError('closed'));
    }
    if (!closed.isCompleted) closed.complete();
  }
}

class _ChangedFingerprintClient implements RemoteServerClient {
  _ChangedFingerprintClient(this.actualFingerprint);

  final String actualFingerprint;
  final Completer<void> closed = Completer<void>();
  bool connected = false;

  @override
  Future<void> connect(ServerProfile profile) async {
    final expected = normalizeSshFingerprint(profile.hostFingerprint);
    if (expected != normalizeSshFingerprint(actualFingerprint)) {
      throw HostKeyMismatchException(expected, actualFingerprint);
    }
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
      actualFingerprint;

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
    if (!closed.isCompleted) closed.complete();
  }
}

const _profile = ServerProfile(
  id: 'server-one',
  name: '测试服务器',
  host: 'server.example',
  username: 'root',
  authMode: AuthMode.password,
  password: 'secret',
  hostFingerprint: 'SHA256:test',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('opens directly on the server list', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [profileStoreProvider.overrideWithValue(_MemoryStore())],
        child: const CodexRemoteApp(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Agent'), findsOneWidget);
    expect(find.text('服务器列表'), findsOneWidget);
    expect(find.text('服务器会话'), findsOneWidget);
    expect(find.text('本机 Linux'), findsOneWidget);
    expect(find.text('实验'), findsOneWidget);
    expect(find.text('还没有服务器'), findsOneWidget);
    expect(find.text('Flutter Demo'), findsNothing);
    final materialLocalizations = MaterialLocalizations.of(
      tester.element(find.text('服务器列表')),
    );
    expect(materialLocalizations.copyButtonLabel, '复制');
    expect(materialLocalizations.cutButtonLabel, '剪切');
    expect(materialLocalizations.pasteButtonLabel, '粘贴');
    expect(materialLocalizations.selectAllButtonLabel, '全选');
  });

  testWidgets('local Linux profile is not duplicated as a normal server', (
    tester,
  ) async {
    const instance = LocalLinuxInstance(
      port: 41234,
      password: 'generated-password',
      architecture: 'arm64-v8a',
      rootfsVersion: 'debian-test',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          profileStoreProvider.overrideWithValue(
            _MemoryStore(
              StoredProfiles(profiles: [localLinuxProfile(instance)]),
            ),
          ),
        ],
        child: const CodexRemoteApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('本机 Linux'), findsOneWidget);
    expect(find.text('添加第一台 SSH 服务器'), findsOneWidget);
    expect(find.text('1 台服务器 · 0 台已连接'), findsNothing);
  });

  testWidgets(
    'connection overlay covers the full 1.5K viewport and blocks back',
    (tester) async {
      tester.view.devicePixelRatio = 2.75;
      tester.view.physicalSize = const Size(1220, 2712);
      addTearDown(tester.view.reset);
      final client = _BlockingClient();
      final manager = ServerConnectionManager(clientFactory: () => client);
      addTearDown(manager.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            profileStoreProvider.overrideWithValue(
              _MemoryStore(const StoredProfiles(profiles: [_profile])),
            ),
            serverConnectionManagerProvider.overrideWithValue(manager),
          ],
          child: const CodexRemoteApp(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('测试服务器'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '连接'));
      await tester.pump();

      final overlay = find.byKey(const ValueKey('connection-overlay'));
      expect(overlay, findsOneWidget);
      expect(tester.getTopLeft(overlay), Offset.zero);
      expect(tester.getSize(overlay), const Size(1220 / 2.75, 2712 / 2.75));

      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(overlay, findsOneWidget);

      client.connectGate.complete();
      await tester.pumpAndSettle();
      expect(overlay, findsNothing);
    },
  );

  testWidgets('changed SSH fingerprint shows old and new values', (
    tester,
  ) async {
    const actualFingerprint = 'SHA256:replacement';
    final store = _MemoryStore(const StoredProfiles(profiles: [_profile]));
    final manager = ServerConnectionManager(
      clientFactory: () => _ChangedFingerprintClient(actualFingerprint),
    );
    addTearDown(manager.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          profileStoreProvider.overrideWithValue(store),
          serverConnectionManagerProvider.overrideWithValue(manager),
        ],
        child: const CodexRemoteApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试服务器'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '连接'));
    await tester.pumpAndSettle();

    expect(find.text('服务器指纹已变化'), findsOneWidget);
    expect(find.text('已保存指纹'), findsOneWidget);
    expect(find.text('SHA256:test'), findsOneWidget);
    expect(find.text('服务器当前指纹'), findsOneWidget);
    expect(find.text(actualFingerprint), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '更新并连接'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(store.value.profiles.single.hostFingerprint, 'SHA256:test');
  });

  testWidgets('server editor survives 1.5K portrait and enlarged text', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 2.75;
    tester.view.physicalSize = const Size(1220, 2712);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [profileStoreProvider.overrideWithValue(_MemoryStore())],
        child: const CodexRemoteApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加服务器').last);
    await tester.pumpAndSettle();

    expect(find.byTooltip('显示私钥密码'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.enterText(find.byType(TextFormField).at(1), 'changed.example');
    await tester.tap(find.byTooltip('返回服务器列表'));
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的修改？'), findsOneWidget);
  });
}
