import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/app_controller.dart';
import '../domain/models.dart';
import 'theme.dart';

class ThreadListScreen extends ConsumerWidget {
  const ThreadListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appControllerProvider);
    final profile = state.profiles
        .where((candidate) => candidate.id == state.selectedProfileId)
        .firstOrNull;
    return Scaffold(
      appBar: AppBar(
        title: InkWell(
          onTap: () => ref.read(appControllerProvider.notifier).backToServers(),
          borderRadius: BorderRadius.circular(5),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Agent'),
                Text(
                  profile?.name ?? '未选择服务器',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: '刷新会话',
            onPressed: null,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '新建会话',
            onPressed: null,
            icon: const Icon(Icons.add_comment_outlined),
          ),
          IconButton(
            tooltip: '终端',
            onPressed: null,
            icon: const Icon(Icons.terminal),
          ),
          IconButton(
            tooltip: '服务器设置',
            onPressed: null,
            icon: const Icon(Icons.settings),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: _ServerStatusLine(
                connection: state.connection,
                metrics: profile == null
                    ? null
                    : state.serverMetrics[profile.id],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<AgentKind>(
                  segments: const [
                    ButtonSegment(
                      value: AgentKind.codex,
                      label: Text('Codex'),
                      icon: Icon(Icons.code, size: 18),
                    ),
                    ButtonSegment(
                      value: AgentKind.openCode,
                      label: Text('OpenCode'),
                      icon: Icon(Icons.hub_outlined, size: 18),
                    ),
                  ],
                  selected: {state.activeAgent},
                  showSelectedIcon: false,
                  onSelectionChanged: null,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              child: TextField(
                enabled: false,
                decoration: const InputDecoration(
                  hintText: '搜索最近任务',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
            ),
            const Divider(height: 1),
            const Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.link_off, size: 34, color: codexMuted),
                    SizedBox(height: 10),
                    Text('Agent 尚未连接'),
                    SizedBox(height: 4),
                    Text(
                      '选择 Codex 或 OpenCode 后再加载会话',
                      style: TextStyle(color: codexMuted, letterSpacing: 0),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ServerStatusLine extends StatelessWidget {
  const _ServerStatusLine({required this.connection, required this.metrics});

  final ConnectionState connection;
  final ServerMetrics? metrics;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: connection.phase == ConnectionPhase.connected
                ? codexGreen
                : codexMuted,
          ),
        ),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            connection.message,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        _compactMetric(Icons.speed, metrics?.cpuPercent),
        _compactMetric(Icons.memory, metrics?.memoryPercent),
        _compactMetric(Icons.storage, metrics?.diskPercent),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _compactMetric(IconData icon, int? value) => Padding(
    padding: const EdgeInsets.only(left: 9),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: codexMuted),
        const SizedBox(width: 2),
        Text(
          value == null ? '--' : '$value%',
          style: const TextStyle(
            fontSize: 11,
            color: codexMuted,
            letterSpacing: 0,
          ),
        ),
      ],
    ),
  );
}
