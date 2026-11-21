import 'dart:async';

import 'package:codex_remote/src/app/app_controller.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/persistence/profile_store.dart';
import 'package:codex_remote/src/ssh/server_connection_manager.dart';
import 'package:codex_remote/src/ui/theme.dart';
import 'package:codex_remote/src/ui/work_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  Completer<String?>? pendingCopy;
  @override
  Future<String?> textForCopyAtTurn(String turnId) =>
      pendingCopy?.future ?? super.textForCopyAtTurn(turnId);

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
    final copy = find.byKey(const ValueKey('copy-turn-t1'));
    expect(action, findsOneWidget);
    expect(find.byTooltip('从此处分叉'), findsNWidgets(2));
    expect(
      tester.getTopLeft(action).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(find.text('第一轮结尾')).dy),
    );
    expect(
      tester.getTopLeft(copy).dx,
      closeTo(tester.getRect(find.byType(CustomScrollView)).left + 9, 1),
    );
    expect(
      tester.getTopRight(copy).dx,
      closeTo(tester.getTopLeft(action).dx, 0.1),
    );
    expect(tester.getCenter(copy).dy, tester.getCenter(action).dy);
    expect(tester.getSize(copy).shortestSide, greaterThanOrEqualTo(48));
    expect(tester.getSize(action).shortestSide, greaterThanOrEqualTo(48));
    Rect iconRect(Finder button) => tester.getRect(
      find.descendant(
        of: button,
        matching: find.byWidget(tester.widget<IconButton>(button).icon),
      ),
    );
    final copyIcon = iconRect(copy);
    final forkIcon = iconRect(action);
    expect(copyIcon.top, closeTo(forkIcon.top, 0.1));
    expect(
      copyIcon.top - tester.getBottomLeft(find.text('第一轮结尾')).dy,
      closeTo(11, 0.1),
    );
    expect(
      tester.getTopLeft(find.text('第二轮结尾')).dy - tester.getBottomLeft(copy).dy,
      closeTo(2, 0.1),
    );

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
    expect(find.byTooltip('复制本轮回复'), findsNothing);
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
      final copy = tester.getRect(find.byKey(const ValueKey('copy-turn-t1')));
      final viewport = tester.getRect(find.byType(CustomScrollView));
      expect(rect.right, closeTo(viewport.right - 9, 1));
      expect(copy.right, closeTo(action.left, 0.1));
      expect(rect.left, greaterThanOrEqualTo(action.right + 6));
      expect(find.text('读取完整内容'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('copies raw Markdown only from the chosen completed final answer', (
    tester,
  ) async {
    _stubClipboardUnlessOnDevice(tester, onDevice);
    const markdown =
        '  # 标题\n\n```dart\n    print(1);\n```\n\n[原始链接](https://example.org)  \n';
    final first = _source.timeline[1];
    final controller = await _pump(
      tester,
      _source.copyWith(
        timeline: [
          first.copyWith(
            id: 'analysis',
            agentMessagePhase: 'commentary',
            text: '进度说明',
          ),
          first.copyWith(agentMessagePhase: 'final_answer', text: markdown),
          _source.timeline[2],
        ],
      ),
    );
    final copy = find.byKey(const ValueKey('copy-turn-t1'));
    await tester.ensureVisible(copy);
    await tester.tap(copy);
    await tester.pumpAndSettle();
    expect((await Clipboard.getData(Clipboard.kTextPlain))?.text, markdown);
    expect(find.text('已复制本轮回复'), findsOneWidget);

    controller.show(
      _source.copyWith(
        timeline: [
          first.copyWith(agentMessagePhase: 'commentary'),
          _source.timeline[2].copyWith(
            agentMessagePhase: 'final_answer',
            status: 'codex.remote.displayRestricted',
            text: '',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(copy).onPressed, isNull);
    // A restricted answer may have no visible row at all. If it has one,
    // never offer to export the restricted message.
    final restricted = find.byKey(const ValueKey('copy-turn-t2'));
    expect(
      tester
          .widgetList<IconButton>(restricted)
          .every((button) => button.onPressed == null),
      isTrue,
    );
  });

  testWidgets(
    'a late history detail cannot write into the clipboard after navigation',
    (tester) async {
      _stubClipboardUnlessOnDevice(tester, onDevice);
      await Clipboard.setData(const ClipboardData(text: '保留原剪贴板'));
      final controller = await _pump(tester, _source);
      final pending = controller.pendingCopy = Completer<String?>();
      await tester.tap(find.byKey(const ValueKey('copy-turn-t1')));
      await tester.pump();
      controller.show(
        _source.copyWith(activeThread: _thread.copyWith(id: 'branch')),
      );
      await tester.pump();
      // Even returning to the original thread must not revive the stale request.
      controller.show(_source);
      await tester.pump();
      pending.complete('来自旧请求的内容');
      await tester.pumpAndSettle();
      expect((await Clipboard.getData(Clipboard.kTextPlain))?.text, '保留原剪贴板');
      expect(find.text('已复制本轮回复'), findsNothing);
    },
  );
}

void _stubClipboardUnlessOnDevice(WidgetTester tester, bool onDevice) {
  if (onDevice) return;
  String? value;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        value = (call.arguments as Map)['text'] as String;
      }
      if (call.method == 'Clipboard.getData') return {'text': value};
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
}
