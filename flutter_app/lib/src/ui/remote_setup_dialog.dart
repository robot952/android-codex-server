import 'package:flutter/material.dart';

import '../agent/remote_bootstrap.dart';
import '../domain/install_progress_format.dart';
import '../domain/models.dart';
import 'theme.dart';

const _pinnedOpenCodeVersion = '1.18.11';

class RemoteSetupDialog extends StatefulWidget {
  const RemoteSetupDialog({
    required this.state,
    required this.proxyUrl,
    required this.onProxyChanged,
    required this.onInstall,
    required this.onCancel,
    required this.onMinimize,
    super.key,
  });

  final AppUiState state;
  final String proxyUrl;
  final ValueChanged<String> onProxyChanged;
  final VoidCallback onInstall;
  final VoidCallback onCancel;
  final VoidCallback onMinimize;

  @override
  State<RemoteSetupDialog> createState() => _RemoteSetupDialogState();
}

class _RemoteSetupDialogState extends State<RemoteSetupDialog> {
  late final TextEditingController _proxyController;
  final _proxyFocusNode = FocusNode();
  final _scrollController = ScrollController();
  bool _proxyFocused = false;

  @override
  void initState() {
    super.initState();
    _proxyController = TextEditingController(text: widget.proxyUrl);
    _proxyFocusNode.addListener(_handleProxyFocusChanged);
  }

  @override
  void didUpdateWidget(covariant RemoteSetupDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.state.setupInProgress && widget.state.setupInProgress) {
      _proxyFocused = false;
      _proxyFocusNode.unfocus();
    }
    if (oldWidget.proxyUrl == widget.proxyUrl ||
        _proxyController.text == widget.proxyUrl) {
      return;
    }
    _proxyController.value = TextEditingValue(
      text: widget.proxyUrl,
      selection: TextSelection.collapsed(offset: widget.proxyUrl.length),
    );
  }

  @override
  void dispose() {
    _proxyFocusNode.removeListener(_handleProxyFocusChanged);
    _proxyController.dispose();
    _proxyFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _handleProxyFocusChanged() {
    final focused = _proxyFocusNode.hasFocus;
    if (focused == _proxyFocused || !mounted) return;
    setState(() => _proxyFocused = focused);
  }

  @override
  Widget build(BuildContext context) {
    final setup = widget.state.remoteSetup;
    if (setup == null) {
      return const SizedBox.shrink(key: ValueKey('remote-setup-empty'));
    }

    final inProgress = widget.state.setupInProgress;
    final failed = _setupFailed(widget.state);
    final viewInsets = MediaQuery.viewInsetsOf(context);
    final display = _RemoteSetupDisplay.fromPrompt(setup);
    final isClaude = setup.agent == AgentKind.claudeCode;
    final title = isClaude ? '安装 Claude Code 连接组件' : setup.title;

    return Positioned.fill(
      key: const ValueKey('remote-setup-overlay'),
      child: Semantics(
        container: true,
        scopesRoute: true,
        explicitChildNodes: true,
        label: title,
        child: Stack(
          children: [
            ModalBarrier(
              dismissible: true,
              onDismiss: inProgress ? widget.onMinimize : widget.onCancel,
              color: Colors.black.withValues(alpha: 0.62),
            ),
            AnimatedPadding(
              key: const ValueKey('remote-setup-keyboard-padding'),
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + viewInsets.bottom),
              child: Center(
                child: SafeArea(
                  minimum: EdgeInsets.zero,
                  child: Dialog(
                    key: const ValueKey('remote-setup-dialog'),
                    insetPadding: EdgeInsets.zero,
                    clipBehavior: Clip.antiAlias,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: 520,
                        maxHeight: 720,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _DialogHeading(title: title),
                          const Divider(height: 1),
                          Flexible(
                            child: Scrollbar(
                              controller: _scrollController,
                              child: SingleChildScrollView(
                                key: const ValueKey('remote-setup-scroll'),
                                controller: _scrollController,
                                keyboardDismissBehavior:
                                    ScrollViewKeyboardDismissBehavior.onDrag,
                                padding: const EdgeInsets.fromLTRB(
                                  18,
                                  15,
                                  18,
                                  16,
                                ),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    AnimatedSize(
                                      duration: const Duration(
                                        milliseconds: 180,
                                      ),
                                      curve: Curves.easeOutCubic,
                                      alignment: Alignment.topCenter,
                                      child: _proxyFocused
                                          ? const SizedBox.shrink()
                                          : Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.stretch,
                                              children: [
                                                Text(
                                                  isClaude
                                                      ? '请先在服务器安装并登录 Claude Code 2.1 或更新的 2.x 版本，准备 Node.js 18 或更新版本。这里仅安装手机连接组件，沿用服务器现有登录和配置。'
                                                      : setup.agent ==
                                                            AgentKind.codex
                                                      ? '将在此服务器安装 Codex ${_codexTargetVersion(setup)}，完成后自动连接。'
                                                      : setup.detail,
                                                  key: const ValueKey(
                                                    'remote-setup-detail',
                                                  ),
                                                ),
                                                const SizedBox(height: 12),
                                                _RuntimeInformation(
                                                  setup: setup,
                                                  display: display,
                                                ),
                                                const SizedBox(height: 12),
                                              ],
                                            ),
                                    ),
                                    if (!isClaude && !inProgress)
                                      TextField(
                                        key: const ValueKey(
                                          'remote-setup-proxy',
                                        ),
                                        controller: _proxyController,
                                        focusNode: _proxyFocusNode,
                                        enabled: !inProgress,
                                        autocorrect: false,
                                        enableSuggestions: false,
                                        keyboardType: TextInputType.url,
                                        textInputAction: TextInputAction.done,
                                        scrollPadding: EdgeInsets.only(
                                          bottom: viewInsets.bottom + 96,
                                        ),
                                        onChanged: widget.onProxyChanged,
                                        onSubmitted: (_) =>
                                            _proxyFocusNode.unfocus(),
                                        decoration: InputDecoration(
                                          labelText: '下载代理（可选）',
                                          hintText: 'http://127.0.0.1:7890',
                                          helperText: display.proxyDescription,
                                          helperMaxLines: 3,
                                          prefixIcon: const Icon(
                                            Icons.route_outlined,
                                            size: 20,
                                          ),
                                        ),
                                      ),
                                    if (inProgress) ...[
                                      _InstallProgress(state: widget.state),
                                      const SizedBox(height: 10),
                                      Text(
                                        '安装在服务器上继续，可最小化查看其他页面。',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodySmall,
                                      ),
                                    ] else if (failed) ...[
                                      const SizedBox(height: 14),
                                      _InstallFailure(state: widget.state),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const Divider(height: 1),
                          _DialogActions(
                            inProgress: inProgress,
                            failed: failed,
                            onInstall: widget.onInstall,
                            onCancel: widget.onCancel,
                            onMinimize: widget.onMinimize,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DialogHeading extends StatelessWidget {
  const _DialogHeading({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 14, 13),
      child: Row(
        children: [
          Icon(
            Icons.download_for_offline_outlined,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              key: const ValueKey('remote-setup-title'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
        ],
      ),
    );
  }
}

class _RuntimeInformation extends StatelessWidget {
  const _RuntimeInformation({required this.setup, required this.display});

  final RemoteSetupPrompt setup;
  final _RemoteSetupDisplay display;

  @override
  Widget build(BuildContext context) {
    final detectedVersion = setup.detectedVersion?.trim();
    return Container(
      key: const ValueKey('remote-setup-runtime-information'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: codexSurface,
        border: Border.all(color: codexBorder),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _InformationLine(
            key: const ValueKey('remote-setup-platform'),
            icon: Icons.dns_outlined,
            label: '服务器',
            value: '${setup.os} · ${setup.architecture}',
          ),
          const SizedBox(height: 8),
          _InformationLine(
            key: const ValueKey('remote-setup-version'),
            icon: Icons.inventory_2_outlined,
            label: '目标版本',
            value: display.versionLine,
          ),
          if (detectedVersion?.isNotEmpty ?? false) ...[
            const SizedBox(height: 8),
            _InformationLine(
              key: const ValueKey('remote-setup-detected-version'),
              icon: Icons.search_outlined,
              label: '当前版本',
              value: detectedVersion!,
            ),
          ],
          const SizedBox(height: 8),
          _InformationLine(
            key: const ValueKey('remote-setup-install-path'),
            icon: Icons.folder_outlined,
            label: '安装位置',
            value: display.installPath,
            monospace: true,
          ),
          if (display.bridgePath != null) ...[
            const SizedBox(height: 8),
            _InformationLine(
              key: const ValueKey('remote-setup-bridge-path'),
              icon: Icons.cable_outlined,
              label: '桥接程序',
              value: display.bridgePath!,
              monospace: true,
            ),
          ],
        ],
      ),
    );
  }
}

class _InformationLine extends StatelessWidget {
  const _InformationLine({
    required this.icon,
    required this.label,
    required this.value,
    this.monospace = false,
    super.key,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final valueText = SelectableText(
      value,
      style: textTheme.bodySmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurface,
        fontFamily: monospace ? 'monospace' : null,
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final labelRow = <Widget>[
          Icon(icon, size: 17, color: codexMuted),
          const SizedBox(width: 8),
          Text(label, style: textTheme.bodySmall),
        ];
        if (constraints.maxWidth < 300 &&
            MediaQuery.textScalerOf(context).scale(14) > 18) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: labelRow),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 25),
                child: valueText,
              ),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 17, color: codexMuted),
            const SizedBox(width: 8),
            SizedBox(width: 62, child: Text(label, style: textTheme.bodySmall)),
            const SizedBox(width: 4),
            Expanded(child: valueText),
          ],
        );
      },
    );
  }
}

class _InstallProgress extends StatelessWidget {
  const _InstallProgress({required this.state});

  final AppUiState state;

  @override
  Widget build(BuildContext context) {
    final fraction = _setupProgressFraction(state);
    final percent = fraction == null ? null : (fraction * 100).round();
    final downloadedBytes = state.setupDownloadedBytes;
    final totalBytes = state.setupTotalBytes;
    final downloadFraction =
        downloadedBytes != null && totalBytes != null && totalBytes > 0
        ? (downloadedBytes / totalBytes).clamp(0.0, 1.0)
        : null;
    final downloadPercent = downloadFraction == null
        ? null
        : (downloadFraction * 100).round();
    final progress = state.setupProgress.trim();
    final detail = state.setupProgressDetail.trim();
    final downloading = downloadedBytes != null || totalBytes != null;
    final transfer = downloading || state.setupElapsedSeconds != null;

    return Container(
      key: const ValueKey('remote-setup-progress'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: codexSurface,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox.square(
                dimension: 19,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  progress.isEmpty ? '正在安装' : progress,
                  key: const ValueKey('remote-setup-progress-label'),
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  '安装步骤进度',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              if (percent != null)
                Text(
                  '$percent%',
                  key: const ValueKey('remote-setup-overall-percent'),
                  style: Theme.of(
                    context,
                  ).textTheme.labelMedium?.copyWith(color: codexMuted),
                ),
            ],
          ),
          const SizedBox(height: 5),
          Semantics(
            label: '安装步骤进度',
            value: percent == null ? '准备中' : '$percent%',
            child: LinearProgressIndicator(
              key: const ValueKey('remote-setup-overall-progress'),
              value: fraction,
              minHeight: 5,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          if (detail.isNotEmpty) ...[
            const SizedBox(height: 9),
            Text(
              detail,
              key: const ValueKey('remote-setup-progress-detail'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          if (downloading) ...[
            const SizedBox(height: 11),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '当前文件下载',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                if (downloadPercent != null)
                  Text(
                    '$downloadPercent%',
                    key: const ValueKey('remote-setup-download-percent'),
                    style: Theme.of(
                      context,
                    ).textTheme.labelMedium?.copyWith(color: codexMuted),
                  ),
              ],
            ),
            const SizedBox(height: 5),
            Semantics(
              label: '当前文件下载',
              value: downloadPercent == null ? '总大小未知' : '$downloadPercent%',
              child: LinearProgressIndicator(
                key: const ValueKey('remote-setup-download-progress'),
                value: downloadFraction,
                minHeight: 4,
                borderRadius: BorderRadius.circular(3),
                color: codexGreen,
              ),
            ),
          ],
          if (state.setupProgressIndeterminate &&
              !downloading &&
              detail.isEmpty) ...[
            const SizedBox(height: 10),
            Text(
              '当前安装阶段仍在处理',
              key: const ValueKey('remote-setup-indeterminate-detail'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          if (transfer) ...[
            const SizedBox(height: 9),
            Text(
              formatInstallTransfer(
                downloadedBytes: downloadedBytes,
                totalBytes: totalBytes,
                bytesPerSecond: downloading ? state.setupBytesPerSecond : null,
                elapsedSeconds: state.setupElapsedSeconds,
                action: '已下载',
              ),
              key: const ValueKey('remote-setup-transfer-summary'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

class _InstallFailure extends StatelessWidget {
  const _InstallFailure({required this.state});

  final AppUiState state;

  @override
  Widget build(BuildContext context) {
    final message = _setupFailureMessage(state);
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('remote-setup-failure'),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer,
        border: Border.all(color: colorScheme.error.withValues(alpha: 0.55)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 19, color: colorScheme.error),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('安装未完成', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 3),
                Text(
                  message,
                  key: const ValueKey('remote-setup-failure-message'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onErrorContainer,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DialogActions extends StatelessWidget {
  const _DialogActions({
    required this.inProgress,
    required this.failed,
    required this.onInstall,
    required this.onCancel,
    required this.onMinimize,
  });

  final bool inProgress;
  final bool failed;
  final VoidCallback onInstall;
  final VoidCallback onCancel;
  final VoidCallback onMinimize;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 6,
        runSpacing: 4,
        children: [
          TextButton(
            key: ValueKey(
              inProgress ? 'remote-setup-minimize' : 'remote-setup-cancel',
            ),
            onPressed: inProgress ? onMinimize : onCancel,
            child: Text(inProgress ? '最小化' : '取消'),
          ),
          FilledButton.icon(
            key: const ValueKey('remote-setup-install'),
            onPressed: inProgress ? null : onInstall,
            icon: inProgress
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(failed ? Icons.refresh : Icons.download_outlined),
            label: Text(
              inProgress
                  ? '安装中'
                  : failed
                  ? '重试安装'
                  : '安装并连接',
            ),
          ),
        ],
      ),
    );
  }
}

class _RemoteSetupDisplay {
  const _RemoteSetupDisplay({
    required this.versionLine,
    required this.installPath,
    required this.proxyDescription,
    this.bridgePath,
  });

  factory _RemoteSetupDisplay.fromPrompt(RemoteSetupPrompt setup) {
    final home = setup.home.endsWith('/')
        ? setup.home.substring(0, setup.home.length - 1)
        : setup.home;
    final sharedRoot = '$home/.local/share/codex-remote';
    return switch (setup.agent) {
      AgentKind.codex => _RemoteSetupDisplay(
        versionLine:
            'Codex ${_codexTargetVersion(setup)} · Node $pinnedNodeVersion',
        installPath: sharedRoot,
        proxyDescription: '仅用于本次远程 Node.js 和 Codex 下载，并保存到此服务器',
      ),
      AgentKind.openCode => _RemoteSetupDisplay(
        versionLine:
            'OpenCode $_pinnedOpenCodeVersion · 共享 Node $pinnedNodeVersion',
        installPath: '$sharedRoot/opencode/releases/$_pinnedOpenCodeVersion',
        bridgePath: '$home/.local/bin/codex-remote-opencode-bridge',
        proxyDescription: '仅用于本次远程 Node.js 和 OpenCode 下载，并保存到此服务器',
      ),
      AgentKind.claudeCode => _RemoteSetupDisplay(
        versionLine: 'Claude Code 2.1+（2.x）· 使用服务器已有 CLI',
        installPath: '$sharedRoot/claude',
        bridgePath: '$home/.local/bin/codex-remote-claude-bridge',
        proxyDescription: '连接组件无需下载，Claude Code 沿用服务器已有网络设置',
      ),
    };
  }

  final String versionLine;
  final String installPath;
  final String? bridgePath;
  final String proxyDescription;
}

bool _setupFailed(AppUiState state) {
  if (state.setupInProgress) return false;
  final status = '${state.setupProgress}\n${state.setupProgressDetail}'
      .toLowerCase();
  return (state.error?.trim().isNotEmpty ?? false) ||
      status.contains('失败') ||
      status.contains('错误') ||
      status.contains('failed') ||
      status.contains('error');
}

String _setupFailureMessage(AppUiState state) {
  final error = state.error?.trim();
  if (error?.isNotEmpty ?? false) return error!;
  final detail = state.setupProgressDetail.trim();
  if (detail.isNotEmpty) return detail;
  final progress = state.setupProgress.trim();
  return progress.isEmpty ? '远程安装失败，请检查网络或代理后重试。' : progress;
}

String _codexTargetVersion(RemoteSetupPrompt setup) {
  final targetVersion = setup.targetVersion?.trim();
  return targetVersion == null || targetVersion.isEmpty
      ? pinnedCodexVersion
      : targetVersion;
}

double? _setupProgressFraction(AppUiState state) {
  if (state.setupProgressPercent > 0) {
    return state.setupProgressPercent.clamp(0, 100) / 100;
  }
  return null;
}
