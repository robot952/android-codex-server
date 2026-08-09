import 'package:codex_remote/src/app/codex_remote_app.dart';
import 'package:codex_remote/src/domain/models.dart' hide ConnectionState;
import 'package:codex_remote/src/domain/models.dart'
    as domain
    show ConnectionState;
import 'package:codex_remote/src/ui/thread_list_screen.dart';
import 'package:codex_remote/src/ui/work_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('hides cached threads while the agent lane is disconnected', () {
    const threads = <AgentThread>[AgentThread(id: 'one', title: 'One')];

    expect(visibleAgentThreads(threads, '', agentConnected: false), isEmpty);
    expect(visibleAgentThreads(threads, '', agentConnected: true), threads);
  });

  test('filters connected thread list by title, preview, and cwd', () {
    const threads = <AgentThread>[
      AgentThread(id: 'title', title: 'Deploy service'),
      AgentThread(id: 'preview', title: 'Other', preview: 'release notes'),
      AgentThread(id: 'cwd', title: 'Other', cwd: '/srv/project'),
    ];

    expect(
      visibleAgentThreads(
        threads,
        'release',
        agentConnected: true,
      ).map((thread) => thread.id),
      ['preview'],
    );
    expect(
      visibleAgentThreads(
        threads,
        '/srv',
        agentConnected: true,
      ).map((thread) => thread.id),
      ['cwd'],
    );
  });

  test('treats working status as an active thread', () {
    expect(
      isAgentThreadRunning(const AgentThread(id: 'working', status: 'working')),
      isTrue,
    );
    expect(
      isAgentThreadRunning(const AgentThread(id: 'idle', status: 'idle')),
      isFalse,
    );
  });

  test('dismisses the keyboard for every non-resumed lifecycle state', () {
    expect(shouldDismissWorkKeyboard(AppLifecycleState.resumed), isFalse);
    expect(shouldDismissWorkKeyboard(AppLifecycleState.inactive), isTrue);
    expect(shouldDismissWorkKeyboard(AppLifecycleState.paused), isTrue);
    expect(shouldDismissWorkKeyboard(AppLifecycleState.hidden), isTrue);
    expect(shouldDismissWorkKeyboard(AppLifecycleState.detached), isTrue);
  });

  test('keeps the app process alive for host, Agent, or running work', () {
    expect(keepsAppAliveInBackground(const AppUiState()), isFalse);
    expect(
      keepsAppAliveInBackground(
        const AppUiState(
          connectionStates: {
            'server': domain.ConnectionState(phase: ConnectionPhase.connected),
          },
        ),
      ),
      isTrue,
    );
    expect(
      keepsAppAliveInBackground(
        AppUiState(
          agentConnectionStates: {
            const AgentConnectionKey(
              profileId: 'server',
              agent: AgentKind.codex,
            ): const domain.ConnectionState(
              phase: ConnectionPhase.installing,
            ),
          },
        ),
      ),
      isTrue,
    );
    expect(keepsAppAliveInBackground(const AppUiState(running: true)), isTrue);
  });
}
