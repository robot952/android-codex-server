import 'dart:async';

import 'package:codex_remote/src/app/codex_remote_app.dart';
import 'package:codex_remote/src/app/app_controller.dart';
import 'package:codex_remote/src/domain/models.dart' hide ConnectionState;
import 'package:codex_remote/src/domain/models.dart'
    as domain
    show ConnectionState;
import 'package:codex_remote/src/persistence/profile_store.dart';
import 'package:codex_remote/src/platform/windows_local_server_client.dart';
import 'package:codex_remote/src/ssh/server_connection_manager.dart';
import 'package:codex_remote/src/ssh/terminal_manager.dart';
import 'package:codex_remote/src/ui/theme.dart';
import 'package:codex_remote/src/ui/thread_list_screen.dart';
import 'package:codex_remote/src/ui/work_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryStore implements ProfileStore {
  @override
  Future<StoredProfiles> load() async => const StoredProfiles();

  @override
  Future<void> save(StoredProfiles value) async {}
}

class _ThreadListController extends AppController {
  // AppController keeps its injected fields private to the production library.
  // ignore: use_super_parameters
  _ThreadListController(ProfileStore store, ServerConnectionManager manager)
    : super(store, manager);

  int refreshThreadsCount = 0;
  bool? lastRefreshSilent;
  Completer<void>? refreshGate;
  AgentKind? selectedAgent;
  bool fileManagerOpened = false;

  void showState(AppUiState value) => state = value;

  @override
  void selectAgent(AgentKind agent) {
    selectedAgent = agent;
  }

  @override
  void showFileManager() {
    fileManagerOpened = true;
  }

  @override
  Future<void> refreshThreads({bool silent = false}) async {
    refreshThreadsCount += 1;
    lastRefreshSilent = silent;
    await refreshGate?.future;
  }
}

class _ConnectedTerminalManager extends TerminalManager {
  _ConnectedTerminalManager(super.connections);

  @override
  TerminalSessionState? stateFor(String profileId) => TerminalSessionState(
    profileId: profileId,
    profileName: '测试服务器',
    endpoint: 'root@example.test:22',
    phase: TerminalPhase.connected,
  );
}

void main() {
  test(
    'formats thread timestamps as relative time at every requested scale',
    () {
      final now = DateTime.fromMillisecondsSinceEpoch(2_000_000_000_000);
      int secondsAgo(int seconds) =>
          now.subtract(Duration(seconds: seconds)).millisecondsSinceEpoch ~/
          1000;

      expect(threadUpdatedAtLabel(0, now: now), isNull);
      expect(threadUpdatedAtLabel(secondsAgo(30), now: now), '刚刚');
      expect(threadUpdatedAtLabel(secondsAgo(5 * 60), now: now), '5 分钟');
      expect(threadUpdatedAtLabel(secondsAgo(3 * 3600), now: now), '3 小时');
      expect(threadUpdatedAtLabel(secondsAgo(4 * 86400), now: now), '4 天');
      expect(threadUpdatedAtLabel(secondsAgo(3 * 604800), now: now), '3 周');
      expect(threadUpdatedAtLabel(secondsAgo(4 * 2592000), now: now), '4 个月');
      expect(
        threadUpdatedAtLabel(
          now.subtract(const Duration(hours: 2)).millisecondsSinceEpoch,
          now: now,
        ),
        '2 小时',
      );
      expect(
        threadUpdatedAtLabel(
          now.add(const Duration(minutes: 5)).millisecondsSinceEpoch,
          now: now,
        ),
        '刚刚',
      );
    },
  );

  test('keeps cached threads visible while the agent lane reconnects', () {
    const threads = <AgentThread>[AgentThread(id: 'one', title: 'One')];

    expect(visibleAgentThreads(threads, '', agentConnected: false), threads);
    expect(visibleAgentThreads(threads, '', agentConnected: true), threads);
  });

  test('filters connected thread list by title, preview, and cwd', () {
    const threads = <AgentThread>[
      AgentThread(id: 'title', title: 'Deploy service'),
      AgentThread(id: 'preview', title: 'Other', preview: 'release notes'),
      AgentThread(id: 'cwd', title: 'Other', cwd: '/srv/project'),
    ];

    expect(
      visibleAgentThreads(
        threads,
        'release',
        agentConnected: true,
      ).map((thread) => thread.id),
      ['preview'],
    );
    expect(
      visibleAgentThreads(
        threads,
        '/srv',
        agentConnected: true,
      ).map((thread) => thread.id),
      ['cwd'],
    );
  });

  test('treats working status as an active thread', () {
    expect(
      isAgentThreadRunning(const AgentThread(id: 'working', status: 'working')),
      isTrue,
    );
    expect(
      isAgentThreadRunning(const AgentThread(id: 'idle', status: 'idle')),
      isFalse,
    );
  });

  test('dismisses the keyboard for every non-resumed lifecycle state', () {
    expect(shouldDismissWorkKeyboard(AppLifecycleState.resumed), isFalse);
    expect(shouldDismissWorkKeyboard(AppLifecycleState.inactive), isTrue);
    expect(shouldDismissWorkKeyboard(AppLifecycleState.paused), isTrue);
    expect(shouldDismissWorkKeyboard(AppLifecycleState.hidden), isTrue);
    expect(shouldDismissWorkKeyboard(AppLifecycleState.detached), isTrue);
  });

  test('keeps the app process alive for host, Agent, or running work', () {
    expect(keepsAppAliveInBackground(const AppUiState()), isFalse);
    expect(
      keepsAppAliveInBackground(
        const AppUiState(
          connectionStates: {
            'server': domain.ConnectionState(phase: ConnectionPhase.connected),
          },
        ),
      ),
      isTrue,
    );
    expect(
      keepsAppAliveInBackground(
        AppUiState(
          agentConnectionStates: {
            const AgentConnectionKey(
              profileId: 'server',
              agent: AgentKind.codex,
            ): const domain.ConnectionState(
              phase: ConnectionPhase.installing,
            ),
          },
        ),
      ),
      isTrue,
    );
    expect(keepsAppAliveInBackground(const AppUiState(running: true)), isTrue);
  });

  test('pauses background metrics while a conversation surface is active', () {
    expect(
      shouldPollBackgroundMetricsInBackground(
        const AppUiState(screen: AppScreen.servers),
      ),
      isTrue,
    );
    expect(
      shouldPollBackgroundMetricsInBackground(
        const AppUiState(screen: AppScreen.threads),
      ),
      isTrue,
    );
    expect(
      shouldPollBackgroundMetricsInBackground(
        const AppUiState(screen: AppScreen.work),
      ),
      isFalse,
    );
    expect(
      shouldPollBackgroundMetricsInBackground(
        const AppUiState(screen: AppScreen.agentWork),
      ),
      isFalse,
    );
    expect(
      shouldPollBackgroundMetricsInBackground(
        const AppUiState(screen: AppScreen.threads, running: true),
      ),
      isFalse,
    );
  });

  testWidgets('right-aligns the thread source after a long workspace path', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.reset);

    final manager = ServerConnectionManager();
    final controller = _ThreadListController(_MemoryStore(), manager);
    addTearDown(manager.close);
    const profile = ServerProfile(
      id: 'server',
      name: '测试服务器',
      host: 'example.test',
      username: 'root',
      authMode: AuthMode.password,
    );
    const key = AgentConnectionKey(profileId: 'server', agent: AgentKind.codex);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: MaterialApp(
          theme: buildCodexTheme(),
          home: const ThreadListScreen(),
        ),
      ),
    );
    await tester.pump();
    controller.showState(
      AppUiState(
        profiles: [profile],
        selectedProfileId: 'server',
        connectionStates: {
          'server': domain.ConnectionState(phase: ConnectionPhase.connected),
        },
        agentConnectionStates: {
          key: domain.ConnectionState(phase: ConnectionPhase.connected),
        },
        agentThreadLists: {
          key: const [
            AgentThread(
              id: 'thread',
              title: '检查任务来源标签布局',
              cwd: '/home/yan/projects/a-very-long-workspace-directory',
              source: 'vscode',
            ),
          ],
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final sourceRight = tester.getTopRight(find.text('vscode')).dx;
    expect(sourceRight, greaterThanOrEqualTo(338));
  });

  testWidgets('allows selecting OpenCode for the native Windows profile', (
    tester,
  ) async {
    final manager = ServerConnectionManager();
    final controller = _ThreadListController(_MemoryStore(), manager);
    addTearDown(manager.close);
    final profile = localWindowsProfile();
    final codexKey = AgentConnectionKey(
      profileId: profile.id,
      agent: AgentKind.codex,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: MaterialApp(
          theme: buildCodexTheme(),
          home: const ThreadListScreen(),
        ),
      ),
    );
    controller.showState(
      AppUiState(
        profiles: [profile],
        selectedProfileId: profile.id,
        connectionStates: {
          profile.id: const domain.ConnectionState(
            phase: ConnectionPhase.connected,
          ),
        },
        agentConnectionStates: {
          codexKey: const domain.ConnectionState(
            phase: ConnectionPhase.connected,
          ),
        },
      ),
    );
    await tester.pump();

    await tester.tap(find.text('OpenCode'));
    await tester.pump();

    expect(controller.selectedAgent, AgentKind.openCode);
    expect(tester.takeException(), isNull);
  });

  testWidgets('updates visible relative times while the list remains open', (
    tester,
  ) async {
    var now = DateTime.now();
    final manager = ServerConnectionManager();
    final controller = _ThreadListController(_MemoryStore(), manager);
    addTearDown(manager.close);
    const profile = ServerProfile(
      id: 'server',
      name: '测试服务器',
      host: 'example.test',
      username: 'root',
      authMode: AuthMode.password,
    );
    const key = AgentConnectionKey(profileId: 'server', agent: AgentKind.codex);
    final updatedAt =
        now.subtract(const Duration(seconds: 30)).millisecondsSinceEpoch ~/
        1000;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: MaterialApp(
          theme: buildCodexTheme(),
          home: ThreadListScreen(now: () => now),
        ),
      ),
    );
    controller.showState(
      AppUiState(
        profiles: const [profile],
        selectedProfileId: 'server',
        connectionStates: const {
          'server': domain.ConnectionState(phase: ConnectionPhase.connected),
        },
        agentConnectionStates: {
          key: const domain.ConnectionState(phase: ConnectionPhase.connected),
        },
        agentThreadLists: {
          key: [AgentThread(id: 'thread', title: '相对时间', updatedAt: updatedAt)],
        },
      ),
    );
    await tester.pump();

    expect(find.text('刚刚'), findsOneWidget);
    now = now.add(const Duration(minutes: 1));
    await tester.pump(const Duration(minutes: 1));
    expect(find.text('刚刚'), findsNothing);
    expect(find.textContaining('分钟'), findsOneWidget);
  });

  testWidgets('shows a green terminal icon while its PTY remains connected', (
    tester,
  ) async {
    final manager = ServerConnectionManager();
    final terminalManager = _ConnectedTerminalManager(manager);
    final controller = _ThreadListController(_MemoryStore(), manager);
    addTearDown(terminalManager.close);
    addTearDown(manager.close);
    const profile = ServerProfile(
      id: 'server',
      name: '测试服务器',
      host: 'example.test',
      username: 'root',
      authMode: AuthMode.password,
    );
    const key = AgentConnectionKey(profileId: 'server', agent: AgentKind.codex);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appControllerProvider.overrideWith((ref) => controller),
          terminalManagerProvider.overrideWithValue(terminalManager),
        ],
        child: MaterialApp(
          theme: buildCodexTheme(),
          home: const ThreadListScreen(),
        ),
      ),
    );
    controller.showState(
      AppUiState(
        profiles: const [profile],
        selectedProfileId: 'server',
        connectionStates: const {
          'server': domain.ConnectionState(phase: ConnectionPhase.connected),
        },
        agentConnectionStates: {
          key: const domain.ConnectionState(phase: ConnectionPhase.connected),
        },
      ),
    );
    await tester.pump();

    final button = find.byKey(const ValueKey('thread-list-terminal'));
    final icon = tester.widget<Icon>(
      find.descendant(of: button, matching: find.byIcon(Icons.terminal)),
    );
    expect(icon.color, codexGreen);
  });

  testWidgets('places file management beside settings on the thread list', (
    tester,
  ) async {
    final manager = ServerConnectionManager();
    final controller = _ThreadListController(_MemoryStore(), manager);
    addTearDown(manager.close);
    const profile = ServerProfile(
      id: 'server',
      name: '测试服务器',
      host: 'example.test',
      username: 'root',
      authMode: AuthMode.password,
    );
    const key = AgentConnectionKey(profileId: 'server', agent: AgentKind.codex);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: MaterialApp(
          theme: buildCodexTheme(),
          home: const ThreadListScreen(),
        ),
      ),
    );
    controller.showState(
      AppUiState(
        profiles: const [profile],
        selectedProfileId: profile.id,
        connectionStates: {
          profile.id: const domain.ConnectionState(
            phase: ConnectionPhase.connected,
          ),
        },
        agentConnectionStates: {
          key: const domain.ConnectionState(phase: ConnectionPhase.connected),
        },
      ),
    );
    await tester.pump();

    final settingsButton = find.byTooltip('设置');
    final fileManagerButton = find.byKey(
      const ValueKey('thread-list-file-manager'),
    );
    expect(settingsButton, findsOneWidget);
    expect(fileManagerButton, findsOneWidget);
    expect(
      tester.getTopLeft(fileManagerButton).dx,
      greaterThan(tester.getTopLeft(settingsButton).dx),
    );

    await tester.tap(fileManagerButton);
    expect(controller.fileManagerOpened, isTrue);

    await tester.tap(settingsButton);
    await tester.pumpAndSettle();
    expect(find.text('文件管理'), findsNothing);
  });

  testWidgets('pulling the thread panel reveals refresh states below search', (
    tester,
  ) async {
    final manager = ServerConnectionManager();
    final controller = _ThreadListController(_MemoryStore(), manager);
    addTearDown(manager.close);
    const profile = ServerProfile(
      id: 'server',
      name: '测试服务器',
      host: 'example.test',
      username: 'root',
      authMode: AuthMode.password,
    );
    const key = AgentConnectionKey(profileId: 'server', agent: AgentKind.codex);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: MaterialApp(
          theme: buildCodexTheme(),
          home: const ThreadListScreen(),
        ),
      ),
    );
    controller.showState(
      AppUiState(
        profiles: const [profile],
        selectedProfileId: 'server',
        connectionStates: const {
          'server': domain.ConnectionState(phase: ConnectionPhase.connected),
        },
        agentConnectionStates: {
          key: const domain.ConnectionState(phase: ConnectionPhase.connected),
        },
        agentThreadLists: {
          key: const [AgentThread(id: 'thread', title: '短对话')],
        },
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('thread-list-refresh')), findsOneWidget);
    expect(find.byType(RefreshIndicator), findsNothing);
    final searchTop = tester.getTopLeft(find.byType(TextField)).dy;
    final headerTop = tester.getTopLeft(find.text('最近任务')).dy;
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('thread-list-scroll'))),
    );
    await gesture.moveBy(const Offset(0, 180));
    await tester.pump();

    expect(find.text('松开刷新'), findsOneWidget);
    expect(tester.getTopLeft(find.byType(TextField)).dy, searchTop);
    expect(
      tester.getTopLeft(find.text('最近任务')).dy,
      greaterThan(headerTop + 70),
    );

    controller.refreshGate = Completer<void>();
    await gesture.up();
    await tester.pump();

    expect(find.text('正在刷新'), findsOneWidget);
    expect(controller.refreshThreadsCount, 1);
    expect(controller.lastRefreshSilent, isTrue);
    expect(tester.getTopLeft(find.byType(TextField)).dy, searchTop);
    expect(tester.getTopLeft(find.text('最近任务')).dy, greaterThan(headerTop));

    controller.refreshGate!.complete();
    await tester.pumpAndSettle();

    expect(tester.getTopLeft(find.text('最近任务')).dy, closeTo(headerTop, 0.1));
    expect(find.text('短对话'), findsOneWidget);
  });
}
