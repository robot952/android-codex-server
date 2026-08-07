/// An in-memory back stack with an independent navigation chain per scope.
class ProfileScopedBackStack<T extends Object> {
  final Map<String, List<T>> _frames = <String, List<T>>{};
  final Map<String, T> _pendingPops = <String, T>{};

  void push(String scopeId, T frame) {
    if (scopeId.trim().isEmpty) return;
    (_frames[scopeId] ??= <T>[]).add(frame);
  }

  T? peek(String scopeId) {
    final stack = _frames[scopeId];
    return stack == null || stack.isEmpty ? null : stack.last;
  }

  T? pop(String scopeId) {
    final stack = _frames[scopeId];
    if (stack == null || stack.isEmpty) return null;

    final frame = stack.removeLast();
    if (identical(_pendingPops[scopeId], frame)) {
      _pendingPops.remove(scopeId);
    }
    if (stack.isEmpty) {
      _frames.remove(scopeId);
    }
    return frame;
  }

  /// Removes [expected] only when it is still the active top frame.
  T? popIfTop(String scopeId, T expected) {
    if (!isTop(scopeId, expected)) return null;
    return pop(scopeId);
  }

  /// Uses identity so a late callback cannot match a newer equal-valued frame.
  bool isTop(String scopeId, T expected) => identical(peek(scopeId), expected);

  /// Marks the top frame as awaiting an asynchronous parent resume.
  T? beginPendingPop(String scopeId) {
    if (scopeId.trim().isEmpty || _pendingPops.containsKey(scopeId)) {
      return null;
    }

    final frame = peek(scopeId);
    if (frame == null) return null;
    _pendingPops[scopeId] = frame;
    return frame;
  }

  /// Completes the transition only if [expected] is still the pending frame.
  T? completePendingPop(String scopeId, T expected) {
    if (!identical(_pendingPops[scopeId], expected)) return null;
    _pendingPops.remove(scopeId);
    return popIfTop(scopeId, expected);
  }

  /// Cancels a transition while retaining its frame for a later retry.
  bool cancelPendingPop(String scopeId, T expected) {
    if (!identical(_pendingPops[scopeId], expected)) return false;
    _pendingPops.remove(scopeId);
    return true;
  }

  bool isPopPending(String scopeId) => _pendingPops.containsKey(scopeId);

  void clear(String scopeId) {
    _frames.remove(scopeId);
    _pendingPops.remove(scopeId);
  }

  int size(String scopeId) => _frames[scopeId]?.length ?? 0;
}
