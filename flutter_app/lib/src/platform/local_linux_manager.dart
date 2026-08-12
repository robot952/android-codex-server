import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../agent/remote_bootstrap.dart';
import '../domain/models.dart';

const localLinuxProfileId = 'agent-local-linux';

bool isLocalLinuxProfile(ServerProfile profile) =>
    profile.id == localLinuxProfileId;

enum LocalLinuxPhase {
  checking,
  unavailable,
  notInstalled,
  installing,
  stopped,
  starting,
  running,
  failed,
}

class LocalLinuxInstance {
  const LocalLinuxInstance({
    required this.port,
    required this.password,
    required this.architecture,
    required this.rootfsVersion,
  });

  factory LocalLinuxInstance.fromWire(Map<Object?, Object?> wire) {
    final port = wire['port'];
    final password = wire['password']?.toString().trim() ?? '';
    if (port is! int || port < 1 || port > 65535 || password.isEmpty) {
      throw StateError('本机 Linux 返回了无效的 SSH 配置');
    }
    return LocalLinuxInstance(
      port: port,
      password: password,
      architecture: wire['architecture']?.toString() ?? '',
      rootfsVersion: wire['rootfsVersion']?.toString() ?? '',
    );
  }

  final int port;
  final String password;
  final String architecture;
  final String rootfsVersion;
}

class LocalLinuxState {
  const LocalLinuxState({
    this.phase = LocalLinuxPhase.checking,
    this.supported = false,
    this.installed = false,
    this.running = false,
    this.progress = 0,
    this.message = '正在检查本机 Linux',
    this.downloadedBytes = 0,
    this.totalBytes,
    this.errorMessage,
    this.instance,
  });

  final LocalLinuxPhase phase;
  final bool supported;
  final bool installed;
  final bool running;
  final int progress;
  final String message;
  final int downloadedBytes;
  final int? totalBytes;
  final String? errorMessage;
  final LocalLinuxInstance? instance;

  LocalLinuxState copyWith({
    LocalLinuxPhase? phase,
    bool? supported,
    bool? installed,
    bool? running,
    int? progress,
    String? message,
    int? downloadedBytes,
    int? totalBytes,
    bool clearTotalBytes = false,
    String? errorMessage,
    bool clearError = false,
    LocalLinuxInstance? instance,
    bool clearInstance = false,
  }) => LocalLinuxState(
    phase: phase ?? this.phase,
    supported: supported ?? this.supported,
    installed: installed ?? this.installed,
    running: running ?? this.running,
    progress: progress ?? this.progress,
    message: message ?? this.message,
    downloadedBytes: downloadedBytes ?? this.downloadedBytes,
    totalBytes: clearTotalBytes ? null : totalBytes ?? this.totalBytes,
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    instance: clearInstance ? null : instance ?? this.instance,
  );
}

abstract interface class LocalLinuxPlatform {
  void setProgressHandler(
    void Function(Map<Object?, Object?> progress)? handler,
  );

  Future<Map<Object?, Object?>> status();

  Future<LocalLinuxInstance> installAndStart();

  Future<void> stop();

  Future<void> uninstall();
}

class MethodChannelLocalLinuxPlatform implements LocalLinuxPlatform {
  MethodChannelLocalLinuxPlatform({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'top.asdb.agent/local_linux';
  final MethodChannel _channel;

  @override
  void setProgressHandler(
    void Function(Map<Object?, Object?> progress)? handler,
  ) {
    _channel.setMethodCallHandler(
      handler == null
          ? null
          : (call) async {
              if (call.method == 'progress' && call.arguments is Map) {
                handler(Map<Object?, Object?>.from(call.arguments as Map));
              }
              return null;
            },
    );
  }

  @override
  Future<Map<Object?, Object?>> status() async {
    final raw = await _channel.invokeMethod<Object?>('status');
    return raw is Map
        ? Map<Object?, Object?>.from(raw)
        : const <Object?, Object?>{};
  }

  @override
  Future<LocalLinuxInstance> installAndStart() async {
    final raw = await _channel.invokeMethod<Object?>('installAndStart');
    if (raw is! Map) throw StateError('本机 Linux 未返回 SSH 配置');
    return LocalLinuxInstance.fromWire(Map<Object?, Object?>.from(raw));
  }

  @override
  Future<void> stop() => _channel.invokeMethod<void>('stop');

  @override
  Future<void> uninstall() => _channel.invokeMethod<void>('uninstall');
}

abstract interface class LocalLinuxRuntime {
  Future<LocalLinuxInstance> ensureStarted();

  Future<void> stop();

  Future<void> uninstall();
}

class UnsupportedLocalLinuxRuntime implements LocalLinuxRuntime {
  const UnsupportedLocalLinuxRuntime();

  @override
  Future<LocalLinuxInstance> ensureStarted() =>
      Future<LocalLinuxInstance>.error(UnsupportedError('当前平台不支持本机 Linux'));

  @override
  Future<void> stop() async {}

  @override
  Future<void> uninstall() async {}
}

class LocalLinuxController extends StateNotifier<LocalLinuxState>
    implements LocalLinuxRuntime {
  LocalLinuxController({LocalLinuxPlatform? platform})
    : _platform = platform ?? MethodChannelLocalLinuxPlatform(),
      super(const LocalLinuxState()) {
    _platform.setProgressHandler(_applyProgress);
    unawaited(refresh());
  }

  final LocalLinuxPlatform _platform;
  Future<LocalLinuxInstance>? _startRequest;

  Future<void> refresh() async {
    try {
      final wire = await _platform.status();
      final supported = wire['supported'] == true;
      final installed = wire['installed'] == true;
      final running = wire['running'] == true;
      final instance = running ? LocalLinuxInstance.fromWire(wire) : null;
      state = state.copyWith(
        phase: !supported
            ? LocalLinuxPhase.unavailable
            : running
            ? LocalLinuxPhase.running
            : installed
            ? LocalLinuxPhase.stopped
            : LocalLinuxPhase.notInstalled,
        supported: supported,
        installed: installed,
        running: running,
        progress: running ? 100 : 0,
        message:
            wire['message']?.toString() ??
            (!supported
                ? '当前设备不支持本机 Linux'
                : installed
                ? '本机 Linux 已安装'
                : '需要首次安装'),
        instance: instance,
        clearInstance: !running,
        clearError: true,
      );
    } on MissingPluginException {
      state = const LocalLinuxState(
        phase: LocalLinuxPhase.unavailable,
        message: '当前平台不支持本机 Linux',
      );
    } on PlatformException catch (error) {
      state = LocalLinuxState(
        phase: LocalLinuxPhase.failed,
        message: '无法检查本机 Linux',
        errorMessage: error.message,
      );
    }
  }

  @override
  Future<LocalLinuxInstance> ensureStarted() {
    final pending = _startRequest;
    if (pending != null) return pending;
    late final Future<LocalLinuxInstance> request;
    request = _start().whenComplete(() {
      if (identical(_startRequest, request)) _startRequest = null;
    });
    _startRequest = request;
    return request;
  }

  Future<LocalLinuxInstance> _start() async {
    state = state.copyWith(
      phase: state.installed
          ? LocalLinuxPhase.starting
          : LocalLinuxPhase.installing,
      supported: true,
      running: false,
      message: state.installed ? '正在启动本机 Linux' : '正在准备本机 Linux',
      clearError: true,
    );
    try {
      final instance = await _platform.installAndStart();
      state = state.copyWith(
        phase: LocalLinuxPhase.running,
        supported: true,
        installed: true,
        running: true,
        progress: 100,
        message: '本机 Linux 正在运行',
        instance: instance,
        clearError: true,
      );
      return instance;
    } catch (error) {
      final message = error is PlatformException
          ? error.message ?? '本机 Linux 启动失败'
          : error.toString();
      state = state.copyWith(
        phase: LocalLinuxPhase.failed,
        running: false,
        message: '本机 Linux 启动失败',
        errorMessage: message,
        clearInstance: true,
      );
      throw StateError(message);
    }
  }

  @override
  Future<void> stop() async {
    await _platform.stop();
    state = state.copyWith(
      phase: state.installed
          ? LocalLinuxPhase.stopped
          : LocalLinuxPhase.notInstalled,
      running: false,
      progress: 0,
      message: state.installed ? '本机 Linux 已停止' : '需要首次安装',
      clearInstance: true,
      clearError: true,
    );
  }

  @override
  Future<void> uninstall() async {
    await _platform.uninstall();
    state = state.copyWith(
      phase: LocalLinuxPhase.notInstalled,
      installed: false,
      running: false,
      progress: 0,
      message: '需要首次安装',
      downloadedBytes: 0,
      clearTotalBytes: true,
      clearInstance: true,
      clearError: true,
    );
  }

  void _applyProgress(Map<Object?, Object?> wire) {
    final phase = switch (wire['phase']?.toString()) {
      'starting' => LocalLinuxPhase.starting,
      'running' => LocalLinuxPhase.running,
      _ => LocalLinuxPhase.installing,
    };
    state = state.copyWith(
      phase: phase,
      supported: true,
      installed: wire['installed'] == true || state.installed,
      running: phase == LocalLinuxPhase.running,
      progress: _boundedInt(wire['percent'], maximum: 100),
      message: wire['message']?.toString() ?? state.message,
      downloadedBytes: _boundedInt(wire['downloadedBytes']),
      totalBytes: _nullableBoundedInt(wire['totalBytes']),
      clearError: true,
    );
  }

  @override
  void dispose() {
    _platform.setProgressHandler(null);
    super.dispose();
  }
}

final localLinuxControllerProvider =
    StateNotifierProvider<LocalLinuxController, LocalLinuxState>((ref) {
      return LocalLinuxController();
    });

ServerProfile localLinuxProfile(
  LocalLinuxInstance instance, {
  ServerProfile? existing,
}) => ServerProfile(
  id: localLinuxProfileId,
  name: '本机 Linux',
  host: '127.0.0.1',
  port: instance.port,
  username: 'root',
  authMode: AuthMode.password,
  password: instance.password,
  hostFingerprint:
      existing?.host == '127.0.0.1' && existing?.port == instance.port
      ? existing!.hostFingerprint
      : '',
  workspace: '/root/workspace',
  approvalMode: ApprovalMode.fullAccess,
  remoteCommand: managedCodexRemoteCommand,
  workspacePromptShown: true,
  activeAgent: AgentKind.codex,
  agentModelSettings:
      existing?.agentModelSettings ?? const <AgentKind, AgentModelSettings>{},
);

int _boundedInt(Object? value, {int maximum = 1 << 53}) =>
    value is int ? value.clamp(0, maximum) : 0;

int? _nullableBoundedInt(Object? value) =>
    value is int && value > 0 ? value.clamp(1, 1 << 53) : null;
