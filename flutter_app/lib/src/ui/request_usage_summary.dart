import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/request_usage_controller.dart';
import '../domain/models.dart';
import 'usage_history_screen.dart';

/// The whole two-line region is one touch target, including gaps between values.
class RequestUsageSummary extends ConsumerWidget {
  const RequestUsageSummary({
    super.key,
    required this.profileId,
    required this.agent,
    required this.provider,
    required this.threadId,
  });

  final String profileId;
  final AgentKind agent;
  final String provider;
  final String threadId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final record = ref.watch(
      requestUsageProvider.select(
        (state) => state.latestFor(
          profileId: profileId,
          agent: agent,
          provider: provider,
          threadId: threadId,
        ),
      ),
    );
    final values = [
      (
        Icons.arrow_upward,
        '输入 Token',
        usageTokenLabel(record?.inputTokens, compact: true),
      ),
      (
        Icons.arrow_downward,
        '输出 Token',
        usageTokenLabel(record?.outputTokens, compact: true),
      ),
      (
        Icons.cached,
        '缓存命中 Token',
        usageTokenLabel(record?.cachedInputTokens, compact: true),
      ),
      (
        Icons.bolt_outlined,
        '首字延迟',
        usageDurationLabel(record?.firstTokenMillis),
      ),
    ];
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: const ValueKey('request-usage-summary'),
        borderRadius: BorderRadius.circular(4),
        onTap: () => showUsageHistory(context),
        child: Semantics(
          label: '最近一次请求用量，点击查看消耗统计',
          button: true,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var index = 0; index < 4; index += 2)
                    Row(
                      children: [
                        for (final value in values.skip(index).take(2))
                          Expanded(
                            child: Tooltip(
                              message: '${value.$2}：${value.$3}',
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 2,
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      value.$1,
                                      size: 12,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                                    const SizedBox(width: 2),
                                    Expanded(
                                      child: Text(
                                        value.$3,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(fontSize: 11),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
