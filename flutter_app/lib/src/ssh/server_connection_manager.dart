import 'dart:async';

import 'package:synchronized/synchronized.dart';

import '../domain/models.dart';
import 'ssh_server_client.dart';

typedef RemoteServerClientFactory = RemoteServerClient Function();

class ServerConnectionManager {
  ServerConnectionManager({RemoteServerClientFactory? clientFactory})
    : _clientFactory = clientFactory ?? DartSshServerClient.new;

  final RemoteServerClientFactory _clientFactory;
  final Map<String, _ServerEntry> _entries = {};
  final Map<String, ConnectionState> _states = {};
  final StreamController<Map<String, ConnectionState>> _stateController =
      StreamController<Map<String, ConnectionState>>.broadcast(sync: true);
  bool _closed = false;

  Map<String, ConnectionState> get states => Map.unmodifiable(_states);
  Stream<Map<String, ConnectionState>> get stateChanges =>
      _stateController.stream;

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
      existing.client.close();
    }
    final entry = _ServerEntry(profile, _clientFactory());
    _entries[profile.id] = entry;
    _setState(profile.id, const ConnectionState());
    return entry.client;
  }

  RemoteServerClient? client(String profileId) => _entries[profileId]?.client;
  ServerProfile? profile(String profileId) => _entries[profileId]?.profile;

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
      await entry.client.disconnect();
      if (_isCurrent(profileId, entry)) {
        _setState(profileId, const ConnectionState());
      }
    });
  }

  void remove(String profileId) {
    final entry = _entries.remove(profileId);
    entry?.generation++;
    entry?.client.close();
    if (_states.remove(profileId) != null) _emitStates();
  }

  Future<void> _watchDisconnect(
    String profileId,
    _ServerEntry entry,
    int generation,
  ) async {
    try {
      await entry.client.done;
    } catch (_) {
      // The visible state below is the same for clean and exceptional closure.
    }
    if (_isCurrent(profileId, entry) && generation == entry.generation) {
      _setState(
        profileId,
        const ConnectionState(
          phase: ConnectionPhase.disconnected,
          message: 'SSH 连接已断开',
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
    for (final entry in entries) {
      entry.generation++;
      entry.client.close();
    }
    await _stateController.close();
  }

  bool _isCurrent(String profileId, _ServerEntry entry) =>
      identical(_entries[profileId], entry);

  void _setState(String profileId, ConnectionState state) {
    if (_closed) return;
    _states[profileId] = state;
    _emitStates();
  }

  void _emitStates() {
    if (!_stateController.isClosed) {
      _stateController.add(Map.unmodifiable(_states));
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
  int generation = 0;
}

String _message(Object error, String fallback) {
  final message = error
      .toString()
      .replaceFirst(RegExp(r'^[^:]+:\s*'), '')
      .trim();
  return message.isEmpty ? fallback : message;
}
