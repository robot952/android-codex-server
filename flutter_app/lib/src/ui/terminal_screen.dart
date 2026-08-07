import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../app/app_controller.dart';
import '../ssh/terminal_manager.dart';

/// Interactive PTY view for one server. Hiding this page keeps the shell
/// alive; the close action explicitly tears down only this shell channel.
class TerminalScreen extends ConsumerStatefulWidget {
  const TerminalScreen({required this.profileId, super.key});

  final String profileId;

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen> {
  late final Terminal _terminal;
  late final TerminalManager _manager;
  StreamSubscription<TerminalOutputEvent>? _outputSubscription;
  int? _attachedGeneration;
  bool _attachScheduled = false;

  @override
  void initState() {
    super.initState();
    _manager = ref.read(terminalManagerProvider);
    _terminal = Terminal(maxLines: 5000);
    _terminal.onOutput = (value) {
      _manager.send(widget.profileId, Uint8List.fromList(utf8.encode(value)));
    };
    _terminal.onResize = (columns, rows, pixelWidth, pixelHeight) {
      _manager.resize(widget.profileId, columns, rows);
    };
    _outputSubscription = _manager.outputChanges.listen(_onOutput);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final state = ref.read(appControllerProvider);
      final profile = state.profiles
          .where((candidate) => candidate.id == widget.profileId)
          .firstOrNull;
      if (profile != null) _manager.open(profile);
    });
  }

  @override
  void dispose() {
    unawaited(_outputSubscription?.cancel() ?? Future<void>.value());
    super.dispose();
  }

  void _onOutput(TerminalOutputEvent event) {
    if (!mounted || event.profileId != widget.profileId) return;
    if (_attachedGeneration != event.generation) return;
    _terminal.write(utf8.decode(event.bytes, allowMalformed: true));
  }

  void _ensureAttached(TerminalSessionState? session) {
    if (session == null || session.phase != TerminalPhase.connected) return;
    if (_attachedGeneration == session.generation || _attachScheduled) return;
    _attachScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _attachScheduled = false;
      if (!mounted) return;
      final current = _manager.stateFor(widget.profileId);
      if (current == null ||
          current.phase != TerminalPhase.connected ||
          current.generation == _attachedGeneration) {
        return;
      }
      _terminal.buffer.clear();
      _terminal.setCursor(0, 0);
      _attachedGeneration = current.generation;
      for (final bytes in _manager.historyFor(
        widget.profileId,
        current.generation,
      )) {
        _terminal.write(utf8.decode(bytes, allowMalformed: true));
      }
      setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _manager,
      builder: (context, _) {
        final session = _manager.stateFor(widget.profileId);
        _ensureAttached(session);
        return Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            titleSpacing: 8,
            title: Row(
              children: [
                Icon(
                  Icons.terminal,
                  size: 20,
                  color: session?.phase == TerminalPhase.connected
                      ? Colors.greenAccent
                      : Colors.white54,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        session?.profileName ?? 'SSH 终端',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        session?.endpoint ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.white54,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: '隐藏终端',
                onPressed: () {
                  _manager.hide();
                  ref.read(appControllerProvider.notifier).closeTerminal();
                },
                icon: const Icon(Icons.keyboard_arrow_down),
              ),
              IconButton(
                tooltip: '关闭终端',
                onPressed: () => _confirmClose(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          body: SafeArea(top: false, child: _body(context, session)),
        );
      },
    );
  }

  Widget _body(BuildContext context, TerminalSessionState? session) {
    final phase = session?.phase ?? TerminalPhase.disconnected;
    if (phase == TerminalPhase.connected) {
      return TerminalView(
        _terminal,
        theme: TerminalThemes.whiteOnBlack,
        autofocus: true,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      );
    }
    final loading = phase == TerminalPhase.connecting;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading)
              const CircularProgressIndicator(strokeWidth: 2)
            else
              Icon(
                phase == TerminalPhase.failed
                    ? Icons.error_outline
                    : Icons.terminal,
                size: 34,
                color: phase == TerminalPhase.failed
                    ? Theme.of(context).colorScheme.error
                    : Colors.white54,
              ),
            const SizedBox(height: 14),
            Text(
              loading
                  ? '正在连接 SSH 终端'
                  : phase == TerminalPhase.failed
                  ? 'SSH 终端连接失败'
                  : 'SSH 终端已断开',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(color: Colors.white),
            ),
            if (session?.message case final message? when message.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 7),
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white60),
                ),
              ),
            if (!loading) ...[
              const SizedBox(height: 14),
              IconButton.filledTonal(
                tooltip: '重新连接',
                onPressed: () => _manager.retry(widget.profileId),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _confirmClose(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.terminal),
        title: const Text('关闭 SSH 终端？'),
        content: const Text('将断开当前命令行连接，Codex 会话不会受到影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('关闭并断开'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    _manager.closeProfile(widget.profileId);
    ref.read(appControllerProvider.notifier).closeTerminal();
  }
}
