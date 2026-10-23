import 'dart:async';
import 'dart:typed_data';

import 'package:codex_remote/src/app/app_controller.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/ui/theme.dart';
import 'package:codex_remote/src/ui/work_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import '../support/message_queue_harness.dart';

class _QueueImagePicker extends ImagePicker {
  Completer<List<XFile>>? gate;
  int calls = 0;

  @override
  Future<List<XFile>> pickMultiImage({
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    int? limit,
    bool requestFullMetadata = true,
  }) async {
    calls++;
    return gate?.future ?? [_image()];
  }

  static XFile _image() => XFile.fromData(
    Uint8List.fromList([137, 80, 78, 71]),
    name: 'queued-photo.png',
    path: '/fixture/queued-photo.png',
    mimeType: 'image/png',
  );
}

Future<QueueHarness> pumpQueueApp(
  WidgetTester tester, {
  AgentKind kind = AgentKind.codex,
  bool running = true,
  double textScale = 1,
  ImagePicker? imagePicker,
}) async {
  final h = (await tester.runAsync(() async => QueueHarness(kind: kind)))!;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(h.close);
  });
  await tester.runAsync(() => h.open(running: running));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appControllerProvider.overrideWith((_) => h.controller)],
      child: MaterialApp(
        theme: buildCodexTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: WorkScreen(imagePicker: imagePicker),
      ),
    ),
  );
  await pumpQueueEvents(tester);
  return h;
}

Future<void> pumpQueueEvents(WidgetTester tester) async {
  await tester.runAsync(queuePump);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

final queueComposer = find.byKey(const Key('composer-input'));
final queueSend = find.byKey(const Key('composer-send-button'));

Future<void> _send(WidgetTester tester, String text) async {
  await tester.enterText(queueComposer, text);
  await tester.pump();
  await tester.tap(queueSend);
  await pumpQueueEvents(tester);
}

Future<void> _edit(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(ValueKey('queued-message-menu:$id')));
  await pumpQueueEvents(tester);
  await tester.tap(find.text('编辑'));
  await pumpQueueEvents(tester);
}

Future<void> verifyImmediateSendingFeedback(
  WidgetTester tester, {
  required AgentKind kind,
  bool withAttachment = true,
}) async {
  final h = await pumpQueueApp(tester, kind: kind, running: false);
  final upload = Completer<void>();
  final reply = Completer<void>();
  h.host.uploadGate = upload;
  h.agent.replyGate = reply;
  addTearDown(() {
    if (!upload.isCompleted) upload.complete();
    if (!reply.isCompleted) reply.complete();
  });
  if (withAttachment) {
    await tester.runAsync(
      () => h.controller.uploadAttachments([
        LocalAttachmentUpload(
          name: 'pending.png',
          bytes: Uint8List.fromList([1, 2, 3]),
          mimeType: 'image/png',
        ),
      ]),
    );
    await pumpQueueEvents(tester);
    expect(h.host.uploads, isEmpty);
  } else {
    await tester.enterText(queueComposer, 'send now');
    await tester.pump();
  }
  await tester.tap(queueSend);
  await pumpQueueEvents(tester);
  expect(h.controller.state.messageSending, isTrue);
  expect(h.controller.state.queuedMessages, isEmpty);
  expect(find.byKey(const Key('queued-messages-panel')), findsNothing);
  expect(tester.widget<IconButton>(queueSend).tooltip, '发送中');
  expect(tester.widget<IconButton>(queueSend).onPressed, isNull);
  final indicator = find.byKey(const Key('composer-sending-indicator'));
  expect(find.byIcon(Icons.sync_rounded), findsOneWidget);
  final rotation = tester.widget<RotationTransition>(indicator).turns;
  final angle = rotation.value;
  await tester.pump(const Duration(milliseconds: 150));
  expect(rotation.value, isNot(angle));

  await tester.enterText(queueComposer, 'next draft');
  await tester.pump();
  await tester.tap(queueSend);
  await pumpQueueEvents(tester);
  expect(h.controller.state.composerDraft, 'next draft');
  expect(h.controller.state.queuedMessages, isEmpty);
  expect(h.agent.starts, hasLength(withAttachment ? 0 : 1));
  expect(tester.widget<IconButton>(queueSend).onPressed, isNull);

  upload.complete();
  await pumpQueueEvents(tester);
  expect(h.agent.starts, hasLength(1));
  expect(h.controller.state.running, isTrue);
  // turn/started can precede the start RPC response. Keep the send lock until
  // confirmation, even though the generic submitting flag has been cleared.
  expect(h.controller.state.messageSending, isTrue);
  expect(tester.widget<IconButton>(queueSend).onPressed, isNull);
  expect(indicator, findsOneWidget);
  expect(h.controller.state.queuedMessages, isEmpty);

  reply.complete();
  await pumpQueueEvents(tester);
  expect(h.controller.state.messageSending, isFalse);
  expect(indicator, findsNothing);
  expect(tester.widget<IconButton>(queueSend).tooltip, '发送');
  expect(tester.widget<IconButton>(queueSend).onPressed, isNotNull);
  expect(h.controller.state.composerDraft, 'next draft');
  await tester.tap(queueSend);
  await pumpQueueEvents(tester);
  expect(h.controller.state.queuedMessages.single.text, 'next draft');
  expect(h.agent.starts, hasLength(1));
  expect(h.host.uploads, withAttachment ? ['pending.png'] : isEmpty);
  expect(tester.widget<IconButton>(queueSend).tooltip, '停止');
  expect(tester.takeException(), isNull);
}

void main() {
  for (final kind in AgentKind.values) {
    for (final withAttachment in [false, true]) {
      testWidgets(
        '${kind.name}: immediate ${withAttachment ? 'attachment' : 'text'} send spins without queue flicker',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(420, 900);
          addTearDown(tester.view.reset);
          await verifyImmediateSendingFeedback(
            tester,
            kind: kind,
            withAttachment: withAttachment,
          );
        },
      );
    }
    testWidgets('${kind.name}: content sends to a multi-message queue', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(420, 900);
      addTearDown(tester.view.reset);
      final h = await pumpQueueApp(tester, kind: kind);
      expect(tester.widget<IconButton>(queueSend).tooltip, '停止');
      await tester.enterText(queueComposer, 'first queued');
      await tester.pump();
      expect(tester.widget<IconButton>(queueSend).tooltip, '发送');
      await tester.tap(queueSend);
      await pumpQueueEvents(tester);
      expect(h.controller.state.queuedMessages.single.text, 'first queued');
      expect(tester.widget<IconButton>(queueSend).tooltip, '停止');
      await tester.runAsync(
        () => h.controller.uploadAttachments([
          LocalAttachmentUpload(
            name: 'image-only.png',
            bytes: Uint8List.fromList([1, 2, 3]),
            mimeType: 'image/png',
          ),
        ]),
      );
      await pumpQueueEvents(tester);
      expect(tester.widget<IconButton>(queueSend).tooltip, '发送');
      await tester.tap(queueSend);
      await pumpQueueEvents(tester);
      final queue = h.controller.state.queuedMessages;
      expect(queue, hasLength(2));
      expect(queue.last.text, isEmpty);
      expect(queue.last.attachments.single.localUpload, isNotNull);
      expect(h.host.uploads, isEmpty);
      expect(h.agent.starts, isEmpty);
      expect(h.agent.steers, isEmpty);
      expect(find.byKey(const Key('background-agents-toggle')), findsNothing);
      h.agent.complete('turn-0');
      await pumpQueueEvents(tester);
      expect(h.agent.starts.single.text, 'first queued');
      expect(h.host.uploads, isEmpty);
      h.agent.complete(h.agent.starts.single.turnId);
      await pumpQueueEvents(tester);
      expect(h.agent.starts, hasLength(2));
      expect(h.host.uploads, ['image-only.png']);
      expect(h.controller.state.queuedMessages, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('idle empty composer is disabled and nonempty composer sends', (
    tester,
  ) async {
    final h = await pumpQueueApp(tester, running: false);
    expect(tester.widget<IconButton>(queueSend).tooltip, '发送');
    expect(tester.widget<IconButton>(queueSend).onPressed, isNull);
    await _send(tester, 'send now');
    expect(h.agent.starts.single.text, 'send now');
    expect(tester.widget<IconButton>(queueSend).tooltip, '停止');
  });

  for (final failUpload in [true, false]) {
    testWidgets(
      'send failure restores the button and draft: upload=$failUpload',
      (tester) async {
        final h = await pumpQueueApp(tester, running: false);
        h.host.failName = failUpload ? 'retry.png' : null;
        h.agent.failNext = !failUpload;
        await tester.runAsync(
          () => h.controller.uploadAttachments([
            LocalAttachmentUpload(
              name: 'retry.png',
              bytes: Uint8List.fromList([1, 2, 3]),
              mimeType: 'image/png',
            ),
          ]),
        );
        await _send(tester, 'retry draft');
        expect(h.controller.state.messageSending, isFalse);
        expect(h.controller.state.queuedMessages, isEmpty);
        expect(h.controller.state.attachments.single.name, 'retry.png');
        expect(
          tester.widget<TextField>(queueComposer).controller!.text,
          'retry draft',
        );
        expect(tester.widget<IconButton>(queueSend).tooltip, '发送');
        expect(tester.widget<IconButton>(queueSend).onPressed, isNotNull);
        expect(
          find.byKey(const Key('composer-sending-indicator')),
          findsNothing,
        );
        h.host.failName = null;
        await tester.tap(queueSend);
        await pumpQueueEvents(tester);
        expect(h.agent.starts.last.text, 'retry draft');
        expect(tester.widget<IconButton>(queueSend).tooltip, '停止');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'edit keeps position and composer draft; delete and steer bind correctly',
    (tester) async {
      final h = await pumpQueueApp(tester);
      await _send(tester, 'first');
      await _send(tester, 'second');
      final first = h.controller.state.queuedMessages.first.id;
      final second = h.controller.state.queuedMessages.last.id;
      await tester.enterText(queueComposer, 'draft stays');
      await _edit(tester, first);
      expect(h.controller.state.queuedMessages.first.editing, isTrue);
      await tester.enterText(
        find.byKey(const Key('queued-message-edit-input')),
        'edited first',
      );
      await tester.tap(find.byKey(const Key('queued-message-save')));
      await pumpQueueEvents(tester);
      expect(h.controller.state.queuedMessages.map((m) => m.id), [
        first,
        second,
      ]);
      expect(h.controller.state.queuedMessages.first.text, 'edited first');
      expect(h.controller.state.composerDraft, 'draft stays');
      expect(
        tester.widget<TextField>(queueComposer).controller!.text,
        'draft stays',
      );
      await _edit(tester, first);
      await tester.enterText(
        find.byKey(const Key('queued-message-edit-input')),
        'cancel this',
      );
      await tester.tap(find.text('取消'));
      await pumpQueueEvents(tester);
      expect(h.controller.state.queuedMessages.first.text, 'edited first');
      expect(h.controller.state.queuedMessages.first.editing, isFalse);
      await tester.tap(find.byKey(ValueKey('queued-message-steer:$second')));
      await pumpQueueEvents(tester);
      expect(h.agent.steers.single.text, 'second');
      expect(h.agent.starts, isEmpty);
      expect(h.controller.state.queuedMessages.single.id, first);
      await tester.tap(find.byKey(ValueKey('queued-message-delete:$first')));
      await pumpQueueEvents(tester);
      expect(h.controller.state.queuedMessages, isEmpty);
      expect(find.byKey(const Key('queued-messages-panel')), findsNothing);
      expect(h.controller.state.composerDraft, 'draft stays');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'editor adds and removes local images without uploading or mutating on cancel',
    (tester) async {
      final picker = _QueueImagePicker();
      final h = await pumpQueueApp(tester, imagePicker: picker);
      await _send(tester, 'with photo');
      final id = h.controller.state.queuedMessages.single.id;
      await _edit(tester, id);
      Future<void> addPhoto() async {
        await tester.tap(find.byKey(const Key('queued-edit-add-attachment')));
        await pumpQueueEvents(tester);
        await tester.tap(find.text('选择图片'));
        await pumpQueueEvents(tester);
      }

      await addPhoto();
      expect(find.text('queued-photo.png'), findsOneWidget);
      expect(h.controller.state.queuedMessages.single.attachments, isEmpty);
      expect(h.host.uploads, isEmpty);
      await tester.tap(find.byTooltip('移除附件'));
      await pumpQueueEvents(tester);
      expect(find.text('queued-photo.png'), findsNothing);
      await addPhoto();
      await tester.tap(find.text('取消'));
      await pumpQueueEvents(tester);
      expect(h.controller.state.queuedMessages.single.attachments, isEmpty);
      await _edit(tester, id);
      await addPhoto();
      await tester.tap(find.byKey(const Key('queued-message-save')));
      await pumpQueueEvents(tester);
      final photo = h.controller.state.queuedMessages.single.attachments.single;
      expect(photo.name, 'queued-photo.png');
      expect(photo.remotePath, isEmpty);
      expect(photo.localUpload, isNotNull);
      expect(h.host.uploads, isEmpty);
      expect(picker.calls, 3);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('picker result is discarded after navigating to another thread', (
    tester,
  ) async {
    final picker = _QueueImagePicker()..gate = Completer<List<XFile>>();
    final h = await pumpQueueApp(tester, imagePicker: picker);
    await tester.tap(find.byTooltip('添加附件').first);
    await pumpQueueEvents(tester);
    await tester.tap(find.text('选择图片'));
    await pumpQueueEvents(tester);
    expect(picker.calls, 1);
    await tester.runAsync(() async {
      h.controller.openThread(h.agent.threads['other-thread']!);
      await queueWait(
        () =>
            !h.controller.state.loading &&
            h.controller.state.activeThread?.id == 'other-thread',
      );
    });
    await pumpQueueEvents(tester);
    picker.gate!.complete([_QueueImagePicker._image()]);
    await pumpQueueEvents(tester);
    expect(h.controller.state.attachments, isEmpty);
    expect(h.host.uploads, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'multiple queued rows and editor fit narrow 2x text with keyboard',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 900);
      addTearDown(tester.view.reset);
      final h = await pumpQueueApp(tester, textScale: 2);
      await tester.runAsync(() async {
        for (var i = 0; i < 8; i++) {
          await h.send('queued message $i');
        }
      });
      await pumpQueueEvents(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await pumpQueueEvents(tester);
      expect(
        tester.getSize(find.byKey(const Key('queued-messages-panel'))).height,
        lessThanOrEqualTo(112),
      );
      expect(tester.getBottomRight(queueSend).dy, lessThanOrEqualTo(600));
      final first = h.controller.state.queuedMessages.first.id;
      await _edit(tester, first);
      expect(
        tester.getBottomRight(find.byKey(const Key('queued-message-save'))).dy,
        lessThanOrEqualTo(600),
      );
      await tester.tap(find.text('取消'));
      await pumpQueueEvents(tester);
      final last = h.controller.state.queuedMessages.last.id;
      await tester.drag(
        find.byKey(const Key('queued-messages-list')),
        const Offset(0, -1000),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(ValueKey('queued-message:$last')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
