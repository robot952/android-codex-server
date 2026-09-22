import 'package:codex_remote/src/app/app_controller.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/persistence/profile_store.dart';
import 'package:codex_remote/src/ssh/server_connection_manager.dart';
import 'package:codex_remote/src/ui/theme.dart';
import 'package:codex_remote/src/ui/work_screen.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryStore implements ProfileStore {
  @override
  Future<StoredProfiles> load() async => const StoredProfiles();

  @override
  Future<void> save(StoredProfiles profiles) async {}
}

class _QuestionController extends AppController {
  _QuestionController(ServerConnectionManager manager)
    : super(_MemoryStore(), manager);

  final sentMessages = <String>[];
  final answers = <Map<String, String>>[];
  bool replyAccepted = true;

  void show(AppUiState value) => state = value;

  @override
  Future<void> sendMessage({String? text}) async {
    sentMessages.add(text ?? state.composerDraft);
  }

  @override
  Future<bool> answerAsyncQuestion({
    required String profileId,
    required AgentKind agent,
    required String threadId,
    required TimelineEntry entry,
    required Map<String, String> answers,
  }) async {
    expect(profileId, 'profile-1');
    expect(agent, AgentKind.codex);
    expect(threadId, 'thread-1');
    expect(entry.id, _question.id);
    this.answers.add(Map.of(answers));
    return replyAccepted;
  }
}

const _question = TimelineEntry(
  id: 'async-scope',
  kind: TimelineKind.agentMessage,
  turnId: 'turn-1',
  text: '代码改动范围',
  questions: [
    InputQuestion(
      id: 'scope',
      header: '范围',
      question: '代码改动范围',
      isOther: true,
      options: [
        InputOption(label: '先出评审报告（推荐）', description: '暂不修改代码'),
        InputOption(label: '评审后直接提交必要代码修改', description: '完成后提交'),
      ],
    ),
  ],
);

AppUiState _state({
  List<TimelineEntry> timeline = const [_question],
  String threadId = 'thread-1',
  bool readOnly = false,
  AppScreen screen = AppScreen.work,
  bool loading = false,
  bool running = false,
}) => AppUiState(
  screen: screen,
  selectedProfileId: 'profile-1',
  activeThread: AgentThread(
    id: threadId,
    title: '问题测试',
    isExternallyOwned: readOnly,
  ),
  activeAgentCapabilities: AgentCapabilities.codex,
  agentConnectionStates: {
    const AgentConnectionKey(profileId: 'profile-1', agent: AgentKind.codex):
        const ConnectionState(phase: ConnectionPhase.connected),
  },
  composerDraft: '保留原有草稿',
  timeline: timeline,
  loading: loading,
  running: running,
  activeTurnId: running ? 'turn-1' : null,
);

Future<_QuestionController> _pump(
  WidgetTester tester,
  AppUiState initial,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(420, 840);
  addTearDown(tester.view.reset);
  final manager = ServerConnectionManager();
  final controller = _QuestionController(manager);
  addTearDown(manager.close);
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  controller.show(initial);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appControllerProvider.overrideWith((_) => controller)],
      child: MaterialApp(theme: buildCodexTheme(), home: const WorkScreen()),
    ),
  );
  if (initial.loading) {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  } else {
    await tester.pumpAndSettle();
  }
  return controller;
}

Finder get _dialog => find.byType(Dialog);

Finder _dialogText(String text) =>
    find.descendant(of: _dialog, matching: find.text(text));

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('回答问题'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'updated question closes stale form and reopens current options',
    (tester) async {
      final controller = await _pump(tester, _state());
      await _open(tester);
      await tester.tap(_dialogText('先出评审报告（推荐）'));
      controller.show(
        _state(
          timeline: [
            _question.copyWith(
              questions: [
                _question.questions.single.copyWith(
                  question: '新版问题',
                  options: const [InputOption(label: '新版选项')],
                ),
              ],
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(_dialog, findsNothing);
      await _open(tester);
      expect(_dialogText('新版选项'), findsOneWidget);
      expect(_dialogText('先出评审报告（推荐）'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('submit-async-question')),
            )
            .onPressed,
        isNull,
      );
      expect(controller.answers, isEmpty);
    },
  );

  testWidgets(
    'replayed structured answer marks the historical question answered',
    (tester) async {
      await _pump(
        tester,
        _state(
          timeline: [
            _question,
            const TimelineEntry(
              id: 'server-reply',
              kind: TimelineKind.userMessage,
              text:
                  '<send_user_message_question_reply>\n[{"questionItemId":"[\\"request_user_input_async\\",\\"async-scope\\",0]","question":"代码改动范围","answer":"只审查"}]\n</send_user_message_question_reply>',
            ),
          ],
        ),
      );
      expect(find.text('已回答'), findsOneWidget);
      expect(
        find.textContaining('<send_user_message_question_reply>'),
        findsNothing,
      );
      expect(_dialog, findsNothing);
    },
  );

  testWidgets('historical questions stay compact until explicitly opened', (
    tester,
  ) async {
    await _pump(tester, _state());

    expect(_dialog, findsNothing);
    expect(find.text('代码改动范围'), findsOneWidget);
    expect(find.text('回答问题'), findsOneWidget);
    expect(find.text('先出评审报告（推荐）'), findsNothing);
    expect(find.text('输入回答'), findsNothing);

    await _open(tester);

    expect(_dialog, findsOneWidget);
    expect(_dialogText('先出评审报告（推荐）'), findsOneWidget);
    expect(_dialogText('跳过'), findsOneWidget);
    expect(_dialogText('发送'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('close preserves the answer draft and skip does not send', (
    tester,
  ) async {
    final controller = await _pump(tester, _state());
    await _open(tester);
    await tester.enterText(
      find.descendant(of: _dialog, matching: find.byType(TextField)).first,
      '仅检查启动逻辑',
    );
    await tester.tap(
      find.descendant(of: _dialog, matching: find.byIcon(Icons.close)),
    );
    await tester.pumpAndSettle();

    expect(_dialog, findsNothing);
    expect(controller.sentMessages, isEmpty);
    expect(controller.answers, isEmpty);
    await _open(tester);
    expect(find.text('仅检查启动逻辑'), findsOneWidget);
    await tester.tap(_dialogText('跳过'));
    await tester.pumpAndSettle();

    expect(_dialog, findsNothing);
    expect(controller.sentMessages, isEmpty);
    expect(controller.answers, isEmpty);
    expect(controller.state.composerDraft, '保留原有草稿');
    expect(find.text('回答问题'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a new live question opens once and remains closed after updates',
    (tester) async {
      final controller = await _pump(tester, _state(timeline: const []));
      controller.show(_state(running: true));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(_dialog, findsOneWidget);
      await tester.tap(
        find.descendant(of: _dialog, matching: find.byIcon(Icons.close)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      controller.show(
        _state(
          timeline: [
            _question,
            const TimelineEntry(
              id: 'ongoing',
              kind: TimelineKind.agentMessage,
              text: '我继续检查其他代码。',
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(_dialog, findsNothing);
      expect(find.text('回答问题'), findsOneWidget);
      expect(controller.sentMessages, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('history loaded after the first frame does not auto-open', (
    tester,
  ) async {
    final controller = await _pump(
      tester,
      _state(timeline: const [], loading: true),
    );
    controller.show(_state());
    await tester.pumpAndSettle();
    expect(_dialog, findsNothing);
    expect(find.text('回答问题'), findsOneWidget);
  });

  testWidgets('switching threads closes the old question without sending', (
    tester,
  ) async {
    final controller = await _pump(tester, _state());
    await _open(tester);
    controller.show(_state(threadId: 'thread-2', timeline: const []));
    await tester.pumpAndSettle();
    expect(_dialog, findsNothing);
    expect(controller.sentMessages, isEmpty);
    expect(controller.answers, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('read-only and child threads never offer answer controls', (
    tester,
  ) async {
    final controller = await _pump(tester, _state(readOnly: true));
    expect(_dialog, findsNothing);
    expect(find.text('先出评审报告（推荐）'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    controller.show(_state(screen: AppScreen.agentWork));
    await tester.pumpAndSettle();
    expect(_dialog, findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(controller.sentMessages, isEmpty);
    expect(controller.answers, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('losing write access closes a visible question', (tester) async {
    final controller = await _pump(tester, _state());
    await _open(tester);
    controller.show(_state(readOnly: true));
    await tester.pumpAndSettle();
    expect(_dialog, findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(controller.sentMessages, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'option answers use the question action and keep composer input',
    (tester) async {
      final controller = await _pump(tester, _state());
      await _open(tester);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('submit-async-question')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(_dialogText('先出评审报告（推荐）'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('submit-async-question')));
      await tester.pumpAndSettle();

      expect(_dialog, findsNothing);
      expect(controller.answers, [
        {'scope': '先出评审报告（推荐）'},
      ]);
      expect(controller.sentMessages, isEmpty);
      expect(controller.state.composerDraft, '保留原有草稿');
      expect(find.text('已回答'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a failed answer retains custom text and can be retried', (
    tester,
  ) async {
    final controller = await _pump(tester, _state());
    controller.replyAccepted = false;
    await _open(tester);
    await tester.enterText(
      find.byKey(const ValueKey('async-answer-scope')),
      '先审查启动逻辑',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('submit-async-question')));
    await tester.pumpAndSettle();
    expect(_dialogText('回复失败，请检查连接后重试'), findsOneWidget);
    expect(find.text('先审查启动逻辑'), findsOneWidget);
    controller.replyAccepted = true;
    await tester.tap(find.byKey(const Key('submit-async-question')));
    await tester.pumpAndSettle();
    expect(_dialog, findsNothing);
    expect(controller.answers, hasLength(2));
    expect(controller.answers.last, {'scope': '先审查启动逻辑'});
    expect(tester.takeException(), isNull);
  });

  testWidgets('dialog actions fit above the keyboard with enlarged text', (
    tester,
  ) async {
    await _pump(tester, _state());
    await _open(tester);
    tester.view.physicalSize = const Size(390, 844);
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.tap(find.byKey(const ValueKey('async-answer-scope')));
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    await tester.enterText(
      find.byKey(const ValueKey('async-answer-scope')),
      '保留原有行为',
    );
    await tester.pumpAndSettle();
    expect(
      tester.getBottomRight(find.byKey(const Key('submit-async-question'))).dy,
      lessThanOrEqualTo(524),
    );
    expect(tester.takeException(), isNull);
  });
}
