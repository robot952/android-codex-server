import 'package:codex_remote/src/app/app_controller.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/persistence/profile_store.dart';
import 'package:codex_remote/src/ssh/server_connection_manager.dart';
import 'package:codex_remote/src/ui/theme.dart';
import 'package:codex_remote/src/ui/work_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryStore implements ProfileStore {
  @override
  Future<StoredProfiles> load() async => const StoredProfiles();

  @override
  Future<void> save(StoredProfiles value) async {}
}

class _ToolCardController extends AppController {
  // ignore: use_super_parameters
  _ToolCardController(ProfileStore store, ServerConnectionManager manager)
    : super(store, manager);

  void showEntries(
    List<TimelineEntry> entries, {
    String thread = 'mcp-thread',
  }) {
    state = AppUiState(
      screen: AppScreen.work,
      activeThread: AgentThread(id: thread, title: '工具详情'),
      timeline: entries,
    );
  }
}

const _entry = TimelineEntry(
  id: 'mcp-1',
  turnId: 'turn-1',
  kind: TimelineKind.tool,
  title: 'codegraph_explore',
  status: 'running',
  text: 'MCP result text',
);

Finder _card(String id) => find.byKey(ValueKey('tool-card-$id'));

Finder _header(String id) =>
    find.descendant(of: _card(id), matching: find.byType(InkWell)).first;

Future<_ToolCardController> _mount(
  WidgetTester tester, {
  List<TimelineEntry> entries = const [_entry],
  Size size = const Size(420, 840),
  double textScale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  final manager = ServerConnectionManager();
  final controller = _ToolCardController(_MemoryStore(), manager);
  addTearDown(() async => manager.close());
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appControllerProvider.overrideWith((ref) => controller)],
      child: MaterialApp(
        theme: buildCodexTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const WorkScreen(),
      ),
    ),
  );
  controller.showEntries(entries);
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  for (final (rawStatus, label) in [
    ('running', '运行中'),
    ('completed', '完成'),
    ('failed', '失败'),
    ('', ''),
  ]) {
    testWidgets('starts $rawStatus MCP calls collapsed with a compact header', (
      tester,
    ) async {
      await _mount(tester, entries: [_entry.copyWith(status: rawStatus)]);
      expect(find.text('codegraph_explore'), findsOneWidget);
      if (label.isNotEmpty) expect(find.text(label), findsOneWidget);
      expect(find.text('MCP result text'), findsNothing);
      expect(
        find.descendant(
          of: _card('mcp-1'),
          matching: find.byType(SelectionArea),
        ),
        findsNothing,
      );
      expect(find.byTooltip('展开工具详情'), findsOneWidget);
      expect(tester.getSize(_card('mcp-1')).height, lessThan(70));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('keeps user expansion and live status/output through rebuilds', (
    tester,
  ) async {
    final controller = await _mount(tester);
    await tester.tap(_header('mcp-1'));
    await tester.pumpAndSettle();
    expect(find.text('MCP result text'), findsOneWidget);
    expect(find.byTooltip('收起工具详情'), findsOneWidget);
    expect(
      tester
          .widget<AnimatedRotation>(find.byKey(const Key('tool-expand-arrow')))
          .turns,
      0.5,
    );
    final completed = _entry.copyWith(
      status: 'completed',
      text: 'New completed result',
    );
    controller.showEntries([completed]);
    await tester.pumpAndSettle();
    expect(find.text('完成'), findsOneWidget);
    expect(find.text('New completed result'), findsOneWidget);
    expect(find.text('MCP result text'), findsNothing);
    await tester.tap(_header('mcp-1'));
    await tester.pumpAndSettle();
    controller.showEntries([completed.copyWith(text: 'Later output')]);
    await tester.pumpAndSettle();
    expect(find.text('Later output'), findsNothing);
    expect(find.byTooltip('展开工具详情'), findsOneWidget);
    expect(tester.getSize(_card('mcp-1')).height, lessThan(70));
  });

  testWidgets('keeps independent tool choices when rows are inserted', (
    tester,
  ) async {
    final second = _entry.copyWith(id: 'mcp-2', text: 'Second tool output');
    final controller = await _mount(tester, entries: [_entry, second]);
    await tester.tap(_header('mcp-1'));
    await tester.pumpAndSettle();
    expect(find.text('MCP result text'), findsOneWidget);
    expect(find.text('Second tool output'), findsNothing);
    controller.showEntries([
      _entry.copyWith(id: 'older-mcp', text: 'Older tool output'),
      _entry,
      second,
    ]);
    await tester.pumpAndSettle();
    expect(find.text('MCP result text'), findsOneWidget);
    expect(find.text('Second tool output'), findsNothing);
    expect(find.text('Older tool output'), findsNothing);
    controller.showEntries([_entry], thread: 'another-thread');
    await tester.pumpAndSettle();
    expect(find.text('MCP result text'), findsNothing);
    expect(find.byTooltip('展开工具详情'), findsOneWidget);
  });

  testWidgets(
    'shows late output without expanding a waiting tool automatically',
    (tester) async {
      final controller = await _mount(
        tester,
        entries: [_entry.copyWith(text: '')],
      );
      expect(find.text('暂无工具详情'), findsNothing);
      await tester.tap(_header('mcp-1'));
      await tester.pumpAndSettle();
      expect(find.text('暂无工具详情'), findsOneWidget);
      controller.showEntries([
        _entry.copyWith(status: 'failed', text: 'Tool failed'),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('失败'), findsOneWidget);
      expect(find.text('Tool failed'), findsOneWidget);
      expect(find.text('暂无工具详情'), findsNothing);
    },
  );

  testWidgets('keeps expanded details selectable and copies the selection', (
    tester,
  ) async {
    String? clipboard;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await _mount(tester, entries: [_entry.copyWith(text: 'copyme')]);
    await tester.tap(_header('mcp-1'));
    await tester.pumpAndSettle();
    final output = find.text('copyme');
    expect(
      find.ancestor(of: output, matching: find.byType(SelectionArea)),
      findsOneWidget,
    );
    await tester.longPress(output);
    await tester.pumpAndSettle();
    expect(find.text('Copy'), findsOneWidget);
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(clipboard, 'copyme');
    expect(find.text('copyme'), findsOneWidget);
  });

  testWidgets(
    'bounds long output and fits long names at twice normal text size',
    (tester) async {
      final output = List.filled(
        80,
        'Long MCP output line with horizontal content',
      ).join('\n');
      await _mount(
        tester,
        size: const Size(320, 840),
        textScale: 2,
        entries: [
          _entry.copyWith(
            title: 'codegraph_explore_with_a_very_long_server_name',
            text: output,
          ),
        ],
      );
      expect(find.text(output), findsNothing);
      expect(tester.getSize(_card('mcp-1')).height, lessThan(100));
      expect(tester.takeException(), isNull);
      await tester.tap(_header('mcp-1'));
      await tester.pumpAndSettle();
      expect(find.text(output), findsOneWidget);
      expect(tester.getSize(_card('mcp-1')).height, lessThan(370));
      expect(tester.takeException(), isNull);
    },
  );
}
