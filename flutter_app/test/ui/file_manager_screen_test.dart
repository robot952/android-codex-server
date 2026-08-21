import 'package:codex_remote/src/app/app_controller.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/persistence/profile_store.dart';
import 'package:codex_remote/src/ssh/server_connection_manager.dart';
import 'package:codex_remote/src/ui/file_manager_screen.dart';
import 'package:codex_remote/src/ui/theme.dart';
import 'package:flutter/material.dart';
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

void main() {
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
