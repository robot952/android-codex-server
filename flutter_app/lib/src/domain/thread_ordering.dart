import 'models.dart';

/// Native Codex timestamps use seconds; bridges and older caches may use
/// milliseconds. Keep ordering and the relative-time label on the same scale.
int threadTimestampMillis(int value) =>
    value <= 0 ? 0 : (value < 100000000000 ? value * 1000 : value);

/// Newest displayed update first, preserving the existing order for ties and
/// placing threads with an unknown update time after dated threads.
List<AgentThread> threadsByUpdatedAt(Iterable<AgentThread> threads) {
  final indexed = threads.indexed.toList();
  indexed.sort((left, right) {
    final byTime = threadTimestampMillis(
      right.$2.updatedAt,
    ).compareTo(threadTimestampMillis(left.$2.updatedAt));
    return byTime != 0 ? byTime : left.$1.compareTo(right.$1);
  });
  return List<AgentThread>.unmodifiable(indexed.map((entry) => entry.$2));
}
