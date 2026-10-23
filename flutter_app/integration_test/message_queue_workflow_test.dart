import 'package:codex_remote/src/domain/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/ui/message_queue_ui_test.dart'
    show
        pumpQueueApp,
        pumpQueueEvents,
        queueComposer,
        queueSend,
        verifyImmediateSendingFeedback;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final kind in AgentKind.values) {
    testWidgets(
      'Android ${kind.name} send spins until upload and confirmation',
      (tester) async {
        await verifyImmediateSendingFeedback(tester, kind: kind);
      },
    );
  }
  testWidgets('Android queue and editor stay above the real keyboard', (
    tester,
  ) async {
    final h = await pumpQueueApp(tester);
    await tester.enterText(queueComposer, 'Queued first');
    await tester.pump();
    await tester.tap(queueSend);
    await pumpQueueEvents(tester);
    await tester.enterText(queueComposer, 'Queued second');
    await tester.pump();
    await tester.tap(queueSend);
    await pumpQueueEvents(tester);
    expect(h.controller.state.queuedMessages, hasLength(2));
    expect(h.agent.starts, isEmpty);
    await tester.enterText(queueComposer, 'Composer draft');
    await Future<void>.delayed(const Duration(milliseconds: 900));
    await pumpQueueEvents(tester);
    final view = tester.view;
    expect(view.physicalSize.width, greaterThanOrEqualTo(1080));
    expect(view.physicalSize.height, greaterThanOrEqualTo(2400));
    expect(view.viewInsets.bottom, greaterThan(0));
    double keyboardTop() =>
        (view.physicalSize.height - view.viewInsets.bottom) /
        view.devicePixelRatio;
    expect(tester.getBottomRight(queueSend).dy, lessThan(keyboardTop()));
    debugPrint('MESSAGE_QUEUE_COMPOSER_SCREENSHOT_READY');
    await Future<void>.delayed(const Duration(seconds: 8));
    final first = h.controller.state.queuedMessages.first.id;
    await tester.tap(find.byKey(ValueKey('queued-message-menu:$first')));
    await pumpQueueEvents(tester);
    await tester.tap(find.text('编辑'));
    await pumpQueueEvents(tester);
    // Let Android attach the editor's IME connection before replacing the text;
    // otherwise its initial native echo can overwrite the test's update.
    await tester.tap(find.byKey(const Key('queued-message-edit-input')));
    await Future<void>.delayed(const Duration(milliseconds: 900));
    await pumpQueueEvents(tester);
    await tester.enterText(
      find.byKey(const Key('queued-message-edit-input')),
      'Edited on Android',
    );
    await Future<void>.delayed(const Duration(milliseconds: 900));
    await pumpQueueEvents(tester);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('queued-message-edit-input')))
          .controller!
          .text,
      'Edited on Android',
    );
    expect(view.viewInsets.bottom, greaterThan(0));
    expect(
      tester.getBottomRight(find.byKey(const Key('queued-message-save'))).dy,
      lessThan(keyboardTop()),
    );
    debugPrint('MESSAGE_QUEUE_IME_SCREENSHOT_READY');
    await Future<void>.delayed(const Duration(seconds: 8));
    await tester.tap(find.byKey(const Key('queued-message-save')));
    await pumpQueueEvents(tester);
    expect(h.controller.state.queuedMessages.first.text, 'Edited on Android');
    expect(h.controller.state.composerDraft, 'Composer draft');
    expect(find.byKey(const Key('background-agents-toggle')), findsNothing);
    h.agent.complete('turn-0');
    await pumpQueueEvents(tester);
    expect(h.agent.starts.single.text, 'Edited on Android');
    expect(h.controller.state.queuedMessages.single.text, 'Queued second');
    expect(tester.takeException(), isNull);
  });
}
