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

// Run the real generated installer and real Node, substituting only npm's
// network/package work. A regular node wrapper is needed by the runtime probe.
Future<Directory> _createInstallHome() async {
  final home = await Directory.systemTemp.createTemp('opencode-install-');
  addTearDown(() => home.delete(recursive: true));
  final node = await Process.run('node', ['-p', 'process.execPath']);
  expect(node.exitCode, 0, reason: '${node.stderr}');
  final bin = '${home.path}/.local/share/codex-remote/runtime/node/bin';
  await _writeFile(
    '$bin/node',
    '#!/bin/sh\nexec ${shellQuote((node.stdout as String).trim())} "\$@"\n',
  );
  await _writeFile(
    '$bin/npm',
    '#!/bin/sh\nexec "\$(dirname "\$0")/node" "\$(dirname "\$0")/npm.cjs" "\$@"\n',
  );
  await _writeFile('$bin/npm.cjs', r'''
const fs = require('node:fs');
const dependencies = JSON.parse(fs.readFileSync('package.json', 'utf8')).dependencies;
const packages = Object.fromEntries(Object.entries(dependencies).map(([name, version]) =>
  [`node_modules/${name}`, {version}]));
if (process.argv[2] === 'install') {
  fs.writeFileSync('package-lock.json', JSON.stringify({packages}));
} else if (process.argv[2] === 'ci') {
  fs.mkdirSync('node_modules/.bin', {recursive: true});
  for (const [path, pkg] of Object.entries(packages)) {
    fs.mkdirSync(`${path}/bin`, {recursive: true});
    fs.writeFileSync(`${path}/package.json`, JSON.stringify(pkg));
    if (path.includes('opencode-linux-')) {
      fs.writeFileSync(`${path}/bin/opencode`, `#!/bin/sh\nprintf '%s\\n' '${pkg.version}'\n`, {mode: 0o700});
    }
  }
} else {
  throw new Error(`Unexpected npm command: ${process.argv[2]}`);
}
''');
  final chmod = await Process.run('chmod', ['700', '$bin/node', '$bin/npm']);
  expect(chmod.exitCode, 0);
  return home;
}

Future<_ShellResult> _runWrapper(
  String wrapper, {
  required String home,
  List<String> arguments = const <String>[],
}) async {
  final directory = await Directory.systemTemp.createTemp(
    'flutter-opencode-wrapper-script-',
  );
  final file = File('${directory.path}/wrapper.sh');
  await file.writeAsString(wrapper);
  try {
    final environment = Map<String, String>.of(Platform.environment)
      ..['HOME'] = home;
    final process = await Process.start('sh', <String>[
      file.path,
      ...arguments,
    ], environment: environment);
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
  } finally {
    await directory.delete(recursive: true);
  }
}

String _extractWrapper(String installScript) {
  const startMarker = 'cat > "\$WRAPPER" <<\'EOF\'\n';
  const endMarker = '\nEOF\nchmod 700 "\$WRAPPER"';
  final start = installScript.indexOf(startMarker);
  final end = installScript.indexOf(endMarker, start + startMarker.length);
  if (start < 0 || end < 0) {
    throw StateError('OpenCode wrapper marker missing from install script');
  }
  return installScript.substring(start + startMarker.length, end);
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
__CODEX_REMOTE_OPENCODE_LAUNCHER_PROTOCOL=2
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
    test('is bundled and matches the reviewed Flutter bridge', () async {
      final source = await OpenCodeBridgeAsset.load();

      expect(source, startsWith('"use strict";'));
      expect(source, contains('module.exports = {'));
      expect(
        OpenCodeBootstrap.bridgeSha256(source),
        '96fb3fd7cdb29a8a3952d91dd5b4f85fee51c85fe43a7339ae269db0fdc8a4ba',
      );
    });

    test(
      'production bridge reports cache-inclusive input without a known window',
      () async {
        final result = await Process.run('node', [
          '-e',
          r'''
const assert = require('node:assert/strict');
const bridge = require(process.argv[1]);
const info = {tokens: {input: 11, output: 5, reasoning: 2, cache: {read: 7, write: 3}}};
const usage = bridge.mapMessageTokenUsage(info, 400000);
assert.deepEqual(usage.last, {
  cachedInputTokens: 7, inputTokens: 21, outputTokens: 7,
  reasoningOutputTokens: 2, totalTokens: 28,
});
assert.equal(usage.modelContextWindow, 400000);
assert.deepEqual(bridge.mapMessageTokenUsage(info, 0).last, usage.last);
assert.equal(bridge.mapMessageTokenUsage({tokens: {}}, 0), null);
assert.equal(bridge.mapMessageTokenUsage({tokens: {input: -1, output: 'invalid'}}, 0), null);
''',
          File('assets/opencode-bridge.cjs').absolute.path,
        ]);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
      },
    );
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

    test(
      'targets the selected release instead of discovering the latest',
      () async {
        const version = '1.17.0';
        final script = OpenCodeBootstrap.combinedProbeScriptFor(
          openCodeVersion: version,
        );

        expect(
          script,
          contains(
            r'OPENCODE_BIN="$ROOT/opencode/releases/1.17.0/node_modules/.bin/opencode"',
          ),
        );
        expect(script, isNot(contains('find -L')));

        final syntax = await _runShell(script, arguments: const <String>['-n']);
        expect(syntax.exitCode, 0, reason: syntax.stderr);
      },
    );

    test('runtime inspection compares against the selected release', () {
      const bridge = 'bridge';
      const version = '1.17.0';
      final bridgeHash = OpenCodeBootstrap.bridgeSha256(bridge);
      final output = _combinedProbeOutput(
        version: version,
        bridgeHash: bridgeHash,
      );

      final matching = OpenCodeBootstrap.inspect(
        output,
        bridgeSource: bridge,
        openCodeVersion: version,
      );
      final different = OpenCodeBootstrap.inspect(output, bridgeSource: bridge);

      expect(matching.detectedVersion, version);
      expect(
        matching.compatibleCommand,
        "'/home/dev/.local/bin/codex-remote-opencode-bridge' "
        "--version '$version'",
      );
      expect(different.detectedVersion, version);
      expect(different.compatibleCommand, isNull);
    });

    test('requires an exact version token', () {
      expect(
        OpenCodeBootstrap.versionMatches('OpenCode 1.18.11', '1.18.11'),
        isTrue,
      );
      expect(
        OpenCodeBootstrap.versionMatches('OpenCode 1.18.110', '1.18.11'),
        isFalse,
      );
      expect(
        OpenCodeBootstrap.versionMatches('OpenCode 11.18.11', '1.18.11'),
        isFalse,
      );
      expect(
        OpenCodeBootstrap.versionMatches('OpenCode v1.18.11', '1.18.11'),
        isTrue,
      );
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
        "'/home/dev/.local/bin/codex-remote-opencode-bridge' "
        "--version '$pinnedOpenCodeVersion'",
      );
      expect(inspection.installationProblem, isNull);

      final staleBridge = OpenCodeBootstrap.inspect(
        _combinedProbeOutput(bridgeHash: List.filled(64, '0').join()),
        bridgeSource: bridge,
      );
      expect(staleBridge.detectedVersion, pinnedOpenCodeVersion);
      expect(staleBridge.compatibleCommand, isNull);
      expect(staleBridge.installationProblem, isNull);

      final oldLauncher = OpenCodeBootstrap.inspect(
        output.replaceAll('__CODEX_REMOTE_OPENCODE_LAUNCHER_PROTOCOL=2\n', ''),
        bridgeSource: bridge,
      );
      expect(oldLauncher.compatibleCommand, isNull);
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
    test(
      'installs the production bridge above the Linux argument limit',
      () async {
        final home = await _createInstallHome();
        final bridge = await OpenCodeBridgeAsset.load();
        expect(
          base64Encode(utf8.encode(bridge)).length,
          greaterThan(128 * 1024),
        );
        const version = '1.19.3';
        final root = '${home.path}/.local/share/codex-remote';
        await _writeFile('$root/runtime/keep', 'shared runtime');
        final result = await _runShell(
          OpenCodeBootstrap.installScript(
            openCodeVersion: version,
            bridgeSource: bridge,
          ),
          home: home.path,
        );
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(result.stdout, contains('安装完成'));
        final installed = File('$root/opencode/bridge.cjs');
        expect(await installed.readAsBytes(), utf8.encode(bridge));
        expect((await installed.stat()).mode & 0x1ff, 0x180);
        expect(
          (await File('$root/opencode/bridge.sha256').readAsString()).trim(),
          OpenCodeBootstrap.bridgeSha256(bridge),
        );
        final probe = await _runShell(
          OpenCodeBootstrap.probeScriptFor(openCodeVersion: version),
          home: home.path,
        );
        expect(probe.exitCode, 0, reason: probe.stderr);
        expect(OpenCodeBootstrap.parseProbe(probe.stdout).version, version);
        expect(
          OpenCodeBootstrap.parseProbe(probe.stdout).bridgeSha256,
          OpenCodeBootstrap.bridgeSha256(bridge),
        );
        expect(
          await File('$root/runtime/keep').readAsString(),
          'shared runtime',
        );
        expect(
          Directory(
            '$root/opencode',
          ).listSync().where((entry) => entry.path.contains('/.install-')),
          isEmpty,
        );
      },
    );

    for (final invalid in ['checksum', 'syntax']) {
      test(
        'preserves the installed release when bridge $invalid fails',
        () async {
          final home = await _createInstallHome();
          final root = '${home.path}/.local/share/codex-remote/opencode';
          final oldFiles = [
            '$root/bridge.cjs',
            '$root/bridge.sha256',
            '$root/releases/1.19.3/keep',
            '${home.path}/.local/bin/codex-remote-opencode-bridge',
          ];
          for (final path in oldFiles) {
            await _writeFile(path, 'previous install');
          }
          const validSource = 'console.log("ok");';
          var script = OpenCodeBootstrap.installScript(
            openCodeVersion: '1.19.3',
            bridgeSource: invalid == 'syntax' ? 'function {' : validSource,
          );
          if (invalid == 'checksum') {
            script = script.replaceAll(
              base64Encode(utf8.encode(validSource)),
              base64Encode(utf8.encode('console.log("tampered");')),
            );
          }
          final result = await _runShell(script, home: home.path);
          expect(result.exitCode, isNot(0), reason: result.stdout);
          expect(
            result.stderr,
            contains(invalid == 'checksum' ? '完整性校验失败' : 'SyntaxError'),
          );
          for (final path in oldFiles) {
            expect(await File(path).readAsString(), 'previous install');
          }
          expect(
            Directory(
              root,
            ).listSync().where((entry) => entry.path.contains('/.install-')),
            isEmpty,
          );
        },
      );
    }

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
      expect(script, contains('PLATFORM_PACKAGE=opencode-linux-x64-baseline'));
      expect(script, isNot(contains('opencode-linux-arm64-musl')));
      expect(script, isNot(contains('opencode-linux-x64-musl')));
      expect(script, contains('--ignore-scripts'));
      expect(script, contains('--omit=optional'));
      expect(script, contains('ln -s "../\$PLATFORM_PACKAGE/bin/opencode"'));
      expect(script, contains('PROXY=${shellQuote(proxy)}'));
      expect(script, contains('HTTP_PROXY="\$PROXY"'));
      expect(script, contains(OpenCodeBootstrap.bridgeSha256(bridge)));
      expect(script, contains('bridge.sha256'));
      expect(script, isNot(contains(bridge)));
      expect(script, isNot(contains('__BRIDGE_BASE64_SHELL__')));

      final syntax = await _runShell(script, arguments: const <String>['-n']);
      expect(syntax.exitCode, 0, reason: syntax.stderr);
    });

    test('installs the selected release into its versioned path', () async {
      const bridge = 'bridge';
      const version = '1.17.0';
      final script = OpenCodeBootstrap.installScript(
        bridgeSource: bridge,
        openCodeVersion: version,
      );

      expect(script, contains(r'RELEASE="$OPENCODE_ROOT/releases/1.17.0"'));
      expect(script, contains('opencode-ai":"$version"'));
      expect(script, contains('"$version"'));
      expect(script, contains('OPEN_CODE_VERSION="1.17.0"'));
      expect(
        script,
        contains(
          r'OPENCODE_BIN="$ROOT/opencode/releases/$OPEN_CODE_VERSION/node_modules/.bin/opencode"',
        ),
      );
      final syntax = await _runShell(script, arguments: const <String>['-n']);
      expect(syntax.exitCode, 0, reason: syntax.stderr);
    });

    test(
      'wrapper selects the requested release even when another is newer',
      () async {
        const selected = pinnedOpenCodeVersion;
        const newer = '1.20.0';
        final home = await Directory.systemTemp.createTemp(
          'flutter-opencode-wrapper-',
        );
        try {
          final script = OpenCodeBootstrap.installScript(
            bridgeSource: 'bridge',
            openCodeVersion: newer,
          );
          await _writeFile(
            '${home.path}/.local/share/codex-remote/runtime/node/bin/node',
            '#!/bin/sh\n'
                'printf "OPENCODE_BIN=%s\\n" "\$OPENCODE_BIN"\n'
                'printf "ARG=%s\\n" "\$@"\n',
          );
          for (final version in <String>[selected, newer]) {
            await _writeFile(
              '${home.path}/.local/share/codex-remote/opencode/releases/'
                  '$version/node_modules/.bin/opencode',
              "#!/bin/sh\nprintf '%s\\n' '$version'\n",
            );
          }
          final nodePath =
              '${home.path}/.local/share/codex-remote/runtime/node/bin/node';
          await Process.run('chmod', <String>['u+x', nodePath]);
          for (final version in <String>[selected, newer]) {
            final executablePath =
                '${home.path}/.local/share/codex-remote/opencode/releases/'
                '$version/node_modules/.bin/opencode';
            await Process.run('chmod', <String>['u+x', executablePath]);
          }
          final wrapper = _extractWrapper(script);
          var result = await _runWrapper(
            wrapper,
            home: home.path,
            arguments: const <String>['--version', selected],
          );
          expect(result.exitCode, 0, reason: result.stderr);
          expect(
            result.stdout,
            contains(
              'OPENCODE_BIN=${home.path}/.local/share/codex-remote/'
              'opencode/releases/$selected/node_modules/.bin/opencode',
            ),
          );

          result = await _runWrapper(
            wrapper,
            home: home.path,
            arguments: <String>['--version', newer, '--directory', '/srv/team'],
          );
          expect(result.exitCode, 0, reason: result.stderr);
          expect(
            result.stdout,
            contains(
              'OPENCODE_BIN=${home.path}/.local/share/codex-remote/'
              'opencode/releases/$newer/node_modules/.bin/opencode',
            ),
          );
          expect(result.stdout, contains('ARG=--directory'));
          expect(result.stdout, contains('ARG=/srv/team'));
          expect(result.stdout, isNot(contains('ARG=--version')));

          final probe = await _runShell(
            OpenCodeBootstrap.probeScriptFor(openCodeVersion: selected),
            home: home.path,
          );
          expect(probe.exitCode, 0, reason: probe.stderr);
          expect(OpenCodeBootstrap.parseProbe(probe.stdout).version, selected);
        } finally {
          await home.delete(recursive: true);
        }
      },
    );

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
