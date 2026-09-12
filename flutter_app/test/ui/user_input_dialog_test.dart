import 'dart:async';

import 'package:codex_remote/src/app/app_controller.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/ui/theme.dart';
import 'package:codex_remote/src/ui/user_input_dialog.dart';
import 'package:codex_remote/src/ui/work_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/user_input_harness.dart';

Future<QuestionHarness> pumpQuestionApp(WidgetTester tester) async {
  final h = QuestionHarness();
  addTearDown(() => tester.runAsync(h.close));
  await tester.runAsync(h.start);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appControllerProvider.overrideWith((_) => h.controller)],
      child: MaterialApp(theme: buildCodexTheme(), home: const WorkScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

void main() {
  testWidgets(
    'work page opens one dialog with descriptions, custom answers and exact JSONL response',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(420, 840);
      addTearDown(tester.view.reset);
      final h = await pumpQuestionApp(tester);
      h.session.ask();
      await tester.pumpAndSettle();
      expect(find.byType(UserInputDialog), findsOneWidget);
      expect(find.text('只修改当前页面，影响范围较小。'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('submit-user-input')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('当前页面（推荐）'));
      await tester.enterText(
        find.byKey(const ValueKey('answer-scope')),
        '只改弹窗',
      );
      await tester.enterText(
        find.byKey(const ValueKey('answer-notes')),
        '保留数据',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('submit-user-input')));
      await tester.runAsync(drain);
      await tester.pumpAndSettle();
      expect(find.byType(UserInputDialog), findsNothing);
      expect(h.session.responses.single['result'], {
        'answers': {
          'scope': {
            'answers': ['只改弹窗'],
          },
          'notes': {
            'answers': ['保留数据'],
          },
        },
      });
      expect(find.text('已收到回答，继续执行。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'server resolution closes only its route and queues next question',
    (tester) async {
      final h = await pumpQuestionApp(tester);
      h.session.ask(id: 'first');
      await tester.pumpAndSettle();
      h.session.ask(id: 'second');
      await tester.pumpAndSettle();
      expect(find.byType(UserInputDialog), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(UserInputDialog), findsOneWidget);
      h.session.resolve('first');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<UserInputDialog>(find.byType(UserInputDialog))
            .prompt
            .requestId,
        'second',
      );
      final navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('另一个页面')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      h.session.resolve('second');
      await tester.pumpAndSettle();
      expect(find.text('另一个页面'), findsOneWidget);
      navigator.pop();
      await tester.pumpAndSettle();
      expect(find.byType(UserInputDialog), findsNothing);
      expect(h.session.responses, isEmpty);
    },
  );

  testWidgets(
    'multi-question form stays usable above IME with enlarged text and secret field',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      final h = await pumpQuestionApp(tester);
      h.session.ask(
        questions: [
          {
            'id': 'secret',
            'header': '私密回答',
            'question': '请输入测试内容',
            'isSecret': true,
          },
        ],
      );
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('answer-secret'));
      await tester.tap(field);
      await tester.pump();
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.enterText(field, 'fixture-secret');
      await tester.pumpAndSettle();
      final input = tester.widget<TextField>(field);
      expect(input.obscureText, isTrue);
      expect(input.enableSuggestions, isFalse);
      expect(
        tester.getBottomRight(find.byKey(const Key('submit-user-input'))).dy,
        lessThanOrEqualTo(524),
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('跳过'));
      await tester.runAsync(drain);
      await tester.pumpAndSettle();
      expect(h.session.responses.single['result'], {'answers': {}});
    },
  );

  testWidgets(
    'failed replies retain answers and busy blocks duplicate submissions',
    (tester) async {
      final gate = Completer<void>();
      var calls = 0;
      const prompt = ApprovalPrompt(
        requestId: 'r',
        requestIdIsString: true,
        kind: ApprovalKind.userInput,
        threadId: 't',
        turnId: 'u',
        itemId: 'i',
        title: '',
        detail: '',
        questions: [InputQuestion(id: 'q', header: '问题', question: '如何处理？')],
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildCodexTheme(),
          home: Scaffold(
            body: UserInputDialog(
              prompt: prompt,
              onAnswer: (_, answers) async {
                calls++;
                expect(answers['q'], '保留');
                await gate.future;
                throw StateError('fixture');
              },
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), '保留');
      await tester.pump();
      await tester.tap(find.byKey(const Key('submit-user-input')));
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('submit-user-input')))
            .onPressed,
        isNull,
      );
      expect(calls, 1);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('回复失败，请检查连接后重试'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '保留',
      );
    },
  );
}
