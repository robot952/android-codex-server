import 'package:codex_remote/src/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ServerProfile', () {
    test('keeps product defaults', () {
      final profile = ServerProfile.create();

      expect(profile.id, isNotEmpty);
      expect(profile.username, 'root');
      expect(profile.port, 22);
      expect(profile.authMode, AuthMode.privateKey);
      expect(
        profile.remoteCommand,
        '~/.local/bin/codex-remote app-server --listen stdio://',
      );
    });

    test(
      'migrates legacy Codex model settings without leaking to OpenCode',
      () {
        const profile = ServerProfile(
          preferredModel: 'gpt-codex',
          preferredEffort: 'high',
          testModel: 'test-model',
          customModels: [CustomModelDefinition(modelId: 'custom')],
        );

        expect(
          profile.modelSettings(AgentKind.codex).preferredModel,
          'gpt-codex',
        );
        expect(profile.modelSettings(AgentKind.codex).managedModelIds, [
          'custom',
        ]);
        expect(
          profile.modelSettings(AgentKind.openCode).preferredModel,
          isEmpty,
        );
      },
    );

    test('writes lane settings independently', () {
      const original = ServerProfile(preferredModel: 'codex-model');
      final updated = original.withModelSettings(
        AgentKind.openCode,
        const AgentModelSettings(preferredModel: 'open-model'),
      );

      expect(updated.preferredModel, 'codex-model');
      expect(
        updated.modelSettings(AgentKind.openCode).preferredModel,
        'open-model',
      );
    });

    test('decodes native Android enum names and missing optional fields', () {
      final profile = ServerProfile.fromJson({
        'id': 'server-1',
        'authMode': 'PrivateKey',
        'approvalMode': 'RequestApproval',
        'agentMode': 'Codex',
        'activeAgent': 'OpenCode',
      });

      expect(profile.authMode, AuthMode.privateKey);
      expect(profile.approvalMode, ApprovalMode.requestApproval);
      expect(profile.activeAgent, AgentKind.openCode);
      expect(profile.username, 'root');
    });

    test(
      'defaults unknown future enum values without dropping the profile',
      () {
        final profile = ServerProfile.fromJson({
          'id': 'future-server',
          'authMode': 'Passkey',
          'approvalMode': 'PolicyV2',
          'agentMode': 'MultiAgent',
          'activeAgent': 'FutureAgent',
        });

        expect(profile.id, 'future-server');
        expect(profile.authMode, AuthMode.privateKey);
        expect(profile.approvalMode, ApprovalMode.requestApproval);
        expect(profile.activeAgent, AgentKind.codex);
        expect(profile.toJson()['agentMode'], 'Codex');
      },
    );

    test('keeps known agent settings and skips unknown agent lanes', () {
      final profile = ServerProfile.fromJson({
        'agentModelSettings': {
          'Codex': {'preferredModel': 'known-model'},
          'FutureAgent': {'preferredModel': 'future-model'},
        },
      });

      expect(profile.agentModelSettings.keys, [AgentKind.codex]);
      expect(
        profile.agentModelSettings[AgentKind.codex]?.preferredModel,
        'known-model',
      );
    });
  });

  test('defaults unknown custom model protocols', () {
    final model = CustomModelDefinition.fromJson({
      'modelId': 'future-model',
      'apiProtocol': 'messages_v2',
    });

    expect(model.modelId, 'future-model');
    expect(model.apiProtocol, ModelApiProtocol.chatCompletions);
  });

  test('thread preference keys isolate profile, agent, and thread', () {
    final keys = {
      threadPreferenceKey('a', AgentKind.codex, 'one'),
      threadPreferenceKey('a', AgentKind.openCode, 'one'),
      threadPreferenceKey('a', AgentKind.codex, 'two'),
      threadPreferenceKey('b', AgentKind.codex, 'one'),
    };

    expect(keys, hasLength(4));
    expect(sessionKey('a', AgentKind.codex), 'a\u0000Codex');
    expect(sessionKey('a', AgentKind.openCode), 'a\u0000OpenCode');
    expect(
      threadPreferenceKey('a', AgentKind.openCode, 'one'),
      'a\u0000OpenCode\u0000one',
    );
  });

  test('context usage and diff helpers retain semantic boundaries', () {
    const usage = TokenUsage(modelContextWindow: 1000);
    const unknown = TokenUsage();
    const change = FileChange(
      path: 'lib/a.dart',
      diff: '--- a/lib/a.dart\n+++ b/lib/a.dart\n-old\n+new\n context',
    );

    expect(usage.hasKnownContextWindow, isTrue);
    expect(unknown.hasKnownContextWindow, isFalse);
    expect(change.additions, 1);
    expect(change.deletions, 1);
  });
}
