import 'dart:io';

import 'package:codex_remote/src/platform/diagnostic_logger.dart';
import 'package:codex_remote/src/ui/diagnostic_log_sheet.dart';
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

  DiagnosticLogger createLogger() => DiagnosticLogger(
    directoryProvider: () async => directory,
    exportDirectoryProvider: () async => exportDirectory,
    settingsProvider: () async => MemoryDiagnosticSettingsStore(),
  );

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
    await tester.tap(find.text('打开'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();

    final rows = tester.widgetList<CheckboxListTile>(
      find.byType(CheckboxListTile),
    );
    expect(rows, hasLength(2));
    expect(
      rows
          .where((row) => (row.title as Text).data!.contains('崩溃'))
          .single
          .value,
      isTrue,
    );

    await tester.tap(find.byType(CheckboxListTile).first);
    await tester.pump();
    await tester.tap(find.text('确定 (2)'));
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
    await tester.tap(find.text('打开'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();

    final rows = tester.widgetList<CheckboxListTile>(
      find.byType(CheckboxListTile),
    );
    expect(rows.where((row) => row.value == true), hasLength(1));
    expect(rows.where((row) => row.value == false).single.onChanged, isNull);
  });
}
