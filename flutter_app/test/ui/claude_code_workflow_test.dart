import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:codex_remote/src/agent/agent_connection_manager.dart';
import 'package:codex_remote/src/agent/claude_code_agent_client.dart';
import 'package:codex_remote/src/agent/claude_code_bootstrap.dart';
import 'package:codex_remote/src/agent/codex_agent_client.dart';
import 'package:codex_remote/src/app/app_controller.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/ssh/server_connection_manager.dart';
import 'package:codex_remote/src/ssh/ssh_server_client.dart';
import 'package:codex_remote/src/ui/theme.dart';
import 'package:codex_remote/src/ui/thread_list_screen.dart';
import 'package:codex_remote/src/ui/work_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/user_input_harness.dart'
    show QuestionHost, QuestionStore, questionProfile, drain;

const _bridgeSource = 'fixture bridge';
const _threadId = 'same-thread-id-in-both-lanes';

void main({bool device = false}) {
  testWidgets(
    'Claude production adapter supports send, stream, approval, stop and isolated history',
    (tester) async {
      if (!device) {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(430, 1000);
        addTearDown(tester.view.reset);
      }
      final h = (await tester.runAsync(() async => _Harness()))!;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(h.close);
      });
      await tester.runAsync(h.start);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appControllerProvider.overrideWith((_) => h.controller)],
          child: MaterialApp(
            theme: buildCodexTheme(),
            home: Consumer(
              builder: (context, ref, child) {
                final state = ref.watch(appControllerProvider);
                return state.screen == AppScreen.work
                    ? const WorkScreen()
                    : const ThreadListScreen();
              },
            ),
          ),
        ),
      );
      await _pump(tester);
      expect(h.controller.state.activeAgent, AgentKind.codex);
      await tester.tap(find.text('Claude Code'));
      await _pump(tester);
      expect(h.controller.state.activeAgent, AgentKind.claudeCode);
      expect(
        h.controller.state.activeAgentCapabilities,
        AgentCapabilities.claudeCode,
      );
      expect(h.commands.single, isNot(contains('.codex')));

      await tester.tap(find.byTooltip('设置'));
      await _pump(tester);
      expect(find.text('配置 Claude Code'), findsNothing);
      expect(find.text('Codex 版本'), findsNothing);
      Navigator.of(tester.element(find.text('选择工作目录'))).pop();
      await _pump(tester);
      await tester.tap(find.byTooltip('新建会话'));
      await _pump(tester);
      expect(h.controller.state.activeThread?.id, _threadId);
      expect(find.byKey(const Key('composer-model-button')), findsNothing);

      // Claude exposes only request-approval and full-access modes. Cancelling
      // the destructive confirmation must leave the effective mode unchanged.
      final approvalBefore = h.controller.state.approvalMode;
      await tester.tap(find.byKey(const Key('composer-permission-button')));
      await _pump(tester);
      expect(find.text('请求批准'), findsOneWidget);
      expect(find.text('完全访问权限'), findsOneWidget);
      expect(find.text('替我审批'), findsNothing);
      await tester.tap(find.text('完全访问权限'));
      await _pump(tester);
      expect(find.text('启用完全访问'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await _pump(tester);
      expect(h.controller.state.approvalMode, approvalBefore);

      await tester.tap(find.byKey(const Key('composer-action-menu')));
      await _pump(tester);
      expect(find.text('选择模型'), findsNothing);
      expect(find.text('压缩会话'), findsNothing);
      // Dismiss the menu through its barrier, leaving the work route intact.
      await tester.tapAt(const Offset(12, 120));
      await _pump(tester);

      await _enterMessage(tester, '请检查工程', device: device);
      await tester.tap(find.byTooltip('发送'));
      await _pump(tester);
      expect(h.controller.state.running, isTrue);
      expect(
        h.claude.requests.where((r) => r['method'] == 'turn/start'),
        hasLength(1),
      );
      expect(find.text('请检查工程'), findsOneWidget);
      h.claude.delta('已检查');
      await _pump(tester);
      expect(find.text('已检查'), findsOneWidget);
      h.claude.delta('，等待工具授权。');
      h.claude.ask('allow-tool');
      await _pump(tester);
      expect(find.text('已检查，等待工具授权。'), findsOneWidget);
      expect(find.text('批准'), findsOneWidget);
      await tester.tap(find.text('批准'));
      await _pump(tester);
      expect(h.claude.responses.last['id'], 'allow-tool');
      expect(
        (h.claude.responses.last['result'] as Map)['permissions'],
        isNotEmpty,
      );
      expect(h.controller.state.approval, isNull);

      h.claude.ask('deny-tool');
      await _pump(tester);
      await tester.tap(find.text('拒绝'));
      await _pump(tester);
      expect(h.claude.responses.last['id'], 'deny-tool');
      expect(
        (h.claude.responses.last['result'] as Map)['permissions'],
        isEmpty,
      );
      expect(h.controller.state.approval, isNull);
      h.claude.finish('已检查，等待工具授权。');
      await _pump(tester);
      expect(h.controller.state.running, isFalse);

      await _enterMessage(tester, '继续运行', device: device);
      await tester.tap(find.byTooltip('发送'));
      await _pump(tester);
      h.claude.delta('保留停止前输出');
      await _pump(tester);
      await tester.tap(find.byTooltip('停止'));
      await _pump(tester);
      expect(find.text('停止当前回复'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '停止'));
      await _pump(tester);
      expect(
        h.claude.requests.where((r) => r['method'] == 'turn/interrupt'),
        hasLength(1),
      );
      expect(h.controller.state.running, isFalse);
      expect(find.text('保留停止前输出'), findsOneWidget);
      expect(h.controller.state.error, isNull);

      await tester.tap(find.byTooltip('返回会话列表'));
      await _pump(tester);
      expect(h.controller.state.screen, AppScreen.threads);
      await tester.tap(find.text('Claude 工作流'));
      await _pump(tester);
      expect(
        h.controller.state.timeline.any((e) => e.text == '保留停止前输出'),
        isTrue,
      );
      expect(
        h.controller.state.timeline.any((e) => e.text == '已检查，等待工具授权。'),
        isTrue,
      );

      await tester.tap(find.byTooltip('返回会话列表'));
      await _pump(tester);
      await tester.tap(find.text('Codex'));
      await _pump(tester);
      await tester.tap(find.text('Codex 独立历史'));
      await _pump(tester);
      expect(h.controller.state.activeThread?.id, _threadId);
      expect(h.controller.state.activeAgent, AgentKind.codex);
      expect(find.text('CODEX_ONLY_HISTORY'), findsOneWidget);
      expect(
        h.controller.state.timeline.any((e) => e.text.contains('停止前输出')),
        isFalse,
      );
      expect(h.codex.responses, isEmpty);
      expect(h.codex.requests.any((r) => r['method'] == 'turn/start'), isFalse);
      expect(find.byKey(const Key('composer-model-button')), findsOneWidget);
      await tester.tap(find.byTooltip('返回会话列表'));
      await _pump(tester);
      await tester.tap(find.text('Claude Code'));
      await _pump(tester);
      await tester.tap(find.text('Claude 工作流'));
      await _pump(tester);
      expect(
        h.controller.state.timeline.any((e) => e.text == 'CODEX_ONLY_HISTORY'),
        isFalse,
      );
      expect(
        h.controller.state.timeline.any((e) => e.text == '保留停止前输出'),
        isTrue,
      );
      expect(h.controller.state.error, isNull);
      expect(tester.takeException(), isNull);
      if (device) {
        debugPrint('CLAUDE_CODE_WORKFLOW_SCREENSHOT_READY');
        await Future<void>.delayed(const Duration(seconds: 4));
      }
    },
  );
}

Future<void> _enterMessage(
  WidgetTester tester,
  String message, {
  required bool device,
}) async {
  await tester.enterText(find.byKey(const Key('composer-input')), message);
  await _pump(tester);
  if (!device) return;
  // Keep Android's real IME open while tapping send. Its final metrics can
  // arrive after Flutter's first frame, so wait before checking the hit bounds.
  for (var attempt = 0; attempt < 50; attempt++) {
    if (tester.view.viewInsets.bottom > 0) break;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }
  await Future<void>.delayed(const Duration(milliseconds: 300));
  await tester.pump();
  expect(tester.view.viewInsets.bottom, greaterThan(0));
  final keyboardTop =
      (tester.view.physicalSize.height - tester.view.viewInsets.bottom) /
      tester.view.devicePixelRatio;
  expect(tester.getBottomRight(find.byTooltip('发送')).dy, lessThan(keyboardTop));
}

Future<void> _pump(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(drain);
    await tester.pump();
  }
  await tester.pump(const Duration(milliseconds: 300));
}

class _Host extends QuestionHost implements RemoteServerScriptClient {
  @override
  Future<String> runShellScript(
    String script, {
    Duration timeout = const Duration(seconds: 15),
    int maxOutputBytes = 1024 * 1024,
  }) async =>
      '''
__CODEX_REMOTE_OS=Linux
__CODEX_REMOTE_ARCH=x86_64
__CODEX_REMOTE_HOME=/home/fixture
__CODEX_REMOTE_HAS_SHELL=1
__CODEX_REMOTE_HAS_SHA256=1
__CODEX_REMOTE_HAS_FLOCK=1
__CODEX_REMOTE_HAS_SETSID_WAIT=1
__CODEX_REMOTE_CLAUDE_PATH=/usr/bin/claude
__CODEX_REMOTE_CLAUDE_VERSION=2.1.150
__CODEX_REMOTE_CLAUDE_NODE=/usr/bin/node
__CODEX_REMOTE_CLAUDE_BRIDGE=/home/fixture/.local/bin/codex-remote-claude-bridge
__CODEX_REMOTE_CLAUDE_BRIDGE_SHA256=${ClaudeCodeBootstrap.bridgeSha256(_bridgeSource)}
__CODEX_REMOTE_CLAUDE_LAUNCHER_SHA256=${ClaudeCodeBootstrap.bridgeSha256(ClaudeCodeBootstrap.launcherSource)}
''';
}

class _Harness {
  final commands = <String>[];
  final claude = _Session(claude: true);
  final codex = _Session(claude: false);
  final hosts = ServerConnectionManager(clientFactory: _Host.new);
  late final agents = AgentConnectionManager(
    hosts,
    clientFactory: (kind) => kind == AgentKind.claudeCode
        ? ClaudeCodeAgentClient(
            bridgeLoader: () async => _bridgeSource,
            sessionOpener: (_, command) async {
              commands.add(command);
              return claude;
            },
          )
        : CodexAgentClient(sessionOpener: (_, _) async => codex),
  );
  late final controller = AppController(QuestionStore(), hosts, agents);
  Future<void> start() async {
    await controller.requestConnect(questionProfile);
    await controller.ensureActiveAgent();
    await drain();
  }

  Future<void> close() async {
    controller.dispose();
    await agents.close();
    await hosts.close();
  }
}

/// Only the transport is controlled: production adapter, controller and pages
/// still parse the same JSONL notifications emitted by the shipped bridge.
class _Session implements CodexSession {
  _Session({required this.claude}) {
    if (!claude) {
      turns.add({
        'id': 'codex-history-turn',
        'status': 'completed',
        'items': [
          {
            'id': 'codex-history',
            'type': 'agentMessage',
            'text': 'CODEX_ONLY_HISTORY',
          },
        ],
      });
    }
  }
  final bool claude;
  final _stdout = StreamController<Uint8List>();
  final _stderr = StreamController<Uint8List>();
  final _done = Completer<void>();
  final requests = <Map<String, dynamic>>[];
  final responses = <Map<String, dynamic>>[];
  final turns = <Map<String, dynamic>>[];
  var reply = '';
  String get turnId => 'turn-${turns.length}';
  String get replyId => 'reply-${turns.length}';
  Map<String, Object?> get thread => {
    'id': _threadId,
    'name': claude ? 'Claude 工作流' : 'Codex 独立历史',
    'preview': claude ? 'Claude 会话记录' : 'Codex 会话记录',
    'cwd': '/fixture/workspace',
    'turns': turns,
  };
  @override
  Stream<Uint8List> get stdout => _stdout.stream;
  @override
  Stream<Uint8List> get stderr => _stderr.stream;
  @override
  Future<void> get done => _done.future;
  void emit(Map<String, Object?> message) =>
      _stdout.add(Uint8List.fromList(utf8.encode('${jsonEncode(message)}\n')));
  void notify(String method, Map<String, Object?> params) => emit({
    'method': method,
    'params': {'threadId': _threadId, ...params},
  });
  void delta(String text) {
    if (reply.isEmpty) {
      notify('item/started', {
        'turnId': turnId,
        'item': {'id': replyId, 'type': 'agentMessage', 'text': ''},
      });
    }
    reply += text;
    notify('item/agentMessage/delta', {
      'turnId': turnId,
      'itemId': replyId,
      'delta': text,
    });
  }

  void ask(String id) => emit({
    'id': id,
    'method': 'item/permissions/requestApproval',
    'params': {
      'threadId': _threadId,
      'turnId': turnId,
      'itemId': 'tool-$id',
      'reason': 'Claude Code 请求使用 Bash',
      'permissions': {
        'claudeTool': {
          'name': 'Bash',
          'input': {'command': 'pwd'},
        },
      },
    },
  });
  void finish(String text, {String status = 'completed'}) {
    final item = {'id': replyId, 'type': 'agentMessage', 'text': text};
    (turns.last['items'] as List).add(item);
    turns.last['status'] = status;
    notify('item/completed', {'turnId': turnId, 'item': item});
    notify('turn/completed', {
      'turn': {'id': turnId, 'status': status},
    });
  }

  @override
  void write(Uint8List data) {
    final request = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
    if (!request.containsKey('method')) {
      responses.add(request);
      notify('serverRequest/resolved', {'requestId': request['id']});
      return;
    }
    if (!request.containsKey('id')) return;
    requests.add(request);
    final params = (request['params'] as Map?) ?? {};
    Object result = <String, Object?>{};
    switch (request['method']) {
      case 'thread/list':
        result = {
          'data': claude && turns.isEmpty ? [] : [thread],
          'nextCursor': null,
        };
      case 'thread/start':
      case 'thread/resume':
      case 'thread/read':
        result = {'thread': thread};
      case 'thread/turns/list':
        result = {'data': turns.reversed.toList(), 'nextCursor': null};
      case 'model/list':
        result = {'data': []};
      case 'turn/start':
        reply = '';
        final input = params['input'] as List;
        final text = (input.first as Map)['text'];
        turns.add({
          'id': 'turn-${turns.length + 1}',
          'status': 'inProgress',
          'items': [
            {
              'id': 'user-${turns.length + 1}',
              'type': 'userMessage',
              'content': [
                {'type': 'text', 'text': text},
              ],
            },
          ],
        });
        result = {
          'turn': {'id': turnId, 'status': 'inProgress'},
        };
        notify('turn/started', {
          'turn': {'id': turnId, 'status': 'inProgress'},
        });
      case 'turn/interrupt':
        finish(reply, status: 'interrupted');
    }
    emit({'id': request['id'], 'result': result});
  }

  @override
  void terminate() {
    if (!_done.isCompleted) _done.complete();
    unawaited(_stdout.close());
    unawaited(_stderr.close());
  }
}
