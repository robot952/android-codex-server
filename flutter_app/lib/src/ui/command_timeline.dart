part of 'work_screen.dart';

const _commandDisclosureDuration = Duration(milliseconds: 220);
final _commandLineBreak = RegExp(r'[\r\n]');
const _commandMonoStyle = TextStyle(
  fontFamily: 'monospace',
  fontSize: 12,
  color: codexText,
  letterSpacing: 0,
);

class _CommandTimelineGroup extends StatefulWidget {
  const _CommandTimelineGroup({
    required this.entries,
    required this.onTextSelectionChanged,
  });

  final List<TimelineEntry> entries;
  final VoidCallback onTextSelectionChanged;

  @override
  State<_CommandTimelineGroup> createState() => _CommandTimelineGroupState();
}

class _CommandTimelineGroupState extends State<_CommandTimelineGroup> {
  bool _expanded = false;
  final _expandedCommands = <(String, int)>{};

  @override
  Widget build(BuildContext context) {
    final active = widget.entries.reversed.where(_commandIsRunning).firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CommandDisclosureRow(
          label: active == null ? '运行了命令' : _commandLabel(active, group: true),
          icon: _activityIcon(active?.commandAction),
          running: active != null,
          expanded: _expanded,
          onTap: () => setState(() => _expanded = !_expanded),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: DecoratedBox(
              decoration: const BoxDecoration(
                border: Border(left: BorderSide(color: _workBorder)),
              ),
              child: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: _buildCommands(),
                ),
              ),
            ),
          ),
      ],
    );
  }

  List<Widget> _buildCommands() {
    final counts = <String, int>{};
    return [
      for (final entry in widget.entries)
        _buildCommand(entry, (
          entry.id,
          counts.update(entry.id, (n) => n + 1, ifAbsent: () => 0),
        )),
    ];
  }

  Widget _buildCommand(TimelineEntry entry, (String, int) identity) {
    final expanded = _expandedCommands.contains(identity);
    final status = _terminalCommandStatus(entry.status);
    return Column(
      key: ValueKey(identity),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CommandDisclosureRow(
          label: _commandLabel(entry),
          icon: _activityIcon(entry.commandAction),
          status: status?.color == codexGreen ? null : status,
          running: _commandIsRunning(entry),
          expanded: expanded,
          isCommand: true,
          onTap: () => setState(() {
            if (expanded) {
              _expandedCommands.remove(identity);
            } else {
              _expandedCommands.add(identity);
            }
          }),
        ),
        AnimatedSize(
          key: const Key('command-details-animation'),
          duration: _commandDisclosureDuration,
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: expanded
              ? _CommandShellPanel(
                  entry: entry,
                  status: status,
                  onSelectionChanged: widget.onTextSelectionChanged,
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

bool _commandIsRunning(TimelineEntry entry) =>
    _terminalCommandStatus(entry.status)?.color == codexAmber &&
    _terminalCommandStatus(entry.turnStatus)?.color != codexGreen &&
    _terminalCommandStatus(entry.turnStatus)?.color != codexRed;

IconData _activityIcon(CommandAction? action) => switch (action?.kind) {
  CommandActionKind.read => Icons.menu_book_outlined,
  CommandActionKind.listFiles => Icons.folder_outlined,
  CommandActionKind.search => Icons.search,
  null => Icons.terminal,
};

String _commandLabel(TimelineEntry entry, {bool group = false}) {
  final action = entry.commandAction;
  if (action == null) {
    final command = entry.command.trimLeft();
    final lineBreak = command.indexOf(_commandLineBreak);
    final preview = lineBreak < 0 ? command : command.substring(0, lineBreak);
    if (group) return preview.isEmpty ? '正在运行命令' : '正在运行 $preview';
    return preview.isEmpty ? '命令详情' : preview;
  }
  final running = _commandIsRunning(entry);
  final completed = _terminalCommandStatus(entry.status)?.color == codexGreen;
  final tense = running
      ? '正在'
      : completed
      ? '已'
      : '';
  final target = action.target;
  switch (action.kind) {
    case CommandActionKind.read:
      return '$tense读取 ${target.isEmpty ? '文件' : target}';
    case CommandActionKind.listFiles:
      return '$tense列出${target.isEmpty ? '文件' : ' $target 中的文件'}';
    case CommandActionKind.search:
      final query = action.query.isEmpty ? '' : '“${action.query}”';
      if (running) {
        return '正在搜索${query.isEmpty ? '' : ' $query'}${target.isEmpty ? '' : '（$target）'}';
      }
      return '$tense${target.isEmpty ? '' : '在 $target 中'}搜索$query';
  }
}

_CommandStatus? _terminalCommandStatus(String raw) {
  return switch (raw.trim().toLowerCase()) {
    'interrupted' ||
    'cancelled' ||
    'canceled' => const _CommandStatus('已中断', codexRed),
    _ => _commandStatus(raw),
  };
}

class _CommandDisclosureRow extends StatelessWidget {
  const _CommandDisclosureRow({
    required this.label,
    required this.icon,
    this.status,
    required this.running,
    required this.expanded,
    required this.onTap,
    this.isCommand = false,
  });

  final String label;
  final IconData icon;
  final _CommandStatus? status;
  final bool running;
  final bool expanded;
  final VoidCallback onTap;
  final bool isCommand;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final labelStyle = isCommand ? textTheme.bodySmall : textTheme.labelLarge;
    final title = Text(
      label,
      style: labelStyle?.copyWith(color: codexMuted),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    return Semantics(
      expanded: expanded,
      button: true,
      value: running && !isCommand ? '运行中' : null,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 32),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Row(
                children: [
                  Icon(icon, size: isCommand ? 14 : 17, color: codexMuted),
                  const SizedBox(width: 6),
                  Flexible(
                    flex: 4,
                    child: running ? _WorkStatusShimmer(child: title) : title,
                  ),
                  const SizedBox(width: 3),
                  AnimatedRotation(
                    key: isCommand ? const Key('command-expand-arrow') : null,
                    turns: expanded ? 0.5 : 0,
                    duration: _commandDisclosureDuration,
                    curve: Curves.easeOutCubic,
                    child: const Icon(
                      Icons.keyboard_arrow_down,
                      size: 15,
                      color: codexMuted,
                    ),
                  ),
                  if (status case final value?) ...[
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        value.label,
                        style: textTheme.bodySmall?.copyWith(
                          color: value.color,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
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

class _CommandShellPanel extends StatelessWidget {
  const _CommandShellPanel({
    required this.entry,
    required this.status,
    required this.onSelectionChanged,
  });

  final TimelineEntry entry;
  final _CommandStatus? status;
  final VoidCallback onSelectionChanged;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.only(top: 2, bottom: 6),
      decoration: BoxDecoration(
        color: _workRaised,
        border: Border.all(color: _workBorder),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(9, 6, 9, 2),
            child: Text(
              'Shell',
              style: textTheme.labelSmall?.copyWith(color: codexMuted),
            ),
          ),
          if (entry.detailsItemId.isNotEmpty)
            _HistoryDetailsLoader(entry: entry)
          else if (entry.command.isEmpty && entry.output.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(9, 4, 9, 7),
              child: Text('未提供命令内容', style: TextStyle(color: codexMuted)),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 216),
              child: SingleChildScrollView(
                primary: false,
                child: SingleChildScrollView(
                  primary: false,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(9, 5, 9, 7),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (entry.command.isNotEmpty)
                        _SelectablePlainText(
                          '\$ ${entry.command}',
                          style: _commandMonoStyle,
                          onSelectionChanged: onSelectionChanged,
                        ),
                      if (entry.output.isNotEmpty) ...[
                        if (entry.command.isNotEmpty) const SizedBox(height: 4),
                        _SelectablePlainText(
                          entry.output,
                          style: _commandMonoStyle,
                          onSelectionChanged: onSelectionChanged,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          if (status case final value?)
            Padding(
              padding: const EdgeInsets.fromLTRB(9, 0, 9, 6),
              child: Text(
                value.label,
                textAlign: TextAlign.end,
                style: textTheme.labelSmall?.copyWith(color: value.color),
              ),
            ),
        ],
      ),
    );
  }
}
