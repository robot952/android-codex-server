import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
    return AlertDialog(
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
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 340),
        child: SingleChildScrollView(
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
        if (download.status == AppUpdateDownloadStatus.idle ||
            download.status == AppUpdateDownloadStatus.failed)
          TextButton(onPressed: onIgnore, child: const Text('忽略此版本')),
        TextButton(
          onPressed: onLater,
          child: Text(
            download.status == AppUpdateDownloadStatus.downloading ||
                    download.status == AppUpdateDownloadStatus.downloaded ||
                    download.status ==
                        AppUpdateDownloadStatus.awaitingInstallPermission ||
                    download.status == AppUpdateDownloadStatus.installing
                ? '后台继续'
                : '下次提醒',
          ),
        ),
        _PrimaryUpdateAction(update: update, download: download),
      ],
    );
  }
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
              '已下载 ${formatAppUpdateByteSize(download.downloadedBytes)} / '
              '${formatAppUpdateByteSize(download.totalBytes ?? download.downloadedBytes)}',
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
    switch (download.status) {
      case AppUpdateDownloadStatus.downloading:
        return FilledButton.icon(
          onPressed: null,
          icon: const SizedBox.square(
            dimension: 17,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          label: const Text('下载中'),
        );
      case AppUpdateDownloadStatus.downloaded:
        return FilledButton(
          onPressed: () => unawaited(controller.installDownloadedUpdate()),
          child: const Text('安装更新'),
        );
      case AppUpdateDownloadStatus.awaitingInstallPermission:
        return FilledButton(
          onPressed: () => unawaited(controller.installDownloadedUpdate()),
          child: const Text('继续安装'),
        );
      case AppUpdateDownloadStatus.installing:
        return FilledButton(
          onPressed: () => unawaited(controller.installDownloadedUpdate()),
          child: const Text('重新打开安装'),
        );
      case AppUpdateDownloadStatus.failed:
        return FilledButton.icon(
          onPressed: () => unawaited(controller.startDownload(update)),
          icon: const Icon(Icons.download, size: 18),
          label: const Text('重新下载'),
        );
      case AppUpdateDownloadStatus.idle:
        return FilledButton.icon(
          onPressed: () => unawaited(controller.startDownload(update)),
          icon: const Icon(Icons.download, size: 18),
          label: const Text('下载更新'),
        );
    }
  }
}

String _downloadProgressText(
  AppUpdateDownloadState download,
  double? progress,
) {
  final total = download.totalBytes == null
      ? '正在获取总大小'
      : formatAppUpdateByteSize(download.totalBytes!);
  final percentage = progress == null ? '' : '（${(progress * 100).round()}%）';
  return '已下载 ${formatAppUpdateByteSize(download.downloadedBytes)} / '
      '$total$percentage';
}
