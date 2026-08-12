import 'dart:convert';
import 'dart:io';

import 'package:codex_remote/src/agent/open_code_bootstrap.dart';
import 'package:codex_remote/src/agent/open_code_bridge_asset.dart';
import 'package:codex_remote/src/agent/remote_bootstrap.dart';
import 'package:flutter_test/flutter_test.dart';

Future<_ShellResult> _runShell(
  String script, {
  String? home,
  List<String> arguments = const <String>['-s'],
}) async {
  final environment = Map<String, String>.of(Platform.environment);
  if (home != null) environment['HOME'] = home;
  final process = await Process.start(
    'sh',
    arguments,
    environment: environment,
  );
  process.stdin.write(script);
  await process.stdin.close();
  final results = await Future.wait<Object>(<Future<Object>>[
    process.stdout.transform(utf8.decoder).join(),
    process.stderr.transform(utf8.decoder).join(),
    process.exitCode,
  ]);
  return _ShellResult(
    stdout: results[0] as String,
    stderr: results[1] as String,
    exitCode: results[2] as int,
  );
}

Future<void> _writeFile(String path, String contents) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsString(contents);
}

String _combinedProbeOutput({
  String os = 'Linux',
  String version = pinnedOpenCodeVersion,
  String? bridgeHash,
}) =>
    '''
login banner
__CODEX_REMOTE_OS=$os
__CODEX_REMOTE_ARCH=x86_64
__CODEX_REMOTE_HOME=/home/dev
__CODEX_REMOTE_LIBC=glibc
__CODEX_REMOTE_HAS_SHELL=1
__CODEX_REMOTE_HAS_TAR=1
__CODEX_REMOTE_HAS_SHA256=1
__CODEX_REMOTE_HAS_FLOCK=1
__CODEX_REMOTE_HAS_SETSID_WAIT=1
__CODEX_REMOTE_DOWNLOADER=curl
__CODEX_REMOTE_OPENCODE_PATH=/home/dev/.local/share/codex-remote/opencode/releases/$version/node_modules/.bin/opencode
__CODEX_REMOTE_OPENCODE_VERSION=$version
__CODEX_REMOTE_OPENCODE_BRIDGE=/home/dev/.local/bin/codex-remote-opencode-bridge
__CODEX_REMOTE_OPENCODE_BRIDGE_SHA256=${bridgeHash ?? 'missing'}
''';

class _ShellResult {
  const _ShellResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
  });

  final String stdout;
  final String stderr;
  final int exitCode;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('OpenCode bridge asset', () {
    test('is bundled and matches the reviewed Kotlin bridge', () async {
      final source = await OpenCodeBridgeAsset.load();

      expect(source, startsWith('"use strict";'));
      expect(source, contains('module.exports = {'));
      expect(
        OpenCodeBootstrap.bridgeSha256(source),
        '56e7ff47749278e1c60ac46294bae0ebbdd835b7607f2bc8930ba906777763d5',
      );
    });
  });

  group('OpenCode runtime probe', () {
    test('combines host and OpenCode checks with valid shell syntax', () async {
      expect(OpenCodeBootstrap.combinedProbeScript, contains('value OS '));
      expect(
        OpenCodeBootstrap.combinedProbeScript,
        contains('__CODEX_REMOTE_OPENCODE_%s=%s'),
      );
      expect(OpenCodeBootstrap.probeScript, contains('find -L'));
      expect(
        OpenCodeBootstrap.probeScript,
        contains('node_modules/.bin/opencode'),
      );

      final syntax = await _runShell(
        OpenCodeBootstrap.combinedProbeScript,
        arguments: const <String>['-n'],
      );

      expect(syntax.exitCode, 0, reason: syntax.stderr);
    });

    test('requires the pinned version, launcher, and exact bridge hash', () {
      const bridge = "console.log('bridge');\n";
      final hash = OpenCodeBootstrap.bridgeSha256(bridge);
      final output = _combinedProbeOutput(bridgeHash: hash);
      expect(
        OpenCodeBootstrap.parseProbe(output).executablePath,
        '/home/dev/.local/share/codex-remote/opencode/releases/'
        '$pinnedOpenCodeVersion/node_modules/.bin/opencode',
      );
      final inspection = OpenCodeBootstrap.inspect(
        output,
        bridgeSource: bridge,
      );

      expect(inspection.detectedVersion, pinnedOpenCodeVersion);
      expect(
        inspection.compatibleCommand,
        "'/home/dev/.local/bin/codex-remote-opencode-bridge'",
      );
      expect(inspection.installationProblem, isNull);

      final staleBridge = OpenCodeBootstrap.inspect(
        _combinedProbeOutput(bridgeHash: List.filled(64, '0').join()),
        bridgeSource: bridge,
      );
      expect(staleBridge.detectedVersion, pinnedOpenCodeVersion);
      expect(staleBridge.compatibleCommand, isNull);
      expect(staleBridge.installationProblem, isNull);
    });

    test(
      'preserves host prerequisite failures and ignores unrelated output',
      () {
        const bridge = 'bridge';
        final probe = OpenCodeBootstrap.parseProbe('''
noise
__CODEX_REMOTE_OPENCODE_VERSION=$pinnedOpenCodeVersion
__CODEX_REMOTE_OPENCODE_BRIDGE=/tmp/a=b
__CODEX_REMOTE_OPENCODE_INVALID
''');
        expect(probe.version, pinnedOpenCodeVersion);
        expect(probe.executablePath, isNull);
        expect(probe.bridgePath, '/tmp/a=b');
        expect(probe.bridgeSha256, isNull);

        final inspection = OpenCodeBootstrap.inspect(
          _combinedProbeOutput(
            os: 'Darwin',
            bridgeHash: OpenCodeBootstrap.bridgeSha256(bridge),
          ),
          bridgeSource: bridge,
        );
        expect(inspection.compatibleCommand, isNull);
        expect(inspection.installationProblem, contains('Darwin'));
      },
    );
  });

  group('OpenCode managed install', () {
    test('uses pinned packages, bridge hash, and HTTP proxy', () async {
      const bridge = "console.log('bridge');\n";
      const proxy = r"https://example.com/'$(touch${IFS}/tmp/injected)'";
      final script = OpenCodeBootstrap.installScript(
        bridgeSource: bridge,
        proxyUrl: proxy,
      );

      expect(
        OpenCodeBootstrap.installNodeRuntimeScript(),
        isNot(contains('@openai/codex')),
      );
      expect(script, contains('opencode-ai":"$pinnedOpenCodeVersion"'));
      expect(script, contains('jsonc-parser":"3.3.1"'));
      expect(
        script,
        contains('npm_config_registry=https://registry.npmmirror.com'),
      );
      expect(script, contains('aarch64|arm64) PLATFORM_PACKAGE='));
      expect(script, contains('PLATFORM_PACKAGE=opencode-linux-arm64'));
      expect(script, contains('PLATFORM_PACKAGE=opencode-linux-x64'));
      expect(
        script,
        contains('PLATFORM_PACKAGE=opencode-linux-x64-baseline'),
      );
      expect(script, isNot(contains('opencode-linux-arm64-musl')));
      expect(script, isNot(contains('opencode-linux-x64-musl')));
      expect(script, contains('--ignore-scripts'));
      expect(script, contains('--omit=optional'));
      expect(
        script,
        contains('ln -s "../\$PLATFORM_PACKAGE/bin/opencode"'),
      );
      expect(script, contains('PROXY=${shellQuote(proxy)}'));
      expect(script, contains('HTTP_PROXY="\$PROXY"'));
      expect(script, contains(OpenCodeBootstrap.bridgeSha256(bridge)));
      expect(script, contains('bridge.sha256'));
      expect(script, isNot(contains(bridge)));
      expect(script, isNot(contains('__BRIDGE_BASE64_SHELL__')));

      final syntax = await _runShell(script, arguments: const <String>['-n']);
      expect(syntax.exitCode, 0, reason: syntax.stderr);
    });

    test('rejects empty bridge, invalid version, and unsupported proxy', () {
      expect(
        () => OpenCodeBootstrap.installScript(bridgeSource: '  '),
        throwsArgumentError,
      );
      expect(
        () => OpenCodeBootstrap.installScript(
          bridgeSource: 'bridge',
          openCodeVersion: '1.2.3; touch /tmp/injected',
        ),
        throwsArgumentError,
      );
      expect(
        () => OpenCodeBootstrap.installScript(
          bridgeSource: 'bridge',
          proxyUrl: 'socks5://127.0.0.1:7890',
        ),
        throwsArgumentError,
      );
    });

    test('uninstaller removes only OpenCode-managed files', () async {
      final home = await Directory.systemTemp.createTemp(
        'flutter-opencode-uninstall-',
      );
      final openCodeRoot = Directory(
        '${home.path}/.local/share/codex-remote/opencode',
      );
      final openCodeWrapper = File(
        '${home.path}/.local/bin/codex-remote-opencode-bridge',
      );
      final sharedNode = File(
        '${home.path}/.local/share/codex-remote/runtime/node/bin/node',
      );
      final codexWrapper = File('${home.path}/.local/bin/codex-remote');
      final upload = File('${home.path}/.codex-mobile/uploads/attachment.txt');
      final accountState = File('${home.path}/.codex/auth.json');
      final vscodeState = File(
        '${home.path}/.vscode-server/extensions/openai.chatgpt/state.json',
      );
      try {
        await _writeFile('${openCodeRoot.path}/bridge.cjs', 'managed');
        await _writeFile(openCodeWrapper.path, 'managed');
        await _writeFile(sharedNode.path, 'shared');
        await _writeFile(codexWrapper.path, 'codex');
        await _writeFile(upload.path, 'upload');
        await _writeFile(accountState.path, 'account');
        await _writeFile(vscodeState.path, 'vscode');

        final result = await _runShell(
          OpenCodeBootstrap.uninstallScript,
          home: home.path,
        );

        expect(result.exitCode, 0, reason: result.stderr);
        expect(await openCodeRoot.exists(), isFalse);
        expect(await openCodeWrapper.exists(), isFalse);
        expect(await sharedNode.exists(), isTrue);
        expect(await codexWrapper.exists(), isTrue);
        expect(await upload.exists(), isTrue);
        expect(await accountState.exists(), isTrue);
        expect(await vscodeState.exists(), isTrue);
      } finally {
        await home.delete(recursive: true);
      }
    });
  });
}
