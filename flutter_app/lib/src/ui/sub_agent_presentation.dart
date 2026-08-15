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
  });

  final String threadId;
  final String name;
  final String path;
  final String turnId;
  final SubAgentDisplayStatus status;
  final String summary;
  final int timelineIndex;

  /// An activity item is only a real collaborator after the server assigns it
  /// a child-thread id. Before that, it represents a creation attempt.
  bool get isConfirmed => threadId.isNotEmpty;

  bool get isOpenable => threadId.isNotEmpty;

  /// Only an assigned collaborator may report actual work in progress.
  bool get showsProgressIndicator => isConfirmed && status.isActive;

  /// Excludes status and timeline position so an agent retains its visual identity.
  String get avatarIdentityKey => threadId.isNotEmpty
      ? threadId
      : path.isNotEmpty
      ? path
      : name;

  int avatarColorIndex(int paletteSize) {
    if (paletteSize <= 0) {
      throw ArgumentError.value(paletteSize, 'paletteSize', 'must be positive');
    }
    final remainder = avatarIdentityKey.hashCode.remainder(paletteSize);
    return remainder < 0 ? remainder + paletteSize : remainder;
  }
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
        pendingAgents.add(entry);
      } else {
        flushAgents();
        rows.add(TimelineEntryRenderRow(entry));
      }
    }
    flushAgents();
    return List.unmodifiable(rows);
  }

  /// Returns the latest stable display state for each sub-agent.
  List<SubAgentPresentation> toSubAgentPresentations() {
    final agents = <String, SubAgentPresentation>{};
    for (var index = 0; index < length; index += 1) {
      final entry = this[index];
      if (entry.kind != TimelineKind.subAgent) continue;

      final candidate = _toSubAgentPresentation(entry, index);
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
    final statuses = confirmedAgents.map((agent) => agent.status).toSet();
    final isActive = confirmedAgents.any((agent) => agent.status.isActive);
    final status = switch (statuses.length) {
      0 when agents.isNotEmpty => SubAgentDisplayStatus.preparing,
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
  final name = _leafName(path);
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
  final name = next.name == '智能体' ? current.name : next.name;
  final path = next.path.isEmpty ? current.path : next.path;
  final summary = next.summary.isEmpty ? current.summary : next.summary;

  if (!current.status.isActive && next.status.isActive && sameOrUnknownTurn) {
    return SubAgentPresentation(
      threadId: current.threadId,
      name: name,
      path: path,
      turnId: current.turnId,
      status: current.status,
      summary: summary,
      timelineIndex: next.timelineIndex,
    );
  }

  return SubAgentPresentation(
    threadId: next.threadId,
    name: name,
    path: path,
    turnId: next.turnId,
    status: next.status,
    summary: summary,
    timelineIndex: next.timelineIndex,
  );
}
