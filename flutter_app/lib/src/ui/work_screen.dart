import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/app_controller.dart';
import '../domain/models.dart';
import '../platform/local_file_exporter.dart';
import 'diagnostic_log_sheet.dart';
import 'markdown_links.dart';
import 'model_selection_presentation.dart';
import 'sub_agent_presentation.dart';
import 'theme.dart';
import 'work_content.dart';

typedef _OpenRemoteImage =
    Future<void> Function(String path, {String? fileName});

// Keep the Work page visually aligned with the original Compose screen
// without changing the palette used by the newer server and settings pages.
const _workSurface = Color(0xFF1F1F1F);
const _workRaised = Color(0xFF272727);
const _workBorder = Color(0xFF373737);
const _workGreen = Color(0xFF68C77B);
const _workLink = Color(0xFF64B5F6);
const _workAmber = Color(0xFFE5B567);

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
  bool _followOutput = true;
  bool _userDraggingTimeline = false;
  bool _canScrollForward = false;
  bool _refreshing = false;
  bool _preparingAttachments = false;
  String? _imageLoadingPath;
  String? _fileDownloadPath;
  bool _savingImage = false;
  String? _syncedThreadId;
  int? _syncedComposerClearNonce;
  int? _timelineSignature;
  double _lastBottomInset = 0;
  String? _viewportThreadId;
  bool _initialBottomPending = true;
  bool _bottomAnchorScheduled = false;
  final GlobalKey _paginationViewportKey = GlobalKey();
  final GlobalKey _transcriptItemsSliverKey = GlobalKey();
  double _transcriptBottomGap = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
    _scrollController.dispose();
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
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
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
            key: const Key('work-action-menu'),
            tooltip: '会话操作',
            enabled: !state.loading && !state.attachmentUploading,
            color: _workSurface,
            surfaceTintColor: Colors.transparent,
            constraints: const BoxConstraints(minWidth: 196, maxWidth: 280),
            menuPadding: const EdgeInsets.symmetric(vertical: 8),
            position: PopupMenuPosition.under,
            offset: const Offset(0, 8),
            popUpAnimationStyle: AnimationStyle.noAnimation,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
            ),
            onSelected: (value) =>
                unawaited(_handleWorkAction(value, state, controller)),
            itemBuilder: (context) => [
              if (state.activeAgentCapabilities.renameThread)
                PopupMenuItem(
                  value: 'rename',
                  enabled: !state.submitting,
                  height: 48,
                  padding: EdgeInsets.zero,
                  child: const _WorkPopupMenuRow(
                    icon: Icons.edit,
                    label: '重命名',
                  ),
                ),
              if (state.activeAgentCapabilities.archiveThread &&
                  state.screen != AppScreen.agentWork)
                PopupMenuItem(
                  value: 'archive',
                  enabled: !state.submitting && !state.running,
                  height: 48,
                  padding: EdgeInsets.zero,
                  child: const _WorkPopupMenuRow(
                    icon: Icons.archive,
                    label: '归档',
                  ),
                ),
              if (state.activeAgentCapabilities.threadGoals)
                PopupMenuItem(
                  value: 'goal',
                  enabled: !state.submitting,
                  height: 48,
                  padding: EdgeInsets.zero,
                  child: _WorkPopupMenuRow(
                    icon: Icons.track_changes,
                    label: state.activeGoal == null ? '设置目标' : '编辑目标',
                  ),
                ),
              if (state.debugModeEnabled) const PopupMenuDivider(height: 1),
              if (state.debugModeEnabled)
                const PopupMenuItem(
                  value: 'debug-logs',
                  height: 48,
                  padding: EdgeInsets.zero,
                  child: _WorkPopupMenuRow(
                    icon: Icons.bug_report,
                    label: '添加崩溃 / Debug 日志',
                  ),
                ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _Transcript(
              state: state,
              controller: _scrollController,
              onOpenImage: (path, {fileName}) =>
                  _openRemoteImage(path, fileName: fileName),
              imageLoadingPath: _imageLoadingPath,
              onOpenRemoteFile: _downloadRemoteFile,
              onOpenDiff: _openDiff,
              onOpenSubAgent: controller.openSubAgentThread,
              onRefresh:
                  state.olderTurnsCursor == null ||
                      state.loading ||
                      state.olderTurnsLoading ||
                      _refreshing
                  ? null
                  : () => _loadOlder(controller),
              onScrollNotification: _onTranscriptScroll,
              initialBottomPending: _initialBottomPending,
              paginationViewportKey: _paginationViewportKey,
              transcriptItemsSliverKey: _transcriptItemsSliverKey,
              bottomGap: _transcriptBottomGap,
              onRefreshStart: _preparePagination,
              showJumpToBottom:
                  state.timeline.isNotEmpty &&
                  !_followOutput &&
                  _canScrollForward,
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
            onTakePhoto: _takePhoto,
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
            onOpenSubAgent: controller.openSubAgentThread,
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
      case 'debug-logs':
        await _addDebugLogs(controller);
    }
  }

  Future<void> _addDebugLogs(AppController controller) async {
    try {
      final availableSlots =
          maxPendingAttachmentCount -
          ref.read(appControllerProvider).attachments.length;
      if (availableSlots <= 0) {
        _showNotice(context, '输入框最多保留 $maxPendingAttachmentCount 个附件');
        return;
      }
      final ids = await pickDiagnosticLogIds(
        context,
        logger: controller.diagnosticLogger,
        preferLatestCrash: true,
        title: '添加崩溃 / Debug 日志',
        maxSelection: availableSlots,
      );
      if (ids == null || ids.isEmpty || !mounted) return;
      final before = ref.read(appControllerProvider).attachments.length;
      await controller.addDebugLogAttachments(ids);
      if (!mounted) return;
      final after = ref.read(appControllerProvider).attachments.length;
      if (after > before) {
        _showNotice(context, '日志已添加到输入框，请点击发送');
      }
    } catch (error) {
      if (mounted) _showNotice(context, _displayError(error, '添加 Debug 日志失败'));
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

  Future<void> _takePhoto() async {
    if (_preparingAttachments ||
        ref.read(appControllerProvider).attachmentUploading) {
      return;
    }
    if (ref.read(appControllerProvider).attachments.length >=
        maxPendingAttachmentCount) {
      _showNotice(context, '输入框最多保留 $maxPendingAttachmentCount 个附件');
      return;
    }
    try {
      setState(() => _preparingAttachments = true);
      final photo = await ImagePicker().pickImage(source: ImageSource.camera);
      if (photo == null || !mounted) return;
      final upload = await cameraPhotoAttachment(photo);
      await ref.read(appControllerProvider.notifier).uploadAttachments(
        <LocalAttachmentUpload>[upload],
      );
    } catch (error) {
      if (mounted) _showNotice(context, _displayError(error, '拍照失败'));
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

  void _syncViewport(AppUiState state, double bottomInset) {
    final threadId = state.activeThread?.id;
    final threadChanged = threadId != _viewportThreadId;
    if (threadChanged) {
      _viewportThreadId = threadId;
      _timelineSignature = null;
      _followOutput = true;
      _userDraggingTimeline = false;
      _canScrollForward = false;
      _initialBottomPending = threadId != null;
      _transcriptBottomGap = 0;
    }
    final last = state.timeline.isEmpty ? null : state.timeline.last;
    final signature = Object.hash(
      threadId,
      state.timeline.length,
      last?.id,
      last?.text.length,
      last?.output.length,
      state.aggregateDiff.length,
      state.running,
      state.loading,
      state.turnTiming?.startedAtMillis,
      state.turnTiming?.completedAtMillis,
      state.turnTiming?.stopped,
    );
    final transcriptChanged = signature != _timelineSignature;
    final viewportChanged = bottomInset != _lastBottomInset;
    if (!threadChanged && viewportChanged) {
      final projectedGap =
          _transcriptBottomGap - (bottomInset - _lastBottomInset);
      _transcriptBottomGap = projectedGap > 0 ? projectedGap : 0;
    }
    _timelineSignature = signature;
    _lastBottomInset = bottomInset;
    if ((!transcriptChanged && !viewportChanged && !threadChanged) ||
        _refreshing ||
        state.olderTurnsLoading) {
      return;
    }
    _scheduleBottomAnchor(threadId);
  }

  void _scheduleBottomAnchor(String? threadId) {
    if (_bottomAnchorScheduled || threadId == null) return;
    _bottomAnchorScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bottomAnchorScheduled = false;
      if (!mounted || threadId != _viewportThreadId) return;
      if (!_scrollController.hasClients ||
          !_scrollController.position.hasContentDimensions) {
        _scheduleBottomAnchor(threadId);
        return;
      }
      final current = ref.read(appControllerProvider);
      if (current.activeThread?.id != threadId) return;
      if (current.loading && current.timeline.isEmpty) return;
      final position = _scrollController.position;
      final itemsRenderObject = _transcriptItemsSliverKey.currentContext
          ?.findRenderObject();
      final itemsExtent = itemsRenderObject is RenderSliver
          ? itemsRenderObject.geometry?.scrollExtent
          : null;
      if (itemsExtent != null) {
        final targetGap = position.viewportDimension > itemsExtent
            ? position.viewportDimension - itemsExtent
            : 0.0;
        if ((targetGap - _transcriptBottomGap).abs() > 0.5) {
          setState(() => _transcriptBottomGap = targetGap);
          _scheduleBottomAnchor(threadId);
          return;
        }
      }
      if (!_followOutput && !_initialBottomPending) return;
      if ((position.pixels - _transcriptBottomOffset).abs() > 0.5) {
        position.jumpTo(_transcriptBottomOffset);
      }
      if (_initialBottomPending) {
        setState(() {
          _initialBottomPending = false;
          _followOutput = true;
          _canScrollForward = false;
        });
      }
    });
  }

  void _onTranscriptScroll(ScrollNotification notification) {
    var userDragging = _userDraggingTimeline;
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      userDragging = true;
    } else if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null) {
      userDragging = true;
    }

    final canScrollForward = notification.metrics.extentAfter > 0.5;
    final preserveFollowState = notification.metrics.outOfRange || _refreshing;
    var followOutput = preserveFollowState
        ? _followOutput
        : updatedFollowOutput(
            current: _followOutput,
            userDragging: userDragging,
            canScrollForward: canScrollForward,
          );
    if (notification is ScrollEndNotification ||
        notification is UserScrollNotification &&
            notification.direction == ScrollDirection.idle) {
      userDragging = false;
      if (!preserveFollowState) {
        followOutput = updatedFollowOutput(
          current: followOutput,
          userDragging: false,
          canScrollForward: canScrollForward,
        );
      }
    }
    if (followOutput == _followOutput &&
        userDragging == _userDraggingTimeline &&
        canScrollForward == _canScrollForward) {
      return;
    }
    void applyScrollState() {
      if (!mounted) return;
      setState(() {
        _followOutput = followOutput;
        _userDraggingTimeline = userDragging;
        _canScrollForward = canScrollForward;
      });
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => applyScrollState());
    } else {
      applyScrollState();
    }
  }

  Future<void> _loadOlder(AppController controller) async {
    if (_refreshing) return;
    setState(() {
      _refreshing = true;
      _followOutput = false;
    });
    await WidgetsBinding.instance.endOfFrame;
    try {
      await controller.loadOlderTurns();
      if (!mounted) return;
      await WidgetsBinding.instance.endOfFrame;
    } finally {
      if (mounted) {
        setState(() {
          _refreshing = false;
        });
      }
    }
  }

  void _preparePagination() {
    if (_refreshing) return;
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final overscroll = (position.minScrollExtent - position.pixels)
        .clamp(0.0, double.infinity)
        .toDouble();
    if (overscroll > 0.5) {
      position.jumpTo(position.minScrollExtent);
    }
  }

  void _jumpToBottom() {
    if (!_scrollController.hasClients) return;
    setState(() => _followOutput = true);
    unawaited(
      _scrollController.animateTo(
        _transcriptBottomOffset,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  void _openDiff(FileChange change) {
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (context) => _DiffScreen(change: change),
        ),
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

Future<LocalAttachmentUpload> cameraPhotoAttachment(XFile photo) async {
  final length = await photo.length();
  if (length <= 0) throw StateError('照片为空');
  if (length > maxLocalAttachmentBytes) {
    throw StateError('照片不能超过 20 MB');
  }
  final bytes = await photo.readAsBytes();
  if (bytes.isEmpty) throw StateError('照片为空');
  return LocalAttachmentUpload(
    name: photo.name,
    bytes: bytes,
    mimeType: attachmentMimeType(photo.name, forceImage: true),
  );
}

bool shouldDismissWorkKeyboard(AppLifecycleState state) =>
    state != AppLifecycleState.resumed;

bool updatedFollowOutput({
  required bool current,
  required bool userDragging,
  required bool canScrollForward,
}) {
  if (!canScrollForward) return true;
  if (userDragging) return false;
  return current;
}

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
    required this.onOpenDiff,
    required this.onOpenSubAgent,
    required this.onRefresh,
    required this.onRefreshStart,
    required this.onScrollNotification,
    required this.initialBottomPending,
    required this.paginationViewportKey,
    required this.transcriptItemsSliverKey,
    required this.bottomGap,
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
  final ValueChanged<FileChange> onOpenDiff;
  final void Function(String threadId, String agentName) onOpenSubAgent;
  final Future<void> Function()? onRefresh;
  final VoidCallback onRefreshStart;
  final ValueChanged<ScrollNotification> onScrollNotification;
  final bool initialBottomPending;
  final GlobalKey paginationViewportKey;
  final GlobalKey transcriptItemsSliverKey;
  final double bottomGap;
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
    final contentItems = <Widget>[];
    final rowKeyCounts = <String, int>{};
    for (final row in rows) {
      final child = switch (row) {
        TimelineEntryRenderRow(:final entry) => _TimelineCard(
          entry: entry,
          onOpenImage: onOpenImage,
          imageLoadingPath: imageLoadingPath,
          onOpenRemoteFile: onOpenRemoteFile,
          onOpenDiff: onOpenDiff,
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
      final baseKey = '${state.activeThread?.id}:${row.stableKey}';
      final occurrence = rowKeyCounts.update(
        baseKey,
        (count) => count + 1,
        ifAbsent: () => 0,
      );
      contentItems.add(
        KeyedSubtree(key: ValueKey('$baseKey:$occurrence'), child: child),
      );
    }
    if (state.aggregateDiff.trim().isNotEmpty) {
      final aggregate = FileChange(
        path: '工作区差异',
        kind: 'diff',
        diff: state.aggregateDiff,
      );
      contentItems.add(
        _AggregateDiffTimelineCard(
          key: const ValueKey('aggregate-diff'),
          change: aggregate,
          onOpen: () => onOpenDiff(aggregate),
        ),
      );
    }
    final threadId = state.activeThread?.id;
    final timing = state.turnTiming?.threadId == threadId
        ? state.turnTiming
        : null;
    final showTiming = state.running || timing?.completedAtMillis != null;
    if (showTiming) {
      contentItems.add(
        _TurnTimingFooter(
          key: const ValueKey('turn-timing-footer'),
          running: state.running,
          timing: timing,
        ),
      );
    }
    contentItems.add(
      const KeyedSubtree(
        key: ValueKey('transcript-tail-spacer'),
        child: SizedBox(height: 6),
      ),
    );
    final reversedItems = contentItems.reversed.toList(growable: false);

    Widget buildItemsSliver(List<Widget> items) {
      final keyToIndex = <Key, int>{
        for (var index = 0; index < items.length; index += 1)
          if (items[index].key != null) items[index].key!: index,
      };
      return SliverPadding(
        key: transcriptItemsSliverKey,
        padding: const EdgeInsets.symmetric(horizontal: 9),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) => Padding(
              padding: EdgeInsets.only(
                top: index == items.length - 1 ? _transcriptVerticalPadding : 0,
                bottom: index == 0 ? 0 : 10,
              ),
              child: items[index],
            ),
            childCount: items.length,
            findChildIndexCallback: (childKey) => keyToIndex[childKey],
          ),
        ),
      );
    }

    Widget buildList(bool refreshVisible) => Scrollbar(
      key: const Key('transcript-scrollbar'),
      controller: controller,
      thumbVisibility: false,
      trackVisibility: false,
      interactive: true,
      thickness: 4,
      radius: const Radius.circular(2),
      child: CustomScrollView(
        key: paginationViewportKey,
        center: _transcriptCenterSliverKey,
        anchor: 1,
        controller: controller,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        slivers: [
          buildItemsSliver(reversedItems),
          SliverToBoxAdapter(child: SizedBox(height: bottomGap)),
          const SliverToBoxAdapter(
            key: _transcriptCenterSliverKey,
            child: SizedBox.shrink(),
          ),
        ],
      ),
    );
    return Stack(
      children: [
        if (entries.isEmpty && !state.loading && !showTiming)
          const Center(child: Text('暂无消息')),
        Positioned.fill(
          child: IgnorePointer(
            ignoring: initialBottomPending,
            child: Opacity(
              opacity: initialBottomPending ? 0 : 1,
              child: NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  onScrollNotification(notification);
                  return false;
                },
                child: _LegacyOlderHistoryRefresh(
                  onRefresh: onRefresh,
                  onRefreshStart: onRefreshStart,
                  refreshing: state.olderTurnsLoading,
                  builder: (context, refreshVisible) =>
                      buildList(refreshVisible),
                ),
              ),
            ),
          ),
        ),
        if (state.loading)
          const Center(
            child: SizedBox.square(
              dimension: 28,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        if (showJumpToBottom)
          Positioned(
            left: 0,
            right: 0,
            bottom: 16,
            child: Material(
              color: _workRaised,
              shape: const CircleBorder(side: BorderSide(color: _workBorder)),
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

const _olderHistoryTriggerExtent = 82.0;
const _transcriptCenterSliverKey = ValueKey<String>('transcript-center-sliver');
const _transcriptBottomOffset = 0.0;
const _olderHistoryIndicatorExtent = 54.0;
const _olderHistoryLoadingExtent = 108.0;
const _transcriptVerticalPadding = 10.0;
const _olderHistoryRetractDuration = Duration(milliseconds: 220);

typedef _OlderHistoryBuilder =
    Widget Function(BuildContext context, bool refreshVisible);

class _LegacyOlderHistoryRefresh extends StatefulWidget {
  const _LegacyOlderHistoryRefresh({
    required this.onRefresh,
    required this.onRefreshStart,
    required this.refreshing,
    required this.builder,
  });

  final Future<void> Function()? onRefresh;
  final VoidCallback onRefreshStart;
  final bool refreshing;
  final _OlderHistoryBuilder builder;

  @override
  State<_LegacyOlderHistoryRefresh> createState() =>
      _LegacyOlderHistoryRefreshState();
}

class _LegacyOlderHistoryRefreshState
    extends State<_LegacyOlderHistoryRefresh> {
  int? _pointer;
  double _pulledExtent = 0;
  bool _armed = false;
  bool _refreshing = false;
  bool _retracting = false;

  bool get _refreshVisible => _refreshing || widget.refreshing;

  void _handlePointerDown(PointerDownEvent event) {
    if (_pointer == null && !_refreshVisible && !_retracting) {
      _pointer = event.pointer;
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (_pointer != event.pointer) return;
    _pointer = null;
    final refresh = widget.onRefresh;
    if (_armed && refresh != null) {
      widget.onRefreshStart();
      setState(() {
        _refreshing = true;
        _pulledExtent = 0;
        _armed = false;
      });
      unawaited(_runRefresh(refresh));
    } else {
      _resetPull();
    }
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (_pointer != event.pointer) return;
    _pointer = null;
    _resetPull();
  }

  bool _handleScroll(ScrollNotification notification) {
    if (notification.depth != 0 ||
        _pointer == null ||
        _refreshVisible ||
        _retracting) {
      return false;
    }
    final extent =
        (notification.metrics.minScrollExtent - notification.metrics.pixels)
            .clamp(0.0, double.infinity)
            .toDouble();
    final armed = extent >= _olderHistoryTriggerExtent;
    if ((extent - _pulledExtent).abs() < 0.5 && armed == _armed) return false;
    setState(() {
      _pulledExtent = extent;
      _armed = armed;
    });
    return false;
  }

  void _resetPull() {
    if (!mounted || (_pulledExtent == 0 && !_armed)) return;
    setState(() {
      _pulledExtent = 0;
      _armed = false;
    });
  }

  Future<void> _runRefresh(Future<void> Function() refresh) async {
    try {
      // Let the loading sliver reserve the same header space as the legacy
      // Compose screen before pagination captures the current scroll extent.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      await refresh();
    } finally {
      if (mounted) {
        setState(() {
          _refreshing = false;
          _retracting = true;
        });
        await Future<void>.delayed(_olderHistoryRetractDuration);
        if (mounted) {
          setState(() => _retracting = false);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final refreshVisible = _refreshVisible;
    final indicatorHeight = _pulledExtent
        .clamp(0.0, _olderHistoryIndicatorExtent)
        .toDouble();
    return Listener(
      onPointerDown: _handlePointerDown,
      onPointerUp: _handlePointerUp,
      onPointerCancel: _handlePointerCancel,
      child: Stack(
        children: [
          Positioned.fill(
            child: AbsorbPointer(
              absorbing: refreshVisible,
              child: NotificationListener<ScrollNotification>(
                onNotification: _handleScroll,
                child: widget.builder(context, refreshVisible),
              ),
            ),
          ),
          if (!refreshVisible && indicatorHeight > 0)
            Positioned(
              left: 0,
              right: 0,
              top: _pulledExtent - indicatorHeight,
              height: indicatorHeight,
              child: IgnorePointer(
                child: ClipRect(
                  child: _OlderHistoryIndicator(loading: false, armed: _armed),
                ),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: IgnorePointer(
              child: _OlderHistoryLoadingHeader(visible: refreshVisible),
            ),
          ),
        ],
      ),
    );
  }
}

class _OlderHistoryLoadingHeader extends StatefulWidget {
  const _OlderHistoryLoadingHeader({required this.visible});

  final bool visible;

  @override
  State<_OlderHistoryLoadingHeader> createState() =>
      _OlderHistoryLoadingHeaderState();
}

class _OlderHistoryLoadingHeaderState extends State<_OlderHistoryLoadingHeader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _olderHistoryRetractDuration,
    value: widget.visible ? 1 : 0,
  );
  late final Animation<double> _heightFactor = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );

  @override
  void didUpdateWidget(_OlderHistoryLoadingHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible == oldWidget.visible) return;
    if (widget.visible) {
      _controller.value = 1;
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final heightFactor = _heightFactor.value;
        if (!widget.visible && _controller.isDismissed) {
          return const SizedBox.shrink();
        }
        return ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: heightFactor,
            child: child,
          ),
        );
      },
      child: const ColoredBox(
        color: _workSurface,
        child: SizedBox(
          height: _olderHistoryLoadingExtent,
          child: _OlderHistoryIndicator(loading: true, armed: true),
        ),
      ),
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
    if (agent.showsProgressIndicator) {
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

class _BackgroundAgentsPanel extends StatefulWidget {
  const _BackgroundAgentsPanel({
    required this.sessionId,
    required this.agents,
    required this.enabled,
    required this.onOpenSubAgent,
  });

  final String sessionId;
  final List<SubAgentPresentation> agents;
  final bool enabled;
  final void Function(String threadId, String agentName) onOpenSubAgent;

  @override
  State<_BackgroundAgentsPanel> createState() => _BackgroundAgentsPanelState();
}

class _BackgroundAgentsPanelState extends State<_BackgroundAgentsPanel> {
  bool _expanded = false;

  @override
  void didUpdateWidget(_BackgroundAgentsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId) _expanded = false;
  }

  @override
  Widget build(BuildContext context) {
    final label = '${widget.agents.length} 个后台智能体';
    return Material(
      color: _workRaised,
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: _workBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            key: const Key('background-agents-toggle'),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
              child: Row(
                children: [
                  const Icon(Icons.smart_toy_outlined, size: 17),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      label,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    child: const Icon(Icons.keyboard_arrow_down, size: 20),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _expanded
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Divider(height: 1, color: _workBorder),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 176),
                        child: SingleChildScrollView(
                          child: Column(
                            children: [
                              for (final agent in widget.agents)
                                _BackgroundAgentRow(
                                  agent: agent,
                                  enabled: widget.enabled,
                                  onOpenSubAgent: widget.onOpenSubAgent,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

class _BackgroundAgentRow extends StatelessWidget {
  const _BackgroundAgentRow({
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
    return InkWell(
      onTap: canOpen ? () => onOpenSubAgent(agent.threadId, agent.name) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        child: Row(
          children: [
            _SubAgentAvatar(agent: agent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                agent.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            _SubAgentStatusVisual(agent: agent),
          ],
        ),
      ),
    );
  }
}

class _OlderHistoryIndicator extends StatelessWidget {
  const _OlderHistoryIndicator({required this.loading, required this.armed});

  final bool loading;
  final bool armed;

  @override
  Widget build(BuildContext context) {
    final label = loading
        ? '正在加载更多...'
        : armed
        ? '松开加载更多'
        : '下拉加载更多';
    return Center(
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
    );
  }
}

class _TimelineCard extends StatelessWidget {
  const _TimelineCard({
    required this.entry,
    required this.onOpenImage,
    required this.imageLoadingPath,
    required this.onOpenRemoteFile,
    required this.onOpenDiff,
    required this.canReview,
    required this.canRollback,
    required this.onReview,
    required this.onRollback,
  });

  final TimelineEntry entry;
  final _OpenRemoteImage onOpenImage;
  final String? imageLoadingPath;
  final Future<void> Function(String path) onOpenRemoteFile;
  final ValueChanged<FileChange> onOpenDiff;
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
      return _MarkdownMessage(
        entry.text,
        onOpenRemoteFile: onOpenRemoteFile,
        onOpenRemoteImage: onOpenImage,
      );
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
    return switch (entry.kind) {
      TimelineKind.fileChange => _FileChangeTimelineCard(
        entry: entry,
        onOpenDiff: onOpenDiff,
        canReview: canReview,
        canRollback: canRollback,
        onReview: onReview,
        onRollback: onRollback,
      ),
      TimelineKind.tool => _ToolTimelineCard(entry: entry),
      TimelineKind.review => _ReviewTimelineCard(
        entry: entry,
        onOpenRemoteImage: onOpenImage,
        onOpenRemoteFile: onOpenRemoteFile,
      ),
      TimelineKind.notice || TimelineKind.subAgent => Text(
        entry.text.trim().isEmpty ? entry.title : entry.text,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: codexMuted),
      ),
      _ => const SizedBox.shrink(),
    };
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
    final maxWidth = MediaQuery.sizeOf(context).width * 0.88;
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Material(
          key: Key('user-message-card-${entry.id}'),
          color: const Color(0xFF2B3730),
          shape: RoundedRectangleBorder(
            side: const BorderSide(color: Color(0xFF53735D)),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
            child: Column(
              mainAxisSize: MainAxisSize.min,
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
        ),
      ),
    );
  }
}

class _FileChangeTimelineCard extends StatefulWidget {
  const _FileChangeTimelineCard({
    required this.entry,
    required this.onOpenDiff,
    required this.canReview,
    required this.canRollback,
    required this.onReview,
    required this.onRollback,
  });

  final TimelineEntry entry;
  final ValueChanged<FileChange> onOpenDiff;
  final bool canReview;
  final bool canRollback;
  final Future<void> Function() onReview;
  final Future<void> Function() onRollback;

  @override
  State<_FileChangeTimelineCard> createState() =>
      _FileChangeTimelineCardState();
}

class _FileChangeTimelineCardState extends State<_FileChangeTimelineCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final additions = entry.changes.fold<int>(
      0,
      (total, change) => total + change.additions,
    );
    final deletions = entry.changes.fold<int>(
      0,
      (total, change) => total + change.deletions,
    );
    final visibleChanges = _expanded
        ? entry.changes
        : entry.changes.take(3).toList(growable: false);
    final hiddenCount = entry.changes.length - visibleChanges.length;
    final shape = RoundedRectangleBorder(
      side: const BorderSide(color: _workBorder),
      borderRadius: BorderRadius.circular(8),
    );
    return Material(
      color: const Color(0xFF1B1B1B),
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: _workRaised,
                    borderRadius: BorderRadius.circular(7),
                  ),
                  alignment: Alignment.center,
                  child: const Icon(Icons.description_outlined, size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '已编辑 ${entry.changes.length} 个文件',
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Row(
                        children: [
                          Text(
                            '+$additions',
                            style: Theme.of(
                              context,
                            ).textTheme.bodySmall?.copyWith(color: _workGreen),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '-$deletions',
                            style: Theme.of(
                              context,
                            ).textTheme.bodySmall?.copyWith(color: codexRed),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (widget.canRollback)
                  SizedBox.square(
                    dimension: 36,
                    child: IconButton(
                      tooltip: '撤销上一轮会话',
                      padding: EdgeInsets.zero,
                      onPressed: () => unawaited(widget.onRollback()),
                      icon: const Icon(Icons.undo, size: 19),
                    ),
                  ),
                if (widget.canReview) ...[
                  const SizedBox(width: 4),
                  SizedBox(
                    height: 36,
                    child: OutlinedButton(
                      onPressed: () => unawaited(widget.onReview()),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: codexText,
                        side: const BorderSide(color: _workBorder),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(7),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                      ),
                      child: Text(
                        '审核',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          for (final change in visibleChanges) ...[
            const Divider(height: 1, color: _workBorder),
            InkWell(
              onTap: () => widget.onOpenDiff(change),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 9,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        change.path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                          color: codexMuted,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '+${change.additions}',
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: _workGreen),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      '-${change.deletions}',
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: codexRed),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (entry.changes.length > 3) ...[
            const Divider(height: 1, color: _workBorder),
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 9,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _expanded ? '收起文件' : '再显示 $hiddenCount 个文件',
                        style: Theme.of(
                          context,
                        ).textTheme.bodyMedium?.copyWith(color: codexMuted),
                      ),
                    ),
                    Icon(
                      _expanded
                          ? Icons.keyboard_arrow_up
                          : Icons.keyboard_arrow_down,
                      size: 19,
                      color: codexMuted,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AggregateDiffTimelineCard extends StatelessWidget {
  const _AggregateDiffTimelineCard({
    super.key,
    required this.change,
    required this.onOpen,
  });

  final FileChange change;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => Material(
    color: _workRaised,
    shape: RoundedRectangleBorder(
      side: const BorderSide(color: _workBorder),
      borderRadius: BorderRadius.circular(6),
    ),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        child: Row(
          children: [
            const Icon(Icons.code, size: 18),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '工作区差异',
                    style: TextStyle(fontWeight: FontWeight.w500),
                  ),
                  Row(
                    children: [
                      Text(
                        '+${change.additions}',
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: _workGreen),
                      ),
                      const SizedBox(width: 7),
                      Text(
                        '-${change.deletions}',
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: codexRed),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            TextButton(onPressed: onOpen, child: const Text('查看差异')),
          ],
        ),
      ),
    ),
  );
}

class _ToolTimelineCard extends StatelessWidget {
  const _ToolTimelineCard({required this.entry});

  final TimelineEntry entry;

  @override
  Widget build(BuildContext context) {
    final status = _commandStatus(entry.status);
    return Material(
      color: _workRaised,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.all(11),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.code, size: 17),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    entry.title.trim().isEmpty ? '工具' : entry.title,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
                if (status != null)
                  Text(
                    status.label,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: status.color),
                  ),
              ],
            ),
            if (entry.text.trim().isNotEmpty) ...[
              const SizedBox(height: 7),
              _BoundedSelectableText(entry.text),
            ],
          ],
        ),
      ),
    );
  }
}

class _ReviewTimelineCard extends StatelessWidget {
  const _ReviewTimelineCard({
    required this.entry,
    required this.onOpenRemoteImage,
    required this.onOpenRemoteFile,
  });

  final TimelineEntry entry;
  final _OpenRemoteImage onOpenRemoteImage;
  final Future<void> Function(String path) onOpenRemoteFile;

  @override
  Widget build(BuildContext context) => Material(
    color: _workRaised,
    borderRadius: BorderRadius.circular(6),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.rate_review_outlined, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  entry.title,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
          if (entry.text.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            _MarkdownMessage(
              entry.text,
              onOpenRemoteFile: onOpenRemoteFile,
              onOpenRemoteImage: onOpenRemoteImage,
            ),
          ],
        ],
      ),
    ),
  );
}

class _TurnTimingFooter extends StatefulWidget {
  const _TurnTimingFooter({
    super.key,
    required this.running,
    required this.timing,
  });

  final bool running;
  final TurnTiming? timing;

  @override
  State<_TurnTimingFooter> createState() => _TurnTimingFooterState();
}

class _TurnTimingFooterState extends State<_TurnTimingFooter> {
  Timer? _timer;
  int _nowMillis = DateTime.now().millisecondsSinceEpoch;

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  @override
  void didUpdateWidget(covariant _TurnTimingFooter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.running != widget.running ||
        oldWidget.timing?.startedAtMillis != widget.timing?.startedAtMillis) {
      _syncTimer();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _syncTimer() {
    _timer?.cancel();
    _timer = null;
    _nowMillis = DateTime.now().millisecondsSinceEpoch;
    if (!widget.running) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() => _nowMillis = DateTime.now().millisecondsSinceEpoch);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final timing = widget.timing;
    if (widget.running) {
      final elapsed = timing == null
          ? null
          : _formatTurnElapsed(timing.startedAtMillis, _nowMillis);
      return Semantics(
        label: elapsed == null ? 'Codex 正在处理' : 'Codex 正在处理，已运行 $elapsed',
        child: Row(
          children: [
            const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: codexText,
              ),
            ),
            const SizedBox(width: 9),
            _ProcessingStatusText(elapsed: elapsed),
          ],
        ),
      );
    }
    final completedAt = timing?.completedAtMillis;
    if (timing == null || completedAt == null) {
      return const SizedBox.shrink();
    }
    final elapsed = _formatTurnElapsed(timing.startedAtMillis, completedAt);
    final stopped = timing.stopped;
    return Semantics(
      label: stopped
          ? '已停止，已处理 $elapsed'
          : '本次耗时 $elapsed，完成于 ${_formatTurnCompletionTime(completedAt)}',
      child: Row(
        children: [
          Icon(
            stopped ? Icons.stop : Icons.check_circle,
            size: 16,
            color: stopped ? _workAmber : _workGreen,
          ),
          const SizedBox(width: 9),
          Text(
            stopped
                ? '已停止  $elapsed'
                : '$elapsed  完成于 ${_formatTurnCompletionTime(completedAt)}',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: codexMuted),
          ),
        ],
      ),
    );
  }
}

class _ProcessingStatusText extends StatefulWidget {
  const _ProcessingStatusText({required this.elapsed});

  final String? elapsed;

  @override
  State<_ProcessingStatusText> createState() => _ProcessingStatusTextState();
}

class _ProcessingStatusTextState extends State<_ProcessingStatusText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final baseColor = codexMuted.withValues(alpha: 0.64);
    return Row(
      children: [
        AnimatedBuilder(
          animation: _controller,
          builder: (context, child) => ShaderMask(
            blendMode: BlendMode.srcIn,
            shaderCallback: (bounds) => LinearGradient(
              colors: [
                baseColor,
                Colors.white.withValues(alpha: 0.68),
                Colors.white.withValues(alpha: 0.92),
                Colors.white.withValues(alpha: 0.68),
                baseColor,
              ],
              stops: const [0, 0.34, 0.5, 0.66, 1],
              begin: Alignment(-3 + _controller.value * 6, 0),
              end: Alignment(-1 + _controller.value * 6, 0),
            ).createShader(bounds),
            child: child,
          ),
          child: Text('正在处理', style: Theme.of(context).textTheme.bodySmall),
        ),
        if (widget.elapsed != null) ...[
          const SizedBox(width: 6),
          Text(
            widget.elapsed!,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: baseColor),
          ),
        ],
      ],
    );
  }
}

String _formatTurnElapsed(int startedAtMillis, int endedAtMillis) {
  final normalizedStart =
      _normalizeEpochMillis(startedAtMillis) ?? endedAtMillis;
  final seconds = ((endedAtMillis - normalizedStart).clamp(0, 1 << 62)) ~/ 1000;
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final remainderSeconds = seconds % 60;
  if (hours > 0) return '${hours}h ${minutes}m ${remainderSeconds}s';
  if (minutes > 0) return '${minutes}m ${remainderSeconds}s';
  return '${remainderSeconds}s';
}

String _formatTurnCompletionTime(int completedAtMillis) {
  final normalized =
      _normalizeEpochMillis(completedAtMillis) ?? completedAtMillis;
  final value = DateTime.fromMillisecondsSinceEpoch(normalized).toLocal();
  String twoDigits(int number) => number.toString().padLeft(2, '0');
  return '${twoDigits(value.hour)}:${twoDigits(value.minute)}:'
      '${twoDigits(value.second)}';
}

int? _normalizeEpochMillis(int timestamp) {
  if (timestamp <= 0) return null;
  return timestamp < 100000000000 ? timestamp * 1000 : timestamp;
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
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(
                  entry.kind == TimelineKind.plan
                      ? Icons.pending_outlined
                      : Icons.search,
                  size: 17,
                  color: codexMuted,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(
                      context,
                    ).textTheme.labelLarge?.copyWith(color: codexMuted),
                  ),
                ),
                Icon(
                  _expanded
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                  size: 18,
                  color: codexMuted,
                ),
              ],
            ),
          ),
        ),
        if (_expanded && text.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 25, top: 4),
            child: SelectableText(
              text,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: codexMuted),
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
        side: const BorderSide(color: _workBorder),
        borderRadius: BorderRadius.circular(6),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
              child: Row(
                children: [
                  const Icon(Icons.terminal, size: 17),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '运行了命令',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                  if (status != null)
                    Text(
                      status.label,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: status.color),
                    ),
                  const SizedBox(width: 4),
                  AnimatedRotation(
                    key: const Key('command-expand-arrow'),
                    turns: _expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    child: const Icon(Icons.keyboard_arrow_down, size: 18),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            key: const Key('command-details-animation'),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _expanded
                ? Column(
                    children: [
                      if (entry.command.isNotEmpty)
                        _CommandOutputBlock(entry.command),
                      if (entry.output.isNotEmpty) ...[
                        if (entry.command.isNotEmpty)
                          const Divider(height: 1, color: _workBorder),
                        _CommandOutputBlock(entry.output),
                      ],
                      if (entry.command.isEmpty && entry.output.isEmpty)
                        const Padding(
                          padding: EdgeInsets.fromLTRB(11, 8, 11, 10),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              '未提供命令内容',
                              style: TextStyle(color: codexMuted),
                            ),
                          ),
                        ),
                    ],
                  )
                : const SizedBox(width: double.infinity),
          ),
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
    color: const Color(0xFF151515),
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
      color: _workRaised,
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: loading ? null : () => onOpenImage(path),
        child: Padding(
          padding: const EdgeInsets.all(11),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.visibility, size: 17, color: codexText),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '查看了图片',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                  loading
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : SizedBox.square(
                          dimension: 30,
                          child: IconButton(
                            tooltip: '查看图片',
                            padding: EdgeInsets.zero,
                            onPressed: () => onOpenImage(path),
                            icon: const Icon(Icons.visibility, size: 18),
                          ),
                        ),
                ],
              ),
              const SizedBox(height: 7),
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
  const _MarkdownMessage(
    this.text, {
    required this.onOpenRemoteFile,
    required this.onOpenRemoteImage,
  });

  final String text;
  final Future<void> Function(String path) onOpenRemoteFile;
  final _OpenRemoteImage onOpenRemoteImage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = MarkdownStyleSheet.fromTheme(theme);
    return MarkdownBody(
      data: markdownWithVisibleLinkDestinations(text),
      inlineSyntaxes: workMarkdownInlineSyntaxes,
      selectable: true,
      softLineBreak: true,
      styleSheet: base.copyWith(
        a: const TextStyle(
          color: _workLink,
          decoration: TextDecoration.underline,
          decorationColor: _workLink,
          letterSpacing: 0,
        ),
        p: theme.textTheme.bodyMedium?.copyWith(fontSize: 15, height: 1.2),
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
          if (isPreviewableImagePath(remotePath)) {
            unawaited(onOpenRemoteImage(remotePath));
          } else {
            unawaited(onOpenRemoteFile(remotePath));
          }
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
    final displayName = attachment.name.trim().isEmpty
        ? image
              ? '图片'
              : '文件'
        : attachment.name;
    return Material(
      color: _workSurface,
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: !image || loading
            ? null
            : () =>
                  onOpenImage(attachment.remotePath, fileName: attachment.name),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 260),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (loading)
                  const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(
                    image ? Icons.image_outlined : Icons.description_outlined,
                    size: 17,
                    color: image ? _workGreen : codexMuted,
                  ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
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

class _DiffScreen extends StatelessWidget {
  const _DiffScreen({required this.change});

  final FileChange change;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('文件差异'),
          Text(
            change.path,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
          ),
        ],
      ),
    ),
    body: SafeArea(top: false, child: _UnifiedDiffView(diff: change.diff)),
  );
}

enum _DiffLineKind { context, header, hunk, added, removed }

_DiffLineKind _diffLineKind(String line) {
  if (line.startsWith('@@')) return _DiffLineKind.hunk;
  if (line.startsWith('diff --git ') ||
      line.startsWith('index ') ||
      line.startsWith('--- ') ||
      line.startsWith('+++ ') ||
      line.startsWith('new file mode ') ||
      line.startsWith('deleted file mode ') ||
      line.startsWith('old mode ') ||
      line.startsWith('new mode ') ||
      line.startsWith('similarity index ') ||
      line.startsWith('rename from ') ||
      line.startsWith('rename to ') ||
      line.startsWith('Binary files ')) {
    return _DiffLineKind.header;
  }
  if (line.startsWith('+')) return _DiffLineKind.added;
  if (line.startsWith('-')) return _DiffLineKind.removed;
  return _DiffLineKind.context;
}

class _UnifiedDiffView extends StatelessWidget {
  const _UnifiedDiffView({required this.diff});

  final String diff;

  @override
  Widget build(BuildContext context) {
    if (diff.trim().isEmpty) {
      return const Center(child: Text('没有可显示的差异'));
    }
    final lines = diff.split('\n');
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: (constraints.maxWidth - 24).clamp(0, double.infinity),
            ),
            child: SelectionArea(
              child: IntrinsicWidth(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var index = 0; index < lines.length; index++)
                      _DiffLine(index: index, line: lines[index]),
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

class _DiffLine extends StatelessWidget {
  const _DiffLine({required this.index, required this.line});

  final int index;
  final String line;

  @override
  Widget build(BuildContext context) {
    final kind = _diffLineKind(line);
    final (foreground, background, semanticsLabel) = switch (kind) {
      _DiffLineKind.added => (
        const Color(0xFFB3E6BC),
        const Color(0xFF17351E),
        '新增行',
      ),
      _DiffLineKind.removed => (
        const Color(0xFFF4B1B5),
        const Color(0xFF3B1D20),
        '删除行',
      ),
      _DiffLineKind.hunk => (
        const Color(0xFFAFCBF1),
        const Color(0xFF1D3047),
        '差异区块',
      ),
      _DiffLineKind.header => (codexMuted, const Color(0xFF222222), '差异文件头'),
      _DiffLineKind.context => (codexText, Colors.transparent, '上下文行'),
    };
    return Semantics(
      label: semanticsLabel,
      container: true,
      child: Container(
        key: ValueKey('diff-line-${kind.name}-$index'),
        color: background,
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
        child: Text(
          line.isEmpty ? ' ' : line,
          softWrap: false,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            color: foreground,
            letterSpacing: 0,
            height: 1.35,
          ),
        ),
      ),
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
                          image: ResizeImage(
                            MemoryImage(widget.bytes),
                            width: 2048,
                            height: 2048,
                            policy: ResizeImagePolicy.fit,
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

class _Composer extends StatelessWidget {
  const _Composer({
    required this.state,
    required this.controller,
    required this.focusNode,
    required this.attachmentBusy,
    required this.onChanged,
    required this.onTakePhoto,
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
    required this.onOpenSubAgent,
  });

  final AppUiState state;
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool attachmentBusy;
  final ValueChanged<String> onChanged;
  final VoidCallback onTakePhoto;
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
  final void Function(String threadId, String agentName) onOpenSubAgent;

  @override
  Widget build(BuildContext context) {
    final canSend =
        (controller.text.trim().isNotEmpty || state.attachments.isNotEmpty) &&
        !state.loading &&
        !state.submitting &&
        !attachmentBusy;
    final actionEnabled = switch ((state.submitting, state.running)) {
      (true, _) => false,
      (_, true) => !state.loading,
      _ => canSend,
    };
    final actionActive = actionEnabled || state.submitting;
    final permissionColor = state.approvalMode == ApprovalMode.fullAccess
        ? _workAmber
        : codexMuted;
    final backgroundAgents = state.activeAgentCapabilities.subAgents
        ? state.timeline.toBackgroundSubAgentPresentations(
            running: state.running,
            activeTurnId: state.running
                ? state.activeTurnId
                : state.turnTiming?.turnId,
          )
        : const <SubAgentPresentation>[];
    final canOpenSubAgents =
        !state.loading && !state.submitting && state.approvalQueue.isEmpty;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 170),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Material(
        color: codexBackground,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
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
                if (backgroundAgents.isNotEmpty) ...[
                  _BackgroundAgentsPanel(
                    sessionId: state.activeThread?.id ?? '',
                    agents: backgroundAgents,
                    enabled: canOpenSubAgents,
                    onOpenSubAgent: onOpenSubAgent,
                  ),
                  const SizedBox(height: 6),
                ],
                Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: const Color(0xFF1B1B1B),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: _workBorder),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (state.attachments.isNotEmpty) ...[
                        SizedBox(
                          height: 34,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: state.attachments.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(width: 6),
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
                        key: const Key('composer-input'),
                        controller: controller,
                        focusNode: focusNode,
                        enabled: !state.submitting,
                        minLines: 3,
                        maxLines: 6,
                        textInputAction: TextInputAction.newline,
                        onChanged: onChanged,
                        decoration: InputDecoration(
                          hintText: state.running ? '提出后续变更要求' : '描述任务',
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          disabledBorder: InputBorder.none,
                          errorBorder: InputBorder.none,
                          focusedErrorBorder: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          SizedBox.square(
                            dimension: 36,
                            child: PopupMenuButton<String>(
                              key: const Key('composer-attachment-menu'),
                              tooltip: '添加附件',
                              enabled:
                                  !state.loading &&
                                  !state.submitting &&
                                  !attachmentBusy,
                              padding: EdgeInsets.zero,
                              iconSize: 20,
                              onSelected: (value) {
                                if (value == 'camera') {
                                  onTakePhoto();
                                } else if (value == 'image') {
                                  onAttachImage();
                                } else if (value == 'file') {
                                  onAttachFile();
                                }
                              },
                              itemBuilder: (context) => const [
                                PopupMenuItem(
                                  value: 'camera',
                                  child: ListTile(
                                    dense: true,
                                    contentPadding: EdgeInsets.zero,
                                    leading: Icon(Icons.photo_camera_outlined),
                                    title: Text('拍照'),
                                  ),
                                ),
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
                              icon: const Icon(Icons.add),
                            ),
                          ),
                          SizedBox.square(
                            dimension: 36,
                            child: PopupMenuButton<String>(
                              key: const Key('composer-action-menu'),
                              tooltip: '会话操作',
                              enabled: !state.loading && !attachmentBusy,
                              padding: EdgeInsets.zero,
                              iconSize: 20,
                              position: PopupMenuPosition.over,
                              offset: Offset(
                                0,
                                -_composerActionMenuHeight(state) - 28,
                              ),
                              constraints: const BoxConstraints(
                                minWidth: 144,
                                maxWidth: 144,
                              ),
                              popUpAnimationStyle: AnimationStyle.noAnimation,
                              onSelected: (value) => unawaited(onAction(value)),
                              itemBuilder: (context) => [
                                if (state.activeAgentCapabilities.threadGoals)
                                  PopupMenuItem(
                                    value: 'goal',
                                    enabled: !state.submitting,
                                    child: _ComposerPopupMenuRow(
                                      icon: Icons.track_changes,
                                      label: state.activeGoal == null
                                          ? '设置目标'
                                          : '编辑目标',
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
                                    child: _ComposerPopupMenuRow(
                                      icon:
                                          state.activeGoal!.status ==
                                              ThreadGoalStatus.paused
                                          ? Icons.play_circle_outline
                                          : Icons.pause_circle_outline,
                                      label:
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
                                    child: const _ComposerPopupMenuRow(
                                      icon: Icons.delete_outline,
                                      label: '删除目标',
                                    ),
                                  ),
                                if (state
                                        .activeAgentCapabilities
                                        .compactThread ||
                                    state.activeAgentCapabilities.models ||
                                    state.activeAgentCapabilities.approvals)
                                  const PopupMenuDivider(height: 1),
                                if (state.activeAgentCapabilities.compactThread)
                                  PopupMenuItem(
                                    value: 'compact',
                                    enabled:
                                        !state.loading &&
                                        !state.submitting &&
                                        !state.running,
                                    child: const _ComposerPopupMenuRow(
                                      icon: Icons.pending,
                                      label: '压缩会话',
                                    ),
                                  ),
                                if (state.activeAgentCapabilities.models)
                                  const PopupMenuItem(
                                    value: 'model',
                                    child: _ComposerPopupMenuRow(
                                      icon: Icons.smart_toy,
                                      label: '选择模型',
                                    ),
                                  ),
                                if (state.activeAgentCapabilities.approvals)
                                  PopupMenuItem(
                                    value: 'permissions',
                                    child: _ComposerPopupMenuRow(
                                      icon: _approvalModeIcon(
                                        state.approvalMode,
                                      ),
                                      label: '权限',
                                    ),
                                  ),
                              ],
                              icon: const Icon(Icons.more_vert),
                            ),
                          ),
                          if (state.activeAgentCapabilities.approvals)
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 64),
                              child: SizedBox(
                                height: 36,
                                child: TextButton(
                                  key: const Key('composer-permission-button'),
                                  onPressed: state.submitting
                                      ? null
                                      : () => unawaited(onPermissionTap()),
                                  style: TextButton.styleFrom(
                                    foregroundColor: permissionColor,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 2,
                                    ),
                                    minimumSize: Size.zero,
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        _approvalModeIcon(state.approvalMode),
                                        size: 16,
                                      ),
                                      const SizedBox(width: 3),
                                      Text(
                                        '权限',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.labelMedium,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          Expanded(
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                _ContextUsageButton(usage: state.tokenUsage),
                                if (state.activeAgentCapabilities.models) ...[
                                  const SizedBox(width: 4),
                                  Flexible(
                                    child: InkWell(
                                      key: const Key('composer-model-button'),
                                      onTap: state.loading ? null : onModelTap,
                                      borderRadius: BorderRadius.circular(5),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 2,
                                          vertical: 7,
                                        ),
                                        child: FittedBox(
                                          fit: BoxFit.scaleDown,
                                          alignment: Alignment.centerRight,
                                          child: Text(
                                            modelSelectionLabel(
                                              state.models,
                                              state.selectedModel,
                                              state.selectedEffort,
                                            ),
                                            key: const Key(
                                              'composer-model-label',
                                            ),
                                            maxLines: 1,
                                            softWrap: false,
                                            textAlign: TextAlign.right,
                                            style: Theme.of(
                                              context,
                                            ).textTheme.bodySmall,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(width: 4),
                          SizedBox.square(
                            dimension: 36,
                            child: IconButton(
                              tooltip: state.running ? '停止' : '发送',
                              onPressed: actionEnabled
                                  ? state.running
                                        ? () => unawaited(onStop())
                                        : onSend
                                  : null,
                              style: IconButton.styleFrom(
                                backgroundColor: actionActive
                                    ? codexText
                                    : const Color(0xFF555555),
                                disabledBackgroundColor: actionActive
                                    ? codexText
                                    : const Color(0xFF555555),
                                foregroundColor: const Color(0xFF171717),
                                disabledForegroundColor: const Color(
                                  0xFFB0B0B0,
                                ),
                                shape: const CircleBorder(),
                                minimumSize: const Size.square(36),
                                padding: EdgeInsets.zero,
                              ),
                              icon: state.submitting
                                  ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Color(0xFF171717),
                                      ),
                                    )
                                  : Icon(
                                      state.running
                                          ? Icons.stop_rounded
                                          : Icons.arrow_upward_rounded,
                                      size: state.running ? 18 : 20,
                                    ),
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
}

class _WorkPopupMenuRow extends StatelessWidget {
  const _WorkPopupMenuRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Icon(icon, size: 24),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ),
        ],
      ),
    );
  }
}

class _ComposerPopupMenuRow extends StatelessWidget {
  const _ComposerPopupMenuRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 22),
      const SizedBox(width: 12),
      Flexible(
        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    ],
  );
}

double _composerActionMenuHeight(AppUiState state) {
  var itemCount = 0;
  if (state.activeAgentCapabilities.threadGoals) itemCount += 1;
  if (state.activeGoal != null &&
      (state.activeGoal!.status == ThreadGoalStatus.active ||
          state.activeGoal!.status == ThreadGoalStatus.paused)) {
    itemCount += 1;
  }
  if (state.activeGoal != null) itemCount += 1;
  if (state.activeAgentCapabilities.compactThread) itemCount += 1;
  if (state.activeAgentCapabilities.models) itemCount += 1;
  if (state.activeAgentCapabilities.approvals) itemCount += 1;
  final hasDivider =
      state.activeAgentCapabilities.compactThread ||
      state.activeAgentCapabilities.models ||
      state.activeAgentCapabilities.approvals;
  return itemCount * 48.0 + (hasDivider ? 1.0 : 0.0) + 16.0;
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
    final usedPercent = (ratio * 100).floor();
    final remainingPercent = 100 - usedPercent;
    return PopupMenuButton<void>(
      tooltip: '上下文用量',
      padding: EdgeInsets.zero,
      position: PopupMenuPosition.over,
      offset: const Offset(82, -128),
      constraints: const BoxConstraints(minWidth: 196, maxWidth: 196),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      color: codexRaised,
      surfaceTintColor: Colors.transparent,
      menuPadding: EdgeInsets.zero,
      itemBuilder: (context) => [
        PopupMenuItem<void>(
          enabled: false,
          child: SizedBox(
            width: 164,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '背景信息窗口：',
                  style: Theme.of(
                    context,
                  ).textTheme.labelMedium?.copyWith(color: codexMuted),
                ),
                const SizedBox(height: 4),
                if (!known)
                  Text(
                    '等待服务器返回上下文用量',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: codexMuted),
                  )
                else ...[
                  Text(
                    '$usedPercent% 已用（剩余 $remainingPercent%）',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '已用 ${_formatTokens(used)} 标记，剩余 '
                    '${_formatTokens(remaining)}，共 ${_formatTokens(window)}',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: codexMuted),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
      child: SizedBox.square(
        key: const Key('composer-context-usage'),
        dimension: 32,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CircularProgressIndicator(
              value: known ? ratio : 0,
              strokeWidth: 2,
              constraints: const BoxConstraints.tightFor(width: 20, height: 20),
              backgroundColor: const Color(0xFF555555),
              color: Colors.white.withValues(alpha: 0.94),
            ),
            SizedBox(
              width: 14,
              height: 8,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  known ? '$usedPercent%' : '?',
                  key: const Key('composer-context-percent'),
                  maxLines: 1,
                  style: TextStyle(
                    color: known ? codexText : codexMuted,
                    fontSize: 6.5,
                    height: 1,
                    fontWeight: FontWeight.w700,
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
