import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:synchronized/synchronized.dart';

import '../domain/models.dart';
import 'ssh_server_client.dart';

typedef RemoteServerClientFactory = RemoteServerClient Function();
typedef ServerConnectionLease = ({RemoteServerClient client, int generation});

class ServerConnectionManager {
  ServerConnectionManager({RemoteServerClientFactory? clientFactory})
    : _clientFactory = clientFactory ?? DartSshServerClient.new;

  final RemoteServerClientFactory _clientFactory;
  final Map<String, _ServerEntry> _entries = {};
  final Map<String, ConnectionState> _states = {};
  final Map<String, ServerMetrics> _serverMetrics = {};
  final StreamController<Map<String, ConnectionState>> _stateController =
      StreamController<Map<String, ConnectionState>>.broadcast(sync: true);
  final StreamController<Map<String, ServerMetrics>> _serverMetricsController =
      StreamController<Map<String, ServerMetrics>>.broadcast(sync: true);
  bool _closed = false;

  Map<String, ConnectionState> get states => Map.unmodifiable(_states);
  Stream<Map<String, ConnectionState>> get stateChanges =>
      _stateController.stream;
  Map<String, ServerMetrics> get serverMetrics =>
      Map.unmodifiable(_serverMetrics);
  Stream<Map<String, ServerMetrics>> get serverMetricChanges =>
      _serverMetricsController.stream;

  RemoteServerClient registerProfile(ServerProfile profile) {
    _ensureOpen();
    final existing = _entries[profile.id];
    if (existing != null &&
        existing.profile.hasSameConnectionIdentity(profile)) {
      existing.profile = profile;
      return existing.client;
    }
    if (existing != null) {
      existing.generation++;
      existing.metricsRequest = null;
      _clearServerMetrics(profile.id);
      existing.client.close();
    }
    final entry = _ServerEntry(profile, _clientFactory());
    _entries[profile.id] = entry;
    _setState(profile.id, const ConnectionState());
    return entry.client;
  }

  RemoteServerClient? client(String profileId) => _entries[profileId]?.client;
  ServerProfile? profile(String profileId) => _entries[profileId]?.profile;

  ServerConnectionLease? connectedLease(ServerProfile profile) {
    final entry = _entries[profile.id];
    if (entry == null ||
        !entry.profile.hasSameConnectionIdentity(profile) ||
        !_isConnected(profile.id, entry)) {
      return null;
    }
    return (client: entry.client, generation: entry.generation);
  }

  bool isLeaseCurrent(ServerProfile profile, ServerConnectionLease lease) {
    final entry = _entries[profile.id];
    return entry != null &&
        entry.profile.hasSameConnectionIdentity(profile) &&
        identical(entry.client, lease.client) &&
        entry.generation == lease.generation &&
        _isConnected(profile.id, entry);
  }

  Future<String> probeFingerprint(ServerProfile profile) async {
    final client = registerProfile(profile);
    final entry = _entries[profile.id];
    if (entry == null || !identical(entry.client, client)) {
      throw StateError('服务器指纹探测已失效');
    }
    return entry.lock.synchronized(() async {
      if (!_isCurrent(profile.id, entry)) {
        throw StateError('服务器指纹探测已失效');
      }
      final generation = ++entry.generation;
      _setState(
        profile.id,
        const ConnectionState(
          phase: ConnectionPhase.probing,
          message: '正在读取 SSH 指纹',
        ),
      );
      try {
        final fingerprint = await client.probeFingerprint(profile);
        if (!_isCurrent(profile.id, entry) || generation != entry.generation) {
          throw StateError('服务器指纹探测已失效');
        }
        _setState(profile.id, const ConnectionState());
        return fingerprint;
      } catch (error) {
        if (_isCurrent(profile.id, entry) && generation == entry.generation) {
          _setState(
            profile.id,
            ConnectionState(
              phase: ConnectionPhase.failed,
              message: _message(error, '读取 SSH 指纹失败'),
            ),
          );
        }
        rethrow;
      }
    });
  }

  Future<void> connect(ServerProfile profile) async {
    final client = registerProfile(profile);
    final entry = _entries[profile.id];
    if (entry == null || !identical(entry.client, client)) {
      throw StateError('服务器连接已失效');
    }
    await entry.lock.synchronized(() async {
      if (!_isCurrent(profile.id, entry)) return;
      if (entry.client.isConnected) {
        _setState(
          profile.id,
          const ConnectionState(
            phase: ConnectionPhase.connected,
            message: 'SSH 已连接',
          ),
        );
        return;
      }
      _setState(
        profile.id,
        const ConnectionState(
          phase: ConnectionPhase.connecting,
          message: '正在连接 SSH',
        ),
      );
      final generation = ++entry.generation;
      try {
        await entry.client.connect(profile);
        if (!_isCurrent(profile.id, entry) || generation != entry.generation) {
          entry.client.close();
          throw StateError('服务器连接配置已更新');
        }
        _setState(
          profile.id,
          const ConnectionState(
            phase: ConnectionPhase.connected,
            message: 'SSH 已连接',
          ),
        );
        unawaited(_watchDisconnect(profile.id, entry, generation));
      } catch (error) {
        if (_isCurrent(profile.id, entry) && generation == entry.generation) {
          _setState(
            profile.id,
            ConnectionState(
              phase: ConnectionPhase.failed,
              message: _message(error, 'SSH 连接失败'),
            ),
          );
        }
        rethrow;
      }
    });
  }

  Future<void> disconnect(String profileId) async {
    final entry = _entries[profileId];
    if (entry == null) return;
    await entry.lock.synchronized(() async {
      entry.generation++;
      entry.metricsRequest = null;
      _clearServerMetrics(profileId);
      await entry.client.disconnect();
      if (_isCurrent(profileId, entry)) {
        _setState(profileId, const ConnectionState());
      }
    });
  }

  /// Opens one interactive PTY on the authenticated connection for [profile].
  ///
  /// The returned channel is checked against the connection generation both
  /// before and after opening. A channel opened while a server is being
  /// replaced or disconnected is closed immediately and never escapes to the
  /// terminal UI.
  Future<SSHSession> openTerminalSession(
    ServerProfile profile, {
    int columns = 80,
    int rows = 24,
  }) async {
    _ensureOpen();
    final entry = _entries[profile.id];
    if (entry == null || !_isConnected(profile.id, entry)) {
      throw StateError('服务器尚未连接');
    }
    if (!entry.profile.hasSameConnectionIdentity(profile)) {
      throw StateError('服务器连接配置已更新');
    }
    final client = entry.client;
    if (client is! RemoteServerTerminalClient) {
      throw UnsupportedError('当前 SSH 客户端不支持终端');
    }
    final terminalClient = client as RemoteServerTerminalClient;
    final generation = entry.generation;
    final session = await terminalClient.openTerminalSession(
      columns: columns,
      rows: rows,
    );
    if (!_isConnectedRequest(profile.id, entry, client, generation) ||
        !entry.profile.hasSameConnectionIdentity(profile)) {
      session.close();
      throw StateError('终端连接请求已失效');
    }
    return session;
  }

  Future<void> refreshServerMetrics(String profileId) {
    if (_closed) return Future<void>.value();
    final entry = _entries[profileId];
    if (entry == null || !_isConnected(profileId, entry)) {
      return Future<void>.value();
    }
    final pending = entry.metricsRequest;
    if (pending != null) return pending;

    final generation = entry.generation;
    final client = entry.client;
    late final Future<void> request;
    request = _readServerMetrics(profileId, entry, client, generation)
        .whenComplete(() {
          if (identical(entry.metricsRequest, request)) {
            entry.metricsRequest = null;
          }
        });
    entry.metricsRequest = request;
    return request;
  }

  /// Sends one SSH-level keepalive without opening an exec channel. This is
  /// intentionally independent from metrics polling because the latter can
  /// race with a long-running Agent JSONL channel.
  Future<void> keepAlive(String profileId) async {
    if (_closed) return;
    final entry = _entries[profileId];
    if (entry == null || !_isConnected(profileId, entry)) return;
    final client = entry.client;
    if (client is! RemoteServerKeepAliveClient) return;
    // The normal transport watcher still publishes disconnect state. Let the
    // heartbeat caller record this lane's exact failure before recovery starts;
    // the Android bridge consumes it as diagnostics and never as a UI error.
    await (client as RemoteServerKeepAliveClient).keepAlive();
  }

  Future<Uint8List> readRemoteImage(
    String profileId,
    String path, {
    int maxBytes = maxRemoteImageBytes,
  }) async {
    _ensureOpen();
    final entry = _entries[profileId];
    if (entry == null || !_isConnected(profileId, entry)) {
      throw StateError('服务器尚未连接');
    }
    final client = entry.client;
    if (client is! RemoteServerImageClient) {
      throw UnsupportedError('当前 SSH 客户端不支持图片预览');
    }
    final imageClient = client as RemoteServerImageClient;
    final generation = entry.generation;
    final bytes = await imageClient.readRemoteImage(path, maxBytes: maxBytes);
    if (!_isConnectedRequest(profileId, entry, client, generation)) {
      throw StateError('图片读取请求已失效');
    }
    return bytes;
  }

  Future<String> uploadAttachment(
    ServerProfile profile,
    String name,
    Uint8List bytes, {
    int maxBytes = maxRemoteAttachmentBytes,
  }) async {
    _ensureOpen();
    final entry = _entries[profile.id];
    if (entry == null) throw StateError('服务器尚未连接');
    if (!entry.profile.hasSameConnectionIdentity(profile)) {
      throw StateError('服务器连接配置已更新');
    }
    if (!_isConnected(profile.id, entry)) {
      throw StateError('服务器尚未连接');
    }
    final client = entry.client;
    if (client is! RemoteServerAttachmentClient) {
      throw UnsupportedError('当前 SSH 客户端不支持附件上传');
    }
    final attachmentClient = client as RemoteServerAttachmentClient;
    final generation = entry.generation;
    final remotePath = await attachmentClient.uploadAttachment(
      name,
      bytes,
      maxBytes: maxBytes,
    );
    if (!_isConnectedRequest(profile.id, entry, client, generation) ||
        !entry.profile.hasSameConnectionIdentity(profile)) {
      throw StateError('附件上传请求已失效');
    }
    return remotePath;
  }

  Future<RemoteDirectoryListing> listDirectories(
    ServerProfile profile,
    String? path,
  ) async {
    _ensureOpen();
    final entry = _entries[profile.id];
    if (entry == null) throw StateError('服务器尚未连接');
    if (!entry.profile.hasSameConnectionIdentity(profile)) {
      throw StateError('服务器连接配置已更新');
    }
    if (!_isConnected(profile.id, entry)) {
      throw StateError('服务器尚未连接');
    }
    final client = entry.client;
    if (client is! RemoteServerDirectoryClient) {
      throw UnsupportedError('当前 SSH 客户端不支持目录浏览');
    }
    final directoryClient = client as RemoteServerDirectoryClient;
    final generation = entry.generation;
    final listing = await directoryClient.listDirectories(path);
    if (!_isConnectedRequest(profile.id, entry, client, generation) ||
        !entry.profile.hasSameConnectionIdentity(profile)) {
      throw StateError('目录浏览请求已失效');
    }
    return listing;
  }

  Future<int> downloadRemoteFile(
    ServerProfile profile,
    String path, {
    required Future<void> Function(Uint8List chunk) writeChunk,
    int maxBytes = maxRemoteFileBytes,
  }) async {
    _ensureOpen();
    final entry = _entries[profile.id];
    if (entry == null) throw StateError('服务器尚未连接');
    if (!entry.profile.hasSameConnectionIdentity(profile)) {
      throw StateError('服务器连接配置已更新');
    }
    if (!_isConnected(profile.id, entry)) {
      throw StateError('服务器尚未连接');
    }
    final client = entry.client;
    if (client is! RemoteServerFileClient) {
      throw UnsupportedError('当前 SSH 客户端不支持文件下载');
    }
    final fileClient = client as RemoteServerFileClient;
    final generation = entry.generation;

    void ensureRequestIsCurrent() {
      if (!_isConnectedRequest(profile.id, entry, client, generation) ||
          !entry.profile.hasSameConnectionIdentity(profile)) {
        throw StateError('文件下载请求已失效');
      }
    }

    final downloadedBytes = await fileClient.downloadRemoteFile(
      path,
      maxBytes: maxBytes,
      writeChunk: (chunk) async {
        ensureRequestIsCurrent();
        await writeChunk(chunk);
        ensureRequestIsCurrent();
      },
    );
    ensureRequestIsCurrent();
    return downloadedBytes;
  }

  Future<RemoteFileListing> listRemoteFiles(
    ServerProfile profile,
    String? path,
  ) async {
    final request = _fileManagerRequest(profile);
    final listing = await request.fileClient.listRemoteFiles(path);
    _ensureFileManagerRequestCurrent(profile, request, '文件列表请求已失效');
    return listing;
  }

  Future<void> uploadRemoteFile(
    ServerProfile profile,
    String directory,
    String name,
    Stream<List<int>> chunks, {
    int? declaredSize,
    int maxBytes = maxRemoteFileBytes,
  }) async {
    final request = _fileManagerRequest(profile);

    Stream<List<int>> guardedChunks() async* {
      await for (final chunk in chunks) {
        _ensureFileManagerRequestCurrent(profile, request, '文件上传请求已失效');
        yield chunk;
        _ensureFileManagerRequestCurrent(profile, request, '文件上传请求已失效');
      }
    }

    await request.fileClient.uploadRemoteFile(
      directory,
      name,
      guardedChunks(),
      declaredSize: declaredSize,
      maxBytes: maxBytes,
    );
    _ensureFileManagerRequestCurrent(profile, request, '文件上传请求已失效');
  }

  Future<void> renameRemoteFile(
    ServerProfile profile,
    String path,
    String newName,
  ) async {
    final request = _fileManagerRequest(profile);
    await request.fileClient.renameRemoteFile(path, newName);
    _ensureFileManagerRequestCurrent(profile, request, '文件重命名请求已失效');
  }

  Future<void> deleteRemoteFiles(
    ServerProfile profile,
    List<String> paths,
  ) async {
    final request = _fileManagerRequest(profile);
    await request.fileClient.deleteRemoteFiles(paths);
    _ensureFileManagerRequestCurrent(profile, request, '文件删除请求已失效');
  }

  Future<void> transferRemoteFiles(
    ServerProfile profile,
    List<String> paths,
    String destinationDirectory,
    RemoteFileTransferMode mode,
  ) async {
    final request = _fileManagerRequest(profile);
    await request.fileClient.transferRemoteFiles(
      paths,
      destinationDirectory,
      mode,
    );
    _ensureFileManagerRequestCurrent(profile, request, '文件传输请求已失效');
  }

  Future<void> _readServerMetrics(
    String profileId,
    _ServerEntry entry,
    RemoteServerClient client,
    int generation,
  ) async {
    try {
      final metrics = await client.readServerMetrics(entry.profile);
      if (_isConnectedRequest(profileId, entry, client, generation)) {
        _setServerMetrics(profileId, metrics);
      }
    } catch (error) {
      if (_isConnectedRequest(profileId, entry, client, generation)) {
        _setServerMetrics(
          profileId,
          ServerMetrics(
            sampledAtEpochMillis: DateTime.now().millisecondsSinceEpoch,
            error: _message(error, '读取失败'),
          ),
        );
      }
    }
  }

  void remove(String profileId) {
    final entry = _entries.remove(profileId);
    entry?.generation++;
    entry?.metricsRequest = null;
    entry?.client.close();
    _clearServerMetrics(profileId);
    if (_states.remove(profileId) != null) _emitStates();
  }

  Future<void> _watchDisconnect(
    String profileId,
    _ServerEntry entry,
    int generation,
  ) async {
    Object? closeError;
    try {
      await entry.client.done;
    } catch (error) {
      closeError = error;
    }
    if (_isCurrent(profileId, entry) && generation == entry.generation) {
      entry.metricsRequest = null;
      _setState(
        profileId,
        ConnectionState(
          phase: ConnectionPhase.disconnected,
          message: closeError == null
              ? 'SSH 连接已断开（远端已关闭）'
              : 'SSH 连接已断开：${_message(closeError, '传输异常')}',
        ),
      );
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final entries = _entries.values.toList();
    _entries.clear();
    _states.clear();
    _serverMetrics.clear();
    for (final entry in entries) {
      entry.generation++;
      entry.metricsRequest = null;
      entry.client.close();
    }
    await _stateController.close();
    await _serverMetricsController.close();
  }

  bool _isCurrent(String profileId, _ServerEntry entry) =>
      identical(_entries[profileId], entry);

  bool _isConnected(String profileId, _ServerEntry entry) =>
      _isCurrent(profileId, entry) &&
      _states[profileId]?.phase == ConnectionPhase.connected &&
      entry.client.isConnected;

  bool _isConnectedRequest(
    String profileId,
    _ServerEntry entry,
    RemoteServerClient client,
    int generation,
  ) =>
      !_closed &&
      identical(entry.client, client) &&
      entry.generation == generation &&
      _isConnected(profileId, entry);

  ({
    _ServerEntry entry,
    RemoteServerClient client,
    RemoteServerFileManagerClient fileClient,
    int generation,
  })
  _fileManagerRequest(ServerProfile profile) {
    _ensureOpen();
    final entry = _entries[profile.id];
    if (entry == null || !_isConnected(profile.id, entry)) {
      throw StateError('服务器尚未连接');
    }
    if (!entry.profile.hasSameConnectionIdentity(profile)) {
      throw StateError('服务器连接配置已更新');
    }
    final client = entry.client;
    if (client is! RemoteServerFileManagerClient) {
      throw UnsupportedError('当前 SSH 客户端不支持文件管理');
    }
    return (
      entry: entry,
      client: client,
      fileClient: client as RemoteServerFileManagerClient,
      generation: entry.generation,
    );
  }

  void _ensureFileManagerRequestCurrent(
    ServerProfile profile,
    ({
      _ServerEntry entry,
      RemoteServerClient client,
      RemoteServerFileManagerClient fileClient,
      int generation,
    })
    request,
    String message,
  ) {
    if (!_isConnectedRequest(
          profile.id,
          request.entry,
          request.client,
          request.generation,
        ) ||
        !request.entry.profile.hasSameConnectionIdentity(profile)) {
      throw StateError(message);
    }
  }

  void _setState(String profileId, ConnectionState state) {
    if (_closed) return;
    if (state.phase != ConnectionPhase.connected) {
      _entries[profileId]?.metricsRequest = null;
    }
    _states[profileId] = state;
    _emitStates();
  }

  void _setServerMetrics(String profileId, ServerMetrics metrics) {
    if (_closed) return;
    _serverMetrics[profileId] = metrics;
    _emitServerMetrics();
  }

  void _clearServerMetrics(String profileId) {
    if (_serverMetrics.remove(profileId) != null) _emitServerMetrics();
  }

  void _emitStates() {
    if (!_stateController.isClosed) {
      _stateController.add(Map.unmodifiable(_states));
    }
  }

  void _emitServerMetrics() {
    if (!_serverMetricsController.isClosed) {
      _serverMetricsController.add(Map.unmodifiable(_serverMetrics));
    }
  }

  void _ensureOpen() {
    if (_closed) throw StateError('连接管理器已经关闭');
  }
}

class _ServerEntry {
  _ServerEntry(this.profile, this.client);

  ServerProfile profile;
  final RemoteServerClient client;
  final Lock lock = Lock();
  Future<void>? metricsRequest;
  int generation = 0;
}

String _message(Object error, String fallback) {
  final message = error
      .toString()
      .replaceFirst(RegExp(r'^[^:]+:\s*'), '')
      .trim();
  return message.isEmpty ? fallback : message;
}
