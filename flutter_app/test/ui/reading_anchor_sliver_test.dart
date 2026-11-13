import 'package:codex_remote/src/ui/reading_anchor_sliver.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'keeps a keyed reading row through appended rows and live dragging',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(420, 840);
      addTearDown(tester.view.reset);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      final ids = ValueNotifier(List.generate(100, (index) => index));
      addTearDown(ids.dispose);
      final built = <int>{};
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<List<int>>(
              valueListenable: ids,
              builder: (context, values, _) => CustomScrollView(
                controller: scroll,
                center: const ValueKey('bottom'),
                anchor: 1,
                slivers: [
                  ReadingAnchorSliverList(
                    preserveReadingPosition: () =>
                        scroll.position.pixels < -0.5,
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final id = values[index];
                        built.add(id);
                        return SizedBox(
                          key: ValueKey(id),
                          height: 50 + (id % 3) * 10,
                          child: Text('row $id'),
                        );
                      },
                      childCount: values.length,
                      findChildIndexCallback: (key) {
                        final index = values.indexOf(
                          (key as ValueKey<int>).value,
                        );
                        return index < 0 ? null : index;
                      },
                    ),
                  ),
                  const SliverToBoxAdapter(
                    key: ValueKey('bottom'),
                    child: SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      scroll.jumpTo(-300);
      await tester.pumpAndSettle();
      final reading = find.text('row 14');
      final before = tester.getTopLeft(reading).dy;
      expect(before, inInclusiveRange(50, 700));
      for (final prefix in [1, 4, 80]) {
        ids.value = [
          ...List.generate(prefix, (index) => -prefix + index),
          ...List.generate(100, (index) => index),
        ];
        for (var frame = 0; frame < 3; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(
            reading,
            findsOneWidget,
            reason: 'prefix $prefix frame $frame offset ${scroll.offset}',
          );
          expect(tester.getTopLeft(reading).dy, closeTo(before, 0.5));
        }
      }
      final gesture = await tester.startGesture(const Offset(200, 450));
      await gesture.moveBy(const Offset(0, 80));
      await tester.pump();
      final draggedTop = tester.getTopLeft(reading).dy;
      expect(draggedTop, greaterThan(before));
      ids.value = [-81, ...ids.value];
      await tester.pump();
      expect(tester.getTopLeft(reading).dy, closeTo(draggedTop, 0.5));
      await gesture.moveBy(const Offset(0, -40));
      await tester.pump();
      expect(tester.getTopLeft(reading).dy, closeTo(draggedTop - 40, 0.5));
      await gesture.cancel();
      await tester.pumpAndSettle();
      final beforeResize = tester.getTopLeft(reading).dy;
      tester.view.physicalSize = const Size(420, 640);
      await tester.pump();
      expect(tester.getTopLeft(reading).dy, closeTo(beforeResize, 0.5));
      expect(
        built.where((id) => id > 60),
        isEmpty,
        reason: 'history stays lazy',
      );
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      expect(scroll.offset, 0);
      expect(find.text('row -81'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final readingLatest in [false, true]) {
    testWidgets(
      'holds ${readingLatest ? 'a paragraph in the active message' : 'older text'} during large output changes',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(420, 840);
        addTearDown(tester.view.reset);
        final scroll = ScrollController();
        addTearDown(scroll.dispose);
        final lineCount = ValueNotifier(30);
        addTearDown(lineCount.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ValueListenableBuilder<int>(
                valueListenable: lineCount,
                builder: (context, count, _) => CustomScrollView(
                  controller: scroll,
                  center: const ValueKey('bottom'),
                  anchor: 1,
                  slivers: [
                    ReadingAnchorSliverList(
                      preserveReadingPosition: () =>
                          scroll.position.pixels < -0.5,
                      delegate: SliverChildBuilderDelegate(
                        (context, index) => index == 0
                            ? Column(
                                key: const ValueKey('live'),
                                children: [
                                  for (var line = 0; line < count; line++)
                                    SizedBox(
                                      height: 40,
                                      child: Text('live line $line'),
                                    ),
                                ],
                              )
                            : SizedBox(
                                key: ValueKey(index),
                                height: 50,
                                child: Text('older $index'),
                              ),
                        childCount: 100,
                      ),
                    ),
                    const SliverToBoxAdapter(
                      key: ValueKey('bottom'),
                      child: SizedBox.shrink(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        scroll.jumpTo(readingLatest ? -600 : -1000);
        await tester.pumpAndSettle();
        final reading = find.text(readingLatest ? 'live line 0' : 'older 8');
        final before = tester.getTopLeft(reading).dy;
        expect(before, inInclusiveRange(0, 800));
        for (final count in [32, 100, 103, 35, 105]) {
          lineCount.value = count;
          for (var frame = 0; frame < 3; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
            expect(
              reading,
              findsOneWidget,
              reason: 'count $count frame $frame offset ${scroll.offset}',
            );
            expect(
              tester.getTopLeft(reading).dy,
              closeTo(before, 0.5),
              reason: 'count $count frame $frame',
            );
          }
        }
        // Anchoring must not pin the text when the user actually scrolls.
        scroll.jumpTo(scroll.offset + 100);
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(reading).dy, closeTo(before - 100, 0.5));
        scroll.jumpTo(0);
        await tester.pumpAndSettle();
        lineCount.value = 110;
        await tester.pumpAndSettle();
        expect(scroll.offset, 0);
        expect(find.text('live line 109'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
