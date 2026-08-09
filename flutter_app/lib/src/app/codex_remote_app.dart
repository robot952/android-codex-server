import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/models.dart';
import '../domain/models.dart' as domain;
import '../platform/app_update_manager.dart';
import '../platform/background_connection_bridge.dart';
import '../platform/turn_completion_notifications.dart';
import '../ui/agent_settings_dialog.dart';
import '../ui/file_manager_screen.dart';
import '../ui/remote_setup_dialog.dart';
import '../ui/server_screen.dart';
import '../ui/thread_list_screen.dart';
import '../ui/theme.dart';
import '../ui/terminal_screen.dart';
import '../ui/work_screen.dart';
import '../ui/workspace_picker_dialog.dart';
import 'app_controller.dart';

class CodexRemoteApp extends ConsumerWidget {
  const CodexRemoteApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'Agent',
      debugShowCheckedModeBanner: false,
      theme: buildCodexTheme(),
      home: const _AppRoot(),
    );
  }
}

class _AppRoot extends ConsumerStatefulWidget {
  const _AppRoot();

  @override
  ConsumerState<_AppRoot> createState() => _AppRootState();
}

class _AppRootState extends ConsumerState<_AppRoot>
    with WidgetsBindingObserver {
  _AppNavigationTarget _previousTarget = const _AppNavigationTarget(
    AppScreen.servers,
    null,
    false,
  );
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;
  Timer? _metricsTimer;
  String? _metricsPollingKey;
  StreamSubscription<TurnCompletion>? _completionSubscription;
  StreamSubscription<CompletedThreadNavigation>? _navigationSubscription;
  bool _backgroundProtectionEnabled = false;
  bool _notificationPermissionRequested = false;
  String? _setupProxyKey;
  String _setupProxyDraft = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lifecycleState =
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
    final controller = ref.read(appControllerProvider.notifier);
    _completionSubscription = controller.turnCompletions.listen(
      _handleTurnCompletion,
    );
    _navigationSubscription = turnCompletionNotifier.navigationEvents.listen(
      _handleCompletedThreadNavigation,
    );
    unawaited(turnCompletionNotifier.initialize());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    _syncMetricsPolling(ref.read(appControllerProvider));
    if (state == AppLifecycleState.resumed) {
      unawaited(ref.read(appUpdateProvider.notifier).refreshAfterResume());
    }
  }

  @override
  void dispose() {
    _metricsTimer?.cancel();
    unawaited(_completionSubscription?.cancel());
    unawaited(_navigationSubscription?.cancel());
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String?>(appControllerProvider.select((value) => value.error), (
      previous,
      next,
    ) {
      if (next == null || next == previous) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(next)));
        ref.read(appControllerProvider.notifier).clearError();
      });
    });
    final state = ref.watch(appControllerProvider);
    _syncMetricsPolling(state);
    _syncBackgroundProtection(state);
    final target = _pageFor(state.screen);
    final navigationTarget = _AppNavigationTarget.fromState(state);
    if (_previousTarget.animationKey != navigationTarget.animationKey) {
      ref
          .read(appControllerProvider.notifier)
          .diagnosticLogger
          .info(
            'Navigation',
            'screen=${navigationTarget.screen.name} '
                'profile=${state.selectedProfileId ?? 'none'} '
                'thread=${navigationTarget.threadId ?? 'none'}',
          );
    }
    final forward = _movesForward(_previousTarget, navigationTarget);
    _previousTarget = navigationTarget;
    _syncSetupProxyDraft(state);

    if (state.loading && state.profiles.isEmpty) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return PopScope(
      canPop:
          state.remoteSetup == null &&
          !state.agentSettingsVisible &&
          !state.workspacePickerVisible &&
          state.screen == AppScreen.servers,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final controller = ref.read(appControllerProvider.notifier);
        if (state.remoteSetup != null) {
          if (state.setupInProgress) {
            controller.minimizeRemoteSetup();
          } else {
            controller.cancelRemoteSetup();
          }
        } else if (state.agentSettingsVisible) {
          controller.dismissAgentSettings();
        } else if (state.workspacePickerVisible) {
          controller.dismissWorkspacePicker();
        } else {
          switch (state.screen) {
            case AppScreen.work:
              controller.backToThreadList();
            case AppScreen.agentWork:
              controller.backFromSubAgentThread();
            case AppScreen.fileManager:
              controller.closeFileManager();
            case AppScreen.terminal:
              controller.closeTerminal();
            case AppScreen.threads:
              controller.backToServers();
            case AppScreen.servers:
              break;
          }
        }
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 230),
            reverseDuration: const Duration(milliseconds: 190),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) {
              final offset = Tween<Offset>(
                begin: Offset(forward ? 0.08 : -0.08, 0),
                end: Offset.zero,
              ).animate(animation);
              return FadeTransition(
                opacity: animation,
                child: SlideTransition(position: offset, child: child),
              );
            },
            child: KeyedSubtree(
              key: ValueKey(navigationTarget.animationKey),
              child: target,
            ),
          ),
          if (state.workspacePickerVisible)
            WorkspacePickerDialog(
              state: state,
              onBrowse: ref
                  .read(appControllerProvider.notifier)
                  .browseWorkspace,
              onConfirm: ref
                  .read(appControllerProvider.notifier)
                  .confirmWorkspace,
              onDismiss: ref
                  .read(appControllerProvider.notifier)
                  .dismissWorkspacePicker,
            ),
          if (state.agentSettingsVisible)
            AgentSettingsDialog(
              state: state,
              onTest: ref
                  .read(appControllerProvider.notifier)
                  .testAgentSettings,
              onSave: ref
                  .read(appControllerProvider.notifier)
                  .saveAgentSettings,
              onDismiss: ref
                  .read(appControllerProvider.notifier)
                  .dismissAgentSettings,
            ),
          if (state.remoteSetup != null)
            RemoteSetupDialog(
              state: state,
              proxyUrl: _setupProxyDraft,
              onProxyChanged: (value) => _setupProxyDraft = value,
              onInstall: () => unawaited(
                ref
                    .read(appControllerProvider.notifier)
                    .installRemoteSetup(_setupProxyDraft),
              ),
              onCancel: ref
                  .read(appControllerProvider.notifier)
                  .cancelRemoteSetup,
              onMinimize: ref
                  .read(appControllerProvider.notifier)
                  .minimizeRemoteSetup,
            ),
        ],
      ),
    );
  }

  Widget _pageFor(AppScreen screen) => switch (screen) {
    AppScreen.servers => const ServerScreen(),
    AppScreen.threads => const ThreadListScreen(),
    AppScreen.work || AppScreen.agentWork => WorkScreen(
      onLoadRemoteImage: ref
          .read(appControllerProvider.notifier)
          .loadImagePreview,
    ),
    AppScreen.fileManager => const FileManagerScreen(),
    AppScreen.terminal => TerminalScreen(
      profileId: screen == AppScreen.terminal
          ? ref.read(appControllerProvider).selectedProfileId ?? ''
          : '',
    ),
  };

  int _rank(AppScreen screen) => switch (screen) {
    AppScreen.servers => 0,
    AppScreen.threads => 1,
    AppScreen.work => 2,
    AppScreen.agentWork => 3,
    AppScreen.fileManager => 2,
    AppScreen.terminal => 2,
  };

  bool _movesForward(_AppNavigationTarget previous, _AppNavigationTarget next) {
    final sameConversationSurface =
        (previous.screen == AppScreen.work ||
            previous.screen == AppScreen.agentWork) &&
        (next.screen == AppScreen.work || next.screen == AppScreen.agentWork);
    if (sameConversationSurface && previous.threadId != next.threadId) {
      return !next.subAgentBackNavigation;
    }
    return _rank(next.screen) >= _rank(previous.screen);
  }

  void _syncMetricsPolling(AppUiState state) {
    final visible =
        state.screen == AppScreen.servers || state.screen == AppScreen.threads;
    if (!visible || _lifecycleState != AppLifecycleState.resumed) {
      _stopMetricsPolling();
      return;
    }

    final connectedIds =
        state.connectionStates.entries
            .where((entry) => entry.value.phase == ConnectionPhase.connected)
            .map((entry) => entry.key)
            .toList()
          ..sort();
    final profileIds = state.screen == AppScreen.servers
        ? connectedIds
        : connectedIds.contains(state.selectedProfileId)
        ? <String>[state.selectedProfileId!]
        : const <String>[];
    final pollingKey = '${state.screen.name}:${profileIds.join(',')}';
    if (_metricsPollingKey == pollingKey) return;

    _stopMetricsPolling();
    _metricsPollingKey = pollingKey;
    if (profileIds.isEmpty) return;

    void refresh() {
      if (!mounted || _metricsPollingKey != pollingKey) return;
      final controller = ref.read(appControllerProvider.notifier);
      for (final profileId in profileIds) {
        unawaited(controller.refreshServerMetrics(profileId));
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => refresh());
    _metricsTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => refresh(),
    );
  }

  void _stopMetricsPolling() {
    _metricsTimer?.cancel();
    _metricsTimer = null;
    _metricsPollingKey = null;
  }

  void _handleTurnCompletion(TurnCompletion completion) {
    if (!mounted || _lifecycleState == AppLifecycleState.resumed) return;
    unawaited(turnCompletionNotifier.show(completion));
  }

  void _handleCompletedThreadNavigation(CompletedThreadNavigation navigation) {
    if (!mounted) return;
    unawaited(
      turnCompletionNotifier.cancel(
        navigation.profileId,
        navigation.agent,
        navigation.threadId,
      ),
    );
    unawaited(
      ref
          .read(appControllerProvider.notifier)
          .openCompletedThread(
            navigation.profileId,
            navigation.agent,
            navigation.threadId,
          ),
    );
  }

  void _syncBackgroundProtection(AppUiState state) {
    final required =
        state.connectionStates.values.any(_keepsBackgroundConnection) ||
        state.agentConnectionStates.values.any(_keepsBackgroundConnection) ||
        state.running;
    if (required == _backgroundProtectionEnabled) return;
    _backgroundProtectionEnabled = required;
    unawaited(backgroundConnectionBridge.setEnabled(required));
    if (required && !_notificationPermissionRequested) {
      _notificationPermissionRequested = true;
      unawaited(turnCompletionNotifier.requestPermission());
    }
  }

  void _syncSetupProxyDraft(AppUiState state) {
    final prompt = state.remoteSetup;
    final profileId = state.selectedProfileId;
    if (prompt == null || profileId == null) {
      _setupProxyKey = null;
      _setupProxyDraft = '';
      return;
    }
    final key = '$profileId:${prompt.agent.name}';
    if (_setupProxyKey == key) return;
    _setupProxyKey = key;
    _setupProxyDraft = state.profiles
        .firstWhere(
          (profile) => profile.id == profileId,
          orElse: () => const ServerProfile(),
        )
        .proxyUrl;
  }
}

class _AppNavigationTarget {
  const _AppNavigationTarget(
    this.screen,
    this.threadId,
    this.subAgentBackNavigation,
  );

  factory _AppNavigationTarget.fromState(AppUiState state) {
    final conversation =
        state.screen == AppScreen.work || state.screen == AppScreen.agentWork;
    return _AppNavigationTarget(
      state.screen,
      conversation ? state.activeThread?.id : null,
      state.subAgentBackNavigation,
    );
  }

  final AppScreen screen;
  final String? threadId;
  final bool subAgentBackNavigation;

  String get animationKey => '${screen.name}:${threadId ?? ''}';
}

bool _keepsBackgroundConnection(domain.ConnectionState state) =>
    switch (state.phase) {
      ConnectionPhase.connecting ||
      ConnectionPhase.installing ||
      ConnectionPhase.connected => true,
      ConnectionPhase.disconnected ||
      ConnectionPhase.probing ||
      ConnectionPhase.failed => false,
    };
