import 'package:codex_remote/src/ui/user_input_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/ui/user_input_dialog_test.dart' show pumpQuestionApp;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android question popup, keyboard, submit, skip and server cancellation',
    (tester) async {
      final h = await pumpQuestionApp(tester);
      h.session.ask();
      await tester.pumpAndSettle();
      expect(find.byType(UserInputDialog), findsOneWidget);
      await tester.tap(find.text('当前页面（推荐）'));
      await tester.ensureVisible(find.byKey(const ValueKey('answer-scope')));
      await tester.enterText(
        find.byKey(const ValueKey('answer-scope')),
        'Only this dialog',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('answer-notes')));
      await tester.enterText(
        find.byKey(const ValueKey('answer-notes')),
        'Keep data',
      );
      // Android's real IME reports its final metrics after the first settled
      // Flutter frame. Pump again after that transition, then check hit bounds.
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await tester.pumpAndSettle();
      final view = tester.view;
      expect(view.viewInsets.bottom, greaterThan(0));
      final keyboardTop =
          (view.physicalSize.height - view.viewInsets.bottom) /
          view.devicePixelRatio;
      expect(
        tester.getBottomRight(find.byKey(const Key('submit-user-input'))).dy,
        lessThan(keyboardTop),
      );
      // Leave the filled popup visible for an independent adb screenshot/IME check.
      await Future<void>.delayed(const Duration(seconds: 12));
      await tester.tap(find.byKey(const Key('submit-user-input')));
      await tester.pumpAndSettle();
      expect(find.byType(UserInputDialog), findsNothing);
      expect(h.session.responses.single['result'], {
        'answers': {
          'scope': {
            'answers': ['Only this dialog'],
          },
          'notes': {
            'answers': ['Keep data'],
          },
        },
      });
      expect(find.text('已收到回答，继续执行。'), findsOneWidget);
      h.session.ask(id: 'skip');
      await tester.pumpAndSettle();
      await tester.tap(find.text('跳过'));
      await tester.pumpAndSettle();
      expect(h.session.responses.last['result'], {'answers': {}});
      h.session.ask(id: 'cancelled');
      await tester.pumpAndSettle();
      h.session.resolve('cancelled');
      await tester.pumpAndSettle();
      expect(find.byType(UserInputDialog), findsNothing);
      expect(h.session.responses, hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );
}
