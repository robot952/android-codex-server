import 'package:codex_remote/src/domain/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sub_agent_workflow_test.dart' show pumpSubAgentApp, pumpSubAgentEvents;

void main({bool device = false}) {
  testWidgets('provider fallback stays readable and does not restart a task', (
    tester,
  ) async {
    if (!device) {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(420, 900);
      addTearDown(tester.view.reset);
    }
    final h = await pumpSubAgentApp(tester);
    h.session.startTurn('parent', 'transport-turn');
    await pumpSubAgentEvents(tester);
    final requestCount = h.session.requests.length;
    const warning =
        'Falling back from WebSockets to HTTPS transport. '
        'stream disconnected before completion: websocket closed by server '
        'before response.completed';
    for (var i = 0; i < 3; i++) {
      h.session.emit({
        'method': 'warning',
        'params': {
          'threadId': 'parent',
          'turnId': 'transport-turn',
          'message': warning,
        },
      });
    }
    await pumpSubAgentEvents(tester);
    expect(find.text('模型连接中断，正在切换到 HTTPS 重试。'), findsOneWidget);
    expect(find.textContaining('Falling back'), findsNothing);
    expect(h.controller.state.running, isTrue);
    expect(h.controller.state.error, isNull);
    expect(h.session.requests.length, requestCount);

    h.session.addThread('background');
    h.session.emit({
      'method': 'warning',
      'params': {
        'threadId': 'background',
        'message': '$warning: no available account',
      },
    });
    await pumpSubAgentEvents(tester);
    expect(find.textContaining('暂无可用账号'), findsNothing);

    if (device) {
      debugPrint('PROVIDER_TRANSPORT_SCREENSHOT_READY');
      await Future<void>.delayed(const Duration(seconds: 12));
    }
    h.session.item('parent', 'transport-turn', {
      'id': 'answer',
      'type': 'agentMessage',
      'text': '回退后正常完成',
    });
    h.session.completeTurn('parent', 'transport-turn');
    await pumpSubAgentEvents(tester);
    expect(h.controller.state.running, isFalse);
    expect(find.text('回退后正常完成'), findsOneWidget);
    expect(h.session.requests.length, requestCount);
    expect(h.controller.state.screen, AppScreen.work);

    h.session.emit({
      'method': 'error',
      'params': {
        'threadId': 'parent',
        'error': {'message': 'API 密钥无效'},
      },
    });
    await pumpSubAgentEvents(tester);
    expect(find.text('API 密钥无效'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
