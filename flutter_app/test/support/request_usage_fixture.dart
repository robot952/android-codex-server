import 'dart:async';

import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/domain/request_usage.dart';
import 'package:codex_remote/src/persistence/request_usage_store.dart';

class MemoryRequestUsageStore implements RequestUsageStore {
  UsageHistorySnapshot snapshot = const UsageHistorySnapshot();
  Completer<UsageHistorySnapshot>? readGate;
  bool failRead = false;
  bool failWrite = false;
  int writes = 0;

  @override
  Future<UsageHistorySnapshot> read() async {
    if (failRead) throw StateError('synthetic read failure');
    return readGate == null ? snapshot : await readGate!.future;
  }

  @override
  Future<void> write(UsageHistorySnapshot value) async {
    writes++;
    if (failWrite) throw StateError('synthetic write failure');
    snapshot = value;
  }
}

RequestUsageRecord usageFixture({
  String id = 'a',
  int? at,
  String model = 'fixture-model',
  int? input = 100,
  int? output = 20,
}) => RequestUsageRecord(
  id: id.padRight(64, id),
  profileId: 'server',
  agent: AgentKind.codex,
  provider: 'fixture-provider',
  threadId: 'thread',
  recordedAtMillis: at ?? DateTime(2026, 10, 28, 12).millisecondsSinceEpoch,
  model: model,
  inputTokens: input,
  outputTokens: output,
  cachedInputTokens: 50,
  totalTokens: input != null && output != null ? input + output : null,
  firstTokenMillis: 350,
  durationMillis: 2100,
);

Map<String, dynamic> usageParams({
  String? requestId = 'request-1',
  int input = 100,
  int output = 20,
  int cumulative = 120,
  Map<String, dynamic> metrics = const {},
}) => {
  'turnId': 'turn-1',
  'tokenUsage': {
    'last': {
      'inputTokens': input,
      'outputTokens': output,
      'cachedInputTokens': 50,
      'totalTokens': input + output,
    },
    'total': {'totalTokens': cumulative},
  },
  'requestMetrics': {'requestId': ?requestId, ...metrics},
};
