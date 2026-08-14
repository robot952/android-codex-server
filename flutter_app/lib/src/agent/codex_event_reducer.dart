import '../domain/models.dart';
import 'codex_protocol.dart';

/// Applies one Codex app-server notification to the Flutter domain state.
///
/// Notifications can describe a background thread while another thread is
/// open. Runtime fields are therefore updated in the thread list for every
/// event, while timeline and turn fields are changed only for the active
/// thread. The reducer is pure so protocol behavior can be tested without an
/// SSH channel or a widget tree.
AppUiState reduceCodexNotification(
  AppUiState state,
  CodexRpcNotification notification, {
  int? nowMillis,
}) {
  final method = notification.method;
  final params = notification.params;
  final threadId = _string(params, const ['threadId', 'thread_id']);
  final activeThreadId = state.activeThread?.id;
  final appliesToActive =
      threadId == activeThreadId ||
      (threadId.isEmpty &&
          (state.screen != AppScreen.agentWork ||
              activeThreadId == null ||
              activeThreadId.isEmpty));
  final now = nowMillis ?? DateTime.now().millisecondsSinceEpoch;

  AppUiState updateRuntime(
    AppUiState current, {
    required String status,
    String? activeTurnId,
  }) {
    if (threadId.isEmpty) return current;
    var next = _updateListedThread(current, threadId, (thread) {
      return thread.copyWith(status: status, activeTurnId: activeTurnId);
    });
    if (appliesToActive && next.activeThread?.id == threadId) {
      next = next.copyWith(
        activeThread: next.activeThread!.copyWith(
          status: status,
          activeTurnId: activeTurnId,
        ),
      );
    }
    return next;
  }

  switch (method) {
    case 'turn/started':
      final turn = _map(params['turn']);
      final turnId = _string(turn, const ['id', 'turnId', 'turn_id']);
      final resolvedTurnId = turnId.isNotEmpty
          ? turnId
          : _string(params, const ['turnId', 'turn_id']);
      var next = updateRuntime(
        state,
        status: 'active',
        activeTurnId: resolvedTurnId.isEmpty ? null : resolvedTurnId,
      );
      if (!appliesToActive) return next;
      final activeId = activeThreadId ?? threadId;
      final currentTiming = next.turnTiming;
      final timing = activeId.isEmpty
          ? currentTiming
          : currentTiming?.threadId == activeId &&
                currentTiming?.completedAtMillis == null
          ? currentTiming!.copyWith(
              turnId: resolvedTurnId.isEmpty
                  ? currentTiming.turnId
                  : resolvedTurnId,
            )
          : TurnTiming(
              threadId: activeId,
              turnId: resolvedTurnId.isEmpty ? null : resolvedTurnId,
              startedAtMillis: now,
            );
      next = next.copyWith(
        activeTurnId: resolvedTurnId.isEmpty
            ? next.activeTurnId
            : resolvedTurnId,
        running: true,
        turnTiming: timing,
      );
      return next;

    case 'turn/completed':
      final turn = _map(params['turn']);
      final completedId = _string(turn, const ['id', 'turnId', 'turn_id']);
      if (appliesToActive &&
          completedId.isNotEmpty &&
          state.activeTurnId?.isNotEmpty == true &&
          state.activeTurnId != completedId) {
        // A completion from an older turn can arrive after a new turn starts.
        // It must not stop the active turn or clear its list spinner.
        return state;
      }
      final resolvedTurnId = completedId.isNotEmpty
          ? completedId
          : (state.activeTurnId ?? '');
      final turnStatus = _wireStatus(turn?['status']);
      var next = updateRuntime(state, status: 'idle', activeTurnId: null);
      if (!appliesToActive) return next;
      final errorObject = _map(turn?['error']);
      final error = _string(errorObject, const [
        'message',
      ]).ifEmpty(() => _string(turn, const ['error']));
      final timing = next.turnTiming;
      final timingThreadId = activeThreadId ?? threadId;
      final completedTiming =
          timing != null &&
              timing.threadId == timingThreadId &&
              timing.completedAtMillis == null
          ? timing.copyWith(
              turnId: resolvedTurnId.isEmpty ? timing.turnId : resolvedTurnId,
              completedAtMillis: now,
              stopped: timing.stopped || _isStoppedStatus(turnStatus),
            )
          : timing;
      next = next.copyWith(
        activeTurnId: null,
        running: false,
        timeline: _completeSubAgentsForTurn(
          next.timeline,
          resolvedTurnId,
          _subAgentStatusForTurn(turnStatus),
        ),
        turnTiming: completedTiming,
        error: error.isEmpty ? next.error : error,
      );
      return next;

    case 'thread/status/changed':
      if (threadId.isEmpty) return state;
      final status = _wireStatus(params['status']);
      if (status.isEmpty) return state;
      final listedTurnId = _listedTurnId(state, threadId);
      final announcedTurnId = _string(params, const [
        'activeTurnId',
        'active_turn_id',
        'turnId',
        'turn_id',
      ]);
      final turnId = status == 'active'
          ? (announcedTurnId.isNotEmpty
                ? announcedTurnId
                : (appliesToActive
                      ? (state.activeTurnId ?? listedTurnId)
                      : listedTurnId))
          : null;
      final previousActiveTurnId = state.activeTurnId;
      var next = updateRuntime(state, status: status, activeTurnId: turnId);
      if (!appliesToActive) return next;
      final timingThreadId = activeThreadId ?? threadId;
      final timing = status == 'active'
          ? _startTiming(next.turnTiming, timingThreadId, turnId, now)
          : _completeTiming(
              next.turnTiming,
              timingThreadId,
              previousActiveTurnId,
              now,
              stopped: _isStoppedStatus(status),
            );
      return next.copyWith(
        running: status == 'active',
        activeTurnId: turnId,
        turnTiming: timing,
      );

    case 'thread/tokenUsage/updated':
      if (!appliesToActive) return state;
      final usage = CodexPayloadParser.parseTokenUsage(params);
      if (usage == null) return state;
      final previous = state.tokenUsage;
      if (usage.hasKnownContextWindow ||
          previous?.hasKnownContextWindow != true) {
        return state.copyWith(tokenUsage: usage);
      }
      return state;

    case 'thread/name/updated':
      if (!appliesToActive || state.activeThread == null) return state;
      final name = _string(params, const ['name', 'title']);
      if (name.isEmpty) return state;
      final active = state.activeThread!.copyWith(title: name);
      final nextThreads = _replaceThread(
        state.threads,
        active.id,
        (_) => active,
      );
      return state.copyWith(activeThread: active, threads: nextThreads);

    case 'thread/goal/updated':
      if (!appliesToActive) return state;
      final goalMap = _map(params['goal']);
      if (goalMap == null) return state;
      return state.copyWith(activeGoal: _parseGoal(goalMap, threadId));

    case 'thread/goal/cleared':
      return appliesToActive ? state.copyWith(activeGoal: null) : state;

    case 'item/started' || 'item/completed':
      if (!appliesToActive) return state;
      final item = _map(params['item']);
      if (item == null) return state;
      final itemType = _string(item, const ['type']);
      var entry = CodexPayloadParser.parseItem(item, turnId: _turnId(params));
      if (entry == null) return state;
      if (entry.kind == TimelineKind.command &&
          method == 'item/completed' &&
          entry.status.trim().isEmpty) {
        entry = entry.copyWith(status: 'completed');
      }
      if (itemType == 'contextCompaction') {
        entry = entry.copyWith(
          text: method == 'item/started' ? '正在压缩上下文' : '上下文已压缩',
          status: method == 'item/started' ? 'inProgress' : 'completed',
        );
      }
      var timeline = _upsertTimeline(
        state.timeline,
        entry,
        allowEmptyOptimisticUserMatch: method == 'item/started',
      );
      if (itemType == 'collabAgentToolCall') {
        timeline = _applySubAgentStates(timeline, item, entry.turnId);
      }
      return state.copyWith(timeline: timeline);

    case 'item/agentMessage/delta':
      if (!appliesToActive) return state;
      final id = _string(params, const ['itemId', 'item_id']);
      if (id.isEmpty) return state;
      final turn = _turnId(params);
      return state.copyWith(
        timeline: _updateTimelineEntry(
          state.timeline,
          id: id,
          kind: TimelineKind.agentMessage,
          turnId: turn,
          update: (existing) =>
              (existing ??
                      TimelineEntry(
                        id: id,
                        kind: TimelineKind.agentMessage,
                        turnId: turn,
                      ))
                  .copyWith(
                    text: _appendBounded(
                      existing?.text ?? '',
                      _string(params, const ['delta']),
                      codexMaxTimelineTextChars,
                      codexTextTruncationMarker,
                    ),
                  ),
        ),
      );

    case 'item/reasoning/summaryPartAdded' ||
        'item/reasoning/summaryTextDelta' ||
        'item/reasoning/textDelta':
      if (!appliesToActive) return state;
      return state.copyWith(
        timeline: _reduceReasoningDelta(state.timeline, params),
      );

    case 'item/plan/delta':
      if (!appliesToActive) return state;
      return state.copyWith(
        timeline: _reduceTextDelta(
          state.timeline,
          params,
          kind: TimelineKind.plan,
          title: '计划',
        ),
      );

    case 'item/commandExecution/outputDelta':
      if (!appliesToActive) return state;
      final id = _string(params, const ['itemId', 'item_id']);
      if (id.isEmpty) return state;
      final turn = _turnId(params);
      final existing = _findTimelineEntry(
        state.timeline,
        id: id,
        kind: TimelineKind.command,
        turnId: turn,
      );
      final entry =
          (existing ??
                  TimelineEntry(
                    id: id,
                    kind: TimelineKind.command,
                    title: '终端',
                    status: 'inProgress',
                    turnId: turn,
                  ))
              .copyWith(
                output: _appendBounded(
                  existing?.output ?? '',
                  _string(params, const ['delta']),
                  codexMaxCommandOutputChars,
                  codexOutputTruncationMarker,
                ),
              );
      return state.copyWith(timeline: _upsertTimeline(state.timeline, entry));

    case 'item/fileChange/patchUpdated':
      if (!appliesToActive) return state;
      final id = _string(params, const ['itemId', 'item_id']);
      if (id.isEmpty) return state;
      final changes = params['changes'];
      final item = <String, Object?>{
        'id': id,
        'type': 'fileChange',
        'status': 'inProgress',
        'changes': changes,
      };
      final parsed = CodexPayloadParser.parseItem(
        item,
        turnId: _turnId(params),
      );
      if (parsed == null) return state;
      final previous = _findTimelineEntry(
        state.timeline,
        id: id,
        kind: TimelineKind.fileChange,
        turnId: parsed.turnId,
      );
      final merged = previous == null
          ? parsed
          : parsed.copyWith(
              status: parsed.status.isEmpty ? previous.status : parsed.status,
              changes: parsed.changes.isEmpty
                  ? previous.changes
                  : parsed.changes,
              turnId: parsed.turnId.isEmpty ? previous.turnId : parsed.turnId,
            );
      return state.copyWith(timeline: _upsertTimeline(state.timeline, merged));

    case 'turn/diff/updated':
      if (!appliesToActive) return state;
      return state.copyWith(
        aggregateDiff: _bounded(
          _string(params, const ['diff']),
          codexMaxAggregateDiffChars,
          codexDiffTruncationMarker,
        ),
      );

    case 'error' || 'warning' || 'deprecationNotice' || 'guardianWarning':
      final message = _string(params, const ['message', 'error']);
      if (message.isEmpty || !appliesToActive) return state;
      return state.copyWith(
        timeline: [
          ...state.timeline,
          TimelineEntry(
            id: 'notice-${now.toString()}',
            kind: TimelineKind.notice,
            text: _bounded(
              message,
              codexMaxTimelineTextChars,
              codexTextTruncationMarker,
            ),
          ),
        ],
      );
    default:
      return state;
  }
}

AppUiState _updateListedThread(
  AppUiState state,
  String threadId,
  AgentThread Function(AgentThread thread) update,
) {
  final index = state.threads.indexWhere((thread) => thread.id == threadId);
  if (index < 0) return state;
  final threads = List<AgentThread>.of(state.threads);
  threads[index] = update(threads[index]);
  return state.copyWith(threads: List<AgentThread>.unmodifiable(threads));
}

List<AgentThread> _replaceThread(
  List<AgentThread> threads,
  String id,
  AgentThread Function(AgentThread thread) update,
) {
  final index = threads.indexWhere((thread) => thread.id == id);
  if (index < 0) return threads;
  final result = List<AgentThread>.of(threads);
  result[index] = update(result[index]);
  return List<AgentThread>.unmodifiable(result);
}

String _turnId(Map<String, Object?> params) {
  final direct = _string(params, const ['turnId', 'turn_id']);
  if (direct.isNotEmpty) return direct;
  return _string(_map(params['turn']), const ['id', 'turnId', 'turn_id']);
}

String _listedTurnId(AppUiState state, String threadId) =>
    state.threads
        .firstWhere(
          (thread) => thread.id == threadId,
          orElse: () => const AgentThread(id: ''),
        )
        .activeTurnId ??
    '';

TimelineEntry? _findTimelineEntry(
  List<TimelineEntry> entries, {
  required String id,
  required TimelineKind kind,
  required String turnId,
}) {
  for (final entry in entries) {
    if (_hasTimelineIdentity(entry, id: id, kind: kind, turnId: turnId)) {
      return entry;
    }
  }
  return null;
}

bool _hasTimelineIdentity(
  TimelineEntry entry, {
  required String id,
  required TimelineKind kind,
  required String turnId,
}) => entry.id == id && entry.kind == kind && entry.turnId == turnId;

List<TimelineEntry> _upsertTimeline(
  List<TimelineEntry> current,
  TimelineEntry incoming, {
  bool allowEmptyOptimisticUserMatch = false,
}) {
  final index = current.indexWhere(
    (entry) => _hasTimelineIdentity(
      entry,
      id: incoming.id,
      kind: incoming.kind,
      turnId: incoming.turnId,
    ),
  );
  final result = List<TimelineEntry>.of(current);
  if (index < 0) {
    // sendMessage() adds a local user row before the app-server has assigned an
    // item id. The live `item/started`/`item/completed` echo is authoritative;
    // fold it into that row instead of rendering the same prompt twice.
    final optimisticIndex = incoming.kind == TimelineKind.userMessage
        ? findMatchingOptimisticUserTimelineEntry(
            result,
            incoming,
            allowEmptyContent: allowEmptyOptimisticUserMatch,
          )
        : -1;
    final existingUserIndex = optimisticIndex >= 0
        ? optimisticIndex
        : incoming.kind == TimelineKind.userMessage
        ? findMatchingResumedUserTimelineEntry(result, incoming)
        : -1;
    if (existingUserIndex >= 0) {
      result[existingUserIndex] = mergeCodexTimelineEntry(
        result[existingUserIndex],
        incoming,
      );
    } else {
      result.add(incoming);
    }
  } else {
    result[index] = mergeCodexTimelineEntry(result[index], incoming);
  }
  return List<TimelineEntry>.unmodifiable(result);
}

/// Reconnects can replay a formal user item with a fresh id. Once the
/// optimistic row has already been replaced, keep that replay from creating
/// another identical bubble in the same turn.
int findMatchingResumedUserTimelineEntry(
  List<TimelineEntry> entries,
  TimelineEntry incoming,
) {
  if (incoming.kind != TimelineKind.userMessage ||
      incoming.turnId.trim().isEmpty ||
      incoming.text.trim().isEmpty) {
    return -1;
  }
  final incomingText = incoming.text.trim();
  for (var index = entries.length - 1; index >= 0; index -= 1) {
    final candidate = entries[index];
    if (candidate.kind != TimelineKind.userMessage ||
        candidate.turnId != incoming.turnId ||
        candidate.text.trim() != incomingText) {
      continue;
    }
    if (incoming.attachments.isNotEmpty &&
        !_sameAttachmentSet(candidate.attachments, incoming.attachments)) {
      continue;
    }
    return index;
  }
  return -1;
}

int findMatchingOptimisticUserTimelineEntry(
  List<TimelineEntry> entries,
  TimelineEntry incoming, {
  required bool allowEmptyContent,
}) {
  final incomingText = incoming.text.trim();
  for (var index = entries.length - 1; index >= 0; index -= 1) {
    final candidate = entries[index];
    if (!candidate.id.startsWith('local-user-') ||
        candidate.kind != TimelineKind.userMessage) {
      continue;
    }
    if (incomingText.isEmpty) {
      if (!allowEmptyContent || incoming.attachments.isNotEmpty) continue;
      if (candidate.turnId.isNotEmpty &&
          incoming.turnId.isNotEmpty &&
          candidate.turnId != incoming.turnId) {
        continue;
      }
      return index;
    }
    if (candidate.text.trim() != incomingText) continue;
    if (incoming.attachments.isNotEmpty &&
        !_sameAttachmentSet(candidate.attachments, incoming.attachments)) {
      continue;
    }
    return index;
  }
  return -1;
}

bool _sameAttachmentSet(
  List<MessageAttachment> first,
  List<MessageAttachment> second,
) {
  if (first.length != second.length) return false;
  for (final attachment in second) {
    final found = first.any((candidate) {
      final sameIdentity = candidate.remotePath.isNotEmpty
          ? candidate.remotePath == attachment.remotePath
          : attachment.remotePath.isEmpty && candidate.name == attachment.name;
      return sameIdentity &&
          (candidate.mimeType == attachment.mimeType ||
              candidate.mimeType == 'image/*' ||
              attachment.mimeType == 'image/*');
    });
    if (!found) return false;
  }
  return true;
}

List<TimelineEntry> _updateTimelineEntry(
  List<TimelineEntry> current, {
  required String id,
  required TimelineKind kind,
  required String turnId,
  required TimelineEntry Function(TimelineEntry? existing) update,
}) {
  final result = List<TimelineEntry>.of(current);
  final index = result.indexWhere(
    (entry) => _hasTimelineIdentity(entry, id: id, kind: kind, turnId: turnId),
  );
  final next = update(index < 0 ? null : result[index]);
  if (index < 0) {
    result.add(next);
  } else {
    result[index] = next;
  }
  return List<TimelineEntry>.unmodifiable(result);
}

TimelineEntry mergeCodexTimelineEntry(
  TimelineEntry previous,
  TimelineEntry incoming,
) {
  final sameTurn =
      previous.turnId.isEmpty ||
      incoming.turnId.isEmpty ||
      previous.turnId == incoming.turnId;
  final mergedStatus =
      previous.kind == TimelineKind.subAgent &&
          _isTerminalSubAgentStatus(previous.status) &&
          _isActiveSubAgentStatus(incoming.status) &&
          sameTurn
      ? previous.status
      : incoming.status.isEmpty
      ? previous.status
      : incoming.status;
  return incoming.copyWith(
    title: incoming.title.isEmpty ? previous.title : incoming.title,
    text: incoming.text.isEmpty ? previous.text : incoming.text,
    status: mergedStatus,
    command: incoming.command.isEmpty ? previous.command : incoming.command,
    cwd: incoming.cwd.isEmpty ? previous.cwd : incoming.cwd,
    output: incoming.output.isEmpty ? previous.output : incoming.output,
    changes: incoming.changes.isEmpty ? previous.changes : incoming.changes,
    attachments: incoming.attachments.isEmpty
        ? previous.attachments
        : incoming.attachments,
    turnId: incoming.turnId.isEmpty ? previous.turnId : incoming.turnId,
    subAgentPath: incoming.subAgentPath.isEmpty
        ? previous.subAgentPath
        : incoming.subAgentPath,
    subAgentThreadId: incoming.subAgentThreadId.isEmpty
        ? previous.subAgentThreadId
        : incoming.subAgentThreadId,
    subAgentActivity: incoming.subAgentActivity.isEmpty
        ? previous.subAgentActivity
        : incoming.subAgentActivity,
    reasoningSummary: incoming.reasoningSummary.isEmpty
        ? previous.reasoningSummary
        : incoming.reasoningSummary,
    reasoningContent: incoming.reasoningContent.isEmpty
        ? previous.reasoningContent
        : incoming.reasoningContent,
  );
}

bool _isActiveSubAgentStatus(String status) => const <String>{
  'pendingInit',
  'running',
  'inProgress',
  'started',
  'interacted',
  'unknown',
}.contains(status);

bool _isTerminalSubAgentStatus(String status) => const <String>{
  'completed',
  'interrupted',
  'errored',
  'failed',
  'shutdown',
  'notFound',
}.contains(status);

String _subAgentStatusForTurn(String turnStatus) => switch (turnStatus.trim()) {
  'interrupted' => 'interrupted',
  'failed' || 'systemError' => 'errored',
  _ => 'completed',
};

List<TimelineEntry> _completeSubAgentsForTurn(
  List<TimelineEntry> timeline,
  String turnId,
  String terminalStatus,
) {
  if (turnId.isEmpty) return timeline;
  var changed = false;
  final result = timeline
      .map((entry) {
        if (entry.kind != TimelineKind.subAgent ||
            entry.turnId != turnId ||
            !_isActiveSubAgentStatus(entry.status)) {
          return entry;
        }
        changed = true;
        return entry.copyWith(status: terminalStatus);
      })
      .toList(growable: false);
  return changed ? List<TimelineEntry>.unmodifiable(result) : timeline;
}

List<TimelineEntry> _applySubAgentStates(
  List<TimelineEntry> timeline,
  Map<String, Object?> collabItem,
  String turnId,
) {
  final rawStates = _map(
    collabItem['agentsStates'] ?? collabItem['agents_states'],
  );
  if (rawStates == null || rawStates.isEmpty) return timeline;
  final states = <String, String>{};
  for (final raw in rawStates.entries) {
    final status = _string(_map(raw.value), const ['status']);
    if (raw.key.isNotEmpty &&
        (_isActiveSubAgentStatus(status) ||
            _isTerminalSubAgentStatus(status))) {
      states[raw.key] = status;
    }
  }
  if (states.isEmpty) return timeline;
  var changed = false;
  final result = timeline
      .map((entry) {
        if (entry.kind != TimelineKind.subAgent ||
            (turnId.isNotEmpty && entry.turnId != turnId)) {
          return entry;
        }
        final status = states[entry.subAgentThreadId];
        if (status == null ||
            !_isActiveSubAgentStatus(entry.status) ||
            status == entry.status) {
          return entry;
        }
        changed = true;
        return entry.copyWith(status: status);
      })
      .toList(growable: false);
  return changed ? List<TimelineEntry>.unmodifiable(result) : timeline;
}

List<TimelineEntry> _reduceTextDelta(
  List<TimelineEntry> timeline,
  Map<String, Object?> params, {
  required TimelineKind kind,
  required String title,
}) {
  final id = _string(params, const ['itemId', 'item_id']);
  if (id.isEmpty) return timeline;
  final turnId = _turnId(params);
  final existing = _findTimelineEntry(
    timeline,
    id: id,
    kind: kind,
    turnId: turnId,
  );
  final delta = _string(params, const ['delta']);
  final entry =
      (existing ??
              TimelineEntry(id: id, kind: kind, title: title, turnId: turnId))
          .copyWith(
            title: existing?.title.isNotEmpty == true ? existing!.title : title,
            text: _appendBounded(
              existing?.text ?? '',
              delta,
              codexMaxTimelineTextChars,
              codexTextTruncationMarker,
            ),
          );
  return _upsertTimeline(timeline, entry);
}

List<TimelineEntry> _reduceReasoningDelta(
  List<TimelineEntry> timeline,
  Map<String, Object?> params,
) {
  final id = _string(params, const ['itemId', 'item_id']);
  if (id.isEmpty) return timeline;
  final turnId = _turnId(params);
  final existing =
      _findTimelineEntry(
        timeline,
        id: id,
        kind: TimelineKind.reasoning,
        turnId: turnId,
      ) ??
      TimelineEntry(
        id: id,
        kind: TimelineKind.reasoning,
        title: '思考过程',
        turnId: turnId,
      );
  final summary = List<String>.of(existing.reasoningSummary);
  final content = List<String>.of(existing.reasoningContent);
  // The caller does not pass method in params, so infer the index fields and
  // update the summary for summary notifications; text deltas use contentIndex.
  final summaryIndex = _int(params, const ['summaryIndex', 'summary_index']);
  final contentIndex = _int(params, const ['contentIndex', 'content_index']);
  final delta = _string(params, const ['delta', 'text']);
  if (params.containsKey('summaryIndex') ||
      params.containsKey('summary_index')) {
    _appendIndexed(summary, summaryIndex, delta);
  } else if (params.containsKey('contentIndex') ||
      params.containsKey('content_index')) {
    _appendIndexed(content, contentIndex, delta);
  } else {
    _appendIndexed(summary, summary.length, delta);
  }
  final text = _bounded(
    [...summary, ...content].where((part) => part.isNotEmpty).join('\n'),
    codexMaxTimelineTextChars,
    codexTextTruncationMarker,
  );
  return _upsertTimeline(
    timeline,
    existing.copyWith(
      text: text,
      reasoningSummary: List<String>.unmodifiable(summary),
      reasoningContent: List<String>.unmodifiable(content),
    ),
  );
}

void _appendIndexed(List<String> values, int index, String delta) {
  if (index < 0 || index > 128) return;
  while (values.length <= index) {
    values.add('');
  }
  values[index] = _bounded(
    '${values[index]}$delta',
    codexMaxTimelineTextChars,
    codexTextTruncationMarker,
  );
}

TurnTiming? _startTiming(
  TurnTiming? current,
  String threadId,
  String? turnId,
  int now,
) {
  if (threadId.isEmpty) return current;
  if (current?.threadId == threadId && current?.completedAtMillis == null) {
    return current!.copyWith(
      turnId: turnId?.isEmpty == true ? current.turnId : turnId,
    );
  }
  return TurnTiming(threadId: threadId, turnId: turnId, startedAtMillis: now);
}

TurnTiming? _completeTiming(
  TurnTiming? current,
  String threadId,
  String? turnId,
  int now, {
  required bool stopped,
}) {
  if (current == null ||
      current.threadId != threadId ||
      current.completedAtMillis != null) {
    return current;
  }
  return current.copyWith(
    turnId: turnId?.isEmpty == true ? current.turnId : turnId,
    completedAtMillis: now,
    stopped: current.stopped || stopped,
  );
}

bool _isStoppedStatus(String status) => switch (status.toLowerCase()) {
  'interrupted' || 'stopped' || 'aborted' || 'cancelled' || 'canceled' => true,
  _ => false,
};

ThreadGoal _parseGoal(Map<String, Object?> value, String fallbackThreadId) =>
    ThreadGoal(
      threadId: _string(value, const ['threadId', 'thread_id']).isEmpty
          ? fallbackThreadId
          : _string(value, const ['threadId', 'thread_id']),
      objective: _string(value, const ['objective', 'goal']),
      status: ThreadGoalStatus.fromWire(_string(value, const ['status'])),
      createdAt: _int(value, const ['createdAt', 'created_at']),
      updatedAt: _int(value, const ['updatedAt', 'updated_at']),
      timeUsedSeconds: _int(value, const [
        'timeUsedSeconds',
        'time_used_seconds',
      ]),
      tokensUsed: _int(value, const ['tokensUsed', 'tokens_used']),
      tokenBudget: _nullableInt(value, const ['tokenBudget', 'token_budget']),
    );

Map<String, Object?>? _map(Object? value) => value is Map
    ? <String, Object?>{
        for (final entry in value.entries)
          if (entry.key is String) entry.key as String: entry.value,
      }
    : null;

String _string(Map<String, Object?>? value, List<String> keys) {
  if (value == null) return '';
  for (final key in keys) {
    final candidate = value[key];
    if (candidate is String) return candidate;
    if (candidate is num || candidate is bool) return candidate.toString();
  }
  return '';
}

String _wireStatus(Object? value) {
  if (value is String) return value;
  return _string(_map(value), const ['type', 'status']);
}

int _int(Map<String, Object?>? value, List<String> keys) {
  if (value == null) return 0;
  for (final key in keys) {
    final candidate = value[key];
    if (candidate is int) return candidate;
    if (candidate is num && candidate.isFinite) return candidate.toInt();
    if (candidate is String) {
      final parsed = int.tryParse(candidate);
      if (parsed != null) return parsed;
    }
  }
  return 0;
}

int? _nullableInt(Map<String, Object?> value, List<String> keys) {
  final result = _int(value, keys);
  return result == 0 && keys.every((key) => !value.containsKey(key))
      ? null
      : result;
}

String _appendBounded(String current, String delta, int limit, String marker) =>
    _bounded('$current$delta', limit, marker);

String _bounded(String value, int limit, String marker) {
  if (value.length <= limit) return value;
  final markerLength = marker.length < limit ? marker.length : limit;
  final contentLength = limit - markerLength;
  return '${value.substring(0, contentLength)}${marker.substring(0, markerLength)}';
}

extension on String {
  String ifEmpty(String Function() fallback) => isEmpty ? fallback() : this;
}
