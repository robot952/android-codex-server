import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:codex_remote/src/agent/agent_connection_manager.dart';
import 'package:codex_remote/src/agent/codex_agent_client.dart';
import 'package:codex_remote/src/app/app_controller.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/persistence/profile_store.dart';
import 'package:codex_remote/src/ssh/server_connection_manager.dart';

import 'user_input_harness.dart' show QuestionHost, drain;

const subAgentProfile = ServerProfile(
  id: 'sub-agents',
  name: '协作协议测试',
  host: 'fixture.invalid',
  hostFingerprint: 'SHA256:fixture',
  remoteCommand: 'fixture-app-server',
  workspacePromptShown: true,
);

class SubAgentStore implements ProfileStore {
  StoredProfiles value = const StoredProfiles(
    profiles: [subAgentProfile],
    selectedProfileId: 'sub-agents',
  );
  @override
  Future<StoredProfiles> load() async => value;
  @override
  Future<void> save(StoredProfiles profiles) async => value = profiles;
}

/// Production JSONL adapter/controller with a controlled protocol peer. No SSH,
/// credentials or model API is used. Snapshots and live notifications agree.
class SubAgentSession implements CodexSession {
  final _stdout = StreamController<Uint8List>();
  final _stderr = StreamController<Uint8List>();
  final _done = Completer<void>();
  final requests = <Map<String, dynamic>>[];
  final responses = <Map<String, dynamic>>[];
  final threads = <String, Map<String, Object?>>{};
  final failNextResume = <String>{};
  final _questions = <Object, String>{};
  @override
  Stream<Uint8List> get stdout => _stdout.stream;
  @override
  Stream<Uint8List> get stderr => _stderr.stream;
  @override
  Future<void> get done => _done.future;

  void addThread(String id, {String? title}) {
    threads[id] = {
      'id': id,
      'preview': title ?? id,
      'createdAt': 200,
      'turns': <Map<String, Object?>>[],
    };
  }

  Map<String, Object?> _turn(String threadId, String turnId) {
    final turns = threads[threadId]!['turns'] as List<Map<String, Object?>>;
    for (final turn in turns) {
      if (turn['id'] == turnId) return turn;
    }
    final turn = <String, Object?>{
      'id': turnId,
      'status': 'completed',
      'startedAt': 201,
      'items': <Map<String, Object?>>[],
    };
    turns.add(turn);
    return turn;
  }

  void emit(Map<String, Object?> value) {
    if (!_stdout.isClosed) {
      _stdout.add(Uint8List.fromList(utf8.encode('${jsonEncode(value)}\n')));
    }
  }

  void item(String threadId, String turnId, Map<String, Object?> item) {
    final items =
        _turn(threadId, turnId)['items'] as List<Map<String, Object?>>;
    items.removeWhere((existing) => existing['id'] == item['id']);
    items.add(item);
    emit({
      'method': 'item/completed',
      'params': {'threadId': threadId, 'turnId': turnId, 'item': item},
    });
  }

  void activity(
    String parent,
    String child, {
    String turn = 'parent-turn',
    String? id,
    String? path,
    String kind = 'started',
  }) => item(parent, turn, {
    'id': id ?? 'activity-$child-$kind',
    'type': 'subAgentActivity',
    'agentThreadId': child,
    'agentPath': path ?? '/root/$child',
    'kind': kind,
  });

  void collaboration(
    String parent,
    Map<String, String> states, {
    String turn = 'parent-turn',
    String id = 'collaboration',
    String tool = 'wait',
    String status = 'completed',
  }) => item(parent, turn, {
    'id': id,
    'type': 'collabAgentToolCall',
    'tool': tool,
    'status': status,
    'receiverThreadIds': states.keys.toList(),
    'agentsStates': {
      for (final entry in states.entries) entry.key: {'status': entry.value},
    },
  });

  void startTurn(String threadId, String turnId) {
    final turn = _turn(threadId, turnId)..['status'] = 'inProgress';
    emit({
      'method': 'turn/started',
      'params': {'threadId': threadId, 'turn': turn},
    });
  }

  void completeTurn(
    String threadId,
    String turnId, {
    String status = 'completed',
  }) {
    final turn = _turn(threadId, turnId)..['status'] = status;
    emit({
      'method': 'turn/completed',
      'params': {'threadId': threadId, 'turn': turn},
    });
  }

  void ask(String threadId, {Object requestId = 'child-question'}) {
    _questions[requestId] = threadId;
    emit({
      'id': requestId,
      'method': 'item/tool/requestUserInput',
      'params': {
        'threadId': threadId,
        'turnId': 'child-turn',
        'itemId': 'child-question-item',
        'questions': [
          {
            'id': 'choice',
            'header': '选择',
            'question': '请选择此智能体的处理范围',
            'isOther': false,
            'options': [
              {'label': '当前模块', 'description': '仅处理当前模块'},
              {'label': '所有模块', 'description': '处理全部模块'},
            ],
          },
        ],
      },
    });
  }

  @override
  void write(Uint8List bytes) {
    final request = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    if (!request.containsKey('method')) {
      responses.add(request);
      final thread = _questions.remove(request['id']);
      if (thread != null) {
        emit({
          'method': 'serverRequest/resolved',
          'params': {'threadId': thread, 'requestId': request['id']},
        });
      }
      return;
    }
    if (!request.containsKey('id')) return;
    requests.add(request);
    final params = request['params'] as Map? ?? const {};
    final threadId = params['threadId'] as String? ?? '';
    if ((request['method'] == 'thread/resume' ||
            request['method'] == 'thread/read') &&
        failNextResume.remove(threadId)) {
      emit({
        'id': request['id'],
        'error': {'code': -32000, 'message': '测试恢复失败'},
      });
      return;
    }
    final result = switch (request['method']) {
      'model/list' => {'data': []},
      'thread/list' => {
        'data': [threads['parent']],
        'nextCursor': null,
      },
      'thread/resume' || 'thread/read' => {'thread': threads[threadId]},
      'thread/turns/list' => {
        'data': (threads[threadId]?['turns'] as List? ?? const []).reversed
            .toList(),
        'nextCursor': null,
      },
      'turn/start' => {
        'turn': {'id': 'sent-$threadId', 'status': 'inProgress'},
      },
      _ => <String, Object?>{},
    };
    emit({'id': request['id'], 'result': result});
    if (request['method'] == 'turn/interrupt') {
      completeTurn(threadId, params['turnId'] as String, status: 'interrupted');
    }
  }

  @override
  void terminate() {
    if (!_done.isCompleted) _done.complete();
    unawaited(_stdout.close());
    unawaited(_stderr.close());
  }
}

class SubAgentHarness {
  final session = SubAgentSession()..addThread('parent', title: '协作测试');
  final hosts = ServerConnectionManager(clientFactory: QuestionHost.new);
  late final client = CodexAgentClient(sessionOpener: (_, _) async => session);
  late final agents = AgentConnectionManager(
    hosts,
    clientFactory: (_) => client,
  );
  late final controller = AppController(SubAgentStore(), hosts, agents);

  Future<void> start() async {
    await controller.requestConnect(subAgentProfile);
    await controller.ensureActiveAgent();
    controller.openThread(const AgentThread(id: 'parent', title: '协作测试'));
    await drain();
  }

  Future<void> close() async {
    if (controller.mounted) controller.dispose();
    await agents.close().timeout(const Duration(seconds: 3));
    await hosts.close().timeout(const Duration(seconds: 3));
  }
}
