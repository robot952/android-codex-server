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
    final ids = await pickDiagnosticLogIds(context, logger: logger);
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
  int? maxSelection,
}) async {
  final entries = await logger.listLogs();
  if (!context.mounted) return null;
  final initial = <String>{};
  if (entries.isNotEmpty) {
    final preferred = preferLatestCrash
        ? entries.where((entry) => entry.hasCrash).firstOrNull
        : null;
    initial.add((preferred ?? entries.first).id);
  }
  return showDialog<List<String>>(
    context: context,
    builder: (context) => _DiagnosticLogPicker(
      title: title,
      entries: entries,
      initialSelection: initial,
      maxSelection: maxSelection,
    ),
  );
}

class _DiagnosticLogPicker extends StatefulWidget {
  const _DiagnosticLogPicker({
    required this.title,
    required this.entries,
    required this.initialSelection,
    this.maxSelection,
  });

  final String title;
  final List<DiagnosticLogEntry> entries;
  final Set<String> initialSelection;
  final int? maxSelection;

  @override
  State<_DiagnosticLogPicker> createState() => _DiagnosticLogPickerState();
}

class _DiagnosticLogPickerState extends State<_DiagnosticLogPicker> {
  late final Set<String> _selected = {...widget.initialSelection};

  int get _selectAllCount {
    final maximum = widget.maxSelection;
    return maximum == null || maximum > widget.entries.length
        ? widget.entries.length
        : maximum;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 500,
        child: widget.entries.isEmpty
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Text('暂无可用日志'),
              )
            : ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 480),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: widget.entries.length,
                  itemBuilder: (context, index) {
                    final entry = widget.entries[index];
                    final selected = _selected.contains(entry.id);
                    final selectionFull =
                        widget.maxSelection != null &&
                        _selected.length >= widget.maxSelection!;
                    final date = _formatLogDate(entry.updatedAt);
                    final marker = entry.hasCrash ? ' · 崩溃' : '';
                    return CheckboxListTile(
                      value: selected,
                      onChanged: !selected && selectionFull
                          ? null
                          : (value) => setState(() {
                              if (value == true) {
                                _selected.add(entry.id);
                              } else {
                                _selected.remove(entry.id);
                              }
                            }),
                      controlAffinity: ListTileControlAffinity.leading,
                      dense: true,
                      title: Text(
                        '$date$marker',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${entry.fileName} · ${_formatBytes(entry.sizeBytes)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    );
                  },
                ),
              ),
      ),
      actions: [
        if (widget.entries.isNotEmpty)
          TextButton(
            onPressed: () => setState(() {
              if (_selected.length >= _selectAllCount) {
                _selected.clear();
              } else {
                final entries = widget.maxSelection == null
                    ? widget.entries
                    : widget.entries.take(widget.maxSelection!);
                _selected
                  ..clear()
                  ..addAll(entries.map((entry) => entry.id));
              }
            }),
            child: Text(_selected.length >= _selectAllCount ? '清除选择' : '全选'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.of(context).pop(_selected.toList()),
          child: Text('确定 (${_selected.length})'),
        ),
      ],
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
    _snapshot = widget.logger.snapshot();
  }

  void _refresh() {
    setState(() => _snapshot = widget.logger.snapshot());
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
      final ids = await pickDiagnosticLogIds(context, logger: widget.logger);
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
                                : '${_formatBytes(value.bytes)} · 自动轮转',
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
