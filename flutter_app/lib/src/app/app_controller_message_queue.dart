part of 'app_controller.dart';

const _maxQueuedMessagesPerThread = 20;
const _maxQueuedMessagesTotal = 100;
const _maxQueuedTextChars = 1024 * 1024;

class _QueuedMessageEntry {
  _QueuedMessageEntry(
    this.message,
    this.settings, {
    this.restoreComposer = false,
    this.visibleInQueue = true,
    this.originalDraft,
  });

  QueuedMessage message;
  final AppUiState settings;
  final bool restoreComposer;
  // Immediate sends share FIFO's dispatch lease and failure handling, but are
  // represented by the composer's busy button instead of a temporary queue row.
  bool visibleInQueue;
  String? originalDraft;
}

class _ThreadMessageQueue {
  _ThreadMessageQueue({
    required this.key,
    required this.profile,
    required this.thread,
    required this.generation,
    required this.running,
    required this.turnId,
  });

  final AgentConnectionKey key;
  final ServerProfile profile;
  final AgentThread thread;
  int generation;
  final List<_QueuedMessageEntry> items = [];
  final Set<String> completedTurns = {};
  bool running;
  String? turnId;
  bool paused = false;
  bool invalidated = false;
  String? pauseReason;
  Future<void>? dispatch;
  int revision = 0;

  String get storageKey =>
      threadPreferenceKey(key.profileId, key.agent, thread.id);
}

class _IndependentMessageSend {
  _IndependentMessageSend(this.queue) : revision = queue.revision;

  final _ThreadMessageQueue queue;
  final int revision;
  final Completer<void> completion = Completer<void>();
}

extension MessageQueueController on AppController {
  // Question replies bypass FIFO, but still share its per-thread dispatch
  // lease. A turn/completed notification must not start the queue while a
  // question's start/steer RPC is still in flight (including off-screen).
  _IndependentMessageSend? _beginIndependentMessageSend(
    ServerProfile profile,
    AgentConnectionKey key,
    AgentThread thread,
  ) {
    final storageKey = threadPreferenceKey(profile.id, key.agent, thread.id);
    final queue = _messageQueues.putIfAbsent(
      storageKey,
      () => _ThreadMessageQueue(
        key: key,
        profile: profile,
        thread: thread,
        generation: _agents.generation(key),
        running: state.running,
        turnId: state.activeTurnId,
      ),
    );
    if (queue.dispatch != null || !_queueProfileMatches(queue)) return null;
    final lease = _IndependentMessageSend(queue);
    queue.dispatch = lease.completion.future;
    return lease;
  }

  void _finishIndependentMessageSend(
    _IndependentMessageSend lease, {
    String? acceptedTurnId,
    required bool failed,
  }) {
    final queue = lease.queue;
    if (mounted && _queueProfileMatches(queue)) {
      if (acceptedTurnId != null &&
          lease.revision == queue.revision &&
          !queue.completedTurns.contains(acceptedTurnId)) {
        queue.running = true;
        queue.turnId = acceptedTurnId;
      } else if (failed) {
        _pauseMessageQueue(queue.key, queue.thread.id, '发送未获确认，请核对对话后点击“引导”继续');
      }
    }
    queue.dispatch = null;
    lease.completion.complete();
    if (mounted) _scheduleMessageQueue(queue);
  }

  Iterable<PendingAttachment> get _queuedAttachments => _messageQueues.values
      .expand((queue) => queue.items)
      .expand((entry) => entry.message.attachments);

  _ThreadMessageQueue? _queueContaining(String id) =>
      _messageQueues.values.firstWhereOrNull(
        (queue) => queue.items.any((entry) => entry.message.id == id),
      );

  bool _queueIsVisible(_ThreadMessageQueue queue) =>
      mounted &&
      identical(_messageQueues[queue.storageKey], queue) &&
      _isActiveThread(queue.key, queue.thread.id) &&
      state.screen == AppScreen.work;

  bool _queueProfileMatches(_ThreadMessageQueue queue) {
    if (!mounted ||
        queue.invalidated ||
        !identical(_messageQueues[queue.storageKey], queue)) {
      return false;
    }
    final profile = state.profiles.firstWhereOrNull(
      (p) => p.id == queue.key.profileId,
    );
    return profile != null &&
        profile.hasSameConnectionIdentity(queue.profile) &&
        profile.remoteCommand == queue.profile.remoteCommand &&
        profile.workspace == queue.profile.workspace &&
        _agentVersion(profile, queue.key.agent) ==
            _agentVersion(queue.profile, queue.key.agent);
  }

  void _refreshMessageQueue() {
    if (mounted) state = state.copyWith();
  }

  Future<void> _enqueueComposerMessage({String? text}) async {
    await _ensureInitialized();
    if (!mounted ||
        state.isThreadReadOnly ||
        state.loading ||
        state.messageSending) {
      return;
    }
    final profileId = state.selectedProfileId;
    final thread = state.activeThread;
    final profile = state.profiles.firstWhereOrNull((p) => p.id == profileId);
    if (profile == null || thread == null) return;
    final draftBeforeSend = text ?? state.composerDraft;
    final content = draftBeforeSend.trimRight();
    final attachments = List<PendingAttachment>.unmodifiable(state.attachments);
    if (content.trim().isEmpty && attachments.isEmpty) return;
    final key = AgentConnectionKey(
      profileId: profile.id,
      agent: state.activeAgent,
    );
    final storageKey = threadPreferenceKey(profile.id, key.agent, thread.id);
    final existing = _messageQueues[storageKey];
    if (existing != null && !_queueProfileMatches(existing)) {
      state = state.copyWith(error: '服务器配置已改变，请先删除旧队列再重新发送');
      return;
    }
    final totalEntries = _messageQueues.values.expand((q) => q.items).toList();
    if ((existing?.items.length ?? 0) >= _maxQueuedMessagesPerThread ||
        totalEntries.length >= _maxQueuedMessagesTotal ||
        totalEntries.fold<int>(
              content.length,
              (sum, entry) => sum + entry.message.text.length,
            ) >
            _maxQueuedTextChars) {
      state = state.copyWith(error: '待发送队列已满，请等待发送或删除部分消息');
      return;
    }
    final queue =
        existing ??
        _ThreadMessageQueue(
          key: key,
          profile: profile,
          thread: thread,
          generation: _agents.generation(key),
          running: state.running || state.submitting,
          turnId: state.activeTurnId,
        );
    _messageQueues[storageKey] = queue;
    // Empty queues are retained only while their accepted turn is active. A
    // new explicit send after a stopped, empty queue establishes a fresh lane.
    if (queue.items.isEmpty && queue.dispatch == null) {
      queue.running = state.running || state.submitting;
      queue.turnId = state.activeTurnId;
      queue.paused = false;
      queue.pauseReason = null;
      queue.generation = _agents.generation(key);
    }
    final sendImmediately =
        queue.items.isEmpty &&
        !queue.running &&
        queue.dispatch == null &&
        !queue.paused;
    final entry = _QueuedMessageEntry(
      QueuedMessage(
        id: 'queued-${DateTime.now().microsecondsSinceEpoch}-${_queuedMessageSequence++}',
        text: content,
        attachments: attachments,
        error: queue.pauseReason,
      ),
      // Capture only send configuration. Do not retain the full transcript,
      // profile collection or another thread's attachment payloads per item.
      AppUiState(
        selectedModel: state.selectedModel,
        selectedEffort: state.selectedEffort,
        models: state.models,
        approvalMode: state.approvalMode,
        sandbox: state.sandbox,
      ),
      restoreComposer: sendImmediately,
      visibleInQueue: !sendImmediately,
      originalDraft: draftBeforeSend,
    );
    queue.items.add(entry);
    _flushPendingDraft();
    state = state.copyWith(
      composerDraft: '',
      attachments: const [],
      composerClearNonce: state.composerClearNonce + 1,
      error: queue.paused ? queue.pauseReason : null,
    );
    unawaited(
      _persist(
        (stored) => stored.copyWith(
          composerDrafts: {...stored.composerDrafts, storageKey: ''},
        ),
      ),
    );
    if (!queue.running &&
        queue.dispatch == null &&
        !queue.paused &&
        identical(queue.items.first, entry)) {
      await _dispatchQueuedMessage(queue, entry, steer: false);
    } else {
      _scheduleMessageQueue(queue);
    }
  }

  bool _beginEditQueuedMessage(String id) {
    final queue = _queueContaining(id);
    if (queue == null || !_queueIsVisible(queue) || state.isThreadReadOnly) {
      return false;
    }
    final entry = queue.items.firstWhere((e) => e.message.id == id);
    if (entry.message.sending || entry.message.editing) return false;
    entry.message = entry.message.copyWith(editing: true);
    _refreshMessageQueue();
    return true;
  }

  void _cancelEditQueuedMessage(String id) {
    final queue = _queueContaining(id);
    if (queue == null) return;
    final entry = queue.items.firstWhere((e) => e.message.id == id);
    entry.message = entry.message.copyWith(editing: false);
    _refreshMessageQueue();
    _scheduleMessageQueue(queue);
  }

  bool _updateQueuedMessage(
    String id, {
    required String text,
    required List<PendingAttachment> attachments,
  }) {
    final queue = _queueContaining(id);
    if (queue == null || !_queueIsVisible(queue) || state.isThreadReadOnly) {
      return false;
    }
    final entry = queue.items.firstWhere((e) => e.message.id == id);
    final textChars = _messageQueues.values
        .expand((q) => q.items)
        .where((other) => !identical(other, entry))
        .fold<int>(
          text.length,
          (sum, other) => sum + other.message.text.length,
        );
    if (entry.message.sending ||
        (text.trim().isEmpty && attachments.isEmpty) ||
        attachments.length > maxPendingAttachmentCount ||
        textChars > _maxQueuedTextChars) {
      return false;
    }
    // The edit dialog may remove existing attachments; newly selected bytes
    // must pass the same bounded local preparation as the main composer.
    final bytes = attachments.fold<int>(
      0,
      (sum, a) => sum + (a.localUpload?.bytes.length ?? 0),
    );
    if (bytes > maxPendingAttachmentTotalBytes) return false;
    entry.message = entry.message.copyWith(
      text: text.trimRight(),
      attachments: List.unmodifiable(attachments),
      editing: false,
    );
    entry.originalDraft = text;
    _refreshMessageQueue();
    _scheduleMessageQueue(queue);
    return true;
  }

  void _deleteQueuedMessage(String id) {
    final queue = _queueContaining(id);
    if (queue == null || !_queueIsVisible(queue)) return;
    final entry = queue.items.firstWhere((e) => e.message.id == id);
    if (entry.message.sending) return;
    queue.items.remove(entry);
    _refreshMessageQueue();
    _scheduleMessageQueue(queue);
  }

  Future<void> _steerQueuedMessage(String id) async {
    final queue = _queueContaining(id);
    if (queue == null ||
        !_queueIsVisible(queue) ||
        state.isThreadReadOnly ||
        state.loading ||
        queue.dispatch != null) {
      return;
    }
    final entry = queue.items.firstWhere((e) => e.message.id == id);
    if (entry.message.editing || entry.message.sending) return;
    if (!_queueProfileMatches(queue)) {
      state = state.copyWith(error: '服务器配置已改变，请重新添加待发送消息');
      return;
    }
    if (_agents.states[queue.key]?.phase != ConnectionPhase.connected) {
      state = state.copyWith(error: '请先重新连接，再发送待发送消息');
      return;
    }
    queue.generation = _agents.generation(queue.key);
    queue.running = state.running;
    queue.turnId = state.activeTurnId;
    if (queue.running &&
        (queue.turnId?.isNotEmpty != true ||
            !_agents.capabilities(queue.key).steerTurn)) {
      state = state.copyWith(error: '当前回合暂不能引导，请稍后重试');
      return;
    }
    queue.paused = false;
    queue.pauseReason = null;
    for (final queued in queue.items) {
      queued.message = queued.message.copyWith(error: null);
    }
    await _dispatchQueuedMessage(queue, entry, steer: queue.running);
  }

  void _pauseMessageQueue(
    AgentConnectionKey key,
    String threadId,
    String reason,
  ) {
    final queue =
        _messageQueues[threadPreferenceKey(key.profileId, key.agent, threadId)];
    if (queue == null) return;
    queue.paused = true;
    queue.pauseReason = reason;
    queue.revision++;
    for (final entry in queue.items) {
      entry.message = entry.message.copyWith(error: reason);
    }
    _refreshMessageQueue();
  }

  void _pauseMessageQueuesForLane(AgentConnectionKey key, String reason) {
    for (final queue
        in _messageQueues.values.where((q) => q.key == key).toList()) {
      _pauseMessageQueue(key, queue.thread.id, reason);
    }
  }

  void _invalidateMessageQueuesForLane(AgentConnectionKey key, String reason) {
    for (final queue
        in _messageQueues.values.where((q) => q.key == key).toList()) {
      queue.invalidated = true;
      _pauseMessageQueue(key, queue.thread.id, reason);
    }
  }

  void _scheduleMessageQueue(_ThreadMessageQueue queue) {
    if (queue.items.isEmpty && queue.dispatch == null) {
      if (identical(_messageQueues[queue.storageKey], queue)) {
        _messageQueues.remove(queue.storageKey);
      }
      _refreshMessageQueue();
      return;
    }
    if (!mounted ||
        queue.paused ||
        queue.running ||
        queue.dispatch != null ||
        queue.items.isEmpty) {
      return;
    }
    final next = queue.items.first;
    if (next.message.editing) return;
    // Run after the current notification has reached the reducer/cache.
    scheduleMicrotask(() {
      if (!mounted ||
          queue.paused ||
          queue.running ||
          queue.dispatch != null ||
          queue.items.isEmpty ||
          !identical(queue.items.first, next) ||
          next.message.editing) {
        return;
      }
      unawaited(_dispatchQueuedMessage(queue, next, steer: false));
    });
  }

  void _observeMessageQueueEvent(AgentEventEnvelope envelope) {
    final event = envelope.event;
    if (event is RemoteAgentConnectionLost) {
      _pauseMessageQueuesForLane(envelope.key, '连接已中断，重连后点击“引导”发送');
      return;
    }
    if (event is! RemoteAgentNotification) return;
    final message = _withResolvedNotificationThreadId(event.message);
    final threadId = _notificationThreadId(message);
    final queue =
        _messageQueues[threadPreferenceKey(
          envelope.key.profileId,
          envelope.key.agent,
          threadId,
        )];
    if (queue == null ||
        !_queueProfileMatches(queue) ||
        queue.generation != _agents.generation(envelope.key)) {
      return;
    }
    final turn = _notificationMap(message.params['turn']);
    final turnId = _notificationString(turn, const ['id', 'turnId', 'turn_id'])
        .ifEmpty(
          () =>
              _notificationString(message.params, const ['turnId', 'turn_id']),
        );
    if (message.method == 'turn/started' && turnId.isNotEmpty) {
      if (queue.completedTurns.contains(turnId)) return;
      queue.running = true;
      queue.turnId = turnId;
    } else if (message.method == 'turn/completed' && turnId.isNotEmpty) {
      if (queue.completedTurns.contains(turnId) ||
          (queue.turnId != null && queue.turnId != turnId)) {
        return;
      }
      if (queue.turnId == null && queue.dispatch == null) return;
      queue.completedTurns.add(turnId);
      while (queue.completedTurns.length > 32) {
        queue.completedTurns.remove(queue.completedTurns.first);
      }
      queue.running = false;
      queue.turnId = null;
      final status = _notificationString(turn, const ['status']).toLowerCase();
      if (status != 'completed' ||
          turn?['error'] != null ||
          message.params['error'] != null) {
        _pauseMessageQueue(queue.key, threadId, '回合已中断或失败，点击“引导”继续发送');
      } else {
        _scheduleMessageQueue(queue);
      }
    } else if (const {
      'thread/archived',
      'thread/deleted',
      'thread/reverted',
      'thread/compacted',
    }.contains(message.method)) {
      _pauseMessageQueue(queue.key, threadId, '会话状态已改变，请确认后点击“引导”发送');
    }
  }

  Future<void> _dispatchQueuedMessage(
    _ThreadMessageQueue queue,
    _QueuedMessageEntry entry, {
    required bool steer,
  }) {
    if (queue.dispatch != null ||
        queue.paused ||
        !queue.items.contains(entry)) {
      return Future.value();
    }
    final completer = Completer<void>();
    queue.dispatch = completer.future;
    unawaited(() async {
      try {
        await _sendQueuedMessage(queue, entry, steer: steer);
      } finally {
        queue.dispatch = null;
        completer.complete();
        _scheduleMessageQueue(queue);
      }
    }());
    return completer.future;
  }

  Future<void> _sendQueuedMessage(
    _ThreadMessageQueue queue,
    _QueuedMessageEntry entry, {
    required bool steer,
  }) async {
    final revision = queue.revision;
    final steeringTurnId = steer ? queue.turnId : null;
    final optimisticId = 'local-user-${entry.message.id}';
    var optimisticAdded = false;
    var requestSent = false;
    bool current() =>
        _queueProfileMatches(queue) &&
        queue.revision == revision &&
        _agents.generation(queue.key) == queue.generation &&
        _agents.states[queue.key]?.phase == ConnectionPhase.connected &&
        (!_queueIsVisible(queue) || !state.isThreadReadOnly);
    bool steeringTargetIsCurrent() =>
        !steer ||
        (queue.running &&
            queue.turnId == steeringTurnId &&
            !queue.completedTurns.contains(steeringTurnId));
    entry.message = entry.message.copyWith(sending: true, error: null);
    _refreshMessageQueue();
    if (_queueIsVisible(queue)) {
      state = state.copyWith(
        submitting: true,
        attachmentUploading: entry.message.attachments.any(
          (a) => a.remotePath.isEmpty,
        ),
      );
    }
    try {
      if (!current()) throw StateError('连接或会话已改变，请确认后重试');
      final attachments = await _uploadMessageAttachments(
        queue.profile,
        entry.message.attachments,
        isCurrent: current,
      );
      if (!current()) throw StateError('发送已取消，消息仍保留在队列');
      if (!steeringTargetIsCurrent()) {
        throw StateError('原回合已结束，消息保留在队列；请确认后再次点击“引导”发送');
      }
      entry.message = entry.message.copyWith(attachments: attachments);
      if (_queueIsVisible(queue)) {
        state = state.copyWith(attachmentUploading: false);
      }
      final settings = entry.settings;
      final modelSettings = queue.profile.modelSettings(queue.key.agent);
      final model = settings.selectedModel?.trim().isNotEmpty == true
          ? settings.selectedModel
          : modelSettings.preferredModel.trim().isEmpty
          ? null
          : modelSettings.preferredModel.trim();
      final requestedEffort = settings.selectedEffort?.trim().isNotEmpty == true
          ? settings.selectedEffort
          : modelSettings.preferredEffort.trim().isEmpty
          ? null
          : modelSettings.preferredEffort.trim();
      final effort = queue.key.agent == AgentKind.claudeCode
          ? resolveModelSelection(
              settings.models,
              model ?? '',
              requestedEffort ?? '',
              agent: AgentKind.claudeCode,
            ).effort
          : requestedEffort;
      if (!steer &&
          queue.key.agent == AgentKind.openCode &&
          (modelSettings.customModels.any(
                (definition) => definition.modelId == model,
              ) ||
              _pendingManagedModelRemovals(modelSettings).isNotEmpty)) {
        await _syncCustomModelsNow(
          queue.key.profileId,
          queue.key.agent,
          requireConnected: true,
        );
      }
      if (!current()) throw StateError('发送已取消，消息仍保留在队列');
      if (!steeringTargetIsCurrent()) {
        throw StateError('原回合已结束，消息保留在队列；请确认后再次点击“引导”发送');
      }
      final optimistic = TimelineEntry(
        id: optimisticId,
        kind: TimelineKind.userMessage,
        text: entry.message.text,
        turnId: steeringTurnId ?? '',
        attachments: attachments
            .map(
              (a) => MessageAttachment(
                name: a.name,
                remotePath: a.remotePath,
                mimeType: a.mimeType,
              ),
            )
            .toList(growable: false),
      );
      _updateQueueThread(
        queue,
        (value) => value.copyWith(
          timeline: [...value.timeline, optimistic],
          running: true,
          submitting: true,
          error: null,
        ),
      );
      optimisticAdded = true;
      queue.running = true;
      _diagnostics.info(
        'Message',
        'send_requested profile=${queue.key.profileId} agent=${queue.key.agent.name} thread=${queue.thread.id} bytes=${utf8.encode(entry.message.text).length} attachments=${attachments.length} steering=$steer',
      );
      requestSent = true;
      final String turnId;
      if (steer) {
        await _agents.steerTurn(
          queue.key,
          threadId: queue.thread.id,
          turnId: steeringTurnId!,
          text: entry.message.text,
          attachments: attachments,
        );
        turnId = steeringTurnId;
      } else {
        turnId = await _agents.startTurn(
          queue.key,
          threadId: queue.thread.id,
          text: entry.message.text,
          attachments: attachments,
          model: model,
          effort: effort,
          subagentModel:
              queue.key.agent == AgentKind.claudeCode &&
                  modelSettings.preferredSubagentModel.trim().isNotEmpty
              ? modelSettings.preferredSubagentModel.trim()
              : null,
          approvalMode: settings.approvalMode,
          sandbox: settings.sandbox,
          cwd: queue.profile.workspace.trim().isEmpty
              ? queue.thread.cwd
              : queue.profile.workspace,
        );
      }
      // Accepted is final even if a stop/navigation raced the response. Never
      // retain an accepted item for automatic re-send or revive its ended turn.
      queue.items.remove(entry);
      if (!mounted) return;
      final completed = queue.completedTurns.contains(turnId);
      if (current() && !completed) {
        queue.running = true;
        queue.turnId = turnId;
      }
      _diagnostics.info(
        'Message',
        'send_accepted profile=${queue.key.profileId} agent=${queue.key.agent.name} thread=${queue.thread.id} turn=$turnId',
      );
      if (!steer) {
        _maybeGenerateThreadTitle(
          queue.key,
          queue.thread.id,
          entry.message.text,
          model,
        );
      }
      if (_queueProfileMatches(queue)) {
        _updateQueueThread(queue, (value) {
          final preserve =
              !current() ||
              completed ||
              (steer && value.activeTurnId != steeringTurnId);
          return value.copyWith(
            submitting: false,
            running: preserve ? value.running : true,
            activeTurnId: preserve ? value.activeTurnId : turnId,
            activeThread: preserve
                ? value.activeThread
                : value.activeThread?.copyWith(
                    status: 'active',
                    activeTurnId: turnId,
                  ),
            timeline: value.timeline
                .map(
                  (item) => item.id == optimisticId
                      ? item.copyWith(turnId: turnId)
                      : item,
                )
                .toList(growable: false),
            turnTiming: preserve || steer
                ? value.turnTiming
                : TurnTiming(
                    threadId: queue.thread.id,
                    turnId: turnId,
                    startedAtMillis: DateTime.now().millisecondsSinceEpoch,
                  ),
          );
        });
      }
    } catch (error, stack) {
      _diagnostics.warn(
        'Message',
        'send_failed profile=${queue.key.profileId} agent=${queue.key.agent.name} thread=${queue.thread.id}',
        error,
        stack,
      );
      if (!mounted) return;
      queue.running =
          steer &&
          queue.turnId == steeringTurnId &&
          !queue.completedTurns.contains(steeringTurnId);
      final reason = requestSent
          ? '发送未获确认，请核对对话后点击“引导”重试'
          : _message(error, '发送失败，请重试');
      // A failed immediate send must remain recoverable if a newer draft or
      // navigation prevents restoring it to the composer.
      entry.visibleInQueue = true;
      _pauseMessageQueue(queue.key, queue.thread.id, reason);
      entry.message = entry.message.copyWith(sending: false, error: reason);
      if (optimisticAdded && _queueProfileMatches(queue)) {
        _updateQueueThread(
          queue,
          (value) => value.copyWith(
            timeline: value.timeline
                .where((item) => item.id != optimisticId)
                .toList(growable: false),
            submitting: false,
            running:
                value.activeTurnId != null &&
                !queue.completedTurns.contains(value.activeTurnId),
          ),
        );
      }
      if (_queueIsVisible(queue)) {
        if (isCodexThreadOwnershipError(error, threadId: queue.thread.id)) {
          _markThreadExternallyOwned(queue.key, queue.thread.id);
        }
        if (entry.restoreComposer &&
            queue.items.length == 1 &&
            state.composerDraft.isEmpty &&
            state.attachments.isEmpty) {
          queue.items.remove(entry);
          state = state.copyWith(
            composerDraft: entry.originalDraft ?? entry.message.text,
            attachments: entry.message.attachments,
            composerClearNonce: state.composerClearNonce + 1,
          );
          unawaited(
            _persist(
              (stored) => stored.copyWith(
                composerDrafts: {
                  ...stored.composerDrafts,
                  queue.storageKey: entry.originalDraft ?? entry.message.text,
                },
              ),
            ),
          );
        }
        state = state.copyWith(error: _message(error, '发送消息失败'));
      }
    } finally {
      entry.message = entry.message.copyWith(sending: false);
      if (_queueIsVisible(queue)) {
        state = state.copyWith(submitting: false, attachmentUploading: false);
      }
      _refreshMessageQueue();
    }
  }

  void _updateQueueThread(
    _ThreadMessageQueue queue,
    AppUiState Function(AppUiState value) update,
  ) {
    if (!mounted) return;
    final visible = _queueIsVisible(queue);
    final cache = _threadCaches.putIfAbsent(queue.key, ThreadSessionCache.new);
    final cached = cache.getStale(queue.thread.id);
    final laneThreads =
        state.agentThreadLists[queue.key] ?? const <AgentThread>[];
    final base = visible
        ? state
        : AppUiState(
            screen: AppScreen.work,
            activeThread: cached?.thread ?? queue.thread,
            threads: laneThreads,
            timeline: cached?.timeline ?? const [],
            activeTurnId: cached?.thread.activeTurnId,
            running: cached == null
                ? queue.running
                : _threadIsRunning(cached.thread),
            olderTurnsCursor: cached?.nextTurnsCursor,
            tokenUsage: cached?.tokenUsage,
          );
    final next = update(base);
    final thread = next.activeThread;
    if (thread == null) return;
    cache.put(
      thread,
      next.timeline,
      nextTurnsCursor: next.olderTurnsCursor,
      tokenUsage: next.tokenUsage,
    );
    final threads = laneThreads
        .map((old) => old.id == thread.id ? thread : old)
        .toList(growable: false);
    final lists = {...state.agentThreadLists, queue.key: threads};
    if (visible) {
      state = next.copyWith(agentThreadLists: lists, threads: threads);
    } else {
      state = state.copyWith(
        agentThreadLists: lists,
        threads: _isActiveKey(queue.key) ? threads : state.threads,
      );
    }
  }
}
