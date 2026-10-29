import 'package:codex_remote/src/app/request_usage_controller.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/persistence/request_usage_store.dart';
import 'package:codex_remote/src/ui/request_usage_summary.dart';
import 'package:codex_remote/src/ui/theme.dart';
import 'package:codex_remote/src/ui/usage_history_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/request_usage_fixture.dart';

void main() {
  test('token labels use compact units in summaries and records', () {
    expect(usageTokenLabel(null), '—');
    expect(usageTokenLabel(0), '0');
    expect(usageTokenLabel(999), '999');
    expect(usageTokenLabel(1000), '1.0k');
    expect(usageTokenLabel(106900), '106.9k');
    expect(usageTokenLabel(236782), '236.8k');
    expect(usageTokenLabel(1000000), '1.0M');
  });
  testWidgets(
    'filters all four local date ranges and clear requires confirmation',
    (tester) async {
      final now = DateTime(2026, 10, 28, 12);
      final store = MemoryRequestUsageStore()
        ..snapshot = UsageHistorySnapshot(
          records: [
            usageFixture(model: 'today-model'),
            usageFixture(
              id: 'b',
              model: 'yesterday-model',
              at: now.subtract(const Duration(days: 1)).millisecondsSinceEpoch,
            ),
            usageFixture(
              id: 'c',
              model: 'week-model',
              at: now.subtract(const Duration(days: 6)).millisecondsSinceEpoch,
            ),
            usageFixture(
              id: 'd',
              model: 'month-model',
              at: now.subtract(const Duration(days: 29)).millisecondsSinceEpoch,
            ),
          ],
        );
      final controller = RequestUsageController(
        store,
        nowMillis: () => now.millisecondsSinceEpoch,
      );
      await controller.ready;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [requestUsageProvider.overrideWith((ref) => controller)],
          child: MaterialApp(
            theme: buildCodexTheme(),
            home: UsageHistoryScreen(now: () => now),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('today-model'), findsWidgets);
      expect(find.text('1 笔请求'), findsOneWidget);
      for (final (label, count) in [('昨天', 1), ('近7天', 3), ('近30天', 4)]) {
        await tester.tap(find.byKey(const ValueKey('usage-period')));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
        expect(find.text('$count 笔请求'), findsOneWidget);
      }
      await tester.tap(find.byTooltip('清空全部记录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(controller.state.records, hasLength(4));
      await tester.tap(find.byTooltip('清空全部记录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清空'));
      await tester.pumpAndSettle();
      expect(controller.state.records, isEmpty);
      expect(store.snapshot.records, isEmpty);
      expect(find.text('当前筛选暂无记录'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('history cards and totals both abbreviate large token counts', (
    tester,
  ) async {
    final now = DateTime(2026, 10, 28, 12);
    final store = MemoryRequestUsageStore()
      ..snapshot = UsageHistorySnapshot(
        records: [usageFixture(input: 12345, output: 2345)],
      );
    final controller = RequestUsageController(
      store,
      nowMillis: () => now.millisecondsSinceEpoch,
    );
    await controller.ready;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [requestUsageProvider.overrideWith((ref) => controller)],
        child: MaterialApp(home: UsageHistoryScreen(now: () => now)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('12.3k'), findsWidgets);
    expect(find.textContaining('2.3k'), findsWidgets);
    expect(find.textContaining('12345'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('model and date filters update weighted cache rate together', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.reset);
    final now = DateTime(2026, 10, 28, 12);
    final store = MemoryRequestUsageStore()
      ..snapshot = UsageHistorySnapshot(
        records: [
          usageFixture(model: 'model-A', input: 100, cached: 50),
          usageFixture(id: 'b', model: 'model-B', input: 900, cached: 810),
          usageFixture(
            id: 'c',
            model: 'model-A',
            input: 400,
            cached: 100,
            at: now.subtract(const Duration(days: 1)).millisecondsSinceEpoch,
          ),
          usageFixture(id: 'd', model: null, input: 50, cached: null),
        ],
      );
    final controller = RequestUsageController(
      store,
      nowMillis: () => now.millisecondsSinceEpoch,
    );
    await controller.ready;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [requestUsageProvider.overrideWith((ref) => controller)],
        child: MaterialApp(
          theme: buildCodexTheme(),
          home: UsageHistoryScreen(now: () => now),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Future<void> select(String key, String label) async {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    expect(find.text('缓存命中率 86.0%'), findsOneWidget);
    await select('usage-model', 'model-A');
    expect(find.text('1 笔请求'), findsOneWidget);
    expect(find.text('缓存命中率 50.0%'), findsOneWidget);
    await select('usage-period', '全部日期');
    expect(find.text('2 笔请求'), findsOneWidget);
    expect(find.text('缓存命中率 30.0%'), findsOneWidget);
    await select('usage-model', '全部模型');
    expect(find.text('4 笔请求'), findsOneWidget);
    expect(find.text('缓存命中率 68.6%'), findsOneWidget);
    await select('usage-model', '模型未上报');
    expect(find.text('缓存命中率 —'), findsOneWidget);
    await select('usage-period', '昨天');
    expect(find.text('0 笔请求'), findsOneWidget);
    expect(find.text('缓存命中率 —'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'single-row icon summary stays compact and opens history at 2x text',
    (tester) async {
      tester.view.physicalSize = const Size(640, 1600);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final store = MemoryRequestUsageStore()
        ..snapshot = UsageHistorySnapshot(
          records: [usageFixture(input: 12345)],
        );
      final controller = RequestUsageController(
        store,
        nowMillis: () => DateTime(2026, 10, 28, 12).millisecondsSinceEpoch,
      );
      await controller.ready;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [requestUsageProvider.overrideWith((ref) => controller)],
          child: MaterialApp(
            theme: buildCodexTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(2)),
              child: child!,
            ),
            home: const Scaffold(
              body: Center(
                child: SizedBox(
                  width: 160,
                  child: RequestUsageSummary(
                    profileId: 'server',
                    agent: AgentKind.codex,
                    provider: 'fixture-provider',
                    threadId: 'thread',
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('12.3k'), findsOneWidget);
      final target = find.byKey(const ValueKey('request-usage-summary'));
      expect(tester.getSize(target).height, inInclusiveRange(32, 40));
      expect(
        tester.getTopLeft(find.byIcon(Icons.arrow_upward)).dy,
        tester.getTopLeft(find.byIcon(Icons.cached)).dy,
      );
      // Tap the blank central gap, not an icon or a number.
      await tester.tapAt(tester.getCenter(target));
      await tester.pumpAndSettle();
      expect(find.byType(UsageHistoryScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'unknown metrics stay unknown, read errors offer retry and explicit clear',
    (tester) async {
      final store = MemoryRequestUsageStore()..failRead = true;
      final controller = RequestUsageController(store);
      await controller.ready;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [requestUsageProvider.overrideWith((ref) => controller)],
          child: MaterialApp(
            theme: buildCodexTheme(),
            home: const UsageHistoryScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('输入 —'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.ancestor(
                of: find.byIcon(Icons.delete_outline),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNotNull,
      );
      store.failRead = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(controller.state.error, isNull);
      expect(usageDurationLabel(null), '—');
      expect(usageDurationLabel(350), '350ms');
      expect(usageDurationLabel(2100), '2.10s');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
