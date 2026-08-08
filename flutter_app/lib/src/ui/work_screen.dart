import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart'
    show CupertinoSliverRefreshControl, RefreshIndicatorMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/app_controller.dart';
import '../domain/models.dart';
import '../platform/local_file_exporter.dart';
import 'markdown_links.dart';
import 'model_selection_presentation.dart';
import 'sub_agent_presentation.dart';
import 'theme.dart';
import 'work_content.dart';

typedef _OpenRemoteImage =
    Future<void> Function(String path, {String? fileName});

/// The active Codex transcript. The screen deliberately consumes domain
/// objects only; JSON-RPC parsing and connection lifetime stay in the agent
/// and controller layers.
class WorkScreen extends ConsumerStatefulWidget {
  const WorkScreen({
    super.key,
    this.onLoadRemoteImage,
    this.fileExporter = const AndroidLocalFileExporter(),
  });

  final Future<Uint8List> Function(String path)? onLoadRemoteImage;
  final LocalFileExporter fileExporter;

  @override
  ConsumerState<WorkScreen> createState() => _WorkScreenState();
}

class _WorkScreenState extends ConsumerState<WorkScreen>
    with WidgetsBindingObserver {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _composerController = TextEditingController();
  final FocusNode _composerFocus = FocusNode();
  bool _showJumpToBottom = false;
  bool _refreshing = false;
  bool _preparingAttachments = false;
  String? _imageLoadingPath;
  String? _fileDownloadPath;
  bool _savingImage = false;
  String? _syncedThreadId;
  int? _syncedComposerClearNonce;
  int? _timelineSignature;
  double _lastBottomInset = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_onScroll);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!shouldDismissWorkKeyboard(state)) return;
    FocusManager.instance.primaryFocus?.unfocus();
    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    _composerController.dispose();
    _composerFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appControllerProvider);
    final controller = ref.read(appControllerProvider.notifier);
    final back = state.screen == AppScreen.agentWork
        ? controller.backFromSubAgentThread
        : controller.backToThreadList;
    final backTooltip = state.screen == AppScreen.agentWork
        ? '返回上级会话'
        : '返回会话列表';
    _syncDraft(state);
    _syncViewport(state, MediaQuery.viewInsetsOf(context).bottom);
    final thread = state.activeThread;
    if (thread == null) {
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: backTooltip,
            onPressed: back,
            icon: const Icon(Icons.arrow_back),
          ),
          title: const Text('会话'),
        ),
        body: const Center(child: Text('正在读取会话…')),
      );
    }

    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        toolbarHeight: 64,
        leading: IconButton(
          tooltip: backTooltip,
          onPressed: back,
          icon: const Icon(Icons.arrow_back),
        ),
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              thread.title.isNotEmpty
                  ? thread.title
                  : state.activeAgentName?.isNotEmpty == true
                  ? state.activeAgentName!
                  : '未命名任务',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
            ),
            if (thread.cwd.isNotEmpty)
              Text(
                thread.cwd,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
        actions: [
          if (_fileDownloadPath != null)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Center(
                child: SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          PopupMenuButton<String>(
            tooltip: '会话操作',
            enabled: !state.loading && !state.attachmentUploading,
            onSelected: (value) =>
                unawaited(_handleWorkAction(value, state, controller)),
            itemBuilder: (context) => [
              if (state.activeAgentCapabilities.renameThread)
                PopupMenuItem(
                  value: 'rename',
                  enabled: !state.submitting,
                  child: const ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.edit_outlined),
                    title: Text('重命名'),
                  ),
                ),
              if (state.activeAgentCapabilities.archiveThread &&
                  state.screen != AppScreen.agentWork)
                PopupMenuItem(
                  value: 'archive',
                  enabled: !state.submitting && !state.running,
                  child: const ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.archive_outlined),
                    title: Text('归档'),
                  ),
                ),
              if (state.activeAgentCapabilities.threadGoals)
                PopupMenuItem(
                  value: 'goal',
                  enabled: !state.submitting,
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.track_changes_outlined),
                    title: Text(state.activeGoal == null ? '设置目标' : '编辑目标'),
                  ),
                ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (state.loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: _Transcript(
              state: state,
              controller: _scrollController,
              onOpenImage: (path, {fileName}) =>
                  _openRemoteImage(path, fileName: fileName),
              imageLoadingPath: _imageLoadingPath,
              onOpenRemoteFile: _downloadRemoteFile,
              onOpenSubAgent: controller.openSubAgentThread,
              onRefresh: state.olderTurnsCursor == null
                  ? null
                  : () => _loadOlder(controller),
              showJumpToBottom: _showJumpToBottom,
              onJumpToBottom: _jumpToBottom,
              onReview: controller.reviewChanges,
              onRollback: () => _confirmRollback(controller),
            ),
          ),
          if (state.approval case final prompt?)
            _ApprovalPanel(
              key: ValueKey(prompt.requestId),
              prompt: prompt,
              submitting: state.submitting,
              onAnswer: controller.answerApproval,
            ),
          _Composer(
            state: state,
            controller: _composerController,
            focusNode: _composerFocus,
            attachmentBusy: _preparingAttachments || state.attachmentUploading,
            onChanged: controller.setComposerDraft,
            onAttachImage: () => _pickAttachments(imagesOnly: true),
            onAttachFile: () => _pickAttachments(imagesOnly: false),
            onRemoveAttachment: controller.removeAttachment,
            onSend: () => controller.sendMessage(),
            onStop: () => _confirmStop(controller),
            onModelTap: () => unawaited(_showModelSheet(context, state)),
            onPermissionTap: () =>
                _showPermissionSheet(context, state, controller),
            onAction: (value) =>
                _handleComposerAction(value, state, controller),
            onEditGoal: () => _showGoalDialog(state, controller),
            onToggleGoal: () => _toggleGoal(state, controller),
            onClearGoal: () => _confirmClearGoal(controller),
          ),
        ],
      ),
    );
  }

  Future<void> _handleWorkAction(
    String action,
    AppUiState state,
    AppController controller,
  ) async {
    switch (action) {
      case 'rename':
        await _showRenameDialog(state, controller);
      case 'archive':
        await _confirmArchive(state, controller);
      case 'goal':
        await _showGoalDialog(state, controller);
    }
  }

  Future<void> _handleComposerAction(
    String action,
    AppUiState state,
    AppController controller,
  ) async {
    switch (action) {
      case 'goal':
        await _showGoalDialog(state, controller);
      case 'toggle-goal':
        await _toggleGoal(state, controller);
      case 'clear-goal':
        await _confirmClearGoal(controller);
      case 'compact':
        final confirmed = await _confirm(
          title: '压缩会话',
          message: '是否压缩当前会话？压缩后可以释放一部分上下文空间。',
          confirmLabel: '压缩',
        );
        if (confirmed) await controller.compactActiveThread();
      case 'model':
        await _showModelSheet(context, state);
      case 'permissions':
        await _showPermissionSheet(context, state, controller);
    }
  }

  Future<void> _showRenameDialog(
    AppUiState state,
    AppController controller,
  ) async {
    final text = TextEditingController(text: state.activeThread?.title ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名任务'),
        content: TextField(
          controller: text,
          autofocus: true,
          maxLines: 1,
          textInputAction: TextInputAction.done,
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(text.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    text.dispose();
    if (name != null) await controller.renameActiveThread(name);
  }

  Future<void> _confirmArchive(
    AppUiState state,
    AppController controller,
  ) async {
    final confirmed = await _confirm(
      title: '归档任务',
      message: state.activeThread?.title ?? '',
      confirmLabel: '归档',
    );
    if (confirmed) await controller.archiveActiveThread();
  }

  Future<void> _confirmRollback(AppController controller) async {
    final confirmed = await _confirm(
      title: '撤销上一轮',
      message: '这只会回退 Agent 会话历史，不会自动恢复服务器上的本地文件。需要恢复文件时，请使用版本控制或手动编辑。',
      confirmLabel: '继续撤销',
    );
    if (confirmed) await controller.rollbackActiveThread();
  }

  Future<void> _confirmStop(AppController controller) async {
    final confirmed = await _confirm(
      title: '停止当前回复',
      message: '确定停止当前正在运行的回复吗？已经生成的内容会保留。',
      confirmLabel: '停止',
      destructive: true,
      icon: Icons.stop_circle_outlined,
    );
    if (confirmed) await controller.stopMessage();
  }

  Future<void> _showGoalDialog(
    AppUiState state,
    AppController controller,
  ) async {
    final text = TextEditingController(text: state.activeGoal?.objective ?? '');
    var canSave = text.text.trim().isNotEmpty;
    final objective = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          icon: const Icon(Icons.track_changes_outlined),
          title: Text(state.activeGoal == null ? '设置目标' : '编辑目标'),
          content: TextField(
            controller: text,
            autofocus: true,
            minLines: 3,
            maxLines: 6,
            maxLength: 4000,
            onChanged: (value) =>
                setDialogState(() => canSave = value.trim().isNotEmpty),
            decoration: const InputDecoration(
              labelText: '目标',
              hintText: '设置要持续追逐的目标',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: canSave
                  ? () => Navigator.of(context).pop(text.text)
                  : null,
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    text.dispose();
    if (objective != null) await controller.setActiveGoal(objective);
  }

  Future<void> _toggleGoal(AppUiState state, AppController controller) async {
    if (state.activeGoal?.status == ThreadGoalStatus.active) {
      final confirmed = await _confirm(
        title: '暂停目标',
        message: '确定暂停当前目标吗？之后可以随时继续。',
        confirmLabel: '暂停',
        icon: Icons.pause_circle_outline,
      );
      if (!confirmed) return;
    }
    await controller.toggleActiveGoalPause();
  }

  Future<void> _confirmClearGoal(AppController controller) async {
    final confirmed = await _confirm(
      title: '删除目标',
      message: '删除当前会话的目标？',
      confirmLabel: '删除',
      destructive: true,
      icon: Icons.delete_outline,
    );
    if (confirmed) await controller.clearActiveGoal();
  }

  Future<void> _showPermissionSheet(
    BuildContext context,
    AppUiState state,
    AppController controller,
  ) async {
    final selected = await showModalBottomSheet<ApprovalMode>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 12),
          children: [
            const ListTile(
              leading: Icon(Icons.shield_outlined),
              title: Text('权限'),
            ),
            for (final mode in ApprovalMode.values)
              ListTile(
                leading: Icon(_approvalModeIcon(mode)),
                title: Text(mode.label),
                subtitle: Text(mode.description),
                trailing: mode == state.approvalMode
                    ? const Icon(Icons.check_circle, color: codexAmber)
                    : null,
                onTap: () => Navigator.of(context).pop(mode),
              ),
          ],
        ),
      ),
    );
    if (selected == null || selected == state.approvalMode || !mounted) return;
    if (selected == ApprovalMode.fullAccess) {
      final confirmed = await _confirm(
        title: '启用完全访问',
        message: '${state.activeAgent.label} 将不受工作区沙箱限制。',
        confirmLabel: '启用',
        destructive: true,
      );
      if (!confirmed) return;
    }
    await controller.selectApprovalMode(selected);
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
    bool destructive = false,
    IconData? icon,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: icon == null ? null : Icon(icon),
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              confirmLabel,
              style: destructive
                  ? TextStyle(color: Theme.of(context).colorScheme.error)
                  : null,
            ),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _pickAttachments({required bool imagesOnly}) async {
    if (_preparingAttachments ||
        ref.read(appControllerProvider).attachmentUploading) {
      return;
    }
    try {
      final result = await FilePicker.pickFiles(
        dialogTitle: imagesOnly ? '选择图片' : '选择文件',
        type: imagesOnly ? FileType.image : FileType.any,
        allowMultiple: true,
        withReadStream: true,
        readSequential: true,
      );
      if (result == null || result.files.isEmpty || !mounted) return;
      final state = ref.read(appControllerProvider);
      if (state.attachments.length + result.files.length >
          maxPendingAttachmentCount) {
        _showNotice(context, '每次最多保留 $maxPendingAttachmentCount 个待发送附件');
        return;
      }
      setState(() => _preparingAttachments = true);
      final uploads = <LocalAttachmentUpload>[];
      Object? firstError;
      var selectedBytes = 0;
      for (final file in result.files) {
        try {
          final mimeType = attachmentMimeType(
            file.name,
            forceImage: imagesOnly,
          );
          final text = isTextAttachment(file.name, mimeType);
          final limit = text
              ? maxInlineTextAttachmentBytes
              : maxLocalAttachmentBytes;
          final bytes = await _readPickedFile(file, maxBytes: limit);
          selectedBytes += bytes.length;
          if (selectedBytes > maxPendingAttachmentTotalBytes) {
            throw StateError('一次选择的附件总大小不能超过 40 MB');
          }
          uploads.add(
            LocalAttachmentUpload(
              name: file.name,
              bytes: bytes,
              mimeType: mimeType,
              textContent: text
                  ? utf8.decode(bytes, allowMalformed: true)
                  : null,
            ),
          );
        } catch (error) {
          firstError ??= error;
        }
      }
      if (uploads.isNotEmpty && mounted) {
        await ref
            .read(appControllerProvider.notifier)
            .uploadAttachments(uploads);
      }
      if (firstError != null && mounted) {
        _showNotice(context, _displayError(firstError, '读取附件失败'));
      }
    } catch (error) {
      if (mounted) {
        _showNotice(context, _displayError(error, '选择附件失败'));
      }
    } finally {
      if (mounted) setState(() => _preparingAttachments = false);
    }
  }

  Future<void> _downloadRemoteFile(String path) async {
    if (_fileDownloadPath != null) {
      _showNotice(context, '已有文件正在下载');
      return;
    }
    final fileName = remoteDownloadFileName(path);
    LocalFileExportSession? export;
    var completed = false;
    try {
      export = await widget.fileExporter.begin(
        fileName: fileName,
        mimeType: attachmentMimeType(fileName),
      );
      if (export == null || !mounted) return;
      setState(() => _fileDownloadPath = path);
      await ref
          .read(appControllerProvider.notifier)
          .downloadRemoteFile(path, writeChunk: export.write);
      await export.complete();
      completed = true;
      if (mounted) _showNotice(context, '已保存 $fileName');
    } catch (error) {
      if (mounted) {
        _showNotice(context, _displayError(error, '保存远程文件失败'));
      }
    } finally {
      if (!completed && export != null) {
        try {
          await export.abort();
        } catch (_) {}
      }
      if (mounted) setState(() => _fileDownloadPath = null);
    }
  }

  Future<void> _openRemoteImage(String path, {String? fileName}) async {
    final normalized = path.trim();
    if (normalized.isEmpty || _imageLoadingPath != null) return;
    final loader = widget.onLoadRemoteImage;
    if (loader == null) {
      _showNotice(context, '图片预览需要已连接的 SSH 文件通道');
      return;
    }
    setState(() => _imageLoadingPath = normalized);
    try {
      final bytes = await loader(normalized);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierColor: Colors.black87,
        builder: (dialogContext) => _RemoteImageDialog(
          path: normalized,
          fileName: fileName,
          bytes: bytes,
          onSave: () =>
              _saveImage(dialogContext, bytes, fileName ?? normalized),
        ),
      );
    } catch (error) {
      if (mounted) {
        _showNotice(context, _displayError(error, '无法加载图片'));
      }
    } finally {
      if (mounted) setState(() => _imageLoadingPath = null);
    }
  }

  Future<void> _saveImage(
    BuildContext dialogContext,
    Uint8List bytes,
    String sourceName,
  ) async {
    if (_savingImage) return;
    setState(() => _savingImage = true);
    try {
      final name = imageFileName(sourceName);
      final saved = await FilePicker.saveFile(
        dialogTitle: '保存图片',
        fileName: name,
        bytes: bytes,
      );
      if (!mounted) return;
      if (saved != null && dialogContext.mounted) {
        Navigator.of(dialogContext).pop();
        _showNotice(context, '图片已保存');
      }
    } catch (error) {
      if (mounted) _showNotice(context, _displayError(error, '保存图片失败'));
    } finally {
      if (mounted) setState(() => _savingImage = false);
    }
  }

  void _showNotice(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _syncDraft(AppUiState state) {
    final threadId = state.activeThread?.id;
    if (threadId == null ||
        (threadId == _syncedThreadId &&
            state.composerClearNonce == _syncedComposerClearNonce)) {
      return;
    }
    _syncedThreadId = threadId;
    _syncedComposerClearNonce = state.composerClearNonce;
    final value = state.composerDraft;
    _composerController.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final distance =
        _scrollController.position.maxScrollExtent -
        _scrollController.position.pixels;
    final next = distance > 180;
    if (next != _showJumpToBottom && mounted) {
      setState(() => _showJumpToBottom = next);
    }
  }

  void _syncViewport(AppUiState state, double bottomInset) {
    final last = state.timeline.isEmpty ? null : state.timeline.last;
    final signature = Object.hash(
      state.activeThread?.id,
      state.timeline.length,
      last?.id,
      last?.text.length,
      last?.output.length,
      state.aggregateDiff.length,
    );
    final transcriptChanged = signature != _timelineSignature;
    final viewportShrank = bottomInset > _lastBottomInset;
    _timelineSignature = signature;
    _lastBottomInset = bottomInset;
    if ((!transcriptChanged && !viewportShrank) || _showJumpToBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients || _showJumpToBottom) {
        return;
      }
      // Streaming deltas and IME frames can arrive faster than an animation.
      // A direct jump keeps the transcript edge attached to the composer.
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  Future<void> _loadOlder(AppController controller) async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    final beforeExtent = _scrollController.hasClients
        ? _scrollController.position.maxScrollExtent
        : null;
    try {
      await controller.loadOlderTurns();
      if (beforeExtent != null && mounted) {
        await WidgetsBinding.instance.endOfFrame;
        if (_scrollController.hasClients) {
          final position = _scrollController.position;
          final addedExtent = position.maxScrollExtent - beforeExtent;
          if (addedExtent > 0) {
            position.jumpTo(
              (position.pixels + addedExtent).clamp(
                position.minScrollExtent,
                position.maxScrollExtent,
              ),
            );
          }
        }
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  void _jumpToBottom() {
    if (!_scrollController.hasClients) return;
    unawaited(
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  Future<void> _showModelSheet(BuildContext context, AppUiState state) async {
    if (!state.activeAgentCapabilities.models) return;
    _composerFocus.unfocus();
    final manageModels = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => const _ModelSelectionSheet(),
    );
    if (manageModels == true && mounted) {
      await showModalBottomSheet<void>(
        context: this.context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (context) => const _ModelManagerSheet(),
      );
    }
  }
}

bool shouldDismissWorkKeyboard(AppLifecycleState state) =>
    state != AppLifecycleState.resumed;

class _ModelSelectionSheet extends ConsumerWidget {
  const _ModelSelectionSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appControllerProvider);
    final controller = ref.read(appControllerProvider.notifier);
    final selected = selectedAgentModel(state.models, state.selectedModel);
    final efforts = state.activeAgentCapabilities.reasoningEffort
        ? selected?.efforts ?? const <String>[]
        : const <String>[];
    final maximumHeight = MediaQuery.sizeOf(context).height * 0.72;
    return SafeArea(
      child: SizedBox(
        height: maximumHeight.clamp(320, 620).toDouble(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 8, 6),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      '模型',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('manage-models'),
                    tooltip: '管理模型',
                    onPressed: () => Navigator.of(context).pop(true),
                    icon: const Icon(Icons.settings_outlined),
                  ),
                ],
              ),
            ),
            Expanded(
              child: state.models.isEmpty
                  ? const Center(
                      child: Text(
                        '暂无可用模型',
                        style: TextStyle(color: codexMuted),
                      ),
                    )
                  : ListView.builder(
                      itemCount: state.models.length,
                      itemBuilder: (context, index) {
                        final model = state.models[index];
                        final selectedModel =
                            identical(model, selected) ||
                            model.id == selected?.id;
                        final wireName = agentModelWireName(model);
                        final displayName = model.displayName.trim().isEmpty
                            ? wireName
                            : model.displayName.trim();
                        final description = model.description.trim();
                        final capability = modelCapabilityLabel(model);
                        final hasDetails =
                            wireName != displayName ||
                            description.isNotEmpty ||
                            capability.isNotEmpty;
                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 3,
                          ),
                          title: Text(displayName),
                          subtitle: hasDetails
                              ? Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (wireName != displayName)
                                      Text(
                                        wireName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    if (description.isNotEmpty)
                                      Text(
                                        description,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    if (capability.isNotEmpty) Text(capability),
                                  ],
                                )
                              : null,
                          trailing: selectedModel
                              ? const Icon(
                                  Icons.check_circle,
                                  size: 19,
                                  color: codexGreen,
                                )
                              : null,
                          onTap: wireName.isEmpty
                              ? null
                              : () => controller.selectThreadModel(
                                  wireName,
                                  effort: model.defaultEffort,
                                ),
                        );
                      },
                    ),
            ),
            if (efforts.isNotEmpty) ...[
              const Divider(height: 1, color: codexBorder),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 7),
                child: Text(
                  '思考强度',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    for (var index = 0; index < efforts.length; index++) ...[
                      if (index > 0) const SizedBox(width: 8),
                      FilterChip(
                        selected: efforts[index] == state.selectedEffort,
                        onSelected: (_) =>
                            controller.selectThreadEffort(efforts[index]),
                        label: Text(
                          reasoningEffortDisplayLabel(efforts[index]),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
          ],
        ),
      ),
    );
  }
}

class _ModelEditorRequest {
  const _ModelEditorRequest({this.originalModelId, this.definition});

  final String? originalModelId;
  final CustomModelDefinition? definition;
}

class _ModelManagerSheet extends ConsumerWidget {
  const _ModelManagerSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appControllerProvider);
    final controller = ref.read(appControllerProvider.notifier);
    ServerProfile? profile;
    for (final candidate in state.profiles) {
      if (candidate.id == state.selectedProfileId) {
        profile = candidate;
        break;
      }
    }
    final settings = profile?.modelSettings(state.activeAgent);
    final customModels = editableCustomModelDefinitions(
      state.models,
      settings?.customModels ?? const <CustomModelDefinition>[],
    );
    final remoteModels = state.models
        .where((model) => !model.isCustom)
        .toList(growable: false);
    final hiddenModelIds = settings?.hiddenModelIds ?? const <String>[];
    final screenHeight = MediaQuery.sizeOf(context).height;
    final height = (screenHeight * 0.82).clamp(420.0, 760.0);

    return SafeArea(
      child: SizedBox(
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '模型管理',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const Text(
                          '仅影响当前服务器',
                          style: TextStyle(color: codexMuted, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('add-custom-model'),
                    onPressed: customModels.length >= maxCustomModels
                        ? null
                        : () => _showEditor(
                            context,
                            ref,
                            const _ModelEditorRequest(),
                            customModels,
                            state,
                          ),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('新增模型'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: codexBorder),
            Expanded(
              child:
                  customModels.isEmpty &&
                      remoteModels.isEmpty &&
                      hiddenModelIds.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 24),
                        child: Text(
                          '暂无模型，可新增模型或重新连接服务器刷新远端列表',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: codexMuted),
                        ),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 18),
                      children: [
                        if (customModels.isNotEmpty) ...[
                          const _ModelSectionTitle('自定义模型'),
                          for (final definition in customModels)
                            _CustomModelRow(
                              definition: definition,
                              showApiProtocol: state
                                  .activeAgentCapabilities
                                  .modelApiProtocols
                                  .isNotEmpty,
                              onEdit: () => _showEditor(
                                context,
                                ref,
                                _ModelEditorRequest(
                                  originalModelId: definition.modelId,
                                  definition: definition,
                                ),
                                customModels,
                                state,
                              ),
                              onDelete: () => _confirmDelete(
                                context,
                                controller,
                                definition,
                              ),
                            ),
                        ],
                        if (remoteModels.isNotEmpty) ...[
                          const _ModelSectionTitle('远端模型'),
                          for (final model in remoteModels)
                            _RemoteModelRow(
                              model: model,
                              onHide: () => controller.setModelHidden(
                                agentModelWireName(model),
                                true,
                              ),
                            ),
                        ],
                        if (hiddenModelIds.isNotEmpty) ...[
                          const _ModelSectionTitle('已隐藏模型'),
                          for (final modelId in hiddenModelIds)
                            ListTile(
                              contentPadding: const EdgeInsets.only(
                                left: 20,
                                right: 8,
                              ),
                              title: Text(
                                modelId,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: IconButton(
                                tooltip: '显示模型',
                                onPressed: () =>
                                    controller.setModelHidden(modelId, false),
                                icon: const Icon(Icons.visibility_outlined),
                              ),
                            ),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showEditor(
    BuildContext context,
    WidgetRef ref,
    _ModelEditorRequest request,
    List<CustomModelDefinition> customModels,
    AppUiState state,
  ) async {
    final definition = await showDialog<CustomModelDefinition>(
      context: context,
      builder: (context) => _CustomModelEditorDialog(
        request: request,
        existingModelIds: customModels
            .map((model) => model.modelId)
            .toList(growable: false),
        modelApiProtocols: state.activeAgentCapabilities.modelApiProtocols,
        canFetchApiModels: state.activeAgentCapabilities.globalSettings,
      ),
    );
    if (definition == null || !context.mounted) return;
    ref
        .read(appControllerProvider.notifier)
        .saveCustomModel(request.originalModelId, definition);
  }

  Future<void> _confirmDelete(
    BuildContext context,
    AppController controller,
    CustomModelDefinition definition,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除自定义模型？'),
        content: Text(
          definition.displayName.trim().isEmpty
              ? definition.modelId
              : definition.displayName,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              '删除',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      controller.deleteCustomModel(definition.modelId);
    }
  }
}

class _ModelSectionTitle extends StatelessWidget {
  const _ModelSectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 15, 20, 5),
    child: Text(
      text,
      style: Theme.of(
        context,
      ).textTheme.labelLarge?.copyWith(color: codexMuted),
    ),
  );
}

class _CustomModelRow extends StatelessWidget {
  const _CustomModelRow({
    required this.definition,
    required this.showApiProtocol,
    required this.onEdit,
    required this.onDelete,
  });

  final CustomModelDefinition definition;
  final bool showApiProtocol;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final displayName = definition.displayName.trim().isEmpty
        ? definition.modelId
        : definition.displayName.trim();
    final details = _modelCapabilityText(
      definition.contextWindowTokens,
      definition.maxOutputTokens,
    );
    return ListTile(
      contentPadding: const EdgeInsets.only(left: 20, right: 4),
      title: Text(displayName),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (displayName != definition.modelId)
            Text(
              definition.modelId,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          if (showApiProtocol) Text(definition.apiProtocol.label),
          if (details.isNotEmpty) Text(details),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '编辑自定义模型',
            onPressed: onEdit,
            icon: const Icon(Icons.edit_outlined),
          ),
          IconButton(
            tooltip: '删除自定义模型',
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline, color: codexRed),
          ),
        ],
      ),
    );
  }
}

class _RemoteModelRow extends StatelessWidget {
  const _RemoteModelRow({required this.model, required this.onHide});

  final AgentModel model;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    final wireName = agentModelWireName(model);
    final displayName = model.displayName.trim().isEmpty
        ? wireName
        : model.displayName.trim();
    final details = _modelCapabilityText(
      model.contextWindowTokens,
      model.maxOutputTokens,
    );
    return ListTile(
      contentPadding: const EdgeInsets.only(left: 20, right: 8),
      title: Text(displayName),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (wireName != displayName)
            Text(wireName, maxLines: 1, overflow: TextOverflow.ellipsis),
          if (details.isNotEmpty) Text(details),
        ],
      ),
      trailing: IconButton(
        tooltip: '隐藏模型',
        onPressed: onHide,
        icon: const Icon(Icons.visibility_off_outlined),
      ),
    );
  }
}

String _modelCapabilityText(int contextWindowTokens, int maxOutputTokens) {
  final details = <String>[
    if (contextWindowTokens > 0)
      '上下文 ${formatModelTokenLimit(contextWindowTokens)}',
    if (maxOutputTokens > 0) '输出 ${formatModelTokenLimit(maxOutputTokens)}',
  ];
  return details.join(' · ');
}

class _CustomModelEditorDialog extends ConsumerStatefulWidget {
  const _CustomModelEditorDialog({
    required this.request,
    required this.existingModelIds,
    required this.modelApiProtocols,
    required this.canFetchApiModels,
  });

  final _ModelEditorRequest request;
  final List<String> existingModelIds;
  final List<ModelApiProtocol> modelApiProtocols;
  final bool canFetchApiModels;

  @override
  ConsumerState<_CustomModelEditorDialog> createState() =>
      _CustomModelEditorDialogState();
}

class _CustomModelEditorDialogState
    extends ConsumerState<_CustomModelEditorDialog> {
  late final TextEditingController _modelIdController;
  late final TextEditingController _displayNameController;
  late final TextEditingController _contextWindowController;
  late final TextEditingController _maxOutputController;
  late ModelApiProtocol _apiProtocol;

  @override
  void initState() {
    super.initState();
    final definition =
        widget.request.definition ?? const CustomModelDefinition();
    _modelIdController = TextEditingController(text: definition.modelId);
    _displayNameController = TextEditingController(
      text: definition.displayName,
    );
    _contextWindowController = TextEditingController(
      text: definition.contextWindowTokens > 0
          ? '${definition.contextWindowTokens}'
          : '',
    );
    _maxOutputController = TextEditingController(
      text: definition.maxOutputTokens > 0
          ? '${definition.maxOutputTokens}'
          : '',
    );
    _apiProtocol = widget.modelApiProtocols.contains(definition.apiProtocol)
        ? definition.apiProtocol
        : widget.modelApiProtocols.isNotEmpty
        ? widget.modelApiProtocols.first
        : definition.apiProtocol;
    for (final controller in <TextEditingController>[
      _modelIdController,
      _displayNameController,
      _contextWindowController,
      _maxOutputController,
    ]) {
      controller.addListener(_rebuild);
    }
  }

  @override
  void dispose() {
    for (final controller in <TextEditingController>[
      _modelIdController,
      _displayNameController,
      _contextWindowController,
      _maxOutputController,
    ]) {
      controller
        ..removeListener(_rebuild)
        ..dispose();
    }
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appControllerProvider);
    final modelId = _modelIdController.text.trim();
    final contextText = _contextWindowController.text.trim();
    final maxOutputText = _maxOutputController.text.trim();
    final contextValue = contextText.isEmpty ? 0 : int.tryParse(contextText);
    final maxOutputValue = maxOutputText.isEmpty
        ? 0
        : int.tryParse(maxOutputText);
    final invalidContext =
        contextValue == null ||
        contextValue < 0 ||
        contextValue > maxModelTokenLimit;
    final invalidMaxOutput =
        maxOutputValue == null ||
        maxOutputValue < 0 ||
        maxOutputValue > maxModelTokenLimit;
    final duplicateId =
        modelId.isNotEmpty &&
        modelId != widget.request.originalModelId?.trim() &&
        widget.existingModelIds.any((id) => id.trim() == modelId);
    final modelIdValid =
        modelId.isNotEmpty &&
        modelId.length <= maxCustomModelIdChars &&
        RegExp(r'^[A-Za-z0-9._:/@+\-]+$').hasMatch(modelId);
    final displayNameValid = isValidCustomModelDisplayName(
      _displayNameController.text,
    );
    final canSave =
        modelIdValid &&
        !duplicateId &&
        !invalidContext &&
        !invalidMaxOutput &&
        displayNameValid;
    final loadingApiModels =
        state.apiModelOptionsLoading &&
        state.apiModelOptionsProfileId == state.selectedProfileId;

    return AlertDialog(
      key: const ValueKey('custom-model-editor'),
      scrollable: true,
      title: Text(widget.request.originalModelId == null ? '新增模型' : '编辑自定义模型'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('custom-model-id'),
                    controller: _modelIdController,
                    autofocus: true,
                    maxLength: maxCustomModelIdChars,
                    decoration: InputDecoration(
                      labelText: '模型 ID',
                      errorText: duplicateId
                          ? '已有相同的自定义模型 ID'
                          : modelId.isNotEmpty && !modelIdValid
                          ? '仅支持字母、数字及 . _ - / : @ +'
                          : null,
                    ),
                  ),
                ),
                if (widget.canFetchApiModels) ...[
                  const SizedBox(width: 8),
                  SizedBox(
                    height: 56,
                    child: OutlinedButton.icon(
                      key: const ValueKey('fetch-api-models'),
                      onPressed: loadingApiModels ? null : _pickApiModel,
                      icon: loadingApiModels
                          ? const SizedBox.square(
                              dimension: 17,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh, size: 18),
                      label: const Text('获取'),
                    ),
                  ),
                ],
              ],
            ),
            if (widget.modelApiProtocols.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('API 协议', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 7),
              SegmentedButton<ModelApiProtocol>(
                segments: [
                  for (final protocol in widget.modelApiProtocols)
                    ButtonSegment<ModelApiProtocol>(
                      value: protocol,
                      label: Text(protocol.label),
                    ),
                ],
                selected: {_apiProtocol},
                showSelectedIcon: false,
                onSelectionChanged: (selection) =>
                    setState(() => _apiProtocol = selection.first),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              key: const ValueKey('custom-model-display-name'),
              controller: _displayNameController,
              maxLength: maxCustomModelNameChars,
              decoration: InputDecoration(
                labelText: '显示名称（可选）',
                errorText: displayNameValid ? null : '显示名称过长或包含控制字符',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('custom-model-context-window'),
              controller: _contextWindowController,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: '上下文长度（tokens，可选）',
                errorText: invalidContext
                    ? '请输入 0 到 $maxModelTokenLimit 的整数'
                    : null,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('custom-model-max-output'),
              controller: _maxOutputController,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: '最大输出长度（tokens，可选）',
                errorText: invalidMaxOutput
                    ? '请输入 0 到 $maxModelTokenLimit 的整数'
                    : null,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('save-custom-model'),
          onPressed: canSave
              ? () => Navigator.of(context).pop(
                  CustomModelDefinition(
                    modelId: modelId,
                    displayName: _displayNameController.text.trim(),
                    contextWindowTokens: contextValue,
                    maxOutputTokens: maxOutputValue,
                    apiProtocol: _apiProtocol,
                  ),
                )
              : null,
          child: const Text('保存'),
        ),
      ],
    );
  }

  Future<void> _pickApiModel() async {
    final option = await showDialog<ApiModelOption>(
      context: context,
      builder: (context) => const _ApiModelPickerDialog(),
    );
    if (option == null || !mounted) return;
    final selection = applyApiModelOption(
      option,
      currentDisplayName: _displayNameController.text,
      currentContextWindow: _contextWindowController.text,
      currentMaxOutput: _maxOutputController.text,
    );
    _modelIdController.text = selection.modelId;
    _displayNameController.text = selection.displayName;
    _contextWindowController.text = selection.contextWindow;
    _maxOutputController.text = selection.maxOutput;
  }
}

class _ApiModelPickerDialog extends ConsumerStatefulWidget {
  const _ApiModelPickerDialog();

  @override
  ConsumerState<_ApiModelPickerDialog> createState() =>
      _ApiModelPickerDialogState();
}

class _ApiModelPickerDialogState extends ConsumerState<_ApiModelPickerDialog> {
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(
          ref.read(appControllerProvider.notifier).fetchApiModelOptions(),
        );
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appControllerProvider);
    final profileMatches =
        state.apiModelOptionsProfileId == state.selectedProfileId;
    final loading = profileMatches && state.apiModelOptionsLoading;
    final error = profileMatches ? state.apiModelOptionsError : null;
    final options = profileMatches
        ? filterApiModelOptions(state.apiModelOptions, _searchController.text)
        : const <ApiModelOption>[];
    final availableHeight =
        MediaQuery.sizeOf(context).height -
        MediaQuery.viewInsetsOf(context).bottom -
        180;
    final contentHeight = availableHeight.clamp(260.0, 480.0);
    final contentWidth = (MediaQuery.sizeOf(context).width - 80).clamp(
      0.0,
      520.0,
    );

    return AlertDialog(
      key: const ValueKey('api-model-picker'),
      title: const Text('选择 API 模型'),
      content: SizedBox(
        width: contentWidth,
        height: contentHeight,
        child: loading
            ? const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(strokeWidth: 2),
                    SizedBox(height: 12),
                    Text('正在获取模型'),
                  ],
                ),
              )
            : error != null
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, color: codexRed, size: 28),
                    const SizedBox(height: 10),
                    Text(error, textAlign: TextAlign.center),
                    const SizedBox(height: 14),
                    OutlinedButton.icon(
                      onPressed: () => unawaited(
                        ref
                            .read(appControllerProvider.notifier)
                            .fetchApiModelOptions(),
                      ),
                      icon: const Icon(Icons.refresh),
                      label: const Text('重新获取'),
                    ),
                  ],
                ),
              )
            : Column(
                children: [
                  TextField(
                    key: const ValueKey('api-model-search'),
                    controller: _searchController,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: '筛选模型',
                      prefixIcon: Icon(Icons.search),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: options.isEmpty
                        ? Center(
                            child: Text(
                              state.apiModelOptions.isEmpty
                                  ? 'API 未返回可用模型'
                                  : '没有匹配的模型',
                              style: const TextStyle(color: codexMuted),
                            ),
                          )
                        : ListView.builder(
                            itemCount: options.length,
                            itemBuilder: (context, index) {
                              final option = options[index];
                              final displayName =
                                  option.displayName.trim().isEmpty
                                  ? option.modelId
                                  : option.displayName.trim();
                              final capability = _modelCapabilityText(
                                option.contextWindowTokens,
                                option.maxOutputTokens,
                              );
                              return ListTile(
                                title: Text(displayName),
                                subtitle:
                                    displayName == option.modelId &&
                                        capability.isEmpty
                                    ? null
                                    : Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          if (displayName != option.modelId)
                                            Text(
                                              option.modelId,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          if (capability.isNotEmpty)
                                            Text(capability),
                                        ],
                                      ),
                                onTap: () => Navigator.of(context).pop(option),
                              );
                            },
                          ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class _ApprovalPanel extends StatefulWidget {
  const _ApprovalPanel({
    super.key,
    required this.prompt,
    required this.submitting,
    required this.onAnswer,
  });

  final ApprovalPrompt prompt;
  final bool submitting;
  final Future<void> Function(bool accept, {Map<String, String> answers})
  onAnswer;

  @override
  State<_ApprovalPanel> createState() => _ApprovalPanelState();
}

class _ApprovalPanelState extends State<_ApprovalPanel> {
  final Map<String, String> _answers = <String, String>{};

  @override
  Widget build(BuildContext context) {
    final prompt = widget.prompt;
    return Material(
      color: codexRaised,
      child: Container(
        width: double.infinity,
        constraints: const BoxConstraints(maxHeight: 300),
        padding: const EdgeInsets.fromLTRB(14, 11, 14, 10),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: codexBorder)),
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.pan_tool_alt_outlined, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      prompt.title,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  if (widget.submitting)
                    const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
              const SizedBox(height: 7),
              Text(prompt.detail),
              if (prompt.command.isNotEmpty) ...[
                const SizedBox(height: 7),
                _CodeBlock(prompt.command),
              ],
              for (final question in prompt.questions) ...[
                const SizedBox(height: 9),
                Text(
                  question.question.isEmpty
                      ? question.header
                      : question.question,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (question.options.isNotEmpty)
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final option in question.options)
                        ChoiceChip(
                          label: Text(option.label),
                          selected: _answers[question.id] == option.label,
                          onSelected: widget.submitting
                              ? null
                              : (selected) => setState(() {
                                  if (selected) {
                                    _answers[question.id] = option.label;
                                  }
                                }),
                        ),
                    ],
                  )
                else
                  TextField(
                    obscureText: question.isSecret,
                    enabled: !widget.submitting,
                    onChanged: (value) => _answers[question.id] = value,
                    decoration: InputDecoration(
                      hintText: question.header.isEmpty
                          ? '请输入'
                          : question.header,
                    ),
                  ),
              ],
              const SizedBox(height: 9),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: widget.submitting
                        ? null
                        : () => widget.onAnswer(false),
                    child: const Text('拒绝'),
                  ),
                  const SizedBox(width: 7),
                  FilledButton(
                    onPressed: widget.submitting
                        ? null
                        : () => widget.onAnswer(true, answers: _answers),
                    child: Text(
                      prompt.kind == ApprovalKind.userInput ? '提交' : '批准',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Transcript extends StatelessWidget {
  const _Transcript({
    required this.state,
    required this.controller,
    required this.onOpenImage,
    required this.imageLoadingPath,
    required this.onOpenRemoteFile,
    required this.onOpenSubAgent,
    required this.onRefresh,
    required this.showJumpToBottom,
    required this.onJumpToBottom,
    required this.onReview,
    required this.onRollback,
  });

  final AppUiState state;
  final ScrollController controller;
  final _OpenRemoteImage onOpenImage;
  final String? imageLoadingPath;
  final Future<void> Function(String path) onOpenRemoteFile;
  final void Function(String threadId, String agentName) onOpenSubAgent;
  final Future<void> Function()? onRefresh;
  final bool showJumpToBottom;
  final VoidCallback onJumpToBottom;
  final Future<void> Function() onReview;
  final Future<void> Function() onRollback;

  @override
  Widget build(BuildContext context) {
    final entries = state.timeline;
    final rows = entries.toTimelineRenderRows();
    final canOpenSubAgents =
        state.activeAgentCapabilities.subAgents &&
        !state.loading &&
        !state.submitting &&
        state.approvalQueue.isEmpty;
    String? latestFileChangeId;
    for (final entry in entries.reversed) {
      if (entry.kind == TimelineKind.fileChange) {
        latestFileChangeId = entry.id;
        break;
      }
    }
    final list = CustomScrollView(
      controller: controller,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      slivers: [
        if (onRefresh != null)
          CupertinoSliverRefreshControl(
            refreshTriggerPullDistance: 82,
            refreshIndicatorExtent: 54,
            onRefresh: onRefresh,
            builder: _buildOlderHistoryIndicator,
          ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 18),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate((context, index) {
              final row = rows[index];
              final child = switch (row) {
                TimelineEntryRenderRow(:final entry) => _TimelineCard(
                  entry: entry,
                  onOpenImage: onOpenImage,
                  imageLoadingPath: imageLoadingPath,
                  onOpenRemoteFile: onOpenRemoteFile,
                  canReview:
                      entry.kind == TimelineKind.fileChange &&
                      entry.changes.isNotEmpty &&
                      state.activeAgentCapabilities.reviewChanges &&
                      !state.loading &&
                      !state.submitting &&
                      !state.running,
                  canRollback:
                      entry.id == latestFileChangeId &&
                      entry.changes.isNotEmpty &&
                      state.activeAgentCapabilities.rollbackThread &&
                      !state.loading &&
                      !state.submitting &&
                      !state.running,
                  onReview: onReview,
                  onRollback: onRollback,
                ),
                SubAgentTimelineRenderRow(:final entries) =>
                  _SubAgentActivityGroupBlock(
                    entries: entries,
                    enabled: canOpenSubAgents,
                    onOpenSubAgent: onOpenSubAgent,
                  ),
              };
              return KeyedSubtree(
                key: ValueKey('${state.activeThread?.id}:${row.stableKey}'),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: child,
                ),
              );
            }, childCount: rows.length),
          ),
        ),
      ],
    );
    return Stack(
      children: [
        if (entries.isEmpty && !state.loading)
          const Center(child: Text('暂无消息')),
        Positioned.fill(child: list),
        if (showJumpToBottom)
          Positioned(
            left: 0,
            right: 0,
            bottom: 16,
            child: Material(
              color: codexRaised,
              shape: const CircleBorder(side: BorderSide(color: codexBorder)),
              elevation: 3,
              child: IconButton(
                tooltip: '回到底部',
                onPressed: onJumpToBottom,
                icon: const Icon(Icons.arrow_downward_rounded),
              ),
            ),
          ),
      ],
    );
  }
}

class _SubAgentActivityGroupBlock extends StatelessWidget {
  const _SubAgentActivityGroupBlock({
    required this.entries,
    required this.enabled,
    required this.onOpenSubAgent,
  });

  final List<TimelineEntry> entries;
  final bool enabled;
  final void Function(String threadId, String agentName) onOpenSubAgent;

  @override
  Widget build(BuildContext context) {
    final agents = entries.toSubAgentPresentations();
    if (agents.isEmpty) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        spacing: 6,
        runSpacing: 5,
        children: [
          for (final agent in agents)
            _SubAgentStatusChip(
              agent: agent,
              enabled: enabled,
              onOpenSubAgent: onOpenSubAgent,
            ),
        ],
      ),
    );
  }
}

class _SubAgentStatusChip extends StatelessWidget {
  const _SubAgentStatusChip({
    required this.agent,
    required this.enabled,
    required this.onOpenSubAgent,
  });

  final SubAgentPresentation agent;
  final bool enabled;
  final void Function(String threadId, String agentName) onOpenSubAgent;

  @override
  Widget build(BuildContext context) {
    final canOpen = enabled && agent.isOpenable;
    return Semantics(
      button: canOpen,
      label: agent.path.isEmpty ? agent.name : '${agent.name}，${agent.path}',
      value: agent.status.label,
      child: ActionChip(
        tooltip: canOpen ? '打开 ${agent.name}' : agent.status.label,
        onPressed: canOpen
            ? () => onOpenSubAgent(agent.threadId, agent.name)
            : null,
        avatar: _SubAgentAvatar(agent: agent),
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: Text(
                agent.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 7),
            _SubAgentStatusVisual(agent: agent),
          ],
        ),
        side: const BorderSide(color: codexBorder),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
        backgroundColor: codexSurface,
        disabledColor: codexSurface,
        padding: const EdgeInsets.symmetric(horizontal: 7),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

class _SubAgentAvatar extends StatelessWidget {
  const _SubAgentAvatar({required this.agent});

  final SubAgentPresentation agent;

  static const _palette = <Color>[
    Color(0xFF71A7F7),
    Color(0xFF9A8CFF),
    Color(0xFF51C7C7),
    Color(0xFFE38CC4),
    Color(0xFFE5A65E),
    Color(0xFF78C98A),
    Color(0xFFA78BFA),
  ];

  @override
  Widget build(BuildContext context) {
    final color = _palette[agent.avatarColorIndex(_palette.length)];
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.2),
      ),
      alignment: Alignment.center,
      child: Icon(Icons.smart_toy_outlined, size: 13, color: color),
    );
  }
}

class _SubAgentStatusVisual extends StatelessWidget {
  const _SubAgentStatusVisual({required this.agent});

  final SubAgentPresentation agent;

  @override
  Widget build(BuildContext context) {
    final color = _subAgentStatusColor(agent.status);
    if (agent.status.isActive) {
      return SizedBox.square(
        dimension: 14,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: color,
          semanticsLabel: agent.status.label,
        ),
      );
    }
    return Text(
      agent.status.label,
      maxLines: 1,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color),
    );
  }
}

Color _subAgentStatusColor(SubAgentDisplayStatus status) => switch (status) {
  SubAgentDisplayStatus.preparing ||
  SubAgentDisplayStatus.started ||
  SubAgentDisplayStatus.updated ||
  SubAgentDisplayStatus.working => codexAmber,
  SubAgentDisplayStatus.completed => codexGreen,
  SubAgentDisplayStatus.interrupted ||
  SubAgentDisplayStatus.failed ||
  SubAgentDisplayStatus.unavailable => codexRed,
  SubAgentDisplayStatus.stopped => codexMuted,
};

Widget _buildOlderHistoryIndicator(
  BuildContext context,
  RefreshIndicatorMode mode,
  double pulledExtent,
  double refreshTriggerPullDistance,
  double refreshIndicatorExtent,
) {
  final loading =
      mode == RefreshIndicatorMode.refresh || mode == RefreshIndicatorMode.done;
  final armed = mode == RefreshIndicatorMode.armed;
  final label = loading
      ? '正在加载更多...'
      : armed
      ? '松开加载更多'
      : '下拉加载更多';
  return SizedBox(
    height: pulledExtent,
    child: Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (loading)
            const SizedBox.square(
              dimension: 17,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(
              armed ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
              size: 21,
              color: codexMuted,
            ),
          const SizedBox(width: 7),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    ),
  );
}

class _TimelineCard extends StatelessWidget {
  const _TimelineCard({
    required this.entry,
    required this.onOpenImage,
    required this.imageLoadingPath,
    required this.onOpenRemoteFile,
    required this.canReview,
    required this.canRollback,
    required this.onReview,
    required this.onRollback,
  });

  final TimelineEntry entry;
  final _OpenRemoteImage onOpenImage;
  final String? imageLoadingPath;
  final Future<void> Function(String path) onOpenRemoteFile;
  final bool canReview;
  final bool canRollback;
  final Future<void> Function() onReview;
  final Future<void> Function() onRollback;

  @override
  Widget build(BuildContext context) {
    if (entry.kind == TimelineKind.userMessage) {
      return _UserMessageTimelineCard(
        entry: entry,
        onOpenImage: onOpenImage,
        imageLoadingPath: imageLoadingPath,
      );
    }
    if (entry.kind == TimelineKind.agentMessage) {
      return _MarkdownMessage(entry.text, onOpenRemoteFile: onOpenRemoteFile);
    }
    if (entry.kind == TimelineKind.reasoning ||
        entry.kind == TimelineKind.plan) {
      return _CollapsibleTimelineRow(entry: entry);
    }
    if (entry.kind == TimelineKind.command) {
      return _CommandTimelineCard(entry: entry);
    }
    final imagePath = imagePreviewPath(entry);
    if (imagePath != null) {
      return _ImageTimelineCard(
        entry: entry,
        path: imagePath,
        loading: imagePath == imageLoadingPath,
        onOpenImage: onOpenImage,
      );
    }
    final isUser = entry.kind == TimelineKind.userMessage;
    final previewPath = imagePreviewPath(entry);
    final loadingImage = previewPath != null && previewPath == imageLoadingPath;
    final color = isUser ? codexBlue : codexText;
    final icon = previewPath != null
        ? Icons.visibility_outlined
        : switch (entry.kind) {
            TimelineKind.userMessage => Icons.person_outline,
            TimelineKind.agentMessage => Icons.auto_awesome,
            TimelineKind.reasoning => Icons.psychology_outlined,
            TimelineKind.plan => Icons.list_alt,
            TimelineKind.command => Icons.terminal,
            TimelineKind.fileChange => Icons.edit_note,
            TimelineKind.tool => Icons.build_outlined,
            TimelineKind.subAgent => Icons.account_tree_outlined,
            TimelineKind.review => Icons.rate_review_outlined,
            TimelineKind.notice => Icons.info_outline,
          };
    final title = switch (entry.kind) {
      TimelineKind.userMessage => '你',
      TimelineKind.agentMessage => 'Codex',
      TimelineKind.reasoning => '思考过程',
      TimelineKind.plan => '计划',
      TimelineKind.command => entry.title.isEmpty ? '终端' : entry.title,
      TimelineKind.fileChange => entry.title.isEmpty ? '文件修改' : entry.title,
      TimelineKind.tool => entry.title.isEmpty ? '工具' : entry.title,
      TimelineKind.subAgent => '协作活动',
      TimelineKind.review => entry.title,
      TimelineKind.notice => entry.title.isEmpty ? '提示' : entry.title,
    };
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Material(
          color: isUser ? const Color(0xFF213A55) : codexSurface,
          shape: RoundedRectangleBorder(
            side: const BorderSide(color: codexBorder),
            borderRadius: BorderRadius.circular(7),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: previewPath == null ? null : () => onOpenImage(previewPath),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(icon, size: 17, color: color),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          title,
                          style: Theme.of(
                            context,
                          ).textTheme.labelLarge?.copyWith(color: color),
                        ),
                      ),
                      if (loadingImage)
                        const SizedBox.square(
                          dimension: 17,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else if (previewPath != null)
                        IconButton(
                          tooltip: '查看图片',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => onOpenImage(previewPath),
                          icon: const Icon(Icons.visibility_outlined, size: 18),
                        )
                      else if (entry.status.isNotEmpty &&
                          entry.status != 'completed' &&
                          entry.status != 'idle')
                        _StatusDot(status: entry.status),
                    ],
                  ),
                  if (entry.text.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    if (previewPath != null || entry.kind == TimelineKind.tool)
                      _BoundedSelectableText(entry.text)
                    else
                      _MarkdownMessage(
                        entry.text,
                        onOpenRemoteFile: onOpenRemoteFile,
                      ),
                  ],
                  if (entry.command.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    _CodeBlock(entry.command),
                  ],
                  if (entry.output.isNotEmpty &&
                      entry.output != previewPath) ...[
                    const SizedBox(height: 7),
                    _CodeBlock(entry.output),
                  ],
                  if (entry.changes.isNotEmpty) ...[
                    const SizedBox(height: 7),
                    for (final change in entry.changes)
                      _ChangeLine(change: change),
                    if (canReview || canRollback) ...[
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (canReview)
                            TextButton.icon(
                              onPressed: () => unawaited(onReview()),
                              icon: const Icon(Icons.rate_review_outlined),
                              label: const Text('审核'),
                            ),
                          if (canRollback)
                            TextButton.icon(
                              onPressed: () => unawaited(onRollback()),
                              icon: const Icon(Icons.undo_outlined),
                              label: const Text('撤销'),
                            ),
                        ],
                      ),
                    ],
                  ],
                  if (entry.subAgentPath.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Text(
                      entry.subAgentPath,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                  if (entry.attachments.isNotEmpty) ...[
                    const SizedBox(height: 7),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final attachment in entry.attachments)
                          _AttachmentChip(
                            attachment: attachment,
                            loading: imageLoadingPath == attachment.remotePath,
                            onOpenImage: onOpenImage,
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _UserMessageTimelineCard extends StatelessWidget {
  const _UserMessageTimelineCard({
    required this.entry,
    required this.onOpenImage,
    required this.imageLoadingPath,
  });

  final TimelineEntry entry;
  final _OpenRemoteImage onOpenImage;
  final String? imageLoadingPath;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: codexSurface,
      borderRadius: BorderRadius.circular(7),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (entry.text.isNotEmpty) SelectableText(entry.text),
            if (entry.attachments.isNotEmpty) ...[
              if (entry.text.isNotEmpty) const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final attachment in entry.attachments)
                    _AttachmentChip(
                      attachment: attachment,
                      loading: imageLoadingPath == attachment.remotePath,
                      onOpenImage: onOpenImage,
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CollapsibleTimelineRow extends StatefulWidget {
  const _CollapsibleTimelineRow({required this.entry});

  final TimelineEntry entry;

  @override
  State<_CollapsibleTimelineRow> createState() =>
      _CollapsibleTimelineRowState();
}

class _CollapsibleTimelineRowState extends State<_CollapsibleTimelineRow> {
  late bool _expanded = widget.entry.kind == TimelineKind.plan;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final title = entry.title.trim().isEmpty ? '思考过程' : entry.title.trim();
    final text = entry.text.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(5),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 3),
            child: Row(
              children: [
                Icon(
                  entry.kind == TimelineKind.plan
                      ? Icons.pending_outlined
                      : Icons.search,
                  size: 22,
                  color: codexMuted,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(
                      context,
                    ).textTheme.titleSmall?.copyWith(color: codexMuted),
                  ),
                ),
                Icon(
                  _expanded
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                  size: 24,
                  color: codexMuted,
                ),
              ],
            ),
          ),
        ),
        if (_expanded && text.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(35, 2, 8, 5),
            child: SelectableText(
              text,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: codexMuted, height: 1.35),
            ),
          ),
      ],
    );
  }
}

class _CommandTimelineCard extends StatefulWidget {
  const _CommandTimelineCard({required this.entry});

  final TimelineEntry entry;

  @override
  State<_CommandTimelineCard> createState() => _CommandTimelineCardState();
}

class _CommandTimelineCardState extends State<_CommandTimelineCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final status = _commandStatus(entry.status);
    return Material(
      color: codexRaised,
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: codexBorder),
        borderRadius: BorderRadius.circular(7),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(11, 9, 9, 9),
              child: Row(
                children: [
                  const Icon(Icons.terminal, size: 20),
                  const SizedBox(width: 9),
                  const Expanded(
                    child: Text(
                      '运行了命令',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  if (status != null)
                    Text(
                      status.label,
                      style: TextStyle(color: status.color, fontSize: 14),
                    ),
                  const SizedBox(width: 8),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 23,
                    color: codexMuted,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            if (entry.command.isNotEmpty) _CommandOutputBlock(entry.command),
            if (entry.output.isNotEmpty) ...[
              if (entry.command.isNotEmpty)
                const Divider(height: 1, color: codexBorder),
              _CommandOutputBlock(entry.output),
            ],
            if (entry.command.isEmpty && entry.output.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(11, 8, 11, 10),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('未提供命令内容', style: TextStyle(color: codexMuted)),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _CommandOutputBlock extends StatelessWidget {
  const _CommandOutputBlock(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    constraints: const BoxConstraints(maxHeight: 340),
    color: codexBackground,
    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SelectableText(
        text,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          color: codexText,
          letterSpacing: 0,
        ),
      ),
    ),
  );
}

class _ImageTimelineCard extends StatelessWidget {
  const _ImageTimelineCard({
    required this.entry,
    required this.path,
    required this.loading,
    required this.onOpenImage,
  });

  final TimelineEntry entry;
  final String path;
  final bool loading;
  final _OpenRemoteImage onOpenImage;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: codexRaised,
      borderRadius: BorderRadius.circular(7),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: loading ? null : () => onOpenImage(path),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 11, 8, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.visibility, size: 23, color: codexText),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      '查看了图片',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  loading
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : IconButton(
                          tooltip: '查看图片',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => onOpenImage(path),
                          icon: const Icon(Icons.visibility, size: 23),
                        ),
                ],
              ),
              const SizedBox(height: 8),
              SelectableText(
                path,
                maxLines: 1,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: codexMuted,
                  letterSpacing: 0,
                ),
              ),
              if (entry.attachments.isNotEmpty) ...[
                const SizedBox(height: 7),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final attachment in entry.attachments)
                      _AttachmentChip(
                        attachment: attachment,
                        loading: false,
                        onOpenImage: onOpenImage,
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _CommandStatus {
  const _CommandStatus(this.label, this.color);

  final String label;
  final Color color;
}

_CommandStatus? _commandStatus(String raw) {
  return switch (raw.trim().toLowerCase()) {
    'completed' ||
    'complete' ||
    'done' => const _CommandStatus('完成', codexGreen),
    'failed' || 'error' => const _CommandStatus('失败', codexRed),
    'declined' || 'rejected' => const _CommandStatus('已拒绝', codexRed),
    'inprogress' ||
    'in_progress' ||
    'running' ||
    'active' => const _CommandStatus('运行中', codexAmber),
    _ => null,
  };
}

class _MarkdownMessage extends StatelessWidget {
  const _MarkdownMessage(this.text, {required this.onOpenRemoteFile});

  final String text;
  final Future<void> Function(String path) onOpenRemoteFile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = MarkdownStyleSheet.fromTheme(theme);
    return MarkdownBody(
      data: markdownWithVisibleLinkDestinations(text),
      selectable: true,
      softLineBreak: true,
      styleSheet: base.copyWith(
        a: const TextStyle(
          color: codexBlue,
          decoration: TextDecoration.underline,
          decorationColor: codexBlue,
          letterSpacing: 0,
        ),
        p: theme.textTheme.bodyMedium?.copyWith(height: 1.35),
        code: theme.textTheme.bodySmall?.copyWith(
          fontFamily: 'monospace',
          color: codexText,
          backgroundColor: codexBackground,
          letterSpacing: 0,
        ),
        codeblockPadding: const EdgeInsets.all(9),
        codeblockDecoration: BoxDecoration(
          color: codexBackground,
          border: Border.all(color: codexBorder),
          borderRadius: BorderRadius.circular(5),
        ),
        blockquotePadding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
        blockquoteDecoration: const BoxDecoration(
          border: Border(left: BorderSide(color: codexAmber, width: 3)),
        ),
        tableBorder: TableBorder.all(color: codexBorder),
      ),
      imageBuilder: (uri, title, alt) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.image_outlined, size: 17, color: codexMuted),
          const SizedBox(width: 5),
          Flexible(
            child: Text(alt?.trim().isNotEmpty == true ? alt! : uri.toString()),
          ),
        ],
      ),
      onTapLink: (_, href, _) {
        if (href == null) return;
        final remotePath = remoteFilePathFromLink(href);
        if (remotePath != null) {
          unawaited(onOpenRemoteFile(remotePath));
        } else {
          unawaited(_confirmAndOpenLink(context, href));
        }
      },
    );
  }
}

class _BoundedSelectableText extends StatelessWidget {
  const _BoundedSelectableText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxHeight: 260),
    child: SingleChildScrollView(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SelectableText(
          text,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            color: codexMuted,
            letterSpacing: 0,
          ),
        ),
      ),
    ),
  );
}

class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({
    required this.attachment,
    required this.loading,
    required this.onOpenImage,
  });

  final MessageAttachment attachment;
  final bool loading;
  final _OpenRemoteImage onOpenImage;

  @override
  Widget build(BuildContext context) {
    final image =
        attachment.mimeType.startsWith('image/') &&
        attachment.remotePath.startsWith('/');
    final avatar = loading
        ? const SizedBox.square(
            dimension: 15,
            child: CircularProgressIndicator(strokeWidth: 1.8),
          )
        : Icon(image ? Icons.image_outlined : Icons.attach_file, size: 16);
    if (!image) {
      return Chip(
        avatar: avatar,
        label: Text(attachment.name),
        visualDensity: VisualDensity.compact,
      );
    }
    return ActionChip(
      avatar: avatar,
      label: Text(attachment.name),
      visualDensity: VisualDensity.compact,
      onPressed: loading
          ? null
          : () => onOpenImage(attachment.remotePath, fileName: attachment.name),
    );
  }
}

class _RemoteImageDialog extends StatefulWidget {
  const _RemoteImageDialog({
    required this.path,
    required this.fileName,
    required this.bytes,
    required this.onSave,
  });

  final String path;
  final String? fileName;
  final Uint8List bytes;
  final Future<void> Function() onSave;

  @override
  State<_RemoteImageDialog> createState() => _RemoteImageDialogState();
}

class _RemoteImageDialogState extends State<_RemoteImageDialog> {
  bool _saving = false;

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: Colors.black,
    insetPadding: const EdgeInsets.all(10),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    clipBehavior: Clip.antiAlias,
    child: SizedBox(
      width: double.maxFinite,
      height: MediaQuery.sizeOf(context).height - 20,
      child: Column(
        children: [
          Row(
            children: [
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  widget.fileName?.trim().isNotEmpty == true
                      ? widget.fileName!
                      : imageFileName(widget.path),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
              IconButton(
                tooltip: '关闭图片',
                onPressed: _saving ? null : () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close, color: Colors.white),
              ),
            ],
          ),
          Expanded(
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    onLongPress: _saving ? null : _requestSave,
                    child: InteractiveViewer(
                      minScale: 0.5,
                      maxScale: 5,
                      child: Center(
                        child: Image(
                          image: ResizeImage.resizeIfNeeded(
                            2048,
                            2048,
                            MemoryImage(widget.bytes),
                          ),
                          fit: BoxFit.contain,
                          gaplessPlayback: true,
                          errorBuilder: (_, _, _) => const Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.broken_image_outlined,
                                color: codexMuted,
                                size: 36,
                              ),
                              SizedBox(height: 8),
                              Text(
                                '文件不是可显示的图片',
                                style: TextStyle(color: codexMuted),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (_saving)
                  const Material(
                    color: codexRaised,
                    borderRadius: BorderRadius.all(Radius.circular(7)),
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      child: SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Future<void> _requestSave() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('保存图片'),
        content: const Text('保存到手机？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _saving = true);
    await widget.onSave();
    if (mounted) setState(() => _saving = false);
  }
}

Future<void> _confirmAndOpenLink(BuildContext context, String value) async {
  final uri = Uri.tryParse(value.trim());
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    _showTransientNotice(context, '只支持打开 HTTP 或 HTTPS 链接');
    return;
  }
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('打开链接'),
      content: SelectableText(uri.toString()),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('打开'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  try {
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && context.mounted) _showTransientNotice(context, '无法打开链接');
  } catch (error) {
    if (context.mounted) {
      _showTransientNotice(context, _displayError(error, '无法打开链接'));
    }
  }
}

void _showTransientNotice(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

String _displayError(Object error, String fallback) {
  final message = error
      .toString()
      .replaceFirst(RegExp(r'^[^:]+:\s*'), '')
      .trim();
  return message.isEmpty ? fallback : message;
}

Future<Uint8List> _readPickedFile(
  PlatformFile file, {
  required int maxBytes,
}) async {
  final sizeError = maxBytes == maxInlineTextAttachmentBytes
      ? '文本附件不能超过 512 KB'
      : '附件不能超过 20 MB';
  if (file.size > maxBytes) throw StateError(sizeError);
  final direct = file.bytes;
  if (direct != null) {
    if (direct.isEmpty) throw StateError('附件不能为空');
    if (direct.length > maxBytes) throw StateError(sizeError);
    return direct;
  }
  final stream = file.readStream;
  if (stream == null) throw StateError('无法读取附件');
  final output = BytesBuilder(copy: false);
  var total = 0;
  await for (final chunk in stream) {
    total += chunk.length;
    if (total > maxBytes) throw StateError(sizeError);
    output.add(chunk);
  }
  final bytes = output.takeBytes();
  if (bytes.isEmpty) throw StateError('附件不能为空');
  return bytes;
}

class _ChangeLine extends StatelessWidget {
  const _ChangeLine({required this.change});

  final FileChange change;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const Icon(Icons.insert_drive_file_outlined, size: 16, color: codexAmber),
      const SizedBox(width: 6),
      Expanded(
        child: Text(change.path, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      Text(
        '+${change.additions} -${change.deletions}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ],
  );
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    constraints: const BoxConstraints(maxHeight: 260),
    padding: const EdgeInsets.all(9),
    decoration: BoxDecoration(
      color: codexBackground,
      borderRadius: BorderRadius.circular(5),
      border: Border.all(color: codexBorder),
    ),
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SelectableText(
        text,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          color: codexMuted,
          letterSpacing: 0,
        ),
      ),
    ),
  );
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final active = switch (status.toLowerCase()) {
      'active' || 'inprogress' || 'in_progress' || 'running' => true,
      _ => false,
    };
    return active
        ? const SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(strokeWidth: 1.7),
          )
        : Icon(
            status.toLowerCase().contains('error')
                ? Icons.error_outline
                : Icons.check_circle_outline,
            size: 15,
            color: status.toLowerCase().contains('error')
                ? codexRed
                : codexGreen,
          );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.state,
    required this.controller,
    required this.focusNode,
    required this.attachmentBusy,
    required this.onChanged,
    required this.onAttachImage,
    required this.onAttachFile,
    required this.onRemoveAttachment,
    required this.onSend,
    required this.onStop,
    required this.onModelTap,
    required this.onPermissionTap,
    required this.onAction,
    required this.onEditGoal,
    required this.onToggleGoal,
    required this.onClearGoal,
  });

  final AppUiState state;
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool attachmentBusy;
  final ValueChanged<String> onChanged;
  final VoidCallback onAttachImage;
  final VoidCallback onAttachFile;
  final ValueChanged<String> onRemoveAttachment;
  final VoidCallback onSend;
  final Future<void> Function() onStop;
  final VoidCallback onModelTap;
  final Future<void> Function() onPermissionTap;
  final Future<void> Function(String action) onAction;
  final Future<void> Function() onEditGoal;
  final Future<void> Function() onToggleGoal;
  final Future<void> Function() onClearGoal;

  @override
  Widget build(BuildContext context) => AnimatedPadding(
    duration: const Duration(milliseconds: 170),
    curve: Curves.easeOutCubic,
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: Material(
      color: codexBackground,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 5, 8, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (state.activeGoal != null) ...[
                _ThreadGoalBar(
                  goal: state.activeGoal!,
                  mutationInProgress: state.submitting,
                  onEdit: onEditGoal,
                  onTogglePause: onToggleGoal,
                  onDelete: onClearGoal,
                ),
                const SizedBox(height: 6),
              ],
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: const Color(0xFF1B1B1B),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: codexBorder),
                ),
                padding: const EdgeInsets.fromLTRB(10, 8, 7, 5),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (state.attachments.isNotEmpty) ...[
                      SizedBox(
                        height: 34,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: state.attachments.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 6),
                          itemBuilder: (context, index) {
                            final attachment = state.attachments[index];
                            return InputChip(
                              key: ValueKey(attachment.remotePath),
                              avatar: Icon(
                                attachment.mimeType.startsWith('image/')
                                    ? Icons.image_outlined
                                    : Icons.description_outlined,
                                size: 16,
                              ),
                              label: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 150,
                                ),
                                child: Text(
                                  attachment.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              onDeleted: attachmentBusy || state.submitting
                                  ? null
                                  : () => onRemoveAttachment(
                                      attachment.remotePath,
                                    ),
                              visualDensity: VisualDensity.compact,
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 5),
                    ],
                    if (attachmentBusy) ...[
                      const LinearProgressIndicator(minHeight: 2),
                      const SizedBox(height: 6),
                    ],
                    TextField(
                      controller: controller,
                      focusNode: focusNode,
                      enabled: !state.submitting,
                      minLines: 3,
                      maxLines: 6,
                      textInputAction: TextInputAction.newline,
                      onChanged: onChanged,
                      decoration: InputDecoration(
                        hintText: state.running ? '提出后续变更要求' : '描述任务',
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        PopupMenuButton<String>(
                          tooltip: '添加附件',
                          enabled:
                              !state.loading &&
                              !state.submitting &&
                              !attachmentBusy,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(
                            width: 36,
                            height: 36,
                          ),
                          onSelected: (value) {
                            if (value == 'image') {
                              onAttachImage();
                            } else if (value == 'file') {
                              onAttachFile();
                            }
                          },
                          itemBuilder: (context) => const [
                            PopupMenuItem(
                              value: 'image',
                              child: ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(Icons.image_outlined),
                                title: Text('上传图片'),
                              ),
                            ),
                            PopupMenuItem(
                              value: 'file',
                              child: ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(Icons.folder_open_outlined),
                                title: Text('上传文件'),
                              ),
                            ),
                          ],
                          icon: const Icon(Icons.add, size: 23),
                        ),
                        PopupMenuButton<String>(
                          tooltip: '会话操作',
                          enabled: !state.loading && !attachmentBusy,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(
                            width: 36,
                            height: 36,
                          ),
                          onSelected: (value) => unawaited(onAction(value)),
                          itemBuilder: (context) => [
                            if (state.activeAgentCapabilities.threadGoals)
                              PopupMenuItem(
                                value: 'goal',
                                enabled: !state.submitting,
                                child: Text(
                                  state.activeGoal == null ? '设置目标' : '编辑目标',
                                ),
                              ),
                            if (state.activeGoal != null &&
                                (state.activeGoal!.status ==
                                        ThreadGoalStatus.active ||
                                    state.activeGoal!.status ==
                                        ThreadGoalStatus.paused))
                              PopupMenuItem(
                                value: 'toggle-goal',
                                enabled: !state.submitting,
                                child: Text(
                                  state.activeGoal!.status ==
                                          ThreadGoalStatus.paused
                                      ? '继续目标'
                                      : '暂停目标',
                                ),
                              ),
                            if (state.activeGoal != null)
                              PopupMenuItem(
                                value: 'clear-goal',
                                enabled: !state.submitting,
                                child: const Text('删除目标'),
                              ),
                            if (state.activeAgentCapabilities.compactThread)
                              PopupMenuItem(
                                value: 'compact',
                                enabled:
                                    !state.loading &&
                                    !state.submitting &&
                                    !state.running,
                                child: const Text('压缩会话'),
                              ),
                          ],
                          icon: const Icon(Icons.more_vert, size: 20),
                        ),
                        if (state.activeAgentCapabilities.approvals)
                          TextButton.icon(
                            onPressed: state.submitting
                                ? null
                                : () => unawaited(onPermissionTap()),
                            icon: Icon(
                              _approvalModeIcon(state.approvalMode),
                              size: 17,
                            ),
                            label: const Text('权限'),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                              ),
                              minimumSize: const Size(0, 36),
                            ),
                          ),
                        const Spacer(),
                        _ContextUsageButton(usage: state.tokenUsage),
                        if (state.activeAgentCapabilities.models) ...[
                          const SizedBox(width: 6),
                          Flexible(
                            child: InkWell(
                              onTap: state.loading ? null : onModelTap,
                              borderRadius: BorderRadius.circular(5),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 7,
                                ),
                                child: Text(
                                  modelSelectionLabel(
                                    state.models,
                                    state.selectedModel,
                                    state.selectedEffort,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.end,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(width: 4),
                        SizedBox.square(
                          dimension: 42,
                          child: state.running
                              ? IconButton.filled(
                                  tooltip: '停止',
                                  onPressed: onStop,
                                  style: IconButton.styleFrom(
                                    backgroundColor: codexRed,
                                    foregroundColor: Colors.white,
                                    shape: const CircleBorder(),
                                    minimumSize: const Size.square(42),
                                    padding: EdgeInsets.zero,
                                  ),
                                  icon: const Icon(Icons.stop_rounded),
                                )
                              : IconButton.filled(
                                  tooltip: '发送',
                                  onPressed:
                                      state.submitting ||
                                          state.loading ||
                                          attachmentBusy ||
                                          (controller.text.trim().isEmpty &&
                                              state.attachments.isEmpty)
                                      ? null
                                      : onSend,
                                  style: IconButton.styleFrom(
                                    shape: const CircleBorder(),
                                    minimumSize: const Size.square(42),
                                    padding: EdgeInsets.zero,
                                  ),
                                  icon: const Icon(Icons.arrow_upward_rounded),
                                ),
                        ),
                      ],
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

class _ThreadGoalBar extends StatelessWidget {
  const _ThreadGoalBar({
    required this.goal,
    required this.mutationInProgress,
    required this.onEdit,
    required this.onTogglePause,
    required this.onDelete,
  });

  final ThreadGoal goal;
  final bool mutationInProgress;
  final Future<void> Function() onEdit;
  final Future<void> Function() onTogglePause;
  final Future<void> Function() onDelete;

  @override
  Widget build(BuildContext context) {
    final canToggle =
        goal.status == ThreadGoalStatus.active ||
        goal.status == ThreadGoalStatus.paused;
    final paused = goal.status == ThreadGoalStatus.paused;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 6, 3, 6),
      decoration: BoxDecoration(
        color: codexRaised,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: codexBorder),
      ),
      child: Row(
        children: [
          Icon(
            Icons.track_changes_outlined,
            size: 18,
            color: _goalStatusColor(goal.status),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  goal.objective,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  _goalSummary(goal),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: _goalStatusColor(goal.status),
                  ),
                ),
              ],
            ),
          ),
          if (mutationInProgress)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: SizedBox.square(
                dimension: 17,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else ...[
            IconButton(
              tooltip: '编辑目标',
              visualDensity: VisualDensity.compact,
              onPressed: () => unawaited(onEdit()),
              icon: const Icon(Icons.edit_outlined, size: 18),
            ),
            if (canToggle)
              IconButton(
                tooltip: paused ? '继续目标' : '暂停目标',
                visualDensity: VisualDensity.compact,
                onPressed: () => unawaited(onTogglePause()),
                icon: Icon(
                  paused
                      ? Icons.play_circle_outline
                      : Icons.pause_circle_outline,
                  size: 19,
                ),
              ),
            IconButton(
              tooltip: '删除目标',
              visualDensity: VisualDensity.compact,
              onPressed: () => unawaited(onDelete()),
              icon: const Icon(Icons.delete_outline, size: 18),
            ),
          ],
        ],
      ),
    );
  }
}

IconData _approvalModeIcon(ApprovalMode mode) => switch (mode) {
  ApprovalMode.requestApproval => Icons.shield_outlined,
  ApprovalMode.autoApprove => Icons.verified_user_outlined,
  ApprovalMode.fullAccess => Icons.warning_amber_rounded,
};

String _goalSummary(ThreadGoal goal) {
  final values = <String>[_goalStatusLabel(goal.status)];
  if (goal.timeUsedSeconds > 0) {
    final duration = Duration(seconds: goal.timeUsedSeconds);
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    values.add(hours > 0 ? '$hours时$minutes分' : '$minutes分钟');
  }
  if (goal.tokensUsed > 0) {
    values.add('${_formatTokens(goal.tokensUsed)} tokens');
  }
  return values.join(' · ');
}

String _goalStatusLabel(ThreadGoalStatus status) => switch (status) {
  ThreadGoalStatus.active => '进行中',
  ThreadGoalStatus.paused => '已暂停',
  ThreadGoalStatus.blocked => '已阻塞',
  ThreadGoalStatus.usageLimited => '用量受限',
  ThreadGoalStatus.budgetLimited => '预算受限',
  ThreadGoalStatus.complete => '已完成',
  ThreadGoalStatus.unknown => '未知状态',
};

Color _goalStatusColor(ThreadGoalStatus status) => switch (status) {
  ThreadGoalStatus.active => codexGreen,
  ThreadGoalStatus.paused => codexAmber,
  ThreadGoalStatus.blocked ||
  ThreadGoalStatus.usageLimited ||
  ThreadGoalStatus.budgetLimited => codexRed,
  ThreadGoalStatus.complete => codexBlue,
  ThreadGoalStatus.unknown => codexMuted,
};

class _ContextUsageButton extends StatelessWidget {
  const _ContextUsageButton({required this.usage});

  final TokenUsage? usage;

  @override
  Widget build(BuildContext context) {
    final window = usage?.modelContextWindow ?? 0;
    // Codex reports the latest request's context usage in `last`; `total` is
    // cumulative thread accounting and would make the ring drift upward.
    final used = usage?.last.totalTokens ?? 0;
    final ratio = window > 0 ? (used / window).clamp(0.0, 1.0) : 0.0;
    final known = window > 0;
    final remaining = known ? (window - used).clamp(0, window) : 0;
    return PopupMenuButton<void>(
      tooltip: '上下文用量',
      padding: EdgeInsets.zero,
      itemBuilder: (context) => [
        PopupMenuItem<void>(
          enabled: false,
          child: SizedBox(
            width: 220,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('背景信息窗口'),
                const SizedBox(height: 6),
                Text(
                  known
                      ? '已用 ${(ratio * 100).floor()}%  ·  '
                            '${_formatTokens(used)} / ${_formatTokens(window)}'
                      : '等待服务器返回上下文用量',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (known)
                  Text(
                    '剩余 ${100 - (ratio * 100).floor()}%  ·  '
                    '${_formatTokens(remaining)} tokens',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
        ),
      ],
      child: SizedBox.square(
        dimension: 32,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CircularProgressIndicator(
              value: known ? ratio : 0,
              strokeWidth: 2.5,
              constraints: const BoxConstraints.tightFor(width: 19, height: 19),
              backgroundColor: codexBorder,
              color: ratio > .85 ? codexRed : codexAmber,
            ),
          ],
        ),
      ),
    );
  }
}

String _formatTokens(int value) {
  final safe = value < 0 ? 0 : value;
  if (safe >= 1000000) {
    final scaled = safe / 1000000;
    return scaled >= 100
        ? '${scaled.floor()}m'
        : '${scaled.toStringAsFixed(1)}m';
  }
  if (safe >= 1000) {
    final scaled = safe / 1000;
    return scaled >= 100
        ? '${scaled.floor()}k'
        : '${scaled.toStringAsFixed(1)}k';
  }
  return safe.toString();
}
