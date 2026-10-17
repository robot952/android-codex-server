import 'dart:async';

import 'package:codex_remote/src/app/codex_remote_app.dart';
import 'package:codex_remote/src/app/app_controller.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/persistence/profile_store.dart';
import 'package:codex_remote/src/platform/app_update_manager.dart';
import 'package:codex_remote/src/platform/local_linux_manager.dart';
import 'package:codex_remote/src/ssh/server_connection_manager.dart';
import 'package:codex_remote/src/ssh/ssh_server_client.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

class _ControllableAppUpdateController extends AppUpdateController {
  _ControllableAppUpdateController() : super(autoCheck: false) {
    emit(const AppUpdateState(installedVersion: '1.2.3'));
  }

  void emit(AppUpdateState value) => state = value;
}

class _VersionEditorController extends AppController {
  // ignore: use_super_parameters
  _VersionEditorController(ProfileStore store, ServerConnectionManager manager)
    : super(store, manager);

  final List<(String, AgentKind)> versionRefreshes = [];

  @override
  Future<void> refreshAgentVersions(String profileId, AgentKind agent) async {
    versionRefreshes.add((profileId, agent));
    state = switch (agent) {
      AgentKind.codex => state.copyWith(codexVersions: ['0.162.1']),
      AgentKind.openCode => state.copyWith(openCodeVersions: ['1.18.11']),
      AgentKind.claudeCode => state.copyWith(claudeCodeVersions: ['2.1.293']),
    };
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

  for (final (width, textScale) in [
    (320.0, 1.0),
    (360.0, 1.0),
    (380.0, 1.0),
    (390.0, 1.0),
    (390.0, 1.2),
    (1220 / 2.75, 2.0),
  ]) {
    testWidgets(
      'promotion keeps Agent visible and stays fixed; width=$width textScale=$textScale',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 2712 / 2.75);
        tester.platformDispatcher.textScaleFactorTestValue = textScale;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final updates = _ControllableAppUpdateController();

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              profileStoreProvider.overrideWithValue(_MemoryStore()),
              appUpdateProvider.overrideWith((ref) => updates),
            ],
            child: const CodexRemoteApp(),
          ),
        );
        await tester.pumpAndSettle();

        final compact = find.text('ai2api.vip').evaluate().isEmpty;
        if (width == 390 && textScale == 1) {
          expect(compact, isFalse);
        }
        final promotion = compact
            ? find.widgetWithIcon(IconButton, Icons.open_in_new)
            : find.ancestor(
                of: find.text('低价中转站优选'),
                matching: find.byType(InkWell),
              );
        expect(promotion, findsOneWidget);
        expect(
          find.text('ai2api.vip'),
          compact ? findsNothing : findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        final initialRect = tester.getRect(promotion);
        final initialElement = tester.element(promotion);
        if (!compact) {
          expect(initialRect.width, 108);
          expect(initialRect.height, 36);
        }

        const longVersion = '123.456.789-development.123456789';
        const states = [
          AppUpdateState(installedVersion: longVersion),
          AppUpdateState(installedVersion: longVersion, checking: true),
          AppUpdateState(
            installedVersion: longVersion,
            availableUpdate: AppUpdateInfo(versionName: '999.0.0', changes: []),
          ),
          AppUpdateState(installedVersion: '1.2.3'),
        ];
        for (final state in states) {
          updates.emit(state);
          // The checking state has a continuously animating progress indicator.
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));

          expect(find.text('v${state.installedVersion}'), findsOneWidget);
          expect(
            find.byType(CircularProgressIndicator),
            state.checking ? findsOneWidget : findsNothing,
          );
          if (state.availableUpdate != null) {
            expect(find.text('有更新'), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
          expect(tester.element(promotion), same(initialElement));
          expect(tester.getRect(promotion), initialRect);
          final title = tester.renderObject<RenderParagraph>(
            find.text('Agent'),
          );
          expect(title.didExceedMaxLines, isFalse);
          expect(
            tester
                .renderObject<RenderParagraph>(find.text('服务器列表'))
                .didExceedMaxLines,
            isFalse,
          );
          if (!compact) {
            for (final label in ['低价中转站优选', 'ai2api.vip']) {
              expect(
                tester
                    .renderObject<RenderParagraph>(find.text(label))
                    .didExceedMaxLines,
                isFalse,
              );
            }
          }
          expect(
            tester.getRect(find.text('Agent')).right,
            lessThanOrEqualTo(tester.getRect(promotion).left),
          );
          expect(
            find.text('ai2api.vip'),
            compact ? findsNothing : findsOneWidget,
          );
        }
      },
    );
  }

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

  for (final cancel in [false, true]) {
    testWidgets(
      'connection overlay only shows spinner and cancel; cancel=$cancel',
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
        expect(find.text('测试服务器'), findsWidgets);
        expect(
          find.descendant(
            of: overlay,
            matching: find.byType(CircularProgressIndicator),
          ),
          findsOneWidget,
        );
        expect(
          tester
              .widgetList<Text>(
                find.descendant(of: overlay, matching: find.byType(Text)),
              )
              .map((text) => text.data),
          ['取消连接'],
        );
        expect(
          find.descendant(of: overlay, matching: find.text('测试服务器')),
          findsNothing,
        );
        expect(
          tester
              .getSize(find.byKey(const ValueKey('connection-overlay-content')))
              .height,
          lessThanOrEqualTo(120),
        );
        expect(find.text('取消连接'), findsOneWidget);

        await tester.binding.handlePopRoute();
        await tester.pump();
        expect(overlay, findsOneWidget);

        if (cancel) {
          tester.platformDispatcher.textScaleFactorTestValue = 2;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(
            tester
                .getSize(
                  find.byKey(const ValueKey('connection-overlay-content')),
                )
                .height,
            lessThanOrEqualTo(120),
          );
          await tester.tap(find.text('取消连接'));
        } else {
          client.connectGate.complete();
        }
        await tester.pumpAndSettle();
        expect(overlay, findsNothing);
        expect(client.connected, !cancel);
      },
    );
  }

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

  for (final (width, textScale) in [(320.0, 1.0), (1220 / 2.75, 2.0)]) {
    testWidgets(
      'server editor Agent versions refresh and save at width=$width scale=$textScale',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 986);
        tester.platformDispatcher.textScaleFactorTestValue = textScale;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final profile = _profile.copyWith(
          codexVersion: '0.162.0',
          openCodeVersion: '1.18.10',
          claudeCodeVersion: '2.1.292',
        );
        final store = _MemoryStore(StoredProfiles(profiles: [profile]));
        final manager = ServerConnectionManager();
        final controller = _VersionEditorController(store, manager);
        addTearDown(manager.close);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appControllerProvider.overrideWith((ref) => controller),
            ],
            child: const CodexRemoteApp(),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('服务器设置'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('高级'));
        await tester.tap(find.text('高级'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        for (final (agent, key, version) in [
          (AgentKind.codex, 'server-codex-version', '0.162.1'),
          (AgentKind.openCode, 'server-opencode-version', '1.18.11'),
          (AgentKind.claudeCode, 'server-claude-code-version', '2.1.293'),
        ]) {
          final refresh = find.byTooltip('刷新 ${agent.label} 版本列表');
          await tester.ensureVisible(refresh);
          await tester.pumpAndSettle();
          await tester.tap(refresh);
          await tester.pumpAndSettle();
          expect(controller.versionRefreshes.last, (profile.id, agent));

          final selector = find.byKey(ValueKey(key));
          await tester.ensureVisible(selector);
          await tester.pumpAndSettle();
          await tester.tap(selector);
          await tester.pumpAndSettle();
          await tester.tap(find.text('${agent.label} $version').last);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        final save = find.widgetWithText(FilledButton, '保存');
        await tester.ensureVisible(save);
        await tester.pumpAndSettle();
        await tester.tap(save);
        await tester.pumpAndSettle();

        expect(store.value.profiles.single.codexVersion, '0.162.1');
        expect(store.value.profiles.single.openCodeVersion, '1.18.11');
        expect(store.value.profiles.single.claudeCodeVersion, '2.1.293');
        expect(find.byTooltip('返回服务器列表'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

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
