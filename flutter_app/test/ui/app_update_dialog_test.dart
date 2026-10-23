import 'dart:async';

import 'package:codex_remote/src/platform/app_update_manager.dart';
import 'package:codex_remote/src/ui/app_update_dialog.dart';
import 'package:codex_remote/src/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const launcherChannel = MethodChannel('plugins.flutter.io/url_launcher');
  final launches = <MethodCall>[];

  setUp(() {
    launches.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(launcherChannel, (call) async {
          launches.add(call);
          return true;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(launcherChannel, null);
  });

  testWidgets('shows release notes and follows download and install states', (
    tester,
  ) async {
    final platform = _ImmediateUpdatePlatform();
    final controller = AppUpdateController(
      client: MockClient((_) async => http.Response('[]', 200)),
      platform: platform,
      preferencesLoader: () async => MemoryAppUpdatePreferences(),
      versionLoader: () async => '1.8.0',
      autoCheck: false,
      pollInterval: Duration.zero,
    );
    var later = 0;
    var ignored = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appUpdateProvider.overrideWith((ref) => controller)],
        child: MaterialApp(
          theme: buildCodexTheme(),
          home: Scaffold(
            body: AppUpdateDialog(
              update: const AppUpdateInfo(
                versionName: '1.8.1',
                apkFileName: 'Agent-1.8.1.apk',
                changes: [
                  AppUpdateReleaseNote(
                    versionName: '1.8.1',
                    gitCommit: 'abcdef1',
                    message: '补齐应用内更新',
                  ),
                ],
              ),
              onLater: () => later += 1,
              onIgnore: () => ignored += 1,
            ),
          ),
        ),
      ),
    );

    expect(find.text('发现新版本'), findsOneWidget);
    expect(find.text('v1.8.1'), findsOneWidget);
    expect(find.text('1. 补齐应用内更新'), findsOneWidget);
    expect(find.text('下载更新'), findsOneWidget);

    await tester.tap(find.text('下载更新'));
    await tester.pumpAndSettle();
    expect(find.text('下载完成'), findsOneWidget);
    expect(find.text('安装更新'), findsOneWidget);

    await tester.tap(find.text('安装更新'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('重新打开安装'), findsOneWidget);

    await tester.tap(find.text('后台继续'));
    expect(later, 1);
    expect(ignored, 0);
    expect(platform.installRequests, 1);
  });

  for (final fileName in ['Agent-1.8.1.apk', 'CodexRemote-1.8.1.apk']) {
    testWidgets('manual download opens $fileName in an external browser', (
      tester,
    ) async {
      final platform = _ImmediateUpdatePlatform();
      final controller = _controller(platform);
      await _pumpDialog(
        tester,
        controller,
        update: AppUpdateInfo(
          versionName: '1.8.1',
          apkFileName: fileName,
          changes: const [],
        ),
      );

      await tester.tap(find.text('手动下载'));
      await tester.pump();

      expect(launches.single.method, 'launch');
      expect(launches.single.arguments, {
        'url':
            'https://gitee.com/YanGanYuan/android-codex-server/releases/download/v1.8.1/$fileName',
        'useSafariVC': false,
        'useWebView': false,
        'enableJavaScript': true,
        'enableDomStorage': true,
        'universalLinksOnly': false,
        'headers': <String, String>{},
      });
      expect(platform.downloadRequests, 0);
      expect(controller.state.download.status, AppUpdateDownloadStatus.idle);
      expect(find.byType(AppUpdateDialog), findsOneWidget);
    });
  }

  testWidgets('manual download preserves an existing app download', (
    tester,
  ) async {
    final pendingSnapshot = Completer<AppUpdateDownloadSnapshot?>();
    final platform = _ImmediateUpdatePlatform()
      ..pendingSnapshot = pendingSnapshot;
    final controller = _controller(platform);
    await _pumpDialog(tester, controller);
    await controller.startDownload(_update);
    await tester.pump();
    expect(find.text('下载中'), findsOneWidget);

    await tester.tap(find.text('手动下载'));
    await tester.pump();

    expect(launches, hasLength(1));
    expect(platform.downloadRequests, 1);
    expect(platform.removedDownloads, isEmpty);
    expect(
      controller.state.download.status,
      AppUpdateDownloadStatus.downloading,
    );
    pendingSnapshot.complete(_downloadedSnapshot);
    await tester.pumpAndSettle();
    expect(find.text('安装更新'), findsOneWidget);
  });

  testWidgets('manual download remains available after app download fails', (
    tester,
  ) async {
    final platform = _ImmediateUpdatePlatform()
      ..downloadError = PlatformException(code: 'download_failed');
    final controller = _controller(platform);
    await _pumpDialog(tester, controller);
    await tester.tap(find.text('下载更新'));
    await tester.pumpAndSettle();
    expect(find.text('重新下载'), findsOneWidget);

    await tester.tap(find.text('手动下载'));
    await tester.pump();

    expect(launches, hasLength(1));
    expect(platform.downloadRequests, 1);
    expect(controller.state.download.status, AppUpdateDownloadStatus.failed);
    platform.downloadError = null;
    await tester.tap(find.text('重新下载'));
    await tester.pumpAndSettle();
    expect(find.text('安装更新'), findsOneWidget);
  });

  for (final throwsError in [false, true]) {
    testWidgets('browser failure is retryable (throws=$throwsError)', (
      tester,
    ) async {
      var failLaunch = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(launcherChannel, (call) async {
            launches.add(call);
            if (failLaunch && throwsError) {
              throw PlatformException(code: 'no_browser');
            }
            return !failLaunch;
          });
      final platform = _ImmediateUpdatePlatform();
      await _pumpDialog(tester, _controller(platform));

      await tester.tap(find.text('手动下载'));
      await tester.pump();
      expect(find.text('无法打开浏览器，请稍后重试'), findsOneWidget);
      expect(find.text('下载更新'), findsOneWidget);
      expect(tester.takeException(), isNull);

      failLaunch = false;
      await tester.tap(find.text('手动下载'));
      await tester.pump();
      expect(launches, hasLength(2));
      expect(platform.downloadRequests, 0);
    });
  }

  testWidgets('late browser failure is safe after the dialog closes', (
    tester,
  ) async {
    final opened = Completer<bool>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(launcherChannel, (_) => opened.future);
    await _pumpDialog(tester, _controller(_ImmediateUpdatePlatform()));
    await tester.tap(find.text('手动下载'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    opened.complete(false);
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  for (final (width, height, textScale) in [
    (390.0, 844.0, 1.0),
    (360.0, 800.0, 1.0),
    (320.0, 640.0, 1.0),
    (360.0, 800.0, 2.0),
    (320.0, 640.0, 2.0),
  ]) {
    testWidgets('update actions use two compact rows at $width/$textScale', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, height);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pumpDialog(
        tester,
        _controller(_ImmediateUpdatePlatform()),
        textScale: textScale,
      );

      final ignore = _actionRect(tester, '忽略此版本');
      final later = _actionRect(tester, '下次提醒');
      final manual = _actionRect(tester, '手动下载');
      final primary = _actionRect(tester, '下载更新');
      expect(ignore.center.dy, closeTo(later.center.dy, 0.5));
      expect(manual.center.dy, closeTo(primary.center.dy, 0.5));
      expect(ignore.right, lessThan(later.left));
      expect(manual.right, lessThan(primary.left));
      expect(ignore.bottom, lessThanOrEqualTo(manual.top));
      expect(manual.left, closeTo(ignore.left, 0.5));
      expect(primary.right, closeTo(later.right, 0.5));
      expect(manual.width, closeTo(primary.width, 0.5));
      if (textScale == 1) {
        expect(primary.bottom - ignore.top, lessThanOrEqualTo(120));
      }
      for (final label in ['忽略此版本', '下次提醒', '手动下载', '下载更新']) {
        expect(find.text(label).hitTestable(), findsOneWidget);
        expect(_actionRect(tester, label).height, greaterThanOrEqualTo(48));
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('long release notes scroll without moving the compact actions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pumpDialog(
      tester,
      _controller(_ImmediateUpdatePlatform()),
      textScale: 2,
      update: AppUpdateInfo(
        versionName: '1.8.1',
        apkFileName: 'Agent-1.8.1.apk',
        changes: List.generate(
          30,
          (index) => AppUpdateReleaseNote(
            versionName: '1.8.1',
            gitCommit: 'abcdef1',
            message: '更新记录 $index：优化界面布局，保留下载和安装操作。',
          ),
        ),
      ),
    );

    final footer = tester.getRect(
      find.byKey(const ValueKey('app-update-actions')),
    );
    final content = find.byKey(const ValueKey('app-update-content'));
    final scrollable = tester.state<ScrollableState>(
      find.descendant(of: content, matching: find.byType(Scrollable)),
    );
    expect(scrollable.position.maxScrollExtent, greaterThan(0));
    await tester.drag(content, const Offset(0, -300));
    await tester.pumpAndSettle();

    expect(scrollable.position.pixels, greaterThan(0));
    expect(
      tester.getRect(find.byKey(const ValueKey('app-update-actions'))),
      footer,
    );
    for (final label in ['忽略此版本', '下次提醒', '手动下载', '下载更新']) {
      expect(find.text(label).hitTestable(), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  for (final (installStatus, installLabel) in [
    (AppUpdateDownloadStatus.installing, '重新打开安装'),
    (AppUpdateDownloadStatus.awaitingInstallPermission, '继续安装'),
  ]) {
    testWidgets(
      'compact actions follow download and $installStatus at 2x text',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final pendingSnapshot = Completer<AppUpdateDownloadSnapshot?>();
        final platform = _ImmediateUpdatePlatform()
          ..pendingSnapshot = pendingSnapshot
          ..installStatus = installStatus;
        final controller = _controller(platform);
        await _pumpDialog(tester, controller, textScale: 2);

        await tester.tap(find.text('下载更新'));
        await tester.pump();
        expect(find.text('忽略此版本'), findsNothing);
        expect(find.text('后台继续').hitTestable(), findsOneWidget);
        expect(
          tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull,
        );
        expect(
          _actionRect(tester, '手动下载').center.dy,
          closeTo(_actionRect(tester, '下载中').center.dy, 0.5),
        );
        expect(tester.takeException(), isNull);

        pendingSnapshot.complete(_downloadedSnapshot);
        await tester.pumpAndSettle();
        expect(find.text('安装更新').hitTestable(), findsOneWidget);
        await tester.tap(find.text('安装更新'));
        await tester.pumpAndSettle();
        expect(find.text(installLabel).hitTestable(), findsOneWidget);
        expect(
          _actionRect(tester, '手动下载').center.dy,
          closeTo(_actionRect(tester, installLabel).center.dy, 0.5),
        );
        expect(
          _actionRect(tester, '手动下载').height,
          _actionRect(tester, installLabel).height,
        );
        expect(platform.installRequests, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('both reminder actions retain their independent callbacks', (
    tester,
  ) async {
    var ignored = 0;
    var later = 0;
    final platform = _ImmediateUpdatePlatform();
    await _pumpDialog(
      tester,
      _controller(platform),
      onIgnore: () => ignored += 1,
      onLater: () => later += 1,
    );

    await tester.tap(find.text('忽略此版本'));
    await tester.tap(find.text('下次提醒'));
    expect(ignored, 1);
    expect(later, 1);
    expect(platform.downloadRequests, 0);
  });

  testWidgets('download actions fit a narrow screen with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pumpDialog(
      tester,
      _controller(_ImmediateUpdatePlatform()),
      textScale: 2,
    );

    expect(find.text('手动下载').hitTestable(), findsOneWidget);
    expect(find.text('下载更新').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
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
  versionName: '1.8.1',
  apkFileName: 'Agent-1.8.1.apk',
  changes: [],
);
const _downloadedSnapshot = AppUpdateDownloadSnapshot(
  status: AppUpdateDownloadStatus.downloaded,
  downloadedBytes: 4096,
  totalBytes: 4096,
);

AppUpdateController _controller(AppUpdatePlatform platform) {
  return AppUpdateController(
    client: MockClient((_) async => http.Response('[]', 200)),
    platform: platform,
    preferencesLoader: () async => MemoryAppUpdatePreferences(),
    versionLoader: () async => '1.8.0',
    autoCheck: false,
    pollInterval: Duration.zero,
  );
}

// Shared with the Android layout regression; no real download or installer runs.
Future<void> pumpAppUpdateDialogFixture(
  WidgetTester tester, {
  required AppUpdateInfo update,
  double textScale = 1,
}) => _pumpDialog(
  tester,
  _controller(_ImmediateUpdatePlatform()),
  update: update,
  textScale: textScale,
);

Future<void> _pumpDialog(
  WidgetTester tester,
  AppUpdateController controller, {
  AppUpdateInfo update = _update,
  double textScale = 1,
  VoidCallback? onLater,
  VoidCallback? onIgnore,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appUpdateProvider.overrideWith((ref) => controller)],
      child: MaterialApp(
        theme: buildCodexTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: AppUpdateDialog(
            update: update,
            onLater: onLater ?? () {},
            onIgnore: onIgnore ?? () {},
          ),
        ),
      ),
    ),
  );
}

class _ImmediateUpdatePlatform implements AppUpdatePlatform {
  int downloadRequests = 0;
  int installRequests = 0;
  PlatformException? downloadError;
  AppUpdateDownloadStatus installStatus = AppUpdateDownloadStatus.installing;
  Completer<AppUpdateDownloadSnapshot?>? pendingSnapshot;
  final removedDownloads = <String>[];

  @override
  Future<String> enqueueDownload({
    required String url,
    required String fileName,
  }) async {
    downloadRequests += 1;
    if (downloadError != null) throw downloadError!;
    return 'download-1';
  }

  @override
  Future<AppUpdateInstallOutcome> installDownload(String downloadId) async {
    installRequests += 1;
    return AppUpdateInstallOutcome(installStatus);
  }

  @override
  Future<void> removeDownload(String downloadId) async {
    removedDownloads.add(downloadId);
  }

  @override
  Future<AppUpdateDownloadSnapshot?> queryDownload(String downloadId) async {
    final pending = pendingSnapshot;
    if (pending != null) return pending.future;
    return _downloadedSnapshot;
  }
}
