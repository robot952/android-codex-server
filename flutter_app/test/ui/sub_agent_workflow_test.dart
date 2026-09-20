import 'package:codex_remote/src/app/app_controller.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/ui/sub_agent_presentation.dart';
import 'package:codex_remote/src/ui/theme.dart';
import 'package:codex_remote/src/ui/user_input_dialog.dart';
import 'package:codex_remote/src/ui/work_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/sub_agent_harness.dart';
import '../support/user_input_harness.dart' show drain;

Future<SubAgentHarness> pumpSubAgentApp(WidgetTester tester) async {
  final harness = (await tester.runAsync(() async => SubAgentHarness()))!;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(harness.close);
  });
  await tester.runAsync(
    () => harness.start().timeout(const Duration(seconds: 8)),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appControllerProvider.overrideWith((_) => harness.controller),
      ],
      child: MaterialApp(theme: buildCodexTheme(), home: const WorkScreen()),
    ),
  );
  await pumpSubAgentEvents(tester);
  return harness;
}

Future<void> pumpSubAgentEvents(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(drain);
    await tester.pump();
  }
  await tester.pump(const Duration(milliseconds: 300));
}

Finder childChip(String thread) =>
    find.byKey(ValueKey('sub-agent-chip:$thread')).first;

void main({bool device = false}) {
  testWidgets(
    'child history excludes root and parent messages are informational',
    (tester) async {
      if (!device) {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(420, 900);
        addTearDown(tester.view.reset);
      }
      final h = await pumpSubAgentApp(tester);
      h.session.addThread('child', title: 'Wrong inherited root title');
      h.session.item('parent', 'root-turn', {
        'id': 'root-only',
        'type': 'agentMessage',
        'text': 'ROOT_ONLY_CONTENT',
      });
      h.session.activity(
        'parent',
        'child',
        turn: 'root-turn',
        path: '/root/History audit',
      );
      h.session.item('child', 'root-turn', {
        'id': 'root-only',
        'type': 'agentMessage',
        'text': 'ROOT_ONLY_CONTENT',
      });
      h.session.item('child', 'child-turn', {
        'id': 'child-only',
        'type': 'agentMessage',
        'text': 'CHILD_ONLY_CONTENT',
      });
      h.session.collaboration(
        'child',
        {'parent': 'running'},
        turn: 'child-turn',
        tool: 'sendMessage',
      );
      await pumpSubAgentEvents(tester);
      await tester.tap(childChip('child'));
      await pumpSubAgentEvents(tester);
      expect(find.text('CHILD_ONLY_CONTENT'), findsOneWidget);
      expect(
        h.controller.state.timeline.any(
          (row) => row.text == 'ROOT_ONLY_CONTENT',
        ),
        isFalse,
      );
      expect(find.text('已向父代理发送消息'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(
        h.controller.state.timeline.toBackgroundSubAgentPresentations(),
        isEmpty,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('sub-agent-page-title')),
          matching: find.text('History audit'),
        ),
        findsOneWidget,
      );
      final childReads = h.session.requests
          .where(
            (request) => (request['params'] as Map?)?['threadId'] == 'child',
          )
          .toList();
      expect(
        childReads.any((request) => request['method'] == 'thread/read'),
        isTrue,
      );
      expect(
        childReads.any((request) => request['method'] == 'thread/resume'),
        isFalse,
      );
      h.session.startTurn('child', 'child-live-turn');
      h.session.ask('child');
      await pumpSubAgentEvents(tester);
      final requestCount = h.session.requests.length;
      await tester.runAsync(() async {
        await h.controller.sendMessage(text: 'must not send');
        await h.controller.stopMessage();
        await h.controller.answerApproval(true);
        await h.controller.renameActiveThread('must not rename');
        await h.controller.selectApprovalMode(ApprovalMode.fullAccess);
      });
      expect(h.session.requests.length, requestCount);
      expect(h.session.responses, isEmpty);
      expect(find.byType(UserInputDialog), findsNothing);
      if (device) {
        debugPrint('SUBAGENT_READ_ONLY_SCREENSHOT_READY');
        await Future<void>.delayed(const Duration(seconds: 12));
      }
      await tester.tap(find.byTooltip('返回上级会话'));
      await pumpSubAgentEvents(tester);
      expect(h.controller.state.screen, AppScreen.work);
      expect(find.byKey(const Key('composer-input')), findsOneWidget);
      await tester.tap(childChip('child'));
      await pumpSubAgentEvents(tester);
      expect(
        h.controller.state.timeline.any(
          (row) => row.text == 'ROOT_ONLY_CONTENT',
        ),
        isFalse,
      );
      expect(h.controller.state.screen, AppScreen.agentWork);
    },
  );

  testWidgets('parallel children retain distinct names and terminal results', (
    tester,
  ) async {
    if (!device) {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
    }
    final h = await pumpSubAgentApp(tester);
    for (final id in ['first', 'second', 'third']) {
      h.session.addThread(id);
      h.session.activity('parent', id, path: '/root/$id/review');
    }
    await pumpSubAgentEvents(tester);
    expect(find.text('3 个后台智能体'), findsOneWidget);
    expect(childChip('first'), findsOneWidget);
    expect(childChip('second'), findsOneWidget);
    expect(childChip('third'), findsOneWidget);
    h.session.collaboration('parent', {
      'first': 'completed',
      'second': 'errored',
      'third': 'interrupted',
    });
    await pumpSubAgentEvents(tester);
    final agents = h.controller.state.timeline
        .toBackgroundSubAgentPresentations();
    expect(agents.map((agent) => agent.name).toSet(), {'review'});
    expect(agents.map((agent) => agent.status).toSet(), {
      SubAgentDisplayStatus.completed,
      SubAgentDisplayStatus.failed,
      SubAgentDisplayStatus.interrupted,
    });
    expect(find.text('已完成'), findsWidgets);
    expect(find.text('失败'), findsWidgets);
    expect(find.text('已中断'), findsWidgets);
    await tester.tap(find.byKey(const Key('background-agents-toggle')));
    await pumpSubAgentEvents(tester);
    // Identity is bound to the thread, even when all three labels are equal.
    await tester.tap(find.byKey(const ValueKey('background-agent:second')));
    await pumpSubAgentEvents(tester);
    expect(h.controller.state.activeThread?.id, 'second');
    expect(h.controller.state.screen, AppScreen.agentWork);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'nested child pages are read-only and preserve the parent draft',
    (tester) async {
      if (!device) {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(420, 900);
        addTearDown(tester.view.reset);
      }
      final h = await pumpSubAgentApp(tester);
      h.session.addThread('child');
      h.session.addThread('grandchild');
      h.session.activity('parent', 'child', path: '/root/review');
      h.session.activity(
        'child',
        'grandchild',
        turn: 'child-turn',
        path: '/root/review/check',
      );
      await pumpSubAgentEvents(tester);
      h.controller.setComposerDraft('父会话草稿');
      await tester.tap(childChip('child'));
      await pumpSubAgentEvents(tester);
      expect(h.controller.state.activeThread?.id, 'child');
      expect(find.byType(TextField), findsNothing);
      expect(find.byKey(const Key('work-action-menu')), findsNothing);
      expect(find.byKey(const Key('background-agents-toggle')), findsNothing);
      final title = find.byKey(const Key('sub-agent-page-title'));
      expect(
        find.descendant(of: title, matching: find.text('review')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: title,
          matching: find.byKey(const ValueKey('sub-agent-icon:child')),
        ),
        findsOneWidget,
      );
      await tester.tap(childChip('grandchild'));
      await pumpSubAgentEvents(tester);
      expect(h.controller.state.activeThread?.id, 'grandchild');
      h.session.ask('child');
      await pumpSubAgentEvents(tester);
      expect(find.byType(UserInputDialog), findsNothing);
      await tester.tap(find.byTooltip('返回上级会话'));
      await pumpSubAgentEvents(tester);
      expect(h.controller.state.activeThread?.id, 'child');
      expect(find.byType(UserInputDialog), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(h.session.responses, isEmpty);
      await tester.tap(find.byTooltip('返回上级会话'));
      await pumpSubAgentEvents(tester);
      expect(h.controller.state.activeThread?.id, 'parent');
      expect(h.controller.state.composerDraft, '父会话草稿');
      expect(find.byType(TextField), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'long names and every terminal state fit enlarged narrow portrait',
    (tester) async {
      if (!device) {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(360, 900);
        addTearDown(tester.view.reset);
      }
      tester.platformDispatcher.textScaleFactorTestValue = 1.8;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final h = await pumpSubAgentApp(tester);
      const statuses = [
        'completed',
        'errored',
        'interrupted',
        'shutdown',
        'notFound',
      ];
      for (var i = 0; i < statuses.length; i++) {
        final id = 'worker-$i';
        h.session.addThread(id);
        h.session.activity('parent', id, path: '/root/检查长名称智能体与布局边界$i');
      }
      h.session.collaboration('parent', {
        for (var i = 0; i < statuses.length; i++) 'worker-$i': statuses[i],
      });
      await pumpSubAgentEvents(tester);
      await tester.tap(find.byKey(const Key('background-agents-toggle')));
      await pumpSubAgentEvents(tester);
      expect(find.text('5 个后台智能体'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'multiple parent turns accumulate workers without resurrecting completed work',
    (tester) async {
      final h = await pumpSubAgentApp(tester);
      for (var i = 0; i < 6; i++) {
        final id = 'worker-$i';
        h.session.addThread(id);
        h.session.activity('parent', id, turn: i < 3 ? 'turn-one' : 'turn-two');
      }
      h.session.collaboration('parent', {
        for (var i = 0; i < 3; i++) 'worker-$i': 'completed',
      }, turn: 'turn-one');
      h.session.activity(
        'parent',
        'worker-0',
        turn: 'turn-one',
        id: 'late-start',
      );
      await pumpSubAgentEvents(tester);
      final agents = h.controller.state.timeline
          .toBackgroundSubAgentPresentations();
      expect(agents, hasLength(6));
      expect(agents.where((agent) => agent.status.isActive), hasLength(3));
      expect(find.text('6 个后台智能体'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
