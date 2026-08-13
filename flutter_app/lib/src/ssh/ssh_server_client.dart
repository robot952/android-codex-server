import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:uuid/uuid.dart';

import '../domain/models.dart';
import 'server_metrics.dart';

abstract interface class RemoteServerClient {
  Future<String> probeFingerprint(ServerProfile profile);
  Future<void> connect(ServerProfile profile);
  Future<void> disconnect();
  Future<void> get done;
  bool get isConnected;
  Future<String> run(String command, {Duration timeout, int maxOutputBytes});
  Future<ServerMetrics> readServerMetrics(ServerProfile profile);
  SSHClient requireSshClient();
  void close();
}

/// Marker for a Host implemented by the current desktop OS instead of SSH.
/// Agent adapters use this only to avoid opening a second SSH connection.
abstract interface class LocalRemoteServerClient {}

/// A byte-oriented local process session. It intentionally mirrors only the
/// stdio surface needed by app-server protocols.
abstract interface class RemoteServerProcessSession {
  Stream<Uint8List> get stdout;
  Stream<Uint8List> get stderr;
  Future<void> get done;
  void write(Uint8List data);
  void terminate();
}

/// Optional capability for starting Codex app-server on the Host itself.
abstract interface class RemoteServerCodexProcessClient {
  Future<RemoteServerProcessSession> openCodexAppServer();
}

/// Optional transport-level keepalive used by the Android foreground service.
/// Keeping this capability separate means lightweight test clients and desktop
/// hosts do not need to emulate SSH global requests.
abstract interface class RemoteServerKeepAliveClient {
  Future<void> keepAlive();
}

/// Optional bounded SFTP capability used by image previews. Test doubles and
/// host implementations without file support can keep implementing only
/// [RemoteServerClient].
abstract interface class RemoteServerImageClient {
  Future<Uint8List> readRemoteImage(
    String path, {
    int maxBytes = maxRemoteImageBytes,
  });
}

/// Optional bounded SFTP capability used to stage local attachments on the
/// connected server before an Agent turn references them.
abstract interface class RemoteServerAttachmentClient {
  Future<String> uploadAttachment(
    String name,
    Uint8List bytes, {
    int maxBytes = maxRemoteAttachmentBytes,
  });
}

/// Optional bounded SFTP capability used to stream a regular remote file into
/// caller-owned storage without buffering the entire file in memory.
abstract interface class RemoteServerFileClient {
  Future<int> downloadRemoteFile(
    String path, {
    required Future<void> Function(Uint8List chunk) writeChunk,
    int maxBytes = maxRemoteFileBytes,
  });
}

/// Optional SFTP capability used by the full remote file manager. Uploads are
/// streamed so Android documents are never buffered as one large byte array.
abstract interface class RemoteServerFileManagerClient {
  Future<RemoteFileListing> listRemoteFiles(String? path);

  Future<void> uploadRemoteFile(
    String directory,
    String name,
    Stream<List<int>> chunks, {
    int? declaredSize,
    int maxBytes = maxRemoteFileBytes,
  });

  Future<void> renameRemoteFile(String path, String newName);

  Future<void> deleteRemoteFiles(List<String> paths);

  Future<void> transferRemoteFiles(
    List<String> paths,
    String destinationDirectory,
    RemoteFileTransferMode mode,
  );
}

/// Optional bounded SFTP capability used by remote workspace pickers.
abstract interface class RemoteServerDirectoryClient {
  Future<RemoteDirectoryListing> listDirectories(String? path);
}

/// Optional capability for running a shell program whose source is supplied
/// through stdin instead of being exposed in the SSH exec command.
abstract interface class RemoteServerScriptClient {
  Future<String> runShellScript(
    String script, {
    Duration timeout,
    int maxOutputBytes,
  });
}

/// Optional long-running script capability with incremental, line-oriented
/// output. The script body is still sent through stdin and never appears in
/// the SSH command or process list.
abstract interface class RemoteServerStreamingScriptClient {
  Future<String> runStreamingShellScript(
    String script, {
    String command,
    Duration timeout,
    int maxOutputBytes,
    void Function(String line)? onStdoutLine,
    void Function(String line)? onStderrLine,
  });
}

/// Optional capability for opening an interactive pseudo-terminal on the
/// already-authenticated host connection.
abstract interface class RemoteServerTerminalClient {
  Future<SSHSession> openTerminalSession({int columns = 80, int rows = 24});
}

const int maxRemoteImageBytes = 20 * 1024 * 1024;
const int maxRemoteAttachmentBytes = 20 * 1024 * 1024;
const int maxRemoteFileBytes = 2 * 1024 * 1024 * 1024;
const int maxRemotePathChars = 4096;
const int maxRemoteDirectoryEntries = 2000;
const int maxRemoteFileManagerEntries = 2000;
const int maxRemoteFileNameChars = 255;
const int _maxRemoteAttachmentNameChars = 120;
const int _attachmentWriteChunkBytes = 64 * 1024;
const int _remoteFileReadChunkBytes = 64 * 1024;
const int _maxRemoteTreeDepth = 128;

class HostKeyMismatchException implements Exception {
  const HostKeyMismatchException(this.expected, this.actual);

  final String expected;
  final String actual;

  @override
  String toString() => 'SSH 主机指纹不匹配：期望 $expected，实际 $actual';
}

class DartSshServerClient
    implements
        RemoteServerClient,
        RemoteServerImageClient,
        RemoteServerAttachmentClient,
        RemoteServerFileClient,
        RemoteServerFileManagerClient,
        RemoteServerDirectoryClient,
        RemoteServerScriptClient,
        RemoteServerStreamingScriptClient,
        RemoteServerTerminalClient,
        RemoteServerKeepAliveClient {
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
  Future<void>? _keepAliveRequest;
  int _operationGeneration = 0;

  @override
  bool get isConnected => _client != null && !_client!.isClosed;

  @override
  Future<void> keepAlive() {
    final client = _client;
    if (client == null || client.isClosed) return Future<void>.value();
    final pending = _keepAliveRequest;
    if (pending != null) return pending;

    late final Future<void> request;
    request = client
        .ping()
        // A server or an intermediate proxy that ignores the global request
        // must not block every later heartbeat forever.
        .timeout(const Duration(seconds: 8))
        .whenComplete(() {
          if (identical(_keepAliveRequest, request)) {
            _keepAliveRequest = null;
          }
        });
    _keepAliveRequest = request;
    return request;
  }

  @override
  Future<void> get done => _done;

  @override
  Future<String> probeFingerprint(ServerProfile profile) async {
    _validateAddress(profile);
    final operation = ++_operationGeneration;
    final socket = await _connectConfiguredSshSocket(
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
    final socket = await _connectConfiguredSshSocket(
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
        // Heartbeats are driven by the Android foreground service through
        // [RemoteServerKeepAliveClient]. Do not also let dartssh2 schedule its
        // own timer: two independent ping loops can write global requests at
        // the same time as an Agent channel upload and make mobile sockets
        // abort during backgrounding.
        keepAliveInterval: null,
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
    return _runCommand(
      command,
      timeout: timeout,
      maxOutputBytes: maxOutputBytes,
    );
  }

  @override
  Future<String> runShellScript(
    String script, {
    Duration timeout = const Duration(seconds: 15),
    int maxOutputBytes = 1024 * 1024,
  }) => _runCommand(
    'sh -s',
    standardInput: script,
    timeout: timeout,
    maxOutputBytes: maxOutputBytes,
  );

  @override
  Future<String> runStreamingShellScript(
    String script, {
    String command = 'sh -s',
    Duration timeout = const Duration(minutes: 30),
    int maxOutputBytes = 8 * 1024 * 1024,
    void Function(String line)? onStdoutLine,
    void Function(String line)? onStderrLine,
  }) => _runCommand(
    command,
    standardInput: script,
    timeout: timeout,
    maxOutputBytes: maxOutputBytes,
    onStdoutLine: onStdoutLine,
    onStderrLine: onStderrLine,
  );

  @override
  Future<SSHSession> openTerminalSession({int columns = 80, int rows = 24}) {
    final safeColumns = columns.clamp(20, 400);
    final safeRows = rows.clamp(4, 200);
    return requireSshClient().shell(
      pty: SSHPtyConfig(
        type: 'xterm-256color',
        width: safeColumns,
        height: safeRows,
      ),
    );
  }

  Future<String> _runCommand(
    String command, {
    String? standardInput,
    required Duration timeout,
    required int maxOutputBytes,
    void Function(String line)? onStdoutLine,
    void Function(String line)? onStderrLine,
  }) async {
    if (maxOutputBytes < 1) {
      throw ArgumentError.value(maxOutputBytes, 'maxOutputBytes');
    }
    final client = requireSshClient();
    final deadline = DateTime.now().add(timeout);
    SSHSession? session;
    StreamSubscription<dynamic>? stdoutSubscription;
    StreamSubscription<dynamic>? stderrSubscription;
    final output = BytesBuilder(copy: false);
    var outputLength = 0;
    var streamsRemaining = 2;
    final streamsDone = Completer<void>();
    var stdoutBuffer = '';
    var stderrBuffer = '';

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

    void consumeLines(
      String chunk,
      bool stdout,
      void Function(String line)? callback,
    ) {
      if (callback == null || chunk.isEmpty) return;
      var pending = (stdout ? stdoutBuffer : stderrBuffer) + chunk;
      var start = 0;
      for (var index = 0; index < pending.length; index++) {
        if (pending.codeUnitAt(index) != 0x0a) continue;
        var line = pending.substring(start, index);
        if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
        callback(line);
        start = index + 1;
      }
      pending = pending.substring(start);
      if (stdout) {
        stdoutBuffer = pending;
      } else {
        stderrBuffer = pending;
      }
    }

    void flushLine(bool stdout, void Function(String line)? callback) {
      if (callback == null) return;
      var pending = stdout ? stdoutBuffer : stderrBuffer;
      if (pending.endsWith('\r')) {
        pending = pending.substring(0, pending.length - 1);
      }
      if (pending.isNotEmpty) callback(pending);
      if (stdout) {
        stdoutBuffer = '';
      } else {
        stderrBuffer = '';
      }
    }

    try {
      session = await client.execute(command).timeout(timeout);
      stdoutSubscription = utf8.decoder
          .bind(
            session.stdout.map((bytes) {
              addOutput(bytes);
              return bytes;
            }),
          )
          .listen(
            (chunk) => consumeLines(chunk, true, onStdoutLine),
            onDone: () {
              flushLine(true, onStdoutLine);
              finishStream();
            },
            onError: fail,
            cancelOnError: true,
          );
      stderrSubscription = utf8.decoder
          .bind(
            session.stderr.map((bytes) {
              addOutput(bytes);
              return bytes;
            }),
          )
          .listen(
            (chunk) => consumeLines(chunk, false, onStderrLine),
            onDone: () {
              flushLine(false, onStderrLine);
              finishStream();
            },
            onError: fail,
            cancelOnError: true,
          );
      final sessionDone = Future.wait([streamsDone.future, session.done]);
      if (standardInput != null) {
        session.stdin.add(utf8.encode(standardInput));
        final remaining = deadline.difference(DateTime.now());
        if (remaining <= Duration.zero) throw TimeoutException('远程命令超时');
        await session.stdin.close().timeout(remaining);
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) throw TimeoutException('远程命令超时');
      await sessionDone.timeout(remaining);
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
      final detail = _boundedRemoteCommandError(
        utf8.decode(bytes, allowMalformed: true),
      );
      throw StateError(detail.isEmpty ? '远程命令执行失败' : detail);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  @override
  Future<ServerMetrics> readServerMetrics(ServerProfile profile) async {
    final output = await run(
      serverMetricsScript,
      timeout: const Duration(seconds: 15),
      maxOutputBytes: 64 * 1024,
    );
    return parseServerMetrics(output);
  }

  @override
  Future<RemoteDirectoryListing> listDirectories(String? path) async {
    final requestedPath = _validatedRemoteDirectoryPath(path);
    final sftp = await requireSshClient().sftp();
    try {
      final currentPath = _normalizedResolvedRemoteDirectoryPath(
        await sftp.absolute(requestedPath),
      );
      final attributes = await sftp.stat(currentPath);
      if (!attributes.isDirectory) throw StateError('不是可浏览的目录');

      final directories = <RemoteDirectory>[];
      var listedEntries = 0;
      var reachedLimit = false;
      await for (final entries in sftp.readdir(currentPath)) {
        for (final entry in entries) {
          // Bound protocol entries so file-heavy directories cannot force an
          // unbounded scan merely because few entries are directories.
          listedEntries++;
          if (_isBrowsableRemoteDirectory(entry)) {
            final childPath = _remoteChildPath(currentPath, entry.filename);
            if (childPath.length <= maxRemotePathChars) {
              directories.add(
                RemoteDirectory(name: entry.filename, path: childPath),
              );
            }
          }
          if (listedEntries == maxRemoteDirectoryEntries) {
            reachedLimit = true;
            break;
          }
        }
        if (reachedLimit) break;
      }
      return RemoteDirectoryListing(
        currentPath: currentPath,
        parentPath: _remoteDirectoryParent(currentPath),
        directories: sortAndLimitRemoteDirectories(directories),
      );
    } finally {
      await sftp.close();
    }
  }

  @override
  Future<RemoteFileListing> listRemoteFiles(String? path) async {
    final requestedPath = _validatedRemoteDirectoryPath(path);
    final sftp = await requireSshClient().sftp();
    try {
      final currentPath = _normalizedResolvedRemoteDirectoryPath(
        await sftp.absolute(requestedPath),
      );
      final attributes = await sftp.stat(currentPath);
      if (!attributes.isDirectory) throw StateError('不是可浏览的目录');

      final entries = <RemoteFileEntry>[];
      var listedEntries = 0;
      var reachedLimit = false;
      await for (final names in sftp.readdir(currentPath)) {
        for (final entry in names) {
          listedEntries++;
          if (_isValidRemoteFileEntry(entry)) {
            final childPath = _remoteChildPath(currentPath, entry.filename);
            if (childPath.length <= maxRemotePathChars) {
              final kind = remoteFileKindForAttributes(entry.attr);
              entries.add(
                RemoteFileEntry(
                  name: entry.filename,
                  path: childPath,
                  kind: kind,
                  sizeBytes: (entry.attr.size ?? 0).clamp(
                    0,
                    maxRemoteFileBytes,
                  ),
                  modifiedAtEpochMillis: entry.attr.modifyTime == null
                      ? null
                      : entry.attr.modifyTime! * 1000,
                  permissions: formatRemoteFilePermissions(
                    kind,
                    entry.attr.mode?.value ?? 0,
                  ),
                ),
              );
            }
          }
          if (listedEntries == maxRemoteFileManagerEntries) {
            reachedLimit = true;
            break;
          }
        }
        if (reachedLimit) break;
      }
      return RemoteFileListing(
        currentPath: currentPath,
        parentPath: _remoteDirectoryParent(currentPath),
        entries: sortAndLimitRemoteFiles(entries),
      );
    } finally {
      await sftp.close();
    }
  }

  @override
  Future<void> uploadRemoteFile(
    String directory,
    String name,
    Stream<List<int>> chunks, {
    int? declaredSize,
    int maxBytes = maxRemoteFileBytes,
  }) async {
    final requestedDirectory = validateRemoteFileManagerPath(directory, '目标目录');
    final fileName = validateRemoteFileManagerName(name);
    _validateRemoteUploadSize(declaredSize, maxBytes);
    final sftp = await requireSshClient().sftp();
    SftpFile? file;
    String? target;
    var created = false;
    try {
      final resolvedDirectory = _normalizedResolvedRemoteDirectoryPath(
        await sftp.absolute(requestedDirectory),
      );
      final directoryAttributes = await sftp.stat(resolvedDirectory);
      if (!directoryAttributes.isDirectory) throw StateError('目标不是目录');
      target = _remoteChildPath(resolvedDirectory, fileName);
      await _requireRemotePathMissing(sftp, target);
      file = await sftp.open(
        target,
        mode:
            SftpFileOpenMode.create |
            SftpFileOpenMode.write |
            SftpFileOpenMode.exclusive,
      );
      created = true;
      var offset = 0;
      await for (final sourceChunk in chunks) {
        if (sourceChunk.isEmpty) continue;
        final chunk = sourceChunk is Uint8List
            ? sourceChunk
            : Uint8List.fromList(sourceChunk);
        if (offset + chunk.length > maxBytes) {
          throw StateError('文件不能超过 ${_formatByteLimit(maxBytes)}');
        }
        for (var start = 0; start < chunk.length;) {
          final end = (start + _attachmentWriteChunkBytes).clamp(
            0,
            chunk.length,
          );
          await file.writeBytes(
            Uint8List.sublistView(chunk, start, end),
            offset: offset,
          );
          offset += end - start;
          start = end;
        }
      }
      if (declaredSize != null && offset != declaredSize) {
        throw StateError('上传文件大小与选择结果不一致');
      }
      final uploadedSize = (await file.stat()).size;
      if (uploadedSize != offset) throw StateError('文件上传不完整');
    } catch (_) {
      if (created && target != null) {
        try {
          await file?.close();
        } catch (_) {}
        file = null;
        try {
          await sftp.remove(target);
        } catch (_) {}
      }
      rethrow;
    } finally {
      try {
        await file?.close();
      } finally {
        await sftp.close();
      }
    }
  }

  @override
  Future<void> renameRemoteFile(String path, String newName) async {
    final source = validateRemoteFileManagerPath(path, '重命名文件');
    final leafName = validateRemoteFileManagerName(newName);
    if (source == '/') throw StateError('不能重命名服务器根目录');
    final target = _remoteChildPath(
      _remoteDirectoryParent(source) ?? '/',
      leafName,
    );
    if (source == target) throw StateError('名称没有变化');
    final sftp = await requireSshClient().sftp();
    try {
      await sftp.stat(source, followLink: false);
      await _requireRemotePathMissing(sftp, target);
      await sftp.rename(source, target);
    } finally {
      await sftp.close();
    }
  }

  @override
  Future<void> deleteRemoteFiles(List<String> paths) async {
    final sources = validateRemoteFileManagerPaths(paths, '删除文件');
    final sftp = await requireSshClient().sftp();
    try {
      for (final source in sources) {
        if (source == '/') throw StateError('不能删除服务器根目录');
        await _deleteRemotePathRecursively(sftp, source, depth: 0);
      }
    } finally {
      await sftp.close();
    }
  }

  @override
  Future<void> transferRemoteFiles(
    List<String> paths,
    String destinationDirectory,
    RemoteFileTransferMode mode,
  ) async {
    final sources = validateRemoteFileManagerPaths(
      paths,
      mode == RemoteFileTransferMode.copy ? '复制文件' : '移动文件',
    );
    final destination = validateRemoteFileManagerPath(
      destinationDirectory,
      '目标目录',
    );
    final sftp = await requireSshClient().sftp();
    try {
      final resolvedDestination = _normalizedResolvedRemoteDirectoryPath(
        await sftp.absolute(destination),
      );
      final destinationAttributes = await sftp.stat(resolvedDestination);
      if (!destinationAttributes.isDirectory) throw StateError('目标不是目录');

      final plans = <_RemoteFileTransferPlan>[];
      for (final source in sources) {
        if (source == '/') throw StateError('不能操作服务器根目录');
        final attributes = await sftp.stat(source, followLink: false);
        final target = _remoteChildPath(
          resolvedDestination,
          _remoteFileName(source),
        );
        if (target == source) throw StateError('目标目录与来源目录相同');
        if (attributes.isDirectory &&
            !attributes.isSymbolicLink &&
            resolvedDestination.startsWith('$source/')) {
          throw StateError('不能将目录放入它自身的子目录');
        }
        await _requireRemotePathMissing(sftp, target);
        plans.add(_RemoteFileTransferPlan(source: source, target: target));
      }
      if (plans.map((plan) => plan.target).toSet().length != plans.length) {
        throw StateError('所选文件名称重复');
      }

      for (final plan in plans) {
        if (mode == RemoteFileTransferMode.move) {
          await sftp.rename(plan.source, plan.target);
        } else {
          try {
            await _copyRemotePathRecursively(
              sftp,
              plan.source,
              plan.target,
              depth: 0,
            );
          } catch (_) {
            try {
              await _deleteRemotePathRecursively(sftp, plan.target, depth: 0);
            } catch (_) {}
            rethrow;
          }
        }
      }
    } finally {
      await sftp.close();
    }
  }

  @override
  Future<Uint8List> readRemoteImage(
    String path, {
    int maxBytes = maxRemoteImageBytes,
  }) async {
    final remotePath = path.trim();
    if (!remotePath.startsWith('/')) {
      throw ArgumentError.value(path, 'path', '图片路径必须是绝对路径');
    }
    if (remotePath.length > maxRemotePathChars) {
      throw ArgumentError.value(path, 'path', '图片路径过长');
    }
    if (maxBytes < 1 || maxBytes > maxRemoteImageBytes) {
      throw ArgumentError.value(maxBytes, 'maxBytes');
    }

    final sftp = await requireSshClient().sftp();
    try {
      final attrs = await sftp.stat(remotePath);
      final size = attrs.size;
      if (size == null || size < 1 || size > maxBytes) {
        throw StateError('图片不能超过 ${(maxBytes / (1024 * 1024)).floor()} MB');
      }
      final file = await sftp.open(remotePath, mode: SftpFileOpenMode.read);
      try {
        final bytes = await file.readBytes(length: size);
        if (bytes.length != size) throw StateError('图片读取不完整');
        return bytes;
      } finally {
        await file.close();
      }
    } finally {
      await sftp.close();
    }
  }

  @override
  Future<int> downloadRemoteFile(
    String path, {
    required Future<void> Function(Uint8List chunk) writeChunk,
    int maxBytes = maxRemoteFileBytes,
  }) async {
    _validateRemoteFileDownloadRequest(path, maxBytes);
    final sftp = await requireSshClient().sftp();
    SftpFile? file;
    try {
      final attributes = await sftp.stat(path, followLink: false);
      final declaredSize = validateRemoteFileForDownload(
        path,
        attributes,
        maxBytes: maxBytes,
      );
      file = await sftp.open(path, mode: SftpFileOpenMode.read);

      var downloadedBytes = 0;
      await for (final chunk in file.read(
        length: declaredSize,
        chunkSize: _remoteFileReadChunkBytes,
        maxPendingRequests: 1,
      )) {
        downloadedBytes += chunk.length;
        if (downloadedBytes > declaredSize) {
          throw StateError('远程文件读取超出声明大小');
        }
        await writeChunk(chunk);
      }
      if (downloadedBytes != declaredSize) {
        throw StateError('远程文件读取不完整');
      }
      return downloadedBytes;
    } finally {
      try {
        await file?.close();
      } finally {
        await sftp.close();
      }
    }
  }

  @override
  Future<String> uploadAttachment(
    String name,
    Uint8List bytes, {
    int maxBytes = maxRemoteAttachmentBytes,
  }) async {
    if (maxBytes < 1 || maxBytes > maxRemoteAttachmentBytes) {
      throw ArgumentError.value(maxBytes, 'maxBytes');
    }
    if (bytes.isEmpty) throw StateError('附件不能为空');
    if (bytes.length > maxBytes) {
      throw StateError('附件不能超过 ${_formatByteLimit(maxBytes)}');
    }

    final safeName = _safeAttachmentName(name);
    final sftp = await requireSshClient().sftp();
    SftpFile? file;
    String? remotePath;
    var remoteFileCreated = false;
    try {
      final home = await sftp.absolute('.');
      if (!home.startsWith('/') || home.length > maxRemotePathChars) {
        throw StateError('无法确定远程用户目录');
      }
      final managedDirectory = _remoteChildPath(home, '.codex-mobile');
      final uploadDirectory = _remoteChildPath(managedDirectory, 'uploads');
      await _ensureRemoteDirectory(sftp, managedDirectory);
      await _ensureRemoteDirectory(sftp, uploadDirectory);

      remotePath = _remoteChildPath(
        uploadDirectory,
        '${const Uuid().v4()}-$safeName',
      );
      if (remotePath.length > maxRemotePathChars) {
        throw StateError('附件远程路径过长');
      }
      file = await sftp.open(
        remotePath,
        mode:
            SftpFileOpenMode.create |
            SftpFileOpenMode.write |
            SftpFileOpenMode.exclusive,
      );
      remoteFileCreated = true;
      for (var offset = 0; offset < bytes.length;) {
        final end = (offset + _attachmentWriteChunkBytes).clamp(
          0,
          bytes.length,
        );
        await file.writeBytes(
          Uint8List.sublistView(bytes, offset, end),
          offset: offset,
        );
        offset = end;
      }
      final uploadedSize = (await file.stat()).size;
      if (uploadedSize != bytes.length) throw StateError('附件上传不完整');
      return remotePath;
    } catch (_) {
      if (remotePath != null && remoteFileCreated) {
        try {
          await file?.close();
        } catch (_) {}
        file = null;
        try {
          await sftp.remove(remotePath);
        } catch (_) {}
      }
      rethrow;
    } finally {
      try {
        await file?.close();
      } catch (_) {}
      try {
        await sftp.close();
      } catch (_) {}
    }
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

/// Validates metadata returned by an SFTP lstat before a remote download.
///
/// Kept separate from the network operation so every caller applies the same
/// path, file-type, and declared-size boundary.
int validateRemoteFileForDownload(
  String path,
  SftpFileAttrs attributes, {
  int maxBytes = maxRemoteFileBytes,
}) {
  _validateRemoteFileDownloadRequest(path, maxBytes);
  if (!attributes.isFile) throw StateError('只能下载普通文件');
  final declaredSize = attributes.size;
  if (declaredSize == null || declaredSize < 0) {
    throw StateError('无法确定远程文件大小');
  }
  if (declaredSize > maxBytes) {
    throw StateError('文件不能超过 ${_formatByteLimit(maxBytes)}');
  }
  return declaredSize;
}

void _validateRemoteFileDownloadRequest(String path, int maxBytes) {
  if (!path.startsWith('/')) {
    throw ArgumentError.value(path, 'path', '文件路径必须是绝对路径');
  }
  if (path.length > maxRemotePathChars) {
    throw ArgumentError.value(path, 'path', '文件路径过长');
  }
  if (path.codeUnits.any((value) => value < 0x20 || value == 0x7f)) {
    throw ArgumentError.value(path, 'path', '文件路径包含控制字符');
  }
  if (maxBytes < 1 || maxBytes > maxRemoteFileBytes) {
    throw ArgumentError.value(maxBytes, 'maxBytes');
  }
}

String _validatedRemoteDirectoryPath(String? path) {
  final requestedPath = path?.trim();
  final normalized = requestedPath == null || requestedPath.isEmpty
      ? '.'
      : requestedPath;
  if (normalized.length > maxRemotePathChars) {
    throw ArgumentError.value(path, 'path', '目录路径过长');
  }
  if (normalized.codeUnits.any((value) => value < 0x20 || value == 0x7f)) {
    throw ArgumentError.value(path, 'path', '目录路径包含控制字符');
  }
  return normalized;
}

String _normalizedResolvedRemoteDirectoryPath(String path) {
  if (!path.startsWith('/') || path.length > maxRemotePathChars) {
    throw StateError('无法确定远程目录');
  }
  if (path.codeUnits.any((value) => value < 0x20 || value == 0x7f)) {
    throw StateError('远程目录路径无效');
  }
  final withoutTrailingSlashes = path.replaceFirst(RegExp(r'/+$'), '');
  return withoutTrailingSlashes.isEmpty ? '/' : withoutTrailingSlashes;
}

bool _isBrowsableRemoteDirectory(SftpName entry) {
  final name = entry.filename;
  return entry.attr.isDirectory &&
      name.isNotEmpty &&
      name != '.' &&
      name != '..' &&
      !name.contains('/') &&
      !name.codeUnits.any((value) => value < 0x20 || value == 0x7f);
}

/// Applies the same deterministic result boundary used by SFTP listings.
List<RemoteDirectory> sortAndLimitRemoteDirectories(
  Iterable<RemoteDirectory> directories, {
  int maxEntries = maxRemoteDirectoryEntries,
}) {
  if (maxEntries < 1 || maxEntries > maxRemoteDirectoryEntries) {
    throw ArgumentError.value(maxEntries, 'maxEntries');
  }
  final result = directories.take(maxEntries).toList();
  result.sort(_compareRemoteDirectories);
  return result;
}

int _compareRemoteDirectories(RemoteDirectory left, RemoteDirectory right) {
  final caseInsensitive = left.name.toLowerCase().compareTo(
    right.name.toLowerCase(),
  );
  return caseInsensitive != 0
      ? caseInsensitive
      : left.name.compareTo(right.name);
}

RemoteFileKind remoteFileKindForAttributes(SftpFileAttrs attributes) {
  if (attributes.isSymbolicLink) return RemoteFileKind.symbolicLink;
  if (attributes.isDirectory) return RemoteFileKind.directory;
  if (attributes.isFile) return RemoteFileKind.file;
  return RemoteFileKind.other;
}

List<RemoteFileEntry> sortAndLimitRemoteFiles(
  Iterable<RemoteFileEntry> entries, {
  int maxEntries = maxRemoteFileManagerEntries,
}) {
  if (maxEntries < 1 || maxEntries > maxRemoteFileManagerEntries) {
    throw ArgumentError.value(maxEntries, 'maxEntries');
  }
  final result = entries.take(maxEntries).toList();
  result.sort((left, right) {
    final leftDirectory = left.kind == RemoteFileKind.directory;
    final rightDirectory = right.kind == RemoteFileKind.directory;
    if (leftDirectory != rightDirectory) return leftDirectory ? -1 : 1;
    final caseInsensitive = left.name.toLowerCase().compareTo(
      right.name.toLowerCase(),
    );
    return caseInsensitive != 0
        ? caseInsensitive
        : left.name.compareTo(right.name);
  });
  return result;
}

String validateRemoteFileManagerPath(String path, String field) {
  final normalized = path.trim();
  if (!normalized.startsWith('/') || normalized.length > maxRemotePathChars) {
    throw ArgumentError.value(path, field, '$field路径无效');
  }
  if (normalized.codeUnits.any((value) => value < 0x20 || value == 0x7f)) {
    throw ArgumentError.value(path, field, '$field路径包含无效字符');
  }
  if (normalized.split('/').contains('..')) {
    throw ArgumentError.value(path, field, '$field路径不能包含上级目录');
  }
  return normalized;
}

List<String> validateRemoteFileManagerPaths(
  Iterable<String> paths,
  String operation,
) {
  final normalized = paths
      .map((path) => validateRemoteFileManagerPath(path, operation))
      .toSet()
      .toList(growable: false);
  if (normalized.isEmpty) throw StateError('请先选择文件');
  return normalized;
}

String validateRemoteFileManagerName(String value) {
  final name = value.trim();
  if (name.isEmpty || name.length > maxRemoteFileNameChars) {
    throw ArgumentError.value(value, 'name', '文件名长度无效');
  }
  if (name == '.' ||
      name == '..' ||
      name.contains('/') ||
      name.contains(r'\')) {
    throw ArgumentError.value(value, 'name', '文件名不能包含路径分隔符');
  }
  if (name.codeUnits.any((value) => value < 0x20 || value == 0x7f)) {
    throw ArgumentError.value(value, 'name', '文件名包含无效字符');
  }
  return name;
}

String formatRemoteFilePermissions(RemoteFileKind kind, int mode) {
  final prefix = switch (kind) {
    RemoteFileKind.directory => 'd',
    RemoteFileKind.symbolicLink => 'l',
    RemoteFileKind.file => '-',
    RemoteFileKind.other => '?',
  };
  const bits = <int>[0x100, 0x80, 0x40, 0x20, 0x10, 0x8, 0x4, 0x2, 0x1];
  const characters = <String>['r', 'w', 'x', 'r', 'w', 'x', 'r', 'w', 'x'];
  final output = StringBuffer(prefix);
  for (var index = 0; index < bits.length; index++) {
    output.write(mode & bits[index] == 0 ? '-' : characters[index]);
  }
  return output.toString();
}

bool _isValidRemoteFileEntry(SftpName entry) {
  final name = entry.filename;
  return name.isNotEmpty &&
      name != '.' &&
      name != '..' &&
      !name.contains('/') &&
      !name.codeUnits.any((value) => value < 0x20 || value == 0x7f);
}

void _validateRemoteUploadSize(int? declaredSize, int maxBytes) {
  if (maxBytes < 1 || maxBytes > maxRemoteFileBytes) {
    throw ArgumentError.value(maxBytes, 'maxBytes');
  }
  if (declaredSize != null && (declaredSize < 0 || declaredSize > maxBytes)) {
    throw StateError('文件不能超过 ${_formatByteLimit(maxBytes)}');
  }
}

Future<void> _requireRemotePathMissing(SftpClient sftp, String path) async {
  try {
    await sftp.stat(path, followLink: false);
    throw StateError('目标已存在：${_remoteFileName(path)}');
  } on SftpStatusError catch (error) {
    if (error.code != SftpStatusCode.noSuchFile) rethrow;
  }
}

Future<void> _deleteRemotePathRecursively(
  SftpClient sftp,
  String path, {
  required int depth,
}) async {
  if (depth > _maxRemoteTreeDepth) throw StateError('远程目录层级过深');
  final attributes = await sftp.stat(path, followLink: false);
  if (attributes.isDirectory && !attributes.isSymbolicLink) {
    await for (final names in sftp.readdir(path)) {
      for (final entry in names.where(_isValidRemoteFileEntry)) {
        await _deleteRemotePathRecursively(
          sftp,
          _remoteChildPath(path, entry.filename),
          depth: depth + 1,
        );
      }
    }
    await sftp.rmdir(path);
  } else {
    await sftp.remove(path);
  }
}

Future<void> _copyRemotePathRecursively(
  SftpClient sftp,
  String source,
  String target, {
  required int depth,
}) async {
  if (depth > _maxRemoteTreeDepth) throw StateError('远程目录层级过深');
  final attributes = await sftp.stat(source, followLink: false);
  if (attributes.isSymbolicLink) throw StateError('不支持复制符号链接');
  if (attributes.isDirectory) {
    await sftp.mkdir(target);
    await for (final names in sftp.readdir(source)) {
      for (final entry in names.where(_isValidRemoteFileEntry)) {
        await _copyRemotePathRecursively(
          sftp,
          _remoteChildPath(source, entry.filename),
          _remoteChildPath(target, entry.filename),
          depth: depth + 1,
        );
      }
    }
    return;
  }
  if (!attributes.isFile) throw StateError('只支持复制普通文件和目录');
  final size = attributes.size;
  if (size == null || size < 0 || size > maxRemoteFileBytes) {
    throw StateError('文件不能超过 ${_formatByteLimit(maxRemoteFileBytes)}');
  }
  final sourceFile = await sftp.open(source, mode: SftpFileOpenMode.read);
  SftpFile? targetFile;
  try {
    targetFile = await sftp.open(
      target,
      mode:
          SftpFileOpenMode.create |
          SftpFileOpenMode.write |
          SftpFileOpenMode.exclusive,
    );
    var offset = 0;
    await for (final chunk in sourceFile.read(
      length: size,
      chunkSize: _remoteFileReadChunkBytes,
      maxPendingRequests: 1,
    )) {
      await targetFile.writeBytes(chunk, offset: offset);
      offset += chunk.length;
    }
    if (offset != size) throw StateError('远程文件复制不完整');
  } finally {
    try {
      await sourceFile.close();
    } finally {
      await targetFile?.close();
    }
  }
}

String _remoteFileName(String path) =>
    path.substring(path.lastIndexOf('/') + 1).trim().isEmpty
    ? '文件'
    : path.substring(path.lastIndexOf('/') + 1);

class _RemoteFileTransferPlan {
  const _RemoteFileTransferPlan({required this.source, required this.target});

  final String source;
  final String target;
}

String? _remoteDirectoryParent(String path) {
  if (path == '/') return null;
  final separator = path.lastIndexOf('/');
  return separator <= 0 ? '/' : path.substring(0, separator);
}

Future<void> _ensureRemoteDirectory(SftpClient sftp, String path) async {
  try {
    final attributes = await sftp.stat(path);
    if (!attributes.isDirectory) throw StateError('远程附件目录不可用');
    return;
  } on SftpStatusError catch (error) {
    if (error.code != SftpStatusCode.noSuchFile) rethrow;
  }

  try {
    await sftp.mkdir(
      path,
      SftpFileAttrs(mode: const SftpFileMode.value(0x1c0)),
    );
  } on SftpStatusError {
    // Concurrent uploads may create the directory between stat and mkdir.
    final attributes = await sftp.stat(path);
    if (!attributes.isDirectory) rethrow;
  }
}

String _safeAttachmentName(String value) {
  final normalized = value.trim().replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  if (normalized.isEmpty) return 'attachment';
  return normalized.substring(
    0,
    normalized.length.clamp(0, _maxRemoteAttachmentNameChars),
  );
}

String _remoteChildPath(String directory, String name) => directory == '/'
    ? '/$name'
    : '${directory.replaceFirst(RegExp(r'/+$'), '')}/$name';

String _formatByteLimit(int bytes) {
  const kibibyte = 1024;
  const mebibyte = kibibyte * 1024;
  if (bytes % mebibyte == 0) return '${bytes ~/ mebibyte} MB';
  if (bytes % kibibyte == 0) return '${bytes ~/ kibibyte} KB';
  return '$bytes 字节';
}

String _boundedRemoteCommandError(String value) {
  final lines = value
      .split(RegExp(r'\r?\n'))
      .where((line) => line.trim().isNotEmpty)
      .toList(growable: false);
  var detail = lines.skip((lines.length - 8).clamp(0, lines.length)).join('\n');
  const maxChars = 8 * 1024;
  if (detail.length > maxChars) {
    detail = detail.substring(detail.length - maxChars);
  }
  return detail.trim();
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

/// Configures the native TCP socket before dartssh2 starts its SSH transport.
/// Dart timers and MethodChannel callbacks may be delayed while Android keeps
/// the foreground service alive in the background; kernel TCP keepalive is the
/// only liveness mechanism that continues to run without the Dart isolate.
Future<SSHSocket> _connectConfiguredSshSocket(
  String host,
  int port, {
  Duration? timeout,
}) async {
  final socket = await Socket.connect(host, port, timeout: timeout);
  try {
    socket.setOption(SocketOption.tcpNoDelay, true);
  } catch (_) {
    // TCP_NODELAY is an optimization; a platform that rejects it can still
    // use the SSH connection.
  }
  if (Platform.isAndroid || Platform.isLinux) {
    _trySetRawSocketOption(
      socket,
      RawSocketOption.fromBool(RawSocketOption.levelSocket, _soKeepAlive, true),
    );
    _trySetRawSocketOption(
      socket,
      RawSocketOption.fromInt(
        RawSocketOption.levelTcp,
        _tcpKeepIdle,
        _tcpKeepIdleSeconds,
      ),
    );
    _trySetRawSocketOption(
      socket,
      RawSocketOption.fromInt(
        RawSocketOption.levelTcp,
        _tcpKeepInterval,
        _tcpKeepIntervalSeconds,
      ),
    );
    _trySetRawSocketOption(
      socket,
      RawSocketOption.fromInt(
        RawSocketOption.levelTcp,
        _tcpKeepCount,
        _tcpKeepCountValue,
      ),
    );
  }
  return _ConfiguredSshSocket(socket);
}

void _trySetRawSocketOption(Socket socket, RawSocketOption option) {
  try {
    socket.setRawOption(option);
  } catch (_) {
    // Some Android vendor kernels expose SO_KEEPALIVE but reject one of the
    // TCP tuning options. Keep the socket usable and fall back to SSH pings.
  }
}

/// Public dartssh2 does not expose the underlying Socket, so keep the socket
/// option setup local while passing a normal SSHSocket to SSHClient.
final class _ConfiguredSshSocket implements SSHSocket {
  _ConfiguredSshSocket(this._socket);

  final Socket _socket;

  @override
  Stream<Uint8List> get stream => _socket;

  @override
  StreamSink<List<int>> get sink => _socket;

  @override
  Future<void> get done => _socket.done;

  @override
  Future<void> close() => _socket.close();

  @override
  void destroy() => _socket.destroy();

  @override
  Future<void> flush() => _socket.flush();
}

// Linux/Android socket option numbers from <sys/socket.h> and <netinet/tcp.h>.
const _soKeepAlive = 9;
const _tcpKeepIdle = 4;
const _tcpKeepInterval = 5;
const _tcpKeepCount = 6;
const _tcpKeepIdleSeconds = 30;
const _tcpKeepIntervalSeconds = 10;
const _tcpKeepCountValue = 3;
