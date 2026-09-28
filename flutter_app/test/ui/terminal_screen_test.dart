import 'dart:async';
import 'dart:convert';

import 'package:codex_remote/src/app/app_controller.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/persistence/profile_store.dart';
import 'package:codex_remote/src/ssh/server_connection_manager.dart';
import 'package:codex_remote/src/ssh/terminal_manager.dart';
import 'package:codex_remote/src/ui/terminal_screen.dart';
import 'package:codex_remote/src/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

class _PendingStore implements ProfileStore {
  final Completer<StoredProfiles> gate = Completer<StoredProfiles>();

  @override
  Future<StoredProfiles> load() => gate.future;

  @override
  Future<void> save(StoredProfiles value) async {}
}

class _TestController extends AppController {
  _TestController(super.store, super.connections);
}

class _ConnectedTerminalManager extends TerminalManager {
  _ConnectedTerminalManager(super.connections, {this.history = ''});

  final String history;
  final List<Uint8List> sent = [];
  TerminalPhase phase = TerminalPhase.connected;
  int generation = 1;

  void changePhase(TerminalPhase next) {
    phase = next;
    if (next == TerminalPhase.connected) generation++;
    notifyListeners();
  }

  @override
  TerminalSessionState? stateFor(String profileId) => TerminalSessionState(
    profileId: profileId,
    profileName: 'n100',
    endpoint: 'root@tx.asdb.top:22',
    phase: phase,
    message: 'SSH 终端已连接',
    generation: generation,
  );

  @override
  List<Uint8List> historyFor(String profileId, int generation) => [
    Uint8List.fromList(utf8.encode(history)),
  ];

  @override
  bool send(String profileId, Uint8List bytes) {
    sent.add(bytes);
    return true;
  }

  @override
  void open(profile) {}
}

void main() {
  test(
    'encodes terminal control and alt shortcuts like the legacy terminal',
    () {
      expect(
        encodeTerminalShortcut('c', control: true, alt: false),
        Uint8List.fromList(const <int>[3]),
      );
      expect(
        encodeTerminalShortcut('/', control: false, alt: true),
        Uint8List.fromList(const <int>[0x1b, 0x2f]),
      );
      expect(
        encodeTerminalShortcut('中', control: true, alt: false),
        Uint8List.fromList(const <int>[0xe4, 0xb8, 0xad]),
      );
    },
  );

  test('limits terminal input without splitting a UTF-8 code point', () {
    expect(
      limitTerminalInput('a中b', 4),
      Uint8List.fromList(const <int>[0x61, 0xe4, 0xb8, 0xad]),
    );
    expect(limitTerminalInput('中', 2), isEmpty);
  });

  testWidgets(
    'long press exposes readable selection, handles and explicit copy',
    (tester) async {
      final manager = await _pumpTerminal(tester, 'hello world\r\nsecond line');
      final clipboard = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final view = tester.widget<TerminalView>(find.byType(TerminalView));
      expect(view.theme.selection.a, inExclusiveRange(0, 1));
      await tester.longPressAt(_cellPoint(tester, 1, 0));
      await tester.pump();
      await tester.pump();
      final selection = view.controller!.selection;
      expect(selection, isNotNull);
      expect(view.terminal.buffer.getText(selection), 'hello');
      expect(
        find.byKey(const ValueKey('terminal-selection-toolbar')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('terminal-selection-start')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('terminal-selection-end')),
        findsOneWidget,
      );
      expect(clipboard, isEmpty);
      expect(manager.sent, isEmpty);
      await tester.tap(find.text('复制'));
      await tester.pump();
      await tester.pump();
      expect(clipboard, ['hello']);
      expect(view.controller!.selection, isNull);
      expect(
        find.byKey(const ValueKey('terminal-selection-toolbar')),
        findsNothing,
      );
      expect(manager.sent, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('selection handle extends across lines without terminal input', (
    tester,
  ) async {
    final manager = await _pumpTerminal(tester, 'hello world\r\nsecond line');
    await tester.longPressAt(_cellPoint(tester, 1, 0));
    await tester.pump();
    await tester.pump();
    final handle = find.byKey(const ValueKey('terminal-selection-end'));
    final drag = await tester.startGesture(tester.getCenter(handle));
    await drag.moveBy(_cellPoint(tester, 11, 1) - _cellPoint(tester, 5, 0));
    await tester.pump();
    await drag.up();
    await tester.pump();
    final view = tester.widget<TerminalView>(find.byType(TerminalView));
    expect(
      view.terminal.buffer.getText(view.controller!.selection),
      'hello world\nsecond line',
    );
    expect(manager.sent, isEmpty);
    await tester.tap(find.byTooltip('取消选择'));
    await tester.pump();
    await tester.pump();
    expect(view.controller!.selection, isNull);
    expect(
      find.byKey(const ValueKey('terminal-selection-toolbar')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'end handle includes the last terminal column at the viewport edge',
    (tester) async {
      await _pumpTerminal(tester, '');
      final view = tester.widget<TerminalView>(find.byType(TerminalView));
      final width = view.terminal.viewWidth;
      final text = 'head ${'A' * (width - 6)}Z';
      view.terminal.write(text);
      await tester.pump();
      await tester.longPressAt(_cellPoint(tester, 1, 0));
      await tester.pump();
      await tester.pump();
      final endHandle = find.byKey(const ValueKey('terminal-selection-end'));
      final drag = await tester.startGesture(tester.getCenter(endHandle));
      await drag.moveBy(
        _cellPoint(tester, width, 0) - _cellPoint(tester, 4, 0),
      );
      await tester.pump();
      await drag.up();
      await tester.pump();
      await tester.pump();
      expect(view.controller!.selection!.normalized.end.x, width);
      expect(view.terminal.buffer.getText(view.controller!.selection), text);
      final surface = tester.getRect(
        find.byKey(const ValueKey('terminal-pinch-surface')),
      );
      expect(tester.getRect(endHandle).right, lessThanOrEqualTo(surface.right));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('select all includes history and shortcut dismisses selection', (
    tester,
  ) async {
    final manager = await _pumpTerminal(tester, 'hello world\r\nsecond line');
    await tester.longPressAt(_cellPoint(tester, 1, 0));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('全选'));
    await tester.pump();
    final view = tester.widget<TerminalView>(find.byType(TerminalView));
    expect(
      view.terminal.buffer.getText(view.controller!.selection),
      'hello world\nsecond line',
    );
    await tester.tap(find.text('ESC'));
    await tester.pump();
    await tester.pump();
    expect(manager.sent.single, [0x1b]);
    expect(view.controller!.selection, isNull);
    expect(
      find.byKey(const ValueKey('terminal-selection-toolbar')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('copy button instructs long press without touching clipboard', (
    tester,
  ) async {
    await _pumpTerminal(tester, 'hello world');
    await tester.tap(find.byTooltip('选择并复制终端文字'));
    await tester.pump();
    expect(find.text('长按文字后拖动选择，再点击复制'), findsOneWidget);
    await tester.longPressAt(_cellPoint(tester, 7, 0));
    await tester.pump();
    await tester.pump();
    expect(find.text('复制'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('terminal-selection-end')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'selection stays within narrow keyboard viewport and cancels cleanly',
    (tester) async {
      await _pumpTerminal(tester, 'hello world\r\nsecond line');
      tester.view.physicalSize = const Size(320, 720);
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pump();
      await tester.longPressAt(_cellPoint(tester, 1, 0));
      await tester.pump();
      await tester.pump();
      final toolbar = find.byKey(const ValueKey('terminal-selection-toolbar'));
      final bounds = tester.getRect(toolbar);
      expect(bounds.left, greaterThanOrEqualTo(0));
      expect(bounds.right, lessThanOrEqualTo(320));
      expect(bounds.bottom, lessThan(440));
      // A first-line selection has no space above, so its menu is below the text.
      expect(bounds.top, greaterThan(_cellPoint(tester, 1, 0).dy));
      await tester.tap(find.byTooltip('取消选择'));
      await tester.pump();
      await tester.pump();
      expect(toolbar, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'scroll hides offscreen selection controls without deleting selection',
    (tester) async {
      await _pumpTerminal(
        tester,
        List.generate(100, (i) => 'line $i text').join('\r\n'),
      );
      final view = tester.widget<TerminalView>(find.byType(TerminalView));
      view.scrollController!.jumpTo(0);
      await tester.pump();
      await tester.longPressAt(_cellPoint(tester, 1, 2));
      await tester.pump();
      await tester.pump();
      final before = view.controller!.selection;
      expect(before, isNotNull);
      expect(
        find.byKey(const ValueKey('terminal-selection-toolbar')),
        findsOneWidget,
      );
      view.scrollController!.jumpTo(
        view.scrollController!.position.maxScrollExtent,
      );
      await tester.pump();
      await tester.pump();
      expect(view.controller!.selection, before);
      expect(
        find.byKey(const ValueKey('terminal-selection-toolbar')),
        findsNothing,
      );
      view.scrollController!.jumpTo(0);
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(const ValueKey('terminal-selection-toolbar')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('pinch dismisses old selection and preserves zoom behavior', (
    tester,
  ) async {
    await _pumpTerminal(tester, 'hello world');
    await tester.longPressAt(_cellPoint(tester, 1, 0));
    await tester.pump();
    await tester.pump();
    final center = tester.getCenter(
      find.byKey(const ValueKey('terminal-pinch-surface')),
    );
    final first = await tester.startGesture(
      center - const Offset(30, 0),
      pointer: 1,
    );
    final second = await tester.startGesture(
      center + const Offset(30, 0),
      pointer: 2,
    );
    await first.moveTo(center - const Offset(45, 0));
    await second.moveTo(center + const Offset(45, 0));
    await tester.pump();
    await first.up();
    await second.up();
    await tester.pump();
    await tester.pump();
    final view = tester.widget<TerminalView>(find.byType(TerminalView));
    expect(view.textStyle.fontSize, 21);
    expect(view.controller!.selection, isNull);
    expect(
      find.byKey(const ValueKey('terminal-selection-toolbar')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 350));
  });

  testWidgets('clipboard failure keeps selection available for retry', (
    tester,
  ) async {
    await _pumpTerminal(tester, 'hello world');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          throw PlatformException(code: 'unavailable');
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.longPressAt(_cellPoint(tester, 1, 0));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('复制'));
    await tester.pump();
    final view = tester.widget<TerminalView>(find.byType(TerminalView));
    expect(view.controller!.selection, isNotNull);
    expect(find.text('复制失败，请重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'left-edge handle stays tappable and disconnect clears selection',
    (tester) async {
      final manager = await _pumpTerminal(tester, 'hello world');
      await tester.longPressAt(_cellPoint(tester, 0, 0));
      await tester.pump();
      await tester.pump();
      final surface = tester.getRect(
        find.byKey(const ValueKey('terminal-pinch-surface')),
      );
      final startHandle = tester.getRect(
        find.byKey(const ValueKey('terminal-selection-start')),
      );
      expect(startHandle.left, greaterThanOrEqualTo(surface.left));
      expect(startHandle.width, greaterThanOrEqualTo(40));
      final view = tester.widget<TerminalView>(find.byType(TerminalView));
      manager.changePhase(TerminalPhase.disconnected);
      await tester.pump();
      await tester.pump();
      expect(view.controller!.selection, isNull);
      expect(
        find.byKey(const ValueKey('terminal-selection-toolbar')),
        findsNothing,
      );
      manager.changePhase(TerminalPhase.connected);
      await tester.pump();
      await tester.pump();
      expect(find.byTooltip('选择并复制终端文字'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('terminal-selection-toolbar')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('restores the legacy terminal toolbar and shortcut rows', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.reset);

    final connections = ServerConnectionManager();
    final manager = _ConnectedTerminalManager(connections);
    final controller = _TestController(_PendingStore(), connections);
    addTearDown(manager.close);
    addTearDown(connections.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appControllerProvider.overrideWith((ref) => controller),
          terminalManagerProvider.overrideWithValue(manager),
        ],
        child: MaterialApp(
          theme: buildCodexTheme(),
          home: const TerminalScreen(profileId: 'server'),
        ),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.content_copy), findsOneWidget);
    expect(find.byIcon(Icons.content_paste), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);
    expect(find.text('ESC'), findsOneWidget);
    expect(find.text('TAB'), findsOneWidget);
    expect(find.text('HOME'), findsOneWidget);
    expect(find.text('END'), findsOneWidget);
    expect(find.text('CTRL'), findsOneWidget);
    expect(find.text('ALT'), findsOneWidget);
    final up = tester.getCenter(find.byKey(const ValueKey('terminal-key-up')));
    final down = tester.getCenter(
      find.byKey(const ValueKey('terminal-key-down')),
    );
    final left = tester.getCenter(
      find.byKey(const ValueKey('terminal-key-left')),
    );
    final right = tester.getCenter(
      find.byKey(const ValueKey('terminal-key-right')),
    );
    expect(up.dx, closeTo(down.dx, 0.1));
    expect(up.dy, lessThan(down.dy));
    expect(left.dy, closeTo(down.dy, 0.1));
    expect(right.dy, closeTo(down.dy, 0.1));
    expect(left.dx, lessThan(down.dx));
    expect(right.dx, greaterThan(down.dx));
    final esc = tester.getCenter(find.text('ESC'));
    final control = tester.getCenter(find.text('CTRL'));
    expect(esc.dy, closeTo(up.dy, 0.1));
    expect(control.dy, closeTo(down.dy, 0.1));
    final directionSize = tester.getSize(
      find.byKey(const ValueKey('terminal-key-down')),
    );
    expect(directionSize.width, greaterThanOrEqualTo(44));
    expect(directionSize.height, greaterThanOrEqualTo(36));
    var terminalView = tester.widget<TerminalView>(find.byType(TerminalView));
    expect(terminalView.theme.background, Colors.black);
    expect(terminalView.theme.foreground, const Color(0xFF00FF00));
    expect(terminalView.theme.cursor, const Color(0xFF00FF00));

    final pinchSurface = find.byKey(const ValueKey('terminal-pinch-surface'));
    final center = tester.getCenter(pinchSurface);
    final firstFinger = await tester.startGesture(
      center - const Offset(20, 0),
      pointer: 1,
    );
    final secondFinger = await tester.startGesture(
      center + const Offset(20, 0),
      pointer: 2,
    );
    await firstFinger.moveTo(center - const Offset(40, 0));
    await secondFinger.moveTo(center + const Offset(40, 0));
    await tester.pump();

    terminalView = tester.widget<TerminalView>(find.byType(TerminalView));
    expect(terminalView.textStyle.fontSize, 28);
    expect(
      find.byKey(const ValueKey('terminal-font-size-indicator')),
      findsOneWidget,
    );

    await firstFinger.up();
    await secondFinger.up();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('terminal-font-size-indicator')),
      findsNothing,
    );

    final thirdFinger = await tester.startGesture(
      center - const Offset(40, 0),
      pointer: 3,
    );
    final fourthFinger = await tester.startGesture(
      center + const Offset(40, 0),
      pointer: 4,
    );
    await thirdFinger.moveTo(center - const Offset(5, 0));
    await fourthFinger.moveTo(center + const Offset(5, 0));
    await tester.pump();

    terminalView = tester.widget<TerminalView>(find.byType(TerminalView));
    expect(terminalView.textStyle.fontSize, 8);
    await thirdFinger.up();
    await fourthFinger.up();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}

Future<_ConnectedTerminalManager> _pumpTerminal(
  WidgetTester tester,
  String history, {
  bool controlledViewport = true,
}) async {
  if (controlledViewport) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.reset);
  }
  final connections = ServerConnectionManager();
  final manager = _ConnectedTerminalManager(connections, history: history);
  final controller = _TestController(_PendingStore(), connections);
  addTearDown(manager.close);
  addTearDown(connections.close);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appControllerProvider.overrideWith((ref) => controller),
        terminalManagerProvider.overrideWithValue(manager),
      ],
      child: MaterialApp(
        theme: buildCodexTheme(),
        home: const TerminalScreen(profileId: 'server'),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return manager;
}

Future<List<Uint8List>> pumpTerminalSelectionFixture(
  WidgetTester tester,
) async {
  final manager = await _pumpTerminal(
    tester,
    'terminal selection test\r\nhello world\r\nsecond line\r\nroot@fixture:~# ',
    controlledViewport: false,
  );
  return manager.sent;
}

Offset _cellPoint(WidgetTester tester, int column, int row) {
  final render = tester
      .state<TerminalViewState>(find.byType(TerminalView))
      .renderTerminal;
  return render.localToGlobal(
    render.getOffset(CellOffset(column, row)) +
        Offset(render.cellSize.width / 2, render.lineHeight / 2),
  );
}
