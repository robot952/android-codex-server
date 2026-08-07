import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/ui/theme.dart';
import 'package:codex_remote/src/ui/workspace_picker_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('browses parent and child directories and confirms selection', (
    tester,
  ) async {
    final browsed = <String?>[];
    var confirmed = false;

    await tester.pumpWidget(
      _DialogHarness(
        state: const AppUiState(
          workspacePickerVisible: true,
          workspaceCurrentPath: '/home/root/project',
          workspaceParentPath: '/home/root',
          workspaceDirectories: [
            RemoteDirectory(
              name: 'android',
              path: '/home/root/project/android',
            ),
            RemoteDirectory(name: 'docs', path: '/home/root/project/docs'),
          ],
        ),
        onBrowse: browsed.add,
        onConfirm: () => confirmed = true,
      ),
    );

    expect(find.text('/home/root/project'), findsOneWidget);
    expect(find.text('上一级'), findsOneWidget);
    expect(find.text('android'), findsOneWidget);

    await tester.tap(find.text('上一级'));
    await tester.tap(find.text('android'));
    await tester.tap(find.byKey(const ValueKey('workspace-picker-confirm')));

    expect(browsed, ['/home/root', '/home/root/project/android']);
    expect(confirmed, isTrue);
  });

  testWidgets(
    'loading blocks confirmation but allows navigation and dismissal',
    (tester) async {
      final browsed = <String?>[];
      var confirmed = false;
      var dismissed = false;

      await tester.pumpWidget(
        _DialogHarness(
          state: const AppUiState(
            workspacePickerVisible: true,
            workspaceLoading: true,
            workspaceCurrentPath: '/srv',
            workspaceDirectories: [
              RemoteDirectory(name: 'app', path: '/srv/app'),
            ],
          ),
          onBrowse: browsed.add,
          onConfirm: () => confirmed = true,
          onDismiss: () => dismissed = true,
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('workspace-picker-confirm')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('workspace-picker-dismiss')),
            )
            .onPressed,
        isNotNull,
      );

      await tester.tap(find.text('app'));
      await tester.tap(
        find.byKey(const ValueKey('workspace-picker-confirm')),
        warnIfMissed: false,
      );
      await tester.tap(
        find.byKey(const ValueKey('workspace-picker-dismiss')),
        warnIfMissed: false,
      );

      expect(browsed, ['/srv/app']);
      expect(confirmed, isFalse);
      expect(dismissed, isTrue);
    },
  );

  testWidgets('failed listing keeps the old path and can close', (
    tester,
  ) async {
    var dismissed = false;

    await tester.pumpWidget(
      _DialogHarness(
        state: const AppUiState(
          workspacePickerVisible: true,
          workspaceCurrentPath: '/workspace',
          workspaceError: '目录读取超时，请重试',
        ),
        onDismiss: () => dismissed = true,
      ),
    );

    expect(find.text('目录读取超时，请重试'), findsOneWidget);
    expect(find.text('当前目录没有子目录'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('workspace-picker-dismiss')));

    expect(dismissed, isTrue);
  });

  testWidgets('long paths and directory names stay inside a narrow viewport', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(280, 568);
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(
      const _DialogHarness(
        state: AppUiState(
          workspacePickerVisible: true,
          workspaceCurrentPath:
              '/home/root/a-very-long-project-name/another-long-directory',
          workspaceParentPath: '/home/root/a-very-long-project-name',
          workspaceDirectories: [
            RemoteDirectory(
              name: 'directory-name-that-must-not-overflow-the-dialog',
              path: '/home/root/a-very-long-project-name/child',
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    final dialogRect = tester.getRect(find.byType(Dialog));
    expect(dialogRect.left, greaterThanOrEqualTo(0));
    expect(dialogRect.right, lessThanOrEqualTo(280));
    expect(tester.takeException(), isNull);
  });
}

class _DialogHarness extends StatelessWidget {
  const _DialogHarness({
    required this.state,
    this.onBrowse = _noopBrowse,
    this.onConfirm = _noop,
    this.onDismiss = _noop,
  });

  final AppUiState state;
  final ValueChanged<String?> onBrowse;
  final VoidCallback onConfirm;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: buildCodexTheme(),
      home: Scaffold(
        body: Stack(
          fit: StackFit.expand,
          children: [
            const SizedBox.expand(),
            WorkspacePickerDialog(
              state: state,
              onBrowse: onBrowse,
              onConfirm: onConfirm,
              onDismiss: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}

void _noop() {}

void _noopBrowse(String? _) {}
