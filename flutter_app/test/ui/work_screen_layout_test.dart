import 'dart:convert';

import 'package:codex_remote/src/app/app_controller.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/persistence/profile_store.dart';
import 'package:codex_remote/src/platform/local_file_exporter.dart';
import 'package:codex_remote/src/ssh/server_connection_manager.dart';
import 'package:codex_remote/src/ui/theme.dart';
import 'package:codex_remote/src/ui/work_screen.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

class _PaginationController extends _LayoutController {
  _PaginationController(super.store, super.manager);

  Future<void> Function()? onLoadOlder;
  int loadOlderCalls = 0;

  @override
  Future<void> loadOlderTurns() async {
    loadOlderCalls += 1;
    await onLoadOlder?.call();
  }
}

class _TrackingFileExporter implements LocalFileExporter {
  int beginCalls = 0;

  @override
  Future<LocalFileExportSession?> begin({
    required String fileName,
    String mimeType = 'application/octet-stream',
  }) async {
    beginCalls += 1;
    return null;
  }
}

TapGestureRecognizer _linkRecognizer(WidgetTester tester, String text) {
  for (final selectable in tester.widgetList<SelectableText>(
    find.byType(SelectableText),
  )) {
    final recognizer = _findLinkRecognizer(selectable.textSpan, text);
    if (recognizer != null) return recognizer;
  }
  throw TestFailure('No clickable link span found for $text');
}

TapGestureRecognizer? _findLinkRecognizer(InlineSpan? span, String text) {
  if (span is! TextSpan) return null;
  if ((span.text ?? '').contains(text) &&
      span.recognizer is TapGestureRecognizer) {
    return span.recognizer! as TapGestureRecognizer;
  }
  for (final child in span.children ?? const <InlineSpan>[]) {
    final recognizer = _findLinkRecognizer(child, text);
    if (recognizer != null) return recognizer;
  }
  return null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  List<TimelineEntry> entries(int start, int count) => [
    for (var index = start; index < start + count; index += 1)
      TimelineEntry(
        id: 'timeline-$index',
        kind: TimelineKind.agentMessage,
        text: '消息 $index',
      ),
  ];

  AppUiState timelineState({
    required List<TimelineEntry> timeline,
    String? olderTurnsCursor,
    bool olderTurnsLoading = false,
    bool loading = false,
  }) => AppUiState(
    screen: AppScreen.work,
    activeThread: const AgentThread(id: 'timeline-thread', title: '分页会话'),
    activeAgentCapabilities: AgentCapabilities.codex,
    timeline: timeline,
    olderTurnsCursor: olderTurnsCursor,
    olderTurnsLoading: olderTurnsLoading,
    loading: loading,
  );

  testWidgets('opens an existing conversation at the latest message', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 840);
    addTearDown(tester.view.reset);

    final manager = ServerConnectionManager();
    final controller = _LayoutController(_MemoryStore(), manager)
      ..showState(timelineState(timeline: const [], loading: true));
    addTearDown(() async => manager.close());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: MaterialApp(theme: buildCodexTheme(), home: const WorkScreen()),
      ),
    );
    await tester.pump();
    controller.showState(
      timelineState(timeline: entries(0, 40), loading: false),
    );
    await tester.pumpAndSettle();

    expect(find.text('消息 39'), findsOneWidget);
    expect(find.text('消息 0'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps the visible message anchored while loading older pages', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 840);
    addTearDown(tester.view.reset);

    final manager = ServerConnectionManager();
    final controller = _PaginationController(_MemoryStore(), manager)
      ..showState(
        timelineState(timeline: entries(0, 40), olderTurnsCursor: 'page-2'),
      );
    addTearDown(() async => manager.close());
    controller.onLoadOlder = () async {
      controller.showState(controller.state.copyWith(olderTurnsLoading: true));
      await Future<void>.value();
      controller.showState(
        controller.state.copyWith(
          timeline: [...entries(-10, 10), ...controller.state.timeline],
          olderTurnsCursor: null,
          olderTurnsLoading: false,
        ),
      );
    };

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: MaterialApp(theme: buildCodexTheme(), home: const WorkScreen()),
      ),
    );
    await tester.pumpAndSettle();
    final scrollView = tester.widget<CustomScrollView>(
      find.byType(CustomScrollView),
    );
    scrollView.controller!.jumpTo(0);
    await tester.pumpAndSettle();
    final beforeTop = tester.getTopLeft(find.text('消息 0')).dy;

    await tester.drag(find.byType(CustomScrollView), const Offset(0, 120));
    await tester.pumpAndSettle();

    expect(controller.loadOlderCalls, 1);
    expect(controller.state.timeline.first.text, '消息 -10');
    expect(controller.state.timeline.length, 50);
    expect(find.text('消息 39'), findsNothing);
    expect(tester.getTopLeft(find.text('消息 0')).dy, closeTo(beforeTop, 2));
    expect(tester.takeException(), isNull);
  });

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
        models: const [
          AgentModel(id: 'gpt-5.6', model: 'gpt-5.6', displayName: 'GPT-5.6'),
        ],
        selectedModel: 'gpt-5.6',
        selectedEffort: 'xhigh',
        tokenUsage: const TokenUsage(
          last: TokenUsageBreakdown(totalTokens: 36),
          modelContextWindow: 100,
        ),
        turnTiming: const TurnTiming(
          threadId: 'thread-1',
          startedAtMillis: 1786210800000,
          completedAtMillis: 1786210802000,
          stopped: true,
        ),
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
    expect(find.text('已停止  2s'), findsOneWidget);
    expect(find.text('描述任务'), findsOneWidget);
    expect(find.text('权限'), findsOneWidget);
    expect(find.text('36%'), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);
    expect(find.byIcon(Icons.search), findsOneWidget);
    expect(find.byIcon(Icons.visibility), findsNWidgets(2));
    expect(tester.widget<Icon>(find.byIcon(Icons.search)).size, 17);
    expect(tester.widget<Icon>(find.byIcon(Icons.terminal)).size, 17);
    expect(
      tester.getSize(find.byKey(const Key('composer-attachment-menu'))),
      const Size.square(36),
    );
    expect(
      tester.getSize(find.byKey(const Key('composer-action-menu'))),
      const Size.square(36),
    );
    expect(
      tester
          .getSize(find.byKey(const Key('composer-permission-button')))
          .height,
      36,
    );
    final composerInput = tester.widget<TextField>(
      find.byKey(const Key('composer-input')),
    );
    expect(composerInput.decoration?.filled, isFalse);
    expect(composerInput.decoration?.border, InputBorder.none);
    expect(composerInput.decoration?.enabledBorder, InputBorder.none);
    expect(composerInput.decoration?.focusedBorder, InputBorder.none);
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(873, 2048);
    controller.showState(
      controller.state.copyWith(
        models: const [
          AgentModel(
            id: 'gpt-5.6-terra-preview',
            model: 'gpt-5.6-terra-preview',
            displayName: 'GPT-5.6-Terra-Preview',
          ),
        ],
        selectedModel: 'gpt-5.6-terra-preview',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('5.6-Terra-Preview 极高'), findsOneWidget);
    final permissionRect = tester.getRect(
      find.byKey(const Key('composer-permission-button')),
    );
    final contextRect = tester.getRect(
      find.byKey(const Key('composer-context-usage')),
    );
    final modelRect = tester.getRect(
      find.byKey(const Key('composer-model-label')),
    );
    final sendRect = tester.getRect(find.byTooltip('发送'));
    expect(contextRect.left, greaterThanOrEqualTo(permissionRect.right));
    expect(modelRect.right, lessThanOrEqualTo(sendRect.left));
    expect(
      tester
          .renderObject<RenderParagraph>(
            find.byKey(const Key('composer-model-label')),
          )
          .didExceedMaxLines,
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('matches the original work menu and gates Debug logs', (
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
    const menuState = AppUiState(
      screen: AppScreen.work,
      activeThread: AgentThread(id: 'thread-menu', title: '菜单样式'),
      activeAgentCapabilities: AgentCapabilities.codex,
    );
    controller.showState(menuState);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('work-action-menu')));
    await tester.pumpAndSettle();
    expect(find.text('重命名'), findsOneWidget);
    expect(find.text('归档'), findsOneWidget);
    expect(find.text('设置目标'), findsOneWidget);
    expect(find.text('添加崩溃 / Debug 日志'), findsNothing);
    expect(find.byIcon(Icons.edit), findsOneWidget);
    expect(find.byIcon(Icons.archive), findsOneWidget);
    expect(find.byIcon(Icons.track_changes), findsOneWidget);
    expect(find.byType(PopupMenuDivider), findsNothing);
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();

    controller.showState(menuState.copyWith(debugModeEnabled: true));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('work-action-menu')));
    await tester.pumpAndSettle();
    expect(find.text('添加崩溃 / Debug 日志'), findsOneWidget);
    expect(find.byIcon(Icons.bug_report), findsOneWidget);
    expect(find.byType(PopupMenuDivider), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('opens adjacent URLs and previews linked remote images', (
    tester,
  ) async {
    const url = 'http://192.168.8.107/codex.apk';
    const imagePath =
        '/home/yan/ygy/codex-remote-android/.workflow-cache/emulator/'
        'latest-release.png';
    final manager = ServerConnectionManager();
    final controller = _LayoutController(_MemoryStore(), manager);
    final exporter = _TrackingFileExporter();
    String? loadedImagePath;
    addTearDown(() async {
      await manager.close();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: MaterialApp(
          theme: buildCodexTheme(),
          home: WorkScreen(
            fileExporter: exporter,
            onLoadRemoteImage: (path) async {
              loadedImagePath = path;
              return base64Decode(
                'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lE'
                'QVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
              );
            },
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    controller.showState(
      const AppUiState(
        screen: AppScreen.work,
        activeThread: AgentThread(id: 'thread-links', title: '链接'),
        timeline: [
          TimelineEntry(
            id: 'links-1',
            kind: TimelineKind.agentMessage,
            text: '内网：$url\n\n[竖屏验收截图]($imagePath)',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    _linkRecognizer(tester, url).onTap!();
    await tester.pumpAndSettle();
    expect(find.text('打开链接'), findsOneWidget);
    expect(find.text(url), findsWidgets);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    _linkRecognizer(tester, '竖屏验收截图').onTap!();
    await tester.pumpAndSettle();
    expect(loadedImagePath, imagePath);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.text('latest-release.png'), findsOneWidget);
    expect(exporter.beginCalls, 0);
    await tester.tap(find.byTooltip('关闭图片'));
    await tester.pumpAndSettle();
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

  testWidgets('renders original file-change cards and opens the full diff', (
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
      const AppUiState(
        screen: AppScreen.work,
        activeThread: AgentThread(
          id: 'thread-files',
          title: '文件修改',
          cwd: '/home/yan/ygy',
        ),
        aggregateDiff: '@@ -1 +1 @@\n-old\n+new',
        timeline: [
          TimelineEntry(
            id: 'files-1',
            kind: TimelineKind.fileChange,
            changes: [
              FileChange(path: '/tmp/a.dart', diff: '-old\n+new'),
              FileChange(path: '/tmp/b.dart', diff: '+line'),
              FileChange(path: '/tmp/c.dart', diff: '-line'),
              FileChange(path: '/tmp/d.dart', diff: '+line'),
            ],
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('已编辑 4 个文件'), findsOneWidget);
    expect(find.text('再显示 1 个文件'), findsOneWidget);
    expect(find.text('工作区差异'), findsOneWidget);
    await tester.tap(find.text('/tmp/a.dart'));
    await tester.pumpAndSettle();
    expect(find.text('文件差异'), findsOneWidget);
    expect(find.text('/tmp/a.dart'), findsOneWidget);
    expect(find.text('-old\n+new'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
