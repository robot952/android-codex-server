import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/install_progress_format.dart';
import 'diagnostic_logger.dart';

const appUpdateRepositoryUrl =
    'https://gitee.com/YanGanYuan/android-codex-server';
const appUpdateReleasesUrl =
    'https://gitee.com/api/v5/repos/YanGanYuan/android-codex-server/releases?page=1&per_page=30&direction=desc';

const _defaultVersion = '1.8.1';
const _maxReleaseResponseBytes = 256 * 1024;
const _maxTagNameChars = 64;
const _maxAssetNameChars = 128;
const _maxReleaseBodyChars = 16 * 1024;
const _maxChangeMessageChars = 240;
const _maxReleaseNotes = 12;
const _defaultApkPrefix = 'CodexRemote';
const _agentApkPrefix = 'Agent';

final _semanticVersionPattern = RegExp(
  r'^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$',
);
final _releaseNotePattern = RegExp(
  r'^\s*[-*]\s+`?([0-9a-fA-F]{7,64})`?\s+(.+?)\s*$',
  multiLine: true,
);

enum AppUpdateDownloadStatus {
  idle,
  downloading,
  downloaded,
  awaitingInstallPermission,
  installing,
  failed,
}

class AppUpdateReleaseNote {
  const AppUpdateReleaseNote({
    required this.versionName,
    required this.gitCommit,
    required this.message,
  });

  final String versionName;
  final String gitCommit;
  final String message;
}

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.versionName,
    required this.changes,
    this.apkFileName,
  });

  final String versionName;
  final List<AppUpdateReleaseNote> changes;
  final String? apkFileName;

  String get downloadFileName =>
      apkFileName ?? '$_defaultApkPrefix-$versionName.apk';
}

class PendingAppUpdateDownload {
  const PendingAppUpdateDownload({
    required this.versionName,
    required this.downloadId,
    required this.apkFileName,
  });

  final String versionName;
  final String downloadId;
  final String apkFileName;
}

class AppUpdateDownloadState {
  const AppUpdateDownloadState({
    this.versionName,
    this.downloadId,
    this.downloadedBytes = 0,
    this.totalBytes,
    this.bytesPerSecond,
    this.elapsedSeconds,
    this.status = AppUpdateDownloadStatus.idle,
    this.errorMessage,
  });

  final String? versionName;
  final String? downloadId;
  final int downloadedBytes;
  final int? totalBytes;
  final int? bytesPerSecond;
  final int? elapsedSeconds;
  final AppUpdateDownloadStatus status;
  final String? errorMessage;
}

const _unset = Object();

class AppUpdateState {
  const AppUpdateState({
    this.checking = false,
    this.installedVersion = _defaultVersion,
    this.availableUpdate,
    this.shouldPromptUpdate = false,
    this.download = const AppUpdateDownloadState(),
    this.checkError,
  });

  final bool checking;
  final String installedVersion;
  final AppUpdateInfo? availableUpdate;
  final bool shouldPromptUpdate;
  final AppUpdateDownloadState download;
  final String? checkError;

  AppUpdateState copyWith({
    bool? checking,
    String? installedVersion,
    Object? availableUpdate = _unset,
    bool? shouldPromptUpdate,
    AppUpdateDownloadState? download,
    Object? checkError = _unset,
  }) {
    return AppUpdateState(
      checking: checking ?? this.checking,
      installedVersion: installedVersion ?? this.installedVersion,
      availableUpdate: identical(availableUpdate, _unset)
          ? this.availableUpdate
          : availableUpdate as AppUpdateInfo?,
      shouldPromptUpdate: shouldPromptUpdate ?? this.shouldPromptUpdate,
      download: download ?? this.download,
      checkError: identical(checkError, _unset)
          ? this.checkError
          : checkError as String?,
    );
  }
}

abstract interface class AppUpdatePreferences {
  String? get ignoredVersionName;

  PendingAppUpdateDownload? get pendingDownload;

  Future<void> setIgnoredVersionName(String value);

  Future<void> setPendingDownload(PendingAppUpdateDownload value);

  Future<void> clearPendingDownload();
}

class SharedPreferencesAppUpdatePreferences implements AppUpdatePreferences {
  SharedPreferencesAppUpdatePreferences(this._preferences);

  final SharedPreferences _preferences;

  @override
  String? get ignoredVersionName =>
      _preferences.getString(_ignoredVersionPreferenceKey);

  @override
  PendingAppUpdateDownload? get pendingDownload {
    final encoded = _preferences.getString(_pendingDownloadPreferenceKey);
    if (encoded == null) return null;
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map) return null;
      final versionName = decoded['versionName']?.toString().trim();
      final downloadId = decoded['downloadId']?.toString().trim();
      final apkFileName = decoded['apkFileName']?.toString().trim();
      final parsedVersion = versionName == null
          ? null
          : _parseSemanticVersion(versionName);
      if (versionName == null ||
          parsedVersion == null ||
          parsedVersion.preRelease != null ||
          downloadId == null ||
          !RegExp(r'^\d{1,20}$').hasMatch(downloadId) ||
          apkFileName == null ||
          !_isExpectedApkFileName(apkFileName, versionName)) {
        return null;
      }
      return PendingAppUpdateDownload(
        versionName: versionName,
        downloadId: downloadId,
        apkFileName: apkFileName,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> setIgnoredVersionName(String value) async {
    await _preferences.setString(_ignoredVersionPreferenceKey, value);
  }

  @override
  Future<void> setPendingDownload(PendingAppUpdateDownload value) async {
    final saved = await _preferences.setString(
      _pendingDownloadPreferenceKey,
      jsonEncode({
        'versionName': value.versionName,
        'downloadId': value.downloadId,
        'apkFileName': value.apkFileName,
      }),
    );
    if (!saved) throw StateError('无法保存更新下载任务');
  }

  @override
  Future<void> clearPendingDownload() async {
    await _preferences.remove(_pendingDownloadPreferenceKey);
  }
}

class MemoryAppUpdatePreferences implements AppUpdatePreferences {
  String? _ignoredVersionName;
  PendingAppUpdateDownload? _pendingDownload;

  @override
  String? get ignoredVersionName => _ignoredVersionName;

  @override
  PendingAppUpdateDownload? get pendingDownload => _pendingDownload;

  @override
  Future<void> setIgnoredVersionName(String value) async {
    _ignoredVersionName = value;
  }

  @override
  Future<void> setPendingDownload(PendingAppUpdateDownload value) async {
    _pendingDownload = value;
  }

  @override
  Future<void> clearPendingDownload() async {
    _pendingDownload = null;
  }
}

class AppUpdateDownloadSnapshot {
  const AppUpdateDownloadSnapshot({
    required this.status,
    this.downloadedBytes = 0,
    this.totalBytes,
    this.errorMessage,
  });

  final AppUpdateDownloadStatus status;
  final int downloadedBytes;
  final int? totalBytes;
  final String? errorMessage;
}

class AppUpdateInstallOutcome {
  const AppUpdateInstallOutcome(this.status, {this.errorMessage});

  final AppUpdateDownloadStatus status;
  final String? errorMessage;
}

abstract interface class AppUpdatePlatform {
  Future<String> enqueueDownload({
    required String url,
    required String fileName,
  });

  Future<AppUpdateDownloadSnapshot?> queryDownload(String downloadId);

  Future<AppUpdateInstallOutcome> installDownload(String downloadId);

  /// Removes a completed or failed system download and its local APK.
  Future<void> removeDownload(String downloadId);
}

class MethodChannelAppUpdatePlatform implements AppUpdatePlatform {
  const MethodChannelAppUpdatePlatform({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'top.asdb.agent/app_update';
  final MethodChannel _channel;

  @override
  Future<String> enqueueDownload({
    required String url,
    required String fileName,
  }) async {
    final value = await _channel.invokeMethod<Object?>('enqueueDownload', {
      'url': url,
      'fileName': fileName,
    });
    final id = value?.toString().trim();
    if (id == null || id.isEmpty) throw StateError('系统下载服务未返回任务编号');
    return id;
  }

  @override
  Future<AppUpdateDownloadSnapshot?> queryDownload(String downloadId) async {
    final raw = await _channel.invokeMethod<Object?>('queryDownload', {
      'downloadId': downloadId,
    });
    if (raw is! Map) return null;
    final map = Map<Object?, Object?>.from(raw);
    return AppUpdateDownloadSnapshot(
      status: _statusFromWire(map['status']?.toString()),
      downloadedBytes: _wireInt(map['downloadedBytes']),
      totalBytes: _wireNullableInt(map['totalBytes']),
      errorMessage: map['errorMessage']?.toString(),
    );
  }

  @override
  Future<AppUpdateInstallOutcome> installDownload(String downloadId) async {
    final raw = await _channel.invokeMethod<Object?>('installDownload', {
      'downloadId': downloadId,
    });
    if (raw is! Map) {
      return const AppUpdateInstallOutcome(AppUpdateDownloadStatus.installing);
    }
    final map = Map<Object?, Object?>.from(raw);
    return AppUpdateInstallOutcome(
      _statusFromWire(map['status']?.toString()),
      errorMessage: map['errorMessage']?.toString(),
    );
  }

  @override
  Future<void> removeDownload(String downloadId) async {
    await _channel.invokeMethod<Object?>('removeDownload', {
      'downloadId': downloadId,
    });
  }
}

final appUpdateProvider =
    StateNotifierProvider<AppUpdateController, AppUpdateState>((ref) {
      final controller = AppUpdateController();
      unawaited(controller.initialize());
      return controller;
    });

class AppUpdateController extends StateNotifier<AppUpdateState> {
  AppUpdateController({
    http.Client? client,
    AppUpdatePlatform? platform,
    Future<AppUpdatePreferences> Function()? preferencesLoader,
    Future<String> Function()? versionLoader,
    this.autoCheck = true,
    bool Function()? supportsAutoCheck,
    this.pollInterval = const Duration(seconds: 1),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _platform = platform ?? const MethodChannelAppUpdatePlatform(),
       _preferencesLoader = preferencesLoader ?? _loadPreferences,
       _versionLoader = versionLoader ?? _loadVersion,
       _supportsAutoCheck = supportsAutoCheck ?? (() => io.Platform.isAndroid),
       super(const AppUpdateState());

  final http.Client _client;
  final bool _ownsClient;
  final AppUpdatePlatform _platform;
  final Future<AppUpdatePreferences> Function() _preferencesLoader;
  final Future<String> Function() _versionLoader;
  final bool autoCheck;
  final bool Function() _supportsAutoCheck;
  final Duration pollInterval;
  Future<void>? _initialization;
  Future<void>? _check;
  Future<bool>? _downloadOperation;
  String? _downloadOperationVersion;
  Future<bool>? _installOperation;
  String? _installOperationId;
  String? _pollingDownloadId;
  final Set<String> _monitoringDownloadIds = <String>{};
  final Map<String, DateTime> _downloadStartedAt = <String, DateTime>{};

  Future<void> initialize() {
    final existing = _initialization;
    if (existing != null) return existing;
    final initialization = _initialize();
    _initialization = initialization;
    return initialization;
  }

  Future<void> _initialize() async {
    try {
      final preferences = await _preferencesLoader();
      _preferences = preferences;
    } catch (_) {
      _preferences = MemoryAppUpdatePreferences();
    }
    var installedVersion = state.installedVersion;
    try {
      final version = (await _versionLoader()).trim();
      if (version.isNotEmpty && mounted) {
        installedVersion = version;
        state = state.copyWith(installedVersion: version);
      }
    } catch (_) {
      // Keep the build-time fallback when package_info is unavailable in a host test.
    }
    await _restorePendingDownload(installedVersion);
    if (autoCheck && _supportsAutoCheck()) {
      unawaited(_checkForUpdates());
    }
  }

  Future<void> _restorePendingDownload(String installedVersion) async {
    final pending = _preferences.pendingDownload;
    if (pending == null) return;
    if (compareSemanticVersions(pending.versionName, installedVersion) <= 0) {
      // A process restart after an upgrade leaves the old DownloadManager row
      // and APK behind. Remove both the row and its file before forgetting the
      // recovery record.
      await _discardDownload(pending.downloadId);
      return;
    }
    if (!mounted) return;
    final update = AppUpdateInfo(
      versionName: pending.versionName,
      changes: const [],
      apkFileName: pending.apkFileName,
    );
    state = state.copyWith(
      availableUpdate: update,
      shouldPromptUpdate: shouldPromptUpdate(
        update,
        _preferences.ignoredVersionName,
      ),
      download: AppUpdateDownloadState(
        versionName: pending.versionName,
        downloadId: pending.downloadId,
        status: AppUpdateDownloadStatus.downloading,
      ),
    );
    _pollingDownloadId = pending.downloadId;
    _downloadStartedAt.putIfAbsent(pending.downloadId, DateTime.now);
    unawaited(_monitorDownload(pending.downloadId, pending.versionName));
    DiagnosticLogger.instance.info(
      'Update',
      'download_restored version=${pending.versionName}',
    );
  }

  AppUpdatePreferences _preferences = MemoryAppUpdatePreferences();

  Future<void> checkForUpdates() async {
    await initialize();
    await _checkForUpdates();
  }

  Future<void> _checkForUpdates() {
    final existing = _check;
    if (existing != null) return existing;
    final operation = _performCheck();
    _check = operation;
    return operation.whenComplete(() {
      if (identical(_check, operation)) _check = null;
    });
  }

  Future<void> _performCheck() async {
    if (mounted) state = state.copyWith(checking: true, checkError: null);
    try {
      final response = await _client
          .get(
            Uri.parse(appUpdateReleasesUrl),
            headers: const {'Accept': 'application/json'},
          )
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) {
        throw StateError('更新服务器返回 HTTP ${response.statusCode}');
      }
      if (response.bodyBytes.length > _maxReleaseResponseBytes) {
        throw StateError('更新信息过大');
      }
      final latest = parseGiteeReleases(utf8.decode(response.bodyBytes));
      final fetchedAvailable = availableUpdateFor(
        latest,
        state.installedVersion,
      );
      final restoredAvailable =
          state.download.downloadId != null &&
              state.availableUpdate?.versionName ==
                  state.download.versionName &&
              compareSemanticVersions(
                    state.download.versionName ?? '',
                    state.installedVersion,
                  ) >
                  0
          ? state.availableUpdate
          : null;
      final available = fetchedAvailable ?? restoredAvailable;
      if (!mounted) return;
      state = state.copyWith(
        checking: false,
        availableUpdate: available,
        shouldPromptUpdate: shouldPromptUpdate(
          available,
          _preferences.ignoredVersionName,
        ),
        download: state.download.versionName == available?.versionName
            ? state.download
            : const AppUpdateDownloadState(),
        checkError: null,
      );
      if (available != null) {
        DiagnosticLogger.instance.info(
          'Update',
          'available version=${available.versionName}',
        );
      }
    } catch (error, stack) {
      if (mounted) {
        state = state.copyWith(checking: false, checkError: _shortError(error));
      }
      DiagnosticLogger.instance.warn(
        'Update',
        'check_failed reason=${_shortError(error)}',
        error,
        stack,
      );
    }
  }

  Future<void> ignoreVersion(String versionName) async {
    if (versionName.trim().isEmpty) return;
    await _preferences.setIgnoredVersionName(versionName);
    if (!mounted) return;
    if (state.availableUpdate?.versionName == versionName) {
      state = state.copyWith(shouldPromptUpdate: false);
    }
    DiagnosticLogger.instance.info('Update', 'ignored version=$versionName');
  }

  Future<bool> startDownload(AppUpdateInfo update) async {
    await initialize();
    final current = state.download;
    if (current.status == AppUpdateDownloadStatus.downloading &&
        current.versionName == update.versionName) {
      return true;
    }
    if (current.status == AppUpdateDownloadStatus.downloading) return false;
    final existing = _downloadOperation;
    if (existing != null) {
      // A repeated tap for the same release observes the original request;
      // never enqueue a second DownloadManager task. A different release is
      // rejected while the first request is still being submitted.
      return _downloadOperationVersion == update.versionName ? existing : false;
    }
    final operation = _performStartDownload(update);
    late final Future<bool> guarded;
    guarded = operation.whenComplete(() {
      if (identical(_downloadOperation, guarded)) {
        _downloadOperation = null;
        _downloadOperationVersion = null;
      }
    });
    _downloadOperation = guarded;
    _downloadOperationVersion = update.versionName;
    return guarded;
  }

  Future<bool> _performStartDownload(AppUpdateInfo update) async {
    try {
      final id = await _platform.enqueueDownload(
        url: appUpdateDownloadUrl(update),
        fileName: update.downloadFileName,
      );
      if (!mounted) return false;
      await _savePendingDownload(
        PendingAppUpdateDownload(
          versionName: update.versionName,
          downloadId: id,
          apkFileName: update.downloadFileName,
        ),
      );
      if (!mounted) return false;
      state = state.copyWith(
        download: AppUpdateDownloadState(
          versionName: update.versionName,
          downloadId: id,
          status: AppUpdateDownloadStatus.downloading,
        ),
      );
      _pollingDownloadId = id;
      _downloadStartedAt[id] = DateTime.now();
      unawaited(_monitorDownload(id, update.versionName));
      DiagnosticLogger.instance.info(
        'Update',
        'download_started version=${update.versionName}',
      );
      return true;
    } catch (error, stack) {
      if (mounted) {
        state = state.copyWith(
          download: AppUpdateDownloadState(
            versionName: update.versionName,
            status: AppUpdateDownloadStatus.failed,
            errorMessage: _shortError(error),
          ),
        );
      }
      DiagnosticLogger.instance.warn(
        'Update',
        'download_start_failed reason=${_shortError(error)}',
        error,
        stack,
      );
      return false;
    }
  }

  Future<void> _monitorDownload(String id, String versionName) async {
    if (!_monitoringDownloadIds.add(id)) return;
    try {
      while (mounted && _pollingDownloadId == id) {
        try {
          final snapshot = await _platform.queryDownload(id);
          if (snapshot == null) {
            // Android may destroy the Activity while DownloadManager keeps
            // running. A null callback is therefore transient, not proof that
            // the task disappeared; preserve the preference for next resume.
            _deferDownloadQuery(id, 'query returned null');
            return;
          }
          if (!mounted || state.download.downloadId != id) return;
          final status = snapshot.status;
          final elapsedSeconds = _downloadElapsed(id);
          final bytesPerSecond = _downloadRate(
            snapshot.downloadedBytes,
            elapsedSeconds,
          );
          state = state.copyWith(
            download: AppUpdateDownloadState(
              versionName: versionName,
              downloadId: id,
              downloadedBytes: snapshot.downloadedBytes,
              totalBytes: snapshot.totalBytes,
              bytesPerSecond: bytesPerSecond,
              elapsedSeconds: elapsedSeconds,
              status: status,
              errorMessage: snapshot.errorMessage,
            ),
          );
          if (status == AppUpdateDownloadStatus.downloaded) {
            if (_pollingDownloadId == id) _pollingDownloadId = null;
            DiagnosticLogger.instance.info(
              'Update',
              'download_completed version=$versionName',
            );
            return;
          }
          if (status == AppUpdateDownloadStatus.failed) {
            if (_pollingDownloadId == id) _pollingDownloadId = null;
            await _discardDownload(id);
            DiagnosticLogger.instance.warn(
              'Update',
              'download_failed version=$versionName',
            );
            return;
          }
        } catch (error, stack) {
          if (_isTransientUpdateLifecycleError(error)) {
            _deferDownloadQuery(id, _shortError(error));
            DiagnosticLogger.instance.info(
              'Update',
              'download_poll_deferred reason=${_shortError(error)}',
            );
            return;
          }
          await _setDownloadFailure(id, versionName, _shortError(error));
          DiagnosticLogger.instance.warn(
            'Update',
            'download_poll_failed reason=${_shortError(error)}',
            error,
            stack,
          );
          return;
        }
        await Future<void>.delayed(pollInterval);
      }
    } finally {
      _monitoringDownloadIds.remove(id);
    }
  }

  Future<void> _setDownloadFailure(
    String id,
    String versionName,
    String message,
  ) async {
    if (!mounted || state.download.downloadId != id) return;
    if (_pollingDownloadId == id) _pollingDownloadId = null;
    state = state.copyWith(
      download: AppUpdateDownloadState(
        versionName: versionName,
        downloadId: id,
        downloadedBytes: state.download.downloadedBytes,
        totalBytes: state.download.totalBytes,
        bytesPerSecond: state.download.bytesPerSecond,
        elapsedSeconds: state.download.elapsedSeconds,
        status: AppUpdateDownloadStatus.failed,
        errorMessage: message,
      ),
    );
    await _discardDownload(id);
  }

  Future<void> refreshAfterResume() async {
    await initialize();
    final download = state.download;
    final id = download.downloadId;
    final versionName = download.versionName;
    if (id == null ||
        versionName == null ||
        download.status != AppUpdateDownloadStatus.downloading &&
            download.status != AppUpdateDownloadStatus.installing &&
            download.status !=
                AppUpdateDownloadStatus.awaitingInstallPermission) {
      return;
    }
    try {
      // PackageInfo is refreshed after Android finishes an APK install. If
      // this process survives the installer hand-off, clean the old task here
      // instead of waiting for a full process restart.
      final refreshedVersion = await _readInstalledVersion();
      if (refreshedVersion != null &&
          compareSemanticVersions(refreshedVersion, versionName) >= 0) {
        await _discardDownload(id);
        if (!mounted || state.download.downloadId != id) return;
        final available = state.availableUpdate;
        final sameUpdate = available?.versionName == versionName;
        state = state.copyWith(
          installedVersion: refreshedVersion,
          availableUpdate: sameUpdate ? null : available,
          shouldPromptUpdate: sameUpdate ? false : state.shouldPromptUpdate,
          download: const AppUpdateDownloadState(),
        );
        return;
      }
      final snapshot = await _platform.queryDownload(id);
      if (!mounted || state.download.downloadId != id) return;
      if (snapshot == null) {
        _deferDownloadQuery(id, 'query returned null after resume');
        return;
      }
      state = state.copyWith(
        download: AppUpdateDownloadState(
          versionName: versionName,
          downloadId: id,
          downloadedBytes: snapshot.downloadedBytes,
          totalBytes: snapshot.totalBytes,
          bytesPerSecond: _downloadRate(
            snapshot.downloadedBytes,
            _downloadElapsed(id),
          ),
          elapsedSeconds: _downloadElapsed(id),
          status: snapshot.status,
          errorMessage: snapshot.errorMessage,
        ),
      );
      if (snapshot.status == AppUpdateDownloadStatus.failed) {
        await _discardDownload(id);
      } else if (snapshot.status == AppUpdateDownloadStatus.downloading) {
        _pollingDownloadId = id;
        _downloadStartedAt.putIfAbsent(id, DateTime.now);
        unawaited(_monitorDownload(id, versionName));
      }
    } catch (error, stack) {
      if (_isTransientUpdateLifecycleError(error)) {
        _deferDownloadQuery(id, _shortError(error));
        DiagnosticLogger.instance.info(
          'Update',
          'download_resume_deferred reason=${_shortError(error)}',
        );
        return;
      }
      DiagnosticLogger.instance.warn(
        'Update',
        'download_resume_failed reason=${_shortError(error)}',
        error,
        stack,
      );
    }
  }

  Future<bool> installDownloadedUpdate() async {
    await initialize();
    final id = state.download.downloadId;
    if (id == null ||
        state.download.status != AppUpdateDownloadStatus.downloaded &&
            state.download.status !=
                AppUpdateDownloadStatus.awaitingInstallPermission &&
            state.download.status != AppUpdateDownloadStatus.installing) {
      return false;
    }
    final existing = _installOperation;
    if (existing != null) {
      // Repeated taps while the system installer request is being prepared
      // must share the same Future instead of opening multiple installers.
      return _installOperationId == id ? existing : false;
    }
    final operation = _performInstall(id);
    late final Future<bool> guarded;
    guarded = operation.whenComplete(() {
      if (identical(_installOperation, guarded)) {
        _installOperation = null;
        _installOperationId = null;
      }
    });
    _installOperation = guarded;
    _installOperationId = id;
    return guarded;
  }

  Future<bool> _performInstall(String id) async {
    try {
      final outcome = await _platform.installDownload(id);
      if (!mounted || state.download.downloadId != id) return false;
      state = state.copyWith(
        download: AppUpdateDownloadState(
          versionName: state.download.versionName,
          downloadId: id,
          downloadedBytes: state.download.downloadedBytes,
          totalBytes: state.download.totalBytes,
          bytesPerSecond: state.download.bytesPerSecond,
          elapsedSeconds: state.download.elapsedSeconds,
          status: outcome.status,
          errorMessage: outcome.errorMessage,
        ),
      );
      return outcome.status != AppUpdateDownloadStatus.failed;
    } catch (error, stack) {
      if (_isTransientUpdateLifecycleError(error)) {
        if (mounted && state.download.downloadId == id) {
          state = state.copyWith(
            download: AppUpdateDownloadState(
              versionName: state.download.versionName,
              downloadId: id,
              downloadedBytes: state.download.downloadedBytes,
              totalBytes: state.download.totalBytes,
              bytesPerSecond: state.download.bytesPerSecond,
              elapsedSeconds: state.download.elapsedSeconds,
              status: AppUpdateDownloadStatus.installing,
            ),
          );
        }
        DiagnosticLogger.instance.info(
          'Update',
          'install_deferred reason=${_shortError(error)}',
        );
        return false;
      }
      if (mounted) {
        state = state.copyWith(
          download: AppUpdateDownloadState(
            versionName: state.download.versionName,
            downloadId: id,
            downloadedBytes: state.download.downloadedBytes,
            totalBytes: state.download.totalBytes,
            bytesPerSecond: state.download.bytesPerSecond,
            elapsedSeconds: state.download.elapsedSeconds,
            status: AppUpdateDownloadStatus.failed,
            errorMessage: _shortError(error),
          ),
        );
      }
      DiagnosticLogger.instance.warn(
        'Update',
        'install_failed reason=${_shortError(error)}',
        error,
        stack,
      );
      return false;
    }
  }

  @override
  void dispose() {
    _pollingDownloadId = null;
    _monitoringDownloadIds.clear();
    _downloadStartedAt.clear();
    if (_ownsClient) _client.close();
    super.dispose();
  }

  Future<void> _savePendingDownload(PendingAppUpdateDownload pending) async {
    try {
      await _preferences.setPendingDownload(pending);
    } catch (error, stack) {
      DiagnosticLogger.instance.warn(
        'Update',
        'download_persist_failed reason=${_shortError(error)}',
        error,
        stack,
      );
    }
  }

  Future<void> _clearPendingDownload(String downloadId) async {
    if (_preferences.pendingDownload?.downloadId != downloadId) return;
    try {
      await _preferences.clearPendingDownload();
    } catch (error, stack) {
      DiagnosticLogger.instance.warn(
        'Update',
        'download_clear_failed reason=${_shortError(error)}',
        error,
        stack,
      );
    }
  }

  Future<void> _discardDownload(String downloadId) async {
    try {
      await _platform.removeDownload(downloadId);
    } catch (error, stack) {
      // Cleanup is best effort. A missing row or a destroyed Activity must not
      // prevent the Dart recovery record from being cleared.
      DiagnosticLogger.instance.warn(
        'Update',
        'download_remove_failed reason=${_shortError(error)}',
        error,
        stack,
      );
    }
    await _clearPendingDownload(downloadId);
  }

  void _deferDownloadQuery(String id, String reason) {
    if (_pollingDownloadId == id) _pollingDownloadId = null;
    DiagnosticLogger.instance.info(
      'Update',
      'download_query_deferred id=$id reason=$reason',
    );
  }

  Future<String?> _readInstalledVersion() async {
    try {
      final version = (await _versionLoader()).trim();
      return version.isEmpty ? null : version;
    } catch (_) {
      return null;
    }
  }

  int _downloadElapsed(String id) {
    final startedAt = _downloadStartedAt.putIfAbsent(id, DateTime.now);
    return DateTime.now().difference(startedAt).inSeconds.clamp(0, 1 << 31);
  }

  int _downloadRate(int downloadedBytes, int elapsedSeconds) {
    if (downloadedBytes <= 0) return 0;
    return (downloadedBytes / (elapsedSeconds == 0 ? 1 : elapsedSeconds))
        .round();
  }
}

Future<AppUpdatePreferences> _loadPreferences() async {
  return SharedPreferencesAppUpdatePreferences(
    await SharedPreferences.getInstance(),
  );
}

Future<String> _loadVersion() async =>
    (await PackageInfo.fromPlatform()).version.trim();

String appUpdateDownloadUrl(AppUpdateInfo update) =>
    '$appUpdateRepositoryUrl/releases/download/v${update.versionName}/${update.downloadFileName}';

AppUpdateInfo? parseGiteeReleases(String value) {
  final decoded = jsonDecode(value);
  if (decoded is! List) throw const FormatException('更新清单格式无效');
  final releases = decoded
      .whereType<Map>()
      .map(_parseRelease)
      .whereType<AppUpdateInfo>()
      .toList(growable: false);
  if (releases.isEmpty) return null;
  releases.sort(
    (left, right) =>
        compareSemanticVersions(right.versionName, left.versionName),
  );
  return releases.first;
}

AppUpdateInfo? _parseRelease(Map release) {
  if (release['prerelease'] == true) return null;
  final rawTag = release['tag_name']?.toString().trim();
  if (rawTag == null ||
      !rawTag.startsWith('v') ||
      rawTag.length > _maxTagNameChars) {
    return null;
  }
  final versionName = rawTag.substring(1);
  final parsedVersion = _parseSemanticVersion(versionName);
  // Gitee's boolean flag is not authoritative: a manually-created Release
  // can omit it while still carrying a SemVer prerelease tag.
  if (parsedVersion == null || parsedVersion.preRelease != null) return null;
  final expectedNames = <String>{
    '$_defaultApkPrefix-$versionName.apk',
    '$_agentApkPrefix-$versionName.apk',
  };
  final assets = release['assets'];
  if (assets is! List) return null;
  final fileName = assets
      .whereType<Map>()
      .map((asset) => asset['name']?.toString().trim())
      .whereType<String>()
      .firstWhere(expectedNames.contains, orElse: () => '');
  if (fileName.isEmpty || fileName.length > _maxAssetNameChars) return null;
  final rawBody = release['body']?.toString().replaceAll('\u0000', ' ').trim();
  final body = rawBody == null || rawBody.length <= _maxReleaseBodyChars
      ? rawBody
      : rawBody.substring(0, _maxReleaseBodyChars);
  final changes = body == null
      ? const <AppUpdateReleaseNote>[]
      : _parseReleaseNotes(body, versionName);
  return AppUpdateInfo(
    versionName: versionName,
    changes: changes,
    apkFileName: fileName,
  );
}

bool _isExpectedApkFileName(String fileName, String versionName) =>
    fileName == '$_defaultApkPrefix-$versionName.apk' ||
    fileName == '$_agentApkPrefix-$versionName.apk';

List<AppUpdateReleaseNote> _parseReleaseNotes(String body, String versionName) {
  return _releaseNotePattern
      .allMatches(body)
      .map((match) {
        final message = match.group(2)?.replaceAll('\u0000', ' ').trim();
        if (message == null || message.isEmpty) return null;
        return AppUpdateReleaseNote(
          versionName: versionName,
          gitCommit: match.group(1)!.toLowerCase(),
          message: message.length > _maxChangeMessageChars
              ? message.substring(0, _maxChangeMessageChars)
              : message,
        );
      })
      .whereType<AppUpdateReleaseNote>()
      .take(_maxReleaseNotes)
      .toList(growable: false);
}

AppUpdateInfo? availableUpdateFor(
  AppUpdateInfo? latestRelease,
  String installedVersion,
) =>
    latestRelease != null &&
        _isStableVersionName(latestRelease.versionName) &&
        compareSemanticVersions(latestRelease.versionName, installedVersion) > 0
    ? latestRelease
    : null;

bool shouldPromptUpdate(AppUpdateInfo? update, String? ignoredVersion) =>
    update != null && update.versionName != ignoredVersion;

double? updateDownloadProgressFraction(int downloadedBytes, int? totalBytes) {
  if (totalBytes == null || totalBytes <= 0) return null;
  return (downloadedBytes.clamp(0, totalBytes) / totalBytes).toDouble();
}

String formatAppUpdateByteSize(int bytes) => formatInstallBytes(bytes);

int compareSemanticVersions(String left, String right) {
  final leftVersion = _parseSemanticVersion(left);
  final rightVersion = _parseSemanticVersion(right);
  if (leftVersion == null || rightVersion == null) return 0;
  final major = leftVersion.major.compareTo(rightVersion.major);
  if (major != 0) return major;
  final minor = leftVersion.minor.compareTo(rightVersion.minor);
  if (minor != 0) return minor;
  final patch = leftVersion.patch.compareTo(rightVersion.patch);
  if (patch != 0) return patch;
  return _comparePreRelease(leftVersion.preRelease, rightVersion.preRelease);
}

class _SemanticVersion {
  const _SemanticVersion(this.major, this.minor, this.patch, this.preRelease);

  final int major;
  final int minor;
  final int patch;
  final List<String>? preRelease;
}

_SemanticVersion? _parseSemanticVersion(String value) {
  final match = _semanticVersionPattern.firstMatch(value.trim());
  if (match == null) return null;
  final major = int.tryParse(match.group(1)!);
  final minor = int.tryParse(match.group(2)!);
  final patch = int.tryParse(match.group(3)!);
  if (major == null || minor == null || patch == null) return null;
  final rawPreRelease = match.group(4);
  return _SemanticVersion(major, minor, patch, rawPreRelease?.split('.'));
}

int _comparePreRelease(List<String>? left, List<String>? right) {
  if (left == null) return right == null ? 0 : 1;
  if (right == null) return -1;
  final length = left.length > right.length ? left.length : right.length;
  for (var index = 0; index < length; index++) {
    if (index >= left.length) return -1;
    if (index >= right.length) return 1;
    final leftIdentifier = left[index];
    final rightIdentifier = right[index];
    final leftNumeric = int.tryParse(leftIdentifier);
    final rightNumeric = int.tryParse(rightIdentifier);
    final comparison = leftNumeric != null && rightNumeric != null
        ? leftNumeric.compareTo(rightNumeric)
        : leftNumeric != null
        ? -1
        : rightNumeric != null
        ? 1
        : leftIdentifier.compareTo(rightIdentifier);
    if (comparison != 0) return comparison;
  }
  return 0;
}

AppUpdateDownloadStatus _statusFromWire(String? value) => switch (value) {
  'downloading' => AppUpdateDownloadStatus.downloading,
  'downloaded' => AppUpdateDownloadStatus.downloaded,
  'awaitingInstallPermission' =>
    AppUpdateDownloadStatus.awaitingInstallPermission,
  'installing' => AppUpdateDownloadStatus.installing,
  'failed' => AppUpdateDownloadStatus.failed,
  _ => AppUpdateDownloadStatus.idle,
};

int _wireInt(Object? value) => switch (value) {
  int number => number,
  num number => number.toInt(),
  String text => int.tryParse(text) ?? 0,
  _ => 0,
};

int? _wireNullableInt(Object? value) {
  final parsed = _wireInt(value);
  return value == null || parsed < 0 ? null : parsed;
}

String _shortError(Object error) {
  final message = error.toString().replaceAll('\n', ' ').trim();
  if (message.isEmpty) return '操作失败';
  return message.length <= 120 ? message : message.substring(0, 120);
}

bool _isTransientUpdateLifecycleError(Object error) {
  if (error is TimeoutException) return true;
  if (error is! PlatformException) return false;
  final code = error.code.toLowerCase();
  return code == 'app_update_activity_destroyed' ||
      code.contains('activity_destroyed') ||
      code.contains('cancelled');
}

bool _isStableVersionName(String value) =>
    _parseSemanticVersion(value)?.preRelease == null;

const _ignoredVersionPreferenceKey = 'ignored_version_name';
const _pendingDownloadPreferenceKey = 'pending_update_download';
