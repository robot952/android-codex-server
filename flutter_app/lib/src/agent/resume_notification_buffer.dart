import '../domain/models.dart';
import 'codex_protocol.dart';

/// Holds notifications for one thread while its resume snapshot is loading.
///
/// A successful resume publishes the snapshot first, then drains this buffer so
/// live events cannot be overwritten by the older response. Events at or before
/// [snapshotSequence] are de-duplicated only when their exact aggregate is
/// already present as a snapshot suffix.
final class ResumeNotificationBuffer {
  ResumeNotificationBuffer({
    required this.threadId,
    required this.generation,
    this.maxEvents = defaultMaxEvents,
    this.maxWeightChars = defaultMaxWeightChars,
  }) {
    if (maxEvents < 1) {
      throw ArgumentError.value(maxEvents, 'maxEvents', 'must be positive');
    }
    if (maxWeightChars < 1) {
      throw ArgumentError.value(
        maxWeightChars,
        'maxWeightChars',
        'must be positive',
      );
    }
  }

  static const int defaultMaxEvents = 4096;
  static const int defaultMaxWeightChars = 4 * 1024 * 1024;
  static const int _maxSequence = 0x7fffffffffffffff;

  final String threadId;
  final int generation;
  final int maxEvents;
  final int maxWeightChars;

  final List<_BufferedEvent> _events = <_BufferedEvent>[];
  int _weightChars = 0;

  bool _overflowed = false;

  bool get overflowed => _overflowed;

  /// Returns whether [notification] belongs to this in-flight resume.
  bool offer(CodexRpcNotification notification) {
    if (notification.generation != generation) return false;
    if (_string(notification.params, const <String>['threadId', 'thread_id']) !=
        threadId) {
      return false;
    }

    final weight = _estimateNotificationWeight(notification, maxWeightChars);
    if (weight > maxWeightChars) {
      _overflowed = true;
      return true;
    }

    if (_events.length >= maxEvents || _weightChars + weight > maxWeightChars) {
      _overflowed = true;
      // Full lifecycle payloads are more useful than streaming fragments after
      // the resume snapshot has been published.
      if (_deltaKey(notification) != null) return true;
      _makeRoomFor(weight);
    }

    if (_events.length >= maxEvents || _weightChars + weight > maxWeightChars) {
      _overflowed = true;
      return true;
    }

    _events.add(_BufferedEvent(notification, weight));
    _weightChars += weight;
    return true;
  }

  /// Replays buffered events in wire order and clears the buffer.
  List<CodexRpcNotification> drain(
    List<TimelineEntry> snapshot, {
    int snapshotSequence = _maxSequence,
  }) {
    if (_events.isEmpty) return const <CodexRpcNotification>[];

    final buffered = _events
        .map((event) => event.notification)
        .toList(growable: false);
    final completedAuthoritativeKeys = <_TimelineKey>{};
    for (final notification in buffered) {
      if (notification.method != 'item/completed') continue;
      final key = _itemKey(notification);
      if (key != null &&
          (key.kind == TimelineKind.agentMessage ||
              key.kind == TimelineKind.plan)) {
        completedAuthoritativeKeys.add(key);
      }
    }

    final aggregates = <_StreamKey, StringBuffer>{};
    for (final notification in buffered) {
      if (notification.sequence > snapshotSequence) continue;
      final key = _deltaKey(notification);
      if (key == null || completedAuthoritativeKeys.contains(key.timelineKey)) {
        continue;
      }
      (aggregates[key] ??= StringBuffer()).write(
        _string(notification.params, const <String>['delta']),
      );
    }

    final snapshotByKey = <_TimelineKey, TimelineEntry>{
      for (final entry in snapshot) _timelineKey(entry): entry,
    };
    final remainingSkip = <_StreamKey, int>{};
    for (final MapEntry(key: key, value: aggregate) in aggregates.entries) {
      final aggregateText = aggregate.toString();
      final existing = snapshotByKey[key.timelineKey];
      remainingSkip[key] = switch ((key.field, existing)) {
        (_StreamField.plan, final TimelineEntry _) => aggregateText.length,
        (_, final TimelineEntry entry)
            when aggregateText.isNotEmpty &&
                _streamValue(entry, key).endsWith(aggregateText) =>
          aggregateText.length,
        _ => 0,
      };
    }

    final replay = <CodexRpcNotification>[];
    for (final notification in buffered) {
      final key = _deltaKey(notification);
      if (key != null && completedAuthoritativeKeys.contains(key.timelineKey)) {
        continue;
      }
      if (key == null) {
        replay.add(notification);
        continue;
      }

      final delta = _string(notification.params, const <String>['delta']);
      final skip = notification.sequence <= snapshotSequence
          ? (remainingSkip[key] ?? 0)
          : 0;
      final consumed = skip < delta.length ? skip : delta.length;
      remainingSkip[key] = skip - consumed;
      final remaining = delta.substring(consumed);
      if (remaining.isNotEmpty) {
        replay.add(_withDelta(notification, remaining));
      }
    }

    _events.clear();
    _weightChars = 0;
    return List<CodexRpcNotification>.unmodifiable(_coalesceDeltas(replay));
  }

  void _makeRoomFor(int incomingWeight) {
    while (_events.isNotEmpty &&
        (_events.length >= maxEvents ||
            _weightChars + incomingWeight > maxWeightChars)) {
      final deltaIndex = _events.indexWhere(
        (event) => _deltaKey(event.notification) != null,
      );
      final removed = _events.removeAt(deltaIndex < 0 ? 0 : deltaIndex);
      _weightChars -= removed.weightChars;
    }
  }
}

final class _BufferedEvent {
  const _BufferedEvent(this.notification, this.weightChars);

  final CodexRpcNotification notification;
  final int weightChars;
}

enum _StreamField { text, plan, output, reasoningSummary, reasoningContent }

typedef _TimelineKey = ({String turnId, String itemId, TimelineKind kind});
typedef _StreamKey = ({
  _TimelineKey timelineKey,
  _StreamField field,
  int partIndex,
});

_TimelineKey _timelineKey(TimelineEntry entry) =>
    (turnId: entry.turnId, itemId: entry.id, kind: entry.kind);

_StreamKey? _deltaKey(CodexRpcNotification notification) {
  final kindAndField = switch (notification.method) {
    'item/agentMessage/delta' => (
      kind: TimelineKind.agentMessage,
      field: _StreamField.text,
      indexName: null,
    ),
    'item/plan/delta' => (
      kind: TimelineKind.plan,
      field: _StreamField.plan,
      indexName: null,
    ),
    'item/commandExecution/outputDelta' => (
      kind: TimelineKind.command,
      field: _StreamField.output,
      indexName: null,
    ),
    'item/reasoning/summaryTextDelta' => (
      kind: TimelineKind.reasoning,
      field: _StreamField.reasoningSummary,
      indexName: 'summaryIndex',
    ),
    'item/reasoning/textDelta' => (
      kind: TimelineKind.reasoning,
      field: _StreamField.reasoningContent,
      indexName: 'contentIndex',
    ),
    _ => null,
  };
  if (kindAndField == null) return null;

  final itemId = _string(notification.params, const <String>[
    'itemId',
    'item_id',
  ]);
  final turnId = _string(notification.params, const <String>[
    'turnId',
    'turn_id',
  ]);
  if (itemId.isEmpty || turnId.isEmpty) return null;
  final indexName = kindAndField.indexName;
  return (
    timelineKey: (turnId: turnId, itemId: itemId, kind: kindAndField.kind),
    field: kindAndField.field,
    partIndex: indexName == null
        ? -1
        : _integer(notification.params[indexName]) ?? -1,
  );
}

_TimelineKey? _itemKey(CodexRpcNotification notification) {
  final item = _objectMap(notification.params['item']);
  if (item == null) return null;
  final turnId = _string(notification.params, const <String>[
    'turnId',
    'turn_id',
  ]);
  final entry = CodexPayloadParser.parseItem(item, turnId: turnId);
  return entry == null ? null : _timelineKey(entry);
}

String _streamValue(TimelineEntry entry, _StreamKey key) => switch (key.field) {
  _StreamField.text => entry.text,
  _StreamField.plan => '',
  _StreamField.output => entry.output,
  _StreamField.reasoningSummary => _valueAt(
    entry.reasoningSummary,
    key.partIndex,
  ),
  _StreamField.reasoningContent => _valueAt(
    entry.reasoningContent,
    key.partIndex,
  ),
};

String _valueAt(List<String> values, int index) =>
    index >= 0 && index < values.length ? values[index] : '';

CodexRpcNotification _withDelta(
  CodexRpcNotification notification,
  String delta,
) {
  final params = <String, Object?>{...notification.params, 'delta': delta};
  return CodexRpcNotification(
    generation: notification.generation,
    sequence: notification.sequence,
    raw: <String, Object?>{...notification.raw, 'params': params},
    method: notification.method,
    params: params,
    isKnown: notification.isKnown,
  );
}

List<CodexRpcNotification> _coalesceDeltas(
  List<CodexRpcNotification> notifications,
) {
  if (notifications.length < 2) return notifications;
  final result = <CodexRpcNotification>[];
  _StreamKey? pendingKey;
  CodexRpcNotification? pendingNotification;
  var pendingDelta = StringBuffer();

  void flush() {
    final notification = pendingNotification;
    if (notification != null) {
      result.add(_withDelta(notification, pendingDelta.toString()));
    }
    pendingKey = null;
    pendingNotification = null;
    pendingDelta = StringBuffer();
  }

  for (final notification in notifications) {
    final key = _deltaKey(notification);
    if (key == null) {
      flush();
      result.add(notification);
    } else if (key == pendingKey) {
      pendingDelta.write(_string(notification.params, const <String>['delta']));
    } else {
      flush();
      pendingKey = key;
      pendingNotification = notification;
      pendingDelta.write(_string(notification.params, const <String>['delta']));
    }
  }
  flush();
  return result;
}

int _estimateNotificationWeight(CodexRpcNotification notification, int limit) {
  var total = notification.method.length.clamp(0, limit + 1);
  final pending = <Object?>[notification.params];
  while (pending.isNotEmpty && total <= limit) {
    final value = pending.removeLast();
    if (value is Map) {
      for (final entry in value.entries) {
        total = (total + entry.key.toString().length).clamp(0, limit + 1);
        if (total <= limit) pending.add(entry.value);
      }
    } else if (value is Iterable) {
      pending.addAll(value);
    } else if (value != null) {
      total = (total + value.toString().length).clamp(0, limit + 1);
    }
  }
  return total;
}

Map<String, Object?>? _objectMap(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is! Map) return null;
  return <String, Object?>{
    for (final entry in value.entries) entry.key.toString(): entry.value,
  };
}

String _string(Map<String, Object?> values, List<String> keys) {
  for (final key in keys) {
    final value = values[key];
    if (value is String) return value;
  }
  return '';
}

int? _integer(Object? value) => switch (value) {
  int number => number,
  num number when number.isFinite => number.toInt(),
  String text => int.tryParse(text),
  _ => null,
};
