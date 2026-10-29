import 'package:codex_remote/src/app/app_controller.dart';
import 'package:codex_remote/src/app/request_usage_controller.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/persistence/profile_store.dart';
import 'package:codex_remote/src/ssh/server_connection_manager.dart';
import 'package:codex_remote/src/ui/theme.dart';
import 'package:codex_remote/src/ui/work_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/support/request_usage_fixture.dart';

class _Store implements ProfileStore {
  @override
  Future<StoredProfiles> load() async => const StoredProfiles();
  @override
  Future<void> save(StoredProfiles value) async {}
}

class _Controller extends AppController {
  // ignore: use_super_parameters
  _Controller(ProfileStore store, ServerConnectionManager manager)
    : super(store, manager);
  void show(AppUiState value) => state = value;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Android processing strip opens filterable request statistics', (
    tester,
  ) async {
    final manager = ServerConnectionManager();
    final controller = _Controller(_Store(), manager);
    final usage = RequestUsageController(MemoryRequestUsageStore());
    addTearDown(manager.close);
    await usage.ready;
    usage.observe(
      profileId: 'server',
      agent: AgentKind.codex,
      provider: 'fixture-provider',
      threadId: 'thread',
      fallbackModel: 'gpt-6-astra',
      params: usageParams(
        input: 130900,
        output: 293,
        metrics: {
          'source': 'server',
          'firstTokenMillis': 350,
          'durationMillis': 650,
        },
      )..['tokenUsage']['last']['cachedInputTokens'] = 129600,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appControllerProvider.overrideWith((ref) => controller),
          requestUsageProvider.overrideWith((ref) => usage),
        ],
        child: MaterialApp(theme: buildCodexTheme(), home: const WorkScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    controller.show(
      AppUiState(
        screen: AppScreen.work,
        selectedProfileId: 'server',
        activeThread: const AgentThread(
          id: 'thread',
          title: '用量统计布局验证',
          modelProvider: 'fixture-provider',
        ),
        running: true,
        activeTurnId: 'turn-1',
        turnTiming: TurnTiming(
          threadId: 'thread',
          startedAtMillis: DateTime.now().millisecondsSinceEpoch - 363000,
        ),
        timeline: const [
          TimelineEntry(
            id: 'reply',
            kind: TimelineKind.agentMessage,
            text: '首字计时来自服务器。点击下方统计区域可以查看请求明细，并按模型和日期筛选。',
          ),
        ],
      ),
    );
    // WorkScreen reveals history after its initial bottom-anchor frames.
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final label = tester.getCenter(find.text('正在处理'));
    final elapsed = tester.getCenter(find.textContaining(RegExp(r'^6m \ds$')));
    expect(label.dy, closeTo(elapsed.dy, 1));
    expect(find.text('350ms').hitTestable(), findsOneWidget);
    debugPrint('REQUEST_USAGE_STRIP_SCREENSHOT_READY');
    await Future<void>.delayed(const Duration(seconds: 10));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('composer-input')));
    await Future<void>.delayed(const Duration(milliseconds: 900));
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.view.viewInsets.bottom, greaterThan(0));
    expect(
      tester
          .getBottomRight(find.byKey(const ValueKey('request-usage-summary')))
          .dy,
      lessThan(
        (tester.view.physicalSize.height - tester.view.viewInsets.bottom) /
            tester.view.devicePixelRatio,
      ),
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byKey(const ValueKey('request-usage-summary')));
    await tester.pumpAndSettle();
    expect(find.text('缓存命中率 99.0%'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('usage-model')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('gpt-6-astra').last);
    await tester.pumpAndSettle();
    expect(find.text('1 笔请求'), findsOneWidget);
    expect(find.text('缓存命中率 99.0%'), findsOneWidget);
    expect(find.textContaining('350ms'), findsOneWidget);
    expect(tester.takeException(), isNull);
    debugPrint('REQUEST_USAGE_HISTORY_SCREENSHOT_READY');
    await Future<void>.delayed(const Duration(seconds: 10));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
