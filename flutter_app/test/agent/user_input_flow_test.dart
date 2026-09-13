import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/agent/opencode_agent_client.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/user_input_harness.dart';

void main() {
  test(
    'Codex opts into Default questions on start and resume, not globally',
    () async {
      final h = QuestionHarness();
      addTearDown(h.close);
      await h.start();
      await h.client.startThread();
      for (final method in ['thread/start', 'thread/resume']) {
        final params =
            h.session.requests.firstWhere(
                  (x) => x['method'] == method,
                )['params']
                as Map;
        expect(params['config'], {
          'features.default_mode_request_user_input': true,
        });
        expect(
          params['approvalPolicy'],
          ApprovalMode.requestApproval.approvalPolicy,
        );
        expect(params.containsKey('collaborationMode'), isFalse);
      }
      expect(
        h.session.requests.any(
          (x) => x['method'].toString().startsWith('config/'),
        ),
        isFalse,
      );
    },
  );

  test('OpenCode never receives Codex question feature overrides', () async {
    final session = QuestionSession();
    final host = QuestionHost();
    await host.connect(questionProfile);
    final client = OpenCodeAgentClient(sessionOpener: (_, _) async => session);
    addTearDown(() async {
      await client.disconnect();
      client.close();
      host.close();
    });
    await client.connect(questionProfile, host);
    await client.startThread();
    await client.resumeThread('question-thread');
    for (final request in session.requests.where(
      (x) => ['thread/start', 'thread/resume'].contains(x['method']),
    )) {
      expect((request['params'] as Map).containsKey('config'), isFalse);
    }
  });

  test(
    'JSONL questions preserve options and custom input and roundtrip answers',
    () async {
      final h = QuestionHarness();
      addTearDown(h.close);
      await h.start();
      h.session.ask(id: 7);
      await drain();
      final prompt = h.controller.state.approval!;
      expect(prompt.kind, ApprovalKind.userInput);
      expect(prompt.questions.first.isOther, isTrue);
      expect(
        prompt.questions.first.options.first.description,
        '只修改当前页面，影响范围较小。',
      );
      await h.controller.answerApproval(
        true,
        answers: {'scope': '自定义范围', 'notes': '保留数据'},
      );
      await drain();
      expect(h.session.responses.single, {
        'id': 7,
        'result': {
          'answers': {
            'scope': {
              'answers': ['自定义范围'],
            },
            'notes': {
              'answers': ['保留数据'],
            },
          },
        },
      });
      expect(h.controller.state.approval, isNull);
      expect(h.controller.state.timeline.last.text, '已收到回答，继续执行。');
    },
  );

  test(
    'resolved requests distinguish numeric ids and clear only their thread',
    () async {
      final h = QuestionHarness();
      addTearDown(h.close);
      await h.start();
      h.session.ask(id: 7);
      h.session.ask(id: '7');
      h.session.ask(id: 'background', threadId: 'other');
      await drain();
      final expired = h.controller.state.approval!;
      expect(h.controller.state.approvalQueue, hasLength(2));
      h.session.resolve(7, threadId: 'other');
      await drain();
      expect(h.controller.state.approvalQueue, hasLength(2));
      h.session.resolve(7);
      await drain();
      expect(h.controller.state.approvalQueue.single.requestIdIsString, isTrue);
      await expectLater(
        h.client.answerApproval(expired, accept: true),
        throwsStateError,
      );
      await h.controller.answerApproval(true, expectedPrompt: expired);
      expect(h.session.responses, isEmpty);
      h.session.resolve('background', threadId: 'other');
      await drain();
      h.controller.openThread(const AgentThread(id: 'other'));
      await drain();
      expect(h.controller.state.approval, isNull);
    },
  );

  test(
    'skip returns no empty or preselected answers and disconnect invalidates prompt',
    () async {
      final h = QuestionHarness();
      addTearDown(h.close);
      await h.start();
      h.session.ask();
      await drain();
      await h.controller.answerApproval(
        false,
        answers: {'scope': 'must not send'},
      );
      await drain();
      expect(h.session.responses.single['result'], {'answers': {}});
      h.session.ask(id: 'next');
      await drain();
      final prompt = h.controller.state.approval!;
      await h.controller.disconnectProfile(questionProfile.id);
      await drain();
      expect(h.controller.state.approval, isNull);
      await expectLater(
        h.client.answerApproval(prompt, accept: true),
        throwsStateError,
      );
    },
  );
}
