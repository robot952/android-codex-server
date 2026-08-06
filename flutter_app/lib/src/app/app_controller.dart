import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:synchronized/synchronized.dart';

import '../domain/models.dart';
import '../persistence/profile_store.dart';
import '../ssh/server_connection_manager.dart';

final profileStoreProvider = Provider<ProfileStore>((ref) {
  return SecureProfileStore();
});

final serverConnectionManagerProvider = Provider<ServerConnectionManager>((
  ref,
) {
  final manager = ServerConnectionManager();
  ref.onDispose(() => unawaited(manager.close()));
  return manager;
});

final appControllerProvider = StateNotifierProvider<AppController, AppUiState>((
  ref,
) {
  return AppController(
    ref.watch(profileStoreProvider),
    ref.watch(serverConnectionManagerProvider),
  );
});

class AppController extends StateNotifier<AppUiState> {
  AppController(this._store, this._connections)
    : super(const AppUiState(loading: true)) {
    _connectionSubscription = _connections.stateChanges.listen(
      _applyConnectionStates,
    );
    _initialization = _initialize();
    unawaited(_initialization);
  }

  final ProfileStore _store;
  final ServerConnectionManager _connections;
  late final StreamSubscription<Map<String, ConnectionState>>
  _connectionSubscription;
  late final Future<void> _initialization;
  final Lock _persistenceLock = Lock();
  StoredProfiles _stored = const StoredProfiles();
  ServerProfile? _pendingFingerprintProfile;

  Future<void> _initialize() async {
    try {
      _stored = await _store.load();
      for (final profile in _stored.profiles) {
        _connections.registerProfile(profile);
      }
      if (!mounted) return;
      final selected =
          _stored.selectedProfileId ?? _stored.profiles.firstOrNull?.id;
      state = state.copyWith(
        profiles: _stored.profiles,
        selectedProfileId: selected,
        connectionStates: _connections.states,
        connection: selected == null
            ? const ConnectionState()
            : _connections.states[selected] ?? const ConnectionState(),
        loading: false,
      );
    } catch (error) {
      if (!mounted) return;
      state = state.copyWith(loading: false, error: _message(error, '读取配置失败'));
    }
  }

  ServerProfile newProfile() => ServerProfile.create();

  Future<ServerProfile> saveProfile(ServerProfile profile) async {
    await _ensureInitialized();
    var normalized = _normalizeProfile(profile);
    final existing = state.profiles.firstWhereOrNull(
      (candidate) => candidate.id == normalized.id,
    );
    final connectionIdentityChanged =
        existing != null && !existing.hasSameConnectionIdentity(normalized);
    if (existing != null &&
        (existing.host.trim() != normalized.host.trim() ||
            existing.port != normalized.port)) {
      normalized = normalized.copyWith(hostFingerprint: '');
    }

    final profiles = [...state.profiles];
    final index = profiles.indexWhere(
      (candidate) => candidate.id == normalized.id,
    );
    if (index < 0) {
      profiles.add(normalized);
    } else {
      profiles[index] = normalized;
    }
    _connections.registerProfile(normalized);
    state = state.copyWith(
      profiles: profiles,
      selectedProfileId: normalized.id,
      connection: _connections.states[normalized.id] ?? const ConnectionState(),
    );
    await _persist((stored) {
      var next = stored.copyWith(
        profiles: profiles,
        selectedProfileId: normalized.id,
      );
      if (connectionIdentityChanged) {
        next = _removeProfileScopedData(next, normalized.id);
      }
      return next;
    });
    return normalized;
  }

  Future<void> deleteProfile(String profileId) async {
    await _ensureInitialized();
    _connections.remove(profileId);
    final profiles = state.profiles
        .where((profile) => profile.id != profileId)
        .toList();
    final selected = state.selectedProfileId == profileId
        ? profiles.firstOrNull?.id
        : state.selectedProfileId;
    state = state.copyWith(
      profiles: profiles,
      selectedProfileId: selected,
      connectionStates: _connections.states,
      connection: selected == null
          ? const ConnectionState()
          : _connections.states[selected] ?? const ConnectionState(),
      screen: AppScreen.servers,
    );
    await _persist(
      (stored) => _removeProfileScopedData(
        stored.copyWith(profiles: profiles, selectedProfileId: selected),
        profileId,
      ),
    );
  }

  void selectProfile(String profileId) {
    unawaited(_selectProfile(profileId));
  }

  Future<void> _selectProfile(String profileId) async {
    await _initialization;
    if (!mounted) return;
    final profile = state.profiles.firstWhereOrNull(
      (candidate) => candidate.id == profileId,
    );
    if (profile == null) return;
    final connection =
        _connections.states[profileId] ?? const ConnectionState();
    state = state.copyWith(
      selectedProfileId: profileId,
      connection: connection,
      screen: connection.phase == ConnectionPhase.connected
          ? AppScreen.threads
          : AppScreen.servers,
    );
    await _persist((stored) => stored.copyWith(selectedProfileId: profileId));
  }

  Future<void> requestConnect(ServerProfile profile) async {
    await _ensureInitialized();
    state = state.copyWith(selectedProfileId: profile.id, error: null);
    await _persist((stored) => stored.copyWith(selectedProfileId: profile.id));
    if (profile.hostFingerprint.trim().isEmpty) {
      try {
        final fingerprint = await _connections.probeFingerprint(profile);
        if (!mounted || state.selectedProfileId != profile.id) return;
        final current = state.profiles.firstWhereOrNull(
          (candidate) => candidate.id == profile.id,
        );
        if (current == null || !current.hasSameConnectionIdentity(profile)) {
          return;
        }
        _pendingFingerprintProfile = current;
        state = state.copyWith(pendingFingerprint: fingerprint);
      } catch (error) {
        _setError(error, '读取 SSH 指纹失败');
      }
      return;
    }
    await _connectVerified(profile);
  }

  Future<void> confirmFingerprint() async {
    final profile = _pendingFingerprintProfile;
    final fingerprint = state.pendingFingerprint;
    if (profile == null || fingerprint == null) return;
    _pendingFingerprintProfile = null;
    state = state.copyWith(pendingFingerprint: null);
    final current = state.profiles.firstWhereOrNull(
      (candidate) => candidate.id == profile.id,
    );
    if (current == null || !current.hasSameConnectionIdentity(profile)) {
      state = state.copyWith(error: '服务器配置已更新，请重新连接并核对指纹');
      return;
    }
    final saved = await saveProfile(
      current.copyWith(hostFingerprint: fingerprint),
    );
    await _connectVerified(saved);
  }

  void cancelFingerprint() {
    _pendingFingerprintProfile = null;
    state = state.copyWith(pendingFingerprint: null);
  }

  Future<void> _connectVerified(ServerProfile profile) async {
    state = state.copyWith(loading: true, error: null);
    try {
      await _connections.connect(profile);
      if (!mounted) return;
      state = state.copyWith(
        selectedProfileId: profile.id,
        connection:
            _connections.states[profile.id] ??
            const ConnectionState(
              phase: ConnectionPhase.connected,
              message: 'SSH 已连接',
            ),
        screen: AppScreen.threads,
        loading: false,
        error: null,
      );
    } catch (error) {
      _setError(error, 'SSH 连接失败');
    }
  }

  Future<void> disconnectProfile(String profileId) async {
    try {
      await _connections.disconnect(profileId);
      if (!mounted) return;
      if (state.selectedProfileId == profileId &&
          state.screen != AppScreen.servers) {
        state = state.copyWith(screen: AppScreen.servers);
      }
    } catch (error) {
      _setError(error, '断开服务器失败');
    }
  }

  void backToServers() {
    state = state.copyWith(screen: AppScreen.servers);
  }

  void enableDebugMode() {
    state = state.copyWith(debugModeEnabled: true);
  }

  void clearError() {
    if (state.error != null) state = state.copyWith(error: null);
  }

  void _applyConnectionStates(Map<String, ConnectionState> connections) {
    if (!mounted) return;
    final selected = state.selectedProfileId;
    state = state.copyWith(
      connectionStates: connections,
      connection: selected == null
          ? const ConnectionState()
          : connections[selected] ?? const ConnectionState(),
    );
  }

  Future<void> _persist(
    StoredProfiles Function(StoredProfiles stored) update,
  ) async {
    await _initialization;
    await _persistenceLock.synchronized(() async {
      final next = normalizeStoredProfiles(update(_stored));
      _stored = next;
      try {
        await _store.save(next);
      } catch (error) {
        _setError(error, '保存配置失败');
      }
    });
  }

  Future<void> _ensureInitialized() async {
    await _initialization;
    if (!mounted) throw StateError('应用控制器已经关闭');
  }

  ServerProfile _normalizeProfile(ServerProfile profile) {
    if (profile.host.trim().isEmpty) throw StateError('服务器地址不能为空');
    if (profile.port < 1 || profile.port > 65535) {
      throw StateError('SSH 端口必须在 1 到 65535 之间');
    }
    return profile.copyWith(
      id: profile.id.trim().isEmpty ? newProfile().id : profile.id.trim(),
      name: profile.name.trim().isEmpty ? '我的服务器' : profile.name.trim(),
      host: profile.host.trim(),
      username: profile.username.trim().isEmpty
          ? 'root'
          : profile.username.trim(),
    );
  }

  void _setError(Object error, String fallback) {
    if (!mounted) return;
    state = state.copyWith(loading: false, error: _message(error, fallback));
  }

  @override
  void dispose() {
    unawaited(_connectionSubscription.cancel());
    super.dispose();
  }
}

StoredProfiles _removeProfileScopedData(
  StoredProfiles stored,
  String profileId,
) => stored.copyWith(
  composerDrafts: _withoutProfileEntries(stored.composerDrafts, profileId),
  threadModelPreferences: _withoutProfileEntries(
    stored.threadModelPreferences,
    profileId,
  ),
  completedTurnTimings: _withoutProfileEntries(
    stored.completedTurnTimings,
    profileId,
  ),
);

Map<String, V> _withoutProfileEntries<V>(
  Map<String, V> values,
  String profileId,
) {
  final prefix = '$profileId\u0000';
  return Map<String, V>.unmodifiable(
    Map<String, V>.fromEntries(
      values.entries.where((entry) => !entry.key.startsWith(prefix)),
    ),
  );
}

String _message(Object error, String fallback) {
  final message = error
      .toString()
      .replaceFirst(RegExp(r'^[^:]+:\s*'), '')
      .trim();
  return message.isEmpty ? fallback : message;
}

extension _FirstWhereOrNull<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T value) test) {
    for (final value in this) {
      if (test(value)) return value;
    }
    return null;
  }
}
