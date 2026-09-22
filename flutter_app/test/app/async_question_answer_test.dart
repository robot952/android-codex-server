import 'dart:async';
import 'dart:convert';

import 'package:codex_remote/src/agent/agent_connection_manager.dart';
import 'package:codex_remote/src/agent/remote_agent_client.dart';
import 'package:codex_remote/src/app/app_controller.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/persistence/profile_store.dart';
import 'package:codex_remote/src/ssh/server_connection_manager.dart';
import 'package:codex_remote/src/ssh/ssh_server_client.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/user_input_harness.dart' show QuestionHost, drain;

const _profile = ServerProfile(
  id: 'server',
  name: 'Question fixture',
  host: 'fixture.invalid',
  hostFingerprint: 'SHA256:fixture',
  workspacePromptShown: true,
);
const _thread = AgentThread(id: 'thread', title: 'Question test');
const _question = TimelineEntry(
  id: 'call_question',
  kind: TimelineKind.agentMessage,
  turnId: 'turn-question',
  questions: [
    InputQuestion(id: 'scope', header: '', question: '修改范围'),
    InputQuestion(id: 'notes', header: '', question: '补充说明'),
  ],
);
const _attachment = PendingAttachment(
  name: 'draft.txt',
  remotePath: '/fixture/draft.txt',
  mimeType: 'text/plain',
);
const _draft = '这段主输入框草稿应保留';

class _Store implements ProfileStore {
  _Store()
    : value = StoredProfiles(
        profiles: const [_profile],
        selectedProfileId: _profile.id,
        composerDrafts: {
          threadPreferenceKey(_profile.id, AgentKind.codex, _thread.id): _draft,
        },
      );

  StoredProfiles value;

  @override
  Future<StoredProfiles> load() async => value;

  @override
  Future<void> save(StoredProfiles value) async => this.value = value;
}

class _QuestionAgent extends Fake
    implements
        RemoteAgentClient,
        RemoteAgentTurnClient,
        RemoteAgentSteerClient {
  bool connected = false;
  Object? sendError;
  Completer<void>? connectGate;
  Completer<void>? sendGate;
  final calls =
      <
        ({
          String method,
          String threadId,
          String text,
          List<PendingAttachment> attachments,
        })
      >[];

  @override
  AgentKind get kind => AgentKind.codex;

  @override
  AgentCapabilities get capabilities =>
      const AgentCapabilities(models: false, steerTurn: true);

  @override
  bool get isConnected => connected;

  @override
  Stream<RemoteAgentEvent> get events => const Stream.empty();

  @override
  Future<void> connect(ServerProfile profile, RemoteServerClient host) async {
    if (connectGate case final gate?) await gate.future;
    connected = true;
  }

  @override
  Future<void> disconnect() async => connected = false;

  @override
  void close() => connected = false;

  @override
  Future<AgentThreadPage> listThreads({String? searchTerm}) async =>
      const AgentThreadPage(threads: [_thread]);

  @override
  Future<AgentSession> resumeThread(
    String threadId, {
    ApprovalMode approvalMode = ApprovalMode.requestApproval,
  }) async => const AgentSession(thread: _thread, timeline: [_question]);

  Future<void> _send(
    String method,
    String threadId,
    String text,
    List<PendingAttachment> attachments,
  ) async {
    calls.add((
      method: method,
      threadId: threadId,
      text: text,
      attachments: List.of(attachments),
    ));
    if (sendGate case final gate?) await gate.future;
    if (sendError case final error?) throw error;
  }

  @override
  Future<String> startTurn({
    required String threadId,
    required String text,
    List<PendingAttachment> attachments = const [],
    String? model,
    String? effort,
    ApprovalMode approvalMode = ApprovalMode.requestApproval,
    SandboxChoice? sandbox,
    String? cwd,
  }) async {
    await _send('start', threadId, text, attachments);
    return 'turn-answer';
  }

  @override
  Future<void> steerTurn({
    required String threadId,
    required String turnId,
    required String text,
    List<PendingAttachment> attachments = const [],
  }) => _send('steer', threadId, text, attachments);
}

class _Controller extends AppController {
  _Controller(super.store, super.connections, super.agents);

  void show(AppUiState value) => state = value;
}

Future<({_Controller controller, _QuestionAgent agent, _Store store})>
_harness() async {
  final store = _Store();
  final hosts = ServerConnectionManager(clientFactory: QuestionHost.new);
  final agent = _QuestionAgent();
  final agents = AgentConnectionManager(hosts, clientFactory: (_) => agent);
  final controller = _Controller(store, hosts, agents);
  addTearDown(() async {
    controller.dispose();
    await agents.close();
    await hosts.close();
  });
  await controller.requestConnect(_profile);
  await controller.ensureActiveAgent();
  controller.openThread(_thread);
  await drain();
  expect(controller.state.loading, isFalse);
  expect(controller.state.timeline, [_question]);
  controller.show(controller.state.copyWith(attachments: [_attachment]));
  return (controller: controller, agent: agent, store: store);
}

Future<bool> _answer(
  _Controller controller, {
  String profileId = 'server',
  AgentKind agent = AgentKind.codex,
  String threadId = 'thread',
  TimelineEntry entry = _question,
  Map<String, String> answers = const {'scope': '只修改当前页面'},
}) => controller.answerAsyncQuestion(
  profileId: profileId,
  agent: agent,
  threadId: threadId,
  entry: entry,
  answers: answers,
);

List<dynamic> _replies(String text) {
  const opening = '<send_user_message_question_reply>\n';
  const closing = '\n</send_user_message_question_reply>';
  expect(text, startsWith(opening));
  expect(text, endsWith(closing));
  return jsonDecode(
        text.substring(opening.length, text.length - closing.length),
      )
      as List<dynamic>;
}

void _expectComposerPreserved(_Controller controller, int nonce) {
  expect(controller.state.composerDraft, _draft);
  expect(controller.state.attachments, [_attachment]);
  expect(controller.state.composerClearNonce, nonce);
}

void main() {
  test(
    'async reply uses question identities and preserves draft and attachments',
    () async {
      final harness = await _harness();
      final controller = harness.controller;
      final nonce = controller.state.composerClearNonce;
      final result = await _answer(
        controller,
        answers: {'scope': '  当前页面  ', 'notes': '保留 "草稿"\n和附件'},
      );

      expect(result, isTrue);
      final call = harness.agent.calls.single;
      expect(call.method, 'start');
      expect(call.threadId, _thread.id);
      expect(call.attachments, isEmpty);
      expect(_replies(call.text), [
        {
          'questionItemId': '["request_user_input_async","call_question",0]',
          'question': '修改范围',
          'answer': '当前页面',
        },
        {
          'questionItemId': '["request_user_input_async","call_question",1]',
          'question': '补充说明',
          'answer': '保留 "草稿"\n和附件',
        },
      ]);
      _expectComposerPreserved(controller, nonce);
      expect(controller.state.submitting, isFalse);
      expect(controller.state.timeline.last.attachments, isEmpty);
      await drain();
      expect(harness.store.value.composerDrafts.values, contains(_draft));
      expect(
        harness.store.value.composerDrafts.values,
        isNot(contains(call.text)),
      );
    },
  );

  test(
    'reply steers an active turn and allows skipping individual questions',
    () async {
      final harness = await _harness();
      final controller = harness.controller;
      controller.show(
        controller.state.copyWith(running: true, activeTurnId: 'turn-running'),
      );
      final nonce = controller.state.composerClearNonce;

      expect(await _answer(controller, answers: {'notes': '继续处理'}), isTrue);

      expect(harness.agent.calls.single.method, 'steer');
      expect(_replies(harness.agent.calls.single.text).single, {
        'questionItemId': '["request_user_input_async","call_question",1]',
        'question': '补充说明',
        'answer': '继续处理',
      });
      expect(controller.state.activeTurnId, 'turn-running');
      _expectComposerPreserved(controller, nonce);
    },
  );

  test(
    'reply failure returns false and keeps composer and answer out of drafts',
    () async {
      final harness = await _harness();
      harness.agent.sendError = StateError('发送失败');
      final controller = harness.controller;
      final nonce = controller.state.composerClearNonce;

      expect(await _answer(controller), isFalse);

      expect(controller.state.timeline, [_question]);
      expect(controller.state.submitting, isFalse);
      expect(controller.state.running, isFalse);
      expect(controller.state.error, contains('发送失败'));
      _expectComposerPreserved(controller, nonce);
      await drain();
      expect(harness.store.value.composerDrafts.values, contains(_draft));
    },
  );

  test('stale scope, changed question and empty answers never send', () async {
    final harness = await _harness();
    final controller = harness.controller;
    expect(await _answer(controller, profileId: 'other'), isFalse);
    expect(await _answer(controller, agent: AgentKind.openCode), isFalse);
    expect(await _answer(controller, threadId: 'other'), isFalse);
    expect(
      await _answer(controller, entry: _question.copyWith(id: 'other')),
      isFalse,
    );
    expect(
      await _answer(controller, entry: _question.copyWith(turnId: 'other')),
      isFalse,
    );
    expect(
      await _answer(
        controller,
        entry: _question.copyWith(
          questions: [_question.questions.first.copyWith(question: '已变更的问题')],
        ),
      ),
      isFalse,
    );
    expect(await _answer(controller, answers: {}), isFalse);
    expect(await _answer(controller, answers: {'scope': '  '}), isFalse);
    expect(await _answer(controller, answers: {'unknown': '不要发'}), isFalse);
    expect(harness.agent.calls, isEmpty);
  });

  test('read-only, child and loading pages reject replies', () async {
    final harness = await _harness();
    final controller = harness.controller;
    final initial = controller.state;
    controller.show(
      initial.copyWith(activeThread: _thread.copyWith(isExternallyOwned: true)),
    );
    expect(await _answer(controller), isFalse);
    controller.show(initial.copyWith(screen: AppScreen.agentWork));
    expect(await _answer(controller), isFalse);
    controller.show(initial.copyWith(loading: true));
    expect(await _answer(controller), isFalse);
    expect(harness.agent.calls, isEmpty);
  });

  test('navigating during reconnect does not send to the new thread', () async {
    final harness = await _harness();
    final controller = harness.controller;
    harness.agent.connected = false;
    harness.agent.connectGate = Completer<void>();
    final answer = _answer(controller);
    await drain();
    expect(controller.state.submitting, isTrue);
    controller.show(
      controller.state.copyWith(
        activeThread: const AgentThread(id: 'other', title: 'Other thread'),
        timeline: const [],
        submitting: false,
        composerDraft: '另一个会话的草稿',
      ),
    );
    harness.agent.connectGate!.complete();

    expect(await answer, isFalse);
    expect(harness.agent.calls, isEmpty);
    expect(controller.state.activeThread!.id, 'other');
    expect(controller.state.timeline, isEmpty);
    expect(controller.state.composerDraft, '另一个会话的草稿');
  });

  test(
    'question replacement during reconnect cancels and clears pending state',
    () async {
      final harness = await _harness();
      final controller = harness.controller;
      harness.agent.connected = false;
      harness.agent.connectGate = Completer<void>();
      final answer = _answer(controller);
      await drain();
      final replacement = _question.copyWith(
        questions: [_question.questions.first.copyWith(question: '新的问题内容')],
      );
      controller.show(
        controller.state.copyWith(
          timeline: [replacement, controller.state.timeline.last],
        ),
      );
      harness.agent.connectGate!.complete();

      expect(await answer, isFalse);
      expect(harness.agent.calls, isEmpty);
      expect(controller.state.timeline, [replacement]);
      expect(controller.state.submitting, isFalse);
      expect(controller.state.running, isFalse);
      expect(controller.state.composerDraft, _draft);
    },
  );

  test('two quick answer submissions send only once', () async {
    final harness = await _harness();
    harness.agent.sendGate = Completer<void>();
    final first = _answer(harness.controller);
    await drain();
    expect(await _answer(harness.controller), isFalse);
    harness.agent.sendGate!.complete();
    expect(await first, isTrue);
    expect(harness.agent.calls, hasLength(1));
  });

  for (final fail in [false, true]) {
    test(
      'a delayed ${fail ? 'failed' : 'accepted'} answer preserves turn completion',
      () async {
        final harness = await _harness();
        final controller = harness.controller;
        controller.show(
          controller.state.copyWith(running: true, activeTurnId: 'active-turn'),
        );
        harness.agent.sendGate = Completer<void>();
        if (fail) harness.agent.sendError = StateError('delayed failure');
        final answer = _answer(controller);
        await drain();
        controller.show(
          controller.state.copyWith(
            running: false,
            activeTurnId: null,
            activeThread: _thread.copyWith(status: 'idle'),
            turnTiming: const TurnTiming(
              threadId: 'thread',
              turnId: 'active-turn',
              startedAtMillis: 1,
              completedAtMillis: 2,
            ),
          ),
        );
        harness.agent.sendGate!.complete();
        expect(await answer, !fail);
        expect(controller.state.running, isFalse);
        expect(controller.state.activeTurnId, isNull);
        expect(controller.state.activeThread!.status, 'idle');
        expect(controller.state.turnTiming!.completedAtMillis, 2);
      },
    );
  }

  test('ordinary send still consumes its draft and attachments', () async {
    final harness = await _harness();
    final controller = harness.controller;
    final nonce = controller.state.composerClearNonce;

    await controller.sendMessage();

    expect(harness.agent.calls.single.text, _draft);
    expect(harness.agent.calls.single.attachments, [_attachment]);
    expect(controller.state.composerDraft, isEmpty);
    expect(controller.state.attachments, isEmpty);
    expect(controller.state.composerClearNonce, nonce + 1);
  });
}
