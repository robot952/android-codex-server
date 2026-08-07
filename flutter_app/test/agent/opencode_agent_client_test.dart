import 'package:codex_remote/src/agent/open_code_bootstrap.dart';
import 'package:codex_remote/src/agent/opencode_agent_client.dart';
import 'package:codex_remote/src/agent/remote_agent_client.dart';
import 'package:codex_remote/src/agent/remote_bootstrap.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/ssh/ssh_server_client.dart';
import 'package:flutter_test/flutter_test.dart';

class _AdapterRequest {
  const _AdapterRequest(this.method, this.params, this.timeout);

  final String method;
  final Map<String, Object?> params;
  final Duration? timeout;
}

class _RecordingOpenCodeClient extends OpenCodeAgentClient {
  _RecordingOpenCodeClient()
    : super(bridgeLoader: () async => 'test bridge source');

  final List<_AdapterRequest> requests = <_AdapterRequest>[];
  final List<Object?> responses = <Object?>[];
  bool reportConnected = true;

  @override
  bool get isConnected => reportConnected;

  @override
  Future<Object?> requestAdapterExtension(
    String method, {
    Map<String, Object?> params = const <String, Object?>{},
    Duration? timeout,
  }) async {
    requests.add(_AdapterRequest(method, params, timeout));
    return responses.isEmpty
        ? const <String, Object?>{}
        : responses.removeAt(0);
  }
}

class _StreamingCall {
  const _StreamingCall(this.script, this.command);

  final String script;
  final String command;
}

class _FakeScriptHost
    implements
        RemoteServerClient,
        RemoteServerScriptClient,
        RemoteServerStreamingScriptClient {
  _FakeScriptHost({this.shellOutput = ''});

  String shellOutput;
  final List<String> shellScripts = <String>[];
  final List<_StreamingCall> streamingCalls = <_StreamingCall>[];
  final List<List<String>> streamingStdout = <List<String>>[];

  @override
  bool get isConnected => true;

  @override
  Future<void> get done => Future<void>.value();

  @override
  Future<String> probeFingerprint(ServerProfile profile) async => 'fingerprint';

  @override
  Future<void> connect(ServerProfile profile) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<String> run(
    String command, {
    Duration timeout = const Duration(seconds: 15),
    int maxOutputBytes = 1024 * 1024,
  }) async => '';

  @override
  Future<ServerMetrics> readServerMetrics(ServerProfile profile) async =>
      const ServerMetrics();

  @override
  Never requireSshClient() => throw UnsupportedError('not used by this fake');

  @override
  Future<String> runShellScript(
    String script, {
    Duration timeout = const Duration(seconds: 15),
    int maxOutputBytes = 1024 * 1024,
  }) async {
    shellScripts.add(script);
    return shellOutput;
  }

  @override
  Future<String> runStreamingShellScript(
    String script, {
    String command = 'sh -s',
    Duration timeout = const Duration(minutes: 30),
    int maxOutputBytes = 8 * 1024 * 1024,
    void Function(String line)? onStdoutLine,
    void Function(String line)? onStderrLine,
  }) async {
    streamingCalls.add(_StreamingCall(script, command));
    final index = streamingCalls.length - 1;
    final lines = index < streamingStdout.length
        ? streamingStdout[index]
        : const <String>[];
    for (final line in lines) {
      onStdoutLine?.call(line);
    }
    return lines.join('\n');
  }

  @override
  void close() {}
}

String _probeOutput(String bridgeSource) =>
    '''
__CODEX_REMOTE_OS=Linux
__CODEX_REMOTE_ARCH=x86_64
__CODEX_REMOTE_HOME=/home/dev
__CODEX_REMOTE_LIBC=glibc
__CODEX_REMOTE_HAS_SHELL=1
__CODEX_REMOTE_HAS_TAR=1
__CODEX_REMOTE_HAS_SHA256=1
__CODEX_REMOTE_HAS_FLOCK=1
__CODEX_REMOTE_HAS_SETSID_WAIT=1
__CODEX_REMOTE_DOWNLOADER=curl
__CODEX_REMOTE_OPENCODE_VERSION=$pinnedOpenCodeVersion
__CODEX_REMOTE_OPENCODE_BRIDGE=/home/dev/.local/bin/codex-remote-opencode-bridge
__CODEX_REMOTE_OPENCODE_BRIDGE_SHA256=${OpenCodeBootstrap.bridgeSha256(bridgeSource)}
''';

void main() {
  group('OpenCode adapter identity and command', () {
    test('advertises only the supported OpenCode capabilities', () {
      final client = OpenCodeAgentClient(
        bridgeLoader: () async => 'test bridge source',
      );
      addTearDown(client.close);

      expect(client.kind, AgentKind.openCode);
      expect(client.capabilities, AgentCapabilities.openCode);
      expect(client.capabilities.rollbackThread, isFalse);
      expect(client.capabilities.reviewChanges, isFalse);
      expect(client.capabilities.threadGoals, isFalse);
      expect(client, isA<RemoteAgentCustomModelClient>());
    });

    test('quotes the workspace as one bridge argument', () {
      expect(buildOpenCodeBridgeCommand('  '), managedOpenCodeBridgeCommand);
      expect(
        buildOpenCodeBridgeCommand(" /srv/team's app "),
        '$managedOpenCodeBridgeCommand --directory '
        "'/srv/team'\"'\"'s app'",
      );
    });
  });

  group('OpenCode runtime lifecycle', () {
    test(
      'probes against the exact bridge asset supplied by the client',
      () async {
        const bridgeSource = "console.log('bridge');\n";
        final host = _FakeScriptHost(shellOutput: _probeOutput(bridgeSource));
        var loads = 0;
        final client = OpenCodeAgentClient(
          bridgeLoader: () async {
            loads += 1;
            return bridgeSource;
          },
        );
        addTearDown(client.close);

        final inspection = await client.inspectRuntime(
          const ServerProfile(id: 'server'),
          host,
        );

        expect(loads, 1);
        expect(host.shellScripts, <String>[
          OpenCodeBootstrap.combinedProbeScript,
        ]);
        expect(inspection.detectedVersion, pinnedOpenCodeVersion);
        expect(
          inspection.compatibleCommand,
          "'/home/dev/.local/bin/codex-remote-opencode-bridge'",
        );
      },
    );

    test(
      'installs shared Node first and exposes both progress phases',
      () async {
        const bridgeSource = "console.log('bridge');\n";
        final host = _FakeScriptHost();
        host.streamingStdout.addAll(const <List<String>>[
          <String>['::progress::50|25|下载 Node.js|一半'],
          <String>['::progress::74||分析 OpenCode 下载清单|锁定版本'],
        ]);
        final progress = <RemoteInstallProgress>[];
        final client = OpenCodeAgentClient(
          bridgeLoader: () async => bridgeSource,
        );
        addTearDown(client.close);

        await client.installRuntime(
          const ServerProfile(id: 'server', proxyUrl: 'http://127.0.0.1:7890'),
          host,
          onProgress: progress.add,
        );

        expect(host.streamingCalls, hasLength(2));
        expect(
          host.streamingCalls.first.script,
          contains('HTTP_PROXY="\$DOWNLOAD_PROXY"'),
        );
        expect(
          host.streamingCalls.last.script,
          contains(OpenCodeBootstrap.bridgeSha256(bridgeSource)),
        );
        expect(
          host.streamingCalls.map((call) => call.command),
          everyElement(remoteInstallCommand),
        );
        expect(progress, hasLength(2));
        expect(progress.first.percent, openCodeSharedRuntimePercent ~/ 2);
        expect(progress.first.downloadPercent, 25);
        expect(progress.first.message, '准备 OpenCode 运行时 · 下载 Node.js');
        expect(progress.last.percent, 74);
      },
    );

    test('uninstalls only the OpenCode-managed runtime paths', () async {
      final host = _FakeScriptHost();
      final client = OpenCodeAgentClient(
        bridgeLoader: () async => 'test bridge source',
      );
      addTearDown(client.close);

      await client.uninstallRuntime(const ServerProfile(id: 'server'), host);

      expect(host.shellScripts, <String>[OpenCodeBootstrap.uninstallScript]);
      expect(host.shellScripts.single, contains('codex-remote/opencode'));
      expect(
        host.shellScripts.single,
        isNot(contains(r'rm -rf -- "$HOME/.codex"')),
      );
      expect(host.shellScripts.single, isNot(contains('codex-mobile/uploads')));
    });
  });

  group('OpenCode global settings', () {
    test('reads every bridge setting including the actual API key', () async {
      final client = _RecordingOpenCodeClient();
      addTearDown(client.close);
      client.responses.add(const <String, Object?>{
        'baseUrl': ' https://api.example.com/v1 ',
        'model': 'provider/gpt-5',
        'reasoningEffort': 'high',
        'modelProvider': 'provider',
        'hasStoredAuthentication': true,
        'apiKey': 'sk-real-key',
        'proxyUrl': 'http://127.0.0.1:7890',
      });

      final settings = await client.readGlobalSettings(
        const ServerProfile(id: 'server'),
      );

      expect(settings.baseUrl, 'https://api.example.com/v1');
      expect(settings.modelProvider, 'provider');
      expect(settings.hasStoredAuthentication, isTrue);
      expect(settings.apiKey, 'sk-real-key');
      expect(client.requests.single.method, 'agent/settings/read');
      expect(client.requests.single.params, isEmpty);
    });

    test(
      'normalizes and writes custom model fields through bridge RPC',
      () async {
        final client = _RecordingOpenCodeClient();
        addTearDown(client.close);
        client.responses.addAll(const <Object?>[
          <String, Object?>{'modelProvider': 'existing-provider'},
          <String, Object?>{'modelProvider': 'custom-api'},
        ]);
        await client.readGlobalSettings(const ServerProfile(id: 'server'));
        const definition = CustomModelDefinition(
          modelId: 'gpt-5.1',
          displayName: 'GPT 5.1',
          contextWindowTokens: 200000,
          maxOutputTokens: 32000,
          apiProtocol: ModelApiProtocol.responses,
        );
        const profile = ServerProfile(
          id: 'server',
          agentModelSettings: <AgentKind, AgentModelSettings>{
            AgentKind.openCode: AgentModelSettings(
              customModels: <CustomModelDefinition>[definition],
            ),
          },
        );

        await client.writeGlobalSettings(
          profile,
          baseUrl: ' https://api.example.com/v1/ ',
          apiKey: ' sk-key ',
          proxyUrl: ' http://127.0.0.1:7890/ ',
          defaultModel: 'gpt-5.1',
          defaultReasoningEffort: 'HIGH',
          preserveCurrentProvider: true,
        );

        final request = client.requests.last;
        expect(request.method, 'agent/settings/write');
        expect(request.params['baseUrl'], 'https://api.example.com/v1');
        expect(request.params['apiKey'], 'sk-key');
        expect(request.params['proxyUrl'], 'http://127.0.0.1:7890');
        expect(request.params['defaultModel'], 'custom-api/gpt-5.1');
        expect(request.params['defaultReasoningEffort'], 'high');
        expect(request.params['preserveCurrentProvider'], isFalse);
        expect(request.params['customModels'], <Map<String, Object?>>[
          <String, Object?>{
            'modelId': 'custom-api/gpt-5.1',
            'displayName': 'GPT 5.1',
            'contextWindowTokens': 200000,
            'maxOutputTokens': 32000,
            'apiProtocol': 'responses',
          },
        ]);
      },
    );

    test('rejects malformed settings payloads', () {
      expect(() => parseOpenCodeGlobalSettings(null), throwsStateError);
      expect(() => parseOpenCodeGlobalSettings('invalid'), throwsStateError);
    });
  });

  group('OpenCode custom models', () {
    const definition = CustomModelDefinition(
      modelId: 'gpt-5.1',
      displayName: 'GPT 5.1',
      contextWindowTokens: 200000,
      maxOutputTokens: 32000,
      apiProtocol: ModelApiProtocol.responses,
    );

    test(
      'syncs protocol metadata, removals, and caches each definition',
      () async {
        final client = _RecordingOpenCodeClient();
        addTearDown(client.close);
        const profile = ServerProfile(id: 'server');

        await client.ensureCustomModel(profile, definition);
        await client.ensureCustomModel(profile, definition);

        expect(client.requests, hasLength(1));
        expect(client.requests.single.method, 'agent/models/sync');
        expect(client.requests.single.params['models'], <Map<String, Object?>>[
          <String, Object?>{
            'modelId': 'custom-api/gpt-5.1',
            'displayName': 'GPT 5.1',
            'contextWindowTokens': 200000,
            'maxOutputTokens': 32000,
            'apiProtocol': 'responses',
          },
        ]);

        await client.syncCustomModels(
          profile,
          definitions: const <CustomModelDefinition>[definition],
          removedModelIds: const <String>['gpt-old', 'gpt-old'],
        );
        expect(client.requests, hasLength(2));
        expect(client.requests.last.params['models'], isEmpty);
        expect(client.requests.last.params['removeModelIds'], <String>[
          'custom-api/gpt-old',
        ]);
      },
    );

    test('disconnect invalidates the ensured-model cache', () async {
      final client = _RecordingOpenCodeClient();
      addTearDown(client.close);
      const profile = ServerProfile(id: 'server');

      await client.ensureCustomModel(profile, definition);
      await client.disconnect();
      await client.ensureCustomModel(profile, definition);

      expect(
        client.requests.where(
          (request) => request.method == 'agent/models/sync',
        ),
        hasLength(2),
      );
    });
  });

  group('OpenCode API model mapping', () {
    test('strips and restores the provider prefix', () {
      expect(openCodeApiModelId('custom-api/gpt-5.1'), 'gpt-5.1');
      expect(openCodeApiModelId('gpt-5.1'), 'gpt-5.1');
      expect(
        openCodeProviderModelId('custom-api', 'gpt-5.1'),
        'custom-api/gpt-5.1',
      );
      expect(
        openCodeProviderModelId('custom-api', 'custom-api/gpt-5.1'),
        'custom-api/gpt-5.1',
      );
    });

    test('uses the configured protocol for custom model API tests', () {
      const definition = CustomModelDefinition(
        modelId: 'gpt-5.1',
        apiProtocol: ModelApiProtocol.responses,
      );
      expect(
        resolveOpenCodeModelApiProtocol(
          'custom-api/gpt-5.1',
          const <CustomModelDefinition>[definition],
        ),
        ModelApiProtocol.responses,
      );
      expect(
        resolveOpenCodeModelApiProtocol(
          'custom-api/unknown',
          const <CustomModelDefinition>[definition],
        ),
        ModelApiProtocol.chatCompletions,
      );
    });
  });
}
