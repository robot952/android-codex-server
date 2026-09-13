import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:codex_remote/src/agent/agent_connection_manager.dart';
import 'package:codex_remote/src/agent/codex_agent_client.dart';
import 'package:codex_remote/src/app/app_controller.dart';
import 'package:codex_remote/src/ssh/server_connection_manager.dart';
import 'package:codex_remote/src/ui/theme.dart';
import 'package:codex_remote/src/ui/user_input_dialog.dart';
import 'package:codex_remote/src/ui/work_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/support/user_input_harness.dart';

class _RealCodexSession implements CodexSession {
  _RealCodexSession(this.socket);
  final WebSocket socket;
  @override
  Stream<Uint8List> get stdout => socket.map(
    (frame) => Uint8List.fromList(utf8.encode('${frame as String}\n')),
  );
  @override
  Stream<Uint8List> get stderr => const Stream.empty();
  @override
  Future<void> get done => socket.done;
  @override
  void write(Uint8List data) => socket.add(utf8.decode(data).trimRight());
  @override
  void terminate() => unawaited(socket.close());
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real Codex Default mode calls question tool and consumes Android answer',
    (tester) async {
      const port = String.fromEnvironment('CODEX_QUESTION_WS_PORT');
      expect(
        port,
        isNotEmpty,
        reason: 'Start scripts/test-codex-user-input.cjs --serve first',
      );
      final hosts = ServerConnectionManager(clientFactory: QuestionHost.new);
      final client = CodexAgentClient(
        sessionOpener: (_, _) async =>
            _RealCodexSession(await WebSocket.connect('ws://127.0.0.1:$port')),
      );
      final agents = AgentConnectionManager(
        hosts,
        clientFactory: (_) => client,
      );
      final controller = AppController(QuestionStore(), hosts, agents);
      addTearDown(() async {
        if (controller.mounted) controller.dispose();
        await agents.close();
        await hosts.close();
      });
      await controller.requestConnect(questionProfile);
      await controller.ensureActiveAgent();
      await controller.createThread();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appControllerProvider.overrideWith((_) => controller)],
          child: MaterialApp(
            theme: buildCodexTheme(),
            home: const WorkScreen(),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await controller.sendMessage(text: 'Ask the fixture question.');
      for (
        var i = 0;
        i < 100 && find.byType(UserInputDialog).evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(UserInputDialog), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('你今天更想喝哪种饮品？'), findsOneWidget);
      await tester.tap(find.text('茶'));
      await tester.pump(const Duration(milliseconds: 300));
      await Future<void>.delayed(const Duration(seconds: 10));
      await tester.tap(find.byKey(const Key('submit-user-input')));
      for (
        var i = 0;
        i < 100 && find.textContaining('QUESTION_RESULT').evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(UserInputDialog), findsNothing);
      expect(find.textContaining('QUESTION_RESULT'), findsOneWidget);
      expect(find.textContaining('茶'), findsWidgets);
      expect(
        find.textContaining('Under-development features enabled:'),
        findsNothing,
      );
      expect(
        controller.state.timeline.any(
          (entry) => entry.text.contains('Under-development features enabled:'),
        ),
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
