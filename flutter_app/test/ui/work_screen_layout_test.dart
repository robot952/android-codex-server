import 'package:codex_remote/src/app/app_controller.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/persistence/profile_store.dart';
import 'package:codex_remote/src/ssh/server_connection_manager.dart';
import 'package:codex_remote/src/ui/theme.dart';
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

class _LayoutController extends AppController {
  // The production constructor uses private positional fields, so a public
  // super-parameter cannot be used from this test library.
  // ignore: use_super_parameters
  _LayoutController(ProfileStore store, ServerConnectionManager manager)
    : super(store, manager);

  void showState(AppUiState value) => state = value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders the screenshot-style work timeline and composer', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 2.75;
    tester.view.physicalSize = const Size(1220, 2712);
    addTearDown(tester.view.reset);

    final manager = ServerConnectionManager();
    final controller = _LayoutController(_MemoryStore(), manager);
    addTearDown(() async {
      await manager.close();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: MaterialApp(theme: buildCodexTheme(), home: const WorkScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    controller.showState(
      AppUiState(
        screen: AppScreen.work,
        activeThread: const AgentThread(
          id: 'thread-1',
          title: '安卓 Codex APP (3)',
          cwd: '/home/yan/ygy',
        ),
        activeAgentCapabilities: AgentCapabilities.codex,
        selectedModel: 'gpt-5.6',
        selectedEffort: 'xhigh',
        timeline: const [
          TimelineEntry(
            id: 'assistant-1',
            kind: TimelineKind.agentMessage,
            text: '助手回复直接显示在背景上。',
          ),
          TimelineEntry(
            id: 'reasoning-1',
            kind: TimelineKind.reasoning,
            title: '思考过程',
            text: '这里是折叠的思考内容。',
          ),
          TimelineEntry(
            id: 'image-1',
            kind: TimelineKind.tool,
            title: '查看了图片',
            text: '/home/yan/ygy/example.png',
          ),
          TimelineEntry(
            id: 'command-1',
            kind: TimelineKind.command,
            status: 'completed',
            command: 'flutter test',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('安卓 Codex APP (3)'), findsOneWidget);
    expect(find.text('/home/yan/ygy'), findsOneWidget);
    expect(find.text('助手回复直接显示在背景上。'), findsOneWidget);
    expect(find.text('思考过程'), findsOneWidget);
    expect(find.text('查看了图片'), findsOneWidget);
    expect(find.text('/home/yan/ygy/example.png'), findsOneWidget);
    expect(find.text('运行了命令'), findsOneWidget);
    expect(find.text('完成'), findsOneWidget);
    expect(find.text('描述任务'), findsOneWidget);
    expect(find.text('权限'), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);
    expect(find.byIcon(Icons.search), findsOneWidget);
    expect(find.byIcon(Icons.visibility), findsNWidgets(2));
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(2712, 1220);
    await tester.pumpAndSettle();
    expect(find.text('安卓 Codex APP (3)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('expands reasoning and command details without changing rows', (
    tester,
  ) async {
    final manager = ServerConnectionManager();
    final controller = _LayoutController(_MemoryStore(), manager);
    addTearDown(() async {
      await manager.close();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: MaterialApp(theme: buildCodexTheme(), home: const WorkScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    controller.showState(
      const AppUiState(
        screen: AppScreen.work,
        activeThread: AgentThread(id: 'thread-2', title: '详情'),
        timeline: [
          TimelineEntry(
            id: 'reasoning-2',
            kind: TimelineKind.reasoning,
            text: '展开后的思考内容',
          ),
          TimelineEntry(
            id: 'command-2',
            kind: TimelineKind.command,
            status: 'completed',
            command: 'echo details',
            output: 'command output',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('展开后的思考内容'), findsNothing);
    expect(find.text('echo details'), findsNothing);
    await tester.tap(find.text('思考过程'));
    await tester.pumpAndSettle();
    expect(find.text('展开后的思考内容'), findsOneWidget);
    await tester.tap(find.text('运行了命令'));
    await tester.pumpAndSettle();
    expect(find.text('echo details'), findsOneWidget);
    expect(find.text('command output'), findsOneWidget);
  });
}
