import 'dart:async';
import 'dart:convert';

import 'package:codex_remote/src/platform/app_update_manager.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('release parser selects the newest stable release with an APK', () {
    final update = parseGiteeReleases(
      jsonEncode([
        {
          'tag_name': 'v1.9.0-beta.1',
          'prerelease': true,
          'assets': [
            {'name': 'Agent-1.9.0-beta.1.apk'},
          ],
        },
        {
          'tag_name': 'v1.8.2',
          'assets': [
            {'name': 'Agent-1.8.2.apk'},
          ],
          'body': '- `abcdef123` 修复会话恢复\n* fedcba987 优化更新页面',
        },
        {
          'tag_name': 'v1.8.1',
          'assets': [
            {'name': 'CodexRemote-1.8.1.apk'},
          ],
        },
        {
          'tag_name': 'v2.0.0',
          'assets': [
            {'name': 'source.zip'},
          ],
        },
      ]),
    );

    expect(update?.versionName, '1.8.2');
    expect(update?.downloadFileName, 'Agent-1.8.2.apk');
    expect(update?.changes.map((entry) => entry.message), ['修复会话恢复', '优化更新页面']);
    expect(
      appUpdateDownloadUrl(update!),
      '$appUpdateRepositoryUrl/releases/download/v1.8.2/Agent-1.8.2.apk',
    );
    expect(
      Uri.parse(appUpdateReleasesUrl).queryParameters['direction'],
      'desc',
    );
  });

  test('release parser rejects a tag that cannot match the download URL', () {
    final update = parseGiteeReleases(
      jsonEncode([
        {
          'tag_name': '1.8.3',
          'assets': [
            {'name': 'Agent-1.8.3.apk'},
          ],
        },
      ]),
    );

    expect(update, isNull);
  });

  test(
    'release parser rejects prerelease SemVer tags without the API flag',
    () {
      final update = parseGiteeReleases(
        jsonEncode([
          {
            'tag_name': 'v1.9.0-beta.1',
            'prerelease': false,
            'assets': [
              {'name': 'Agent-1.9.0-beta.1.apk'},
            ],
          },
          {
            'tag_name': 'v1.8.2',
            'assets': [
              {'name': 'Agent-1.8.2.apk'},
            ],
          },
        ]),
      );

      expect(update?.versionName, '1.8.2');
    },
  );

  test('semantic versions follow release and prerelease ordering', () {
    expect(compareSemanticVersions('1.8.1', '1.8.0'), greaterThan(0));
    expect(compareSemanticVersions('1.8.0', '1.8.0-beta.2'), greaterThan(0));
    expect(
      compareSemanticVersions('1.8.0-beta.10', '1.8.0-beta.2'),
      greaterThan(0),
    );
    expect(compareSemanticVersions('1.8.0+120', '1.8.0+119'), 0);
    expect(compareSemanticVersions('invalid', '1.8.0'), 0);
  });

  test('prompt, progress, and byte helpers match the legacy behavior', () {
    const update = AppUpdateInfo(versionName: '1.8.1', changes: []);

    expect(availableUpdateFor(update, '1.8.0'), same(update));
    expect(availableUpdateFor(update, '1.8.1'), isNull);
    expect(shouldPromptUpdate(update, null), isTrue);
    expect(shouldPromptUpdate(update, '1.8.1'), isFalse);
    expect(updateDownloadProgressFraction(25, 100), 0.25);
    expect(updateDownloadProgressFraction(200, 100), 1);
    expect(updateDownloadProgressFraction(10, null), isNull);
    expect(formatAppUpdateByteSize(1024), '1.0 KB');
    expect(formatAppUpdateByteSize(1024 * 1024), '1.0 MB');
  });

  test('persists and clears a recoverable system download record', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesAppUpdatePreferences(
      await SharedPreferences.getInstance(),
    );
    const pending = PendingAppUpdateDownload(
      versionName: '1.8.1',
      downloadId: '123',
      apkFileName: 'Agent-1.8.1.apk',
    );

    await preferences.setPendingDownload(pending);

    expect(preferences.pendingDownload?.versionName, '1.8.1');
    expect(preferences.pendingDownload?.downloadId, '123');
    expect(preferences.pendingDownload?.apkFileName, 'Agent-1.8.1.apk');

    await preferences.clearPendingDownload();
    expect(preferences.pendingDownload, isNull);
  });

  test('download state follows the native task to completion', () async {
    final platform = _FakeUpdatePlatform();
    final preferences = MemoryAppUpdatePreferences();
    final controller = AppUpdateController(
      platform: platform,
      preferencesLoader: () async => preferences,
      versionLoader: () async => '1.8.0',
      autoCheck: false,
      pollInterval: Duration.zero,
    );
    addTearDown(controller.dispose);

    await controller.initialize();
    const update = AppUpdateInfo(
      versionName: '1.8.1',
      changes: [],
      apkFileName: 'Agent-1.8.1.apk',
    );
    expect(await controller.startDownload(update), isTrue);
    await _waitUntil(
      () =>
          controller.state.download.status ==
          AppUpdateDownloadStatus.downloaded,
    );

    expect(platform.enqueuedFileName, 'Agent-1.8.1.apk');
    expect(controller.state.download.downloadedBytes, 2048);
    expect(controller.state.download.totalBytes, 2048);
    expect(preferences.pendingDownload?.downloadId, '42');
    expect(await controller.installDownloadedUpdate(), isTrue);
    expect(
      controller.state.download.status,
      AppUpdateDownloadStatus.installing,
    );
    expect(await controller.installDownloadedUpdate(), isTrue);
    expect(platform.installRequests, 2);

    await controller.refreshAfterResume();
    expect(
      controller.state.download.status,
      AppUpdateDownloadStatus.downloaded,
    );
  });

  test(
    'restores a persisted system download without enqueueing it again',
    () async {
      final preferences = MemoryAppUpdatePreferences();
      await preferences.setPendingDownload(
        const PendingAppUpdateDownload(
          versionName: '1.8.1',
          downloadId: '77',
          apkFileName: 'Agent-1.8.1.apk',
        ),
      );
      final platform = _FakeUpdatePlatform();
      final controller = AppUpdateController(
        platform: platform,
        preferencesLoader: () async => preferences,
        versionLoader: () async => '1.8.0',
        autoCheck: false,
        pollInterval: Duration.zero,
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      expect(controller.state.availableUpdate?.versionName, '1.8.1');
      expect(controller.state.download.downloadId, '77');
      await _waitUntil(
        () =>
            controller.state.download.status ==
            AppUpdateDownloadStatus.downloaded,
      );

      expect(platform.enqueuedFileName, isNull);
      expect(preferences.pendingDownload?.downloadId, '77');
    },
  );

  test('clears a persisted task after that version is installed', () async {
    final preferences = MemoryAppUpdatePreferences();
    await preferences.setPendingDownload(
      const PendingAppUpdateDownload(
        versionName: '1.8.1',
        downloadId: '77',
        apkFileName: 'Agent-1.8.1.apk',
      ),
    );
    final platform = _FakeUpdatePlatform();
    final controller = AppUpdateController(
      platform: platform,
      preferencesLoader: () async => preferences,
      versionLoader: () async => '1.8.1',
      autoCheck: false,
      pollInterval: Duration.zero,
    );
    addTearDown(controller.dispose);

    await controller.initialize();

    expect(preferences.pendingDownload, isNull);
    expect(controller.state.download.status, AppUpdateDownloadStatus.idle);
    expect(platform.queryRequests, 0);
    expect(platform.removedDownloadIds, ['77']);
  });

  test('failed system downloads are not restored on the next launch', () async {
    final preferences = MemoryAppUpdatePreferences();
    final platform = _FakeUpdatePlatform(
      snapshots: const [
        AppUpdateDownloadSnapshot(
          status: AppUpdateDownloadStatus.failed,
          errorMessage: '网络错误',
        ),
      ],
    );
    final controller = AppUpdateController(
      platform: platform,
      preferencesLoader: () async => preferences,
      versionLoader: () async => '1.8.0',
      autoCheck: false,
      pollInterval: Duration.zero,
    );
    addTearDown(controller.dispose);

    await controller.initialize();
    await controller.startDownload(
      const AppUpdateInfo(
        versionName: '1.8.1',
        changes: [],
        apkFileName: 'Agent-1.8.1.apk',
      ),
    );
    await _waitUntil(() => preferences.pendingDownload == null);

    expect(controller.state.download.status, AppUpdateDownloadStatus.failed);
  });

  test('concurrent taps enqueue only one download task', () async {
    final platform = _BlockingEnqueueUpdatePlatform();
    final controller = AppUpdateController(
      platform: platform,
      preferencesLoader: () async => MemoryAppUpdatePreferences(),
      versionLoader: () async => '1.8.0',
      autoCheck: false,
      pollInterval: Duration.zero,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    const update = AppUpdateInfo(
      versionName: '1.8.1',
      changes: [],
      apkFileName: 'Agent-1.8.1.apk',
    );

    final first = controller.startDownload(update);
    await platform.enqueueStarted.future;
    final second = controller.startDownload(update);
    expect(platform.enqueueRequests, 1);

    platform.enqueueRelease.complete('88');
    expect(await first, isTrue);
    expect(await second, isTrue);
  });

  test(
    'a different release is rejected while a download request is in flight',
    () async {
      final platform = _BlockingEnqueueUpdatePlatform();
      final controller = AppUpdateController(
        platform: platform,
        preferencesLoader: () async => MemoryAppUpdatePreferences(),
        versionLoader: () async => '1.8.0',
        autoCheck: false,
        pollInterval: Duration.zero,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      const firstUpdate = AppUpdateInfo(
        versionName: '1.8.1',
        changes: [],
        apkFileName: 'Agent-1.8.1.apk',
      );
      const secondUpdate = AppUpdateInfo(
        versionName: '1.8.2',
        changes: [],
        apkFileName: 'Agent-1.8.2.apk',
      );

      final first = controller.startDownload(firstUpdate);
      await platform.enqueueStarted.future;
      expect(await controller.startDownload(secondUpdate), isFalse);
      expect(platform.enqueueRequests, 1);

      platform.enqueueRelease.complete('89');
      expect(await first, isTrue);
    },
  );

  test('concurrent install taps share one installer request', () async {
    final platform = _BlockingInstallUpdatePlatform();
    final controller = AppUpdateController(
      platform: platform,
      preferencesLoader: () async => MemoryAppUpdatePreferences(),
      versionLoader: () async => '1.8.0',
      autoCheck: false,
      pollInterval: Duration.zero,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.startDownload(
      const AppUpdateInfo(
        versionName: '1.8.1',
        changes: [],
        apkFileName: 'Agent-1.8.1.apk',
      ),
    );
    await _waitUntil(
      () =>
          controller.state.download.status ==
          AppUpdateDownloadStatus.downloaded,
    );

    final first = controller.installDownloadedUpdate();
    await platform.installStarted.future;
    final second = controller.installDownloadedUpdate();
    expect(platform.installRequests, 1);

    platform.installRelease.complete(
      const AppUpdateInstallOutcome(AppUpdateDownloadStatus.installing),
    );
    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(platform.installRequests, 1);
  });

  test(
    'a null query result preserves the recoverable download record',
    () async {
      final preferences = MemoryAppUpdatePreferences();
      final platform = _FakeUpdatePlatform(snapshots: const [null, null]);
      final controller = AppUpdateController(
        platform: platform,
        preferencesLoader: () async => preferences,
        versionLoader: () async => '1.8.0',
        autoCheck: false,
        pollInterval: Duration.zero,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.startDownload(
        const AppUpdateInfo(
          versionName: '1.8.1',
          changes: [],
          apkFileName: 'Agent-1.8.1.apk',
        ),
      );
      await _waitUntil(() => platform.queryRequests > 0);
      expect(
        controller.state.download.status,
        AppUpdateDownloadStatus.downloading,
      );
      expect(preferences.pendingDownload?.downloadId, '42');

      await controller.refreshAfterResume();
      expect(
        controller.state.download.status,
        AppUpdateDownloadStatus.downloading,
      );
      expect(preferences.pendingDownload?.downloadId, '42');
    },
  );

  test('activity destruction error preserves an installing task', () async {
    final preferences = MemoryAppUpdatePreferences();
    final platform = _DestroyedActivityUpdatePlatform();
    final controller = AppUpdateController(
      platform: platform,
      preferencesLoader: () async => preferences,
      versionLoader: () async => '1.8.0',
      autoCheck: false,
      pollInterval: Duration.zero,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.startDownload(
      const AppUpdateInfo(
        versionName: '1.8.1',
        changes: [],
        apkFileName: 'Agent-1.8.1.apk',
      ),
    );
    await _waitUntil(
      () =>
          controller.state.download.status ==
          AppUpdateDownloadStatus.downloaded,
    );

    expect(await controller.installDownloadedUpdate(), isFalse);
    expect(
      controller.state.download.status,
      AppUpdateDownloadStatus.installing,
    );
    expect(preferences.pendingDownload?.downloadId, '42');
    await controller.refreshAfterResume();
    expect(preferences.pendingDownload?.downloadId, '42');
  });

  test(
    'refresh removes the APK after the installed version advances',
    () async {
      final preferences = MemoryAppUpdatePreferences();
      final platform = _FakeUpdatePlatform(
        snapshots: const [
          AppUpdateDownloadSnapshot(
            status: AppUpdateDownloadStatus.downloaded,
            downloadedBytes: 2048,
            totalBytes: 2048,
          ),
        ],
      );
      var installedVersion = '1.8.0';
      final controller = AppUpdateController(
        platform: platform,
        preferencesLoader: () async => preferences,
        versionLoader: () async => installedVersion,
        autoCheck: false,
        pollInterval: Duration.zero,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.startDownload(
        const AppUpdateInfo(
          versionName: '1.8.1',
          changes: [],
          apkFileName: 'Agent-1.8.1.apk',
        ),
      );
      await _waitUntil(
        () =>
            controller.state.download.status ==
            AppUpdateDownloadStatus.downloaded,
      );
      expect(await controller.installDownloadedUpdate(), isTrue);
      installedVersion = '1.8.1';

      await controller.refreshAfterResume();
      expect(platform.removedDownloadIds, ['42']);
      expect(preferences.pendingDownload, isNull);
      expect(controller.state.download.status, AppUpdateDownloadStatus.idle);
    },
  );
}

class _FakeUpdatePlatform implements AppUpdatePlatform {
  _FakeUpdatePlatform({List<AppUpdateDownloadSnapshot?>? snapshots})
    : _snapshots =
          snapshots ??
          const [
            AppUpdateDownloadSnapshot(
              status: AppUpdateDownloadStatus.downloading,
              downloadedBytes: 512,
              totalBytes: 2048,
            ),
            AppUpdateDownloadSnapshot(
              status: AppUpdateDownloadStatus.downloaded,
              downloadedBytes: 2048,
              totalBytes: 2048,
            ),
          ];

  final List<AppUpdateDownloadSnapshot?> _snapshots;
  String? enqueuedFileName;
  var _queries = 0;
  int installRequests = 0;
  final List<String> removedDownloadIds = <String>[];

  int get queryRequests => _queries;

  @override
  Future<String> enqueueDownload({
    required String url,
    required String fileName,
  }) async {
    enqueuedFileName = fileName;
    return '42';
  }

  @override
  Future<AppUpdateInstallOutcome> installDownload(String downloadId) async {
    installRequests += 1;
    return const AppUpdateInstallOutcome(AppUpdateDownloadStatus.installing);
  }

  @override
  Future<void> removeDownload(String downloadId) async {
    removedDownloadIds.add(downloadId);
  }

  @override
  Future<AppUpdateDownloadSnapshot?> queryDownload(String downloadId) async {
    final index = _queries < _snapshots.length
        ? _queries
        : _snapshots.length - 1;
    _queries += 1;
    return index < 0 ? null : _snapshots[index];
  }
}

class _BlockingEnqueueUpdatePlatform extends _FakeUpdatePlatform {
  final Completer<void> enqueueStarted = Completer<void>();
  final Completer<String> enqueueRelease = Completer<String>();
  var enqueueRequests = 0;

  @override
  Future<String> enqueueDownload({
    required String url,
    required String fileName,
  }) async {
    enqueueRequests += 1;
    if (!enqueueStarted.isCompleted) enqueueStarted.complete();
    return enqueueRelease.future;
  }
}

class _BlockingInstallUpdatePlatform extends _FakeUpdatePlatform {
  final Completer<void> installStarted = Completer<void>();
  final Completer<AppUpdateInstallOutcome> installRelease =
      Completer<AppUpdateInstallOutcome>();

  _BlockingInstallUpdatePlatform()
    : super(
        snapshots: const [
          AppUpdateDownloadSnapshot(
            status: AppUpdateDownloadStatus.downloaded,
            downloadedBytes: 2048,
            totalBytes: 2048,
          ),
        ],
      );

  @override
  Future<AppUpdateInstallOutcome> installDownload(String downloadId) async {
    installRequests += 1;
    if (!installStarted.isCompleted) installStarted.complete();
    return installRelease.future;
  }
}

class _DestroyedActivityUpdatePlatform extends _FakeUpdatePlatform {
  _DestroyedActivityUpdatePlatform()
    : super(
        snapshots: const [
          AppUpdateDownloadSnapshot(
            status: AppUpdateDownloadStatus.downloaded,
            downloadedBytes: 2048,
            totalBytes: 2048,
          ),
        ],
      );

  var _destroyedQueryRequests = 0;

  @override
  Future<AppUpdateInstallOutcome> installDownload(String downloadId) async {
    installRequests += 1;
    throw PlatformException(
      code: 'app_update_activity_destroyed',
      message: 'Activity 已销毁',
    );
  }

  @override
  Future<AppUpdateDownloadSnapshot?> queryDownload(String downloadId) async {
    if (_destroyedQueryRequests++ == 0) {
      return super.queryDownload(downloadId);
    }
    throw PlatformException(
      code: 'app_update_activity_destroyed',
      message: 'Activity 已销毁',
    );
  }
}

Future<void> _waitUntil(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(Duration.zero);
  }
  throw TimeoutException('condition was not reached');
}
