import 'package:codex_remote/src/domain/models.dart';

/// Display state for a remote collaborator.
///
/// A terminal state never regresses to a late activity item from the same turn.
enum SubAgentDisplayStatus {
  preparing('准备中', true),
  started('已开始工作', true),
  updated('已更新', true),
  working('正在工作', true),
  completed('已完成', false),
  interrupted('已中断', false),
  failed('失败', false),
  stopped('已停止', false),
  unavailable('未找到', false);

  const SubAgentDisplayStatus(this.label, this.isActive);

  final String label;
  final bool isActive;
}

class SubAgentPresentation {
  const SubAgentPresentation({
    required this.threadId,
    required this.name,
    required this.path,
    required this.turnId,
    required this.status,
    required this.summary,
    required this.timelineIndex,
    this.activity = '',
  });

  final String threadId;
  final String name;
  final String path;
  final String turnId;
  final SubAgentDisplayStatus status;
  final String summary;
  final int timelineIndex;
  final String activity;

  bool get isMessageActivity =>
      activity == 'sendInput' ||
      activity == 'sendMessage' ||
      activity == 'followupTask' ||
      activity == 'interacted' ||
      isParentMessage;

  bool get isParentMessage => activity == 'sendMessageToParent';

  /// Activity rows describe what happened at that point in the transcript.
  /// Their status may later be updated by a child lifecycle notification.
  String get activityLabel {
    if (isParentMessage) return '已向父代理发送消息';
    if (!isConfirmed) return status.label;
    return switch (activity) {
      'started' || 'spawnAgent' => '开始工作',
      'completed' => '已完成',
      'sendInput' || 'sendMessage' || 'interacted' => '发送消息',
      'followupTask' => '追加任务',
      'resumeAgent' => '已恢复',
      'closeAgent' => '已关闭',
      'interrupted' => '已中断',
      'interruptAgent' => '已请求中断',
      _ => status.label,
    };
  }

  /// An activity item is only a real collaborator after the server assigns it
  /// a child-thread id. Before that, it represents a creation attempt.
  bool get isConfirmed => threadId.isNotEmpty && !isParentMessage;

  bool get isOpenable => isConfirmed;

  /// Only an assigned collaborator may report actual work in progress.
  bool get showsProgressIndicator => isConfirmed && status.isActive;

  /// Excludes status and timeline position so an agent retains its visual identity.
  String get avatarIdentityKey => threadId.isNotEmpty
      ? threadId
      : path.isNotEmpty
      ? path
      : name;

  int avatarColorIndex(int paletteSize) {
    return subAgentAvatarColorIndex(avatarIdentityKey, paletteSize);
  }
}

/// A deterministic identity color across app processes and platforms.
int subAgentAvatarColorIndex(String identity, int paletteSize) {
  if (paletteSize <= 0) {
    throw ArgumentError.value(paletteSize, 'paletteSize', 'must be positive');
  }
  var hash = 0x811c9dc5;
  for (final codeUnit in identity.codeUnits) {
    hash = ((hash ^ codeUnit) * 0x01000193) & 0xffffffff;
  }
  return hash % paletteSize;
}

class SubAgentActivityGroupPresentation {
  const SubAgentActivityGroupPresentation({
    required this.agents,
    required this.status,
    required this.isActive,
  });

  final List<SubAgentPresentation> agents;
  final SubAgentDisplayStatus status;
  final bool isActive;

  String get statusLabel => status.label;
}

sealed class TimelineRenderRow {
  const TimelineRenderRow();

  String get stableKey;
}

final class TimelineEntryRenderRow extends TimelineRenderRow {
  const TimelineEntryRenderRow(this.entry);

  final TimelineEntry entry;

  @override
  String get stableKey => 'entry:${entry.turnId}:${entry.kind}:${entry.id}';
}

final class SubAgentTimelineRenderRow extends TimelineRenderRow {
  const SubAgentTimelineRenderRow(this.entries);

  final List<TimelineEntry> entries;

  @override
  String get stableKey =>
      'agents:${entries.map((entry) => '${entry.turnId}:${entry.id}').join(':')}';
}

extension SubAgentTimelinePresentation on List<TimelineEntry> {
  /// Groups adjacent sub-agent activities from the same turn into one render row.
  List<TimelineRenderRow> toTimelineRenderRows() {
    if (isEmpty) return const <TimelineRenderRow>[];

    final rows = <TimelineRenderRow>[];
    final pendingAgents = <TimelineEntry>[];
    final knownPaths = <String, String>{
      for (final entry in this)
        if (entry.kind == TimelineKind.subAgent &&
            entry.subAgentThreadId.trim().isNotEmpty &&
            entry.subAgentPath.trim().isNotEmpty)
          entry.subAgentThreadId: entry.subAgentPath,
    };

    void flushAgents() {
      if (pendingAgents.isEmpty) return;
      rows.add(SubAgentTimelineRenderRow(List.unmodifiable(pendingAgents)));
      pendingAgents.clear();
    }

    for (final entry in this) {
      if (entry.kind == TimelineKind.subAgent) {
        final previousTurn = pendingAgents.isEmpty
            ? null
            : pendingAgents.last.turnId;
        final canJoin =
            pendingAgents.isEmpty ||
            (previousTurn != null &&
                previousTurn.isNotEmpty &&
                previousTurn == entry.turnId);
        if (!canJoin) flushAgents();
        pendingAgents.add(
          entry.subAgentPath.trim().isEmpty &&
                  knownPaths.containsKey(entry.subAgentThreadId)
              ? entry.copyWith(
                  subAgentPath: knownPaths[entry.subAgentThreadId]!,
                )
              : entry,
        );
      } else {
        flushAgents();
        rows.add(TimelineEntryRenderRow(entry));
      }
    }
    flushAgents();
    return List.unmodifiable(rows);
  }

  /// Keeps each activity in wire order. Only the background index deduplicates
  /// collaborators; starts, completions and messages remain separate rows.
  List<SubAgentPresentation> toSubAgentActivityPresentations() =>
      List.unmodifiable([
        for (var index = 0; index < length; index++)
          if (this[index].kind == TimelineKind.subAgent)
            _toSubAgentPresentation(this[index], index),
      ]);

  /// Returns the latest stable display state for each sub-agent.
  List<SubAgentPresentation> toSubAgentPresentations() {
    final agents = <String, SubAgentPresentation>{};
    for (var index = 0; index < length; index += 1) {
      final entry = this[index];
      if (entry.kind != TimelineKind.subAgent) continue;

      final candidate = _toSubAgentPresentation(entry, index);
      if (candidate.isParentMessage) continue;
      final key = candidate.threadId.isNotEmpty
          ? candidate.threadId
          : 'entry:${entry.id}:$index';
      final existing = agents[key];
      agents[key] = existing == null
          ? candidate
          : _mergeWith(existing, candidate);
    }

    final result = agents.values.toList()
      ..sort((left, right) {
        if (left.status.isActive != right.status.isActive) {
          return left.status.isActive ? -1 : 1;
        }
        return right.timelineIndex.compareTo(left.timelineIndex);
      });
    return List.unmodifiable(result);
  }

  /// Returns every confirmed collaborator in the parent conversation.
  ///
  /// The composer panel is a session-level index: agents created by a later
  /// parent turn are added to the existing list instead of replacing it.
  List<SubAgentPresentation> toBackgroundSubAgentPresentations() {
    final agents = toSubAgentPresentations();
    return List.unmodifiable(agents.where((agent) => agent.isConfirmed));
  }

  SubAgentActivityGroupPresentation toSubAgentActivityGroupPresentation() {
    final agents = toSubAgentPresentations();
    final confirmedAgents = agents
        .where((agent) => agent.isConfirmed)
        .toList(growable: false);
    final statuses = agents.map((agent) => agent.status).toSet();
    final isActive = confirmedAgents.any((agent) => agent.status.isActive);
    final status = switch (statuses.length) {
      0 => SubAgentDisplayStatus.unavailable,
      1 => statuses.single,
      _ when isActive => SubAgentDisplayStatus.working,
      _ when statuses.contains(SubAgentDisplayStatus.failed) =>
        SubAgentDisplayStatus.failed,
      _ when statuses.contains(SubAgentDisplayStatus.interrupted) =>
        SubAgentDisplayStatus.interrupted,
      _ when statuses.contains(SubAgentDisplayStatus.unavailable) =>
        SubAgentDisplayStatus.unavailable,
      _ when statuses.contains(SubAgentDisplayStatus.stopped) =>
        SubAgentDisplayStatus.stopped,
      _
          when agents.every(
            (agent) => agent.status == SubAgentDisplayStatus.completed,
          ) =>
        SubAgentDisplayStatus.completed,
      _ => agents.first.status,
    };
    return SubAgentActivityGroupPresentation(
      agents: agents,
      status: status,
      isActive: isActive,
    );
  }
}

SubAgentPresentation _toSubAgentPresentation(TimelineEntry entry, int index) {
  final path = entry.subAgentPath.trim();
  final name = _displayAgentName(_leafName(path));
  final threadId = entry.subAgentThreadId.trim();
  return SubAgentPresentation(
    threadId: threadId,
    name: name.isNotEmpty
        ? name
        : threadId.isNotEmpty
        ? threadId.substring(0, threadId.length > 8 ? 8 : threadId.length)
        : '智能体',
    path: path,
    turnId: entry.turnId,
    status: _toDisplayStatus(entry),
    summary: entry.text.trim(),
    timelineIndex: index,
    activity: entry.subAgentActivity,
  );
}

String _leafName(String path) {
  final trimmed = path.replaceFirst(RegExp(r'[\\/]+$'), '');
  final separator = [
    trimmed.lastIndexOf('/'),
    trimmed.lastIndexOf('\\'),
  ].reduce((left, right) => left > right ? left : right);
  return (separator < 0 ? trimmed : trimmed.substring(separator + 1)).trim();
}

/// Agent paths are stable protocol values, but their leaf names are user-facing.
/// Keep the wire/path identity intact while making generated snake_case names
/// readable in activity rows, the background list, and the child page title.
String _displayAgentName(String value) {
  return value
      .replaceAll(RegExp(r'_+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

SubAgentDisplayStatus _toDisplayStatus(TimelineEntry entry) {
  final status = switch (entry.status) {
    'completed' => SubAgentDisplayStatus.completed,
    'interrupted' => SubAgentDisplayStatus.interrupted,
    'errored' || 'failed' => SubAgentDisplayStatus.failed,
    'shutdown' => SubAgentDisplayStatus.stopped,
    'notFound' => SubAgentDisplayStatus.unavailable,
    'pendingInit' => SubAgentDisplayStatus.preparing,
    'running' ||
    'inProgress' ||
    'unknown' ||
    'started' ||
    'interacted' => _activityStatus(entry.subAgentActivity),
    _ => switch (entry.subAgentActivity) {
      'started' => SubAgentDisplayStatus.started,
      'interacted' => SubAgentDisplayStatus.updated,
      'interrupted' => SubAgentDisplayStatus.interrupted,
      _ => SubAgentDisplayStatus.working,
    },
  };
  // Activity messages are emitted before collaboration creation has been
  // acknowledged. They cannot represent a running child session yet.
  return entry.subAgentThreadId.trim().isEmpty && status.isActive
      ? SubAgentDisplayStatus.preparing
      : status;
}

SubAgentDisplayStatus _activityStatus(String activity) {
  return switch (activity) {
    'started' => SubAgentDisplayStatus.started,
    'interacted' => SubAgentDisplayStatus.updated,
    _ => SubAgentDisplayStatus.working,
  };
}

SubAgentPresentation _mergeWith(
  SubAgentPresentation current,
  SubAgentPresentation next,
) {
  final sameOrUnknownTurn =
      current.turnId.isEmpty ||
      next.turnId.isEmpty ||
      current.turnId == next.turnId;
  final path = next.path.isEmpty ? current.path : next.path;
  // Collaboration status updates often omit agentPath. The shortened thread id
  // is only a fallback, not a rename of an already named collaborator.
  final name = path.isNotEmpty ? _displayAgentName(_leafName(path)) : next.name;
  final summary = next.summary.isEmpty ? current.summary : next.summary;
  final explicitlyRestarts =
      next.activity == 'sendInput' || next.activity == 'resumeAgent';

  if (!current.status.isActive &&
      next.status.isActive &&
      sameOrUnknownTurn &&
      !explicitlyRestarts) {
    return SubAgentPresentation(
      threadId: current.threadId,
      name: name,
      path: path,
      turnId: current.turnId,
      status: current.status,
      summary: summary,
      timelineIndex: next.timelineIndex,
      activity: next.activity,
    );
  }

  final mergedStatus =
      !current.status.isActive && !next.status.isActive && sameOrUnknownTurn
      ? _strongerTerminalStatus(current.status, next.status)
      : next.status;

  return SubAgentPresentation(
    threadId: next.threadId,
    name: name,
    path: path,
    turnId: next.turnId,
    status: mergedStatus,
    summary: summary,
    timelineIndex: next.timelineIndex,
    activity: next.activity,
  );
}

SubAgentDisplayStatus _strongerTerminalStatus(
  SubAgentDisplayStatus current,
  SubAgentDisplayStatus next,
) {
  int rank(SubAgentDisplayStatus status) => switch (status) {
    SubAgentDisplayStatus.completed => 5,
    SubAgentDisplayStatus.failed => 4,
    SubAgentDisplayStatus.interrupted => 3,
    SubAgentDisplayStatus.stopped => 2,
    SubAgentDisplayStatus.unavailable => 1,
    _ => 0,
  };
  return rank(next) >= rank(current) ? next : current;
}
