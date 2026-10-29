import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/request_usage_controller.dart';
import '../domain/models.dart';
import '../domain/request_usage.dart';

void showUsageHistory(BuildContext context) {
  Navigator.of(
    context,
  ).push<void>(MaterialPageRoute(builder: (_) => const UsageHistoryScreen()));
}

String usageTokenLabel(int? value, {bool compact = true}) {
  if (value == null) return '—';
  if (!compact || value < 1000) return '$value';
  if (value < 1000000) return '${(value / 1000).toStringAsFixed(1)}k';
  if (value < 1000000000) return '${(value / 1000000).toStringAsFixed(1)}M';
  return '${(value / 1000000000).toStringAsFixed(1)}G';
}

String usageDurationLabel(int? millis) {
  if (millis == null) return '—';
  if (millis < 1000) return '${millis}ms';
  if (millis < 60000) return '${(millis / 1000).toStringAsFixed(2)}s';
  return '${millis ~/ 60000}m ${millis % 60000 ~/ 1000}s';
}

class UsageHistoryScreen extends ConsumerStatefulWidget {
  const UsageHistoryScreen({super.key, this.now});

  final DateTime Function()? now;

  @override
  ConsumerState<UsageHistoryScreen> createState() => _UsageHistoryScreenState();
}

class _UsageHistoryScreenState extends ConsumerState<UsageHistoryScreen> {
  UsagePeriod _period = UsagePeriod.today;
  String _modelFilter = 'all';
  bool _clearing = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空消耗统计？'),
        content: const Text('将删除本机所有日期的统计明细，无法撤销。不会删除对话或影响正在进行的请求。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _clearing = true);
    final saved = await ref.read(requestUsageProvider.notifier).clear();
    if (!mounted) return;
    setState(() => _clearing = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(saved ? '消耗统计已清空' : '当前记录已清空，但保存失败，请重试以防重启后恢复。')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(requestUsageProvider);
    final now = widget.now?.call() ?? DateTime.now();
    String modelKey(RequestUsageRecord record) =>
        record.model == null ? 'unknown' : 'model:${record.model}';
    final modelOptions =
        {
          'all': '全部模型',
          for (final record in state.records)
            modelKey(record): record.model ?? '模型未上报',
          if (_modelFilter != 'all')
            _modelFilter: _modelFilter == 'unknown'
                ? '模型未上报'
                : _modelFilter.substring(6),
        }.entries.toList()..sort(
          (a, b) => a.key == b.key
              ? 0
              : a.key == 'all'
              ? -1
              : b.key == 'all'
              ? 1
              : a.value.compareTo(b.value),
        );
    final records = state.records
        .where(
          (r) =>
              _period.contains(r.recordedAtMillis, now) &&
              (_modelFilter == 'all' || modelKey(r) == _modelFilter),
        )
        .toList();
    final totals = UsageTotals(records);
    return Scaffold(
      appBar: AppBar(
        title: const Text('消耗统计'),
        actions: [
          IconButton(
            tooltip: '清空全部记录',
            onPressed:
                _clearing ||
                    state.loading ||
                    (state.records.isEmpty && state.error == null)
                ? null
                : _clear,
            icon: _clearing
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: DropdownButtonFormField<UsagePeriod>(
                key: const ValueKey('usage-period'),
                initialValue: _period,
                decoration: const InputDecoration(
                  labelText: '日期范围',
                  isDense: true,
                ),
                items: [
                  for (final period in UsagePeriod.values)
                    DropdownMenuItem(value: period, child: Text(period.label)),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _period = value);
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: DropdownButtonFormField<String>(
                key: const ValueKey('usage-model'),
                initialValue: _modelFilter,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: '模型',
                  isDense: true,
                ),
                items: [
                  for (final option in modelOptions)
                    DropdownMenuItem(
                      value: option.key,
                      child: Text(
                        option.value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _modelFilter = value);
                },
              ),
            ),
            if (state.error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        state.error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: state.loading
                          ? null
                          : () =>
                                ref.read(requestUsageProvider.notifier).retry(),
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: state.loading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.builder(
                      key: const ValueKey('usage-history-list'),
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                      itemCount: records.length + 1,
                      itemBuilder: (context, index) {
                        if (index > 0) {
                          return _RequestUsageCard(record: records[index - 1]);
                        }
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${totals.requests} 笔请求',
                              key: const ValueKey('usage-request-count'),
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 16,
                              runSpacing: 6,
                              children: [
                                Text(
                                  '输入 ${usageTokenLabel(totals.inputTokens)}',
                                ),
                                Text(
                                  '输出 ${usageTokenLabel(totals.outputTokens)}',
                                ),
                                Text(
                                  '缓存 ${usageTokenLabel(totals.cachedInputTokens)}',
                                ),
                                Text(
                                  '总 Token ${usageTokenLabel(totals.totalTokens)}',
                                ),
                                Text(
                                  '缓存命中率 ${totals.cacheHitRate == null ? '—' : '${(totals.cacheHitRate! * 100).toStringAsFixed(1)}%'}',
                                  key: const ValueKey('usage-cache-hit-rate'),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '缓存已计入输入。命中率 = 缓存合计 ÷ 输入合计'
                              '（有效 ${totals.cacheRateRequests}/${totals.requests} 笔）。'
                              '未知值显示 —。仅统计本机收到的用量，非账单；最多保留 90 天、10000 笔。',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const Divider(height: 24),
                            if (records.isEmpty)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 32),
                                child: Center(child: Text('当前筛选暂无记录')),
                              ),
                          ],
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RequestUsageCard extends StatelessWidget {
  const _RequestUsageCard({required this.record});
  final RequestUsageRecord record;

  @override
  Widget build(BuildContext context) {
    final date = DateTime.fromMillisecondsSinceEpoch(
      record.recordedAtMillis,
    ).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final fields = [
      ('输入', usageTokenLabel(record.inputTokens)),
      ('输出', usageTokenLabel(record.outputTokens)),
      ('缓存命中', usageTokenLabel(record.cachedInputTokens)),
      ('首字', usageDurationLabel(record.firstTokenMillis)),
      ('总耗时', usageDurationLabel(record.durationMillis)),
      ('总 Token', usageTokenLabel(record.totalTokens)),
    ];
    return Card(
      key: ValueKey('usage-record-${record.id}'),
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              record.model ?? '模型未上报',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              '${record.agent.label} · ${date.year}-${two(date.month)}-${two(date.day)} '
              '${two(date.hour)}:${two(date.minute)}:${two(date.second)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            for (var index = 0; index < fields.length; index += 2)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final field in fields.skip(index).take(2))
                      Expanded(
                        child: Text(
                          '${field.$1}  ${field.$2}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
