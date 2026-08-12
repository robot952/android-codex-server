import 'dart:io';

import 'package:codex_remote/src/platform/diagnostic_logger.dart';
import 'package:codex_remote/src/ui/diagnostic_log_sheet.dart';
import 'package:codex_remote/src/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late Directory exportDirectory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('agent-log-picker-');
    exportDirectory = await Directory.systemTemp.createTemp(
      'agent-log-picker-export-',
    );
  });

  tearDown(() async {
    await directory.delete(recursive: true);
    await exportDirectory.delete(recursive: true);
  });

  DiagnosticLogger createLogger({
    bool enabled = false,
    DiagnosticShareHandler? shareHandler,
    DateTime Function()? clock,
  }) => DiagnosticLogger(
    directoryProvider: () async => directory,
    exportDirectoryProvider: () async => exportDirectory,
    settingsProvider: () async {
      final store = MemoryDiagnosticSettingsStore();
      await store.writeEnabled(enabled);
      return store;
    },
    shareHandler: shareHandler,
    clock: clock,
  );

  Future<void> writeLog(int timestamp, int size) => File(
    '${directory.path}/session-$timestamp-0.log',
  ).writeAsBytes(List<int>.filled(size, 65));

  Future<void> openPicker(WidgetTester tester) async {
    await tester.tap(find.text('打开'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find
          .byKey(const Key('diagnostic-log-confirm'))
          .evaluate()
          .isNotEmpty) {
        return;
      }
    }
    fail('diagnostic log picker did not open');
  }

  testWidgets('share picker matches the diagnostic log reference layout', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await writeLog(1_786_420_800_000, 484);
      await writeLog(1_786_424_400_000, 5_632);
    });
    List<String>? selected;
    final logger = createLogger(
      enabled: true,
      clock: () => DateTime.fromMillisecondsSinceEpoch(1_786_428_000_000),
    );
    await tester.runAsync(logger.initialize);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildCodexTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                selected = await pickDiagnosticLogIds(
                  context,
                  logger: logger,
                  title: '选择要分享的诊断日志',
                  confirmLabel: '分享',
                  preselectLatest: false,
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await openPicker(tester);

    expect(find.text('选择要分享的诊断日志'), findsOneWidget);
    expect(find.text('484 B'), findsOneWidget);
    expect(find.text('5.5 KB'), findsOneWidget);
    expect(find.text('当前记录中'), findsOneWidget);
    expect(find.textContaining('session-'), findsNothing);
    expect(find.text('全选'), findsNothing);
    expect(find.text('清除选择'), findsNothing);

    final activeLabel = tester.widget<Text>(find.text('当前记录中'));
    expect(activeLabel.style?.color, codexGreen);
    final confirm = find.byKey(const Key('diagnostic-log-confirm'));
    expect(tester.widget<TextButton>(confirm).onPressed, isNull);

    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    expect(tester.widget<TextButton>(confirm).onPressed, isNotNull);
    await tester.tap(find.text('分享'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(selected, hasLength(1));
  });

  testWidgets('latest crash is preselected and several logs can be chosen', (
    tester,
  ) async {
    final logger = createLogger();
    await tester.runAsync(() async {
      await logger.initialize();
      logger.recordError(StateError('crash'), StackTrace.current);
      await logger.snapshot();
      await logger.setEnabled(true);
      logger.info('Navigation', 'screen=threads');
      await logger.snapshot();
    });
    List<String>? selected;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildCodexTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                selected = await pickDiagnosticLogIds(
                  context,
                  logger: logger,
                  preferLatestCrash: true,
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await openPicker(tester);

    final checkboxes = tester.widgetList<Checkbox>(find.byType(Checkbox));
    expect(checkboxes, hasLength(2));
    expect(
      checkboxes.where((checkbox) => checkbox.value == true),
      hasLength(1),
    );
    expect(find.text('崩溃'), findsOneWidget);

    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(selected, hasLength(2));
  });

  testWidgets('attachment picker enforces its remaining attachment limit', (
    tester,
  ) async {
    final logger = createLogger();
    await tester.runAsync(() async {
      await logger.initialize();
      logger.recordError(StateError('first'), StackTrace.current);
      await logger.snapshot();
      await logger.setEnabled(true);
      logger.info('Test', 'second');
      await logger.snapshot();
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: buildCodexTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => pickDiagnosticLogIds(
                context,
                logger: logger,
                maxSelection: 1,
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await openPicker(tester);

    final checkboxes = tester.widgetList<Checkbox>(find.byType(Checkbox));
    expect(
      checkboxes.where((checkbox) => checkbox.value == true),
      hasLength(1),
    );
    expect(
      checkboxes.where((checkbox) => !checkbox.value!).single.onChanged,
      isNull,
    );
  });

  testWidgets(
    'many logs remain scrollable without overflowing a narrow screen',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        for (var index = 0; index < 14; index++) {
          await writeLog(1_786_420_800_000 + index * 1_000, 100 + index);
        }
      });
      final logger = createLogger();
      await tester.runAsync(logger.initialize);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildCodexTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => pickDiagnosticLogIds(
                  context,
                  logger: logger,
                  preselectLatest: false,
                  title: '选择要分享的诊断日志',
                  confirmLabel: '分享',
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await openPicker(tester);

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('diagnostic-log-list')), findsOneWidget);
      await tester.drag(
        find.byKey(const Key('diagnostic-log-list')),
        const Offset(0, -500),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
