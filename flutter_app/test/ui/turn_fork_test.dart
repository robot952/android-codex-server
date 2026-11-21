import 'package:codex_remote/src/app/app_controller.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/persistence/profile_store.dart';
import 'package:codex_remote/src/ssh/server_connection_manager.dart';
import 'package:codex_remote/src/ui/theme.dart';
import 'package:codex_remote/src/ui/work_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Store implements ProfileStore {
  @override
  Future<StoredProfiles> load() async => const StoredProfiles();

  @override
  Future<void> save(StoredProfiles profiles) async {}
}

class _ForkController extends AppController {
  _ForkController(ServerConnectionManager manager) : super(_Store(), manager);

  final forked = <String>[];
  void show(AppUiState value) => state = value;

  // This fixture models a runtime that advertises native fork support. The
  // protocol capability probe itself is covered by the transport tests.
  @override
  bool get supportsActiveThreadFork =>
      state.activeAgent == AgentKind.codex && !state.isThreadReadOnly;

  @override
  bool canForkAtTurn(String turnId) =>
      supportsActiveThreadFork && isCompletedTurn(turnId) && !state.running;

  @override
  Future<void> forkAtTurn(String turnId) async => forked.add(turnId);
}

const _thread = AgentThread(id: 'source', title: '原对话');
const _source = AppUiState(
  screen: AppScreen.work,
  selectedProfileId: 'server',
  activeThread: _thread,
  activeAgentCapabilities: AgentCapabilities.codex,
  olderTurnsCursor: 'older',
  timeline: [
    // A partial page may omit the user's first message for this turn.
    TimelineEntry(
      id: 'tool',
      turnId: 't1',
      turnStatus: 'completed',
      kind: TimelineKind.command,
      command: 'pwd',
      status: 'completed',
    ),
    TimelineEntry(
      id: 'reply',
      turnId: 't1',
      turnStatus: 'completed',
      kind: TimelineKind.agentMessage,
      text: '第一轮结尾',
    ),
    TimelineEntry(
      id: 'reply2',
      turnId: 't2',
      turnStatus: 'completed',
      kind: TimelineKind.agentMessage,
      text: '第二轮结尾',
    ),
    TimelineEntry(
      id: 'fail',
      turnId: 't3',
      turnStatus: 'failed',
      kind: TimelineKind.notice,
      text: '失败',
    ),
    TimelineEntry(
      id: 'stop',
      turnId: 't4',
      turnStatus: 'interrupted',
      kind: TimelineKind.notice,
      text: '中断',
    ),
    TimelineEntry(
      id: 'unknown',
      turnId: 't5',
      status: 'completed',
      kind: TimelineKind.agentMessage,
      text: '只有条目完成',
    ),
  ],
);

Future<_ForkController> _pump(WidgetTester tester, AppUiState value) async {
  final manager = ServerConnectionManager();
  final controller = _ForkController(manager);
  addTearDown(manager.close);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appControllerProvider.overrideWith((_) => controller)],
      child: MaterialApp(theme: buildCodexTheme(), home: const WorkScreen()),
    ),
  );
  await tester.pump();
  controller.show(value);
  await tester.pumpAndSettle();
  return controller;
}

void main() => runTurnForkTests();

void runTurnForkTests({bool onDevice = false}) {
  testWidgets('fork action appears below each completed turn, not each item', (
    tester,
  ) async {
    final controller = await _pump(tester, _source);
    final action = find.byKey(const ValueKey('fork-turn-t1'));
    expect(action, findsOneWidget);
    expect(find.byTooltip('从此处分叉'), findsNWidgets(2));
    expect(
      tester.getTopLeft(action).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(find.text('第一轮结尾')).dy),
    );
    expect(
      tester.getTopLeft(action).dx,
      closeTo(tester.getRect(find.byType(CustomScrollView)).left + 9, 1),
    );
    expect(tester.getSize(action).shortestSide, greaterThanOrEqualTo(48));

    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(find.text('从此处分叉？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(controller.forked, isEmpty);
    await tester.tap(action);
    await tester.pumpAndSettle();
    await tester.tap(find.text('创建分支'));
    await tester.pumpAndSettle();
    expect(controller.forked, ['t1']);

    controller.show(_source.copyWith(running: true, activeTurnId: 't6'));
    await tester.pump();
    expect(tester.widget<IconButton>(action).onPressed, isNull);
    controller.show(_source.copyWith(activeAgent: AgentKind.openCode));
    await tester.pumpAndSettle();
    expect(find.byTooltip('从此处分叉'), findsNothing);
  });

  testWidgets(
    'old fork confirmation cannot apply to a different thread sharing history',
    (tester) async {
      final controller = await _pump(tester, _source);
      await tester.tap(find.byKey(const ValueKey('fork-turn-t1')));
      await tester.pumpAndSettle();
      controller.show(
        _source.copyWith(activeThread: _thread.copyWith(id: 'another-fork')),
      );
      await tester.pumpAndSettle();
      expect(find.text('创建分支'), findsNothing);
      expect(controller.forked, isEmpty);
    },
  );

  testWidgets(
    'long outgoing previews leave a clear fork gutter on narrow screens',
    (tester) async {
      if (!onDevice) {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 900);
        tester.platformDispatcher.textScaleFactorTestValue = 1.5;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      }
      await _pump(
        tester,
        _source.copyWith(
          timeline: [
            TimelineEntry(
              id: 'long',
              kind: TimelineKind.userMessage,
              turnId: 't1',
              turnStatus: 'completed',
              detailsItemId: 'deferred',
              text: '较长的用户消息会换行。' * 6,
            ),
          ],
        ),
      );
      final rect = tester.getRect(
        find.byKey(const Key('user-message-card-long')),
      );
      final action = tester.getRect(find.byKey(const ValueKey('fork-turn-t1')));
      final viewport = tester.getRect(find.byType(CustomScrollView));
      expect(rect.right, closeTo(viewport.right - 9, 1));
      expect(rect.left, greaterThanOrEqualTo(action.right + 6));
      expect(find.text('读取完整内容'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
