import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/models.dart';
import '../ui/server_screen.dart';
import '../ui/thread_list_screen.dart';
import '../ui/theme.dart';
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

class _AppRootState extends ConsumerState<_AppRoot> {
  AppScreen _previousScreen = AppScreen.servers;

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
    final target = _pageFor(state.screen);
    final forward = _rank(state.screen) >= _rank(_previousScreen);
    _previousScreen = state.screen;

    if (state.loading && state.profiles.isEmpty) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return PopScope(
      canPop: state.screen == AppScreen.servers,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && state.screen != AppScreen.servers) {
          ref.read(appControllerProvider.notifier).backToServers();
        }
      },
      child: AnimatedSwitcher(
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
        child: KeyedSubtree(key: ValueKey(state.screen), child: target),
      ),
    );
  }

  Widget _pageFor(AppScreen screen) => switch (screen) {
    AppScreen.servers => const ServerScreen(),
    AppScreen.threads => const ThreadListScreen(),
    _ => const ThreadListScreen(),
  };

  int _rank(AppScreen screen) => switch (screen) {
    AppScreen.servers => 0,
    AppScreen.threads => 1,
    AppScreen.work => 2,
    AppScreen.agentWork => 3,
    AppScreen.fileManager => 2,
  };
}
