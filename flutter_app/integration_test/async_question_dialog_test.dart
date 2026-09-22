import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/ui/user_input_dialog_test.dart' show pumpQuestionApp;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Android nonblocking question collapses, reopens and skips', (
    tester,
  ) async {
    final h = await pumpQuestionApp(tester);
    h.session.emit({
      'method': 'turn/started',
      'params': {
        'threadId': 'question-thread',
        'turn': {'id': 'turn-async', 'status': 'inProgress'},
      },
    });
    h.session.emit({
      'method': 'item/completed',
      'params': {
        'threadId': 'question-thread',
        'turnId': 'turn-async',
        'item': {
          'id': 'async-scope',
          'type': 'agentMessage',
          'delivery': 'async',
          'text': '代码改动范围',
          'questions': [
            {
              'title': '代码改动范围',
              'options': ['先出评审报告（推荐）', '提交必要代码修改'],
            },
          ],
        },
      },
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const Key('async-question-dialog')), findsOneWidget);
    h.session.emit({
      'method': 'turn/completed',
      'params': {
        'threadId': 'question-thread',
        'turn': {'id': 'turn-async', 'status': 'completed'},
      },
    });
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('close-async-question')));
    await tester.pumpAndSettle();
    expect(find.text('先出评审报告（推荐）'), findsNothing);
    expect(find.text('回答问题'), findsOneWidget);
    await tester.tap(find.text('回答问题'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('async-answer-async:async-scope:0')),
      'Review only',
    );
    await Future<void>.delayed(const Duration(milliseconds: 800));
    await tester.pumpAndSettle();
    final view = tester.view;
    expect(view.viewInsets.bottom, greaterThan(0));
    final keyboardTop =
        (view.physicalSize.height - view.viewInsets.bottom) /
        view.devicePixelRatio;
    expect(
      tester.getBottomRight(find.byKey(const Key('submit-async-question'))).dy,
      lessThan(keyboardTop),
    );
    await Future<void>.delayed(const Duration(seconds: 4));
    await tester.tap(find.byKey(const Key('skip-async-question')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('async-question-dialog')), findsNothing);
    expect(
      h.session.requests.where(
        (r) =>
            r['method'] == 'turn/start' ||
            r['method'] == 'turn/steer' ||
            r['method'] == 'turn/interrupt',
      ),
      isEmpty,
    );
    expect(h.session.responses, isEmpty);
    await tester.tap(find.text('回答问题'));
    await tester.pumpAndSettle();
    expect(find.text('Review only'), findsOneWidget);
    await tester.tap(find.byKey(const Key('close-async-question')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
