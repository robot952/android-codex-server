import 'dart:convert';
import 'dart:io';

import 'package:codex_remote/src/agent/remote_bootstrap.dart';
import 'package:flutter_test/flutter_test.dart';

AgentRuntimeInspection _supportedInspection({
  String os = 'Linux',
  String architecture = 'x86_64',
  String libc = 'glibc',
  bool hasShell = true,
  bool hasTar = true,
  bool hasSha256 = true,
  bool hasFlock = true,
  bool hasSetsidWait = true,
  String? downloader = 'curl',
}) => AgentRuntimeInspection(
  os: os,
  architecture: architecture,
  home: '/home/dev',
  libc: libc,
  hasShell: hasShell,
  hasTar: hasTar,
  hasSha256: hasSha256,
  hasFlock: hasFlock,
  hasSetsidWait: hasSetsidWait,
  downloader: downloader,
);

Future<void> _writeFile(String path, String contents) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsString(contents);
}

Future<_ShellResult> _runShell(
  String script, {
  String? home,
  List<String> arguments = const <String>['-s'],
  Map<String, String> environmentOverrides = const <String, String>{},
}) async {
  final environment = Map<String, String>.of(Platform.environment);
  if (home != null) environment['HOME'] = home;
  environment.addAll(environmentOverrides);
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

List<RemoteInstallProgress> _progressRecords(String output) =>
    const LineSplitter()
        .convert(output)
        .map(parseRemoteInstallProgressLine)
        .whereType<RemoteInstallProgress>()
        .toList();

void main() {
  group('remote probe', () {
    test('parses a compatible managed Codex command and ignores noise', () {
      final inspection = RemoteBootstrap.parseProbe('''
login banner
__CODEX_REMOTE_OS=Linux
__CODEX_REMOTE_ARCH=x86_64
__CODEX_REMOTE_HOME=/home/dev
__CODEX_REMOTE_LIBC=glibc
__CODEX_REMOTE_MANAGED_PATH=/home/dev/.local/bin/codex-remote
__CODEX_REMOTE_MANAGED_VERSION=codex-cli $pinnedCodexVersion
__CODEX_REMOTE_SYSTEM_PATH=/usr/local/bin/codex
__CODEX_REMOTE_SYSTEM_VERSION=codex-cli 0.1.0
__CODEX_REMOTE_HAS_SHELL=1
__CODEX_REMOTE_HAS_TAR=1
__CODEX_REMOTE_HAS_SHA256=1
__CODEX_REMOTE_HAS_FLOCK=1
__CODEX_REMOTE_HAS_SETSID_WAIT=1
__CODEX_REMOTE_DOWNLOADER=curl
__CODEX_REMOTE_INVALID
''');

      expect(inspection.os, 'Linux');
      expect(inspection.architecture, 'x86_64');
      expect(inspection.home, '/home/dev');
      expect(inspection.libc, 'glibc');
      expect(inspection.downloader, 'curl');
      expect(inspection.detectedVersion, 'codex-cli $pinnedCodexVersion');
      expect(
        inspection.compatibleCommand,
        "'/home/dev/.local/bin/codex-remote' app-server --listen stdio://",
      );
      expect(inspection.installationProblem, isNull);
    });

    test('uses an exact system version but rejects a different version', () {
      final compatible = RemoteBootstrap.parseProbe('''
__CODEX_REMOTE_OS=Linux\r
__CODEX_REMOTE_ARCH=arm64\r
__CODEX_REMOTE_HOME=/root\r
__CODEX_REMOTE_LIBC=glibc\r
__CODEX_REMOTE_SYSTEM_PATH=/opt/codex cli/bin/codex\r
__CODEX_REMOTE_SYSTEM_VERSION=codex-cli $pinnedCodexVersion\r
__CODEX_REMOTE_HAS_SHELL=1\r
__CODEX_REMOTE_HAS_TAR=1\r
__CODEX_REMOTE_HAS_SHA256=1\r
__CODEX_REMOTE_HAS_FLOCK=1\r
__CODEX_REMOTE_HAS_SETSID_WAIT=1\r
__CODEX_REMOTE_DOWNLOADER=wget\r
''');
      final incompatible = RemoteBootstrap.parseProbe('''
__CODEX_REMOTE_OS=Linux
__CODEX_REMOTE_ARCH=arm64
__CODEX_REMOTE_HOME=/root
__CODEX_REMOTE_LIBC=glibc
__CODEX_REMOTE_SYSTEM_PATH=/usr/bin/codex
__CODEX_REMOTE_SYSTEM_VERSION=codex-cli 0.145.0
__CODEX_REMOTE_HAS_SHELL=1
__CODEX_REMOTE_HAS_TAR=1
__CODEX_REMOTE_HAS_SHA256=1
__CODEX_REMOTE_HAS_FLOCK=1
__CODEX_REMOTE_HAS_SETSID_WAIT=1
__CODEX_REMOTE_DOWNLOADER=wget
''');

      expect(
        compatible.compatibleCommand,
        "'/opt/codex cli/bin/codex' app-server --listen stdio://",
      );
      expect(incompatible.compatibleCommand, isNull);
      expect(incompatible.detectedVersion, 'codex-cli 0.145.0');
      expect(incompatible.installationProblem, isNull);
    });

    test('matches the selected Codex runtime version', () {
      final inspection = RemoteBootstrap.parseProbe('''
__CODEX_REMOTE_OS=Linux
__CODEX_REMOTE_ARCH=x86_64
__CODEX_REMOTE_HOME=/home/dev
__CODEX_REMOTE_LIBC=glibc
__CODEX_REMOTE_SYSTEM_PATH=/usr/local/bin/codex
__CODEX_REMOTE_SYSTEM_VERSION=codex-cli 0.152.0
__CODEX_REMOTE_HAS_SHELL=1
__CODEX_REMOTE_HAS_TAR=1
__CODEX_REMOTE_HAS_SHA256=1
__CODEX_REMOTE_HAS_FLOCK=1
__CODEX_REMOTE_HAS_SETSID_WAIT=1
__CODEX_REMOTE_DOWNLOADER=curl
''', expectedVersion: '0.152.0');

      expect(inspection.compatibleCommand, contains('/usr/local/bin/codex'));
    });

    test('reports unsupported hosts and each required dependency', () {
      final cases = <(AgentRuntimeInspection, String)>[
        (_supportedInspection(os: 'Darwin'), 'Darwin'),
        (_supportedInspection(architecture: 'riscv64'), 'riscv64'),
        (_supportedInspection(libc: 'musl'), 'musl'),
        (_supportedInspection(hasShell: false), '/bin/sh'),
        (_supportedInspection(hasTar: false), 'tar'),
        (_supportedInspection(hasSha256: false), 'sha256sum'),
        (_supportedInspection(hasFlock: false), 'flock'),
        (_supportedInspection(hasSetsidWait: false), 'setsid'),
        (_supportedInspection(downloader: null), 'curl 或 wget'),
      ];

      for (final (inspection, expected) in cases) {
        expect(
          inspection.installationProblem,
          contains(expected),
          reason: '应报告缺失或不支持项：$expected',
        );
      }
      expect(_supportedInspection().installationProblem, isNull);
    });
  });

  group('proxy and progress', () {
    test('accepts only trimmed HTTP and HTTPS proxy URLs', () {
      expect(RemoteBootstrap.validateProxyUrl('   '), '');
      expect(
        RemoteBootstrap.validateProxyUrl(' http://127.0.0.1:7890 '),
        'http://127.0.0.1:7890',
      );
      expect(
        RemoteBootstrap.validateProxyUrl(
          'https://user:pass@example.com:8443/proxy',
        ),
        'https://user:pass@example.com:8443/proxy',
      );

      for (final value in <String>[
        'socks5://127.0.0.1:7890',
        'file:///tmp/proxy',
        'http:///missing-host',
        'http://127.0.0.1:bad',
        'http://127.0.0.1:7890\necho injected',
        'http://127.0.0.1:7890 proxy',
        'http://例子.测试:7890',
      ]) {
        expect(
          () => RemoteBootstrap.validateProxyUrl(value),
          throwsArgumentError,
          reason: '不应接受代理地址：$value',
        );
      }
    });

    test('shell-quotes proxy metacharacters instead of creating commands', () {
      const proxy = r"https://example.com/'$(touch${IFS}/tmp/injected)'";

      final script = RemoteBootstrap.installScript(proxyUrl: proxy);

      expect(RemoteBootstrap.validateProxyUrl(proxy), proxy);
      expect(shellQuote("a'b"), r"""'a'"'"'b'""");
      expect(script, contains('DOWNLOAD_PROXY=${shellQuote(proxy)}'));
      expect(script, isNot(contains('__PROXY_SHELL__')));
      expect(script, contains('HTTP_PROXY="\$DOWNLOAD_PROXY"'));
      expect(script, contains('npm_config_https_proxy="\$DOWNLOAD_PROXY"'));
    });

    test(
      'parses structured, legacy, bounded, and unrelated progress lines',
      () {
        final detailed = parseRemoteInstallProgressLine(
          '::progress::72|67|下载并安装 Codex CLI|已处理 24 / 36|18.4 MB',
        );
        final clamped = parseRemoteInstallProgressLine(
          '::progress::150|120|完成|全部完成',
        );
        final extended = parseRemoteInstallProgressLine(
          '::progress::65||下载依赖|总大小未知|1048576||262144|4',
        );
        final legacy = parseRemoteInstallProgressLine('::progress::-10|准备环境');

        expect(detailed?.percent, 72);
        expect(detailed?.downloadPercent, 67);
        expect(detailed?.message, '下载并安装 Codex CLI');
        expect(detailed?.detail, '已处理 24 / 36|18.4 MB');
        expect(clamped?.percent, 100);
        expect(clamped?.downloadPercent, 100);
        expect(extended?.downloadedBytes, 1048576);
        expect(extended?.totalBytes, isNull);
        expect(extended?.bytesPerSecond, 262144);
        expect(extended?.elapsedSeconds, 4);
        expect(extended?.indeterminate, isTrue);
        expect(legacy?.percent, 0);
        expect(legacy?.message, '准备环境');
        expect(parseRemoteInstallProgressLine('ordinary output'), isNull);
      },
    );

    test(
      'requires a positive total before displaying a download percentage',
      () {
        for (final total in <String>['', '0', '-1']) {
          final progress = parseRemoteInstallProgressLine(
            '::progress::68|14|下载依赖|进行中|1048576|$total|262144|4',
          );
          expect(progress?.downloadPercent, isNull, reason: 'total=$total');
          expect(progress?.totalBytes, isNull, reason: 'total=$total');
          expect(progress?.indeterminate, isTrue, reason: 'total=$total');
        }
        final known = parseRemoteInstallProgressLine(
          '::progress::68|14|下载依赖|进行中|1048576|8388608|262144|4',
        );
        expect(known?.downloadPercent, 14);
        expect(known?.totalBytes, 8388608);
        expect(known?.indeterminate, isFalse);
        final components = parseRemoteInstallProgressLine(
          '::progress::65||安装依赖|已安装 1 个组件||||4',
        );
        expect(components?.downloadPercent, isNull);
        expect(components?.downloadedBytes, isNull);
        expect(components?.bytesPerSecond, isNull);
        expect(components?.elapsedSeconds, 4);
        expect(components?.indeterminate, isTrue);
      },
    );

    test(
      'partial responses use full Content-Range size or remain unknown',
      () async {
        final work = await Directory.systemTemp.createTemp(
          'flutter-codex-download-range-',
        );
        try {
          final script = RemoteBootstrap.installScript();
          final helpers = script.substring(0, script.indexOf('\nROOT='));
          final headers = '${work.path}/response.headers';
          for (final (range, expected) in <(String?, String)>[
            ('bytes 65536-131071/131072', '131072'),
            (null, ''),
            ('bytes 65536-131071/*', ''),
            ('bytes 131071-65536/131072', ''),
            ('bytes 65536-131071/65536', ''),
            ('items 65536-131071/131072', ''),
          ]) {
            await _writeFile(headers, '''
HTTP/1.1 200 OK
Content-Length: 262144

  HTTP/1.1 206 Partial Content
  Content-Length: 65536
${range == null ? '' : '  Content-Range: $range'}

''');
            final result = await _runShell(
              '$helpers\ndownload_response_size ${shellQuote(headers)}\n',
            );
            expect(result.exitCode, 0, reason: result.stderr);
            expect(result.stdout.trim(), expected, reason: 'range=$range');
          }
        } finally {
          await work.delete(recursive: true);
        }
      },
    );

    for (final (knownSize, useWget) in <(bool, bool)>[
      (true, false),
      (false, false),
      (true, true),
      (false, true),
    ]) {
      test(
        'reads GET total bytes and handles chunked redirects; known=$knownSize wget=$useWget',
        () async {
          final work = await Directory.systemTemp.createTemp(
            'flutter-codex-download-progress-',
          );
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          final payload = List<int>.filled(131072, 97);
          var headRequests = 0;
          server.listen((request) async {
            if (request.method == 'HEAD') {
              headRequests++;
              request.response.statusCode = HttpStatus.methodNotAllowed;
              await request.response.close();
              return;
            }
            if (request.uri.path == '/redirect') {
              request.response.statusCode = HttpStatus.found;
              request.response.headers.set(HttpHeaders.locationHeader, '/file');
              request.response.contentLength = 17;
              request.response.write('redirect response');
              await request.response.close();
              return;
            }
            if (knownSize) request.response.contentLength = payload.length;
            request.response.add(payload.sublist(0, 65536));
            await request.response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 1800));
            request.response.add(payload.sublist(65536));
            await request.response.close();
          });
          try {
            final environment = <String, String>{
              'NO_PROXY': '127.0.0.1',
              'no_proxy': '127.0.0.1',
            };
            if (useWget) {
              final downloader = await Process.run('sh', <String>[
                '-c',
                'command -v wget',
              ]);
              if (downloader.exitCode != 0) {
                markTestSkipped('备用下载器 wget 未安装');
                return;
              }
              final bin = await Directory('${work.path}/bin').create();
              for (final command in <String>[
                'sh',
                'wget',
                'awk',
                'date',
                'wc',
                'tr',
                'sleep',
              ]) {
                final executable = await Process.run('sh', <String>[
                  '-c',
                  'command -v $command',
                ]);
                expect(executable.exitCode, 0, reason: command);
                await Link(
                  '${bin.path}/$command',
                ).create('${executable.stdout}'.trim());
              }
              environment['PATH'] = bin.path;
            }
            final script = RemoteBootstrap.installScript();
            final downloadHelpers = script.substring(
              0,
              script.indexOf('\nROOT='),
            );
            final endpoint =
                'http://127.0.0.1:${server.port}/${knownSize ? 'file' : 'redirect'}';
            final destination = '${work.path}/runtime.tar.gz';
            final result = await _runShell(
              '$downloadHelpers\ndownload_file ${shellQuote(endpoint)} ${shellQuote(destination)} 15 38 下载运行时\n',
              environmentOverrides: environment,
            );
            expect(result.exitCode, 0, reason: result.stderr);
            expect(headRequests, 0);
            expect(await File(destination).readAsBytes(), payload);
            final records = _progressRecords(result.stdout);
            final active = records.where(
              (record) =>
                  record.percent < 38 && (record.downloadedBytes ?? 0) > 0,
            );
            expect(active, isNotEmpty, reason: result.stdout);
            if (knownSize) {
              expect(
                active.every((record) => record.totalBytes == payload.length),
                isTrue,
              );
              expect(
                active.every((record) => record.downloadPercent != null),
                isTrue,
              );
            } else {
              expect(
                active.every((record) => record.totalBytes == null),
                isTrue,
              );
              expect(
                active.every((record) => record.downloadPercent == null),
                isTrue,
              );
              expect(active.every((record) => record.indeterminate), isTrue);
            }
            expect(records.last.percent, 38);
            expect(records.last.downloadPercent, 100);
            expect(records.last.downloadedBytes, payload.length);
            expect(records.last.totalBytes, payload.length);
          } finally {
            await server.close(force: true);
            await work.delete(recursive: true);
          }
        },
      );
    }

    test(
      'npm reports installed components without inventing transfer stats',
      () async {
        final work = await Directory.systemTemp.createTemp(
          'flutter-codex-npm-progress-',
        );
        try {
          final runtime = '${work.path}/runtime';
          final release = '${work.path}/release';
          await _writeFile('$runtime/bin/npm', '#!/bin/sh\nsleep 2\n');
          final executable = await Process.run('chmod', <String>[
            '700',
            '$runtime/bin/npm',
          ]);
          expect(executable.exitCode, 0, reason: '${executable.stderr}');
          await _writeFile(
            '$release/node_modules/@openai/codex/package.json',
            '{}',
          );
          await _writeFile(
            '$release/node_modules/@openai/codex/binary',
            'x' * 131072,
          );
          final script = RemoteBootstrap.installScript();
          final helpers = script.substring(0, script.indexOf('\nROOT='));
          final npmPhase = script.substring(
            script.indexOf('\nnpm_component_count()'),
            script.indexOf("\nprogress 90 '' '验证 Codex app-server'"),
          );
          final result = await _runShell('''
$helpers
WORK=${shellQuote(work.path)}
NODE_DIR=${shellQuote(runtime)}
TEMP_RELEASE=${shellQuote(release)}
$npmPhase
''');
          expect(result.exitCode, 0, reason: result.stderr);
          final records = _progressRecords(result.stdout);
          expect(records.length, greaterThan(2));
          expect(records.last.detail, contains('已安装 1 个组件'));
          expect(records.last.percent, 88);
          for (final record in records) {
            expect(record.downloadPercent, isNull);
            expect(record.downloadedBytes, isNull);
            expect(record.totalBytes, isNull);
            expect(record.bytesPerSecond, isNull);
            expect(record.elapsedSeconds, isNotNull);
            expect(record.indeterminate, isTrue);
          }
        } finally {
          await work.delete(recursive: true);
        }
      },
    );
  });

  group('managed install boundaries', () {
    test('installer is pinned and confined to the current SSH user', () async {
      final script = RemoteBootstrap.installScript();

      expect(script, contains('"@openai/codex":"$pinnedCodexVersion"'));
      expect(script, contains('node-v$pinnedNodeVersion-linux-'));
      expect(script, contains(r'ROOT="$HOME/.local/share/codex-remote"'));
      expect(script, contains(r'BIN_DIR="$HOME/.local/bin"'));
      expect(script, contains(r'flock -n 9'));
      expect(script, contains(r'trap cleanup EXIT'));
      expect(script, contains(r'INSTALL_COMMITTED=1'));
      expect(script, contains('node_modules/@openai/codex/bin/codex.js'));
      expect(script, contains(r'NODE_SLOT="${CANDIDATE##*/}"'));
      expect(script, isNot(contains('/lib/node_modules/@openai/codex')));
      expect(script, isNot(contains('sudo')));
      expect(script, isNot(contains('npm install -g')));
      expect(script, isNot(contains('/usr/local')));

      final syntax = await _runShell(script, arguments: const <String>['-n']);
      expect(syntax.exitCode, 0, reason: syntax.stderr);
    });

    test('node-only installer stops before creating a Codex release', () {
      final script = RemoteBootstrap.installNodeRuntimeScript();

      expect(script, contains('共享 Node.js 运行时已就绪'));
      expect(script, isNot(contains('@openai/codex')));
      expect(script, isNot(contains('node_modules/@openai/codex')));
      expect(script, isNot(contains('npm" ci')));
      expect(script, isNot(contains('准备 Codex CLI 安装目录')));
    });

    test('uninstaller removes only app-managed files', () async {
      final home = await Directory.systemTemp.createTemp(
        'flutter-codex-remote-uninstall-',
      );
      final managedRoot = Directory('${home.path}/.local/share/codex-remote');
      final managedWrapper = File('${home.path}/.local/bin/codex-remote');
      final systemCodex = File('${home.path}/.local/bin/codex');
      final accountState = File('${home.path}/.codex/auth.json');
      final upload = File('${home.path}/.codex-mobile/uploads/attachment.txt');
      final vscodeState = File(
        '${home.path}/.vscode-server/extensions/openai.chatgpt/state.json',
      );
      try {
        await _writeFile(
          '${managedRoot.path}/runtime/node/bin/node',
          'managed',
        );
        await _writeFile(managedWrapper.path, 'managed');
        await _writeFile(systemCodex.path, 'system');
        await _writeFile(accountState.path, 'account');
        await _writeFile(upload.path, 'upload');
        await _writeFile(vscodeState.path, 'vscode');

        final result = await _runShell(
          RemoteBootstrap.uninstallScript,
          home: home.path,
        );

        expect(result.exitCode, 0, reason: result.stderr);
        expect(result.stdout, contains('已卸载'));
        expect(await managedRoot.exists(), isFalse);
        expect(await managedWrapper.exists(), isFalse);
        expect(await Directory('${home.path}/.codex-mobile').exists(), isFalse);
        expect(await systemCodex.exists(), isTrue);
        expect(await accountState.exists(), isTrue);
        expect(await vscodeState.exists(), isTrue);
      } finally {
        await home.delete(recursive: true);
      }
    });

    test('uninstaller matches the corrected release path only', () {
      final script = RemoteBootstrap.uninstallScript;

      expect(
        script,
        contains(
          r'"$ROOT"/releases/*/node_modules/@openai/codex/bin/codex.js\ app-server*',
        ),
      );
      expect(
        script,
        isNot(
          contains(
            r'"$ROOT"/releases/*/lib/node_modules/@openai/codex/bin/codex.js',
          ),
        ),
      );
      expect(script, isNot(contains('pkill')));
      expect(script, isNot(contains('.vscode-server')));
      expect(script, isNot(contains(r'rm -rf -- "$HOME/.codex"')));
      expect(script, contains(r'rm -f -- "$WRAPPER"'));
      expect(script, contains(r'rm -rf -- "$ROOT"'));
      expect(script, contains(r'rm -rf -- "$UPLOAD_ROOT"'));
    });
  });
}
