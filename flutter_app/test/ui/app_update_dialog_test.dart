import 'package:codex_remote/src/platform/app_update_manager.dart';
import 'package:codex_remote/src/ui/app_update_dialog.dart';
import 'package:codex_remote/src/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
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
}

class _ImmediateUpdatePlatform implements AppUpdatePlatform {
  int installRequests = 0;

  @override
  Future<String> enqueueDownload({
    required String url,
    required String fileName,
  }) async => 'download-1';

  @override
  Future<AppUpdateInstallOutcome> installDownload(String downloadId) async {
    installRequests += 1;
    return const AppUpdateInstallOutcome(AppUpdateDownloadStatus.installing);
  }

  @override
  Future<void> removeDownload(String downloadId) async {}

  @override
  Future<AppUpdateDownloadSnapshot?> queryDownload(String downloadId) async {
    return const AppUpdateDownloadSnapshot(
      status: AppUpdateDownloadStatus.downloaded,
      downloadedBytes: 4096,
      totalBytes: 4096,
    );
  }
}
