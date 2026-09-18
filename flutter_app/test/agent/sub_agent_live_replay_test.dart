import 'dart:convert';
import 'dart:io';

import 'package:codex_remote/src/ui/sub_agent_presentation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/sub_agent_harness.dart';
import '../support/user_input_harness.dart' show drain;

void main() {
  test(
    'recorded live parallel, nested and followup events stay isolated',
    () async {
      // Codex 0.154.0, real configured provider, 2026-09-18. Only the IDs and
      // timestamps were normalized; these are actual collaboration event shapes.
      final events =
          jsonDecode(
                File(
                  'test/fixtures/subagent_live_events.json',
                ).readAsStringSync(),
              )
              as List;
      final h = SubAgentHarness();
      addTearDown(h.close);
      for (final id in ['alpha', 'beta', 'beta/gamma']) {
        h.session.addThread(id);
      }
      await h.start();
      var observedRestart = false;
      for (final raw in events) {
        final event = Map<String, Object?>.from(raw as Map);
        final params = Map<String, Object?>.from(event['params'] as Map);
        final thread = params['threadId'] as String;
        switch (event['method']) {
          case 'item/completed':
            h.session.item(
              thread,
              params['turnId'] as String,
              Map<String, Object?>.from(params['item'] as Map),
            );
          case 'turn/started':
            h.session.startTurn(
              thread,
              (params['turn'] as Map)['id'] as String,
            );
          case 'turn/completed':
            h.session.completeTurn(
              thread,
              (params['turn'] as Map)['id'] as String,
            );
        }
        await drain();
        final workers = h.controller.state.timeline
            .toBackgroundSubAgentPresentations();
        // The grandchild belongs only to beta, and wait is never a fake worker.
        expect(
          workers.map((x) => x.threadId).toSet().difference({'alpha', 'beta'}),
          isEmpty,
        );
        if (thread == 'alpha' &&
            event['method'] == 'turn/started' &&
            (params['turn'] as Map)['id'] == 'turn-6') {
          expect(
            workers.singleWhere((x) => x.threadId == 'alpha').status.isActive,
            isTrue,
          );
          observedRestart = true;
        }
      }
      expect(observedRestart, isTrue);
      final workers = h.controller.state.timeline
          .toBackgroundSubAgentPresentations();
      expect(workers.map((x) => x.name).toSet(), {'alpha', 'beta'});
      expect(
        workers.every((x) => x.status == SubAgentDisplayStatus.completed),
        isTrue,
      );
      h.controller.openSubAgentThread('beta', 'beta');
      await drain();
      expect(
        h.controller.state.timeline
            .toBackgroundSubAgentPresentations()
            .single
            .threadId,
        'beta/gamma',
      );
      h.controller.backFromSubAgentThread();
      await drain();
      expect(h.controller.state.activeThread?.id, 'parent');
      expect(
        h.controller.state.timeline.toBackgroundSubAgentPresentations(),
        hasLength(2),
      );
    },
  );
}
