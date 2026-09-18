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
    find.byKey(ValueKey('sub-agent-chip:$thread'));

void main({bool device = false}) {
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
    'nested child navigation keeps drafts and answers in the correct thread',
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
      h.controller.setComposerDraft('子会话草稿');
      await tester.tap(childChip('grandchild'));
      await pumpSubAgentEvents(tester);
      expect(h.controller.state.activeThread?.id, 'grandchild');
      h.session.ask('child');
      await pumpSubAgentEvents(tester);
      expect(find.byType(UserInputDialog), findsNothing);
      await tester.tap(find.byTooltip('返回上级会话'));
      await pumpSubAgentEvents(tester);
      expect(h.controller.state.activeThread?.id, 'child');
      expect(h.controller.state.composerDraft, '子会话草稿');
      expect(find.byType(UserInputDialog), findsOneWidget);
      await tester.tap(find.text('当前模块'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('submit-user-input')));
      await pumpSubAgentEvents(tester);
      expect(find.byType(UserInputDialog), findsNothing);
      expect(h.session.responses.single['id'], 'child-question');
      expect(h.session.responses.single['result'], {
        'answers': {
          'choice': {
            'answers': ['当前模块'],
          },
        },
      });
      await tester.tap(find.byTooltip('返回上级会话'));
      await pumpSubAgentEvents(tester);
      expect(h.controller.state.activeThread?.id, 'parent');
      expect(h.controller.state.composerDraft, '父会话草稿');
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
