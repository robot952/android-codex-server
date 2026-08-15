import 'dart:convert';
import 'dart:io';

import 'package:codex_remote/src/app/app_controller.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/persistence/profile_store.dart';
import 'package:codex_remote/src/platform/local_file_exporter.dart';
import 'package:codex_remote/src/ssh/server_connection_manager.dart';
import 'package:codex_remote/src/ui/theme.dart';
import 'package:codex_remote/src/ui/work_screen.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

class _MemoryStore implements ProfileStore {
  @override
  Future<StoredProfiles> load() async => const StoredProfiles();

  @override
  Future<void> save(StoredProfiles value) async {}
}

class _LayoutController extends AppController {
  // The production constructor uses private positional fields, so a public
  // super-parameter cannot be used from this test library.
  // ignore: use_super_parameters
  _LayoutController(ProfileStore store, ServerConnectionManager manager)
    : super(store, manager);

  void showState(AppUiState value) => state = value;
}

class _PaginationController extends _LayoutController {
  _PaginationController(super.store, super.manager);

  Future<void> Function()? onLoadOlder;
  int loadOlderCalls = 0;

  @override
  Future<void> loadOlderTurns() async {
    loadOlderCalls += 1;
    await onLoadOlder?.call();
  }
}

class _TrackingFileExporter implements LocalFileExporter {
  int beginCalls = 0;

  @override
  Future<LocalFileExportSession?> begin({
    required String fileName,
    String mimeType = 'application/octet-stream',
  }) async {
    beginCalls += 1;
    return null;
  }
}

TapGestureRecognizer _linkRecognizer(WidgetTester tester, String text) {
  final recognizer = _maybeLinkRecognizer(tester, text);
  if (recognizer != null) return recognizer;
  throw TestFailure('No clickable link span found for $text');
}

TapGestureRecognizer? _maybeLinkRecognizer(WidgetTester tester, String text) {
  for (final selectable in tester.widgetList<SelectableText>(
    find.byType(SelectableText),
  )) {
    final recognizer = _findLinkRecognizer(selectable.textSpan, text);
    if (recognizer != null) return recognizer;
  }
  return null;
}

TapGestureRecognizer? _findLinkRecognizer(InlineSpan? span, String text) {
  if (span is! TextSpan) return null;
  if ((span.text ?? '').contains(text) &&
      span.recognizer is TapGestureRecognizer) {
    return span.recognizer! as TapGestureRecognizer;
  }
  for (final child in span.children ?? const <InlineSpan>[]) {
    final recognizer = _findLinkRecognizer(child, text);
    if (recognizer != null) return recognizer;
  }
  return null;
}

Finder _popupItemForText(String text) => find.ancestor(
  of: find.text(text),
  matching: find.byWidgetPredicate((widget) => widget is PopupMenuItem),
);

Future<void> _jumpToTranscriptStart(
  WidgetTester tester,
  ScrollController controller,
) async {
  for (var attempt = 0; attempt < 8; attempt += 1) {
    controller.jumpTo(controller.position.minScrollExtent);
    await tester.pumpAndSettle();
    if ((controller.position.pixels - controller.position.minScrollExtent)
            .abs() <
        0.5) {
      return;
    }
  }
  throw TestFailure('Transcript did not settle at its minimum scroll extent');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('matches the legacy follow-output state machine', () {
    expect(
      updatedFollowOutput(
        current: false,
        userDragging: false,
        canScrollForward: false,
      ),
      isTrue,
    );
    expect(
      updatedFollowOutput(
        current: true,
        userDragging: true,
        canScrollForward: true,
      ),
      isFalse,
    );
    expect(
      updatedFollowOutput(
        current: false,
        userDragging: false,
        canScrollForward: true,
      ),
      isFalse,
    );
  });

  List<TimelineEntry> entries(int start, int count) => [
    for (var index = start; index < start + count; index += 1)
      TimelineEntry(
        id: 'timeline-$index',
        kind: TimelineKind.agentMessage,
        text: '消息 $index',
      ),
  ];

  AppUiState timelineState({
    required List<TimelineEntry> timeline,
    String? olderTurnsCursor,
    bool olderTurnsLoading = false,
    bool loading = false,
  }) => AppUiState(
    screen: AppScreen.work,
    activeThread: const AgentThread(id: 'timeline-thread', title: '分页会话'),
    activeAgentCapabilities: AgentCapabilities.codex,
    timeline: timeline,
    olderTurnsCursor: olderTurnsCursor,
    olderTurnsLoading: olderTurnsLoading,
    loading: loading,
  );

  testWidgets('opens an existing conversation at the latest message', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 840);
    addTearDown(tester.view.reset);

    final manager = ServerConnectionManager();
    final controller = _LayoutController(_MemoryStore(), manager)
      ..showState(timelineState(timeline: const [], loading: true));
    addTearDown(() async => manager.close());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: MaterialApp(theme: buildCodexTheme(), home: const WorkScreen()),
      ),
    );
    await tester.pump();
    controller.showState(
      timelineState(timeline: entries(0, 40), loading: false),
    );
    await tester.pumpAndSettle();

    final scrollbar = tester.widget<Scrollbar>(
      find.byKey(const Key('transcript-scrollbar')),
    );
    final scrollView = tester.widget<CustomScrollView>(
      find.byType(CustomScrollView),
    );
    expect(scrollbar.controller, same(scrollView.controller));
    expect(scrollbar.thumbVisibility, isFalse);
    expect(scrollbar.trackVisibility, isFalse);
    expect(scrollbar.interactive, isTrue);
    expect(scrollbar.thickness, 4);
    expect(find.text('消息 39'), findsOneWidget);
    expect(find.text('消息 0'), findsNothing);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, 160));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final scrollbarPainter = tester
        .widgetList<CustomPaint>(
          find.descendant(
            of: find.byKey(const Key('transcript-scrollbar')),
            matching: find.byType(CustomPaint),
          ),
        )
        .map((paint) => paint.foregroundPainter)
        .whereType<ScrollbarPainter>()
        .single;
    expect(scrollbarPainter.fadeoutOpacityAnimation.value, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('opens a short conversation at the top of the transcript', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 840);
    addTearDown(tester.view.reset);

    final manager = ServerConnectionManager();
    final controller = _LayoutController(_MemoryStore(), manager)
      ..showState(
        timelineState(
          timeline: const <TimelineEntry>[
            TimelineEntry(
              id: 'short-user',
              kind: TimelineKind.userMessage,
              text: '短对话第一条',
            ),
            TimelineEntry(
              id: 'short-agent',
              kind: TimelineKind.agentMessage,
              text: '短对话回复',
            ),
          ],
        ),
      );
    addTearDown(() async => manager.close());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: MaterialApp(theme: buildCodexTheme(), home: const WorkScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final scrollViewFinder = find.byType(CustomScrollView);
    final scrollView = tester.widget<CustomScrollView>(scrollViewFinder);
    final viewport = tester.getRect(scrollViewFinder);
    final firstMessage = tester.getRect(find.text('短对话第一条'));

    expect(firstMessage.top, lessThan(viewport.top + 80));
    expect(scrollView.controller!.position.pixels, closeTo(0, 0.01));
    expect(scrollView.controller!.position.maxScrollExtent, closeTo(0, 0.01));

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    expect(find.text('短对话回复'), findsOneWidget);

    tester.view.viewInsets = const FakeViewPadding();
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.text('短对话第一条')).top,
      closeTo(firstMessage.top, 1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('opens a long cached conversation without chasing its extent', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 840);
    addTearDown(tester.view.reset);

    final timeline = <TimelineEntry>[
      for (var index = 0; index < 253; index += 1)
        TimelineEntry(
          id: 'cached-$index',
          kind: TimelineKind.agentMessage,
          text:
              '缓存消息 $index\n'
              '${List.filled(index % 9 + 1, '不同高度的缓存内容').join('\n')}',
        ),
    ];
    final manager = ServerConnectionManager();
    final controller = _LayoutController(_MemoryStore(), manager)
      ..showState(
        timelineState(
          timeline: timeline,
          olderTurnsCursor: 'older',
          loading: true,
        ),
      );
    addTearDown(() async => manager.close());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: MaterialApp(theme: buildCodexTheme(), home: const WorkScreen()),
      ),
    );
    await tester.pump();

    final scrollViewFinder = find.byType(CustomScrollView);
    final scrollView = tester.widget<CustomScrollView>(scrollViewFinder);
    final latestFinder = find.text(timeline.last.text);
    expect(scrollView.anchor, 1);
    expect(latestFinder, findsOneWidget);

    void expectStableBottom() {
      final position = scrollView.controller!.position;
      expect(position.pixels, closeTo(0, 0.01));
      expect(position.maxScrollExtent, closeTo(0, 0.01));
      expect(position.outOfRange, isFalse);
      expect(latestFinder, findsOneWidget);
    }

    expectStableBottom();
    for (var frame = 0; frame < 12; frame += 1) {
      await tester.pump(const Duration(milliseconds: 16));
      expectStableBottom();
    }

    controller.showState(controller.state.copyWith(loading: false));
    for (var frame = 0; frame < 12; frame += 1) {
      await tester.pump(const Duration(milliseconds: 16));
      expectStableBottom();
    }

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    for (var frame = 0; frame < 14; frame += 1) {
      await tester.pump(const Duration(milliseconds: 16));
      expectStableBottom();
    }
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps cached history visible with a centered loading state', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 840);
    addTearDown(tester.view.reset);

    final manager = ServerConnectionManager();
    final controller = _LayoutController(_MemoryStore(), manager);
    addTearDown(() async => manager.close());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: MaterialApp(theme: buildCodexTheme(), home: const WorkScreen()),
      ),
    );
    controller.showState(
      timelineState(timeline: entries(0, 12), loading: true),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('消息 11'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsWidgets);

    controller.showState(
      timelineState(timeline: entries(0, 40), loading: false),
    );
    await tester.pumpAndSettle();

    expect(find.text('消息 39'), findsOneWidget);
    expect(find.text('消息 0'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'cancels older-page loading when the pull returns below threshold',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(420, 840);
      addTearDown(tester.view.reset);

      final manager = ServerConnectionManager();
      final controller = _PaginationController(_MemoryStore(), manager)
        ..showState(
          timelineState(timeline: entries(0, 40), olderTurnsCursor: 'page-2'),
        );
      addTearDown(() async => manager.close());
      controller.onLoadOlder = () async {};

      await tester.pumpWidget(
        ProviderScope(
          overrides: [appControllerProvider.overrideWith((ref) => controller)],
          child: MaterialApp(
            theme: buildCodexTheme(),
            home: const WorkScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final scrollViewFinder = find.byType(CustomScrollView);
      final scrollView = tester.widget<CustomScrollView>(scrollViewFinder);
      await _jumpToTranscriptStart(tester, scrollView.controller!);

      final rect = tester.getRect(scrollViewFinder);
      final gesture = await tester.startGesture(
        Offset(rect.center.dx, rect.top + 80),
      );
      await gesture.moveBy(const Offset(0, 220));
      await tester.pump();
      expect(find.text('松开加载更多'), findsOneWidget);

      await gesture.moveBy(const Offset(0, -400));
      await tester.pump();
      expect(find.text('松开加载更多'), findsNothing);

      await gesture.up();
      await tester.pumpAndSettle();
      expect(controller.loadOlderCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('shows the release label while an older-page pull is held', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 840);
    addTearDown(tester.view.reset);

    final manager = ServerConnectionManager();
    final controller = _PaginationController(_MemoryStore(), manager)
      ..showState(
        timelineState(timeline: entries(0, 40), olderTurnsCursor: 'page-2'),
      );
    addTearDown(() async => manager.close());
    controller.onLoadOlder = () async {};

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: MaterialApp(theme: buildCodexTheme(), home: const WorkScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final scrollViewFinder = find.byType(CustomScrollView);
    final scrollView = tester.widget<CustomScrollView>(scrollViewFinder);
    await _jumpToTranscriptStart(tester, scrollView.controller!);

    final rect = tester.getRect(scrollViewFinder);
    final gesture = await tester.startGesture(
      Offset(rect.center.dx, rect.top + 80),
    );
    await gesture.moveBy(const Offset(0, 220));
    await tester.pump();

    expect(find.text('松开加载更多'), findsOneWidget);
    expect(controller.loadOlderCalls, 0);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(controller.loadOlderCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('can start a history pull before the list reaches the top', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 840);
    addTearDown(tester.view.reset);

    final manager = ServerConnectionManager();
    final controller = _PaginationController(_MemoryStore(), manager)
      ..showState(
        timelineState(timeline: entries(0, 40), olderTurnsCursor: 'page-2'),
      );
    addTearDown(() async => manager.close());
    controller.onLoadOlder = () async {};

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: MaterialApp(theme: buildCodexTheme(), home: const WorkScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final scrollViewFinder = find.byType(CustomScrollView);
    final scrollView = tester.widget<CustomScrollView>(scrollViewFinder);
    await _jumpToTranscriptStart(tester, scrollView.controller!);
    final position = scrollView.controller!.position;
    scrollView.controller!.jumpTo(
      (position.minScrollExtent + 120).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
    await tester.pump();

    final rect = tester.getRect(scrollViewFinder);
    final gesture = await tester.startGesture(
      Offset(rect.center.dx, rect.top + 160),
    );
    await gesture.moveBy(const Offset(0, 420));
    await tester.pump();

    expect(find.text('松开加载更多'), findsOneWidget);
    expect(controller.loadOlderCalls, 0);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(controller.loadOlderCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps the visible message anchored while loading older pages', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 840);
    addTearDown(tester.view.reset);

    final manager = ServerConnectionManager();
    final controller = _PaginationController(_MemoryStore(), manager)
      ..showState(
        timelineState(timeline: entries(0, 40), olderTurnsCursor: 'page-2'),
      );
    addTearDown(() async => manager.close());
    controller.onLoadOlder = () async {
      controller.showState(controller.state.copyWith(olderTurnsLoading: true));
      await Future<void>.value();
      controller.showState(
        controller.state.copyWith(
          timeline: [...entries(-10, 10), ...controller.state.timeline],
          olderTurnsCursor: null,
          olderTurnsLoading: false,
        ),
      );
    };

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: MaterialApp(theme: buildCodexTheme(), home: const WorkScreen()),
      ),
    );
    await tester.pumpAndSettle();
    final scrollView = tester.widget<CustomScrollView>(
      find.byType(CustomScrollView),
    );
    await _jumpToTranscriptStart(tester, scrollView.controller!);
    final beforeTop = tester.getTopLeft(find.text('消息 0')).dy;

    await tester.drag(find.byType(CustomScrollView), const Offset(0, 120));
    await tester.pumpAndSettle();

    expect(controller.loadOlderCalls, 1);
    expect(controller.state.timeline.first.text, '消息 -10');
    expect(controller.state.timeline.length, 50);
    expect(find.text('消息 39'), findsNothing);
    expect(tester.getTopLeft(find.text('消息 0')).dy, closeTo(beforeTop, 2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('retracts the older-page header without a one-frame jump', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 840);
    addTearDown(tester.view.reset);

    final manager = ServerConnectionManager();
    final controller = _PaginationController(_MemoryStore(), manager)
      ..showState(
        timelineState(timeline: entries(0, 40), olderTurnsCursor: 'page-2'),
      );
    addTearDown(() async => manager.close());
    controller.onLoadOlder = () async {
      controller.showState(controller.state.copyWith(olderTurnsLoading: true));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      controller.showState(
        controller.state.copyWith(
          timeline: [...entries(-10, 10), ...controller.state.timeline],
          olderTurnsCursor: null,
          olderTurnsLoading: false,
        ),
      );
    };

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: MaterialApp(theme: buildCodexTheme(), home: const WorkScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final scrollViewFinder = find.byType(CustomScrollView);
    final scrollView = tester.widget<CustomScrollView>(scrollViewFinder);
    await _jumpToTranscriptStart(tester, scrollView.controller!);
    final restingTop = tester.getTopLeft(find.text('消息 0')).dy;

    await tester.drag(scrollViewFinder, const Offset(0, 120));
    await tester.pump(const Duration(milliseconds: 120));
    final retractStartTop = tester.getTopLeft(find.text('消息 0')).dy;
    expect(retractStartTop, closeTo(restingTop, 2));

    await tester.pump(const Duration(milliseconds: 16));
    final nextFrameTop = tester.getTopLeft(find.text('消息 0')).dy;
    expect(nextFrameTop, closeTo(retractStartTop, 2));

    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('消息 0')).dy, closeTo(restingTop, 2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps the anchor across repeated older-page pulls', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 840);
    addTearDown(tester.view.reset);

    final manager = ServerConnectionManager();
    final controller = _PaginationController(_MemoryStore(), manager)
      ..showState(
        timelineState(timeline: entries(0, 40), olderTurnsCursor: 'page-2'),
      );
    addTearDown(() async => manager.close());
    List<TimelineEntry> olderPage(int start) => [
      for (var index = start; index < start + 10; index += 1)
        TimelineEntry(
          id: 'timeline-$index',
          kind: TimelineKind.agentMessage,
          text:
              '消息 $index\n${List.filled(index.abs() % 4 + 1, '高度变化内容').join('\n')}',
        ),
    ];
    controller.onLoadOlder = () async {
      final page = controller.loadOlderCalls;
      controller.showState(controller.state.copyWith(olderTurnsLoading: true));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final olderStart = page == 1 ? -10 : -20;
      controller.showState(
        controller.state.copyWith(
          timeline: [...olderPage(olderStart), ...controller.state.timeline],
          olderTurnsCursor: page == 1 ? 'page-3' : null,
          olderTurnsLoading: false,
        ),
      );
    };

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: MaterialApp(theme: buildCodexTheme(), home: const WorkScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final scrollViewFinder = find.byType(CustomScrollView);
    final scrollView = tester.widget<CustomScrollView>(scrollViewFinder);
    await _jumpToTranscriptStart(tester, scrollView.controller!);
    final beforeTop = tester.getTopLeft(find.text('消息 0')).dy;
    await tester.drag(scrollViewFinder, const Offset(0, 10000));
    await tester.pump();
    await tester.pump();
    expect(controller.loadOlderCalls, 1);
    expect(controller.state.olderTurnsLoading, isTrue);

    await tester.drag(
      scrollViewFinder,
      const Offset(0, 120),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(controller.loadOlderCalls, 1);

    await tester.pumpAndSettle();
    expect(find.text('消息 0'), findsOneWidget);
    expect(tester.getTopLeft(find.text('消息 0')).dy, closeTo(beforeTop, 2));

    await _jumpToTranscriptStart(tester, scrollView.controller!);
    final secondAnchorText = olderPage(-10).first.text;
    final beforeSecondTop = tester.getTopLeft(find.text(secondAnchorText)).dy;

    await tester.drag(scrollViewFinder, const Offset(0, 120));
    await tester.pumpAndSettle();

    expect(controller.loadOlderCalls, 2);
    expect(find.text(secondAnchorText), findsOneWidget);
    expect(
      tester.getTopLeft(find.text(secondAnchorText)).dy,
      closeTo(beforeSecondTop, 2),
    );
    expect(find.text('消息 39'), findsNothing);

    await _jumpToTranscriptStart(tester, scrollView.controller!);
    await tester.drag(scrollViewFinder, const Offset(0, 120));
    await tester.pumpAndSettle();
    expect(controller.loadOlderCalls, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps position when repeated lazy-list extents change', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 840);
    addTearDown(tester.view.reset);

    List<TimelineEntry> variableEntries(int start, int count) => [
      for (var index = start; index < start + count; index += 1)
        TimelineEntry(
          id: 'variable-$index',
          kind: TimelineKind.agentMessage,
          text:
              '可变消息 $index\n'
              '${List.filled(index.abs() % 12 + 1, '不同高度的历史内容').join('\n')}',
        ),
    ];

    final manager = ServerConnectionManager();
    final pageSizes = <int>[24, 10, 29, 22, 36];
    var nextStart = 0;
    final controller = _PaginationController(_MemoryStore(), manager)
      ..showState(
        timelineState(
          timeline: variableEntries(0, 27),
          olderTurnsCursor: 'page-1',
        ),
      );
    addTearDown(() async => manager.close());
    controller.onLoadOlder = () async {
      final pageIndex = controller.loadOlderCalls - 1;
      final pageSize = pageSizes[pageIndex];
      nextStart -= pageSize;
      controller.showState(controller.state.copyWith(olderTurnsLoading: true));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      controller.showState(
        controller.state.copyWith(
          timeline: [
            ...variableEntries(nextStart, pageSize),
            ...controller.state.timeline,
          ],
          olderTurnsCursor: pageIndex == pageSizes.length - 1
              ? null
              : 'page-${pageIndex + 2}',
          olderTurnsLoading: false,
        ),
      );
    };

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: MaterialApp(theme: buildCodexTheme(), home: const WorkScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final scrollViewFinder = find.byType(CustomScrollView);
    final scrollView = tester.widget<CustomScrollView>(scrollViewFinder);
    expect(scrollView.center, isNotNull);

    for (var pageIndex = 0; pageIndex < pageSizes.length; pageIndex += 1) {
      await _jumpToTranscriptStart(tester, scrollView.controller!);
      final anchorText = controller.state.timeline.first.text;
      final anchorFinder = find.text(anchorText);
      expect(anchorFinder, findsOneWidget);
      final anchorTop = tester.getTopLeft(anchorFinder).dy;

      await tester.drag(scrollViewFinder, const Offset(0, 150));
      await tester.pumpAndSettle();

      expect(controller.loadOlderCalls, pageIndex + 1);
      expect(anchorFinder, findsOneWidget);
      expect(tester.getTopLeft(anchorFinder).dy, closeTo(anchorTop, 2));
      expect(scrollView.controller!.position.extentAfter, greaterThan(100));
    }

    expect(tester.takeException(), isNull);
  });

  testWidgets('renders the screenshot-style work timeline and composer', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 2.75;
    tester.view.physicalSize = const Size(1220, 2712);
    addTearDown(tester.view.reset);

    final manager = ServerConnectionManager();
    final controller = _LayoutController(_MemoryStore(), manager);
    addTearDown(() async {
      await manager.close();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: MaterialApp(theme: buildCodexTheme(), home: const WorkScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    controller.showState(
      AppUiState(
        screen: AppScreen.work,
        activeThread: const AgentThread(
          id: 'thread-1',
          title: '安卓 Codex APP (3)',
          cwd: '/home/yan/ygy',
        ),
        activeAgentCapabilities: AgentCapabilities.codex,
        models: const [
          AgentModel(id: 'gpt-5.6', model: 'gpt-5.6', displayName: 'GPT-5.6'),
        ],
        selectedModel: 'gpt-5.6',
        selectedEffort: 'xhigh',
        tokenUsage: const TokenUsage(
          last: TokenUsageBreakdown(totalTokens: 36),
          modelContextWindow: 100,
        ),
        turnTiming: const TurnTiming(
          threadId: 'thread-1',
          startedAtMillis: 1786210800000,
          completedAtMillis: 1786210802000,
          stopped: true,
        ),
        timeline: const [
          TimelineEntry(
            id: 'assistant-1',
            kind: TimelineKind.agentMessage,
            text: '助手回复直接显示在背景上。',
          ),
          TimelineEntry(
            id: 'reasoning-1',
            kind: TimelineKind.reasoning,
            title: '思考过程',
            text: '这里是折叠的思考内容。',
          ),
          TimelineEntry(
            id: 'image-1',
            kind: TimelineKind.tool,
            title: '查看了图片',
            text: '/home/yan/ygy/example.png',
          ),
          TimelineEntry(
            id: 'command-1',
            kind: TimelineKind.command,
            status: 'completed',
            command: 'flutter test',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('安卓 Codex APP (3)'), findsOneWidget);
    expect(find.text('/home/yan/ygy'), findsOneWidget);
    expect(find.text('助手回复直接显示在背景上。'), findsOneWidget);
    expect(find.text('思考过程'), findsOneWidget);
    expect(find.text('查看了图片'), findsOneWidget);
    expect(find.text('/home/yan/ygy/example.png'), findsOneWidget);
    expect(find.text('运行了命令'), findsOneWidget);
    expect(find.text('完成'), findsOneWidget);
    expect(find.text('已停止  2s'), findsOneWidget);
    expect(find.text('描述任务'), findsOneWidget);
    expect(find.text('权限'), findsOneWidget);
    expect(find.text('36%'), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);
    expect(find.byIcon(Icons.search), findsOneWidget);
    expect(find.byIcon(Icons.visibility), findsNWidgets(2));
    expect(tester.widget<Icon>(find.byIcon(Icons.search)).size, 17);
    expect(tester.widget<Icon>(find.byIcon(Icons.terminal)).size, 17);
    expect(
      tester.getSize(find.byKey(const Key('composer-attachment-menu'))),
      const Size.square(36),
    );
    await tester.tap(find.byKey(const Key('composer-attachment-menu')));
    await tester.pumpAndSettle();
    expect(find.text('拍照'), findsOneWidget);
    expect(find.byIcon(Icons.photo_camera_outlined), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const Key('composer-action-menu'))),
      const Size.square(36),
    );
    expect(
      tester
          .getSize(find.byKey(const Key('composer-permission-button')))
          .height,
      36,
    );
    final composerInput = tester.widget<TextField>(
      find.byKey(const Key('composer-input')),
    );
    expect(composerInput.decoration?.filled, isFalse);
    expect(composerInput.decoration?.border, InputBorder.none);
    expect(composerInput.decoration?.enabledBorder, InputBorder.none);
    expect(composerInput.decoration?.focusedBorder, InputBorder.none);
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(873, 2048);
    controller.showState(
      controller.state.copyWith(
        models: const [
          AgentModel(
            id: 'gpt-5.6-terra-preview',
            model: 'gpt-5.6-terra-preview',
            displayName: 'GPT-5.6-Terra-Preview',
          ),
        ],
        selectedModel: 'gpt-5.6-terra-preview',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('5.6-Terra-Preview 极高'), findsOneWidget);
    final permissionRect = tester.getRect(
      find.byKey(const Key('composer-permission-button')),
    );
    final contextRect = tester.getRect(
      find.byKey(const Key('composer-context-usage')),
    );
    final modelRect = tester.getRect(
      find.byKey(const Key('composer-model-label')),
    );
    final sendRect = tester.getRect(find.byTooltip('发送'));
    expect(contextRect.left, greaterThanOrEqualTo(permissionRect.right));
    expect(modelRect.right, lessThanOrEqualTo(sendRect.left));
    expect(
      tester
          .renderObject<RenderParagraph>(
            find.byKey(const Key('composer-model-label')),
          )
          .didExceedMaxLines,
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  test('camera photo is prepared as an image attachment', () async {
    final directory = await Directory.systemTemp.createTemp(
      'work-camera-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final photoBytes = <int>[0xff, 0xd8, 0xff, 0xd9];
    final photo = File('${directory.path}/camera-photo.jpg');
    await photo.writeAsBytes(photoBytes);

    final upload = await cameraPhotoAttachment(XFile(photo.path));

    expect(upload.name, 'camera-photo.jpg');
    expect(upload.mimeType, 'image/jpeg');
    expect(upload.bytes, photoBytes);
  });

  testWidgets('shows completed background agents above the composer', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 840);
    addTearDown(tester.view.reset);
    final manager = ServerConnectionManager();
    final controller = _LayoutController(_MemoryStore(), manager);
    addTearDown(() async => manager.close());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: MaterialApp(theme: buildCodexTheme(), home: const WorkScreen()),
      ),
    );
    controller.showState(
      const AppUiState(
        screen: AppScreen.work,
        activeThread: AgentThread(id: 'agents-thread', title: '子智能体'),
        activeAgentCapabilities: AgentCapabilities.codex,
        timeline: <TimelineEntry>[
          TimelineEntry(
            id: 'agent-a',
            kind: TimelineKind.subAgent,
            status: 'completed',
            turnId: 'turn-1',
            subAgentPath: 'team/check_workspace',
            subAgentThreadId: 'child-a',
          ),
          TimelineEntry(
            id: 'agent-b',
            kind: TimelineKind.subAgent,
            status: 'completed',
            turnId: 'turn-1',
            subAgentPath: 'team/check_time',
            subAgentThreadId: 'child-b',
          ),
          TimelineEntry(
            id: 'agent-c',
            kind: TimelineKind.subAgent,
            status: 'completed',
            turnId: 'turn-1',
            subAgentPath: 'team/check_system',
            subAgentThreadId: 'child-c',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('3 个后台智能体'), findsOneWidget);
    await tester.tap(find.byKey(const Key('background-agents-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('check_workspace'), findsWidgets);
    expect(find.text('check_time'), findsWidgets);
    expect(find.text('check_system'), findsWidgets);
    expect(find.text('已完成'), findsNWidgets(6));
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows six background agents after two parent turns', (
    tester,
  ) async {
    final manager = ServerConnectionManager();
    final controller = _LayoutController(_MemoryStore(), manager);
    addTearDown(() async => manager.close());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: MaterialApp(theme: buildCodexTheme(), home: const WorkScreen()),
      ),
    );
    controller.showState(
      const AppUiState(
        screen: AppScreen.work,
        activeThread: AgentThread(id: 'agents-thread'),
        activeTurnId: 'turn-current',
        running: true,
        activeAgentCapabilities: AgentCapabilities.codex,
        timeline: <TimelineEntry>[
          TimelineEntry(
            id: 'old-a',
            kind: TimelineKind.subAgent,
            status: 'completed',
            turnId: 'turn-old',
            subAgentThreadId: 'old-a',
          ),
          TimelineEntry(
            id: 'old-b',
            kind: TimelineKind.subAgent,
            status: 'completed',
            turnId: 'turn-old',
            subAgentThreadId: 'old-b',
          ),
          TimelineEntry(
            id: 'old-c',
            kind: TimelineKind.subAgent,
            status: 'completed',
            turnId: 'turn-old',
            subAgentThreadId: 'old-c',
          ),
          TimelineEntry(
            id: 'current-a',
            kind: TimelineKind.subAgent,
            status: 'running',
            turnId: 'turn-current',
            subAgentThreadId: 'current-a',
          ),
          TimelineEntry(
            id: 'current-b',
            kind: TimelineKind.subAgent,
            status: 'running',
            turnId: 'turn-current',
            subAgentThreadId: 'current-b',
          ),
          TimelineEntry(
            id: 'current-c',
            kind: TimelineKind.subAgent,
            status: 'running',
            turnId: 'turn-current',
            subAgentThreadId: 'current-c',
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('6 个后台智能体'), findsOneWidget);
  });

  testWidgets(
    'does not show unconfirmed sub-agent attempts as background agents',
    (tester) async {
      final manager = ServerConnectionManager();
      final controller = _LayoutController(_MemoryStore(), manager);
      addTearDown(() async => manager.close());
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appControllerProvider.overrideWith((ref) => controller)],
          child: MaterialApp(
            theme: buildCodexTheme(),
            home: const WorkScreen(),
          ),
        ),
      );
      controller.showState(
        const AppUiState(
          screen: AppScreen.work,
          activeThread: AgentThread(id: 'agents-thread'),
          activeTurnId: 'turn-current',
          running: true,
          activeAgentCapabilities: AgentCapabilities.codex,
          timeline: <TimelineEntry>[
            TimelineEntry(
              id: 'attempt-a',
              kind: TimelineKind.subAgent,
              status: 'running',
              turnId: 'turn-current',
              subAgentPath: 'team/check_workspace',
              subAgentActivity: 'started',
            ),
            TimelineEntry(
              id: 'attempt-b',
              kind: TimelineKind.subAgent,
              status: 'running',
              turnId: 'turn-current',
              subAgentPath: 'team/check_time',
              subAgentActivity: 'started',
            ),
            TimelineEntry(
              id: 'attempt-c',
              kind: TimelineKind.subAgent,
              status: 'running',
              turnId: 'turn-current',
              subAgentPath: 'team/check_system',
              subAgentActivity: 'started',
            ),
          ],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('3 个后台智能体'), findsNothing);
      expect(find.byKey(const Key('background-agents-toggle')), findsNothing);
      expect(find.text('准备中'), findsNWidgets(3));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('matches the original work menu and gates Debug logs', (
    tester,
  ) async {
    final manager = ServerConnectionManager();
    final controller = _LayoutController(_MemoryStore(), manager);
    addTearDown(() async {
      await manager.close();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: MaterialApp(theme: buildCodexTheme(), home: const WorkScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    const menuState = AppUiState(
      screen: AppScreen.work,
      activeThread: AgentThread(id: 'thread-menu', title: '菜单样式'),
      activeAgentCapabilities: AgentCapabilities.codex,
    );
    controller.showState(menuState);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('work-action-menu')));
    await tester.pumpAndSettle();
    expect(find.text('重命名'), findsOneWidget);
    expect(find.text('归档'), findsOneWidget);
    expect(find.text('设置目标'), findsOneWidget);
    expect(find.text('添加崩溃 / Debug 日志'), findsNothing);
    expect(find.byIcon(Icons.edit), findsOneWidget);
    expect(find.byIcon(Icons.archive), findsOneWidget);
    expect(find.byIcon(Icons.track_changes), findsOneWidget);
    expect(find.byType(PopupMenuDivider), findsNothing);
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();

    controller.showState(menuState.copyWith(debugModeEnabled: true));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('work-action-menu')));
    await tester.pumpAndSettle();
    expect(find.text('添加崩溃 / Debug 日志'), findsOneWidget);
    expect(find.byIcon(Icons.bug_report), findsOneWidget);
    expect(find.byType(PopupMenuDivider), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('anchors work popups like the original Android layout', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 840);
    addTearDown(tester.view.reset);
    final manager = ServerConnectionManager();
    final controller = _LayoutController(_MemoryStore(), manager);
    addTearDown(() async => manager.close());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: MaterialApp(theme: buildCodexTheme(), home: const WorkScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    controller.showState(
      const AppUiState(
        screen: AppScreen.work,
        activeThread: AgentThread(id: 'popup-thread', title: '弹窗位置'),
        activeAgentCapabilities: AgentCapabilities.codex,
        tokenUsage: TokenUsage(
          last: TokenUsageBreakdown(totalTokens: 14_300),
          modelContextWindow: 258_000,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final topButton = find.byKey(const Key('work-action-menu'));
    final topButtonWidget = tester.widget<PopupMenuButton<String>>(topButton);
    expect(topButtonWidget.position, PopupMenuPosition.under);
    expect(topButtonWidget.popUpAnimationStyle, AnimationStyle.noAnimation);
    final topButtonRect = tester.getRect(topButton);
    await tester.tap(topButton);
    await tester.pump();
    expect(find.text('重命名'), findsOneWidget);
    final topFirstItemRect = tester.getRect(_popupItemForText('重命名'));
    expect(
      topFirstItemRect.top,
      greaterThanOrEqualTo(topButtonRect.bottom + 8),
    );
    expect((topFirstItemRect.right - topButtonRect.right).abs(), lessThan(9));
    await tester.tapAt(const Offset(8, 400));
    await tester.pumpAndSettle();

    final composerButton = find.byKey(const Key('composer-action-menu'));
    final composerButtonWidget = tester.widget<PopupMenuButton<String>>(
      composerButton,
    );
    expect(
      composerButtonWidget.popUpAnimationStyle,
      AnimationStyle.noAnimation,
    );
    final composerButtonRect = tester.getRect(composerButton);
    await tester.tap(composerButton);
    await tester.pump();
    expect(find.text('选择模型'), findsOneWidget);
    final composerLastItemRect = tester.getRect(_popupItemForText('权限'));
    expect(
      composerLastItemRect.bottom,
      lessThanOrEqualTo(composerButtonRect.top - 28),
    );
    final composerFirstItemRect = tester.getRect(_popupItemForText('设置目标'));
    expect(
      (composerFirstItemRect.left - composerButtonRect.left).abs(),
      lessThan(9),
    );
    expect(composerFirstItemRect.width, lessThanOrEqualTo(150));
    await tester.tapAt(const Offset(410, 300));
    await tester.pumpAndSettle();

    final contextButton = find.byKey(const Key('composer-context-usage'));
    final contextButtonRect = tester.getRect(contextButton);
    await tester.tap(contextButton);
    await tester.pumpAndSettle();
    final contextItemRect = tester.getRect(_popupItemForText('背景信息窗口：'));
    expect(
      contextItemRect.bottom,
      lessThanOrEqualTo(contextButtonRect.top - 28),
    );
    expect(contextItemRect.center.dx, closeTo(contextButtonRect.center.dx, 1));
    expect(contextItemRect.width, closeTo(196, 1));
    expect(find.text('5% 已用（剩余 95%）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('opens adjacent URLs and previews linked remote images', (
    tester,
  ) async {
    const url = 'http://192.168.8.107/codex.apk';
    const imagePath =
        '/home/yan/ygy/codex-remote-android/.workflow-cache/emulator/'
        'latest-release.png';
    final manager = ServerConnectionManager();
    final controller = _LayoutController(_MemoryStore(), manager);
    final exporter = _TrackingFileExporter();
    String? loadedImagePath;
    addTearDown(() async {
      await manager.close();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: MaterialApp(
          theme: buildCodexTheme(),
          home: WorkScreen(
            fileExporter: exporter,
            onLoadRemoteImage: (path) async {
              loadedImagePath = path;
              return base64Decode(
                'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lE'
                'QVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
              );
            },
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    controller.showState(
      const AppUiState(
        screen: AppScreen.work,
        activeThread: AgentThread(id: 'thread-links', title: '链接'),
        timeline: [
          TimelineEntry(
            id: 'links-1',
            kind: TimelineKind.agentMessage,
            text:
                '[内网下载]($url)\n\n'
                '[竖屏验收截图]($imagePath)',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(_maybeLinkRecognizer(tester, '内网下载'), isNull);
    final visibleUrlRecognizer = _linkRecognizer(tester, url);
    visibleUrlRecognizer.onTap!();
    await tester.pumpAndSettle();
    expect(find.text('打开链接'), findsOneWidget);
    expect(find.text(url), findsWidgets);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    _linkRecognizer(tester, '竖屏验收截图').onTap!();
    await tester.pumpAndSettle();
    expect(loadedImagePath, imagePath);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.text('latest-release.png'), findsOneWidget);
    final previewImage = tester.widget<Image>(find.byType(Image));
    expect(previewImage.fit, BoxFit.contain);
    final resizedImage = previewImage.image as ResizeImage;
    expect(resizedImage.width, 2048);
    expect(resizedImage.height, 2048);
    expect(resizedImage.policy, ResizeImagePolicy.fit);
    expect(exporter.beginCalls, 0);
    await tester.tap(find.byTooltip('关闭图片'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('expands reasoning and command details without changing rows', (
    tester,
  ) async {
    final manager = ServerConnectionManager();
    final controller = _LayoutController(_MemoryStore(), manager);
    addTearDown(() async {
      await manager.close();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: MaterialApp(theme: buildCodexTheme(), home: const WorkScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    controller.showState(
      const AppUiState(
        screen: AppScreen.work,
        activeThread: AgentThread(id: 'thread-2', title: '详情'),
        timeline: [
          TimelineEntry(
            id: 'reasoning-2',
            kind: TimelineKind.reasoning,
            text: '展开后的思考内容',
          ),
          TimelineEntry(
            id: 'command-2',
            kind: TimelineKind.command,
            status: 'completed',
            command: 'echo details',
            output: 'command output',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('展开后的思考内容'), findsNothing);
    expect(find.text('echo details'), findsNothing);
    await tester.tap(find.text('思考过程'));
    await tester.pumpAndSettle();
    expect(find.text('展开后的思考内容'), findsOneWidget);
    await tester.tap(find.text('运行了命令'));
    await tester.pumpAndSettle();
    expect(find.text('echo details'), findsOneWidget);
    expect(find.text('command output'), findsOneWidget);
  });

  testWidgets('distinguishes user messages without adding an identity label', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 840);
    addTearDown(tester.view.reset);
    final manager = ServerConnectionManager();
    final controller = _LayoutController(_MemoryStore(), manager);
    addTearDown(() async => manager.close());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: MaterialApp(theme: buildCodexTheme(), home: const WorkScreen()),
      ),
    );
    controller.showState(
      const AppUiState(
        screen: AppScreen.work,
        activeThread: AgentThread(id: 'thread-user-style', title: '消息样式'),
        timeline: [
          TimelineEntry(
            id: 'user-style-1',
            kind: TimelineKind.userMessage,
            text: '这是用户发送的内容',
          ),
          TimelineEntry(
            id: 'agent-style-1',
            kind: TimelineKind.agentMessage,
            text: '这是助手回复',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    final card = find.byKey(const Key('user-message-card-user-style-1'));
    final cardMaterial = tester.widget<Material>(card);
    final viewport = tester.getRect(find.byType(CustomScrollView));
    final cardRect = tester.getRect(card);
    expect(cardMaterial.color, const Color(0xFF2B3730));
    expect(cardRect.right, closeTo(viewport.right - 9, 1));
    expect(cardRect.width, lessThan(viewport.width));
    expect(find.text('你'), findsNothing);
  });

  testWidgets('shows command status and animates expanded details', (
    tester,
  ) async {
    final manager = ServerConnectionManager();
    final controller = _LayoutController(_MemoryStore(), manager);
    addTearDown(() async => manager.close());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: MaterialApp(theme: buildCodexTheme(), home: const WorkScreen()),
      ),
    );
    controller.showState(
      AppUiState(
        screen: AppScreen.work,
        activeThread: const AgentThread(
          id: 'thread-command-animation',
          title: '命令详情',
        ),
        timeline: [
          const TimelineEntry(
            id: 'command-animation-1',
            kind: TimelineKind.command,
            status: 'running',
            command: 'sleep 10',
            output: 'still running',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('运行中'), findsOneWidget);
    expect(find.textContaining('秒'), findsNothing);
    await tester.ensureVisible(find.text('运行了命令'));
    await tester.pump();
    await tester.tap(find.text('运行了命令'));
    await tester.pump();
    expect(find.text('sleep 10'), findsOneWidget);
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pump(const Duration(milliseconds: 150));
    expect(
      tester
          .widget<AnimatedSize>(
            find.byKey(const Key('command-details-animation')).first,
          )
          .duration,
      const Duration(milliseconds: 220),
    );
    expect(
      tester
          .widgetList<AnimatedRotation>(
            find.byKey(const Key('command-expand-arrow')),
          )
          .map((animation) => animation.turns),
      contains(0.5),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('renders original file-change cards and opens the full diff', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 2.75;
    tester.view.physicalSize = const Size(1220, 2712);
    addTearDown(tester.view.reset);

    final manager = ServerConnectionManager();
    final controller = _LayoutController(_MemoryStore(), manager);
    addTearDown(() async {
      await manager.close();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: MaterialApp(theme: buildCodexTheme(), home: const WorkScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    controller.showState(
      const AppUiState(
        screen: AppScreen.work,
        activeThread: AgentThread(
          id: 'thread-files',
          title: '文件修改',
          cwd: '/home/yan/ygy',
        ),
        aggregateDiff: '@@ -1 +1 @@\n-old\n+new',
        timeline: [
          TimelineEntry(
            id: 'files-1',
            kind: TimelineKind.fileChange,
            changes: [
              FileChange(
                path: '/tmp/a.dart',
                diff:
                    'diff --git a/tmp/a.dart b/tmp/a.dart\n'
                    '--- a/tmp/a.dart\n'
                    '+++ b/tmp/a.dart\n'
                    '@@ -1 +1 @@\n'
                    '-old\n'
                    '+new',
              ),
              FileChange(path: '/tmp/b.dart', diff: '+line'),
              FileChange(path: '/tmp/c.dart', diff: '-line'),
              FileChange(path: '/tmp/d.dart', diff: '+line'),
            ],
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('已编辑 4 个文件'), findsOneWidget);
    expect(find.text('再显示 1 个文件'), findsOneWidget);
    expect(find.text('工作区差异'), findsOneWidget);
    await tester.tap(find.text('/tmp/a.dart'));
    await tester.pumpAndSettle();
    expect(find.text('文件差异'), findsOneWidget);
    expect(find.text('/tmp/a.dart'), findsOneWidget);
    expect(find.text('-old'), findsOneWidget);
    expect(find.text('+new'), findsOneWidget);
    expect(
      tester.widget<Text>(find.text('+new')).style?.color,
      const Color(0xFFB3E6BC),
    );
    expect(
      tester
          .widget<Container>(find.byKey(const ValueKey('diff-line-added-5')))
          .color,
      const Color(0xFF17351E),
    );
    expect(
      tester.widget<Text>(find.text('-old')).style?.color,
      const Color(0xFFF4B1B5),
    );
    expect(
      tester
          .widget<Container>(find.byKey(const ValueKey('diff-line-removed-4')))
          .color,
      const Color(0xFF3B1D20),
    );
    expect(
      tester.widget<Text>(find.text('@@ -1 +1 @@')).style?.color,
      const Color(0xFFAFCBF1),
    );
    expect(
      tester.widget<Text>(find.text('+++ b/tmp/a.dart')).style?.color,
      codexMuted,
    );
    expect(find.byType(SelectionArea), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
