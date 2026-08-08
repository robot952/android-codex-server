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
    AgentSetupState? setupFor(AgentKind agent) {
      if (profileId == null) return null;
      return state.agentSetupStates[AgentConnectionKey(
        profileId: profileId,
        agent: agent,
      )];
    }

    final sourceThreads = key == null
        ? const <AgentThread>[]
        : state.agentThreadLists[key] ?? const <AgentThread>[];
    final threads = visibleAgentThreads(
      sourceThreads,
      state.threadSearch,
      agentConnected: agentConnected,
    );

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
            tooltip: '终端',
            onPressed: hostConnected ? controller.openTerminal : null,
            icon: const Icon(Icons.terminal),
          ),
          IconButton(
            tooltip: '刷新会话',
            onPressed: agentConnected && !loading
                ? controller.refreshThreads
                : null,
            icon: hostConnected && loading
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
            tooltip: '设置',
            onPressed: hostConnected
                ? () => _showThreadSettings(context, state, controller)
                : null,
            icon: const Icon(Icons.settings),
          ),
          IconButton(
            tooltip: '切换服务器',
            onPressed: () => _showServerSwitcher(context, state, controller),
            icon: const Icon(Icons.dns),
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
              padding: const EdgeInsets.fromLTRB(18, 7, 18, 7),
              child: _AgentSwitcher(
                activeAgent: state.activeAgent,
                enabled: hostConnected && !loading,
                setupFor: setupFor,
                connectionFor: (agent) =>
                    state.agentConnectionStates[AgentConnectionKey(
                      profileId: profileId ?? '',
                      agent: agent,
                    )],
                onSelect: controller.selectAgent,
                onResume: (agent) =>
                    _resumeAgentSetup(state.activeAgent, agent, controller),
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
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0.05, 0),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                child: _ThreadListBody(
                  key: ValueKey(state.activeAgent),
                  agent: state.activeAgent,
                  hostConnected: hostConnected,
                  connectionState: agentState,
                  loading: loading,
                  query: state.threadSearch,
                  threads: threads,
                  diagnostic: state.diagnostic,
                  onRetry: controller.ensureActiveAgent,
                  onReconnect: profile == null
                      ? null
                      : () => controller.requestConnect(profile),
                  onOpen: controller.openThread,
                  hasMoreThreads: controller.activeThreadListHasMore,
                  onLoadMore: controller.loadMoreThreads,
                ),
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

  void _resumeAgentSetup(
    AgentKind activeAgent,
    AgentKind targetAgent,
    AppController controller,
  ) {
    if (activeAgent == targetAgent) {
      controller.resumeRemoteSetup();
    } else {
      controller.selectAgent(targetAgent);
    }
  }
}

void _showThreadSettings(
  BuildContext context,
  AppUiState state,
  AppController controller,
) {
  showDialog<void>(
    context: context,
    builder: (_) => _ThreadSettingsDialog(
      agent: state.activeAgent,
      agentConnected:
          state
              .agentConnectionStates[AgentConnectionKey(
                profileId: state.selectedProfileId ?? '',
                agent: state.activeAgent,
              )]
              ?.phase ==
          ConnectionPhase.connected,
      canConfigureAgent: state.activeAgentCapabilities.globalSettings,
      hostConnected:
          state.selectedProfileId != null &&
          state.connectionStates[state.selectedProfileId]?.phase ==
              ConnectionPhase.connected,
      onSelectWorkspace: () {
        Navigator.of(context).pop();
        controller.showWorkspacePicker();
      },
      onConfigureAgent: () {
        Navigator.of(context).pop();
        controller.showAgentSettings();
      },
      onOpenFileManager: () {
        Navigator.of(context).pop();
        controller.showFileManager();
      },
    ),
  );
}

void _showServerSwitcher(
  BuildContext context,
  AppUiState state,
  AppController controller,
) {
  showDialog<void>(
    context: context,
    builder: (_) => _ServerSwitcherDialog(
      state: state,
      onSelect: (profile) {
        Navigator.of(context).pop();
        controller.selectProfile(profile.id);
      },
      onManage: () {
        Navigator.of(context).pop();
        controller.backToServers();
      },
    ),
  );
}

class _ThreadSettingsDialog extends StatelessWidget {
  const _ThreadSettingsDialog({
    required this.agent,
    required this.agentConnected,
    required this.canConfigureAgent,
    required this.hostConnected,
    required this.onSelectWorkspace,
    required this.onConfigureAgent,
    required this.onOpenFileManager,
  });

  final AgentKind agent;
  final bool agentConnected;
  final bool canConfigureAgent;
  final bool hostConnected;
  final VoidCallback onSelectWorkspace;
  final VoidCallback onConfigureAgent;
  final VoidCallback onOpenFileManager;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Material(
          color: codexRaised,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
                child: Text(
                  '设置',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              _SettingsActionRow(
                icon: Icons.folder,
                title: '选择工作目录',
                detail: '切换新会话默认使用的目录',
                enabled: agentConnected,
                onTap: onSelectWorkspace,
              ),
              _SettingsActionRow(
                icon: Icons.settings,
                title: '配置 ${agent.label}',
                detail: '模型地址、API 密钥和代理',
                enabled: agentConnected && canConfigureAgent,
                onTap: onConfigureAgent,
              ),
              _SettingsActionRow(
                icon: Icons.folder_open,
                title: '文件管理',
                detail: '浏览和管理服务器文件',
                enabled: hostConnected,
                onTap: onOpenFileManager,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsActionRow extends StatelessWidget {
  const _SettingsActionRow({
    required this.icon,
    required this.title,
    required this.detail,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String detail;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.38,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          child: Row(
            children: [
              SizedBox(
                width: 34,
                height: 34,
                child: Icon(icon, size: 27, color: codexText),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.bodyLarge),
                    Text(detail, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ServerSwitcherDialog extends StatelessWidget {
  const _ServerSwitcherDialog({
    required this.state,
    required this.onSelect,
    required this.onManage,
  });

  final AppUiState state;
  final ValueChanged<ServerProfile> onSelect;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final connectedCount = state.connectionStates.values
        .where((connection) => connection.phase == ConnectionPhase.connected)
        .length;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440, maxHeight: 560),
        child: Material(
          color: codexRaised,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 8, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '切换服务器',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Text(
                            '$connectedCount 台已连接',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: state.profiles.length,
                  itemBuilder: (context, index) {
                    final profile = state.profiles[index];
                    final connected =
                        state.connectionStates[profile.id]?.phase ==
                        ConnectionPhase.connected;
                    final selected = profile.id == state.selectedProfileId;
                    return InkWell(
                      onTap: () => onSelect(profile),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 12,
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: connected
                                    ? codexGreen
                                    : codexMuted.withValues(alpha: 0.62),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    profile.name.trim().isEmpty
                                        ? '未命名服务器'
                                        : profile.name.trim(),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    '${profile.username.trim().isEmpty ? 'root' : profile.username}@${profile.host.trim().isEmpty ? '待配置' : profile.host}:${profile.port}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(fontFamily: 'monospace'),
                                  ),
                                ],
                              ),
                            ),
                            if (selected) const Icon(Icons.check, size: 22),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              const Divider(height: 1),
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 3, 8, 5),
                  child: TextButton(
                    onPressed: onManage,
                    child: const Text('管理服务器'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AgentSwitcher extends StatelessWidget {
  const _AgentSwitcher({
    required this.activeAgent,
    required this.enabled,
    required this.setupFor,
    required this.connectionFor,
    required this.onSelect,
    required this.onResume,
  });

  final AgentKind activeAgent;
  final bool enabled;
  final AgentSetupState? Function(AgentKind agent) setupFor;
  final ConnectionState? Function(AgentKind agent) connectionFor;
  final ValueChanged<AgentKind> onSelect;
  final ValueChanged<AgentKind> onResume;

  @override
  Widget build(BuildContext context) {
    final selected = activeAgent == AgentKind.codex;
    return SizedBox(
      height: 54,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: codexSurface,
          border: Border.all(color: codexBorder),
          borderRadius: BorderRadius.circular(10),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final segmentWidth = constraints.maxWidth / 2;
            return Stack(
              children: [
                AnimatedAlign(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  alignment: selected
                      ? Alignment.centerLeft
                      : Alignment.centerRight,
                  child: SizedBox(
                    width: segmentWidth,
                    height: double.infinity,
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: codexRaised,
                          border: Border.all(
                            color: codexGreen.withValues(alpha: 0.72),
                          ),
                          borderRadius: BorderRadius.circular(7),
                        ),
                      ),
                    ),
                  ),
                ),
                Row(
                  children: [
                    _AgentSegment(
                      agent: AgentKind.codex,
                      selected: selected,
                      enabled: enabled,
                      setup: setupFor(AgentKind.codex),
                      connection: connectionFor(AgentKind.codex),
                      onTap: () => onSelect(AgentKind.codex),
                      onResume: () => onResume(AgentKind.codex),
                    ),
                    _AgentSegment(
                      agent: AgentKind.openCode,
                      selected: !selected,
                      enabled: enabled,
                      setup: setupFor(AgentKind.openCode),
                      connection: connectionFor(AgentKind.openCode),
                      onTap: () => onSelect(AgentKind.openCode),
                      onResume: () => onResume(AgentKind.openCode),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _AgentSegment extends StatelessWidget {
  const _AgentSegment({
    required this.agent,
    required this.selected,
    required this.enabled,
    required this.setup,
    required this.connection,
    required this.onTap,
    required this.onResume,
  });

  final AgentKind agent;
  final bool selected;
  final bool enabled;
  final AgentSetupState? setup;
  final ConnectionState? connection;
  final VoidCallback onTap;
  final VoidCallback onResume;

  @override
  Widget build(BuildContext context) {
    final install = setup;
    final canResume =
        enabled && install?.prompt != null && install?.minimized == true;
    final percent = install?.percent.clamp(0, 100) ?? 0;
    final progress = install?.inProgress == true
        ? (percent > 0 ? percent / 100 : null)
        : null;
    final failed =
        install != null &&
        !install.inProgress &&
        install.prompt != null &&
        install.progress.toLowerCase().contains('失败');
    final phase = connection?.phase;
    final statusColor = phase == ConnectionPhase.connected
        ? codexGreen
        : phase == ConnectionPhase.failed || failed
        ? codexRed
        : phase == ConnectionPhase.installing || install?.inProgress == true
        ? codexAmber
        : codexMuted.withValues(alpha: 0.62);

    final label = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle),
        ),
        const SizedBox(width: 7),
        Text(
          agent.label,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? codexText : codexMuted,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (install?.inProgress == true && progress != null) ...[
          const SizedBox(width: 7),
          Text(
            '$percent%',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: codexGreen,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
    if (install?.inProgress != true && !failed) {
      return Expanded(
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: Center(child: label),
        ),
      );
    }

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(child: label),
        const SizedBox(height: 3),
        LinearProgressIndicator(
          value: failed ? 1 : progress,
          minHeight: 3,
          color: failed ? codexRed : codexGreen,
          backgroundColor: codexBorder,
          borderRadius: BorderRadius.circular(2),
        ),
      ],
    );
    return Expanded(
      child: InkWell(
        key: ValueKey('resume-${agent.name}-setup'),
        onTap: canResume ? onResume : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: content,
        ),
      ),
    );
  }
}

class _ThreadListBody extends StatefulWidget {
  const _ThreadListBody({
    super.key,
    required this.agent,
    required this.hostConnected,
    required this.connectionState,
    required this.loading,
    required this.query,
    required this.threads,
    required this.diagnostic,
    required this.onRetry,
    required this.onReconnect,
    required this.onOpen,
    required this.hasMoreThreads,
    required this.onLoadMore,
  });

  final AgentKind agent;
  final bool hostConnected;
  final ConnectionState connectionState;
  final bool loading;
  final String query;
  final List<AgentThread> threads;
  final String? diagnostic;
  final Future<void> Function() onRetry;
  final Future<void> Function()? onReconnect;
  final void Function(AgentThread thread) onOpen;
  final bool hasMoreThreads;
  final Future<void> Function() onLoadMore;

  @override
  State<_ThreadListBody> createState() => _ThreadListBodyState();
}

class _ThreadListBodyState extends State<_ThreadListBody> {
  bool _loadingMore = false;

  @override
  void didUpdateWidget(covariant _ThreadListBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.agent != widget.agent ||
        oldWidget.query != widget.query ||
        oldWidget.threads.isEmpty && widget.threads.isEmpty) {
      _loadingMore = false;
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !widget.hasMoreThreads || !mounted) return;
    setState(() => _loadingMore = true);
    try {
      await widget.onLoadMore();
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  bool _handleScroll(ScrollNotification notification) {
    if (notification.metrics.extentAfter < 240 &&
        widget.hasMoreThreads &&
        !_loadingMore) {
      _loadMore();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final agent = widget.agent;
    final hostConnected = widget.hostConnected;
    final connectionState = widget.connectionState;
    final loading = widget.loading;
    final query = widget.query;
    final threads = widget.threads;
    final diagnostic = widget.diagnostic;
    final onRetry = widget.onRetry;
    final onReconnect = widget.onReconnect;
    final onOpen = widget.onOpen;
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(18, 7, 18, 7),
      child: Row(
        children: [
          Text(
            query.trim().isEmpty ? '最近任务' : '搜索结果',
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(color: codexMuted),
          ),
          const Spacer(),
          Text(
            '${threads.length}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
    if (threads.isNotEmpty) {
      return NotificationListener<ScrollNotification>(
        onNotification: _handleScroll,
        child: Column(
          children: [
            if (loading) const LinearProgressIndicator(minHeight: 2),
            if (diagnostic != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 7, 16, 3),
                child: Text(
                  diagnostic,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            header,
            Expanded(
              child: ListView.separated(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.fromLTRB(10, 4, 10, 18),
                itemCount: threads.length + (_loadingMore ? 1 : 0),
                separatorBuilder: (_, _) =>
                    const Divider(height: 1, indent: 52),
                itemBuilder: (context, index) {
                  if (index == threads.length) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 14),
                      child: Center(
                        child: SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    );
                  }
                  return _ThreadRow(
                    threads[index],
                    onTap: () => onOpen(threads[index]),
                  );
                },
              ),
            ),
          ],
        ),
      );
    }

    if (hostConnected &&
        (loading || connectionState.phase == ConnectionPhase.connecting)) {
      return Column(
        children: [
          header,
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(strokeWidth: 2),
                  const SizedBox(height: 12),
                  Text(connectionState.message),
                ],
              ),
            ),
          ),
        ],
      );
    }

    final failed = connectionState.phase == ConnectionPhase.failed;
    final message = switch ((hostConnected, failed, query.trim().isNotEmpty)) {
      (false, _, _) => 'SSH 尚未连接',
      (_, true, _) => connectionState.message,
      (_, _, true) => '没有匹配任务',
      _ => '暂无任务',
    };
    return Column(
      children: [
        header,
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    failed ? Icons.error_outline : Icons.terminal,
                    size: 30,
                    color: failed
                        ? Theme.of(context).colorScheme.error
                        : codexMuted,
                  ),
                  const SizedBox(height: 9),
                  Text(message, textAlign: TextAlign.center),
                  if ((!hostConnected && onReconnect != null) ||
                      (failed && hostConnected)) ...[
                    const SizedBox(height: 12),
                    IconButton.filledTonal(
                      tooltip: hostConnected
                          ? '重新连接 ${agent.label}'
                          : '重新连接服务器',
                      onPressed: hostConnected ? onRetry : onReconnect,
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ThreadRow extends StatelessWidget {
  const _ThreadRow(this.thread, {required this.onTap});

  final AgentThread thread;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final running = isAgentThreadRunning(thread);
    final updatedAt = _updatedAtLabel(thread.updatedAt);
    return Column(
      children: [
        Material(
          color: running ? codexRaised : Colors.transparent,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: Center(
                      child: running
                          ? const SizedBox.square(
                              dimension: 17,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: codexGreen,
                              ),
                            )
                          : const Icon(
                              Icons.terminal,
                              size: 17,
                              color: codexMuted,
                            ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: Text(
                                thread.title.trim().isEmpty
                                    ? '未命名任务'
                                    : thread.title.trim(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodyLarge
                                    ?.copyWith(
                                      fontWeight: running
                                          ? FontWeight.w500
                                          : FontWeight.normal,
                                    ),
                              ),
                            ),
                            if (updatedAt != null) ...[
                              const SizedBox(width: 10),
                              Text(
                                updatedAt,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ],
                        ),
                        if (thread.preview.trim().isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            thread.preview.trim(),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                        const SizedBox(height: 6),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.folder_open,
                              size: 14,
                              color: codexMuted,
                            ),
                            const SizedBox(width: 5),
                            Expanded(
                              child: Text(
                                thread.cwd.trim().isEmpty
                                    ? '未指定目录'
                                    : thread.cwd.trim(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(fontFamily: 'monospace'),
                              ),
                            ),
                            if (thread.source.trim().isNotEmpty) ...[
                              const SizedBox(width: 8),
                              const Icon(
                                Icons.code,
                                size: 13,
                                color: codexMuted,
                              ),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  thread.source.trim(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const Divider(height: 1, indent: 46),
      ],
    );
  }
}

List<AgentThread> visibleAgentThreads(
  List<AgentThread> threads,
  String query, {
  required bool agentConnected,
}) {
  if (!agentConnected) return const <AgentThread>[];
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

bool isAgentThreadRunning(AgentThread thread) {
  if (thread.activeTurnId?.isNotEmpty ?? false) return true;
  return switch (thread.status.toLowerCase()) {
    'active' || 'running' || 'working' || 'inprogress' || 'in_progress' => true,
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
