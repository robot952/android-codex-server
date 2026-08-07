import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/app_controller.dart';
import '../domain/models.dart';
import 'server_metrics_strip.dart';
import 'theme.dart';

class ThreadListScreen extends ConsumerStatefulWidget {
  const ThreadListScreen({super.key});

  @override
  ConsumerState<ThreadListScreen> createState() => _ThreadListScreenState();
}

class _ThreadListScreenState extends ConsumerState<ThreadListScreen> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  String? _requestedLane;

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appControllerProvider);
    final controller = ref.read(appControllerProvider.notifier);
    final profile = state.profiles
        .where((candidate) => candidate.id == state.selectedProfileId)
        .firstOrNull;
    final profileId = profile?.id;
    final hostConnected =
        profileId != null &&
        state.connectionStates[profileId]?.phase == ConnectionPhase.connected;
    final key = profileId == null
        ? null
        : AgentConnectionKey(profileId: profileId, agent: state.activeAgent);
    final agentState = key == null
        ? const ConnectionState()
        : state.agentConnectionStates[key] ?? const ConnectionState();
    final agentConnected = agentState.phase == ConnectionPhase.connected;
    final loading = key != null && state.agentLoadingStates[key] == true;
    final sourceThreads = key == null
        ? const <AgentThread>[]
        : state.agentThreadLists[key] ?? const <AgentThread>[];
    final threads = _visibleThreads(sourceThreads, state.threadSearch);

    if (!_searchFocus.hasFocus &&
        _searchController.text != state.threadSearch) {
      _searchController.value = TextEditingValue(
        text: state.threadSearch,
        selection: TextSelection.collapsed(offset: state.threadSearch.length),
      );
    }
    _scheduleInitialConnection(
      hostConnected: hostConnected,
      key: key,
      phase: agentState.phase,
    );

    return Scaffold(
      appBar: AppBar(
        title: InkWell(
          onTap: controller.backToServers,
          borderRadius: BorderRadius.circular(5),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Agent'),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: hostConnected ? codexGreen : codexMuted,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        profile?.name ?? '未选择服务器',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: '刷新会话',
            onPressed: agentConnected && !loading
                ? controller.refreshThreads
                : null,
            icon: loading
                ? const SizedBox.square(
                    dimension: 19,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '新建会话',
            onPressed: agentConnected && !loading && !state.submitting
                ? controller.createThread
                : null,
            icon: const Icon(Icons.add_comment_outlined),
          ),
          IconButton(
            tooltip: '终端',
            onPressed: hostConnected ? controller.openTerminal : null,
            icon: const Icon(Icons.terminal),
          ),
          PopupMenuButton<_ThreadSettingsAction>(
            tooltip: '服务器设置',
            icon: const Icon(Icons.settings),
            onSelected: (action) {
              switch (action) {
                case _ThreadSettingsAction.workspace:
                  controller.showWorkspacePicker();
                case _ThreadSettingsAction.agentSettings:
                  controller.showAgentSettings();
                case _ThreadSettingsAction.fileManager:
                  controller.showFileManager();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: _ThreadSettingsAction.workspace,
                enabled: agentConnected,
                child: const Row(
                  children: [
                    Icon(Icons.folder_outlined, size: 19),
                    SizedBox(width: 10),
                    Text('选择工作目录'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: _ThreadSettingsAction.agentSettings,
                enabled:
                    agentConnected &&
                    state.activeAgentCapabilities.globalSettings,
                child: Row(
                  children: [
                    const Icon(Icons.tune, size: 19),
                    const SizedBox(width: 10),
                    Text('配置 ${state.activeAgent.label}'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: _ThreadSettingsAction.fileManager,
                enabled: hostConnected,
                child: const Row(
                  children: [
                    Icon(Icons.folder_open_outlined, size: 19),
                    SizedBox(width: 10),
                    Text('文件管理'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 18, right: 18, bottom: 1),
              child: ServerMetricsStrip(
                metrics: profile == null
                    ? null
                    : state.serverMetrics[profile.id],
                showResourceDetails: true,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
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
                  onSelectionChanged: hostConnected && !loading
                      ? (selection) => controller.selectAgent(selection.first)
                      : null,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              child: TextField(
                controller: _searchController,
                focusNode: _searchFocus,
                enabled: agentConnected,
                textInputAction: TextInputAction.search,
                onChanged: controller.setThreadSearch,
                onSubmitted: (_) => controller.refreshThreads(),
                decoration: const InputDecoration(
                  hintText: '搜索最近任务',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _ThreadListBody(
                agent: state.activeAgent,
                hostConnected: hostConnected,
                connectionState: agentState,
                loading: loading,
                query: state.threadSearch,
                threads: threads,
                diagnostic: state.diagnostic,
                onRetry: controller.ensureActiveAgent,
                onOpen: controller.openThread,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _scheduleInitialConnection({
    required bool hostConnected,
    required AgentConnectionKey? key,
    required ConnectionPhase phase,
  }) {
    if (!hostConnected || key == null) {
      _requestedLane = null;
      return;
    }
    final lane = '${key.profileId}:${key.agent.name}';
    if (phase != ConnectionPhase.disconnected || _requestedLane == lane) return;
    _requestedLane = lane;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(appControllerProvider.notifier).ensureActiveAgent();
      }
    });
  }
}

enum _ThreadSettingsAction { workspace, agentSettings, fileManager }

class _ThreadListBody extends StatelessWidget {
  const _ThreadListBody({
    required this.agent,
    required this.hostConnected,
    required this.connectionState,
    required this.loading,
    required this.query,
    required this.threads,
    required this.diagnostic,
    required this.onRetry,
    required this.onOpen,
  });

  final AgentKind agent;
  final bool hostConnected;
  final ConnectionState connectionState;
  final bool loading;
  final String query;
  final List<AgentThread> threads;
  final String? diagnostic;
  final Future<void> Function() onRetry;
  final void Function(AgentThread thread) onOpen;

  @override
  Widget build(BuildContext context) {
    if (threads.isNotEmpty) {
      return Column(
        children: [
          if (loading) const LinearProgressIndicator(minHeight: 2),
          if (diagnostic != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 7, 16, 3),
              child: Text(
                diagnostic!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          Expanded(
            child: ListView.separated(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 18),
              itemCount: threads.length,
              separatorBuilder: (_, _) => const Divider(height: 1, indent: 52),
              itemBuilder: (context, index) => _ThreadRow(
                threads[index],
                onTap: () => onOpen(threads[index]),
              ),
            ),
          ),
        ],
      );
    }

    if (loading || connectionState.phase == ConnectionPhase.connecting) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(strokeWidth: 2),
            const SizedBox(height: 12),
            Text(connectionState.message),
          ],
        ),
      );
    }

    final failed = connectionState.phase == ConnectionPhase.failed;
    final message = switch ((hostConnected, failed, query.trim().isNotEmpty)) {
      (false, _, _) => 'SSH 尚未连接',
      (_, true, _) => connectionState.message,
      (_, _, true) => '没有匹配任务',
      _ => '暂无任务',
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              failed ? Icons.error_outline : Icons.terminal,
              size: 34,
              color: failed ? Theme.of(context).colorScheme.error : codexMuted,
            ),
            const SizedBox(height: 10),
            Text(message, textAlign: TextAlign.center),
            if (failed && hostConnected) ...[
              const SizedBox(height: 12),
              IconButton.filledTonal(
                tooltip: '重新连接 ${agent.label}',
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ThreadRow extends StatelessWidget {
  const _ThreadRow(this.thread, {required this.onTap});

  final AgentThread thread;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final running = _isRunning(thread);
    final updatedAt = _updatedAtLabel(thread.updatedAt);
    final subtitle = <String>[
      if (thread.preview.trim().isNotEmpty) thread.preview.trim(),
      if (thread.cwd.trim().isNotEmpty) thread.cwd.trim(),
    ].join('\n');
    return ListTile(
      onTap: onTap,
      minTileHeight: 68,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      leading: SizedBox.square(
        dimension: 32,
        child: Center(
          child: running
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.chat_bubble_outline, size: 20),
        ),
      ),
      title: Text(
        thread.title.trim().isEmpty ? '未命名任务' : thread.title.trim(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: subtitle.isEmpty
          ? null
          : Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: updatedAt != null
          ? Text(updatedAt, style: Theme.of(context).textTheme.bodySmall)
          : null,
    );
  }
}

List<AgentThread> _visibleThreads(List<AgentThread> threads, String query) {
  final normalized = query.trim().toLowerCase();
  if (normalized.isEmpty) return threads;
  return threads
      .where(
        (thread) =>
            thread.title.toLowerCase().contains(normalized) ||
            thread.preview.toLowerCase().contains(normalized) ||
            thread.cwd.toLowerCase().contains(normalized),
      )
      .toList(growable: false);
}

bool _isRunning(AgentThread thread) {
  if (thread.activeTurnId?.isNotEmpty ?? false) return true;
  return switch (thread.status.toLowerCase()) {
    'active' || 'running' || 'inprogress' || 'in_progress' => true,
    _ => false,
  };
}

String? _updatedAtLabel(int value) {
  if (value <= 0) return null;
  final millis = value < 100000000000 ? value * 1000 : value;
  final updated = DateTime.fromMillisecondsSinceEpoch(millis).toLocal();
  final now = DateTime.now();
  if (updated.year == now.year &&
      updated.month == now.month &&
      updated.day == now.day) {
    return '${updated.hour.toString().padLeft(2, '0')}:'
        '${updated.minute.toString().padLeft(2, '0')}';
  }
  return '${updated.month}/${updated.day}';
}
