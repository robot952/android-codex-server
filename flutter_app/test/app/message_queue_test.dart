import 'dart:async';
import 'dart:typed_data';

import 'package:codex_remote/src/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/message_queue_harness.dart';

LocalAttachmentUpload image(String name) => LocalAttachmentUpload(
  name: name,
  bytes: Uint8List.fromList([1, 2, 3]),
  mimeType: 'image/png',
);

void main() {
  for (final kind in AgentKind.values) {
    test(
      '${kind.name} immediate send stays out of queue until upload and RPC finish',
      () async {
        final h = QueueHarness(kind: kind);
        addTearDown(h.close);
        await h.open(running: false);
        final upload = h.host.uploadGate = Completer<void>();
        final reply = h.agent.replyGate = Completer<void>();
        addTearDown(() {
          if (!upload.isCompleted) upload.complete();
          if (!reply.isCompleted) reply.complete();
        });
        final visibleQueues = <List<QueuedMessage>>[];
        final removeListener = h.controller.addListener(
          (state) => visibleQueues.add(state.queuedMessages),
          fireImmediately: false,
        );
        addTearDown(removeListener);
        await h.controller.uploadAttachments([image('direct.png')]);
        final send = h.send('send now');
        await queueWait(() => h.host.uploads.isNotEmpty);
        expect(h.controller.state.messageSending, isTrue);
        expect(h.controller.state.queuedMessages, isEmpty);
        // A second activation cannot submit the next draft during this send.
        h.controller.setComposerDraft('next draft');
        await h.controller.sendMessage();
        expect(h.controller.state.composerDraft, 'next draft');
        expect(h.controller.state.queuedMessages, isEmpty);
        upload.complete();
        await queueWait(() => h.agent.starts.isNotEmpty);
        expect(h.controller.state.running, isTrue);
        // turn/started may clear generic submitting before the RPC is accepted.
        expect(h.controller.state.messageSending, isTrue);
        expect(h.controller.state.queuedMessages, isEmpty);
        reply.complete();
        await send;
        expect(h.controller.state.messageSending, isFalse);
        expect(visibleQueues.every((queue) => queue.isEmpty), isTrue);
        expect(h.host.uploads, ['direct.png']);
        expect(h.agent.starts, hasLength(1));
        await h.controller.sendMessage();
        expect(h.controller.state.queuedMessages.single.text, 'next draft');
        expect(h.agent.starts, hasLength(1));
      },
    );

    for (final failUpload in [false, true]) {
      test(
        '${kind.name} failed immediate ${failUpload ? 'upload' : 'RPC'} restores composer and clears busy',
        () async {
          final h = QueueHarness(kind: kind);
          addTearDown(h.close);
          await h.open(running: false);
          await h.controller.uploadAttachments([image('retry-direct.png')]);
          if (failUpload) {
            h.host.failName = 'retry-direct.png';
          } else {
            h.agent.failNext = true;
          }
          await h.send('preserve draft   ');
          expect(h.controller.state.messageSending, isFalse);
          expect(h.controller.state.queuedMessages, isEmpty);
          expect(h.controller.state.composerDraft, 'preserve draft   ');
          expect(
            h.controller.state.attachments.single.name,
            'retry-direct.png',
          );
          h.host.failName = null;
          await h.controller.sendMessage();
          expect(h.controller.state.messageSending, isFalse);
          expect(h.agent.starts.last.text, 'preserve draft');
          expect(
            h.host.uploads,
            failUpload
                ? ['retry-direct.png', 'retry-direct.png']
                : ['retry-direct.png'],
          );
        },
      );
    }

    test(
      '${kind.name} queues multiple messages and uploads only at FIFO dispatch',
      () async {
        final h = QueueHarness(kind: kind);
        addTearDown(h.close);
        await h.open();
        await h.controller.uploadAttachments([image('one.png')]);
        await h.send('first');
        await h.controller.uploadAttachments([image('two.png')]);
        await h.send('');
        await h.send('third');
        expect(h.host.uploads, isEmpty);
        expect(h.agent.starts, isEmpty);
        expect(h.agent.steers, isEmpty);
        expect(h.controller.state.queuedMessages.map((m) => m.text), [
          'first',
          '',
          'third',
        ]);
        h.agent.emit('item/completed', {
          'threadId': 'queue-thread',
          'turnId': 'turn-0',
          'item': {
            'id': 'answer',
            'type': 'agentMessage',
            'text': 'Final response',
            'phase': 'final_answer',
          },
        });
        await queuePump();
        expect(h.agent.starts, isEmpty);
        h.agent.complete('turn-0');
        await queueWait(
          () =>
              h.agent.starts.length == 1 &&
              h.controller.state.queuedMessages.length == 2,
        );
        expect(h.agent.starts.single.text, 'first');
        expect(h.host.uploads, ['one.png']);
        expect(
          h.agent.starts.single.attachments.single.remotePath,
          '/fixture/uploads/one.png',
        );
        h.agent.complete(
          'turn-0',
        ); // Duplicate old completion cannot drain turn-1.
        await queuePump();
        expect(h.agent.starts, hasLength(1));
        h.agent.complete('turn-1');
        await queueWait(
          () =>
              h.agent.starts.length == 2 &&
              h.controller.state.queuedMessages.length == 1,
        );
        expect(h.host.uploads, ['one.png', 'two.png']);
        expect(h.agent.starts.last.text, isEmpty);
        h.agent.complete('turn-2');
        await queueWait(
          () =>
              h.agent.starts.length == 3 &&
              h.controller.state.queuedMessages.isEmpty,
        );
        expect(h.agent.starts.last.text, 'third');
      },
    );

    test(
      '${kind.name} explicitly steers selected item with images without reordering remaining queue',
      () async {
        final h = QueueHarness(kind: kind);
        addTearDown(h.close);
        await h.open();
        await h.send('first');
        await h.controller.uploadAttachments([image('steer.png')]);
        await h.send('priority');
        final selected = h.controller.state.queuedMessages.last.id;
        await h.controller.steerQueuedMessage(selected);
        expect(h.agent.starts, isEmpty);
        expect(h.agent.steers.single.text, 'priority');
        expect(h.agent.steers.single.turnId, 'turn-0');
        expect(h.host.uploads, ['steer.png']);
        expect(h.controller.state.queuedMessages.single.text, 'first');
      },
    );
  }

  test(
    'editing freezes FIFO and preserves separate composer; deleting does not upload',
    () async {
      final h = QueueHarness();
      addTearDown(h.close);
      await h.open();
      await h.controller.uploadAttachments([image('discard.png')]);
      await h.send('first');
      await h.send('second');
      final first = h.controller.state.queuedMessages.first;
      expect(h.controller.beginEditQueuedMessage(first.id), isTrue);
      h.controller.setComposerDraft('new unrelated draft');
      h.agent.complete('turn-0');
      await queuePump();
      expect(h.agent.starts, isEmpty);
      expect(
        h.controller.updateQueuedMessage(
          first.id,
          text: 'edited',
          attachments: const [],
        ),
        isTrue,
      );
      await queueWait(() => h.agent.starts.length == 1);
      expect(h.agent.starts.single.text, 'edited');
      expect(h.controller.state.composerDraft, 'new unrelated draft');
      expect(h.host.uploads, isEmpty);
      h.controller.deleteQueuedMessage(
        h.controller.state.queuedMessages.single.id,
      );
      h.agent.complete('turn-1');
      await queuePump();
      expect(h.agent.starts, hasLength(1));
    },
  );

  test(
    'completion arriving before start RPC reply does not revive finished turn',
    () async {
      final h = QueueHarness();
      addTearDown(h.close);
      await h.open(running: false);
      h.agent.completeBeforeReply = true;
      final gate = h.agent.replyGate = Completer<void>();
      final send = h.send('fast');
      await queueWait(() => h.agent.starts.length == 1);
      await h.send('next');
      expect(h.agent.starts, hasLength(1));
      expect(h.controller.state.messageSending, isTrue);
      expect(h.controller.state.queuedMessages, isEmpty);
      expect(h.controller.state.composerDraft, 'next');
      h.agent.replyGate = null;
      gate.complete();
      await send;
      expect(h.controller.state.messageSending, isFalse);
      expect(h.controller.state.running, isFalse);
      expect(h.controller.state.activeTurnId, isNull);
      await h.controller.sendMessage();
      await queueWait(
        () =>
            h.agent.starts.length == 2 &&
            h.controller.state.queuedMessages.isEmpty,
      );
      expect(h.controller.state.running, isFalse);
      expect(h.controller.state.activeTurnId, isNull);
    },
  );

  test(
    'upload in flight preserves the next draft and attachments without submitting them',
    () async {
      final h = QueueHarness();
      addTearDown(h.close);
      await h.open(running: false);
      final gate = h.host.uploadGate = Completer<void>();
      await h.controller.uploadAttachments([image('first.png')]);
      final send = h.send('first');
      await queueWait(() => h.host.uploads.isNotEmpty);
      await h.controller.uploadAttachments([image('next.png')]);
      await h.send('next');
      h.controller.setComposerDraft('still typing');
      expect(h.controller.state.queuedMessages, isEmpty);
      expect(h.controller.state.messageSending, isTrue);
      expect(h.host.uploads, ['first.png']);
      h.host.uploadGate = null;
      gate.complete();
      await send;
      expect(h.controller.state.composerDraft, 'still typing');
      expect(h.controller.state.queuedMessages, isEmpty);
      expect(h.controller.state.attachments.single.name, 'next.png');
      expect(h.controller.state.messageSending, isFalse);
      h.controller.setComposerDraft('next');
      await h.controller.sendMessage();
      expect(h.controller.state.queuedMessages.single.text, 'next');
      h.agent.complete('turn-1');
      await queueWait(() => h.agent.starts.length == 2);
      expect(h.host.uploads, ['first.png', 'next.png']);
    },
  );

  test(
    'busy immediate send is isolated when switching and reopening threads',
    () async {
      final h = QueueHarness();
      addTearDown(h.close);
      await h.open(running: false);
      final gate = h.host.uploadGate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      await h.controller.uploadAttachments([image('held-direct.png')]);
      final send = h.send('direct');
      await queueWait(() => h.controller.state.messageSending);
      h.controller.openThread(h.agent.threads['other-thread']!);
      await queueWait(
        () =>
            h.controller.state.activeThread?.id == 'other-thread' &&
            !h.controller.state.loading,
      );
      expect(h.controller.state.messageSending, isFalse);
      expect(h.controller.state.queuedMessages, isEmpty);
      h.controller.openThread(h.agent.threads['queue-thread']!);
      await queueWait(
        () =>
            h.controller.state.activeThread?.id == 'queue-thread' &&
            !h.controller.state.loading,
      );
      expect(h.controller.state.messageSending, isTrue);
      expect(h.controller.state.queuedMessages, isEmpty);
      gate.complete();
      await send;
      expect(h.controller.state.messageSending, isFalse);
      expect(h.agent.starts.single.text, 'direct');
    },
  );

  test(
    'failed queued send pauses entire queue; explicit retry preserves uploaded image',
    () async {
      final h = QueueHarness();
      addTearDown(h.close);
      await h.open();
      await h.controller.uploadAttachments([image('retry.png')]);
      await h.send('first');
      await h.send('second');
      h.agent.failNext = true;
      h.agent.complete('turn-0');
      await queueWait(
        () => h.controller.state.queuedMessages.first.error != null,
      );
      expect(h.agent.starts, hasLength(1));
      expect(h.controller.state.queuedMessages, hasLength(2));
      await queuePump();
      expect(h.agent.starts, hasLength(1));
      await h.controller.steerQueuedMessage(
        h.controller.state.queuedMessages.first.id,
      );
      expect(h.agent.starts, hasLength(2));
      expect(h.host.uploads, ['retry.png']);
      expect(h.controller.state.queuedMessages.single.text, 'second');
    },
  );

  test('stop pauses queue even after late successful completion', () async {
    final h = QueueHarness();
    addTearDown(h.close);
    await h.open();
    await h.send('queued');
    await h.controller.stopMessage();
    h.agent.complete('turn-0');
    await queuePump();
    expect(h.agent.starts, isEmpty);
    expect(h.controller.state.queuedMessages.single.error, isNotNull);
    await h.controller.steerQueuedMessage(
      h.controller.state.queuedMessages.single.id,
    );
    expect(h.agent.starts.single.text, 'queued');
  });

  test(
    'switching threads preserves queue and background drain does not consume new draft',
    () async {
      final h = QueueHarness();
      addTearDown(h.close);
      await h.open();
      await h.send('background');
      h.controller.openThread(h.agent.threads['other-thread']!);
      await queueWait(
        () =>
            h.controller.state.activeThread?.id == 'other-thread' &&
            !h.controller.state.loading,
      );
      h.controller.setComposerDraft('other draft');
      expect(h.controller.state.queuedMessages, isEmpty);
      h.agent.complete('turn-0');
      await queueWait(() => h.agent.starts.length == 1);
      expect(h.agent.starts.single.threadId, 'queue-thread');
      expect(h.controller.state.activeThread?.id, 'other-thread');
      expect(h.controller.state.composerDraft, 'other draft');
      expect(
        h.controller.state.timeline.where((e) => e.text == 'background'),
        isEmpty,
      );
    },
  );

  test(
    'disconnect keeps queue paused and reconnect never auto sends',
    () async {
      final h = QueueHarness();
      addTearDown(h.close);
      await h.open();
      await h.send('queued');
      await h.agents.disconnect(h.profile.id, agent: h.profile.activeAgent);
      await queuePump();
      expect(h.controller.state.queuedMessages.single.error, isNotNull);
      h.agent.complete('turn-0');
      await queuePump();
      expect(h.agent.starts, isEmpty);
    },
  );

  test(
    'queue is bounded and rejects overflow without clearing draft',
    () async {
      final h = QueueHarness();
      addTearDown(h.close);
      await h.open();
      for (var i = 0; i < 20; i++) {
        await h.send('message $i');
      }
      await h.send('overflow');
      expect(h.controller.state.queuedMessages, hasLength(20));
      expect(h.controller.state.composerDraft, 'overflow');
      expect(h.controller.state.error, contains('队列已满'));
    },
  );

  test(
    'partial upload retry reuses successful files and retries only failed file',
    () async {
      final h = QueueHarness();
      addTearDown(h.close);
      await h.open();
      await h.controller.uploadAttachments([image('a.png'), image('b.png')]);
      await h.send('two files');
      h.host.failName = 'b.png';
      h.agent.complete('turn-0');
      await queueWait(
        () => h.controller.state.queuedMessages.single.error != null,
      );
      expect(h.host.uploads, ['a.png', 'b.png']);
      expect(h.agent.starts, isEmpty);
      expect(
        h.controller.state.queuedMessages.single.attachments,
        hasLength(2),
      );
      h.host.failName = null;
      await h.controller.steerQueuedMessage(
        h.controller.state.queuedMessages.single.id,
      );
      expect(h.host.uploads, ['a.png', 'b.png', 'b.png']);
      expect(h.agent.starts.single.attachments.map((a) => a.remotePath), [
        '/fixture/uploads/a.png',
        '/fixture/uploads/b.png',
      ]);
    },
  );

  test(
    'new sends cannot bypass an editing queue head after turn completes',
    () async {
      final h = QueueHarness();
      addTearDown(h.close);
      await h.open();
      await h.send('first');
      final first = h.controller.state.queuedMessages.single.id;
      expect(h.controller.beginEditQueuedMessage(first), isTrue);
      h.agent.complete('turn-0');
      await h.send('second');
      expect(h.agent.starts, isEmpty);
      expect(h.controller.state.queuedMessages.map((e) => e.text), [
        'first',
        'second',
      ]);
      h.controller.cancelEditQueuedMessage(first);
      await queueWait(() => h.agent.starts.length == 1);
      expect(h.agent.starts.single.text, 'first');
    },
  );

  for (final status in ['failed', 'interrupted', 'unknown', '']) {
    test('unconfirmed success status $status pauses queued sends', () async {
      final h = QueueHarness();
      addTearDown(h.close);
      await h.open();
      await h.send('pending');
      h.agent.complete('turn-0', status: status);
      await queuePump();
      expect(h.agent.starts, isEmpty);
      expect(h.controller.state.queuedMessages.single.error, isNotNull);
    });
  }

  test(
    'deleting failed upload retains other queue items without retrying files',
    () async {
      final h = QueueHarness();
      addTearDown(h.close);
      await h.open();
      await h.controller.uploadAttachments([image('a.png'), image('b.png')]);
      await h.send('delete this');
      await h.send('keep this');
      h.host.failName = 'b.png';
      h.agent.complete('turn-0');
      await queueWait(
        () => h.controller.state.queuedMessages.first.error != null,
      );
      h.controller.deleteQueuedMessage(
        h.controller.state.queuedMessages.first.id,
      );
      await queuePump();
      expect(h.host.uploads, ['a.png', 'b.png']);
      expect(h.agent.starts, isEmpty);
      expect(h.controller.state.queuedMessages.single.text, 'keep this');
    },
  );

  for (final disconnect in [false, true]) {
    test(
      '${disconnect ? 'disconnect' : 'stop'} during upload never starts a turn',
      () async {
        final h = QueueHarness();
        addTearDown(h.close);
        await h.open();
        await h.controller.uploadAttachments([image('held.png')]);
        await h.send('held');
        final gate = h.host.uploadGate = Completer<void>();
        h.agent.complete('turn-0');
        await queueWait(() => h.host.uploads.isNotEmpty);
        expect(h.controller.state.activeTurnId, isNull);
        if (disconnect) {
          await h.agents.disconnect(h.profile.id, agent: h.profile.activeAgent);
        } else {
          await h.controller.stopMessage();
        }
        h.host.uploadGate = null;
        gate.complete();
        await queueWait(
          () => !h.controller.state.queuedMessages.single.sending,
        );
        expect(h.agent.starts, isEmpty);
        expect(h.agent.steers, isEmpty);
        expect(h.agent.interrupted, isEmpty);
        expect(h.controller.state.queuedMessages.single.error, isNotNull);
        expect(
          h.controller.state.queuedMessages.single.attachments,
          hasLength(1),
        );
        expect(h.controller.state.running, isFalse);
      },
    );
  }

  test(
    'completed steer target during upload stays queued and does not revive running',
    () async {
      final h = QueueHarness();
      addTearDown(h.close);
      await h.open();
      await h.controller.uploadAttachments([image('late.png')]);
      await h.send('late steer');
      final gate = h.host.uploadGate = Completer<void>();
      final steer = h.controller.steerQueuedMessage(
        h.controller.state.queuedMessages.single.id,
      );
      await queueWait(() => h.host.uploads.isNotEmpty);
      h.agent.complete('turn-0');
      h.host.uploadGate = null;
      gate.complete();
      await steer;
      expect(h.agent.steers, isEmpty);
      expect(h.agent.starts, isEmpty);
      expect(h.controller.state.running, isFalse);
      expect(h.controller.state.activeTurnId, isNull);
      expect(
        h.controller.state.queuedMessages.single.error,
        contains('原回合已结束'),
      );
      await h.controller.steerQueuedMessage(
        h.controller.state.queuedMessages.single.id,
      );
      expect(h.agent.starts.single.text, 'late steer');
      expect(h.host.uploads, ['late.png']);
    },
  );

  test(
    'agent lanes isolate identical thread and turn ids while background queue drains',
    () async {
      final h = QueueHarness();
      addTearDown(h.close);
      await h.open();
      await h.send('codex queued');
      h.controller.backToThreadList();
      h.controller.selectAgent(AgentKind.openCode);
      await queueWait(() => h.clients[AgentKind.openCode]?.connected == true);
      await h.controller.ensureActiveAgent();
      final openCode = h.clients[AgentKind.openCode]!;
      h.controller.openThread(openCode.threads['queue-thread']!);
      await queueWait(
        () =>
            h.controller.state.activeAgent == AgentKind.openCode &&
            h.controller.state.activeThread?.id == 'queue-thread' &&
            !h.controller.state.loading,
      );
      expect(h.controller.state.queuedMessages, isEmpty);
      await h.send('opencode queued');
      h.controller.setComposerDraft('opencode draft');
      h.agent.complete('turn-0');
      await queueWait(() => h.agent.starts.isNotEmpty);
      expect(openCode.starts, isEmpty);
      expect(h.controller.state.queuedMessages.single.text, 'opencode queued');
      expect(h.controller.state.composerDraft, 'opencode draft');
      openCode.complete('turn-0');
      await queueWait(() => openCode.starts.isNotEmpty);
      expect(openCode.starts.single.text, 'opencode queued');
      expect(h.agent.starts.single.text, 'codex queued');
    },
  );

  test(
    'edited idle retry restores edited draft rather than original input',
    () async {
      final h = QueueHarness();
      addTearDown(h.close);
      await h.open(running: false);
      await h.controller.uploadAttachments([image('failed.png')]);
      final gate = h.host.uploadGate = Completer<void>();
      h.host.failName = 'failed.png';
      final sending = h.send('original draft   ');
      await queueWait(() => h.host.uploads.isNotEmpty);
      h.controller.setComposerDraft('separate new draft');
      gate.complete();
      await sending;
      final queued = h.controller.state.queuedMessages.single;
      expect(h.controller.state.composerDraft, 'separate new draft');
      h.controller.setComposerDraft('');
      expect(h.controller.beginEditQueuedMessage(queued.id), isTrue);
      expect(
        h.controller.updateQueuedMessage(
          queued.id,
          text: 'edited retry draft   ',
          attachments: queued.attachments,
        ),
        isTrue,
      );
      await h.controller.steerQueuedMessage(queued.id);
      expect(h.controller.state.queuedMessages, isEmpty);
      expect(h.controller.state.composerDraft, 'edited retry draft   ');
      expect(h.controller.state.attachments.single.name, 'failed.png');
      await queuePump();
      expect(
        h.store.value.composerDrafts.values,
        contains('edited retry draft   '),
      );
    },
  );

  test(
    'changing profile identity permanently invalidates old queue even after change back',
    () async {
      final h = QueueHarness();
      addTearDown(h.close);
      await h.open();
      await h.controller.uploadAttachments([image('old-host.png')]);
      await h.send('old target');
      final id = h.controller.state.queuedMessages.single.id;
      await h.controller.saveProfile(
        h.profile.copyWith(workspace: '/different'),
      );
      await h.controller.saveProfile(h.profile);
      await h.controller.requestConnect(h.profile);
      await h.controller.ensureActiveAgent();
      h.controller.openThread(h.agent.threads['queue-thread']!);
      await queueWait(
        () =>
            h.controller.state.screen == AppScreen.work &&
            h.controller.state.activeThread?.id == 'queue-thread' &&
            !h.controller.state.loading,
      );
      await h.controller.steerQueuedMessage(id);
      expect(h.agent.starts, isEmpty);
      expect(h.agent.steers, isEmpty);
      expect(h.host.uploads, isEmpty);
      expect(h.controller.state.error, contains('服务器配置已改变'));
      expect(h.controller.state.queuedMessages.single.id, id);
      h.controller.deleteQueuedMessage(id);
      expect(h.controller.state.queuedMessages, isEmpty);
    },
  );

  test(
    'async question reply shares dispatch lock until response even after navigation',
    () async {
      final h = QueueHarness();
      addTearDown(h.close);
      await h.open();
      await h.send('first queued');
      await h.send('second queued');
      h.agent.emit('item/completed', {
        'threadId': 'queue-thread',
        'turnId': 'turn-0',
        'item': {
          'id': 'question',
          'type': 'agentMessage',
          'text': 'Question',
          'delivery': 'async',
          'questions': [
            {'id': 'scope', 'header': '', 'question': 'Which scope?'},
          ],
        },
      });
      await queueWait(
        () => h.controller.state.timeline.any((e) => e.id == 'question'),
      );
      final question = h.controller.state.timeline.firstWhere(
        (e) => e.id == 'question',
      );
      expect(question.questions, hasLength(1));
      final gate = h.agent.replyGate = Completer<void>();
      final reply = h.controller.answerAsyncQuestion(
        profileId: h.profile.id,
        agent: AgentKind.codex,
        threadId: 'queue-thread',
        entry: question,
        answers: {question.questions.single.id: 'all'},
      );
      await queueWait(() => h.agent.steers.length == 1);
      h.agent.complete('turn-0');
      h.controller.openThread(h.agent.threads['other-thread']!);
      await queueWait(
        () =>
            h.controller.state.activeThread?.id == 'other-thread' &&
            !h.controller.state.loading,
      );
      h.controller.setComposerDraft('other draft');
      await queuePump();
      expect(h.agent.starts, isEmpty);
      h.agent.replyGate = null;
      gate.complete();
      expect(await reply, isTrue);
      await queueWait(() => h.agent.starts.length == 1);
      expect(h.agent.starts.single.text, 'first queued');
      expect(h.controller.state.composerDraft, 'other draft');
      expect(h.agent.steers.single.attachments, isEmpty);
      await queuePump();
      expect(h.agent.starts, hasLength(1));
    },
  );
}
