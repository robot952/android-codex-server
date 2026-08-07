import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:codex_remote/src/agent/remote_bootstrap.dart';
import 'package:codex_remote/src/ssh/ssh_server_client.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

class _ConnectedTestClient extends DartSshServerClient {
  _ConnectedTestClient(this.sshClient);

  final SSHClient sshClient;

  @override
  SSHClient requireSshClient() => sshClient;
}

class _FakeSshClient implements SSHClient {
  _FakeSshClient(this.session);

  final SSHSession session;
  final List<String> commands = <String>[];

  @override
  Future<SSHSession> execute(
    String command, {
    SSHPtyConfig? pty,
    SSHX11Config? x11,
    Map<String, String>? environment,
  }) async {
    commands.add(command);
    return session;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSshSession implements SSHSession {
  _FakeSshSession({
    this.stdoutText = '',
    this.stderrText = '',
    this.stdoutChunks = const <List<int>>[],
    this.stderrChunks = const <List<int>>[],
    this.exitCode = 0,
    this.finishOnStdinClose = true,
  }) {
    _stdinController.stream.listen(
      stdinBytes.addAll,
      onDone: () {
        stdinClosed = true;
        if (finishOnStdinClose) finish();
      },
    );
  }

  final String stdoutText;
  final String stderrText;
  final List<List<int>> stdoutChunks;
  final List<List<int>> stderrChunks;
  final bool finishOnStdinClose;
  final List<int> stdinBytes = <int>[];
  final StreamController<Uint8List> _stdinController =
      StreamController<Uint8List>();
  final StreamController<Uint8List> _stdoutController =
      StreamController<Uint8List>();
  final StreamController<Uint8List> _stderrController =
      StreamController<Uint8List>();
  final Completer<void> _done = Completer<void>();
  bool stdinClosed = false;
  bool wasClosed = false;
  bool _finished = false;

  @override
  final int? exitCode;

  @override
  Future<void> get done => _done.future;

  @override
  StreamSink<Uint8List> get stdin => _stdinController.sink;

  @override
  Stream<Uint8List> get stdout => _stdoutController.stream;

  @override
  Stream<Uint8List> get stderr => _stderrController.stream;

  void finish() {
    if (_finished) return;
    _finished = true;
    if (stdoutChunks.isNotEmpty) {
      for (final chunk in stdoutChunks) {
        _stdoutController.add(Uint8List.fromList(chunk));
      }
    } else if (stdoutText.isNotEmpty) {
      _stdoutController.add(Uint8List.fromList(utf8.encode(stdoutText)));
    }
    if (stderrChunks.isNotEmpty) {
      for (final chunk in stderrChunks) {
        _stderrController.add(Uint8List.fromList(chunk));
      }
    } else if (stderrText.isNotEmpty) {
      _stderrController.add(Uint8List.fromList(utf8.encode(stderrText)));
    }
    unawaited(_stdoutController.close());
    unawaited(_stderrController.close());
    if (!_done.isCompleted) _done.complete();
  }

  @override
  void close() {
    wasClosed = true;
    finish();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('runs shell scripts through fixed sh -s command and stdin', () async {
    const apiKey = 'secret-key-not-for-command-line';
    const script = 'printf "%s" "$apiKey"\n';
    final session = _FakeSshSession(stdoutText: 'ok\n');
    final sshClient = _FakeSshClient(session);
    final RemoteServerScriptClient client = _ConnectedTestClient(sshClient);

    final result = await client.runShellScript(script);

    expect(sshClient.commands, <String>['sh -s']);
    expect(sshClient.commands.single, isNot(contains(apiKey)));
    expect(utf8.decode(session.stdinBytes), script);
    expect(session.stdinClosed, isTrue);
    expect(result, 'ok\n');
  });

  test(
    'streams the fixed installer command without exposing its script',
    () async {
      const proxy = 'https://proxy.example:8443';
      final script = RemoteBootstrap.installScript(proxyUrl: proxy);
      final session = _FakeSshSession(stdoutText: 'installed\n');
      final sshClient = _FakeSshClient(session);
      final RemoteServerStreamingScriptClient client = _ConnectedTestClient(
        sshClient,
      );

      final result = await client.runStreamingShellScript(
        script,
        command: remoteInstallCommand,
      );

      expect(sshClient.commands, <String>[remoteInstallCommand]);
      expect(sshClient.commands.single, isNot(contains(proxy)));
      expect(sshClient.commands.single, isNot(contains('set -eu')));
      expect(sshClient.commands.single, isNot(contains(script)));
      expect(utf8.decode(session.stdinBytes), script);
      expect(session.stdinClosed, isTrue);
      expect(result, 'installed\n');
    },
  );

  test('decodes UTF-8 and CRLF progress lines across chunks', () async {
    const output =
        '::progress::52||复用现有 Node.js 运行时|独立环境已就绪\r\n'
        '::progress::100||安装完成|未换行';
    const errorOutput = '下载警告跨块\r\n错误尾行';
    final bytes = utf8.encode(output);
    final errorBytes = utf8.encode(errorOutput);
    final firstChineseByte = utf8.encode('::progress::52||').length;
    final carriageReturn = bytes.indexOf(0x0d);
    final secondLineChineseByte = utf8
        .encode(
          '::progress::52||复用现有 Node.js 运行时|独立环境已就绪\r\n'
          '::progress::100||',
        )
        .length;
    final session = _FakeSshSession(
      stdoutChunks: <List<int>>[
        bytes.sublist(0, firstChineseByte + 1),
        bytes.sublist(firstChineseByte + 1, carriageReturn + 1),
        bytes.sublist(carriageReturn + 1, secondLineChineseByte + 2),
        bytes.sublist(secondLineChineseByte + 2),
      ],
      stderrChunks: <List<int>>[
        errorBytes.sublist(0, 2),
        errorBytes.sublist(2, errorBytes.indexOf(0x0d) + 1),
        errorBytes.sublist(errorBytes.indexOf(0x0d) + 1),
      ],
    );
    final client = _ConnectedTestClient(_FakeSshClient(session));
    final lines = <String>[];
    final errorLines = <String>[];

    final result = await client.runStreamingShellScript(
      'printf progress\n',
      onStdoutLine: lines.add,
      onStderrLine: errorLines.add,
    );

    expect(result, isNotEmpty);
    expect(lines, <String>[
      '::progress::52||复用现有 Node.js 运行时|独立环境已就绪',
      '::progress::100||安装完成|未换行',
    ]);
    expect(
      lines.map(parseRemoteInstallProgressLine).map((value) => value?.percent),
      <int?>[52, 100],
    );
    expect(errorLines, <String>['下载警告跨块', '错误尾行']);
  });

  test('reports bounded output from a non-zero shell exit', () async {
    final session = _FakeSshSession(
      stderrText: 'permission denied\n',
      exitCode: 23,
    );
    final client = _ConnectedTestClient(_FakeSshClient(session));

    await expectLater(
      client.runShellScript('exit 23\n'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'permission denied',
        ),
      ),
    );
  });

  test('closes a shell session whose output exceeds the bound', () async {
    final session = _FakeSshSession(stdoutText: '12345');
    final client = _ConnectedTestClient(_FakeSshClient(session));

    await expectLater(
      client.runShellScript('printf 12345\n', maxOutputBytes: 4),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('输出超过'),
        ),
      ),
    );
    expect(session.wasClosed, isTrue);
  });

  test('closes a shell session when execution times out', () async {
    final session = _FakeSshSession(finishOnStdinClose: false);
    final client = _ConnectedTestClient(_FakeSshClient(session));

    await expectLater(
      client.runShellScript(
        'while :; do :; done\n',
        timeout: const Duration(milliseconds: 10),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          '远程命令执行超时',
        ),
      ),
    );
    expect(session.wasClosed, isTrue);
  });
}
