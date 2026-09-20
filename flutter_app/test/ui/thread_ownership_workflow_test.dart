import 'package:codex_remote/src/domain/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sub_agent_workflow_test.dart' show pumpSubAgentApp, pumpSubAgentEvents;

void main({bool device = false}) {
  testWidgets(
    'occupied thread stays readable and retries after writer release',
    (tester) async {
      if (!device) {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(tester.view.reset);
      }
      final h = await pumpSubAgentApp(tester);
      h.session.item('parent', 'history-turn', {
        'id': 'history-answer',
        'type': 'agentMessage',
        'text': '已完成历史检查，保留当前页面的修改。',
      });
      await pumpSubAgentEvents(tester);
      await tester.enterText(
        find.byKey(const Key('composer-input')),
        '释放占用后继续检查',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      h.controller.backToThreadList();
      await pumpSubAgentEvents(tester);
      h.session.externallyOwnedThreads.add('parent');
      h.controller.openThread(const AgentThread(id: 'parent', title: '共享任务'));
      await pumpSubAgentEvents(tester);

      expect(h.controller.state.activeThread?.id, 'parent');
      expect(h.controller.state.activeThread?.isExternallyOwned, isTrue);
      expect(h.controller.state.isThreadReadOnly, isTrue);
      expect(find.text('已完成历史检查，保留当前页面的修改。'), findsOneWidget);
      expect(find.text('已在另一个应用中打开'), findsOneWidget);
      expect(find.text('请先在那边关闭会话，才能在这里继续。'), findsOneWidget);
      expect(find.byKey(const Key('composer-input')), findsNothing);
      expect(find.byKey(const Key('work-action-menu')), findsNothing);
      expect(h.controller.state.composerDraft, '释放占用后继续检查');
      expect(
        h.session.requests.any((request) => request['method'] == 'thread/read'),
        isTrue,
      );

      final beforeRetry = h.session.requests
          .where((request) => request['method'] == 'thread/resume')
          .length;
      await tester.tap(find.byKey(const Key('retry-active-thread')));
      await pumpSubAgentEvents(tester);
      expect(h.controller.state.activeThread?.isExternallyOwned, isTrue);
      expect(h.controller.state.loading, isFalse);
      expect(find.byKey(const Key('composer-input')), findsNothing);
      expect(
        h.session.requests
            .where((request) => request['method'] == 'thread/resume')
            .length,
        beforeRetry + 1,
      );
      final requestCount = h.session.requests.length;
      await tester.runAsync(() async {
        await h.controller.sendMessage(text: '不得发送');
        await h.controller.stopMessage();
        await h.controller.renameActiveThread('不得改名');
      });
      expect(h.session.requests.length, requestCount);

      if (device) {
        debugPrint('THREAD_OWNERSHIP_SCREENSHOT_READY');
        await Future<void>.delayed(const Duration(seconds: 12));
      }

      h.session.externallyOwnedThreads.remove('parent');
      await tester.tap(find.byKey(const Key('retry-active-thread')));
      await pumpSubAgentEvents(tester);
      expect(h.controller.state.activeThread?.isExternallyOwned, isFalse);
      expect(
        h.controller.state.timeline.any(
          (entry) => entry.text == '已完成历史检查，保留当前页面的修改。',
        ),
        isTrue,
      );
      await tester.pumpAndSettle();
      expect(h.controller.state.isThreadReadOnly, isFalse);
      expect(
        find.byKey(const Key('work-thread-read-only-banner')),
        findsNothing,
      );
      expect(find.byKey(const Key('composer-input')), findsOneWidget);
      expect(h.controller.state.composerDraft, '释放占用后继续检查');
      expect(find.text('释放占用后继续检查'), findsOneWidget);
      expect(find.text('已完成历史检查，保留当前页面的修改。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed read after ownership rejection retains cached history', (
    tester,
  ) async {
    final h = await pumpSubAgentApp(tester);
    h.session.item('parent', 'cached-turn', {
      'id': 'cached-answer',
      'type': 'agentMessage',
      'text': '只读加载失败时仍然保留这条历史。',
    });
    await pumpSubAgentEvents(tester);
    h.controller.backToThreadList();
    await pumpSubAgentEvents(tester);
    h.session.externallyOwnedThreads.add('parent');
    h.session.failNextResume.add('parent');
    h.controller.openThread(const AgentThread(id: 'parent', title: '共享任务'));
    await pumpSubAgentEvents(tester);

    expect(h.controller.state.activeThread?.isExternallyOwned, isTrue);
    expect(h.controller.state.loading, isFalse);
    expect(find.text('只读加载失败时仍然保留这条历史。'), findsOneWidget);
    expect(find.byKey(const Key('composer-input')), findsNothing);
    expect(find.text('已在另一个应用中打开'), findsOneWidget);
    expect(h.session.failNextResume, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
