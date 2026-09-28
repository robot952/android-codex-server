import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:xterm/xterm.dart';

import '../test/ui/terminal_screen_test.dart' show pumpTerminalSelectionFixture;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android terminal long press, handle drag and explicit clipboard',
    (tester) async {
      final sent = await pumpTerminalSelectionFixture(tester);
      await Clipboard.setData(
        const ClipboardData(text: 'unchanged-before-copy'),
      );
      final view = tester.widget<TerminalView>(find.byType(TerminalView));
      final viewState = tester.state<TerminalViewState>(
        find.byType(TerminalView),
      );
      Offset point(int column, int row) {
        final render = viewState.renderTerminal;
        return render.localToGlobal(
          render.getOffset(CellOffset(column, row)) +
              Offset(render.cellSize.width / 2, render.lineHeight / 2),
        );
      }

      // Commit focus first, then allow the native IME to report its insets.
      await tester.tapAt(point(15, 3));
      await tester.pump();
      for (var attempt = 0; attempt < 50; attempt++) {
        if (tester.view.viewInsets.bottom > 0) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
      }
      expect(viewState.hasInputConnection, isTrue);
      expect(tester.view.viewInsets.bottom, greaterThan(0));
      await tester.pumpAndSettle();

      await tester.longPressAt(point(1, 1));
      await tester.pumpAndSettle();
      expect(view.terminal.buffer.getText(view.controller!.selection), 'hello');
      expect(
        find.byKey(const ValueKey('terminal-selection-toolbar')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('terminal-selection-start')),
        findsOneWidget,
      );
      final endHandle = find.byKey(const ValueKey('terminal-selection-end'));
      expect(endHandle, findsOneWidget);
      final drag = await tester.startGesture(tester.getCenter(endHandle));
      await drag.moveBy(point(11, 2) - point(5, 1));
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
      expect(
        view.terminal.buffer.getText(view.controller!.selection),
        'hello world\nsecond line',
      );
      expect(
        (await Clipboard.getData(Clipboard.kTextPlain))?.text,
        'unchanged-before-copy',
      );
      expect(sent, isEmpty);
      final keyboardTop =
          (tester.view.physicalSize.height - tester.view.viewInsets.bottom) /
          tester.view.devicePixelRatio;
      expect(tester.getBottomRight(endHandle).dy, lessThan(keyboardTop));
      debugPrint('TERMINAL_SELECTION_SCREENSHOT_READY');
      await Future<void>.delayed(const Duration(seconds: 8));
      await tester.tap(find.text('复制'));
      await tester.pumpAndSettle();
      expect(
        (await Clipboard.getData(Clipboard.kTextPlain))?.text,
        'hello world\nsecond line',
      );
      expect(view.controller!.selection, isNull);
      expect(sent, isEmpty);

      await tester.longPressAt(point(1, 1));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('取消选择'));
      await tester.pumpAndSettle();
      expect(view.controller!.selection, isNull);
      viewState.requestKeyboard();
      await tester.pumpAndSettle();
      expect(viewState.hasInputConnection, isTrue);
      await tester.tap(find.text('TAB'));
      await tester.pumpAndSettle();
      expect(utf8.decode(sent.single), '\t');
      expect(
        find.byKey(const ValueKey('terminal-selection-toolbar')),
        findsNothing,
      );
      viewState.closeKeyboard();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
