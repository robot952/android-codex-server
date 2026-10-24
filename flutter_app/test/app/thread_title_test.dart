import 'dart:async';
import 'dart:typed_data';

import 'package:codex_remote/src/agent/remote_agent_client.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/message_queue_harness.dart';

class TitleAgent extends QueueAgent
    implements
        RemoteAgentThreadCreateClient,
        RemoteAgentThreadMutationClient,
        RemoteAgentTitleClient {
  TitleAgent(super.kind);
  static const fallback = '首条消息的旧截断标题';
  final titleReply = Completer<String>();
  final titleCalls = <({String text, String? model})>[];
  final names = <({String threadId, String name})>[];
  Completer<void>? renameGate;
  var created = 0;

  @override
  AgentCapabilities get capabilities => const AgentCapabilities(
    renameThread: true,
    interruptTurn: true,
    steerTurn: true,
  );

  @override
  Future<AgentSession> startThread({
    String? cwd,
    String? model,
    ApprovalMode approvalMode = ApprovalMode.requestApproval,
    SandboxChoice? sandbox,
  }) async {
    final thread = AgentThread(
      id: 'new-thread-${++created}',
      title: fallback,
      cwd: cwd ?? '/fixture',
    );
    threads[thread.id] = thread;
    return AgentSession(thread: thread, timeline: const []);
  }

  @override
  Future<String> generateThreadTitle(
    ServerProfile profile, {
    required String text,
    String? model,
  }) async {
    titleCalls.add((text: text, model: model));
    return titleReply.future;
  }

  @override
  Future<void> setThreadName(String threadId, String name) async {
    names.add((threadId: threadId, name: name));
    await renameGate?.future;
    threads[threadId] = threads[threadId]!.copyWith(title: name);
  }
}

void main() {
  QueueHarness harness(AgentKind kind) {
    final h = QueueHarness(kind: kind, clientFactory: TitleAgent.new);
    addTearDown(() async {
      final agent = h.agent as TitleAgent;
      if (!agent.titleReply.isCompleted) agent.titleReply.complete('未使用的摘要');
      if (agent.renameGate case final gate? when !gate.isCompleted) {
        gate.complete();
      }
      await h.close();
    });
    return h;
  }

  for (final kind in AgentKind.values) {
    test(
      '${kind.name} uses first accepted text and selected model without blocking send',
      () async {
        final h = harness(kind);
        await h.open(running: false);
        await h.controller.createThread();
        final agent = h.agent as TitleAgent;
        h.controller.selectThreadModel('fixture-selected-model');
        await h.send('请帮我实现多消息队列和图片附件');
        await queueWait(() => agent.titleCalls.isNotEmpty);
        expect(agent.titleCalls.single, (
          text: '请帮我实现多消息队列和图片附件',
          model: kind == AgentKind.openCode
              ? 'custom-api/fixture-selected-model'
              : 'fixture-selected-model',
        ));
        expect(h.controller.state.messageSending, isFalse);
        expect(h.controller.state.running, isTrue);
        expect(h.controller.state.activeThread?.title, TitleAgent.fallback);
        final timeline = h.controller.state.timeline;
        await h.send('这是第二条，应该只排队');
        expect(h.controller.state.queuedMessages, hasLength(1));
        expect(agent.titleCalls, hasLength(1));
        expect(agent.starts, hasLength(1));
        agent.titleReply.complete('多消息队列与图片附件');
        await queueWait(
          () => h.controller.state.activeThread?.title == '多消息队列与图片附件',
        );
        expect(h.controller.state.timeline, timeline);
        expect(
          h.controller.state.threads
              .firstWhere((t) => t.id == 'new-thread-1')
              .title,
          '多消息队列与图片附件',
        );
        expect(agent.names.single.threadId, 'new-thread-1');
        h.controller.backToThreadList();
        h.controller.openThread(agent.threads['new-thread-1']!);
        await queueWait(
          () =>
              h.controller.state.activeThread?.id == 'new-thread-1' &&
              !h.controller.state.loading,
        );
        expect(h.controller.state.activeThread?.title, '多消息队列与图片附件');
        expect(agent.titleCalls, hasLength(1));
      },
    );

    test(
      '${kind.name} failure preserves fallback and does not retry on later messages',
      () async {
        final h = harness(kind);
        await h.open(running: false);
        await h.controller.createThread();
        final agent = h.agent as TitleAgent;
        await h.send('第一条消息');
        agent.titleReply.completeError(StateError('fixture request failed'));
        await queuePump();
        expect(h.controller.state.error, isNull);
        expect(h.controller.state.activeThread?.title, TitleAgent.fallback);
        expect(agent.names, isEmpty);
        agent.complete(agent.starts.single.turnId, threadId: 'new-thread-1');
        await h.send('第二条消息');
        expect(agent.titleCalls, hasLength(1));
      },
    );

    test(
      '${kind.name} existing history and attachment-only first message do not trigger titles',
      () async {
        final h = harness(kind);
        await h.open(running: false);
        final agent = h.agent as TitleAgent;
        await h.send('给已有会话续聊');
        expect(agent.titleCalls, isEmpty);
        await h.controller.createThread();
        await h.controller.uploadAttachments([
          LocalAttachmentUpload(
            name: 'first.png',
            mimeType: 'image/png',
            bytes: Uint8List.fromList([1, 2, 3]),
          ),
        ]);
        await h.send('');
        expect(agent.titleCalls, isEmpty);
        agent.complete(agent.starts.last.turnId, threadId: 'new-thread-1');
        await h.send('稍后补充的文字');
        expect(agent.titleCalls, isEmpty);
      },
    );

    test(
      '${kind.name} failed send does not consume first accepted message',
      () async {
        final h = harness(kind);
        await h.open(running: false);
        await h.controller.createThread();
        final agent = h.agent as TitleAgent;
        agent.failNext = true;
        await h.send('未发送成功的文字');
        expect(agent.titleCalls, isEmpty);
        await h.send('实际被接受的第一条消息');
        expect(agent.titleCalls.single.text, '实际被接受的第一条消息');
      },
    );
  }

  test('manual rename wins over a late generated title', () async {
    final h = harness(AgentKind.codex);
    await h.open(running: false);
    await h.controller.createThread();
    final agent = h.agent as TitleAgent;
    await h.send('首条消息');
    await h.controller.renameActiveThread('我自己取的标题');
    agent.titleReply.complete('自动生成的标题');
    await queuePump();
    expect(agent.names.map((n) => n.name), ['我自己取的标题']);
    expect(h.controller.state.activeThread?.title, '我自己取的标题');
  });

  test(
    'manual rename is serialized after an in-flight automatic rename',
    () async {
      final h = harness(AgentKind.codex);
      await h.open(running: false);
      await h.controller.createThread();
      final agent = h.agent as TitleAgent;
      final gate = agent.renameGate = Completer<void>();
      await h.send('首条消息');
      agent.titleReply.complete('自动标题');
      await queueWait(() => agent.names.isNotEmpty);
      final rename = h.controller.renameActiveThread('手动标题');
      await queuePump();
      expect(agent.names, hasLength(1));
      gate.complete();
      await rename;
      expect(agent.names.map((n) => n.name), ['自动标题', '手动标题']);
      expect(agent.threads['new-thread-1']?.title, '手动标题');
      expect(h.controller.state.activeThread?.title, '手动标题');
    },
  );

  test(
    'late title updates original thread without changing another visible thread',
    () async {
      final h = harness(AgentKind.codex);
      await h.open(running: false);
      await h.controller.createThread();
      final agent = h.agent as TitleAgent;
      await h.send('首条消息');
      h.controller.openThread(agent.threads['other-thread']!);
      await queueWait(
        () =>
            h.controller.state.activeThread?.id == 'other-thread' &&
            !h.controller.state.loading,
      );
      agent.titleReply.complete('后台生成的标题');
      await queueWait(() => agent.names.isNotEmpty);
      await queuePump();
      expect(h.controller.state.activeThread?.title, 'Other');
      expect(
        h.controller.state.threads
            .firstWhere((t) => t.id == 'new-thread-1')
            .title,
        '后台生成的标题',
      );
    },
  );

  test(
    'disconnect discards a late title rather than renaming through a new connection',
    () async {
      final h = harness(AgentKind.codex);
      await h.open(running: false);
      await h.controller.createThread();
      final agent = h.agent as TitleAgent;
      await h.send('首条消息');
      await h.controller.disconnectProfile(h.profile.id);
      agent.titleReply.complete('过期的标题');
      await queuePump();
      expect(agent.names, isEmpty);
      expect(h.controller.state.error, isNull);
    },
  );
}
