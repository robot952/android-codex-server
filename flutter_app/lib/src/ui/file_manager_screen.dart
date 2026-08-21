import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/app_controller.dart';
import '../domain/models.dart';
import '../platform/local_file_exporter.dart';
import '../ssh/ssh_server_client.dart';
import 'theme.dart';

class FileManagerScreen extends ConsumerStatefulWidget {
  const FileManagerScreen({
    super.key,
    this.fileExporter = const AndroidLocalFileExporter(),
  });

  final LocalFileExporter fileExporter;

  @override
  ConsumerState<FileManagerScreen> createState() => _FileManagerScreenState();
}

class _FileManagerScreenState extends ConsumerState<FileManagerScreen> {
  final Set<String> _selectedPaths = <String>{};
  String? _selectionDirectory;
  bool _pickingFiles = false;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appControllerProvider);
    final controller = ref.read(appControllerProvider.notifier);
    if (_selectionDirectory != state.fileManagerCurrentPath) {
      _selectionDirectory = state.fileManagerCurrentPath;
      _selectedPaths.clear();
    }
    final selectedEntries = state.fileManagerEntries
        .where((entry) => _selectedPaths.contains(entry.path))
        .toList(growable: false);
    final busy =
        state.fileManagerLoading ||
        state.fileManagerOperation != null ||
        _pickingFiles;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: selectedEntries.isEmpty ? '返回会话' : '取消选择',
          onPressed: () {
            if (selectedEntries.isEmpty) {
              controller.closeFileManager();
            } else {
              setState(_selectedPaths.clear);
            }
          },
          icon: Icon(selectedEntries.isEmpty ? Icons.arrow_back : Icons.close),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              selectedEntries.isEmpty
                  ? '文件管理'
                  : '已选择 ${selectedEntries.length} 项',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (state.fileManagerOperation case final operation?)
              Text(
                operation,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: codexGreen),
              ),
          ],
        ),
        actions: [
          if (selectedEntries.isNotEmpty)
            IconButton(
              tooltip: '所选文件操作',
              onPressed: busy ? null : () => _showEntryActions(selectedEntries),
              icon: const Icon(Icons.more_vert),
            ),
          IconButton(
            tooltip: '刷新目录',
            onPressed: busy ? null : controller.refreshFileManager,
            icon: state.fileManagerLoading
                ? const SizedBox.square(
                    dimension: 19,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: PopupMenuButton<_FileToolbarAction>(
        tooltip: '更多文件操作',
        enabled: !busy,
        onSelected: (action) {
          switch (action) {
            case _FileToolbarAction.createFolder:
              unawaited(_createFolder());
            case _FileToolbarAction.upload:
              unawaited(_pickAndUploadFiles());
            case _FileToolbarAction.download:
              final entry = selectedEntries.length == 1
                  ? selectedEntries.first
                  : null;
              if (entry != null) unawaited(_download(entry));
            case _FileToolbarAction.paste:
              unawaited(controller.pasteRemoteFiles());
          }
        },
        itemBuilder: (context) => [
          const PopupMenuItem(
            value: _FileToolbarAction.createFolder,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.create_new_folder_outlined),
              title: Text('新建文件夹'),
            ),
          ),
          const PopupMenuItem(
            value: _FileToolbarAction.upload,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.upload_file_outlined),
              title: Text('上传文件'),
            ),
          ),
          PopupMenuItem(
            value: _FileToolbarAction.download,
            enabled:
                selectedEntries.length == 1 &&
                selectedEntries.first.kind == RemoteFileKind.file,
            child: const ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.download_outlined),
              title: Text('下载所选文件'),
            ),
          ),
          PopupMenuItem(
            value: _FileToolbarAction.paste,
            enabled: state.fileManagerClipboard != null,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.content_paste_outlined),
              title: Text(_pasteLabel(state.fileManagerClipboard)),
            ),
          ),
        ],
        child: FloatingActionButton.small(
          heroTag: 'file-manager-actions',
          tooltip: '更多文件操作',
          onPressed: null,
          backgroundColor: codexRaised,
          foregroundColor: codexText,
          child: const Icon(Icons.more_vert),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            SelectionArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 7, 18, 9),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    state.fileManagerCurrentPath.trim().isEmpty
                        ? '正在打开目录'
                        : state.fileManagerCurrentPath,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                  ),
                ),
              ),
            ),
            if (state.fileManagerClipboard case final clipboard?)
              _ClipboardBanner(clipboard: clipboard),
            if (state.fileManagerOperation != null || _pickingFiles)
              const LinearProgressIndicator(minHeight: 2),
            if (state.fileManagerError case final error?)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 7),
                color: codexRed.withValues(alpha: 0.08),
                child: Text(
                  error,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: codexRed),
                ),
              ),
            const Divider(height: 1),
            Expanded(
              child: _FileList(
                state: state,
                busy: busy,
                selectedPaths: _selectedPaths,
                onBrowse: controller.browseFileManager,
                onToggle: _toggleSelection,
                onActions: _showEntryActions,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _toggleSelection(RemoteFileEntry entry) {
    setState(() {
      if (!_selectedPaths.remove(entry.path)) _selectedPaths.add(entry.path);
    });
  }

  Future<void> _showEntryActions(List<RemoteFileEntry> entries) async {
    if (entries.isEmpty || !mounted) return;
    final action = await showModalBottomSheet<_EntryAction>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final single = entries.length == 1 ? entries.first : null;
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (single?.kind == RemoteFileKind.file)
                ListTile(
                  leading: const Icon(Icons.download_outlined),
                  title: const Text('下载'),
                  onTap: () => Navigator.pop(context, _EntryAction.download),
                ),
              if (single != null)
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: const Text('重命名'),
                  onTap: () => Navigator.pop(context, _EntryAction.rename),
                ),
              ListTile(
                leading: const Icon(Icons.content_copy_outlined),
                title: const Text('复制'),
                onTap: () => Navigator.pop(context, _EntryAction.copy),
              ),
              ListTile(
                leading: const Icon(Icons.content_cut_outlined),
                title: const Text('剪切'),
                onTap: () => Navigator.pop(context, _EntryAction.cut),
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline, color: codexRed),
                title: const Text('删除', style: TextStyle(color: codexRed)),
                onTap: () => Navigator.pop(context, _EntryAction.delete),
              ),
            ],
          ),
        );
      },
    );
    if (!mounted || action == null) return;
    final controller = ref.read(appControllerProvider.notifier);
    switch (action) {
      case _EntryAction.download:
        await _download(entries.single);
      case _EntryAction.rename:
        await _rename(entries.single);
      case _EntryAction.copy:
        controller.copyRemoteFiles(entries);
        setState(_selectedPaths.clear);
      case _EntryAction.cut:
        controller.cutRemoteFiles(entries);
        setState(_selectedPaths.clear);
      case _EntryAction.delete:
        await _confirmDelete(entries);
    }
  }

  Future<void> _createFolder() async {
    final value = await showDialog<String>(
      context: context,
      builder: (context) => const _RemoteNameDialog(
        title: '新建文件夹',
        label: '文件夹名称',
        confirmLabel: '创建',
        invalidNameFallback: '文件夹名称无效',
      ),
    );
    if (value == null || !mounted) return;
    await ref.read(appControllerProvider.notifier).createRemoteDirectory(value);
  }

  Future<void> _pickAndUploadFiles() async {
    if (_pickingFiles) return;
    setState(() => _pickingFiles = true);
    try {
      final result = await FilePicker.pickFiles(
        dialogTitle: '选择要上传的文件',
        type: FileType.any,
        allowMultiple: true,
        withReadStream: true,
        readSequential: true,
      );
      if (result == null || result.files.isEmpty || !mounted) return;
      final uploads = <LocalRemoteFileUpload>[];
      Object? firstError;
      for (final file in result.files) {
        try {
          if (file.size < 0 || file.size > maxRemoteFileBytes) {
            throw StateError('文件不能超过 2 GB');
          }
          final stream = file.readStream;
          if (stream == null) throw StateError('无法读取 ${file.name}');
          uploads.add(
            LocalRemoteFileUpload(
              name: file.name,
              sizeBytes: file.size,
              chunks: stream,
            ),
          );
        } catch (error) {
          firstError ??= error;
        }
      }
      if (uploads.isNotEmpty) {
        await ref
            .read(appControllerProvider.notifier)
            .uploadRemoteFiles(uploads);
      }
      if (firstError != null && mounted) {
        _showNotice(_displayError(firstError, '读取本地文件失败'));
      }
    } catch (error) {
      if (mounted) _showNotice(_displayError(error, '选择文件失败'));
    } finally {
      if (mounted) setState(() => _pickingFiles = false);
    }
  }

  Future<void> _download(RemoteFileEntry entry) async {
    if (entry.kind != RemoteFileKind.file) return;
    LocalFileExportSession? export;
    var completed = false;
    try {
      export = await widget.fileExporter.begin(fileName: entry.name);
      if (export == null || !mounted) return;
      await ref
          .read(appControllerProvider.notifier)
          .downloadFileManagerFile(entry.path, writeChunk: export.write);
      await export.complete();
      completed = true;
      if (mounted) setState(_selectedPaths.clear);
    } catch (error) {
      if (mounted) _showNotice(_displayError(error, '下载文件失败'));
    } finally {
      if (!completed && export != null) {
        try {
          await export.abort();
        } catch (_) {}
      }
    }
  }

  Future<void> _rename(RemoteFileEntry entry) async {
    final value = await showDialog<String>(
      context: context,
      builder: (context) => _RemoteNameDialog(
        title: '重命名',
        label: '新名称',
        confirmLabel: '重命名',
        invalidNameFallback: '名称无效',
        initialValue: entry.name,
      ),
    );
    if (value == null || !mounted) return;
    await ref
        .read(appControllerProvider.notifier)
        .renameRemoteFile(entry, value);
    if (mounted) setState(_selectedPaths.clear);
  }

  Future<void> _confirmDelete(List<RemoteFileEntry> entries) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          entries.length == 1
              ? '删除 ${entries.single.name}'
              : '删除 ${entries.length} 项',
        ),
        content: const Text('删除后无法恢复。目录及其内容会一并删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除', style: TextStyle(color: codexRed)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(appControllerProvider.notifier).deleteRemoteFiles(entries);
    if (mounted) setState(_selectedPaths.clear);
  }

  void _showNotice(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _RemoteNameDialog extends StatefulWidget {
  const _RemoteNameDialog({
    required this.title,
    required this.label,
    required this.confirmLabel,
    required this.invalidNameFallback,
    this.initialValue = '',
  });

  final String title;
  final String label;
  final String confirmLabel;
  final String invalidNameFallback;
  final String initialValue;

  @override
  State<_RemoteNameDialog> createState() => _RemoteNameDialogState();
}

class _RemoteNameDialogState extends State<_RemoteNameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue,
  );
  String? _errorText;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    try {
      final name = validateRemoteFileManagerName(_controller.text);
      Navigator.pop(context, name);
    } catch (error) {
      setState(
        () => _errorText = _displayError(error, widget.invalidNameFallback),
      );
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SingleChildScrollView(
      child: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: maxRemoteFileNameChars,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          labelText: widget.label,
          errorText: _errorText,
        ),
        onChanged: (_) {
          if (_errorText != null) setState(() => _errorText = null);
        },
        onSubmitted: (_) => _submit(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
    ],
  );
}

class _FileList extends StatelessWidget {
  const _FileList({
    required this.state,
    required this.busy,
    required this.selectedPaths,
    required this.onBrowse,
    required this.onToggle,
    required this.onActions,
  });

  final AppUiState state;
  final bool busy;
  final Set<String> selectedPaths;
  final ValueChanged<String> onBrowse;
  final ValueChanged<RemoteFileEntry> onToggle;
  final ValueChanged<List<RemoteFileEntry>> onActions;

  @override
  Widget build(BuildContext context) {
    if (state.fileManagerLoading && state.fileManagerEntries.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (!state.fileManagerLoading &&
        state.fileManagerEntries.isEmpty &&
        state.fileManagerParentPath == null &&
        state.fileManagerError == null) {
      return const Center(child: Text('当前目录为空'));
    }
    final hasParent = state.fileManagerParentPath != null;
    return ListView.separated(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount: state.fileManagerEntries.length + (hasParent ? 1 : 0),
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 54),
      itemBuilder: (context, index) {
        if (hasParent && index == 0) {
          return ListTile(
            enabled: !busy,
            leading: const Icon(Icons.drive_folder_upload_outlined),
            title: const Text('上级目录'),
            onTap: () => onBrowse(state.fileManagerParentPath!),
          );
        }
        final entry = state.fileManagerEntries[index - (hasParent ? 1 : 0)];
        final selected = selectedPaths.contains(entry.path);
        return ListTile(
          enabled: !busy,
          selected: selected,
          selectedTileColor: codexRaised,
          minTileHeight: 62,
          leading: Icon(
            _fileIcon(entry.kind),
            color: entry.kind == RemoteFileKind.directory
                ? codexGreen
                : codexMuted,
          ),
          title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            _entryDetail(entry),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: selected
              ? const Icon(Icons.check_circle, color: codexGreen, size: 19)
              : null,
          onTap: () {
            if (selectedPaths.isNotEmpty) {
              onToggle(entry);
            } else if (entry.kind == RemoteFileKind.directory) {
              onBrowse(entry.path);
            }
          },
          onLongPress: () {
            if (!selected) onToggle(entry);
            final paths = {...selectedPaths, entry.path};
            onActions(
              state.fileManagerEntries
                  .where((candidate) => paths.contains(candidate.path))
                  .toList(growable: false),
            );
          },
        );
      },
    );
  }
}

class _ClipboardBanner extends StatelessWidget {
  const _ClipboardBanner({required this.clipboard});

  final RemoteFileClipboard clipboard;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    color: codexRaised,
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
    child: Row(
      children: [
        Icon(
          clipboard.mode == RemoteFileTransferMode.copy
              ? Icons.content_copy_outlined
              : Icons.content_cut_outlined,
          size: 16,
          color: codexGreen,
        ),
        const SizedBox(width: 8),
        Text(
          '${clipboard.entries.length} 项待${clipboard.mode == RemoteFileTransferMode.copy ? '复制' : '移动'}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
  );
}

enum _FileToolbarAction { createFolder, upload, download, paste }

enum _EntryAction { download, rename, copy, cut, delete }

String _pasteLabel(RemoteFileClipboard? clipboard) => switch (clipboard?.mode) {
  RemoteFileTransferMode.copy => '粘贴复制项',
  RemoteFileTransferMode.move => '粘贴剪切项',
  null => '粘贴',
};

IconData _fileIcon(RemoteFileKind kind) => switch (kind) {
  RemoteFileKind.directory => Icons.folder_outlined,
  RemoteFileKind.file => Icons.description_outlined,
  RemoteFileKind.symbolicLink => Icons.link,
  RemoteFileKind.other => Icons.insert_drive_file_outlined,
};

String _entryDetail(RemoteFileEntry entry) {
  final parts = <String>[
    switch (entry.kind) {
      RemoteFileKind.directory => '目录',
      RemoteFileKind.file => '文件',
      RemoteFileKind.symbolicLink => '链接',
      RemoteFileKind.other => '其他',
    },
    if (entry.kind == RemoteFileKind.file) _formatFileSize(entry.sizeBytes),
    if (entry.permissions.trim().isNotEmpty) entry.permissions,
    if (entry.modifiedAtEpochMillis case final millis?) _formatTime(millis),
  ];
  return parts.join(' · ');
}

String _formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

String _formatTime(int milliseconds) {
  final value = DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)} '
      '${two(value.hour)}:${two(value.minute)}';
}

String _displayError(Object error, String fallback) {
  final message = error
      .toString()
      .replaceFirst(RegExp(r'^[^:]+:\s*'), '')
      .trim();
  return message.isEmpty ? fallback : message;
}
