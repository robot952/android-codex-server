import 'package:codex_remote/src/app/app_controller.dart';
import 'package:codex_remote/src/app/codex_remote_app.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/persistence/profile_store.dart';
import 'package:codex_remote/src/platform/local_linux_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryStore implements ProfileStore {
  _MemoryStore(this.value);
  StoredProfiles value;
  @override
  Future<StoredProfiles> load() async => value;
  @override
  Future<void> save(StoredProfiles value) async => this.value = value;
}

List<ServerProfile> _servers(int count) => List.generate(
  count,
  (i) =>
      ServerProfile(id: 'server-$i', name: '服务器 $i', host: 'host-$i.example'),
);

Future<void> _pumpServers(WidgetTester tester, _MemoryStore store) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(444, 900);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [profileStoreProvider.overrideWithValue(store)],
      child: const CodexRemoteApp(),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _move(WidgetTester tester, String name, Offset destination) async {
  final start = tester.getCenter(find.text(name));
  final gesture = await tester.startGesture(start);
  await tester.pump(const Duration(milliseconds: 600));
  for (var step = 1; step <= 12; step++) {
    await gesture.moveTo(Offset.lerp(start, destination, step / 12)!);
    await tester.pump(const Duration(milliseconds: 40));
  }
  await tester.pump(const Duration(milliseconds: 300));
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('long press moves servers both ways and survives a restart', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final servers = _servers(3);
    final local = localLinuxProfile(
      const LocalLinuxInstance(
        port: 41234,
        password: 'fixture',
        architecture: 'arm64-v8a',
        rootfsVersion: 'test',
      ),
    );
    final store = _MemoryStore(
      StoredProfiles(
        profiles: [servers[0], local, ...servers.skip(1)],
        selectedProfileId: servers[0].id,
      ),
    );
    await _pumpServers(tester, store);
    final localPosition = tester.getTopLeft(
      find.byKey(const ValueKey('local-linux-panel')),
    );
    await _move(
      tester,
      '服务器 2',
      tester.getCenter(find.text('服务器 0')) + const Offset(0, 4),
    );
    expect(store.value.profiles.map((p) => p.id), [
      'server-2',
      local.id,
      'server-0',
      'server-1',
    ]);
    expect(
      tester.getTopLeft(find.text('服务器 2')).dy,
      lessThan(tester.getTopLeft(find.text('服务器 0')).dy),
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('local-linux-panel'))),
      localPosition,
    );
    expect(find.text('连接服务器？'), findsNothing);
    expect(store.value.selectedProfileId, 'server-0');

    await _move(
      tester,
      '服务器 2',
      tester.getBottomLeft(find.byKey(const ValueKey('server-row-server-1'))) +
          const Offset(80, 50),
    );
    expect(store.value.profiles.map((p) => p.id), [
      'server-0',
      local.id,
      'server-1',
      'server-2',
    ]);
    await _move(
      tester,
      '服务器 1',
      tester.getCenter(find.text('服务器 0')) + const Offset(0, 4),
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await _pumpServers(tester, store);
    expect(store.value.profiles.map((p) => p.id), [
      'server-1',
      local.id,
      'server-0',
      'server-2',
    ]);
    expect(
      tester.getTopLeft(find.text('服务器 1')).dy,
      lessThan(tester.getTopLeft(find.text('服务器 0')).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('ordinary scrolling and taps do not reorder servers', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final servers = _servers(15);
    final store = _MemoryStore(StoredProfiles(profiles: servers));
    await _pumpServers(tester, store);
    await tester.drag(find.text('服务器 2'), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(store.value.profiles.map((p) => p.id), servers.map((p) => p.id));
    expect(find.text('连接服务器？'), findsNothing);
    await tester.tap(find.text('服务器 3'));
    await tester.pumpAndSettle();
    expect(find.text('连接服务器？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('server-row-server-3'));
    await tester.tap(
      find.descendant(of: row, matching: find.byIcon(Icons.settings)),
    );
    await tester.pumpAndSettle();
    expect(find.text('服务器设置'), findsOneWidget);
    expect(store.value.profiles.map((p) => p.id), servers.map((p) => p.id));
    expect(tester.takeException(), isNull);
  });

  testWidgets('dragging at the viewport edge scrolls the whole server list', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final store = _MemoryStore(StoredProfiles(profiles: _servers(18)));
    await _pumpServers(tester, store);
    final scroll = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const ValueKey('server-list-scroll')),
        matching: find.byType(Scrollable),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('服务器 0')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(const Offset(160, 890));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(scroll.position.pixels, greaterThan(200));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      store.value.profiles.indexWhere((p) => p.id == 'server-0'),
      greaterThan(3),
    );
    expect(store.value.profiles.map((p) => p.id).toSet(), hasLength(18));
    expect(find.text('连接服务器？'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
