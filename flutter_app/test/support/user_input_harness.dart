import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:codex_remote/src/agent/agent_connection_manager.dart';
import 'package:codex_remote/src/agent/codex_agent_client.dart';
import 'package:codex_remote/src/app/app_controller.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/persistence/profile_store.dart';
import 'package:codex_remote/src/ssh/server_connection_manager.dart';
import 'package:codex_remote/src/ssh/ssh_server_client.dart';
import 'package:flutter_test/flutter_test.dart';

class QuestionHost extends Fake implements RemoteServerClient {
  bool connected = false;
  final _done = Completer<void>();
  @override
  bool get isConnected => connected;
  @override
  Future<void> get done => _done.future;
  @override
  Future<void> connect(ServerProfile profile) async {
    connected = true;
  }

  @override
  Future<String> probeFingerprint(ServerProfile profile) async =>
      'SHA256:fixture';
  @override
  Future<void> disconnect() async {
    close();
  }

  @override
  void close() {
    connected = false;
    if (!_done.isCompleted) _done.complete();
  }
}

class QuestionStore implements ProfileStore {
  @override
  Future<StoredProfiles> load() async => const StoredProfiles(
    profiles: [questionProfile],
    selectedProfileId: 'questions',
  );
  @override
  Future<void> save(StoredProfiles value) async {}
}

const questionProfile = ServerProfile(
  id: 'questions',
  name: '本地协议测试',
  host: 'fixture.invalid',
  hostFingerprint: 'SHA256:fixture',
  remoteCommand: 'fixture-app-server',
  workspacePromptShown: true,
);
const questionThread = AgentThread(id: 'question-thread', title: '提问弹窗测试');

const fixtureQuestions = <Map<String, Object?>>[
  {
    'id': 'scope',
    'header': '范围',
    'question': '这次需要处理哪些内容？',
    'isOther': true,
    'options': [
      {'label': '当前页面（推荐）', 'description': '只修改当前页面，影响范围较小。'},
      {'label': '全部页面', 'description': '同时更新所有页面。'},
    ],
  },
  {'id': 'notes', 'header': '补充', 'question': '还有什么要求？', 'options': null},
];

/// Real JSONL adapter/controller, but no SSH account, provider or model billing.
class QuestionSession implements CodexSession {
  final _stdout = StreamController<Uint8List>();
  final _stderr = StreamController<Uint8List>();
  final _done = Completer<void>();
  final List<Map<String, dynamic>> responses = [];
  @override
  Stream<Uint8List> get stdout => _stdout.stream;
  @override
  Stream<Uint8List> get stderr => _stderr.stream;
  @override
  Future<void> get done => _done.future;

  void emit(Map<String, Object?> value) =>
      _stdout.add(Uint8List.fromList(utf8.encode('${jsonEncode(value)}\n')));

  void ask({
    Object id = 'question-1',
    String threadId = 'question-thread',
    List<Map<String, Object?>> questions = fixtureQuestions,
  }) => emit({
    'id': id,
    'method': 'item/tool/requestUserInput',
    'params': {
      'threadId': threadId,
      'turnId': 'turn-1',
      'itemId': 'item-1',
      'questions': questions,
      'autoResolutionMs': null,
    },
  });

  void resolve(Object id, {String threadId = 'question-thread'}) => emit({
    'method': 'serverRequest/resolved',
    'params': {'threadId': threadId, 'requestId': id},
  });

  @override
  void write(Uint8List data) {
    final value = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
    if (!value.containsKey('method')) {
      responses.add(value);
      resolve(value['id'] as Object);
      emit({
        'method': 'item/completed',
        'params': {
          'threadId': 'question-thread',
          'turnId': 'turn-1',
          'item': {
            'id': 'reply-${responses.length}',
            'type': 'agentMessage',
            'text': '已收到回答，继续执行。',
          },
        },
      });
      return;
    }
    if (!value.containsKey('id')) return;
    final result = switch (value['method']) {
      'thread/list' => {
        'data': [
          {'id': 'question-thread', 'preview': '提问弹窗测试', 'turns': []},
        ],
        'nextCursor': null,
      },
      'thread/resume' => {
        'thread': {'id': (value['params'] as Map)['threadId'], 'turns': []},
      },
      'model/list' => {'data': []},
      _ => <String, Object?>{},
    };
    emit({'id': value['id'], 'result': result});
  }

  @override
  void terminate() {
    if (!_done.isCompleted) _done.complete();
    unawaited(_stdout.close());
    unawaited(_stderr.close());
  }
}

class QuestionHarness {
  final session = QuestionSession();
  final hosts = ServerConnectionManager(clientFactory: QuestionHost.new);
  late final client = CodexAgentClient(sessionOpener: (_, _) async => session);
  late final agents = AgentConnectionManager(
    hosts,
    clientFactory: (_) => client,
  );
  late final controller = AppController(QuestionStore(), hosts, agents);

  Future<void> start() async {
    await controller.requestConnect(questionProfile);
    await controller.ensureActiveAgent();
    controller.openThread(questionThread);
    await drain();
  }

  Future<void> close() async {
    controller.dispose();
    await agents.close();
    await hosts.close();
  }
}

Future<void> drain() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
