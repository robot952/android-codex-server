import 'dart:async';
import 'dart:typed_data';

import 'package:codex_remote/src/app/app_controller.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/persistence/profile_store.dart';
import 'package:codex_remote/src/ssh/server_connection_manager.dart';
import 'package:codex_remote/src/ssh/terminal_manager.dart';
import 'package:codex_remote/src/ui/terminal_screen.dart';
import 'package:codex_remote/src/ui/theme.dart';
import 'package:flutter/material.dart';
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
  _ConnectedTerminalManager(super.connections);

  @override
  TerminalSessionState? stateFor(String profileId) => TerminalSessionState(
    profileId: profileId,
    profileName: 'n100',
    endpoint: 'root@tx.asdb.top:22',
    phase: TerminalPhase.connected,
    message: 'SSH 终端已连接',
    generation: 1,
  );

  @override
  List<Uint8List> historyFor(String profileId, int generation) =>
      const <Uint8List>[];

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
