import 'package:codex_remote/src/app/codex_remote_app.dart';
import 'package:codex_remote/src/app/app_controller.dart';
import 'package:codex_remote/src/domain/models.dart' hide ConnectionState;
import 'package:codex_remote/src/domain/models.dart'
    as domain
    show ConnectionState;
import 'package:codex_remote/src/persistence/profile_store.dart';
import 'package:codex_remote/src/ssh/server_connection_manager.dart';
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

  void showState(AppUiState value) => state = value;
}

void main() {
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
}
