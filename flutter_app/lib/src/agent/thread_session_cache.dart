import 'dart:collection';

import '../domain/models.dart';

class ThreadSessionSnapshot {
  ThreadSessionSnapshot({
    required this.thread,
    required List<TimelineEntry> timeline,
    required this.savedAtEpochMillis,
    this.nextTurnsCursor,
    this.tokenUsage,
  }) : timeline = List.unmodifiable(timeline);

  final AgentThread thread;
  final List<TimelineEntry> timeline;
  final int savedAtEpochMillis;
  final String? nextTurnsCursor;
  final TokenUsage? tokenUsage;

  ThreadSessionSnapshot copyWith({TokenUsage? tokenUsage}) =>
      ThreadSessionSnapshot(
        thread: thread,
        timeline: timeline,
        savedAtEpochMillis: savedAtEpochMillis,
        nextTurnsCursor: nextTurnsCursor,
        tokenUsage: tokenUsage ?? this.tokenUsage,
      );
}

/// Per-server in-memory cache used to render a resumed thread immediately.
class ThreadSessionCache {
  ThreadSessionCache({
    this.maxEntries = defaultMaxEntries,
    this.ttl = defaultTtl,
    this.maxWeightChars = defaultMaxWeightChars,
    int Function()? nowEpochMillis,
  }) : _nowEpochMillis =
           nowEpochMillis ?? (() => DateTime.now().millisecondsSinceEpoch) {
    if (maxEntries < 1) throw ArgumentError.value(maxEntries, 'maxEntries');
    if (ttl <= Duration.zero) throw ArgumentError.value(ttl, 'ttl');
    if (maxWeightChars < 1) {
      throw ArgumentError.value(maxWeightChars, 'maxWeightChars');
    }
  }

  static const defaultMaxEntries = 8;
  static const defaultTtl = Duration(minutes: 30);
  static const defaultMaxWeightChars = 2 * 1024 * 1024;
  static const _contextUsageEntriesPerTranscript = 4;

  final int maxEntries;
  final Duration ttl;
  final int maxWeightChars;
  final int Function() _nowEpochMillis;
  final LinkedHashMap<String, _WeightedSnapshot> _entries = LinkedHashMap();
  final LinkedHashMap<String, TokenUsage> _contextUsages = LinkedHashMap();
  int _currentWeightChars = 0;

  int get length => _entries.length;

  ThreadSessionSnapshot? get(String threadId) {
    final weighted = _touch(_entries, threadId);
    final snapshot = weighted?.snapshot;
    if (snapshot == null) return null;
    if (_nowEpochMillis() - snapshot.savedAtEpochMillis > ttl.inMilliseconds) {
      return null;
    }
    return _withLatestContextUsage(snapshot, threadId);
  }

  /// Returns an expired snapshot too, for a timeout fallback while reconnecting.
  ThreadSessionSnapshot? getStale(String threadId) {
    final snapshot = _touch(_entries, threadId)?.snapshot;
    return snapshot == null
        ? null
        : _withLatestContextUsage(snapshot, threadId);
  }

  TokenUsage? contextUsage(String threadId) => _touch(_contextUsages, threadId);

  void put(
    AgentThread thread,
    List<TimelineEntry> timeline, {
    String? nextTurnsCursor,
    TokenUsage? tokenUsage,
  }) {
    if (tokenUsage?.hasKnownContextWindow ?? false) {
      _contextUsages.remove(thread.id);
      _contextUsages[thread.id] = tokenUsage!;
      while (_contextUsages.length > _maxContextUsageEntries) {
        _contextUsages.remove(_contextUsages.keys.first);
      }
    }

    final weight = _snapshotWeight(thread, timeline, nextTurnsCursor);
    if (weight > maxWeightChars) return;

    _removeSnapshot(thread.id);
    final snapshot = ThreadSessionSnapshot(
      thread: thread,
      timeline: timeline,
      savedAtEpochMillis: _nowEpochMillis(),
      nextTurnsCursor: nextTurnsCursor,
      tokenUsage: _touch(_contextUsages, thread.id),
    );
    _entries[thread.id] = _WeightedSnapshot(snapshot, weight);
    _currentWeightChars += weight;
    while (_entries.length > maxEntries ||
        _currentWeightChars > maxWeightChars) {
      _removeSnapshot(_entries.keys.first);
    }
  }

  void remove(String threadId) {
    _removeSnapshot(threadId);
    _contextUsages.remove(threadId);
  }

  /// Marks a completed child thread in every retained parent transcript.
  ///
  /// Child turns are delivered on their own thread, so their terminal event
  /// would otherwise wait for the parent turn to end before its cached
  /// collaborator rows are refreshed.
  bool updateSubAgentStatus(String subAgentThreadId, String status) {
    final childId = subAgentThreadId.trim();
    final nextStatus = status.trim();
    if (childId.isEmpty || nextStatus.isEmpty || _entries.isEmpty) return false;

    var changed = false;
    for (final entry in _entries.entries.toList(growable: false)) {
      final snapshot = entry.value.snapshot;
      var timelineChanged = false;
      final timeline = snapshot.timeline
          .map((item) {
            if (item.kind != TimelineKind.subAgent ||
                item.subAgentThreadId != childId ||
                !_isActiveSubAgentStatus(item.status) ||
                item.status == nextStatus) {
              return item;
            }
            timelineChanged = true;
            return item.copyWith(status: nextStatus);
          })
          .toList(growable: false);
      if (!timelineChanged) continue;

      final replacement = ThreadSessionSnapshot(
        thread: snapshot.thread,
        timeline: timeline,
        savedAtEpochMillis: snapshot.savedAtEpochMillis,
        nextTurnsCursor: snapshot.nextTurnsCursor,
        tokenUsage: snapshot.tokenUsage,
      );
      final nextWeight = _snapshotWeight(
        replacement.thread,
        replacement.timeline,
        replacement.nextTurnsCursor,
      );
      _entries[entry.key] = _WeightedSnapshot(replacement, nextWeight);
      _currentWeightChars += nextWeight - entry.value.weightChars;
      changed = true;
    }
    while (_entries.length > maxEntries ||
        _currentWeightChars > maxWeightChars) {
      _removeSnapshot(_entries.keys.first);
    }
    return changed;
  }

  void clear() {
    _entries.clear();
    _contextUsages.clear();
    _currentWeightChars = 0;
  }

  int get _maxContextUsageEntries =>
      maxEntries * _contextUsageEntriesPerTranscript;

  ThreadSessionSnapshot _withLatestContextUsage(
    ThreadSessionSnapshot snapshot,
    String threadId,
  ) {
    final latest = _touch(_contextUsages, threadId);
    return latest == null ? snapshot : snapshot.copyWith(tokenUsage: latest);
  }

  void _removeSnapshot(String threadId) {
    final removed = _entries.remove(threadId);
    if (removed != null) _currentWeightChars -= removed.weightChars;
  }

  int _snapshotWeight(
    AgentThread thread,
    List<TimelineEntry> timeline,
    String? nextTurnsCursor,
  ) {
    var result =
        thread.id.length +
        thread.title.length +
        thread.preview.length +
        thread.cwd.length +
        thread.source.length +
        thread.status.length +
        thread.cliVersion.length +
        (nextTurnsCursor?.length ?? 0);
    result += estimateTimelineWeightChars(timeline);
    return result;
  }
}

class _WeightedSnapshot {
  const _WeightedSnapshot(this.snapshot, this.weightChars);

  final ThreadSessionSnapshot snapshot;
  final int weightChars;
}

V? _touch<V>(LinkedHashMap<String, V> values, String key) {
  final value = values.remove(key);
  if (value != null) values[key] = value;
  return value;
}

bool _isActiveSubAgentStatus(String status) => const <String>{
  'pendingInit',
  'running',
  'inProgress',
  'started',
  'interacted',
  'unknown',
}.contains(status);

int estimateTimelineWeightChars(List<TimelineEntry> timeline) {
  var result = 0;
  for (final entry in timeline) {
    result +=
        entry.id.length +
        entry.title.length +
        entry.text.length +
        entry.status.length +
        entry.command.length +
        entry.cwd.length +
        entry.output.length +
        entry.turnId.length +
        entry.subAgentPath.length +
        entry.subAgentThreadId.length +
        entry.subAgentActivity.length;
    for (final value in entry.reasoningSummary) {
      result += value.length;
    }
    for (final value in entry.reasoningContent) {
      result += value.length;
    }
    for (final change in entry.changes) {
      result += change.path.length + change.kind.length + change.diff.length;
    }
    for (final attachment in entry.attachments) {
      result +=
          attachment.name.length +
          attachment.remotePath.length +
          attachment.mimeType.length;
    }
  }
  return result;
}
