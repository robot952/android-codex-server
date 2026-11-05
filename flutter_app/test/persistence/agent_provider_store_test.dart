import 'dart:convert';

import 'package:codex_remote/src/domain/agent_provider_profile.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/persistence/agent_provider_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('persists provider settings and secrets in secure storage', () async {
    const storage = FlutterSecureStorage();
    final store = SecureAgentProviderStore(storage: storage);
    const profile = AgentProviderProfile(
      id: 'provider-1',
      serverProfileId: 'server-1',
      agent: AgentKind.openCode,
      name: '兼容接口',
      baseUrl: 'https://example.test/v1',
      apiKey: ' secret-token ',
      proxyUrl: 'http://127.0.0.1:7890',
      defaultModel: 'provider/model',
      defaultSubagentModel: 'provider/model-mini',
      defaultReasoningEffort: 'high',
      websocketPolicy: 'auto',
      contextWindowTokens: 160000,
      preserveCurrentProvider: false,
    );

    await store.save(profile);
    final raw = await storage.read(key: SecureAgentProviderStore.storageKey);
    final reloaded = await SecureAgentProviderStore(storage: storage).loadAll();

    expect(raw, isNotNull);
    expect(jsonDecode(raw!), hasLength(1));
    expect(reloaded.single.toJson(), profile.toJson());
  });

  test('scopes upsert and delete by server, agent, and profile id', () async {
    final store = SecureAgentProviderStore();
    const sameIdCodex = AgentProviderProfile(
      id: 'shared',
      serverProfileId: 'server-1',
      agent: AgentKind.codex,
      name: 'Codex provider',
    );
    const sameIdOpenCode = AgentProviderProfile(
      id: 'shared',
      serverProfileId: 'server-1',
      agent: AgentKind.openCode,
      name: 'OpenCode provider',
    );
    const anotherServer = AgentProviderProfile(
      id: 'shared',
      serverProfileId: 'server-2',
      agent: AgentKind.codex,
      name: 'Other server',
    );
    await store.save(sameIdCodex);
    await store.save(sameIdOpenCode);
    await store.save(anotherServer);
    await store.save(sameIdCodex.copyWith(name: 'Updated Codex provider'));

    expect(await store.loadAll(), hasLength(3));
    expect(
      (await store.loadAll(
        serverProfileId: 'server-1',
        agent: AgentKind.codex,
      )).single.name,
      'Updated Codex provider',
    );
    await store.delete(
      serverProfileId: 'server-1',
      agent: AgentKind.codex,
      id: 'shared',
    );

    expect((await store.loadAll()).map((profile) => profile.name), [
      'OpenCode provider',
      'Other server',
    ]);
  });

  test(
    'ignores malformed entries without throwing or rewriting storage',
    () async {
      const storage = FlutterSecureStorage();
      const raw = '[{"id":"broken","agent":"unknown"},null]';
      await storage.write(key: SecureAgentProviderStore.storageKey, value: raw);

      expect(
        await SecureAgentProviderStore(storage: storage).loadAll(),
        isEmpty,
      );
      expect(await storage.read(key: SecureAgentProviderStore.storageKey), raw);
    },
  );
}
