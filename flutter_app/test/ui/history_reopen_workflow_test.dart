import 'dart:convert';
import 'dart:typed_data';

import 'package:codex_remote/src/app/app_controller.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/ui/theme.dart';
import 'package:codex_remote/src/ui/work_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/sub_agent_harness.dart';
import 'sub_agent_workflow_test.dart' show pumpSubAgentEvents;

void main({bool device = false}) {
  testWidgets('paged reopen retains answers before a new user-only turn', (
    tester,
  ) async {
    if (!device) {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
    }
    final h = (await tester.runAsync(
      () async => SubAgentHarness(session: _PagedSession()),
    ))!;
    final peer = h.session as _PagedSession;
    peer.threads['parent']!['updatedAt'] = 10;
    peer.threads['parent']!['turns'] = <Map<String, Object?>>[
      {
        'id': 'older-turn',
        'status': 'completed',
        'items': [
          {
            'id': 'answer',
            'type': 'agentMessage',
            'text': 'Earlier answer remains visible.',
          },
        ],
      },
      {
        'id': 'latest-turn',
        'status': 'inProgress',
        'items': [
          {
            'id': 'question',
            'type': 'userMessage',
            'content': [
              {'type': 'text', 'text': 'Latest question'},
            ],
          },
        ],
      },
    ];
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(h.close);
    });
    await tester.runAsync(() => h.start().timeout(const Duration(seconds: 8)));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((_) => h.controller)],
        child: MaterialApp(theme: buildCodexTheme(), home: const WorkScreen()),
      ),
    );
    await pumpSubAgentEvents(tester);
    expect(h.controller.state.loading, isFalse);
    expect(h.controller.state.olderTurnsLoading, isFalse);
    expect(peer.pageReads, 1);
    expect(find.text('Earlier answer remains visible.'), findsOneWidget);
    expect(find.text('Latest question'), findsOneWidget);

    for (var revision = 11; revision <= 13; revision++) {
      h.controller.backToThreadList();
      await pumpSubAgentEvents(tester);
      peer.threads['parent']!['updatedAt'] = revision;
      h.controller.openThread(
        AgentThread(id: 'parent', title: 'History test', updatedAt: revision),
      );
      await pumpSubAgentEvents(tester);
      expect(h.controller.state.loading, isFalse);
      expect(h.controller.state.timeline.map((row) => row.id), [
        'answer',
        'question',
      ]);
      expect(find.text('Earlier answer remains visible.'), findsOneWidget);
      expect(find.text('Latest question'), findsOneWidget);
      expect(
        peer.pageReads,
        1,
        reason: 'cached context avoids another full history read',
      );
    }

    final pagination = h.controller.loadOlderTurns();
    await pumpSubAgentEvents(tester);
    expect(h.controller.state.olderTurnsLoading, isFalse);
    await pagination;
    expect(h.controller.state.timeline.map((row) => row.id), [
      'answer',
      'question',
    ]);
    expect(h.controller.state.olderTurnsCursor, isNull);
    expect(tester.takeException(), isNull);
    if (device) {
      debugPrint('HISTORY_REOPEN_SCREENSHOT_READY');
      await Future<void>.delayed(const Duration(seconds: 5));
    }
  });
}

/// Uses the production JSONL adapter against a bounded protocol fixture.
class _PagedSession extends SubAgentSession {
  int pageReads = 0;

  @override
  void write(Uint8List bytes) {
    final request = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final method = request['method'];
    if (method != 'thread/resume' && method != 'thread/turns/list') {
      super.write(bytes);
      return;
    }
    requests.add(request);
    final params = request['params'] as Map;
    final thread = threads[params['threadId']]!;
    final turns = thread['turns'] as List<Map<String, Object?>>;
    final isResume = method == 'thread/resume';
    final paging = isResume ? params['initialTurnsPage'] as Map? : params;
    if (!isResume) pageReads++;
    final cursor = paging?['cursor'] as String?;
    final end = cursor == null ? turns.length : int.parse(cursor);
    final limit = paging?['limit'] as int? ?? 1;
    final start = (end - limit).clamp(0, turns.length);
    final page = {
      'data': turns.sublist(start, end).reversed.toList(),
      'nextCursor': start == 0 ? null : '$start',
    };
    emit({
      'id': request['id'],
      'result': isResume
          ? {
              'thread': {...thread, 'turns': <Object>[]},
              if (paging != null) 'initialTurnsPage': page,
            }
          : page,
    });
  }
}
