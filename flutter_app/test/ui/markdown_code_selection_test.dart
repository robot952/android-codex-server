import 'dart:ui' as ui;

import 'package:codex_remote/src/app/app_controller.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/persistence/profile_store.dart';
import 'package:codex_remote/src/ssh/server_connection_manager.dart';
import 'package:codex_remote/src/ui/theme.dart';
import 'package:codex_remote/src/ui/work_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryStore implements ProfileStore {
  @override
  Future<StoredProfiles> load() async => const StoredProfiles();

  @override
  Future<void> save(StoredProfiles value) async {}
}

class _SelectionController extends AppController {
  // ignore: use_super_parameters
  _SelectionController(ProfileStore store, ServerConnectionManager manager)
    : super(store, manager);

  void showMessage(String text) {
    state = AppUiState(
      screen: AppScreen.work,
      activeThread: const AgentThread(id: 'selection', title: '代码选择'),
      timeline: [
        TimelineEntry(
          id: 'code-message',
          kind: TimelineKind.agentMessage,
          text: text,
        ),
      ],
    );
  }
}

// Inspect painted pixels, not just selectionColor: an opaque TextSpan
// background can cover the selection even when the theme and handles work.
Future<int> _highlightPixels(WidgetTester tester, Rect globalRect) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('selection-paint')),
  );
  final rect = globalRect
      .shift(-boundary.localToGlobal(Offset.zero))
      .intersect(Offset.zero & boundary.size);
  return (await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      var count = 0;
      for (var y = rect.top.ceil(); y < rect.bottom.floor(); y += 1) {
        for (var x = rect.left.ceil(); x < rect.right.floor(); x += 1) {
          final offset = (y * image.width + x) * 4;
          final color = Color.fromARGB(
            bytes.getUint8(offset + 3),
            bytes.getUint8(offset),
            bytes.getUint8(offset + 1),
            bytes.getUint8(offset + 2),
          );
          if (color == codexSelection) count += 1;
        }
      }
      return count;
    } finally {
      image.dispose();
    }
  }))!;
}

void main() => runMarkdownCodeSelectionTests();

void runMarkdownCodeSelectionTests({bool onDevice = false}) {
  const code = '#include <stdio.h>\nint main(void){ puts("Hello"); return 0; }';
  for (final sample in [
    (name: 'fenced code', markdown: '```c\n$code\n```', plain: code),
    (
      name: 'indented code',
      markdown:
          '    #include <stdio.h>\n    int main(void){ puts("Hello"); return 0; }',
      plain: code,
    ),
    (
      name: 'inline code',
      markdown: 'Use `Hello world` here.',
      plain: 'Use Hello world here.',
    ),
  ]) {
    testWidgets('${sample.name} paints selection and copies exact text', (
      tester,
    ) async {
      if (!onDevice) {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(420, 840);
        addTearDown(tester.view.reset);
      }
      final manager = ServerConnectionManager();
      final controller = _SelectionController(_MemoryStore(), manager);
      addTearDown(manager.close);
      String? copied;
      if (!onDevice) {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          },
        );
        addTearDown(() {
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          );
        });
      }
      Future<String?> clipboardText() async => onDevice
          ? (await Clipboard.getData(Clipboard.kTextPlain))?.text
          : copied;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appControllerProvider.overrideWith((ref) => controller)],
          child: MaterialApp(
            theme: buildCodexTheme(),
            home: const RepaintBoundary(
              key: Key('selection-paint'),
              child: WorkScreen(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      controller.showMessage(sample.markdown);
      await tester.pumpAndSettle();

      final paragraph = tester.renderObject<RenderParagraph>(
        find.byWidgetPredicate(
          (widget) =>
              widget is RichText && widget.text.toPlainText() == sample.plain,
        ),
      );
      final start = sample.plain.indexOf('Hello');
      final wordBox = paragraph
          .getBoxesForSelection(
            TextSelection(baseOffset: start, extentOffset: start + 5),
          )
          .single
          .toRect()
          .shift(paragraph.localToGlobal(Offset.zero));
      // Anti-aliased device glyphs can contain a few gray pixels even before
      // selection. Compare against that baseline instead of requiring zero.
      final unselectedPixels = await _highlightPixels(tester, wordBox);
      expect(unselectedPixels, lessThan(5));
      await tester.longPressAt(wordBox.center);
      await tester.pumpAndSettle();
      expect(find.text('Copy'), findsOneWidget);
      if (onDevice) {
        // Device fonts leave space between strokes, so also check a single
        // selected word rather than only the spaces covered by Select all.
        expect(
          await _highlightPixels(tester, wordBox),
          greaterThan(unselectedPixels + 20),
        );
      }
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();
      expect(await clipboardText(), 'Hello');
      expect(
        await _highlightPixels(tester, wordBox),
        closeTo(unselectedPixels, 2),
      );

      await tester.longPressAt(wordBox.center);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select all'));
      await tester.pumpAndSettle();
      final allBoxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: 0, extentOffset: sample.plain.length),
      );
      // Ahem draws each non-space glyph as a solid rectangle. Select the
      // spaces too so painted highlights are observable without font fixtures.
      for (final box in allBoxes) {
        expect(
          await _highlightPixels(
            tester,
            box.toRect().shift(paragraph.localToGlobal(Offset.zero)),
          ),
          greaterThan(20),
        );
      }
      if (onDevice && sample.name == 'fenced code') {
        debugPrint('CODE_SELECTION_SCREENSHOT_READY');
        await Future<void>.delayed(const Duration(seconds: 8));
      }
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();
      expect(await clipboardText(), sample.plain);
      expect(tester.takeException(), isNull);
    });
  }
}
