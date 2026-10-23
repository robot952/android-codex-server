import 'package:codex_remote/src/platform/app_update_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/ui/app_update_dialog_test.dart' show pumpAppUpdateDialogFixture;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android update dialog keeps actions in two compact rows', (
    tester,
  ) async {
    await pumpAppUpdateDialogFixture(tester, update: _update);
    await tester.pumpAndSettle();
    _expectTwoRows(tester);
    expect(tester.view.physicalSize.width, greaterThanOrEqualTo(1080));
    expect(tester.view.physicalSize.height, greaterThanOrEqualTo(2400));
    debugPrint('APP_UPDATE_COMPACT_SCREENSHOT_READY');
    await Future<void>.delayed(const Duration(seconds: 8));

    await tester.tap(find.text('下载更新'));
    await tester.pumpAndSettle();
    expect(find.text('安装更新').hitTestable(), findsOneWidget);
    expect(find.text('后台继续').hitTestable(), findsOneWidget);
    await tester.tap(find.text('安装更新'));
    await tester.pumpAndSettle();
    expect(find.text('重新打开安装').hitTestable(), findsOneWidget);
    expect(
      _actionRect(tester, '手动下载').center.dy,
      closeTo(_actionRect(tester, '重新打开安装').center.dy, 0.5),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Android update dialog keeps actions visible with 2x long notes',
    (tester) async {
      await pumpAppUpdateDialogFixture(
        tester,
        textScale: 2,
        update: AppUpdateInfo(
          versionName: _update.versionName,
          apkFileName: _update.apkFileName,
          changes: List.generate(
            20,
            (index) => AppUpdateReleaseNote(
              versionName: _update.versionName,
              gitCommit: 'abcdef1',
              message: '更新记录 ${index + 1}：优化更新弹窗布局，保留下载与安装操作。',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      _expectTwoRows(tester);
      final before = _actionRect(tester, '下载更新');
      await tester.drag(
        find.byKey(const ValueKey('app-update-content')),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();
      expect(_actionRect(tester, '下载更新'), before);
      _expectTwoRows(tester);
      debugPrint('APP_UPDATE_LARGE_TEXT_SCREENSHOT_READY');
      await Future<void>.delayed(const Duration(seconds: 8));
      expect(tester.takeException(), isNull);
    },
  );
}

void _expectTwoRows(WidgetTester tester) {
  final ignore = _actionRect(tester, '忽略此版本');
  final later = _actionRect(tester, '下次提醒');
  final manual = _actionRect(tester, '手动下载');
  final primary = _actionRect(tester, '下载更新');
  expect(ignore.center.dy, closeTo(later.center.dy, 0.5));
  expect(manual.center.dy, closeTo(primary.center.dy, 0.5));
  expect(ignore.right, lessThan(later.left));
  expect(manual.right, lessThan(primary.left));
  expect(ignore.bottom, lessThanOrEqualTo(manual.top));
  for (final label in ['忽略此版本', '下次提醒', '手动下载', '下载更新']) {
    expect(find.text(label).hitTestable(), findsOneWidget);
    expect(_actionRect(tester, label).height, greaterThanOrEqualTo(48));
  }
}

Rect _actionRect(WidgetTester tester, String label) => tester.getRect(
  find
      .ancestor(
        of: find.text(label),
        matching: find.bySubtype<ButtonStyleButton>(),
      )
      .first,
);

const _update = AppUpdateInfo(
  versionName: '1.8.184',
  apkFileName: 'Agent-1.8.184.apk',
  changes: [
    AppUpdateReleaseNote(
      versionName: '1.8.184',
      gitCommit: 'abcdef1',
      message: '优化更新弹窗布局，四个操作改为紧凑双列，下载与提醒分组显示。',
    ),
  ],
);
