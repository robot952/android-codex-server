import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../platform/diagnostic_logger.dart';
import 'theme.dart';

Future<void> showDiagnosticLogSheet(
  BuildContext context, {
  required DiagnosticLogger logger,
  VoidCallback? onDisable,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (context) =>
        DiagnosticLogSheet(logger: logger, onDisable: onDisable),
  );
}

Future<void> shareDiagnosticLogs(
  BuildContext context, {
  required DiagnosticLogger logger,
}) async {
  try {
    final ids = await pickDiagnosticLogIds(
      context,
      logger: logger,
      title: '选择要分享的诊断日志',
      confirmLabel: '分享',
      preselectLatest: false,
    );
    if (ids == null || ids.isEmpty) return;
    await logger.share(ids: ids);
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('已打开系统分享')));
    }
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('无法分享日志：${_displayError(error)}')),
        );
    }
  }
}

/// Opens the bounded log selector used by both system sharing and work-page
/// attachments. A crash session is selected first when requested; the user
/// can add or remove any other retained session before confirming.
Future<List<String>?> pickDiagnosticLogIds(
  BuildContext context, {
  required DiagnosticLogger logger,
  bool preferLatestCrash = false,
  String title = '选择 Debug 日志',
  String confirmLabel = '确定',
  bool preselectLatest = true,
  int? maxSelection,
}) async {
  final entries = await logger.listLogs();
  if (!context.mounted) return null;
  final initial = <String>{};
  if (entries.isNotEmpty && (preferLatestCrash || preselectLatest)) {
    final preferred = preferLatestCrash
        ? entries.where((entry) => entry.hasCrash).firstOrNull
        : null;
    initial.add((preferred ?? entries.first).id);
  }
  return showDialog<List<String>>(
    context: context,
    builder: (context) => _DiagnosticLogPicker(
      title: title,
      confirmLabel: confirmLabel,
      entries: entries,
      initialSelection: initial,
      maxSelection: maxSelection,
    ),
  );
}

class _DiagnosticLogPicker extends StatefulWidget {
  const _DiagnosticLogPicker({
    required this.title,
    required this.confirmLabel,
    required this.entries,
    required this.initialSelection,
    this.maxSelection,
  });

  final String title;
  final String confirmLabel;
  final List<DiagnosticLogEntry> entries;
  final Set<String> initialSelection;
  final int? maxSelection;

  @override
  State<_DiagnosticLogPicker> createState() => _DiagnosticLogPickerState();
}

class _DiagnosticLogPickerState extends State<_DiagnosticLogPicker> {
  late final Set<String> _selected = {...widget.initialSelection};

  void _setSelected(DiagnosticLogEntry entry, bool selected) {
    setState(() {
      if (selected) {
        _selected.add(entry.id);
      } else {
        _selected.remove(entry.id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final availableHeight = MediaQuery.sizeOf(context).height - 48;
    final listHeight = (widget.entries.length * 73.0).clamp(72.0, 420.0);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      backgroundColor: codexRaised,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 520,
          maxHeight: availableHeight.clamp(280.0, 600.0).toDouble(),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final maximumListHeight = constraints.maxHeight - 112;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
                  child: Text(
                    widget.title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                if (widget.entries.isEmpty)
                  const SizedBox(
                    height: 80,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(24, 20, 24, 28),
                      child: Text('暂无可用日志'),
                    ),
                  )
                else
                  SizedBox(
                    height: listHeight
                        .clamp(72.0, maximumListHeight)
                        .toDouble(),
                    child: Scrollbar(
                      child: ListView.separated(
                        key: const Key('diagnostic-log-list'),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: widget.entries.length,
                        separatorBuilder: (context, index) => const Divider(
                          height: 1,
                          indent: 8,
                          endIndent: 8,
                          color: codexBorder,
                        ),
                        itemBuilder: (context, index) {
                          final entry = widget.entries[index];
                          final selected = _selected.contains(entry.id);
                          final selectionFull =
                              widget.maxSelection != null &&
                              _selected.length >= widget.maxSelection!;
                          final enabled = selected || !selectionFull;
                          return _DiagnosticLogRow(
                            key: Key('diagnostic-log-row-${entry.id}'),
                            entry: entry,
                            selected: selected,
                            enabled: enabled,
                            onChanged: (value) => _setSelected(entry, value),
                          );
                        },
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        key: const Key('diagnostic-log-confirm'),
                        onPressed: _selected.isEmpty
                            ? null
                            : () => Navigator.of(context).pop(
                                widget.entries
                                    .where(
                                      (entry) => _selected.contains(entry.id),
                                    )
                                    .map((entry) => entry.id)
                                    .toList(growable: false),
                              ),
                        child: Text(widget.confirmLabel),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _DiagnosticLogRow extends StatelessWidget {
  const _DiagnosticLogRow({
    super.key,
    required this.entry,
    required this.selected,
    required this.enabled,
    required this.onChanged,
  });

  final DiagnosticLogEntry entry;
  final bool selected;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? () => onChanged(!selected) : null,
      child: SizedBox(
        height: 72,
        child: Row(
          children: [
            Checkbox(
              value: selected,
              onChanged: enabled ? (value) => onChanged(value ?? false) : null,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _formatLogDate(entry.createdAt),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Text(
                        _formatBytes(entry.sizeBytes),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (entry.isActive) ...[
                        const SizedBox(width: 8),
                        const Text(
                          '当前记录中',
                          style: TextStyle(
                            color: codexGreen,
                            fontSize: 12,
                            letterSpacing: 0,
                          ),
                        ),
                      ],
                      if (entry.hasCrash) ...[
                        const SizedBox(width: 8),
                        const Text(
                          '崩溃',
                          style: TextStyle(
                            color: codexRed,
                            fontSize: 12,
                            letterSpacing: 0,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatLogDate(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

class DiagnosticLogSheet extends StatefulWidget {
  const DiagnosticLogSheet({super.key, required this.logger, this.onDisable});

  final DiagnosticLogger logger;
  final VoidCallback? onDisable;

  @override
  State<DiagnosticLogSheet> createState() => _DiagnosticLogSheetState();
}

class _DiagnosticLogSheetState extends State<DiagnosticLogSheet> {
  late Future<DiagnosticLogSnapshot> _snapshot;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _snapshot = widget.logger.currentSnapshot();
  }

  void _refresh() {
    setState(() => _snapshot = widget.logger.currentSnapshot());
  }

  Future<void> _copy(DiagnosticLogSnapshot snapshot) async {
    if (snapshot.preview.trim().isEmpty) return;
    await Clipboard.setData(ClipboardData(text: snapshot.preview));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('日志已复制')));
  }

  Future<void> _share() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final ids = await pickDiagnosticLogIds(
        context,
        logger: widget.logger,
        title: '选择要分享的诊断日志',
        confirmLabel: '分享',
        preselectLatest: false,
      );
      if (ids == null || ids.isEmpty) return;
      await widget.logger.share(ids: ids);
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('已打开系统分享')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(content: Text('无法分享日志：${_displayError(error)}')),
          );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空诊断日志？'),
        content: const Text('会删除当前设备上保留的 Debug 日志。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: codexRed),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    await widget.logger.clear();
    if (mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Material(
      color: codexSurface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 12, 16, 16 + bottom),
        child: FutureBuilder<DiagnosticLogSnapshot>(
          future: _snapshot,
          builder: (context, snapshot) {
            final value = snapshot.data;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.bug_report_outlined, color: codexAmber),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '诊断日志',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          Text(
                            value == null
                                ? '正在读取…'
                                : '${_formatBytes(value.bytes)} · 当前记录',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '刷新日志',
                      onPressed: _busy ? null : _refresh,
                      icon: const Icon(Icons.refresh),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxHeight: 280,
                    minHeight: 100,
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.28),
                      border: Border.all(color: codexBorder),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: value == null
                        ? const Center(
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Scrollbar(
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.all(10),
                              child: SelectableText(
                                value.preview.isEmpty ? '暂无日志' : value.preview,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                  height: 1.35,
                                ),
                              ),
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: value == null || value.preview.isEmpty
                            ? null
                            : () => _copy(value),
                        icon: const Icon(Icons.copy_outlined, size: 18),
                        label: const Text('复制'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : _clear,
                        icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                        label: const Text('清空'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _busy ? null : _share,
                        icon: _busy
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.share_outlined, size: 18),
                        label: const Text('分享'),
                      ),
                    ),
                  ],
                ),
                if (widget.onDisable != null) ...[
                  const SizedBox(height: 4),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () {
                            widget.onDisable!();
                            Navigator.pop(context);
                          },
                    child: const Text('关闭 Debug 模式'),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '$bytes B';
}

String _displayError(Object error) {
  final message = error.toString().replaceFirst('Exception: ', '').trim();
  return message.isEmpty ? '未知错误' : message;
}
