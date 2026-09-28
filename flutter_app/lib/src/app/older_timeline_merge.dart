import '../domain/models.dart';

/// Inserts an older page without moving turns already visible in the cache.
List<TimelineEntry> mergeOlderTimelinePage({
  required List<TimelineEntry> older,
  required List<TimelineEntry> current,
}) {
  final currentRows = _uniqueRows(current);
  final olderRows = _uniqueRows(older);
  final positions = <(String, TimelineKind, String), int>{};
  final turnBounds = <Object, ({int start, int end})>{};
  for (var index = 0; index < currentRows.length; index += 1) {
    final entry = currentRows[index];
    positions[_entryIdentity(entry)] = index;
    final key = _turnIdentity(entry);
    turnBounds[key] = (start: turnBounds[key]?.start ?? index, end: index + 1);
  }
  final previousRowEnds = List<int?>.filled(olderRows.length, null);
  final previousRowsByTurn = <Object, int>{};
  for (var index = 0; index < olderRows.length; index += 1) {
    final entry = olderRows[index];
    final key = _turnIdentity(entry);
    previousRowEnds[index] = previousRowsByTurn[key];
    final position = positions[_entryIdentity(entry)];
    if (position != null) previousRowsByTurn[key] = position + 1;
  }

  final anchors = List<({int before, int after})?>.filled(
    olderRows.length,
    null,
  );
  final insertionOffsets = List<int?>.filled(olderRows.length, null);
  final nextRowsByTurn = <Object, int>{};
  ({int before, int after})? nextAnchor;
  for (var index = olderRows.length - 1; index >= 0; index -= 1) {
    final entry = olderRows[index];
    final key = _turnIdentity(entry);
    final position = positions[_entryIdentity(entry)];
    final bounds = turnBounds[key];
    if (position != null) {
      anchors[index] = (before: position, after: position + 1);
      nextRowsByTurn[key] = position;
    } else if (bounds != null) {
      anchors[index] = (
        before: nextRowsByTurn[key] ?? previousRowEnds[index] ?? bounds.start,
        after: bounds.end,
      );
    }
    nextAnchor = anchors[index] ?? nextAnchor;
    insertionOffsets[index] = nextAnchor?.before;
  }

  // Keep page rows in their received order, including unscoped notices between
  // two rows of one turn. Anchors locate insertions without regrouping either
  // transcript or sorting opaque turn IDs. Current live rows always win.
  final insertions = <int, List<TimelineEntry>>{};
  ({int before, int after})? previousAnchor;
  var minimumOffset = 0;
  for (var index = 0; index < olderRows.length; index += 1) {
    final entry = olderRows[index];
    final position = positions[_entryIdentity(entry)];
    if (position != null) {
      if (position + 1 > minimumOffset) minimumOffset = position + 1;
    } else {
      var offset = insertionOffsets[index] ?? previousAnchor?.after ?? 0;
      if (offset < minimumOffset) offset = minimumOffset;
      insertions.putIfAbsent(offset, () => <TimelineEntry>[]).add(entry);
      minimumOffset = offset;
    }
    previousAnchor = anchors[index] ?? previousAnchor;
  }
  return List<TimelineEntry>.unmodifiable([
    for (var index = 0; index <= currentRows.length; index += 1) ...[
      ...?insertions[index],
      if (index < currentRows.length) currentRows[index],
    ],
  ]);
}

Object _turnIdentity(TimelineEntry entry) =>
    entry.turnId.isEmpty ? _entryIdentity(entry) : entry.turnId;

(String, TimelineKind, String) _entryIdentity(TimelineEntry entry) =>
    (entry.turnId, entry.kind, entry.id);

List<TimelineEntry> _uniqueRows(List<TimelineEntry> entries) =>
    <(String, TimelineKind, String), TimelineEntry>{
      for (final entry in entries) _entryIdentity(entry): entry,
    }.values.toList(growable: false);
