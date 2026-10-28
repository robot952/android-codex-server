import 'models.dart';

/// A single model request, not an agent turn or the conversation's running sum.
/// No prompts, responses, server addresses or credentials belong in this record.
class RequestUsageRecord {
  const RequestUsageRecord({
    required this.id,
    required this.profileId,
    required this.agent,
    required this.provider,
    required this.threadId,
    required this.recordedAtMillis,
    this.model,
    this.inputTokens,
    this.outputTokens,
    this.cachedInputTokens,
    this.totalTokens,
    this.firstTokenMillis,
    this.durationMillis,
    this.hasServerTimestamp = false,
  });

  final String id;
  final String profileId;
  final AgentKind agent;
  final String provider;
  final String threadId;
  final int recordedAtMillis;
  final String? model;
  // Input includes cache reads; cache hits are a subset, never added twice.
  final int? inputTokens;
  final int? outputTokens;
  final int? cachedInputTokens;
  final int? totalTokens;
  final int? firstTokenMillis;
  final int? durationMillis;
  final bool hasServerTimestamp;

  RequestUsageRecord merge(RequestUsageRecord next) => RequestUsageRecord(
    id: id,
    profileId: profileId,
    agent: agent,
    provider: provider,
    threadId: threadId,
    recordedAtMillis: next.hasServerTimestamp
        ? next.recordedAtMillis
        : recordedAtMillis,
    hasServerTimestamp: hasServerTimestamp || next.hasServerTimestamp,
    model: next.model ?? model,
    inputTokens: _maximum(inputTokens, next.inputTokens),
    outputTokens: _maximum(outputTokens, next.outputTokens),
    cachedInputTokens: _maximum(cachedInputTokens, next.cachedInputTokens),
    totalTokens: _maximum(totalTokens, next.totalTokens),
    firstTokenMillis: next.firstTokenMillis ?? firstTokenMillis,
    durationMillis: next.durationMillis ?? durationMillis,
  );

  static int? _maximum(int? previous, int? next) => previous == null
      ? next
      : next == null || previous > next
      ? previous
      : next;

  Map<String, Object?> toJson() => {
    'id': id,
    'profileId': profileId,
    'agent': agent.name,
    'provider': provider,
    'threadId': threadId,
    'recordedAtMillis': recordedAtMillis,
    'model': model,
    'inputTokens': inputTokens,
    'outputTokens': outputTokens,
    'cachedInputTokens': cachedInputTokens,
    'totalTokens': totalTokens,
    'firstTokenMillis': firstTokenMillis,
    'durationMillis': durationMillis,
    'hasServerTimestamp': hasServerTimestamp,
  };

  static RequestUsageRecord? fromJson(Map<String, dynamic> value) {
    final id = usageIdentifier(value['id']);
    final profileId = usageIdentifier(value['profileId']);
    final threadId = usageIdentifier(value['threadId']);
    final at = usageInteger(value['recordedAtMillis']);
    final agent = AgentKind.values
        .where((agent) => agent.name == value['agent'])
        .firstOrNull;
    if (id == null ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(id) ||
        profileId == null ||
        threadId == null ||
        at == null ||
        at == 0 ||
        at > 8640000000000000 ||
        agent == null) {
      return null;
    }
    return RequestUsageRecord(
      id: id,
      profileId: profileId,
      agent: agent,
      provider: usageIdentifier(value['provider']) ?? '',
      threadId: threadId,
      recordedAtMillis: at,
      model: usageIdentifier(value['model']),
      inputTokens: usageInteger(value['inputTokens']),
      outputTokens: usageInteger(value['outputTokens']),
      cachedInputTokens: usageInteger(value['cachedInputTokens']),
      totalTokens: usageInteger(value['totalTokens']),
      firstTokenMillis: usageInteger(value['firstTokenMillis']),
      durationMillis: usageInteger(value['durationMillis']),
      hasServerTimestamp: value['hasServerTimestamp'] == true,
    );
  }
}

// Keep malformed, absent and negative counters distinct from a reported zero.
int? usageInteger(Object? value) =>
    value is int && value >= 0 && value <= 9007199254740991 ? value : null;

String? usageIdentifier(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  if (text.isEmpty ||
      text.length > 256 ||
      RegExp(r'[\x00-\x20\x7f]|://|[?&#]').hasMatch(text)) {
    return null;
  }
  return text;
}

enum UsagePeriod {
  today('今天'),
  yesterday('昨天'),
  week('近7天'),
  month('近30天');

  const UsagePeriod(this.label);
  final String label;

  bool contains(int epochMillis, DateTime now) {
    final local = now.toLocal();
    final dayStart = DateTime(local.year, local.month, local.day);
    final start = switch (this) {
      today => dayStart,
      yesterday => DateTime(local.year, local.month, local.day - 1),
      week => DateTime(local.year, local.month, local.day - 6),
      month => DateTime(local.year, local.month, local.day - 29),
    };
    final end = this == yesterday
        ? dayStart
        : DateTime(local.year, local.month, local.day + 1);
    return epochMillis >= start.millisecondsSinceEpoch &&
        epochMillis < end.millisecondsSinceEpoch;
  }
}

class UsageTotals {
  UsageTotals(Iterable<RequestUsageRecord> records) {
    for (final record in records) {
      requests++;
      if (record.inputTokens case final value?) {
        inputTokens = (inputTokens ?? 0) + value;
      }
      if (record.outputTokens case final value?) {
        outputTokens = (outputTokens ?? 0) + value;
      }
      if (record.cachedInputTokens case final value?) {
        cachedInputTokens = (cachedInputTokens ?? 0) + value;
      }
      if (record.totalTokens case final value?) {
        totalTokens = (totalTokens ?? 0) + value;
      }
    }
  }

  int requests = 0;
  int? inputTokens;
  int? outputTokens;
  int? cachedInputTokens;
  int? totalTokens;
}
