import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/app_controller.dart';
import '../domain/install_progress_format.dart';
import '../domain/models.dart';
import '../platform/app_update_manager.dart';
import '../platform/diagnostic_logger.dart';
import '../platform/local_linux_manager.dart';
import '../platform/windows_local_server_client.dart';
import '../ssh/ssh_server_client.dart';
import 'app_update_dialog.dart';
import 'diagnostic_log_sheet.dart';
import 'server_metrics_strip.dart';
import 'theme.dart';

const _promotionUrl = 'https://lowapi.button1.cn';
const _maxPrivateKeyBytes = 1024 * 1024;

class ServerScreen extends ConsumerStatefulWidget {
  const ServerScreen({super.key});

  @override
  ConsumerState<ServerScreen> createState() => _ServerScreenState();
}

class _ServerScreenState extends ConsumerState<ServerScreen> {
  ServerProfile? _draft;
  ServerProfile? _initialDraft;
  bool _editorVisible = false;
  bool _advanced = false;
  bool _passwordVisible = false;
  bool _updateDialogVisible = false;
  String? _deferredUpdateVersion;
  final DebugTapCounter _debugTapCounter = DebugTapCounter();
  String? _shownFingerprint;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appControllerProvider);
    final localLinux = ref.watch(localLinuxControllerProvider);
    ref.listen<AppUpdateState>(appUpdateProvider, _scheduleUpdatePrompt);
    final pendingFingerprintProfile = state.profiles.firstWhereOrNull(
      (profile) => profile.id == state.selectedProfileId,
    );
    _scheduleFingerprintDialog(
      state.pendingFingerprint,
      pendingFingerprintProfile?.hostFingerprint,
    );
    final blocking = _blockingConnection(state);

    return PopScope(
      canPop: blocking == null && !_editorVisible,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && blocking == null && _editorVisible) {
          _requestCloseEditor();
        }
      },
      child: Stack(
        children: [
          Scaffold(
            resizeToAvoidBottomInset: true,
            appBar: AppBar(
              toolbarHeight: 64,
              leading: _editorVisible
                  ? IconButton(
                      tooltip: '返回服务器列表',
                      onPressed: _requestCloseEditor,
                      icon: const Icon(Icons.arrow_back),
                    )
                  : null,
              automaticallyImplyLeading: false,
              title: _AppTitle(
                subtitle: _editorVisible
                    ? (_existingDraft(state) ? '服务器设置' : '添加服务器')
                    : '服务器列表',
                onTap: () => _handleLogoTap(state.debugModeEnabled),
              ),
              actions: [
                if (!_editorVisible) _PromotionAction(onOpen: _openPromotion),
                _AppVersion(onTap: _handleUpdateTap),
              ],
            ),
            body: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) {
                final enteringEditor = child.key == const ValueKey('editor');
                return FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: Offset(enteringEditor ? 0.08 : -0.08, 0),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                );
              },
              child: _editorVisible
                  ? _ServerEditor(
                      key: const ValueKey('editor'),
                      profile:
                          _draft ??
                          ref.read(appControllerProvider.notifier).newProfile(),
                      advanced: _advanced,
                      passwordVisible: _passwordVisible,
                      isExisting: _existingDraft(state),
                      onChanged: (value) => setState(() => _draft = value),
                      onToggleAdvanced: () =>
                          setState(() => _advanced = !_advanced),
                      onTogglePassword: () =>
                          setState(() => _passwordVisible = !_passwordVisible),
                      onPickKey: _pickPrivateKey,
                      onSave: _saveDraft,
                      onDelete: _existingDraft(state) ? _deleteDraft : null,
                      onUninstall:
                          _existingDraft(state) &&
                              state.connectionStates[_draft?.id]?.phase ==
                                  ConnectionPhase.connected
                          ? _uninstallDraft
                          : null,
                    )
                  : _ServerList(
                      key: const ValueKey('list'),
                      state: state,
                      onAdd: _newProfile,
                      localLinux: localLinux,
                      onOpenLocalLinux: _openLocalLinux,
                      onUninstallLocalLinux: _uninstallLocalLinux,
                      localWindows: Platform.isWindows
                          ? state.profiles.firstWhereOrNull(
                              isLocalWindowsProfile,
                            )
                          : null,
                      onOpenLocalWindows: _openLocalWindows,
                      onSettings: _editProfile,
                      onOpen: _openProfile,
                      onDisconnect: _confirmDisconnect,
                      onOpenDebugLogs: _openDebugLogs,
                      onShareDebugLogs: _shareDebugLogs,
                    ),
            ),
          ),
          if (blocking != null) _ConnectionOverlay(connection: blocking),
        ],
      ),
    );
  }

  bool _existingDraft(AppUiState state) =>
      _draft != null &&
      state.profiles.any((profile) => profile.id == _draft!.id);

  void _newProfile() {
    final profile = ref.read(appControllerProvider.notifier).newProfile();
    setState(() {
      _draft = profile;
      _initialDraft = profile;
      _editorVisible = true;
      _advanced = false;
      _passwordVisible = false;
    });
  }

  Future<void> _openLocalLinux() async {
    final localState = ref.read(localLinuxControllerProvider);
    final appState = ref.read(appControllerProvider);
    final localProfile = appState.profiles.firstWhereOrNull(
      isLocalLinuxProfile,
    );
    if (localProfile != null &&
        appState.connectionStates[localLinuxProfileId]?.phase ==
            ConnectionPhase.connected) {
      ref.read(appControllerProvider.notifier).selectProfile(localProfile.id);
      return;
    }
    if (!localState.supported &&
        localState.phase != LocalLinuxPhase.checking &&
        localState.phase != LocalLinuxPhase.failed) {
      _showMessage(localState.message);
      return;
    }
    if (!localState.installed) {
      final approved = await _confirm(
        title: '安装本机 Linux？',
        message:
            '将下载约 35 MB 的 Debian ARM64 环境，解压后约占用 173 MB。'
            '安装 SSH、Git 和 Codex 后占用会继续增加。'
            '环境只监听手机本机，不会开放到局域网。Codex 仍需要联网访问模型服务。',
        confirmLabel: '安装并启动',
      );
      if (!approved || !mounted) return;
    }
    try {
      await ref.read(appControllerProvider.notifier).connectLocalLinux();
    } catch (error) {
      if (mounted) _showMessage(_errorText(error));
    }
  }

  Future<void> _openLocalWindows() async {
    final controller = ref.read(appControllerProvider.notifier);
    final state = ref.read(appControllerProvider);
    final profile = state.profiles.firstWhereOrNull(isLocalWindowsProfile);
    if (profile == null) return;
    if (state.connectionStates[profile.id]?.phase ==
        ConnectionPhase.connected) {
      controller.selectProfile(profile.id);
    } else {
      await controller.requestConnect(profile);
    }
  }

  Future<void> _uninstallLocalLinux() async {
    final approved = await _confirm(
      title: '删除本机 Linux？',
      message: '将删除 Debian、已安装的 Codex、Linux 工作区和本机配置。这个操作不能撤销。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!approved || !mounted) return;
    try {
      await ref.read(appControllerProvider.notifier).uninstallLocalLinux();
      if (mounted) _showMessage('本机 Linux 已删除');
    } catch (error) {
      if (mounted) _showMessage(_errorText(error));
    }
  }

  void _editProfile(ServerProfile profile) {
    setState(() {
      _draft = profile;
      _initialDraft = profile;
      _editorVisible = true;
      _advanced = false;
      _passwordVisible = false;
    });
  }

  Future<void> _requestCloseEditor() async {
    if (_draft != _initialDraft) {
      final discard = await _confirm(
        title: '放弃未保存的修改？',
        message: '当前服务器设置尚未保存。',
        confirmLabel: '放弃',
        destructive: true,
      );
      if (!discard || !mounted) return;
    }
    _closeEditor();
  }

  void _closeEditor() {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _editorVisible = false;
      _draft = null;
      _initialDraft = null;
    });
  }

  Future<void> _saveDraft() async {
    final draft = _draft;
    if (draft == null) return;
    try {
      await ref.read(appControllerProvider.notifier).saveProfile(draft);
      if (mounted) _closeEditor();
    } catch (error) {
      _showMessage(_errorText(error));
    }
  }

  Future<void> _deleteDraft() async {
    final draft = _draft;
    if (draft == null) return;
    final approved = await _confirm(
      title: '删除服务器？',
      message: '将删除“${draft.name}”及其本地配置，不会修改远端服务器。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!approved || !mounted) return;
    await ref.read(appControllerProvider.notifier).deleteProfile(draft.id);
    if (mounted) _closeEditor();
  }

  Future<void> _uninstallDraft() async {
    final draft = _draft;
    if (draft == null) return;
    final approved = await _confirm(
      title: '卸载托管 Codex？',
      message:
          '只会删除 Agent 安装在当前 SSH 用户目录中的 Codex 运行时和附件暂存目录。'
          '系统 Codex、VS Code、~/.codex 配置和工作区不会被修改。',
      confirmLabel: '卸载',
      destructive: true,
    );
    if (!approved || !mounted) return;
    try {
      await ref
          .read(appControllerProvider.notifier)
          .uninstallRemoteRuntime(draft.id);
      if (mounted) _showMessage('托管 Codex 已卸载');
    } catch (error) {
      if (mounted) _showMessage(_errorText(error));
    }
  }

  Future<void> _openProfile(
    ServerProfile profile,
    ConnectionState connection,
  ) async {
    if (connection.phase == ConnectionPhase.connected) {
      ref.read(appControllerProvider.notifier).selectProfile(profile.id);
      return;
    }
    final approved = await _confirm(
      title: '连接服务器？',
      message: '使用已保存的 SSH 配置连接“${profile.name}”。',
      confirmLabel: '连接',
    );
    if (!approved || !mounted) return;
    await ref.read(appControllerProvider.notifier).requestConnect(profile);
  }

  Future<void> _confirmDisconnect(ServerProfile profile) async {
    final approved = await _confirm(
      title: '断开服务器？',
      message: '将断开“${profile.name}”的 SSH 与 Agent 通道。远端已保存的会话不会删除。',
      confirmLabel: '断开',
      destructive: true,
    );
    if (!approved || !mounted) return;
    await ref
        .read(appControllerProvider.notifier)
        .disconnectProfile(profile.id);
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
    bool destructive = false,
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Text(message),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                style: destructive
                    ? FilledButton.styleFrom(backgroundColor: codexRed)
                    : null,
                onPressed: () => Navigator.pop(context, true),
                child: Text(confirmLabel),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _scheduleFingerprintDialog(
    String? fingerprint,
    String? savedFingerprint,
  ) {
    if (fingerprint == null || fingerprint == _shownFingerprint) return;
    _shownFingerprint = fingerprint;
    final previous = savedFingerprint?.trim() ?? '';
    final fingerprintChanged =
        previous.isNotEmpty &&
        normalizeSshFingerprint(previous) !=
            normalizeSshFingerprint(fingerprint);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final approved = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.fingerprint, color: codexAmber),
          title: Text(fingerprintChanged ? '服务器指纹已变化' : '核对 SSH 主机指纹'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  fingerprintChanged
                      ? '服务器返回的 SSH 指纹与已保存记录不同。请先确认服务器已重装或密钥已更换；来源不明时请取消连接。'
                      : '请与服务器管理员提供的 SHA-256 指纹核对。信任后会固定保存。',
                ),
                const SizedBox(height: 12),
                if (fingerprintChanged) ...[
                  const Text('已保存指纹'),
                  const SizedBox(height: 4),
                  SelectableText(
                    previous,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                  const SizedBox(height: 12),
                  const Text('服务器当前指纹'),
                  const SizedBox(height: 4),
                ],
                SelectableText(
                  fingerprint,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    color: codexBlue,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(fingerprintChanged ? '更新并连接' : '信任并连接'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (approved == true) {
        await ref.read(appControllerProvider.notifier).confirmFingerprint();
      } else {
        ref.read(appControllerProvider.notifier).cancelFingerprint();
      }
      _shownFingerprint = null;
    });
  }

  Future<void> _pickPrivateKey() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.any,
        allowMultiple: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty || !mounted) return;
      final file = result.files.single;
      if (file.size > _maxPrivateKeyBytes) {
        throw StateError('私钥文件不能超过 1 MB');
      }
      final bytes = file.bytes;
      if (bytes == null) throw StateError('无法读取私钥文件');
      final pem = utf8.decode(bytes);
      if (!pem.contains('PRIVATE KEY')) {
        throw const FormatException('不是有效的 SSH 私钥');
      }
      setState(() => _draft = _draft?.copyWith(privateKeyPem: pem));
    } catch (error) {
      _showMessage(_errorText(error));
    }
  }

  Future<void> _openPromotion() async {
    final opened = await launchUrl(
      Uri.parse(_promotionUrl),
      mode: LaunchMode.externalApplication,
    );
    if (!opened && mounted) _showMessage('无法打开系统浏览器');
  }

  void _scheduleUpdatePrompt(AppUpdateState? previous, AppUpdateState next) {
    final update = next.availableUpdate;
    if (update == null ||
        !next.shouldPromptUpdate ||
        _deferredUpdateVersion == update.versionName ||
        _updateDialogVisible) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _updateDialogVisible) return;
      unawaited(_showUpdateDialog(update));
    });
  }

  Future<void> _handleUpdateTap() async {
    final controller = ref.read(appUpdateProvider.notifier);
    var update = ref.read(appUpdateProvider).availableUpdate;
    if (update == null) {
      await controller.checkForUpdates();
      if (!mounted) return;
      final updateState = ref.read(appUpdateProvider);
      update = updateState.availableUpdate;
      if (update == null) {
        _showMessage(
          updateState.checkError == null
              ? '当前已是最新版本'
              : '检查更新失败：${updateState.checkError}',
        );
        return;
      }
    }
    if (!_updateDialogVisible) await _showUpdateDialog(update);
  }

  Future<void> _showUpdateDialog(AppUpdateInfo update) async {
    if (!mounted || _updateDialogVisible) return;
    _updateDialogVisible = true;
    final ignored = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => AppUpdateDialog(
        update: update,
        onLater: () => Navigator.of(dialogContext).pop(false),
        onIgnore: () => Navigator.of(dialogContext).pop(true),
      ),
    );
    _updateDialogVisible = false;
    _deferredUpdateVersion = update.versionName;
    if (ignored == true && mounted) {
      await ref
          .read(appUpdateProvider.notifier)
          .ignoreVersion(update.versionName);
    }
  }

  void _handleLogoTap(bool debugEnabled) {
    if (debugEnabled) {
      _showMessage('Debug 模式已开启');
      return;
    }
    if (_debugTapCounter.registerTap()) {
      ref.read(appControllerProvider.notifier).enableDebugMode();
      ref
          .read(appControllerProvider.notifier)
          .diagnosticLogger
          .info('Debug', 'diagnostic_logging_enabled_from_logo');
      _showMessage('Debug 模式已开启');
    }
  }

  Future<void> _openDebugLogs() async {
    if (!mounted) return;
    final controller = ref.read(appControllerProvider.notifier);
    await showDiagnosticLogSheet(
      context,
      logger: controller.diagnosticLogger,
      onDisable: controller.disableDebugMode,
    );
  }

  Future<void> _shareDebugLogs() async {
    if (!mounted) return;
    await shareDiagnosticLogs(
      context,
      logger: ref.read(appControllerProvider.notifier).diagnosticLogger,
    );
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _AppTitle extends StatelessWidget {
  const _AppTitle({required this.subtitle, required this.onTap});

  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: 'Agent',
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(6),
            child: SizedBox.square(
              dimension: 48,
              child: Center(
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: codexText,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Icon(
                    Icons.terminal,
                    size: 19,
                    color: codexSurface,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Agent',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ],
    );
  }
}

class _PromotionAction extends StatelessWidget {
  const _PromotionAction({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.textScalerOf(context).scale(1) > 1.3;
    if (compact) {
      return IconButton(
        tooltip: '低价中转站优选',
        onPressed: onOpen,
        icon: const Icon(Icons.open_in_new, size: 19),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Tooltip(
        message: '打开低价中转站优选：lowapi.button1.cn',
        child: InkWell(
          onTap: onOpen,
          borderRadius: BorderRadius.circular(7),
          child: Container(
            width: 148,
            height: 42,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: codexAmber.withValues(alpha: 0.12),
              border: Border.all(color: codexAmber.withValues(alpha: 0.5)),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Row(
              children: [
                const Icon(Icons.open_in_new, size: 16, color: codexAmber),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '低价中转站优选',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: codexAmber,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      Text(
                        'lowapi.button1.cn',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(
                          context,
                        ).textTheme.labelSmall?.copyWith(color: codexMuted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AppVersion extends ConsumerWidget {
  const _AppVersion({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final updateState = ref.watch(appUpdateProvider);
    final description = updateState.availableUpdate != null
        ? '有新版本，查看更新'
        : updateState.checking
        ? '检查更新中'
        : '检查更新';
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: Center(
        child: Tooltip(
          message: description,
          child: Semantics(
            button: true,
            label: description,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(5),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'v${updateState.installedVersion}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        if (updateState.availableUpdate != null) ...[
                          const SizedBox(width: 5),
                          Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: codexGreen,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ],
                      ],
                    ),
                    SizedBox(
                      height: 16,
                      child: updateState.checking
                          ? const Align(
                              alignment: Alignment.centerRight,
                              child: SizedBox.square(
                                dimension: 11,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.5,
                                ),
                              ),
                            )
                          : Text(
                              updateState.availableUpdate == null
                                  ? '检查更新'
                                  : '有更新',
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: updateState.availableUpdate == null
                                        ? Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant
                                        : codexGreen,
                                  ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ServerList extends StatelessWidget {
  const _ServerList({
    super.key,
    required this.state,
    required this.onAdd,
    required this.localLinux,
    required this.onOpenLocalLinux,
    required this.onUninstallLocalLinux,
    required this.localWindows,
    required this.onOpenLocalWindows,
    required this.onSettings,
    required this.onOpen,
    required this.onDisconnect,
    required this.onOpenDebugLogs,
    required this.onShareDebugLogs,
  });

  final AppUiState state;
  final VoidCallback onAdd;
  final LocalLinuxState localLinux;
  final VoidCallback onOpenLocalLinux;
  final VoidCallback onUninstallLocalLinux;
  final ServerProfile? localWindows;
  final VoidCallback onOpenLocalWindows;
  final ValueChanged<ServerProfile> onSettings;
  final void Function(ServerProfile, ConnectionState) onOpen;
  final ValueChanged<ServerProfile> onDisconnect;
  final VoidCallback onOpenDebugLogs;
  final VoidCallback onShareDebugLogs;

  @override
  Widget build(BuildContext context) {
    final profiles = state.profiles
        .where(
          (profile) =>
              !isLocalLinuxProfile(profile) && !isLocalWindowsProfile(profile),
        )
        .toList(growable: false);
    final connectedCount = profiles
        .where(
          (profile) =>
              state.connectionStates[profile.id]?.phase ==
              ConnectionPhase.connected,
        )
        .length;
    return SafeArea(
      top: false,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          if (!Platform.isWindows)
            _LocalLinuxPanel(
              state: localLinux,
              onOpen: onOpenLocalLinux,
              onUninstall: onUninstallLocalLinux,
            ),
          if (localWindows != null)
            _LocalWindowsPanel(
              profile: localWindows!,
              connection:
                  state.connectionStates[localWindows!.id] ??
                  const ConnectionState(),
              onOpen: onOpenLocalWindows,
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: codexSurface,
                border: Border.all(color: codexBorder),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
                    child: Row(
                      children: [
                        const Icon(Icons.star, size: 22, color: codexAmber),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '服务器会话',
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                              Text(
                                profiles.isEmpty
                                    ? '添加第一台 SSH 服务器'
                                    : '${profiles.length} 台服务器 · $connectedCount 台已连接',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        SizedBox.square(
                          dimension: 40,
                          child: IconButton(
                            tooltip: '添加服务器',
                            onPressed: onAdd,
                            icon: const Icon(Icons.add, size: 21),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: codexBorder),
                  if (profiles.isEmpty)
                    _EmptyServerState(onAdd: onAdd)
                  else
                    for (var index = 0; index < profiles.length; index++) ...[
                      _ServerRow(
                        profile: profiles[index],
                        connection:
                            state.connectionStates[profiles[index].id] ??
                            const ConnectionState(),
                        metrics: state.serverMetrics[profiles[index].id],
                        onOpen: onOpen,
                        onSettings: onSettings,
                        onDisconnect: onDisconnect,
                      ),
                      if (index != profiles.length - 1)
                        Padding(
                          padding: EdgeInsets.only(left: 52),
                          child: Divider(
                            height: 1,
                            color: codexBorder.withValues(alpha: 0.72),
                          ),
                        ),
                    ],
                ],
              ),
            ),
          ),
          if (state.debugModeEnabled)
            _DebugLogBar(onOpen: onOpenDebugLogs, onShare: onShareDebugLogs),
          if (state.debugModeEnabled)
            const Divider(height: 1, color: codexBorder),
        ],
      ),
    );
  }
}

class _LocalLinuxPanel extends StatelessWidget {
  const _LocalLinuxPanel({
    required this.state,
    required this.onOpen,
    required this.onUninstall,
  });

  final LocalLinuxState state;
  final VoidCallback onOpen;
  final VoidCallback onUninstall;

  @override
  Widget build(BuildContext context) {
    final busy =
        state.phase == LocalLinuxPhase.installing ||
        state.phase == LocalLinuxPhase.starting ||
        state.phase == LocalLinuxPhase.checking;
    final trailingLabel = switch (state.phase) {
      LocalLinuxPhase.running => '打开',
      LocalLinuxPhase.stopped => '启动',
      LocalLinuxPhase.installing ||
      LocalLinuxPhase.starting => '${state.progress}%',
      LocalLinuxPhase.unavailable => '不可用',
      _ => '安装',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: DecoratedBox(
        key: const ValueKey('local-linux-panel'),
        decoration: BoxDecoration(
          color: codexSurface,
          border: Border.all(color: codexBorder),
          borderRadius: BorderRadius.circular(8),
        ),
        child: InkWell(
          onTap: busy ? null : onOpen,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 11, 8, 11),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: codexRaised,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Icon(Icons.phone_android, size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              '本机 Linux',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                          const SizedBox(width: 7),
                          const _ExperimentalBadge(),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        state.errorMessage ?? state.message,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: state.errorMessage == null ? null : codexRed,
                        ),
                      ),
                      if (busy && state.phase != LocalLinuxPhase.checking) ...[
                        const SizedBox(height: 7),
                        LinearProgressIndicator(
                          value: !state.indeterminate && state.progress > 0
                              ? state.progress / 100
                              : null,
                          minHeight: 3,
                          borderRadius: BorderRadius.circular(2),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          formatInstallTransfer(
                            downloadedBytes:
                                state.downloadedBytes > 0 ||
                                    state.totalBytes != null ||
                                    state.bytesPerSecond != null
                                ? state.downloadedBytes
                                : null,
                            totalBytes: state.totalBytes,
                            bytesPerSecond: state.bytesPerSecond,
                            elapsedSeconds: state.elapsedSeconds,
                            action: state.message.contains('解压')
                                ? '已处理'
                                : '已下载',
                          ),
                          key: const ValueKey('local-linux-transfer-summary'),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
                if (state.installed && !busy)
                  IconButton(
                    tooltip: '删除本机 Linux',
                    onPressed: onUninstall,
                    icon: const Icon(Icons.delete_outline, size: 20),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    trailingLabel,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: state.running ? codexGreen : codexMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LocalWindowsPanel extends StatelessWidget {
  const _LocalWindowsPanel({
    required this.profile,
    required this.connection,
    required this.onOpen,
  });

  final ServerProfile profile;
  final ConnectionState connection;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final busy =
        connection.phase == ConnectionPhase.connecting ||
        connection.phase == ConnectionPhase.probing;
    final connected = connection.phase == ConnectionPhase.connected;
    final failed = connection.phase == ConnectionPhase.failed;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: DecoratedBox(
        key: const ValueKey('local-windows-panel'),
        decoration: BoxDecoration(
          color: codexSurface,
          border: Border.all(color: codexBorder),
          borderRadius: BorderRadius.circular(8),
        ),
        child: InkWell(
          onTap: busy ? null : onOpen,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 11, 16, 11),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: codexRaised,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Icon(Icons.desktop_windows_outlined, size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        profile.name,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        failed
                            ? connection.message
                            : connected
                            ? 'Windows 原生 Codex'
                            : busy
                            ? connection.message
                            : '使用本机工作区和网络',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: failed ? codexRed : null,
                        ),
                      ),
                    ],
                  ),
                ),
                if (busy)
                  const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Text(
                    connected ? '打开' : '连接',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: connected ? codexGreen : codexMuted,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ExperimentalBadge extends StatelessWidget {
  const _ExperimentalBadge();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
    decoration: BoxDecoration(
      border: Border.all(color: codexAmber.withValues(alpha: 0.7)),
      borderRadius: BorderRadius.circular(3),
    ),
    child: Text(
      '实验',
      style: Theme.of(
        context,
      ).textTheme.labelSmall?.copyWith(color: codexAmber, fontSize: 9),
    ),
  );
}

class _DebugLogBar extends StatelessWidget {
  const _DebugLogBar({required this.onOpen, required this.onShare});

  final VoidCallback onOpen;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(
          children: [
            const Icon(Icons.bug_report, size: 21, color: codexGreen),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Debug 模式',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    '运行日志正在记录',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            SizedBox.square(
              dimension: 40,
              child: IconButton(
                tooltip: '分享诊断日志',
                onPressed: onShare,
                icon: const Icon(Icons.share, size: 20),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ServerRow extends StatelessWidget {
  const _ServerRow({
    required this.profile,
    required this.connection,
    required this.metrics,
    required this.onOpen,
    required this.onSettings,
    required this.onDisconnect,
  });

  final ServerProfile profile;
  final ConnectionState connection;
  final ServerMetrics? metrics;
  final void Function(ServerProfile, ConnectionState) onOpen;
  final ValueChanged<ServerProfile> onSettings;
  final ValueChanged<ServerProfile> onDisconnect;

  @override
  Widget build(BuildContext context) {
    final busy = {
      ConnectionPhase.probing,
      ConnectionPhase.connecting,
      ConnectionPhase.installing,
    }.contains(connection.phase);
    return Semantics(
      button: true,
      label: '服务器：${profile.name}，${_connectionLabel(connection.phase)}',
      child: InkWell(
        onTap: busy ? null : () => onOpen(profile, connection),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: codexRaised,
                  borderRadius: BorderRadius.circular(5),
                ),
                alignment: Alignment.center,
                child: const Icon(Icons.key, size: 16, color: codexAmber),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: 14,
                height: 14,
                child: busy
                    ? const CircularProgressIndicator(strokeWidth: 1.6)
                    : Center(
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: connection.phase == ConnectionPhase.connected
                                ? codexGreen
                                : codexMuted.withValues(alpha: 0.62),
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      profile.name.trim().isEmpty ? '未命名服务器' : profile.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    ServerMetricsStrip(
                      metrics: metrics,
                      compactForServerList: true,
                    ),
                    Text(
                      '${profile.username.trim().isEmpty ? 'root' : profile.username} · ${_connectionLabel(connection.phase)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: 40,
                height: 40,
                child: connection.phase == ConnectionPhase.connected
                    ? IconButton(
                        tooltip: '断开服务器',
                        onPressed: () => onDisconnect(profile),
                        icon: Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: codexRed.withValues(alpha: 0.2),
                            border: Border.all(
                              color: codexRed.withValues(alpha: 0.6),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.45),
                                blurRadius: 5,
                                offset: const Offset(0, 2),
                              ),
                              BoxShadow(
                                color: Colors.white.withValues(alpha: 0.08),
                                blurRadius: 1,
                                offset: const Offset(0, -1),
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.power_settings_new,
                            size: 17,
                            color: codexRed,
                          ),
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: 6),
              Tooltip(
                message: '服务器设置',
                child: InkWell(
                  onTap: () => onSettings(profile),
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    width: 42,
                    height: 40,
                    decoration: BoxDecoration(
                      border: Border.all(color: codexBorder),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Icon(Icons.settings, size: 18),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyServerState extends StatelessWidget {
  const _EmptyServerState({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 34),
      child: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: const BoxDecoration(
              color: codexRaised,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.dns, color: codexAmber),
          ),
          const SizedBox(height: 12),
          Text('还没有服务器', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 5),
          Text(
            '添加 SSH 服务器后，可在这里连接、断开或进入设置。',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('添加服务器'),
          ),
        ],
      ),
    );
  }
}

class _ServerEditor extends StatelessWidget {
  const _ServerEditor({
    super.key,
    required this.profile,
    required this.advanced,
    required this.passwordVisible,
    required this.isExisting,
    required this.onChanged,
    required this.onToggleAdvanced,
    required this.onTogglePassword,
    required this.onPickKey,
    required this.onSave,
    required this.onDelete,
    required this.onUninstall,
  });

  final ServerProfile profile;
  final bool advanced;
  final bool passwordVisible;
  final bool isExisting;
  final ValueChanged<ServerProfile> onChanged;
  final VoidCallback onToggleAdvanced;
  final VoidCallback onTogglePassword;
  final VoidCallback onPickKey;
  final VoidCallback onSave;
  final VoidCallback? onDelete;
  final VoidCallback? onUninstall;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: codexSurface,
                  border: Border.all(color: codexBorder),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isExisting ? '连接设置' : '新建服务器',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        isExisting ? profile.name : '填写 SSH 登录信息',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 14),
                      _field(
                        initialValue: profile.name,
                        label: '服务器名称',
                        icon: Icons.badge_outlined,
                        onChanged: (value) =>
                            onChanged(profile.copyWith(name: value)),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: _field(
                              initialValue: profile.host,
                              label: '服务器地址',
                              icon: Icons.dns_outlined,
                              onChanged: (value) => onChanged(
                                profile.copyWith(
                                  host: value,
                                  hostFingerprint: '',
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          SizedBox(
                            width: 104,
                            child: _field(
                              initialValue: profile.port.toString(),
                              label: '端口',
                              keyboardType: TextInputType.number,
                              onChanged: (value) => onChanged(
                                profile.copyWith(
                                  port: int.tryParse(value) ?? 0,
                                  hostFingerprint: '',
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _field(
                        initialValue: profile.username,
                        label: '用户名',
                        icon: Icons.person_outline,
                        onChanged: (value) =>
                            onChanged(profile.copyWith(username: value)),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: SegmentedButton<AuthMode>(
                          segments: const [
                            ButtonSegment(
                              value: AuthMode.password,
                              icon: Icon(Icons.lock_outline, size: 18),
                              label: Text('密码'),
                            ),
                            ButtonSegment(
                              value: AuthMode.privateKey,
                              icon: Icon(Icons.key, size: 18),
                              label: Text('私钥'),
                            ),
                          ],
                          selected: {profile.authMode},
                          showSelectedIcon: false,
                          onSelectionChanged: (selection) => onChanged(
                            profile.copyWith(authMode: selection.single),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (profile.authMode == AuthMode.password)
                        _field(
                          initialValue: profile.password,
                          label: 'SSH 密码',
                          icon: Icons.password,
                          obscureText: !passwordVisible,
                          suffix: IconButton(
                            tooltip: passwordVisible ? '隐藏密码' : '显示密码',
                            onPressed: onTogglePassword,
                            icon: Icon(
                              passwordVisible
                                  ? Icons.visibility_off
                                  : Icons.visibility,
                              size: 19,
                            ),
                          ),
                          onChanged: (value) =>
                              onChanged(profile.copyWith(password: value)),
                        )
                      else ...[
                        OutlinedButton.icon(
                          onPressed: onPickKey,
                          icon: const Icon(Icons.key, size: 18),
                          label: Text(
                            profile.privateKeyPem.isEmpty
                                ? '选择 SSH 私钥'
                                : '已选择私钥 · 点击更换',
                          ),
                        ),
                        const SizedBox(height: 12),
                        _field(
                          initialValue: profile.privateKeyPassphrase,
                          label: '私钥密码（可选）',
                          icon: Icons.lock_open_outlined,
                          obscureText: !passwordVisible,
                          suffix: IconButton(
                            tooltip: passwordVisible ? '隐藏私钥密码' : '显示私钥密码',
                            onPressed: onTogglePassword,
                            icon: Icon(
                              passwordVisible
                                  ? Icons.visibility_off
                                  : Icons.visibility,
                              size: 19,
                            ),
                          ),
                          onChanged: (value) => onChanged(
                            profile.copyWith(privateKeyPassphrase: value),
                          ),
                        ),
                      ],
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          const Icon(
                            Icons.fingerprint,
                            size: 21,
                            color: codexMuted,
                          ),
                          const SizedBox(width: 9),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('SSH 主机指纹'),
                                SelectableText(
                                  profile.hostFingerprint.isEmpty
                                      ? '尚未核对，将在首次连接时显示'
                                      : profile.hostFingerprint,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: profile.hostFingerprint.isEmpty
                                            ? codexMuted
                                            : codexBlue,
                                      ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: onToggleAdvanced,
                        icon: Icon(
                          advanced ? Icons.expand_less : Icons.expand_more,
                          size: 20,
                        ),
                        label: const Text('高级'),
                      ),
                      AnimatedSize(
                        duration: const Duration(milliseconds: 180),
                        curve: Curves.easeOutCubic,
                        child: advanced
                            ? Column(
                                children: [
                                  const SizedBox(height: 6),
                                  _field(
                                    initialValue: profile.workspace,
                                    label: '默认工作目录（可选）',
                                    icon: Icons.folder_outlined,
                                    onChanged: (value) => onChanged(
                                      profile.copyWith(workspace: value),
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  _field(
                                    initialValue: profile.proxyUrl,
                                    label: '远程下载代理（可选）',
                                    hint: 'http://127.0.0.1:7890',
                                    icon: Icons.route_outlined,
                                    onChanged: (value) => onChanged(
                                      profile.copyWith(proxyUrl: value),
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  _field(
                                    initialValue: profile.remoteCommand,
                                    label: 'Codex 远程命令',
                                    icon: Icons.terminal,
                                    onChanged: (value) => onChanged(
                                      profile.copyWith(remoteCommand: value),
                                    ),
                                  ),
                                  if (onUninstall != null) ...[
                                    const SizedBox(height: 12),
                                    Align(
                                      alignment: Alignment.centerLeft,
                                      child: OutlinedButton.icon(
                                        onPressed: onUninstall,
                                        icon: const Icon(
                                          Icons.delete_forever_outlined,
                                          size: 18,
                                        ),
                                        label: const Text('卸载托管 Codex'),
                                      ),
                                    ),
                                  ],
                                ],
                              )
                            : const SizedBox.shrink(),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          if (onDelete != null)
                            IconButton.outlined(
                              tooltip: '删除服务器',
                              onPressed: onDelete,
                              icon: const Icon(
                                Icons.delete_outline,
                                color: codexRed,
                              ),
                            ),
                          const Spacer(),
                          FilledButton.icon(
                            onPressed: onSave,
                            icon: const Icon(Icons.save_outlined, size: 18),
                            label: const Text('保存'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field({
    required String initialValue,
    required String label,
    required ValueChanged<String> onChanged,
    IconData? icon,
    Widget? suffix,
    String? hint,
    TextInputType? keyboardType,
    bool obscureText = false,
  }) {
    return TextFormField(
      key: ValueKey('$label-${profile.id}'),
      initialValue: initialValue,
      onChanged: onChanged,
      obscureText: obscureText,
      keyboardType: keyboardType,
      autocorrect: false,
      enableSuggestions: !obscureText,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: icon == null ? null : Icon(icon, size: 19),
        suffixIcon: suffix,
      ),
    );
  }
}

class _ConnectionOverlay extends StatelessWidget {
  const _ConnectionOverlay({required this.connection});

  final ConnectionState connection;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      key: const ValueKey('connection-overlay'),
      child: Semantics(
        container: true,
        scopesRoute: true,
        explicitChildNodes: true,
        label: '连接进行中',
        child: Stack(
          children: [
            ModalBarrier(
              dismissible: false,
              color: Colors.black.withValues(alpha: 0.58),
            ),
            Center(
              child: Container(
                constraints: const BoxConstraints(minWidth: 190, maxWidth: 300),
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 20,
                ),
                decoration: BoxDecoration(
                  color: codexRaised,
                  border: Border.all(color: codexBorder),
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black54,
                      blurRadius: 18,
                      offset: Offset(0, 6),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(strokeWidth: 2.2),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

ConnectionState? _blockingConnection(AppUiState state) {
  for (final connection in state.connectionStates.values) {
    if ({
      ConnectionPhase.probing,
      ConnectionPhase.connecting,
      ConnectionPhase.installing,
    }.contains(connection.phase)) {
      return connection;
    }
  }
  // Agent runtime loading happens after the SSH host is connected. It must
  // not keep the server-page modal visible with the stale "SSH 已连接"
  // message when the user has already returned to the server list.
  if (state.loading && state.selectedProfileId != null) {
    final connection = state.connectionStates[state.selectedProfileId];
    if (connection != null &&
        {
          ConnectionPhase.probing,
          ConnectionPhase.connecting,
          ConnectionPhase.installing,
        }.contains(connection.phase)) {
      return connection;
    }
  }
  return null;
}

String _connectionLabel(ConnectionPhase phase) => switch (phase) {
  ConnectionPhase.disconnected => '未连接',
  ConnectionPhase.probing => '读取指纹',
  ConnectionPhase.connecting => '连接中',
  ConnectionPhase.installing => '安装中',
  ConnectionPhase.connected => '已连接',
  ConnectionPhase.failed => '连接失败',
};

String _errorText(Object error) =>
    error.toString().replaceFirst(RegExp(r'^[^:]+:\s*'), '').trim();
