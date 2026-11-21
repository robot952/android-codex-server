import 'dart:async';

import 'package:codex_remote/src/app/app_controller.dart';
import 'package:codex_remote/src/app/codex_remote_app.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/persistence/profile_store.dart';
import 'package:codex_remote/src/ssh/server_connection_manager.dart';
import 'package:codex_remote/src/ui/file_manager_screen.dart';
import 'package:codex_remote/src/ui/theme.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryStore implements ProfileStore {
  @override
  Future<StoredProfiles> load() async => const StoredProfiles();

  @override
  Future<void> save(StoredProfiles value) async {}
}

class _FileManagerController extends AppController {
  // The production constructor uses private positional fields, so a public
  // super-parameter cannot be used from this test library.
  // ignore: use_super_parameters
  _FileManagerController(ProfileStore store, ServerConnectionManager manager)
    : super(store, manager);

  String? createdName;

  void showState(AppUiState value) => state = value;

  @override
  Future<void> createRemoteDirectory(String name) async {
    createdName = name;
  }
}

const _profile = ServerProfile(id: 'file-test', name: 'File server');

class _DirectoryManager extends ServerConnectionManager {
  final requested = <String?>[];
  late Completer<RemoteFileListing> pending;

  @override
  Map<String, ConnectionState> get states => {
    _profile.id: const ConnectionState(phase: ConnectionPhase.connected),
  };

  @override
  Future<RemoteFileListing> listRemoteFiles(
    ServerProfile profile,
    String? path,
  ) {
    requested.add(path);
    pending = Completer<RemoteFileListing>();
    return pending.future;
  }
}

Future<_DirectoryManager> _openNavigationFixture(WidgetTester tester) async {
  final manager = _DirectoryManager();
  final controller = _FileManagerController(_MemoryStore(), manager);
  addTearDown(manager.close);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appControllerProvider.overrideWith((ref) => controller)],
      child: const CodexRemoteApp(),
    ),
  );
  await tester.pump();
  controller.showState(
    AppUiState(
      screen: AppScreen.fileManager,
      profiles: const [_profile],
      selectedProfileId: _profile.id,
      fileManagerProfileId: _profile.id,
      fileManagerCurrentPath: '/work/child',
      fileManagerParentPath: '/work',
      fileManagerEntries: const [
        RemoteFileEntry(
          name: 'notes',
          path: '/work/child/notes',
          kind: RemoteFileKind.file,
        ),
      ],
    ),
  );
  await tester.pumpAndSettle();
  return manager;
}

void main() {
  testWidgets('system back goes up one directory, but never exits at root', (
    tester,
  ) async {
    final manager = await _openNavigationFixture(tester);
    expect(find.text('/work/child'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(manager.requested, ['/work']);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(manager.requested, ['/work']);
    expect(find.byType(FileManagerScreen), findsOneWidget);

    manager.pending.complete(
      const RemoteFileListing(currentPath: '/work', parentPath: '/'),
    );
    await tester.pumpAndSettle();
    expect(find.text('/work'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(manager.requested, ['/work', '/']);
    manager.pending.complete(const RemoteFileListing(currentPath: '/'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(FileManagerScreen), findsOneWidget);
    expect(find.text('/'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(manager.requested, ['/work', '/']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('left toolbar button clears selection or goes up one directory', (
    tester,
  ) async {
    final manager = await _openNavigationFixture(tester);
    await tester.longPress(find.text('notes'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute(); // Dismiss the entry actions sheet.
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('取消选择'));
    await tester.pumpAndSettle();
    expect(find.text('/work/child'), findsOneWidget);
    expect(manager.requested, isEmpty);
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump();
    expect(manager.requested, ['/work']);
    manager.pending.complete(
      const RemoteFileListing(currentPath: '/work', parentPath: '/'),
    );
    await tester.pumpAndSettle();
    expect(find.text('/work'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('only confirming the white close action leaves file manager', (
    tester,
  ) async {
    final manager = await _openNavigationFixture(tester);
    final close = find.byTooltip('关闭文件管理');
    final closeIcon = find.descendant(
      of: close,
      matching: find.byIcon(Icons.close),
    );
    expect(closeIcon, findsOneWidget);
    expect(
      tester.widget<Icon>(closeIcon).color ??
          IconTheme.of(tester.element(closeIcon)).color,
      Colors.white,
    );
    expect(
      tester.getCenter(close).dx,
      greaterThan(tester.getCenter(find.byTooltip('刷新目录')).dx),
    );

    await tester.tap(close);
    await tester.pumpAndSettle();
    expect(find.text('关闭文件管理？'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('/work/child'), findsOneWidget);
    expect(manager.requested, isEmpty);

    await tester.tap(close);
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('/work/child'), findsOneWidget);
    await tester.tap(close);
    await tester.pumpAndSettle();
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(FileManagerScreen), findsNothing);
    expect(find.text('最近任务'), findsOneWidget);
    expect(manager.requested, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('creates a folder from the file-manager action menu', (
    tester,
  ) async {
    final manager = ServerConnectionManager();
    final controller = _FileManagerController(_MemoryStore(), manager);
    addTearDown(manager.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: MaterialApp(
          theme: buildCodexTheme(),
          home: const FileManagerScreen(),
        ),
      ),
    );
    await tester.pump();
    controller.showState(
      const AppUiState(
        screen: AppScreen.fileManager,
        fileManagerCurrentPath: '/srv',
        fileManagerParentPath: '/',
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('更多文件操作').first);
    await tester.pumpAndSettle();
    expect(find.text('新建文件夹'), findsOneWidget);
    await tester.tap(find.text('新建文件夹'));
    await tester.pumpAndSettle();

    expect(find.text('文件夹名称'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '../invalid');
    await tester.tap(find.text('创建'));
    await tester.pump();
    expect(find.textContaining('文件名不能包含路径分隔符'), findsOneWidget);
    expect(controller.createdName, isNull);

    await tester.enterText(find.byType(TextField), 'reports');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    expect(controller.createdName, 'reports');
    expect(find.byType(AlertDialog), findsNothing);
  });
}
