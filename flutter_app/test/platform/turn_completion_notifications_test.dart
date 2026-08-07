import 'package:flutter_test/flutter_test.dart';

import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/platform/turn_completion_notifications.dart';

void main() {
  TurnCompletion completion({String turnId = 'turn-a'}) => TurnCompletion(
    profileId: 'server-a',
    agent: AgentKind.codex,
    profileName: 'Server A',
    threadId: 'thread-a',
    turnId: turnId,
  );

  test('duplicate turn completion is suppressed', () {
    final deduplicator = TurnCompletionDeduplicator();

    expect(deduplicator.shouldPublish(completion()), isTrue);
    expect(deduplicator.shouldPublish(completion()), isFalse);
    expect(deduplicator.shouldPublish(completion(turnId: 'turn-b')), isTrue);
  });

  test('completion without turn id is not permanently suppressed', () {
    final deduplicator = TurnCompletionDeduplicator();

    expect(deduplicator.shouldPublish(completion(turnId: '')), isTrue);
    expect(deduplicator.shouldPublish(completion(turnId: '')), isTrue);
  });

  test('deduplicator evicts oldest identities', () {
    final deduplicator = TurnCompletionDeduplicator(maxEntries: 2);

    expect(deduplicator.shouldPublish(completion(turnId: 'a')), isTrue);
    expect(deduplicator.shouldPublish(completion(turnId: 'b')), isTrue);
    expect(deduplicator.shouldPublish(completion(turnId: 'c')), isTrue);
    expect(deduplicator.shouldPublish(completion(turnId: 'a')), isTrue);
  });

  test('sub-agent registry is isolated by profile and agent', () {
    final registry = SubAgentThreadRegistry();
    final key = AgentConnectionKey(
      profileId: 'server-a',
      agent: AgentKind.codex,
    );
    registry.remember(key, 'child-thread');

    expect(registry.contains(key, 'child-thread'), isTrue);
    expect(
      registry.contains(
        const AgentConnectionKey(profileId: 'server-b', agent: AgentKind.codex),
        'child-thread',
      ),
      isFalse,
    );
    expect(
      registry.contains(
        const AgentConnectionKey(
          profileId: 'server-a',
          agent: AgentKind.openCode,
        ),
        'child-thread',
      ),
      isFalse,
    );
  });

  test('source matching handles protocol spelling variants', () {
    expect(isSubAgentThreadSource('subAgent'), isTrue);
    expect(isSubAgentThreadSource('SUB_AGENT'), isTrue);
    expect(isSubAgentThreadSource('sub-agent'), isTrue);
    expect(isSubAgentThreadSource('appServer'), isFalse);
  });

  test('navigation payload parses and defaults unknown agent to Codex', () {
    final navigation = CompletedThreadNavigation.fromJson({
      'profileId': 'server-a',
      'agent': 'OpenCode',
      'threadId': 'thread-a',
    });
    expect(navigation?.profileId, 'server-a');
    expect(navigation?.agent, AgentKind.openCode);
    expect(navigation?.threadId, 'thread-a');
    expect(
      CompletedThreadNavigation.fromJson({
        'profileId': 'server-a',
        'threadId': 'thread-a',
      })?.agent,
      AgentKind.codex,
    );
    expect(CompletedThreadNavigation.fromJson({}), isNull);
  });

  test('notification id is stable and lane-scoped', () {
    final first = completionNotificationId(
      'server-a',
      AgentKind.codex,
      'thread-a',
    );
    expect(
      completionNotificationId('server-a', AgentKind.codex, 'thread-a'),
      first,
    );
    expect(
      completionNotificationId('server-a', AgentKind.openCode, 'thread-a'),
      isNot(first),
    );
    expect(
      completionNotificationId('server-b', AgentKind.codex, 'thread-a'),
      isNot(first),
    );
  });
}
