import 'dart:async';
import 'dart:typed_data';

import 'package:codex_remote/src/agent/agent_connection_manager.dart';
import 'package:codex_remote/src/agent/codex_protocol.dart';
import 'package:codex_remote/src/agent/remote_agent_client.dart';
import 'package:codex_remote/src/app/app_controller.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/persistence/profile_store.dart';
import 'package:codex_remote/src/ssh/server_connection_manager.dart';
import 'package:codex_remote/src/ssh/ssh_server_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'user_input_harness.dart' show QuestionHost;

class QueueStore implements ProfileStore {
  QueueStore(ServerProfile profile)
    : value = StoredProfiles(
        profiles: [profile],
        selectedProfileId: profile.id,
      );
  StoredProfiles value;
  @override
  Future<StoredProfiles> load() async => value;
  @override
  Future<void> save(StoredProfiles value) async {
    this.value = value;
  }
}

class QueueHost extends QuestionHost implements RemoteServerAttachmentClient {
  final List<String> uploads = [];
  Completer<void>? uploadGate;
  String? failName;
  @override
  Future<String> uploadAttachment(
    String name,
    Uint8List bytes, {
    int maxBytes = maxRemoteAttachmentBytes,
  }) async {
    uploads.add(name);
    await uploadGate?.future;
    if (name == failName) throw StateError('上传失败');
    return '/fixture/uploads/$name';
  }
}

class QueueCall {
  QueueCall(this.threadId, this.turnId, this.text, this.attachments);
  final String threadId, turnId, text;
  final List<PendingAttachment> attachments;
}

class QueueAgent extends Fake
    implements
        RemoteAgentClient,
        RemoteAgentTurnClient,
        RemoteAgentSteerClient {
  QueueAgent(this.kind);
  @override
  final AgentKind kind;
  bool connected = false;
  bool failNext = false;
  bool completeBeforeReply = false;
  Completer<void>? replyGate;
  final starts = <QueueCall>[];
  final steers = <QueueCall>[];
  final interrupted = <String>[];
  final eventController = StreamController<RemoteAgentEvent>.broadcast(
    sync: true,
  );
  final threads = <String, AgentThread>{
    'queue-thread': const AgentThread(
      id: 'queue-thread',
      title: 'Queue',
      cwd: '/fixture',
      status: 'active',
      activeTurnId: 'turn-0',
    ),
    'other-thread': const AgentThread(
      id: 'other-thread',
      title: 'Other',
      cwd: '/fixture',
    ),
  };
  @override
  bool get isConnected => connected;
  @override
  AgentCapabilities get capabilities =>
      const AgentCapabilities(interruptTurn: true, steerTurn: true);
  @override
  Stream<RemoteAgentEvent> get events => eventController.stream;
  @override
  Future<void> connect(ServerProfile profile, RemoteServerClient host) async {
    connected = true;
  }

  @override
  Future<void> disconnect() async {
    connected = false;
  }

  @override
  void close() {
    connected = false;
    unawaited(eventController.close());
  }

  @override
  Future<List<AgentModel>> listModels() async => [];
  @override
  Future<AgentThreadPage> listThreads({String? searchTerm}) async =>
      AgentThreadPage(threads: threads.values.toList());
  @override
  Future<AgentSession> resumeThread(
    String threadId, {
    ApprovalMode approvalMode = ApprovalMode.requestApproval,
  }) async => AgentSession(thread: threads[threadId]!, timeline: const []);
  @override
  Future<AgentTurnsPage> loadOlderTurns({
    required String threadId,
    required String cursor,
    int? subAgentCreatedAt,
  }) async => const AgentTurnsPage(timeline: []);

  void emit(String method, Map<String, Object?> params) => eventController.add(
    RemoteAgentNotification(
      CodexRpcNotification(
        generation: 1,
        raw: const {},
        isKnown: true,
        method: method,
        params: params,
      ),
    ),
  );
  void complete(
    String turnId, {
    String threadId = 'queue-thread',
    String status = 'completed',
  }) {
    final thread = threads[threadId]!;
    if (thread.activeTurnId == turnId) {
      threads[threadId] = thread.copyWith(status: 'idle', activeTurnId: null);
    }
    emit('turn/completed', {
      'threadId': threadId,
      'turn': {'id': turnId, 'status': status},
    });
  }

  @override
  Future<String> startTurn({
    required String threadId,
    required String text,
    List<PendingAttachment> attachments = const [],
    String? model,
    String? effort,
    String? subagentModel,
    ApprovalMode approvalMode = ApprovalMode.requestApproval,
    SandboxChoice? sandbox,
    String? cwd,
  }) async {
    final turnId = 'turn-${starts.length + 1}';
    starts.add(QueueCall(threadId, turnId, text, List.of(attachments)));
    if (failNext) {
      failNext = false;
      throw StateError('发送失败');
    }
    threads[threadId] = threads[threadId]!.copyWith(
      status: 'active',
      activeTurnId: turnId,
    );
    emit('turn/started', {
      'threadId': threadId,
      'turn': {'id': turnId, 'status': 'inProgress'},
    });
    if (completeBeforeReply) complete(turnId, threadId: threadId);
    await replyGate?.future;
    return turnId;
  }

  @override
  Future<void> steerTurn({
    required String threadId,
    required String turnId,
    required String text,
    List<PendingAttachment> attachments = const [],
  }) async {
    steers.add(QueueCall(threadId, turnId, text, List.of(attachments)));
    if (failNext) {
      failNext = false;
      throw StateError('引导失败');
    }
    await replyGate?.future;
  }

  @override
  Future<void> interruptTurn({
    required String threadId,
    required String turnId,
  }) async {
    interrupted.add(turnId);
  }
}

class QueueHarness {
  QueueHarness({
    AgentKind kind = AgentKind.codex,
    QueueAgent Function(AgentKind)? clientFactory,
  }) : profile = ServerProfile(
         id: 'queue-profile',
         name: 'Queue fixture',
         host: 'fixture.invalid',
         hostFingerprint: 'SHA256:fixture',
         remoteCommand: 'fixture-app-server',
         workspacePromptShown: true,
         activeAgent: kind,
       ) {
    store = QueueStore(profile);
    hosts = ServerConnectionManager(clientFactory: () => host);
    agents = AgentConnectionManager(
      hosts,
      clientFactory: (kind) => clients.putIfAbsent(
        kind,
        () => clientFactory?.call(kind) ?? QueueAgent(kind),
      ),
    );
    controller = AppController(store, hosts, agents);
  }
  final ServerProfile profile;
  final host = QueueHost();
  final clients = <AgentKind, QueueAgent>{};
  late final QueueStore store;
  late final ServerConnectionManager hosts;
  late final AgentConnectionManager agents;
  late final AppController controller;
  QueueAgent get agent => clients[profile.activeAgent]!;
  Future<void> open({
    String threadId = 'queue-thread',
    bool running = true,
  }) async {
    await queueWait(
      () => !controller.state.loading && controller.state.profiles.isNotEmpty,
    );
    await controller.requestConnect(profile);
    await controller.ensureActiveAgent();
    if (!running) {
      agent.threads[threadId] = agent.threads[threadId]!.copyWith(
        status: 'idle',
        activeTurnId: null,
      );
    }
    controller.openThread(agent.threads[threadId]!);
    await queueWait(
      () =>
          controller.state.activeThread?.id == threadId &&
          !controller.state.loading,
    );
  }

  Future<void> send(String text) async {
    controller.setComposerDraft(text);
    await controller.sendMessage();
  }

  Future<void> close() async {
    controller.dispose();
    await agents.close();
    await hosts.close();
  }
}

Future<void> queueWait(bool Function() condition) async {
  for (var i = 0; i < 200; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  throw StateError('Queue fixture condition was not reached');
}

Future<void> queuePump() =>
    Future<void>.delayed(const Duration(milliseconds: 20));
