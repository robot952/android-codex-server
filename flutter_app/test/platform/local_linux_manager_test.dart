import 'dart:async';

import 'package:codex_remote/src/agent/remote_bootstrap.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/platform/local_linux_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('local Linux profile keeps the fixed loopback security boundary', () {
    const instance = LocalLinuxInstance(
      port: 41234,
      password: 'generated-password',
      architecture: 'arm64-v8a',
      rootfsVersion: 'debian-test',
    );

    final profile = localLinuxProfile(instance);

    expect(profile.id, localLinuxProfileId);
    expect(profile.host, '127.0.0.1');
    expect(profile.port, 41234);
    expect(profile.username, 'root');
    expect(profile.authMode, AuthMode.password);
    expect(profile.password, 'generated-password');
    expect(profile.workspace, '/root/workspace');
    expect(profile.approvalMode, ApprovalMode.fullAccess);
    expect(profile.remoteCommand, managedCodexRemoteCommand);
    expect(profile.workspacePromptShown, isTrue);
  });

  test('profile preserves identity-bound settings only for the same port', () {
    const instance = LocalLinuxInstance(
      port: 41234,
      password: 'new-password',
      architecture: 'arm64-v8a',
      rootfsVersion: 'debian-test',
    );
    final existing = localLinuxProfile(instance).copyWith(
      hostFingerprint: 'SHA256:local',
      agentModelSettings: const {
        AgentKind.codex: AgentModelSettings(preferredModel: 'codex-model'),
      },
    );

    expect(
      localLinuxProfile(instance, existing: existing).hostFingerprint,
      'SHA256:local',
    );
    expect(
      localLinuxProfile(
        const LocalLinuxInstance(
          port: 41235,
          password: 'new-password',
          architecture: 'arm64-v8a',
          rootfsVersion: 'debian-test',
        ),
        existing: existing,
      ).hostFingerprint,
      isEmpty,
    );
    expect(
      localLinuxProfile(instance, existing: existing).agentModelSettings,
      existing.agentModelSettings,
    );
  });

  test('controller maps native status and progress updates', () async {
    final platform = _FakeLocalLinuxPlatform(
      statusResult: {
        'supported': true,
        'installed': false,
        'running': false,
        'message': '首次使用需下载约 35 MB',
      },
    );
    final controller = LocalLinuxController(platform: platform);
    addTearDown(controller.dispose);
    await controller.refresh();

    expect(controller.state.phase, LocalLinuxPhase.notInstalled);
    platform.emitProgress({
      'phase': 'installing',
      'percent': 25,
      'message': '正在下载 Debian',
      'downloadedBytes': 1024,
      'totalBytes': 4096,
      'bytesPerSecond': 512,
      'elapsedSeconds': 2,
      'indeterminate': false,
    });
    expect(controller.state.phase, LocalLinuxPhase.installing);
    expect(controller.state.progress, 25);
    expect(controller.state.downloadedBytes, 1024);
    expect(controller.state.totalBytes, 4096);
    expect(controller.state.bytesPerSecond, 512);
    expect(controller.state.elapsedSeconds, 2);
    expect(controller.state.indeterminate, isFalse);

    platform.emitProgress({
      'phase': 'installing',
      'percent': 46,
      'message': '正在解压 Debian',
      'downloadedBytes': 8192,
      'bytesPerSecond': 2048,
      'elapsedSeconds': 4,
      'indeterminate': true,
    });
    expect(controller.state.totalBytes, isNull);
    expect(controller.state.indeterminate, isTrue);
  });

  test('ensureStarted coalesces concurrent native start requests', () async {
    final platform = _FakeLocalLinuxPlatform();
    final controller = LocalLinuxController(platform: platform);
    addTearDown(controller.dispose);
    final first = controller.ensureStarted();
    final second = controller.ensureStarted();

    expect(identical(first, second), isTrue);
    expect(platform.startCalls, 1);
    platform.startResult.complete(_instance);
    expect(await first, same(_instance));
    expect(controller.state.phase, LocalLinuxPhase.running);
    expect(controller.state.running, isTrue);
  });

  test('start failure leaves a retryable failed state', () async {
    final platform = _FakeLocalLinuxPlatform();
    final controller = LocalLinuxController(platform: platform);
    addTearDown(controller.dispose);
    final start = controller.ensureStarted();
    platform.startResult.completeError(StateError('download failed'));

    await expectLater(start, throwsA(isA<StateError>()));
    expect(controller.state.phase, LocalLinuxPhase.failed);
    expect(controller.state.running, isFalse);
    expect(controller.state.errorMessage, contains('download failed'));
  });

  test('stop and uninstall clear the running instance', () async {
    final platform = _FakeLocalLinuxPlatform();
    final controller = LocalLinuxController(platform: platform);
    addTearDown(controller.dispose);
    final start = controller.ensureStarted();
    platform.startResult.complete(_instance);
    await start;

    await controller.stop();
    expect(platform.stopCalls, 1);
    expect(controller.state.phase, LocalLinuxPhase.stopped);
    expect(controller.state.instance, isNull);

    await controller.uninstall();
    expect(platform.uninstallCalls, 1);
    expect(controller.state.phase, LocalLinuxPhase.notInstalled);
    expect(controller.state.installed, isFalse);
  });
}

const _instance = LocalLinuxInstance(
  port: 41234,
  password: 'generated-password',
  architecture: 'arm64-v8a',
  rootfsVersion: 'debian-test',
);

class _FakeLocalLinuxPlatform implements LocalLinuxPlatform {
  _FakeLocalLinuxPlatform({this.statusResult = const {}});

  final Map<Object?, Object?> statusResult;
  final Completer<LocalLinuxInstance> startResult =
      Completer<LocalLinuxInstance>();
  void Function(Map<Object?, Object?> progress)? progressHandler;
  int startCalls = 0;
  int stopCalls = 0;
  int uninstallCalls = 0;

  void emitProgress(Map<Object?, Object?> progress) =>
      progressHandler?.call(progress);

  @override
  Future<LocalLinuxInstance> installAndStart() {
    startCalls++;
    return startResult.future;
  }

  @override
  void setProgressHandler(
    void Function(Map<Object?, Object?> progress)? handler,
  ) {
    progressHandler = handler;
  }

  @override
  Future<Map<Object?, Object?>> status() async => statusResult;

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<void> uninstall() async {
    uninstallCalls++;
  }
}
