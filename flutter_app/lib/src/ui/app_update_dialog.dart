import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../domain/install_progress_format.dart';
import '../platform/app_update_manager.dart';
import 'theme.dart';

class AppUpdateDialog extends ConsumerWidget {
  const AppUpdateDialog({
    super.key,
    required this.update,
    required this.onLater,
    required this.onIgnore,
  });

  final AppUpdateInfo update;
  final VoidCallback onLater;
  final VoidCallback onIgnore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appUpdateProvider);
    final download = state.download.versionName == update.versionName
        ? state.download
        : const AppUpdateDownloadState();
    final progress = updateDownloadProgressFraction(
      download.downloadedBytes,
      download.totalBytes,
    );
    final canIgnore =
        download.status == AppUpdateDownloadStatus.idle ||
        download.status == AppUpdateDownloadStatus.failed;
    final dismissStyle = TextButton.styleFrom(
      foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
      minimumSize: const Size(0, 48),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
    );
    return AlertDialog(
      constraints: const BoxConstraints(maxWidth: 440),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      title: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('发现新版本'),
          const SizedBox(height: 2),
          Text(
            'v${update.versionName}',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: codexGreen),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400, maxHeight: 340),
        child: SingleChildScrollView(
          key: const ValueKey('app-update-content'),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _DownloadStatus(download: download, progress: progress),
              const SizedBox(height: 14),
              Text('更新日志', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              if (update.changes.isEmpty)
                Text(
                  '此版本包含改进与问题修复。',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                )
              else
                for (var index = 0; index < update.changes.length; index++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      '${index + 1}. ${update.changes[index].message}',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
            ],
          ),
        ),
      ),
      actions: [
        // A single footer keeps AlertDialog's OverflowBar from turning all four
        // actions into a column when their combined width exceeds the dialog.
        SizedBox(
          key: const ValueKey('app-update-actions'),
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _UpdateActionRow(
                leading: canIgnore
                    ? TextButton(
                        style: dismissStyle,
                        onPressed: onIgnore,
                        child: const Text('忽略此版本', textAlign: TextAlign.center),
                      )
                    : const SizedBox.shrink(),
                trailing: TextButton(
                  style: dismissStyle,
                  onPressed: onLater,
                  child: Text(
                    canIgnore ? '下次提醒' : '后台继续',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              _UpdateActionRow(
                leading: OutlinedButton(
                  onPressed: () => unawaited(_openManualDownload(context)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.onSurface,
                    minimumSize: const Size(0, 48),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Text('手动下载', textAlign: TextAlign.center),
                ),
                trailing: _PrimaryUpdateAction(
                  update: update,
                  download: download,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _openManualDownload(BuildContext context) async {
    try {
      final opened = await launchUrl(
        Uri.parse(appUpdateDownloadUrl(update)),
        mode: LaunchMode.externalApplication,
      );
      if (opened) return;
    } catch (_) {
      // The platform may either return false or throw when no browser opens.
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('无法打开浏览器，请稍后重试')));
  }
}

class _UpdateActionRow extends StatelessWidget {
  const _UpdateActionRow({required this.leading, required this.trailing});

  final Widget leading;
  final Widget trailing;

  @override
  Widget build(BuildContext context) => IntrinsicHeight(
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: leading),
        const SizedBox(width: 8),
        Expanded(child: trailing),
      ],
    ),
  );
}

class _DownloadStatus extends StatelessWidget {
  const _DownloadStatus({required this.download, required this.progress});

  final AppUpdateDownloadState download;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    switch (download.status) {
      case AppUpdateDownloadStatus.idle:
        return Text(
          '安装包将下载到本机，下载完成后可直接安装。',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: muted),
        );
      case AppUpdateDownloadStatus.downloading:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('下载进度', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 7),
            Text(
              _downloadProgressText(download, progress),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: muted),
            ),
          ],
        );
      case AppUpdateDownloadStatus.downloaded:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('下载完成', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            const LinearProgressIndicator(value: 1),
            const SizedBox(height: 7),
            Text(
              '已下载 ${formatInstallBytes(download.downloadedBytes)} / '
              '${formatInstallBytes(download.totalBytes ?? download.downloadedBytes)}',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: muted),
            ),
          ],
        );
      case AppUpdateDownloadStatus.awaitingInstallPermission:
        return Text(
          '请在系统设置中允许本应用安装未知来源应用，然后返回此处继续安装。',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: muted),
        );
      case AppUpdateDownloadStatus.installing:
        return Text(
          '系统安装界面已打开；如果已经取消，可以重新打开。',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: muted),
        );
      case AppUpdateDownloadStatus.failed:
        return Text(
          download.errorMessage ?? '下载失败，请重试。',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.error,
          ),
        );
    }
  }
}

class _PrimaryUpdateAction extends ConsumerWidget {
  const _PrimaryUpdateAction({required this.update, required this.download});

  final AppUpdateInfo update;
  final AppUpdateDownloadState download;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(appUpdateProvider.notifier);
    final label = switch (download.status) {
      AppUpdateDownloadStatus.downloading => '下载中',
      AppUpdateDownloadStatus.downloaded => '安装更新',
      AppUpdateDownloadStatus.awaitingInstallPermission => '继续安装',
      AppUpdateDownloadStatus.installing => '重新打开安装',
      AppUpdateDownloadStatus.failed => '重新下载',
      AppUpdateDownloadStatus.idle => '下载更新',
    };
    final VoidCallback? onPressed = switch (download.status) {
      AppUpdateDownloadStatus.downloading => null,
      AppUpdateDownloadStatus.downloaded ||
      AppUpdateDownloadStatus.awaitingInstallPermission ||
      AppUpdateDownloadStatus.installing => () => unawaited(
        controller.installDownloadedUpdate(),
      ),
      AppUpdateDownloadStatus.failed || AppUpdateDownloadStatus.idle =>
        () => unawaited(controller.startDownload(update)),
    };
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      child: download.status == AppUpdateDownloadStatus.downloading
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox.square(
                  dimension: 17,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 6),
                Flexible(child: Text(label, textAlign: TextAlign.center)),
              ],
            )
          : Text(label, textAlign: TextAlign.center),
    );
  }
}

String _downloadProgressText(
  AppUpdateDownloadState download,
  double? progress,
) {
  final total = download.totalBytes == null
      ? '正在获取总大小'
      : formatInstallBytes(download.totalBytes!);
  final percentage = progress == null ? '' : '（${(progress * 100).round()}%）';
  final speed = formatInstallRate(download.bytesPerSecond);
  final elapsed = formatInstallDuration(download.elapsedSeconds);
  return '已下载 ${formatInstallBytes(download.downloadedBytes)} / '
      '$total$percentage · $speed · $elapsed';
}
