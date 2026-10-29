import 'dart:async';
import 'dart:convert';

import 'package:codex_remote/src/app/request_usage_controller.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/domain/request_usage.dart';
import 'package:codex_remote/src/persistence/request_usage_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/request_usage_fixture.dart';

void main() {
  test(
    'cache rate weights comparable token counts and leaves missing data unknown',
    () {
      final totals = UsageTotals([
        usageFixture(input: 100, cached: 50),
        usageFixture(input: 900, cached: 810),
        usageFixture(input: 1000, cached: null),
        usageFixture(input: null, cached: 50),
        usageFixture(input: 10, cached: 20),
      ]);
      expect(totals.cacheHitRate, closeTo(.86, .0001));
      expect(totals.cacheRateRequests, 2);
      expect(UsageTotals([]).cacheHitRate, isNull);
      expect(
        UsageTotals([usageFixture(input: 0, cached: 0)]).cacheHitRate,
        isNull,
      );
      expect(
        UsageTotals([usageFixture(input: 100, cached: 0)]).cacheHitRate,
        0,
      );
      expect(
        UsagePeriod.all.contains(
          DateTime(2026, 9, 1).millisecondsSinceEpoch,
          DateTime(2026, 10, 28),
        ),
        isTrue,
      );
    },
  );
  final now = DateTime(2026, 10, 28, 12);
  late MemoryRequestUsageStore store;
  late RequestUsageController controller;

  setUp(() async {
    store = MemoryRequestUsageStore();
    controller = RequestUsageController(
      store,
      nowMillis: () => now.millisecondsSinceEpoch,
    );
    await controller.ready;
  });
  tearDown(() => controller.dispose());

  void feed(
    Map<String, dynamic> params, {
    String profile = 'server',
    AgentKind agent = AgentKind.codex,
    String provider = 'fixture-provider',
    String thread = 'thread',
  }) => controller.observe(
    profileId: profile,
    agent: agent,
    provider: provider,
    threadId: thread,
    params: params,
    fallbackModel: 'selected-model',
  );

  test(
    'one request merges partial/repeated/late updates without losing counts',
    () {
      feed(usageParams(output: 0));
      feed(
        usageParams(
          metrics: {
            'model': 'actual-model',
            'firstTokenMillis': 310,
            'durationMillis': 1400,
          },
        ),
      );
      feed(usageParams(output: 0));
      expect(controller.state.records, hasLength(1));
      final row = controller.state.records.single;
      expect(row.model, 'actual-model');
      expect(row.inputTokens, 100);
      expect(row.outputTokens, 20);
      expect(row.totalTokens, 120);
      expect(row.firstTokenMillis, 310);
      expect(row.durationMillis, 1400);
    },
  );

  test(
    'native cumulative usage separates equal-sized requests and deduplicates replay',
    () {
      feed(usageParams(requestId: null));
      feed(usageParams(requestId: null));
      feed(usageParams(requestId: null, cumulative: 240));
      expect(controller.state.records, hasLength(2));
      expect(UsageTotals(controller.state.records).totalTokens, 240);
    },
  );

  test(
    'late server timing corrects receipt time without inventing another request',
    () async {
      final started = now
          .subtract(const Duration(hours: 1))
          .millisecondsSinceEpoch;
      feed(usageParams(requestId: null));
      feed(usageParams(requestId: null, cumulative: 240));
      feed(
        usageParams(
          requestId: null,
          metrics: {
            'source': 'server',
            'startedAtMillis': started,
            'firstTokenMillis': 350,
            'durationMillis': 650,
          },
        ),
      );
      expect(controller.state.records, hasLength(2));
      final older = controller.state.records.last;
      expect(older.recordedAtMillis, started);
      expect(older.hasServerTimestamp, isTrue);
      expect(older.firstTokenMillis, 350);
      expect(older.durationMillis, 650);
      feed(usageParams(requestId: null));
      expect(controller.state.records.last.recordedAtMillis, started);
      await controller.flush();
      final restored = RequestUsageRecord.fromJson(older.toJson())!;
      expect(restored.hasServerTimestamp, isTrue);
      expect(restored.firstTokenMillis, 350);
      await controller.clear();
      feed(
        usageParams(
          requestId: null,
          metrics: {
            'source': 'server',
            'startedAtMillis': started,
            'firstTokenMillis': 350,
          },
        ),
      );
      expect(controller.state.records, isEmpty);
    },
  );

  test(
    'profile, agent, provider and thread isolate otherwise identical IDs',
    () {
      feed(usageParams());
      feed(usageParams(), profile: 'another-server');
      feed(usageParams(), agent: AgentKind.openCode);
      feed(usageParams(), agent: AgentKind.claudeCode);
      feed(usageParams(), provider: 'another-provider');
      feed(usageParams(), thread: 'another-thread');
      expect(controller.state.records, hasLength(6));
      expect(
        controller.state
            .latestFor(
              profileId: 'server',
              agent: AgentKind.codex,
              provider: 'fixture-provider',
              threadId: 'thread',
            )
            ?.model,
        'selected-model',
      );
    },
  );

  test('historical snapshots and invalid usage do not create requests', () {
    feed(usageParams(metrics: {'historical': true}));
    feed({
      'tokenUsage': {
        'total': {'totalTokens': 900},
      },
    });
    feed({
      'turnId': 'turn-1',
      'tokenUsage': {
        'last': {'inputTokens': 0, 'outputTokens': 0},
      },
    });
    expect(controller.state.records, isEmpty);
    feed(
      usageParams(
        metrics: {
          'usage': {'inputTokens': -1, 'outputTokens': '20'},
        },
      ),
    );
    final record = controller.state.records.single;
    expect(record.inputTokens, isNull);
    expect(record.outputTokens, isNull);
    expect(record.firstTokenMillis, isNull);
    expect(record.durationMillis, isNull);
  });

  test(
    'a late old request cannot replace the latest request or its timestamp',
    () {
      final at = now.millisecondsSinceEpoch;
      feed(usageParams(metrics: {'startedAtMillis': at - 1000}));
      feed(
        usageParams(requestId: 'request-2', metrics: {'startedAtMillis': at}),
      );
      feed(usageParams(output: 30, metrics: {'startedAtMillis': at + 1000}));
      expect(controller.state.records.first.outputTokens, 20);
      expect(controller.state.records.last.recordedAtMillis, at - 1000);
    },
  );

  test(
    'clear is persisted, replay stays cleared and new requests still work',
    () async {
      feed(usageParams());
      expect(await controller.clear(), isTrue);
      expect(store.snapshot.records, isEmpty);
      controller.dispose();
      controller = RequestUsageController(
        store,
        nowMillis: () => now.millisecondsSinceEpoch,
      );
      await controller.ready;
      feed(usageParams());
      expect(controller.state.records, isEmpty);
      feed(usageParams(requestId: 'request-new'));
      expect(controller.state.records, hasLength(1));
    },
  );

  test(
    'store failure is visible and retry preserves received records',
    () async {
      store.failWrite = true;
      feed(usageParams());
      expect(await controller.flush(), isFalse);
      expect(controller.state.error, isNotNull);
      store.failWrite = false;
      expect(await controller.retry(), isTrue);
      expect(store.snapshot.records, hasLength(1));
      expect(controller.state.error, isNull);
    },
  );

  test(
    'read failure never overwrites unread history; retry merges live usage',
    () async {
      controller.dispose();
      store.snapshot = UsageHistorySnapshot(records: [usageFixture()]);
      store.failRead = true;
      controller = RequestUsageController(
        store,
        nowMillis: () => now.millisecondsSinceEpoch,
      );
      await controller.ready;
      feed(usageParams());
      expect(await controller.flush(), isFalse);
      expect(store.writes, 0);
      store.failRead = false;
      expect(await controller.retry(), isTrue);
      expect(store.snapshot.records, hasLength(2));
    },
  );

  test(
    'notifications received while loading merge with disk and prune expired rows',
    () async {
      controller.dispose();
      final gate = Completer<UsageHistorySnapshot>();
      store.readGate = gate;
      controller = RequestUsageController(
        store,
        nowMillis: () => now.millisecondsSinceEpoch,
      );
      feed(usageParams());
      gate.complete(
        UsageHistorySnapshot(
          records: [
            usageFixture(),
            usageFixture(
              id: 'b',
              at: now.subtract(const Duration(days: 91)).millisecondsSinceEpoch,
            ),
          ],
        ),
      );
      await controller.ready;
      await controller.flush();
      expect(controller.state.records, hasLength(2));
      expect(store.snapshot.dismissedIds, contains('b'.padRight(64, 'b')));
    },
  );

  test('persistence is metadata only, never raw request payloads', () async {
    feed({
      ...usageParams(),
      'prompt': 'private-prompt',
      'apiKey': 'private-key',
      'response': 'private-response',
      'url': 'https://private.example.test',
    });
    await controller.flush();
    final data = jsonEncode(
      store.snapshot.records.map((r) => r.toJson()).toList(),
    );
    expect(data, isNot(contains('private-')));
    expect(data, isNot(contains('https://')));
  });

  test('local calendar filters have inclusive starts and exclusive ends', () {
    int day(int n) => DateTime(2026, 10, n).millisecondsSinceEpoch;
    expect(UsagePeriod.today.contains(day(28), now), isTrue);
    expect(UsagePeriod.today.contains(day(29), now), isFalse);
    expect(UsagePeriod.yesterday.contains(day(27), now), isTrue);
    expect(UsagePeriod.yesterday.contains(day(28), now), isFalse);
    expect(UsagePeriod.week.contains(day(22), now), isTrue);
    expect(UsagePeriod.week.contains(day(22) - 1, now), isFalse);
    expect(
      UsagePeriod.month.contains(
        DateTime(2026, 9, 29).millisecondsSinceEpoch,
        now,
      ),
      isTrue,
    );
  });

  test(
    'record parsing rejects invalid dates and preserves unknown versus zero',
    () {
      final data = usageFixture().toJson();
      expect(
        RequestUsageRecord.fromJson({
          ...data,
          'recordedAtMillis': 9007199254740991,
        }),
        isNull,
      );
      expect(
        RequestUsageRecord.fromJson({...data, 'inputTokens': 0})?.inputTokens,
        0,
      );
      expect(
        RequestUsageRecord.fromJson({...data, 'inputTokens': -1})?.inputTokens,
        isNull,
      );
      expect(
        UsageTotals([usageFixture(input: null, output: null)]).totalTokens,
        isNull,
      );
    },
  );
}
