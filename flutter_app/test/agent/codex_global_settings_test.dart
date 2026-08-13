import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codex_remote/src/agent/codex_global_settings.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Codex global settings validation', () {
    test('normalizes HTTP URLs and rejects unsupported proxy schemes', () {
      expect(
        normalizeCodexBaseUrl('  https://gateway.example.com/v1///  '),
        'https://gateway.example.com/v1',
      );
      expect(
        normalizeCodexProxyUrl(' http://127.0.0.1:7890/ '),
        'http://127.0.0.1:7890',
      );
      expect(
        normalizeCodexProxyUrl('https://proxy.example.com:8443'),
        'https://proxy.example.com:8443',
      );
      expect(
        () => normalizeCodexProxyUrl('socks5://127.0.0.1:7890'),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => normalizeCodexBaseUrl('ftp://gateway.example.com/v1'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('accepts supported effort values and rejects shell-like models', () {
      expect(normalizeCodexReasoningEffort(' XHIGH '), 'xhigh');
      expect(normalizeCodexReasoningEffort('  '), isEmpty);
      expect(
        () => normalizeCodexReasoningEffort('maximum'),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => normalizeCodexModel('gpt-test; rm', '测试模型'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('parses native and SSH model responses through one decoder', () {
      final options = parseCodexApiModelsJson(
        utf8.encode(
          '{"data":['
          '{"id":"gpt-native","display_name":"Native",'
          '"context_window":131072,"max_output_tokens":32768},'
          '{"id":"gpt-native"}'
          ']}',
        ),
      );

      expect(options, hasLength(1));
      expect(options.single.modelId, 'gpt-native');
      expect(options.single.displayName, 'Native');
      expect(options.single.contextWindowTokens, 131072);
      expect(options.single.maxOutputTokens, 32768);
    });
  });

  group('Codex global settings shell scripts', () {
    test('all generated scripts have valid POSIX shell syntax', () async {
      final scripts = <String>[
        readCodexGlobalSettingsScript,
        buildWriteCodexGlobalSettingsScript(
          baseUrl: 'https://gateway.example.com/v1',
          apiKey: "sk-quote-'value",
          proxyUrl: 'http://127.0.0.1:7890',
          defaultModel: 'gpt-5.4',
          defaultReasoningEffort: 'high',
          preserveCurrentProvider: false,
        ),
        buildTestCodexGlobalSettingsScript(
          baseUrl: '',
          apiKey: "sk-quote-'value",
          proxyUrl: 'https://proxy.example.com:8443',
          testModel: 'gpt-5.4',
        ),
        buildFetchCodexApiModelsScript(
          baseUrl: 'https://gateway.example.com/v1',
          apiKey: "sk-quote-'value",
          proxyUrl: 'http://127.0.0.1:7890',
        ),
      ];

      for (final script in scripts) {
        final result = await _runProcessWithInput('sh', ['-n'], script);
        expect(result.exitCode, 0, reason: result.stderr);
      }
    });

    test('reads a custom provider, proxy, and actual API key', () async {
      final home = await _temporaryHome('codex-settings-read-');
      final codexDir = Directory('${home.path}/.codex');
      await codexDir.create();
      await File('${codexDir.path}/config.toml').writeAsString('''
model = "gpt-5.4"
model_reasoning_effort = "high"
model_provider = "relay"

[model_providers.relay]
base_url = "https://relay.example.com/v1"
env_key = "OPENAI_API_KEY"

[features]
web_search = true
''');
      await File(
        '${codexDir.path}/codex-remote.env',
      ).writeAsString('# codex-remote-proxy: http://127.0.0.1:7890\n');
      await File(
        '${codexDir.path}/auth.json',
      ).writeAsString('{"OPENAI_API_KEY":"sk-visible-test-key"}\n');

      final result = await _runShell(readCodexGlobalSettingsScript, home: home);

      expect(result.exitCode, 0, reason: result.stderr);
      final settings = parseCodexGlobalSettings(result.stdout);
      expect(settings.modelProvider, 'relay');
      expect(settings.model, 'gpt-5.4');
      expect(settings.reasoningEffort, 'high');
      expect(settings.baseUrl, 'https://relay.example.com/v1');
      expect(settings.proxyUrl, 'http://127.0.0.1:7890');
      expect(settings.hasStoredAuthentication, isTrue);
      expect(settings.apiKey, 'sk-visible-test-key');
    });

    test('writes private files without re-rendering user values', () async {
      final home = await _temporaryHome('codex-settings-write-');
      final codexDir = Directory('${home.path}/.codex');
      await codexDir.create();
      final config = File('${codexDir.path}/config.toml');
      await config.writeAsString('''
model = "gpt-old"
model_reasoning_effort = "low"
openai_base_url = "https://old.example.com/v1"

[features]
web_search = true
''');
      final wrapper = File('${home.path}/.local/bin/codex-remote');
      await _writeExecutable(wrapper, r'''#!/bin/sh
printf '%s\n' "$@" > "$HOME/login-arguments"
IFS= read -r key || true
printf '%s' "$key" > "$HOME/login-key"
printf '%s' "${HTTP_PROXY:-}" > "$HOME/login-proxy"
''');
      const apiKey = "sk-@@PROXY_URL@@-'quoted'";
      const proxyUrl = 'https://proxy.example.com/@@MODEL_LINE@@';
      const baseUrl = 'https://gateway.example.com/v1/@@PROXY_URL@@';
      const model = 'gpt-@@EFFORT_LINE@@';

      final result = await _runShell(
        buildWriteCodexGlobalSettingsScript(
          baseUrl: baseUrl,
          apiKey: apiKey,
          proxyUrl: proxyUrl,
          defaultModel: model,
          defaultReasoningEffort: 'xhigh',
          preserveCurrentProvider: false,
        ),
        home: home,
      );

      expect(result.exitCode, 0, reason: result.stderr);
      expect(result.stdout, contains('__CODEX_GLOBAL_UPDATED=1'));
      expect(result.stdout, isNot(contains(apiKey)));
      expect(result.stderr, isNot(contains(apiKey)));
      expect(await File('${home.path}/login-key').readAsString(), apiKey);
      final loginArguments = await File(
        '${home.path}/login-arguments',
      ).readAsString();
      expect(loginArguments, 'login\n--with-api-key\n');
      expect(loginArguments, isNot(contains(apiKey)));
      expect(await File('${home.path}/login-proxy').readAsString(), proxyUrl);

      final updatedConfig = await config.readAsString();
      expect(updatedConfig, contains('model = "$model"'));
      expect(updatedConfig, contains('model_reasoning_effort = "xhigh"'));
      expect(updatedConfig, contains('model_provider = "openai"'));
      expect(updatedConfig, contains('openai_base_url = "$baseUrl"'));
      expect(updatedConfig, isNot(contains('https://old.example.com/v1')));
      expect(updatedConfig, contains('[features]\nweb_search = true'));

      final environment = File('${codexDir.path}/codex-remote.env');
      final environmentText = await environment.readAsString();
      expect(environmentText, contains('# codex-remote-proxy: $proxyUrl'));
      expect(environmentText, contains('export HTTP_PROXY=$proxyUrl'));
      expect(await _permissionBits(codexDir.path), '700');
      expect(await _permissionBits(config.path), '600');
      expect(await _permissionBits(environment.path), '600');
      expect(await _permissionBits(wrapper.path), '700');
    });

    test(
      'preserves custom provider tables and clears model defaults',
      () async {
        final home = await _temporaryHome('codex-settings-clear-');
        final codexDir = Directory('${home.path}/.codex');
        await codexDir.create();
        final config = File('${codexDir.path}/config.toml');
        await config.writeAsString('''
model = "gpt-5.4"
model_reasoning_effort = "low"
model_provider = "relay"

[model_providers.relay]
base_url = "https://relay.example.com/v1"

[features]
web_search = true
''');

        final result = await _runShell(
          buildWriteCodexGlobalSettingsScript(
            baseUrl: 'https://relay.example.com/v1',
            apiKey: '',
            proxyUrl: '',
            defaultModel: '',
            defaultReasoningEffort: '',
            preserveCurrentProvider: true,
          ),
          home: home,
        );

        expect(result.exitCode, 0, reason: result.stderr);
        final lines = (await config.readAsString())
            .split('\n')
            .map((line) => line.trim())
            .toList();
        expect(lines.where((line) => line.startsWith('model =')), isEmpty);
        expect(
          lines.where((line) => line.startsWith('model_reasoning_effort =')),
          isEmpty,
        );
        expect(lines, contains('model_provider = "relay"'));
        expect(lines, contains('[model_providers.relay]'));
        expect(lines, contains('base_url = "https://relay.example.com/v1"'));
        expect(lines, contains('[features]'));
        expect(lines, contains('web_search = true'));
        expect(
          await File('${codexDir.path}/codex-remote.env').exists(),
          isFalse,
        );
        expect(await _permissionBits(config.path), '600');
      },
    );
  });

  group('Codex connection test script', () {
    test(
      'uses Responses and keeps the API key out of arguments and output',
      () async {
        const apiKey = "sk-@@PROXY_URL@@-'private'";
        const model = 'gpt-@@CHAT_ENDPOINT@@';
        const baseUrl = 'https://gateway.example.com/v1';
        const proxyUrl = 'http://127.0.0.1:7890';
        final home = await _apiFixtureHome(apiKey: apiKey, model: model);

        final result = await _runShell(
          buildTestCodexGlobalSettingsScript(
            baseUrl: baseUrl,
            apiKey: apiKey,
            proxyUrl: proxyUrl,
            testModel: model,
          ),
          home: home,
          environment: _fakeCurlEnvironment(home, 'responses_success'),
        );

        expect(result.exitCode, 0, reason: result.stderr);
        expect(
          result.stdout,
          contains('__CODEX_CONNECTION_TEST_STATUS=SUCCESS'),
        );
        expect(
          result.stdout,
          contains('__CODEX_CONNECTION_TEST_API=responses'),
        );
        expect(result.stdout, contains('__CODEX_CONNECTION_TEST_MODEL=$model'));
        expect(result.stdout, isNot(contains(apiKey)));
        expect(result.stderr, isNot(contains(apiKey)));
        final arguments = await File(
          '${home.path}/curl-arguments',
        ).readAsString();
        expect(arguments, isNot(contains(apiKey)));
        expect(arguments, contains('--proxy\n$proxyUrl\n'));
        expect(
          await File('${home.path}/curl-endpoints').readAsString(),
          '$baseUrl/responses\n',
        );
        final parsed = parseCodexConnectionTest(result.stdout);
        expect(parsed.successful, isTrue);
        expect(parsed.message, contains('Responses'));
        expect(parsed.message, contains(model));
      },
    );

    test(
      'falls back to Chat Completions after a Responses HTTP error',
      () async {
        const apiKey = 'sk-chat-fallback';
        const model = 'gpt-chat';
        final home = await _apiFixtureHome(apiKey: apiKey, model: model);

        final result = await _runShell(
          buildTestCodexGlobalSettingsScript(
            baseUrl: 'https://gateway.example.com/v1/',
            apiKey: apiKey,
            proxyUrl: '',
            testModel: model,
          ),
          home: home,
          environment: _fakeCurlEnvironment(home, 'fallback'),
        );

        expect(result.exitCode, 0, reason: result.stderr);
        expect(
          result.stdout,
          contains('__CODEX_CONNECTION_TEST_STATUS=SUCCESS'),
        );
        expect(
          result.stdout,
          contains('__CODEX_CONNECTION_TEST_API=chat/completions'),
        );
        expect(
          await File('${home.path}/curl-endpoints').readAsString(),
          'https://gateway.example.com/v1/responses\n'
          'https://gateway.example.com/v1/chat/completions\n',
        );
        final parsed = parseCodexConnectionTest(result.stdout);
        expect(parsed.successful, isTrue);
        expect(parsed.message, contains('Chat Completions'));
      },
    );

    test('honors an explicit model API protocol without fallback', () async {
      const apiKey = 'sk-explicit-protocol';
      const model = 'gpt-explicit';
      const baseUrl = 'https://gateway.example.com/v1';

      final responsesHome = await _apiFixtureHome(apiKey: apiKey, model: model);
      final responsesResult = await _runShell(
        buildTestCodexGlobalSettingsScript(
          baseUrl: baseUrl,
          apiKey: apiKey,
          proxyUrl: '',
          testModel: model,
          apiProtocol: ModelApiProtocol.responses,
        ),
        home: responsesHome,
        environment: _fakeCurlEnvironment(responsesHome, 'fallback'),
      );
      expect(
        responsesResult.stdout,
        contains('__CODEX_CONNECTION_TEST_STATUS=HTTP_ERROR'),
      );
      expect(
        await File('${responsesHome.path}/curl-endpoints').readAsString(),
        '$baseUrl/responses\n',
      );

      final chatHome = await _apiFixtureHome(apiKey: apiKey, model: model);
      final chatResult = await _runShell(
        buildTestCodexGlobalSettingsScript(
          baseUrl: baseUrl,
          apiKey: apiKey,
          proxyUrl: '',
          testModel: model,
          apiProtocol: ModelApiProtocol.chatCompletions,
        ),
        home: chatHome,
        environment: _fakeCurlEnvironment(chatHome, 'fallback'),
      );
      expect(
        chatResult.stdout,
        contains('__CODEX_CONNECTION_TEST_STATUS=SUCCESS'),
      );
      expect(
        chatResult.stdout,
        contains('__CODEX_CONNECTION_TEST_API=chat/completions'),
      );
      expect(
        await File('${chatHome.path}/curl-endpoints').readAsString(),
        '$baseUrl/chat/completions\n',
      );
    });

    test('maps network, authentication, and HTTP errors', () async {
      const cases = <({String mode, String status, String message})>[
        (
          mode: 'network',
          status: 'NETWORK_ERROR',
          message: '无法连接 API 服务端口，请检查地址、代理或网络',
        ),
        (
          mode: 'unauthorized',
          status: 'UNAUTHORIZED',
          message: 'API 密钥无效或没有权限（HTTP 401）',
        ),
        (
          mode: 'http_error',
          status: 'HTTP_ERROR',
          message: 'API 服务返回异常（HTTP 500）',
        ),
      ];

      for (final testCase in cases) {
        const apiKey = 'sk-error-test';
        const model = 'gpt-error-test';
        final home = await _apiFixtureHome(apiKey: apiKey, model: model);
        final result = await _runShell(
          buildTestCodexGlobalSettingsScript(
            baseUrl: '',
            apiKey: apiKey,
            proxyUrl: '',
            testModel: model,
          ),
          home: home,
          environment: _fakeCurlEnvironment(home, testCase.mode),
        );

        expect(
          result.exitCode,
          0,
          reason: '${testCase.mode}: ${result.stderr}',
        );
        expect(
          result.stdout,
          contains('__CODEX_CONNECTION_TEST_STATUS=${testCase.status}'),
        );
        final parsed = parseCodexConnectionTest(result.stdout);
        expect(parsed.successful, isFalse);
        expect(parsed.message, testCase.message);
        expect(result.stdout, isNot(contains(apiKey)));
        expect(result.stderr, isNot(contains(apiKey)));
      }
    });

    test('maps common curl failures to actionable network messages', () {
      const cases = <String, String>{
        '6': '无法解析 API 域名，请检查本机 Linux 的 DNS',
        '7': '无法连接 API 服务端口，请检查地址、代理或网络',
        '28': '连接 API 服务超时，请检查网络或代理',
        '60': 'API 服务 TLS 证书或握手失败',
      };

      for (final entry in cases.entries) {
        final parsed = parseCodexConnectionTest(
          '__CODEX_CONNECTION_TEST_STATUS=NETWORK_ERROR\n'
          '__CODEX_CONNECTION_TEST_CURL_EXIT=${entry.key}\n',
        );
        expect(parsed.successful, isFalse);
        expect(parsed.message, entry.value);
      }
    });

    test('maps local preparation errors and rejects unknown output', () {
      expect(
        parseCodexConnectionTest(
          '__CODEX_CONNECTION_TEST_STATUS=MISSING_API_KEY\n',
        ).message,
        '请输入 API 密钥后再测试',
      );
      expect(
        parseCodexConnectionTest(
          '__CODEX_CONNECTION_TEST_STATUS=CURL_UNAVAILABLE\n',
        ).message,
        '服务器未安装 curl，无法测试 API 连接',
      );
      expect(
        () => parseCodexConnectionTest('unrelated output\n'),
        throwsStateError,
      );
    });
  });

  group('Codex API model list', () {
    test('parses common provider metadata and removes duplicate IDs', () {
      final encoded = base64.encode(
        utf8.encode(
          jsonEncode({
            'data': [
              {
                'id': 'gpt-z',
                'display_name': 'GPT Z',
                'context_length': 200000,
                'top_provider': {'max_completion_tokens': 32000},
              },
              {
                'model': 'gpt-a',
                'contextWindow': '128000',
                'max_output_tokens': 16000,
              },
              {'id': 'gpt-z'},
            ],
          }),
        ),
      );
      final split = encoded.length ~/ 2;
      final models = parseCodexApiModels('''
__CODEX_API_MODEL_LIST_STATUS=SUCCESS
__CODEX_API_MODEL_LIST_HTTP_STATUS=200
__CODEX_API_MODEL_LIST_DATA=${encoded.substring(0, split)}
__CODEX_API_MODEL_LIST_DATA=${encoded.substring(split)}
''');

      expect(models.map((model) => model.modelId), ['gpt-a', 'gpt-z']);
      expect(models.first.contextWindowTokens, 128000);
      expect(models.first.maxOutputTokens, 16000);
      expect(models.last.displayName, 'GPT Z');
      expect(models.last.maxOutputTokens, 32000);
    });

    test('maps authentication, network, and malformed payload errors', () {
      expect(
        () => parseCodexApiModels(
          '__CODEX_API_MODEL_LIST_STATUS=MISSING_API_KEY\n',
        ),
        throwsA(predicate((error) => '$error'.contains('保存 API 密钥'))),
      );
      expect(
        () => parseCodexApiModels('''
__CODEX_API_MODEL_LIST_STATUS=NETWORK_ERROR
__CODEX_API_MODEL_LIST_CURL_EXIT=7
'''),
        throwsA(predicate((error) => '$error'.contains('curl exit 7'))),
      );
      expect(
        () => parseCodexApiModels('''
__CODEX_API_MODEL_LIST_STATUS=SUCCESS
__CODEX_API_MODEL_LIST_DATA=not-base64
'''),
        throwsStateError,
      );
    });

    test('keeps API keys out of endpoint and curl arguments', () {
      const apiKey = "sk-private-'quoted'";
      final script = buildFetchCodexApiModelsScript(
        baseUrl: 'https://gateway.example.com/v1',
        apiKey: apiKey,
        proxyUrl: 'http://127.0.0.1:7890',
      );

      expect(script, contains("API_KEY='sk-private-'\"'\"'quoted'"));
      expect(script, contains('--header "@\$HEADER_FILE"'));
      expect(script, isNot(contains('Authorization: Bearer $apiKey')));
    });
  });
}

Future<Directory> _temporaryHome(String prefix) async {
  final directory = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });
  return directory;
}

Future<Directory> _apiFixtureHome({
  required String apiKey,
  required String model,
}) async {
  final home = await _temporaryHome('codex-settings-api-');
  final bin = Directory('${home.path}/bin');
  await bin.create();
  final fixture = File('test/agent/fixtures/codex_settings_fake_curl.sh');
  await _writeExecutable(
    File('${bin.path}/curl'),
    await fixture.readAsString(),
  );
  await File('${home.path}/expected-key').writeAsString(apiKey);
  await File(
    '${home.path}/expected-header',
  ).writeAsString('Authorization: Bearer $apiKey\n');
  await File(
    '${home.path}/expected-responses',
  ).writeAsString('{"model":"$model","input":"ping"}');
  await File('${home.path}/expected-chat').writeAsString(
    '{"model":"$model","messages":[{"role":"user","content":"ping"}]}',
  );
  return home;
}

Map<String, String> _fakeCurlEnvironment(Directory home, String mode) => {
  'PATH': '${home.path}/bin:${Platform.environment['PATH'] ?? ''}',
  'FAKE_CURL_MODE': mode,
};

Future<void> _writeExecutable(File file, String contents) async {
  await file.parent.create(recursive: true);
  await file.writeAsString(contents);
  final chmod = await Process.run('chmod', ['700', file.path]);
  if (chmod.exitCode != 0) {
    throw StateError('chmod failed: ${chmod.stderr}');
  }
}

Future<String> _permissionBits(String path) async {
  final stat = await FileStat.stat(path);
  return (stat.mode & 0x1ff).toRadixString(8).padLeft(3, '0');
}

Future<_ProcessResult> _runShell(
  String script, {
  required Directory home,
  Map<String, String> environment = const {},
}) => _runProcessWithInput(
  'sh',
  const ['-s'],
  script,
  environment: {'HOME': home.path, ...environment},
);

Future<_ProcessResult> _runProcessWithInput(
  String executable,
  List<String> arguments,
  String input, {
  Map<String, String> environment = const {},
}) async {
  final process = await Process.start(
    executable,
    arguments,
    environment: environment,
  );
  final stdout = process.stdout.transform(utf8.decoder).join();
  final stderr = process.stderr.transform(utf8.decoder).join();
  process.stdin.add(utf8.encode(input));
  await process.stdin.close();

  int exitCode;
  try {
    exitCode = await process.exitCode.timeout(const Duration(seconds: 10));
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
    rethrow;
  }
  return _ProcessResult(
    exitCode: exitCode,
    stdout: await stdout,
    stderr: await stderr,
  );
}

final class _ProcessResult {
  const _ProcessResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}
