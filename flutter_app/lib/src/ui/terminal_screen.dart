import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../app/app_controller.dart';
import '../ssh/terminal_manager.dart';
import 'theme.dart';

/// Interactive PTY view for one server. Hiding this page keeps the shell
/// alive; the close action explicitly tears down only this shell channel.
class TerminalScreen extends ConsumerStatefulWidget {
  const TerminalScreen({required this.profileId, super.key});

  final String profileId;

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen> {
  static const _defaultFontSize = 14.0;
  static const _minimumFontSize = 8.0;
  static const _maximumFontSize = 28.0;

  late final Terminal _terminal;
  late final TerminalController _terminalController;
  late final FocusNode _terminalFocus;
  late final TerminalManager _manager;
  StreamSubscription<TerminalOutputEvent>? _outputSubscription;
  int? _attachedGeneration;
  bool _attachScheduled = false;
  bool _controlEnabled = false;
  bool _altEnabled = false;
  bool _copyMode = false;
  bool _copyModeHadSelection = false;
  double _terminalFontSize = _defaultFontSize;
  final Map<int, Offset> _terminalTouchPoints = <int, Offset>{};
  double? _pinchStartDistance;
  double? _pinchStartFontSize;

  @override
  void initState() {
    super.initState();
    _manager = ref.read(terminalManagerProvider);
    _terminal = Terminal(maxLines: 5000);
    _terminalController = TerminalController();
    _terminalController.addListener(_copySelectionWhenReady);
    _terminalFocus = FocusNode();
    _terminal.onOutput = _sendTerminalInput;
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
    _terminalController.removeListener(_copySelectionWhenReady);
    _terminalController.dispose();
    _terminalFocus.dispose();
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
            toolbarHeight: 64,
            backgroundColor: const Color(0xFF151515),
            titleSpacing: 12,
            title: Row(
              children: [
                Icon(
                  Icons.terminal,
                  size: 21,
                  color: session?.phase == TerminalPhase.connected
                      ? codexGreen
                      : Colors.white54,
                ),
                const SizedBox(width: 10),
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
              if (session?.phase == TerminalPhase.connected) ...[
                IconButton(
                  tooltip: '复制终端文字',
                  onPressed: _copySelection,
                  icon: const Icon(Icons.content_copy),
                ),
                IconButton(
                  tooltip: '粘贴到终端',
                  onPressed: _pasteClipboard,
                  icon: const Icon(Icons.content_paste),
                ),
              ],
              IconButton(
                tooltip: '隐藏终端',
                onPressed: _hideTerminal,
                icon: const Icon(Icons.keyboard_arrow_down),
              ),
              IconButton(
                tooltip: '关闭终端',
                onPressed: () => _confirmClose(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          body: SafeArea(
            top: false,
            child: Column(
              children: [
                Expanded(child: _body(context, session)),
                if (session?.phase == TerminalPhase.connected)
                  _TerminalKeyBar(
                    controlEnabled: _controlEnabled,
                    altEnabled: _altEnabled,
                    onToggleControl: () => setState(() {
                      _controlEnabled = !_controlEnabled;
                    }),
                    onToggleAlt: () => setState(() {
                      _altEnabled = !_altEnabled;
                    }),
                    onSend: _sendShortcut,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _body(BuildContext context, TerminalSessionState? session) {
    final phase = session?.phase ?? TerminalPhase.disconnected;
    if (phase == TerminalPhase.connected) {
      return Stack(
        children: [
          Positioned.fill(
            child: Listener(
              key: const ValueKey('terminal-pinch-surface'),
              onPointerDown: _onTerminalPointerDown,
              onPointerMove: _onTerminalPointerMove,
              onPointerUp: _onTerminalPointerEnd,
              onPointerCancel: _onTerminalPointerEnd,
              child: TerminalView(
                _terminal,
                controller: _terminalController,
                focusNode: _terminalFocus,
                theme: _legacyTerminalTheme,
                textStyle: TerminalStyle(
                  fontSize: _terminalFontSize,
                  height: 1.2,
                ),
                autofocus: true,
                padding: const EdgeInsets.fromLTRB(4, 4, 3, 2),
              ),
            ),
          ),
          if (_pinchStartDistance != null)
            Positioned(
              top: 12,
              right: 12,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xDD202020),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 5,
                    ),
                    child: Text(
                      '${_terminalFontSize.round()} pt',
                      key: const ValueKey('terminal-font-size-indicator'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
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

  void _onTerminalPointerDown(PointerDownEvent event) {
    _terminalTouchPoints[event.pointer] = event.localPosition;
    if (_terminalTouchPoints.length != 2) return;
    _pinchStartDistance = _terminalTouchDistance();
    _pinchStartFontSize = _terminalFontSize;
    setState(() {});
  }

  void _onTerminalPointerMove(PointerMoveEvent event) {
    if (!_terminalTouchPoints.containsKey(event.pointer)) return;
    _terminalTouchPoints[event.pointer] = event.localPosition;
    final startDistance = _pinchStartDistance;
    final startFontSize = _pinchStartFontSize;
    if (_terminalTouchPoints.length != 2 ||
        startDistance == null ||
        startFontSize == null ||
        startDistance <= 0) {
      return;
    }
    final nextFontSize =
        (startFontSize * (_terminalTouchDistance() / startDistance))
            .clamp(_minimumFontSize, _maximumFontSize)
            .toDouble();
    if ((nextFontSize - _terminalFontSize).abs() < 0.05) return;
    setState(() => _terminalFontSize = nextFontSize);
  }

  void _onTerminalPointerEnd(PointerEvent event) {
    _terminalTouchPoints.remove(event.pointer);
    if (_pinchStartDistance == null) return;
    setState(() {
      _pinchStartDistance = null;
      _pinchStartFontSize = null;
    });
  }

  double _terminalTouchDistance() {
    final points = _terminalTouchPoints.values.take(2).toList();
    return (points[0] - points[1]).distance;
  }

  void _hideTerminal() {
    _terminalFocus.unfocus();
    _manager.hide();
    ref.read(appControllerProvider.notifier).closeTerminal();
  }

  void _sendBytes(Uint8List bytes) {
    if (bytes.isEmpty) return;
    if (_manager.send(widget.profileId, bytes)) return;
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('终端输入队列已满，请稍后重试')));
  }

  void _sendShortcut(String value) {
    _sendTerminalInput(value);
    _terminalFocus.requestFocus();
  }

  void _sendTerminalInput(String value) {
    final bytes = encodeTerminalShortcut(
      value,
      control: _controlEnabled,
      alt: _altEnabled,
    );
    if (_controlEnabled || _altEnabled) {
      setState(() {
        _controlEnabled = false;
        _altEnabled = false;
      });
    }
    _sendBytes(bytes);
  }

  Future<void> _copySelection() async {
    final selection = _terminalController.selection;
    if (selection == null) {
      _copyMode = true;
      _copyModeHadSelection = false;
      _terminalFocus.unfocus();
      return;
    }
    _copyMode = false;
    _copyModeHadSelection = false;
    await _writeSelectionToClipboard(selection);
  }

  void _copySelectionWhenReady() {
    if (!_copyMode) return;
    final selection = _terminalController.selection;
    if (selection == null) {
      if (_copyModeHadSelection) {
        _copyMode = false;
        _copyModeHadSelection = false;
      }
      return;
    }
    _copyModeHadSelection = true;
    unawaited(_writeSelectionToClipboard(selection, clearSelection: false));
  }

  Future<void> _writeSelectionToClipboard(
    BufferRange selection, {
    bool clearSelection = true,
  }) async {
    final value = _terminal.buffer.getText(selection);
    if (value.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: value));
    if (clearSelection) _terminalController.clearSelection();
  }

  Future<void> _pasteClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted || data?.text == null || data!.text!.isEmpty) return;
    final value = data.text!;
    final bytes = limitTerminalInput(value, TerminalManager.maxInputBytes);
    if (bytes.length < utf8.encode(value).length) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('粘贴内容过大，已限制为 512 KiB')));
    }
    _sendBytes(bytes);
    _terminalFocus.requestFocus();
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
    _terminalFocus.unfocus();
    _manager.closeProfile(widget.profileId);
    ref.read(appControllerProvider.notifier).closeTerminal();
  }
}

class _TerminalKeyBar extends StatelessWidget {
  const _TerminalKeyBar({
    required this.controlEnabled,
    required this.altEnabled,
    required this.onToggleControl,
    required this.onToggleAlt,
    required this.onSend,
  });

  final bool controlEnabled;
  final bool altEnabled;
  final VoidCallback onToggleControl;
  final VoidCallback onToggleAlt;
  final ValueChanged<String> onSend;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF171717),
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 38,
              child: Row(
                children: [
                  for (
                    var index = 0;
                    index < _terminalKeyRowOne.length;
                    index++
                  ) ...[
                    if (index > 0) const SizedBox(width: 3),
                    _shortcutKey(_terminalKeyRowOne[index], index),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 3),
            SizedBox(
              height: 38,
              child: Row(
                children: [
                  _TerminalKey(
                    label: 'CTRL',
                    active: controlEnabled,
                    flex: _terminalKeyFlexes[0],
                    onPressed: onToggleControl,
                  ),
                  const SizedBox(width: 3),
                  _TerminalKey(
                    label: 'ALT',
                    active: altEnabled,
                    flex: _terminalKeyFlexes[1],
                    onPressed: onToggleAlt,
                  ),
                  for (
                    var index = 0;
                    index < _terminalKeyRowTwo.length;
                    index++
                  ) ...[
                    const SizedBox(width: 3),
                    _shortcutKey(_terminalKeyRowTwo[index], index + 2),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _shortcutKey(_TerminalKeySpec key, int column) {
    return _TerminalKey(
      key: key.name.isEmpty ? null : ValueKey('terminal-key-${key.name}'),
      label: key.label,
      flex: _terminalKeyFlexes[column],
      fontSize: key.name.isEmpty ? 12 : 20,
      onPressed: () => onSend(key.sequence),
    );
  }
}

class _TerminalKey extends StatelessWidget {
  const _TerminalKey({
    required this.label,
    required this.onPressed,
    this.active = false,
    this.fontSize = 12,
    this.flex = 10,
    super.key,
  });

  final String label;
  final VoidCallback onPressed;
  final bool active;
  final double fontSize;
  final int flex;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: flex,
      child: SizedBox.expand(
        child: Material(
          color: active ? const Color(0xFF315D35) : const Color(0xFF292929),
          borderRadius: BorderRadius.circular(4),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: Center(
              child: Text(
                label,
                maxLines: 1,
                style: TextStyle(
                  color: const Color(0xFFD0D0D0),
                  fontSize: fontSize,
                  letterSpacing: 0,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

@visibleForTesting
Uint8List encodeTerminalShortcut(
  String value, {
  required bool control,
  required bool alt,
}) {
  var payload = Uint8List.fromList(utf8.encode(value));
  if (control && value.runes.length == 1) {
    final codePoint = value.toUpperCase().runes.single;
    if (codePoint >= 0x40 && codePoint <= 0x5f) {
      payload = Uint8List.fromList(<int>[codePoint & 0x1f]);
    }
  }
  return alt ? Uint8List.fromList(<int>[0x1b, ...payload]) : payload;
}

@visibleForTesting
Uint8List limitTerminalInput(String value, int maxBytes) {
  final safeLimit = maxBytes.clamp(0, TerminalManager.maxInputBytes);
  final result = BytesBuilder(copy: false);
  var used = 0;
  for (final rune in value.runes) {
    final bytes = utf8.encode(String.fromCharCode(rune));
    if (used + bytes.length > safeLimit) break;
    result.add(bytes);
    used += bytes.length;
  }
  return result.takeBytes();
}

class _TerminalKeySpec {
  const _TerminalKeySpec(this.label, this.sequence, {this.name = ''});

  final String label;
  final String sequence;
  final String name;
}

const _terminalKeyRowOne = <_TerminalKeySpec>[
  _TerminalKeySpec('ESC', '\u001b'),
  _TerminalKeySpec('TAB', '\t'),
  _TerminalKeySpec('HOME', '\u001b[1~'),
  _terminalUp,
  _TerminalKeySpec('END', '\u001b[4~'),
  _TerminalKeySpec('/', '/'),
  _TerminalKeySpec('|', '|'),
  _TerminalKeySpec('-', '-'),
];

const _terminalUp = _TerminalKeySpec('\u2191', '\u001b[A', name: 'up');
const _terminalDown = _TerminalKeySpec('\u2193', '\u001b[B', name: 'down');
const _terminalLeft = _TerminalKeySpec('\u2190', '\u001b[D', name: 'left');
const _terminalRight = _TerminalKeySpec('\u2192', '\u001b[C', name: 'right');

const _terminalKeyRowTwo = <_TerminalKeySpec>[
  _terminalLeft,
  _terminalDown,
  _terminalRight,
  _TerminalKeySpec('~', '~'),
  _TerminalKeySpec(':', ':'),
  _TerminalKeySpec('_', '_'),
];

const _terminalKeyFlexes = <int>[10, 10, 11, 11, 11, 10, 10, 10];

const _legacyTerminalTheme = TerminalTheme(
  cursor: Color(0xFF00FF00),
  selection: Color(0xFF2F5F2F),
  foreground: Color(0xFF00FF00),
  background: Color(0xFF000000),
  black: Color(0xFF000000),
  red: Color(0xFFCD3131),
  green: Color(0xFF0DBC79),
  yellow: Color(0xFFE5E510),
  blue: Color(0xFF2472C8),
  magenta: Color(0xFFBC3FBC),
  cyan: Color(0xFF11A8CD),
  white: Color(0xFFE5E5E5),
  brightBlack: Color(0xFF666666),
  brightRed: Color(0xFFF14C4C),
  brightGreen: Color(0xFF23D18B),
  brightYellow: Color(0xFFF5F543),
  brightBlue: Color(0xFF3B8EEA),
  brightMagenta: Color(0xFFD670D6),
  brightCyan: Color(0xFF29B8DB),
  brightWhite: Color(0xFFFFFFFF),
  searchHitBackground: Color(0xFFFFFF2B),
  searchHitBackgroundCurrent: Color(0xFF31FF26),
  searchHitForeground: Color(0xFF000000),
);
