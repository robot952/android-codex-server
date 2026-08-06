import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../domain/models.dart';

abstract interface class RemoteServerClient {
  Future<String> probeFingerprint(ServerProfile profile);
  Future<void> connect(ServerProfile profile);
  Future<void> disconnect();
  Future<void> get done;
  bool get isConnected;
  Future<String> run(String command, {Duration timeout, int maxOutputBytes});
  SSHClient requireSshClient();
  void close();
}

class HostKeyMismatchException implements Exception {
  const HostKeyMismatchException(this.expected, this.actual);

  final String expected;
  final String actual;

  @override
  String toString() => 'SSH 主机指纹不匹配：期望 $expected，实际 $actual';
}

class DartSshServerClient implements RemoteServerClient {
  DartSshServerClient({
    this.connectTimeout = const Duration(seconds: 20),
    this.authTimeout = const Duration(seconds: 20),
  });

  final Duration connectTimeout;
  final Duration authTimeout;

  SSHClient? _client;
  SSHClient? _pendingClient;
  SSHSocket? _pendingSocket;
  Future<void> _done = Future<void>.value();
  int _operationGeneration = 0;

  @override
  bool get isConnected => _client != null && !_client!.isClosed;

  @override
  Future<void> get done => _done;

  @override
  Future<String> probeFingerprint(ServerProfile profile) async {
    _validateAddress(profile);
    final operation = ++_operationGeneration;
    final socket = await SSHSocket.connect(
      profile.host.trim(),
      profile.port,
      timeout: connectTimeout,
    );
    if (operation != _operationGeneration) {
      socket.destroy();
      throw StateError('SSH 指纹探测已取消');
    }
    _pendingSocket = socket;
    String? captured;
    final client = SSHClient(
      socket,
      username: profile.username.trim().isEmpty
          ? 'root'
          : profile.username.trim(),
      handshakeTimeout: connectTimeout,
      authTimeout: authTimeout,
      onVerifyHostKey: (_, fingerprint) {
        captured = normalizeSshFingerprint(utf8.decode(fingerprint));
        return false;
      },
    );
    _pendingClient = client;
    try {
      await client.authenticated;
    } catch (_) {
      // Rejecting the key intentionally terminates the probe before authentication.
    } finally {
      if (identical(_pendingClient, client)) _pendingClient = null;
      if (identical(_pendingSocket, socket)) _pendingSocket = null;
      client.close();
      await client.done.catchError((_) {});
    }
    if (operation != _operationGeneration) {
      throw StateError('SSH 指纹探测已取消');
    }
    return captured ?? (throw StateError('无法读取服务器 SSH 主机指纹'));
  }

  @override
  Future<void> connect(ServerProfile profile) async {
    _validateAddress(profile);
    final expected = normalizeSshFingerprint(profile.hostFingerprint);
    if (expected.isEmpty) throw StateError('请先核对并保存 SSH 主机指纹');
    final identities = profile.authMode == AuthMode.privateKey
        ? _decodeIdentities(profile)
        : null;

    await disconnect();
    final operation = ++_operationGeneration;
    final socket = await SSHSocket.connect(
      profile.host.trim(),
      profile.port,
      timeout: connectTimeout,
    );
    if (operation != _operationGeneration) {
      socket.destroy();
      throw StateError('SSH 连接已取消');
    }
    _pendingSocket = socket;
    final password = profile.password;
    String? mismatchedFingerprint;
    SSHClient? client;
    try {
      client = SSHClient(
        socket,
        username: profile.username.trim(),
        identities: identities,
        onPasswordRequest: profile.authMode == AuthMode.password
            ? () => password
            : null,
        onUserInfoRequest: profile.authMode == AuthMode.password
            ? (request) => List<String>.filled(request.prompts.length, password)
            : null,
        keepAliveInterval: const Duration(seconds: 15),
        handshakeTimeout: connectTimeout,
        authTimeout: authTimeout,
        onVerifyHostKey: (_, fingerprint) {
          final actual = normalizeSshFingerprint(utf8.decode(fingerprint));
          if (actual != expected) {
            mismatchedFingerprint = actual;
            return false;
          }
          return true;
        },
      );
      _pendingClient = client;
      await client.authenticated.timeout(authTimeout);
      if (operation != _operationGeneration) {
        throw StateError('SSH 连接已取消');
      }
      _pendingClient = null;
      _pendingSocket = null;
      _client = client;
      _done = client.done;
    } catch (_) {
      if (identical(_pendingClient, client)) _pendingClient = null;
      if (identical(_pendingSocket, socket)) _pendingSocket = null;
      client?.close();
      if (client == null) {
        socket.destroy();
      } else {
        await client.done.catchError((_) {});
      }
      if (mismatchedFingerprint != null) {
        throw HostKeyMismatchException(expected, mismatchedFingerprint!);
      }
      rethrow;
    }
  }

  @override
  Future<String> run(
    String command, {
    Duration timeout = const Duration(seconds: 15),
    int maxOutputBytes = 1024 * 1024,
  }) async {
    if (command.trim().isEmpty) throw ArgumentError.value(command, 'command');
    if (maxOutputBytes < 1) {
      throw ArgumentError.value(maxOutputBytes, 'maxOutputBytes');
    }
    final client = requireSshClient();
    final deadline = DateTime.now().add(timeout);
    SSHSession? session;
    StreamSubscription<Uint8List>? stdoutSubscription;
    StreamSubscription<Uint8List>? stderrSubscription;
    final output = BytesBuilder(copy: false);
    var outputLength = 0;
    var streamsRemaining = 2;
    final streamsDone = Completer<void>();

    void finishStream() {
      streamsRemaining--;
      if (streamsRemaining == 0 && !streamsDone.isCompleted) {
        streamsDone.complete();
      }
    }

    void fail(Object error, StackTrace stackTrace) {
      if (!streamsDone.isCompleted) {
        streamsDone.completeError(error, stackTrace);
      }
      session?.close();
    }

    void addOutput(Uint8List bytes) {
      if (streamsDone.isCompleted) return;
      outputLength += bytes.length;
      if (outputLength > maxOutputBytes) {
        fail(
          StateError('远程命令输出超过 ${(maxOutputBytes / 1024).ceil()} KB 限制'),
          StackTrace.current,
        );
        return;
      }
      output.add(bytes);
    }

    try {
      session = await client.execute(command).timeout(timeout);
      stdoutSubscription = session.stdout.listen(
        addOutput,
        onDone: finishStream,
        onError: fail,
        cancelOnError: true,
      );
      stderrSubscription = session.stderr.listen(
        addOutput,
        onDone: finishStream,
        onError: fail,
        cancelOnError: true,
      );
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) throw TimeoutException('远程命令超时');
      await Future.wait([streamsDone.future, session.done]).timeout(remaining);
    } on TimeoutException {
      session?.close();
      throw StateError('远程命令执行超时');
    } catch (_) {
      session?.close();
      rethrow;
    } finally {
      await stdoutSubscription?.cancel();
      await stderrSubscription?.cancel();
    }

    final bytes = output.takeBytes();
    if ((session.exitCode ?? 0) != 0) {
      final detail = utf8.decode(bytes, allowMalformed: true).trim();
      throw StateError(detail.isEmpty ? '远程命令执行失败' : detail);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  @override
  SSHClient requireSshClient() {
    final client = _client;
    if (client == null || client.isClosed) {
      throw StateError('SSH 通道尚未连接');
    }
    return client;
  }

  @override
  Future<void> disconnect() async {
    _operationGeneration++;
    final client = _client;
    final pendingClient = _pendingClient;
    final pendingSocket = _pendingSocket;
    _client = null;
    _pendingClient = null;
    _pendingSocket = null;
    _done = Future<void>.value();
    client?.close();
    pendingClient?.close();
    pendingSocket?.destroy();
    await Future.wait([
      if (client != null) client.done.catchError((_) {}),
      if (pendingClient != null) pendingClient.done.catchError((_) {}),
    ]);
  }

  @override
  void close() {
    _operationGeneration++;
    final client = _client;
    final pendingClient = _pendingClient;
    final pendingSocket = _pendingSocket;
    _client = null;
    _pendingClient = null;
    _pendingSocket = null;
    _done = Future<void>.value();
    client?.close();
    pendingClient?.close();
    pendingSocket?.destroy();
  }

  List<SSHKeyPair> _decodeIdentities(ServerProfile profile) {
    if (profile.privateKeyPem.trim().isEmpty) {
      throw StateError('请选择 SSH 私钥');
    }
    try {
      final keys = SSHKeyPair.fromPem(
        profile.privateKeyPem,
        profile.privateKeyPassphrase.trim().isEmpty
            ? null
            : profile.privateKeyPassphrase,
      );
      if (keys.isEmpty) throw const FormatException('empty key');
      return keys;
    } catch (_) {
      throw const FormatException('SSH 私钥格式或密码不正确');
    }
  }

  void _validateAddress(ServerProfile profile) {
    if (profile.host.trim().isEmpty) throw StateError('服务器地址不能为空');
    if (profile.port < 1 || profile.port > 65535) {
      throw StateError('SSH 端口必须在 1 到 65535 之间');
    }
    if (profile.username.trim().isEmpty) throw StateError('用户名不能为空');
  }
}

String normalizeSshFingerprint(String value) {
  var normalized = value.trim();
  if (normalized.isEmpty) return '';
  if (!normalized.toUpperCase().startsWith('SHA256:')) {
    normalized = 'SHA256:$normalized';
  }
  final body = normalized
      .substring(normalized.indexOf(':') + 1)
      .replaceAll('=', '');
  return body.isEmpty ? '' : 'SHA256:$body';
}
