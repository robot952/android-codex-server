part of 'app_controller.dart';

/// Only conversations created by this controller are eligible. No history scan,
/// extra conversation turn or persistence of the user's first message is needed.
class _ThreadTitleAttempt {
  _ThreadTitleAttempt(
    this.profile,
    this.key,
    this.threadId,
    this.generation,
    this.remoteGeneration,
  );

  final ServerProfile profile;
  final AgentConnectionKey key;
  final String threadId;
  final int generation;
  final int? remoteGeneration;
  final Lock lock = Lock();
  bool used = false;
  bool cancelled = false;
}

extension _AppControllerThreadTitles on AppController {
  void _rememberNewThreadForTitle(
    ServerProfile profile,
    AgentConnectionKey key,
    String threadId,
  ) {
    if (!_agents.capabilities(key).renameThread) return;
    final storageKey = threadPreferenceKey(profile.id, key.agent, threadId);
    _threadTitleAttempts[storageKey] = _ThreadTitleAttempt(
      profile,
      key,
      threadId,
      _agents.generation(key),
      _agents.remoteGeneration(key),
    );
    while (_threadTitleAttempts.length > 128) {
      _threadTitleAttempts.remove(_threadTitleAttempts.keys.first)?.cancelled =
          true;
    }
  }

  bool _isThreadTitleCurrent(_ThreadTitleAttempt attempt) {
    if (!mounted || attempt.cancelled) return false;
    final key = attempt.key;
    if (!identical(
          _threadTitleAttempts[threadPreferenceKey(
            key.profileId,
            key.agent,
            attempt.threadId,
          )],
          attempt,
        ) ||
        _agents.generation(key) != attempt.generation ||
        _agents.remoteGeneration(key) != attempt.remoteGeneration ||
        _agents.states[key]?.phase != ConnectionPhase.connected) {
      return false;
    }
    final profile = state.profiles.firstWhereOrNull(
      (p) => p.id == key.profileId,
    );
    if (profile == null ||
        !profile.hasSameConnectionIdentity(attempt.profile) ||
        profile.remoteCommand != attempt.profile.remoteCommand ||
        profile.workspace != attempt.profile.workspace ||
        _agentVersion(profile, key.agent) !=
            _agentVersion(attempt.profile, key.agent)) {
      return false;
    }
    final thread = _titleThread(key, attempt.threadId);
    return thread != null && !thread.isExternallyOwned;
  }

  AgentThread? _titleThread(AgentConnectionKey key, String threadId) {
    if (_isActiveThread(key, threadId)) return state.activeThread;
    return _threadCaches[key]?.getStale(threadId)?.thread ??
        state.agentThreadLists[key]?.firstWhereOrNull((t) => t.id == threadId);
  }

  void _maybeGenerateThreadTitle(
    AgentConnectionKey key,
    String threadId,
    String text,
    String? model,
  ) {
    final storageKey = threadPreferenceKey(key.profileId, key.agent, threadId);
    final attempt = _threadTitleAttempts[storageKey];
    if (attempt == null || attempt.used) return;
    // Even an attachment-only first message consumes eligibility. A later
    // message must not unexpectedly rename this conversation.
    attempt.used = true;
    if (text.trim().isEmpty || !_isThreadTitleCurrent(attempt)) {
      _threadTitleAttempts.remove(storageKey);
      return;
    }
    unawaited(_generateThreadTitle(attempt, text, model));
  }

  Future<void> _generateThreadTitle(
    _ThreadTitleAttempt attempt,
    String text,
    String? model,
  ) async {
    final key = attempt.key;
    final storageKey = threadPreferenceKey(
      key.profileId,
      key.agent,
      attempt.threadId,
    );
    try {
      final title = normalizeGeneratedThreadTitle(
        await _agents.generateThreadTitle(key, text: text, model: model),
      );
      await attempt.lock.synchronized(() async {
        if (!_isThreadTitleCurrent(attempt)) return;
        await _agents.setThreadName(
          key,
          threadId: attempt.threadId,
          name: title,
        );
        if (!_isThreadTitleCurrent(attempt)) return;
        _applyThreadName(key, attempt.threadId, title);
      });
    } catch (_) {
      // Optional enhancement: never expose API output, credentials or a new
      // chat error when the original truncated title remains usable.
      _diagnostics.info('ThreadTitle', 'fallback agent=${key.agent.name}');
    } finally {
      if (identical(_threadTitleAttempts[storageKey], attempt)) {
        _threadTitleAttempts.remove(storageKey);
      }
    }
  }

  void _applyThreadName(AgentConnectionKey key, String threadId, String title) {
    final thread = _titleThread(key, threadId);
    if (thread == null) return;
    final renamed = thread.copyWith(title: title);
    final cache = _threadCaches[key];
    final cached = cache?.getStale(threadId);
    if (cached != null) {
      cache!.put(
        cached.thread.copyWith(title: title),
        cached.timeline,
        nextTurnsCursor: cached.nextTurnsCursor,
        tokenUsage: cached.tokenUsage,
      );
    }
    final lists = _replaceLaneThread(state.agentThreadLists, key, renamed);
    state = state.copyWith(
      activeThread: _isActiveThread(key, threadId)
          ? renamed
          : state.activeThread,
      agentThreadLists: lists,
      threads: _isActiveKey(key) ? lists[key] ?? state.threads : state.threads,
    );
  }

  void _invalidateThreadTitles(
    bool Function(AgentConnectionKey) matches, {
    String? threadId,
  }) {
    _threadTitleAttempts.removeWhere((_, attempt) {
      if (!matches(attempt.key) ||
          (threadId != null && attempt.threadId != threadId)) {
        return false;
      }
      attempt.cancelled = true;
      return true;
    });
  }
}
