import 'dart:async';

import 'package:codex_remote/src/app/app_controller.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/persistence/profile_store.dart';
import 'package:codex_remote/src/ssh/server_connection_manager.dart';
import 'package:codex_remote/src/ui/theme.dart';
import 'package:codex_remote/src/ui/user_input_dialog.dart';
import 'package:codex_remote/src/ui/work_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryStore implements ProfileStore {
  @override
  Future<StoredProfiles> load() async => const StoredProfiles();

  @override
  Future<void> save(StoredProfiles profiles) async {}
}

class _UiController extends AppController {
  _UiController(ServerConnectionManager manager)
    : super(_MemoryStore(), manager);

  final retryGate = Completer<void>();
  int retries = 0;

  void show(AppUiState value) => state = value;

  @override
  Future<void> retryActiveThread() async {
    retries += 1;
    state = state.copyWith(loading: true);
    await retryGate.future;
    state = state.copyWith(
      loading: false,
      activeThread: state.activeThread!.copyWith(isExternallyOwned: false),
    );
  }
}

const _thread = AgentThread(
  id: 'occupied-thread',
  title: '共享任务',
  cwd: '/fixture/workspace',
);

AppUiState _state({bool locked = true, ApprovalPrompt? approval}) => AppUiState(
  screen: AppScreen.work,
  activeThread: _thread.copyWith(isExternallyOwned: locked),
  activeAgentCapabilities: AgentCapabilities.codex,
  composerDraft: '尚未发送的草稿',
  approval: approval,
  approvalQueue: approval == null ? const [] : [approval],
  timeline: const [
    TimelineEntry(
      id: 'answer',
      kind: TimelineKind.agentMessage,
      text: '原有对话仍可阅读和复制。',
    ),
  ],
);

const _question = ApprovalPrompt(
  requestId: 'question',
  requestIdIsString: true,
  kind: ApprovalKind.userInput,
  threadId: 'occupied-thread',
  turnId: 'turn',
  itemId: 'item',
  title: '',
  detail: '',
  questions: [InputQuestion(id: 'scope', header: '范围', question: '修改哪里？')],
);

Future<_UiController> _pump(WidgetTester tester, AppUiState state) async {
  final manager = ServerConnectionManager();
  final controller = _UiController(manager);
  addTearDown(manager.close);
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  controller.show(state);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appControllerProvider.overrideWith((_) => controller)],
      child: MaterialApp(theme: buildCodexTheme(), home: const WorkScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  testWidgets('occupied conversation keeps history and wraps its lock banner', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 800);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await _pump(tester, _state(approval: _question));

    expect(find.text('共享任务'), findsOneWidget);
    expect(find.text('原有对话仍可阅读和复制。'), findsOneWidget);
    expect(find.text('已在另一个应用中打开'), findsOneWidget);
    expect(find.text('请先在那边关闭会话，才能在这里继续。'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byKey(const Key('work-action-menu')), findsNothing);
    expect(find.byKey(const Key('composer-action-menu')), findsNothing);
    expect(find.byType(UserInputDialog), findsNothing);
    final banner = tester.getRect(
      find.byKey(const Key('work-thread-read-only-banner')),
    );
    expect(banner.right, lessThanOrEqualTo(320));
    expect(banner.bottom, lessThanOrEqualTo(800));
    expect(banner.top, greaterThan(200));
    expect(tester.takeException(), isNull);
  });

  testWidgets('retry remains read only while loading then restores the draft', (
    tester,
  ) async {
    final controller = await _pump(tester, _state());
    await tester.tap(find.byKey(const Key('retry-active-thread')));
    await tester.pump();

    expect(controller.retries, 1);
    expect(find.text('已在另一个应用中打开'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('retry-active-thread')))
          .onPressed,
      isNull,
    );
    controller.retryGate.complete();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('work-thread-read-only-banner')), findsNothing);
    expect(find.text('尚未发送的草稿'), findsOneWidget);
    expect(find.byKey(const Key('work-action-menu')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ownership change closes open action and attachment menus', (
    tester,
  ) async {
    final controller = await _pump(tester, _state(locked: false));
    for (final key in [
      'work-action-menu',
      'composer-action-menu',
      'composer-attachment-menu',
    ]) {
      controller.show(_state(locked: false));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
      expect(find.byType(PopupMenuItem<String>), findsWidgets);
      controller.show(_state());
      await tester.pumpAndSettle();
      expect(find.byType(PopupMenuItem<String>), findsNothing);
      expect(find.text('已在另一个应用中打开'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('ownership change closes a rename dialog and keyboard focus', (
    tester,
  ) async {
    final controller = await _pump(tester, _state(locked: false));
    await tester.tap(find.byKey(const Key('work-action-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    expect(find.text('重命名任务'), findsOneWidget);

    controller.show(_state());
    await tester.pumpAndSettle();

    expect(find.text('重命名任务'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('已在另一个应用中打开'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ownership change closes only its question route', (
    tester,
  ) async {
    final controller = await _pump(
      tester,
      _state(locked: false, approval: _question),
    );
    expect(find.byType(UserInputDialog), findsOneWidget);
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('图片预览')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    controller.show(_state(approval: _question));
    await tester.pumpAndSettle();

    expect(find.text('图片预览'), findsOneWidget);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(find.byType(UserInputDialog), findsNothing);
    expect(find.text('已在另一个应用中打开'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ownership change closes permission settings', (tester) async {
    final controller = await _pump(tester, _state(locked: false));
    await tester.tap(find.text('权限'));
    await tester.pumpAndSettle();
    expect(find.text(ApprovalMode.fullAccess.label), findsOneWidget);

    controller.show(_state());
    await tester.pumpAndSettle();

    expect(find.text(ApprovalMode.fullAccess.label), findsNothing);
    expect(find.text('已在另一个应用中打开'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('locked history keeps diff browsing without review or rollback', (
    tester,
  ) async {
    await _pump(
      tester,
      _state().copyWith(
        timeline: const [
          TimelineEntry(
            id: 'changed-file',
            kind: TimelineKind.fileChange,
            changes: [
              FileChange(path: 'fixture.dart', diff: '-before\n+after'),
            ],
          ),
        ],
        approval: _question.copyWith(kind: ApprovalKind.command, title: '审批测试'),
      ),
    );

    expect(find.byTooltip('撤销上一轮会话'), findsNothing);
    expect(find.text('审查'), findsNothing);
    expect(find.text('审批测试'), findsNothing);
    await tester.tap(find.text('fixture.dart'));
    await tester.pumpAndSettle();
    expect(find.text('-before'), findsOneWidget);
    expect(find.text('+after'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('child detail keeps an empty bottom even when externally owned', (
    tester,
  ) async {
    await _pump(
      tester,
      _state().copyWith(screen: AppScreen.agentWork, activeAgentName: '历史审查'),
    );

    expect(find.text('历史审查'), findsOneWidget);
    expect(find.text('原有对话仍可阅读和复制。'), findsOneWidget);
    expect(find.byKey(const Key('work-thread-read-only-banner')), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(find.byKey(const Key('work-action-menu')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
