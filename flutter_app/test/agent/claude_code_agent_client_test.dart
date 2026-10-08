import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codex_remote/src/agent/claude_code_agent_client.dart';
import 'package:codex_remote/src/agent/claude_code_bootstrap.dart';
import 'package:codex_remote/src/agent/claude_code_bridge_asset.dart';
import 'package:codex_remote/src/agent/codex_agent_client.dart';
import 'package:codex_remote/src/agent/remote_bootstrap.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/ssh/ssh_server_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';

void main() {
  test('advertises Claude Code model and settings capabilities', () {
    final client = ClaudeCodeAgentClient(bridgeLoader: () async => 'bridge');
    addTearDown(client.close);

    expect(client.kind, AgentKind.claudeCode);
    expect(client.capabilities, AgentCapabilities.claudeCode);
    expect(client.capabilities.models, isTrue);
    expect(client.capabilities.globalSettings, isTrue);
    expect(client.capabilities.approvals, isTrue);
  });

  test('builds a quoted bridge command', () {
    expect(buildClaudeCodeBridgeCommand(''), managedClaudeCodeBridgeCommand);
    expect(
      buildClaudeCodeBridgeCommand(" /srv/team's app "),
      '$managedClaudeCodeBridgeCommand --directory '
      "'/srv/team'\"'\"'s app'",
    );
  });

  test('parses a compatible remote Claude probe', () {
    const source = 'bridge source';
    final hash = ClaudeCodeBootstrap.bridgeSha256(source);
    final output =
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
__CODEX_REMOTE_CLAUDE_PATH=/usr/local/bin/claude
__CODEX_REMOTE_CLAUDE_VERSION=2.1.150
__CODEX_REMOTE_CLAUDE_NODE=/usr/bin/node
__CODEX_REMOTE_CLAUDE_BRIDGE=/home/dev/.local/bin/codex-remote-claude-bridge
__CODEX_REMOTE_CLAUDE_BRIDGE_SHA256=$hash
__CODEX_REMOTE_CLAUDE_LAUNCHER_SHA256=${ClaudeCodeBootstrap.bridgeSha256(ClaudeCodeBootstrap.launcherSource)}
''';

    final inspection = ClaudeCodeBootstrap.inspect(
      output,
      bridgeSource: source,
    );
    expect(inspection.detectedVersion, '2.1.150');
    expect(
      inspection.compatibleCommand,
      "'/home/dev/.local/bin/codex-remote-claude-bridge'",
    );
  });

  test('checks bridge prerequisites without requiring download tools', () {
    const host = '''
__CODEX_REMOTE_OS=Linux
__CODEX_REMOTE_ARCH=x86_64
__CODEX_REMOTE_HOME=/home/dev
__CODEX_REMOTE_HAS_SHELL=1
__CODEX_REMOTE_HAS_SHA256=1
__CODEX_REMOTE_HAS_FLOCK=1
__CODEX_REMOTE_HAS_SETSID_WAIT=1
''';
    const cli = '''
__CODEX_REMOTE_CLAUDE_PATH=/home/dev/.local/bin/claude
__CODEX_REMOTE_CLAUDE_VERSION=2.1.150 (Claude Code)
''';
    String? problem(String value) => ClaudeCodeBootstrap.inspect(
      value,
      bridgeSource: 'source',
    ).installationProblem;
    expect(problem(host), contains('安装并登录 Claude Code'));
    expect(problem('$host$cli'), contains('Node.js 18'));
    expect(
      problem('$host${cli.replaceAll('2.1.150', '2.0.9')}'),
      contains('升级'),
    );
    expect(
      problem('$host${cli}__CODEX_REMOTE_CLAUDE_NODE=/usr/bin/node\n'),
      isNull,
    );
  });

  test(
    'handshake and thread RPCs stay isolated from Codex configuration',
    () async {
      final session = _Session();
      final host = _Host();
      String? command;
      final client = ClaudeCodeAgentClient(
        sessionOpener: (_, value) async {
          command = value;
          return session;
        },
      );
      addTearDown(client.close);
      await client.connect(
        const ServerProfile(id: 'test', workspace: "/srv/team's app"),
        host,
      );
      expect(
        command,
        "exec $managedClaudeCodeBridgeCommand --directory '/srv/team'\"'\"'s app'",
      );
      expect(command, isNot(contains('.codex')));
      final created = await client.startThread(cwd: '/workspace');
      expect(created.thread.id, 'claude-thread');
      final start = session.requests.firstWhere(
        (value) => value['method'] == 'thread/start',
      );
      expect(start['params'] as Map, isNot(contains('config')));
      expect(
        await client.startTurn(threadId: created.thread.id, text: 'hello'),
        'claude-turn',
      );
      final resumed = await client.resumeThread(created.thread.id);
      expect(resumed.thread.id, created.thread.id);
      expect(resumed.timeline, hasLength(1));
      expect(resumed.timeline.single.text, 'Claude reply');
      expect(host.commands, isEmpty);
    },
  );

  test('runtime progress uses only protocol progress lines', () async {
    final host = _Host();
    final client = ClaudeCodeAgentClient(
      bridgeLoader: () async => 'process.exit(0);',
    );
    addTearDown(client.close);
    final progress = <RemoteInstallProgress>[];
    await client.installRuntime(
      const ServerProfile(id: 'test'),
      host,
      onProgress: progress.add,
    );
    expect(host.scripts, hasLength(1));
    expect(progress.map((value) => value.percent), [5, 25, 100]);
    expect(
      progress.any((value) => value.message.contains('diagnostic')),
      isFalse,
    );
  });

  test(
    'rejects unsupported local hosts before opening a Codex session',
    () async {
      var opened = false;
      final client = ClaudeCodeAgentClient(
        sessionOpener: (_, _) async {
          opened = true;
          return _Session();
        },
      );
      addTearDown(client.close);
      expect(
        () => client.connect(const ServerProfile(id: 'local'), _LocalHost()),
        throwsUnsupportedError,
      );
      expect(opened, isFalse);
    },
  );

  test('uses managed Node when the SSH PATH has no Node executable', () async {
    final fixture = await _RuntimeFixture.create();
    addTearDown(fixture.close);
    final nodeResult = await Process.run('/bin/sh', ['-c', 'command -v node']);
    final node = (nodeResult.stdout as String).trim();
    final tools = Directory('${fixture.directory.path}/tools');
    await tools.create();
    for (final command in [
      'dirname',
      'mkdir',
      'flock',
      'mktemp',
      'sha256sum',
      'cut',
      'chmod',
      'sh',
      'mv',
      'rm',
      'rmdir',
    ]) {
      await Link('${tools.path}/$command').create('/usr/bin/$command');
    }
    final managed = File(
      '${fixture.directory.path}/.local/share/codex-remote/runtime/node-test/bin/node',
    );
    await managed.parent.create(recursive: true);
    await Link(managed.path).create(node);
    final result = await fixture.script(
      ClaudeCodeBootstrap.installScript(
        bridgeSource: 'console.log("managed-node-ok");',
      ),
      path: tools.path,
    );
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final launched = await fixture.script(
      'exec ~/.local/bin/codex-remote-claude-bridge',
      path: tools.path,
    );
    expect(launched.exitCode, 0, reason: '${launched.stderr}');
    expect(launched.stdout, 'managed-node-ok\n');
  });

  test(
    'installs, executes, detects tampering and preserves user data on uninstall',
    () async {
      final fixture = await _RuntimeFixture.create();
      addTearDown(fixture.close);
      const source =
          'console.log(JSON.stringify({args:process.argv.slice(2),cli:process.env.CLAUDE_BIN,codex:process.env.CODEX_ONLY_SENTINEL??null}));\n';
      var result = await fixture.script(
        ClaudeCodeBootstrap.installScript(bridgeSource: source),
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final client = ClaudeCodeAgentClient();
      addTearDown(client.close);
      result = await fixture.script(
        client.buildSessionCommand(
          const ServerProfile(
            id: 'test',
            remoteCommand:
                "~/.local/bin/codex-remote-claude-bridge --directory '/workspace with spaces'",
          ),
        ),
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final output = jsonDecode(result.stdout as String) as Map;
      expect(output['args'], ['--directory', '/workspace with spaces']);
      expect(output['cli'], '${fixture.directory.path}/.local/bin/claude');
      expect(output['codex'], isNull);
      result = await fixture.script(ClaudeCodeBootstrap.combinedProbeScript);
      expect(
        ClaudeCodeBootstrap.inspect(
          result.stdout as String,
          bridgeSource: source,
        ).compatibleCommand,
        isNotNull,
      );
      final installed = File(
        '${fixture.directory.path}/.local/share/codex-remote/claude/bridge.cjs',
      );
      await installed.writeAsString('console.log("corrupt");');
      result = await fixture.script(ClaudeCodeBootstrap.combinedProbeScript);
      expect(
        ClaudeCodeBootstrap.inspect(
          result.stdout as String,
          bridgeSource: source,
        ).compatibleCommand,
        isNull,
      );
      result = await fixture.script(
        ClaudeCodeBootstrap.installScript(bridgeSource: source),
      );
      expect(result.exitCode, 0);
      final launcher = File(
        '${fixture.directory.path}/.local/bin/codex-remote-claude-bridge',
      );
      await launcher.writeAsString('\n# changed\n', mode: FileMode.append);
      result = await fixture.script(ClaudeCodeBootstrap.combinedProbeScript);
      expect(
        ClaudeCodeBootstrap.inspect(
          result.stdout as String,
          bridgeSource: source,
        ).compatibleCommand,
        isNull,
      );
      final history = File('${installed.parent.path}/threads.json');
      await history.writeAsString('{"kept":true}');
      result = await fixture.script(ClaudeCodeBootstrap.uninstallScript);
      expect(result.exitCode, 0);
      expect(await launcher.exists(), isFalse);
      expect(await installed.exists(), isFalse);
      expect(await history.readAsString(), '{"kept":true}');
      expect(
        await File(
          '${fixture.directory.path}/.claude/settings.json',
        ).readAsString(),
        '{"user":"retained"}',
      );
      expect(
        await File('${fixture.directory.path}/.local/bin/claude').exists(),
        isTrue,
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'rejects old CLI and invalid source before replacing installed bridge',
    () async {
      final fixture = await _RuntimeFixture.create();
      addTearDown(fixture.close);
      const source = 'console.log("valid");';
      expect(
        (await fixture.script(
          ClaudeCodeBootstrap.installScript(bridgeSource: source),
        )).exitCode,
        0,
      );
      final badSyntax = await fixture.script(
        ClaudeCodeBootstrap.installScript(
          bridgeSource: 'not valid javascript !!',
        ),
      );
      expect(badSyntax.exitCode, isNot(0));
      final installed = File(
        '${fixture.directory.path}/.local/share/codex-remote/claude/bridge.cjs',
      );
      expect(await installed.readAsString(), source);
      await fixture.writeCli('2.0.9');
      final oldVersion = await fixture.script(
        ClaudeCodeBootstrap.installScript(
          bridgeSource: 'console.log("replacement");',
        ),
      );
      expect(oldVersion.exitCode, 65);
      expect(await installed.readAsString(), source);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test('settings use Claude extension RPCs and preserve blank keys', () async {
    final session = _Session();
    final client = ClaudeCodeAgentClient(
      sessionOpener: (_, _) async => session,
    );
    addTearDown(client.close);
    const profile = ServerProfile(id: 'server');
    final host = _Host();
    await client.connect(profile, host);
    final settings = await client.readGlobalSettings(profile);
    expect(settings.modelProvider, 'anthropic');
    expect(settings.model, 'm-claude');
    expect(settings.apiKey, 'fixture-token');
    expect(settings.hasStoredAuthentication, true);
    await client.writeGlobalSettings(
      profile,
      baseUrl: 'https://example.invalid',
      apiKey: '',
      proxyUrl: '',
      defaultModel: 'claude-opus-5-5',
      defaultSubagentModel: 'claude-haiku-4-5',
      defaultReasoningEffort: 'xhigh',
      contextLimit: 0,
      preserveCurrentProvider: true,
    );
    final write = session.requests.singleWhere(
      (request) => request['method'] == 'agent/settings/write',
    );
    // The sub-agent default always travels with the write, blank included: a
    // stale server value would otherwise keep pinning delegated work.
    expect(write['params'], {
      'baseUrl': 'https://example.invalid',
      'apiKey': '',
      'proxyUrl': '',
      'defaultModel': 'claude-opus-5-5',
      'defaultSubagentModel': 'claude-haiku-4-5',
      'defaultReasoningEffort': 'xhigh',
      'contextLimit': 0,
    });
    final result = await client.testGlobalSettings(
      profile,
      baseUrl: 'https://draft.invalid',
      apiKey: 'draft-token',
      proxyUrl: '',
      testModel: 'claude-opus-5-5',
    );
    expect(result.successful, true);
    final test = session.requests.singleWhere(
      (request) => request['method'] == 'agent/settings/test',
    );
    expect((test['params'] as Map)['apiKey'], 'draft-token');
    final models = await client.fetchApiModels(
      profile,
      baseUrl: '',
      apiKey: '',
      proxyUrl: '',
    );
    expect(models, hasLength(2));
    expect(models.first.modelId, 'claude-opus-5-5');
    expect(models.first.contextWindowTokens, 1000000);
    expect(models.last.contextWindowTokens, 0);
    expect(host.commands, isEmpty);
    expect(host.scripts, isEmpty);
  });

  test(
    'installed bridge bundles settings with a single hash and no relative require dependency',
    () async {
      final source = await ClaudeCodeBridgeAsset.load(bundle: _BridgeAssets());
      expect(source, startsWith('#!/usr/bin/env node\n'));
      expect(RegExp(r'^#!', multiLine: true).allMatches(source), hasLength(1));
      final fixture = await _RuntimeFixture.create();
      addTearDown(fixture.close);
      final result = await fixture.script(
        ClaudeCodeBootstrap.installScript(bridgeSource: source),
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final launched = await fixture.script(
        'exec ~/.local/bin/codex-remote-claude-bridge',
      );
      expect(launched.exitCode, 0, reason: '${launched.stderr}');
      expect(launched.stdout, 'settings-ready\n');
    },
  );

  test(
    'installs large bridge sources without putting base64 content in argv',
    () async {
      final fixture = await _RuntimeFixture.create();
      addTearDown(fixture.close);
      final source = 'console.log("large");\n${List.filled(300000, 'x').join()}';
      final script = ClaudeCodeBootstrap.installScript(bridgeSource: source);
      expect(script, contains('process.stdin.on("data"'));
      expect(script, isNot(contains('process.argv[2]')));
      expect(script.length, greaterThan(131072));
      final result = await fixture.scriptFromStdin(script);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(
        await File(
          '${fixture.directory.path}/.local/share/codex-remote/claude/bridge.cjs',
        ).readAsString(),
        source,
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

class _RuntimeFixture {
  _RuntimeFixture(this.directory);
  final Directory directory;

  static Future<_RuntimeFixture> create() async {
    final fixture = _RuntimeFixture(
      await Directory.systemTemp.createTemp('claude bootstrap '),
    );
    await Directory(
      '${fixture.directory.path}/.local/bin',
    ).create(recursive: true);
    final node = await Process.run('/bin/sh', ['-c', 'command -v node']);
    await Link(
      '${fixture.directory.path}/.local/bin/node',
    ).create((node.stdout as String).trim());
    await Directory('${fixture.directory.path}/.claude').create();
    await Directory('${fixture.directory.path}/.codex').create();
    await File(
      '${fixture.directory.path}/.claude/settings.json',
    ).writeAsString('{"user":"retained"}');
    await File(
      '${fixture.directory.path}/.codex/codex-remote.env',
    ).writeAsString('export CODEX_ONLY_SENTINEL=wrong\n');
    await fixture.writeCli('2.1.150');
    return fixture;
  }

  Future<void> writeCli(String version) async {
    final cli = File('${directory.path}/.local/bin/claude');
    await cli.writeAsString(
      '#!/bin/sh\nprintf "%s\\n" "$version (Claude Code)"\n',
    );
    await Process.run('chmod', ['700', cli.path]);
  }

  Future<ProcessResult> script(String source, {String? path}) async =>
      Process.run(
        '/bin/sh',
        ['-c', source],
        environment: {
          'HOME': directory.path,
          'PATH': path ?? '${directory.path}/.local/bin:/usr/bin:/bin',
        },
        includeParentEnvironment: false,
      );

  Future<ProcessResult> scriptFromStdin(String source, {String? path}) async {
    final process = await Process.start(
      '/bin/sh',
      ['-s'],
      environment: {
        'HOME': directory.path,
        'PATH': path ?? '${directory.path}/.local/bin:/usr/bin:/bin',
      },
      includeParentEnvironment: false,
    );
    final stdout = process.stdout.transform(utf8.decoder).join();
    final stderr = process.stderr.transform(utf8.decoder).join();
    process.stdin.write(source);
    await process.stdin.close();
    final exitCode = await process.exitCode;
    return ProcessResult(process.pid, exitCode, await stdout, await stderr);
  }

  Future<void> close() => directory.delete(recursive: true);
}

class _Host
    implements
        RemoteServerClient,
        RemoteServerScriptClient,
        RemoteServerStreamingScriptClient {
  final commands = <String>[];
  final scripts = <String>[];
  @override
  bool get isConnected => true;
  @override
  Future<void> get done => Completer<void>().future;
  @override
  Future<String> run(
    String command, {
    Duration timeout = const Duration(seconds: 15),
    int maxOutputBytes = 1024 * 1024,
  }) async {
    commands.add(command);
    return '';
  }

  @override
  Future<String> runShellScript(
    String script, {
    Duration timeout = const Duration(seconds: 15),
    int maxOutputBytes = 1024 * 1024,
  }) async {
    scripts.add(script);
    return '';
  }

  @override
  Future<String> runStreamingShellScript(
    String script, {
    String command = 'sh -s',
    Duration timeout = const Duration(minutes: 30),
    int maxOutputBytes = 8 * 1024 * 1024,
    void Function(String)? onStdoutLine,
    void Function(String)? onStderrLine,
  }) async {
    scripts.add(script);
    onStdoutLine?.call('diagnostic, not completion');
    onStdoutLine?.call('::progress::25||校验连接组件|CLI 已就绪');
    return '';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Session implements CodexSession {
  final requests = <Map<String, dynamic>>[];
  final _stdout = StreamController<Uint8List>();
  final _stderr = StreamController<Uint8List>();
  final _done = Completer<void>();
  @override
  Stream<Uint8List> get stdout => _stdout.stream;
  @override
  Stream<Uint8List> get stderr => _stderr.stream;
  @override
  Future<void> get done => _done.future;
  @override
  void write(Uint8List data) {
    final request = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
    requests.add(request);
    if (request['id'] == null) return;
    final result = switch (request['method']) {
      'thread/start' => {
        'thread': {'id': 'claude-thread', 'cwd': '/workspace'},
      },
      'turn/start' => {
        'turn': {'id': 'claude-turn'},
      },
      'agent/settings/read' => {
        'model': 'm-claude',
        'reasoningEffort': 'high',
        'modelProvider': 'anthropic',
        'apiKey': 'fixture-token',
        'hasStoredAuthentication': true,
      },
      'agent/settings/test' => {'successful': true, 'message': 'API 连接成功'},
      'agent/models/list' => [
        {
          'modelId': 'claude-opus-5-5',
          'displayName': 'Opus 5.5',
          'contextWindowTokens': 1000000,
        },
        {'modelId': 'claude-opus-5-5'},
        {'modelId': 'custom', 'contextWindowTokens': -1},
        {'modelId': ''},
      ],
      'thread/resume' => {
        'thread': {
          'id': 'claude-thread',
          'cwd': '/workspace',
          'turns': [
            {
              'id': 'claude-turn',
              'status': 'completed',
              'items': [
                {'id': 'reply', 'type': 'agentMessage', 'text': 'Claude reply'},
              ],
            },
          ],
        },
      },
      _ => <String, Object?>{},
    };
    _stdout.add(
      Uint8List.fromList(
        utf8.encode('${jsonEncode({'id': request['id'], 'result': result})}\n'),
      ),
    );
  }

  @override
  void terminate() {
    if (!_done.isCompleted) _done.complete();
    unawaited(_stdout.close());
    unawaited(_stderr.close());
  }
}

class _LocalHost extends _Host implements LocalRemoteServerClient {}

class _BridgeAssets extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    final source = key == claudeCodeSettingsAssetPath
        ? 'globalThis.__claudeRemoteSettings = {readSettings: () => "settings-ready"};'
        : '#!/usr/bin/env node\nconsole.log(globalThis.__claudeRemoteSettings.readSettings());';
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(source)));
  }
}
