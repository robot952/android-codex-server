import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:synchronized/synchronized.dart';

import '../domain/agent_provider_profile.dart';
import '../domain/models.dart';

abstract interface class AgentProviderStore {
  Future<List<AgentProviderProfile>> loadAll({
    String? serverProfileId,
    AgentKind? agent,
  });

  Future<void> save(AgentProviderProfile profile);

  Future<void> delete({
    required String serverProfileId,
    required AgentKind agent,
    required String id,
  });
}

/// Stores provider settings, including API keys, using the platform secure
/// storage backend shared with server profiles.
class SecureAgentProviderStore implements AgentProviderStore {
  SecureAgentProviderStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(storageNamespace: 'codex_remote'),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
          );

  static const storageKey = 'agent_provider_profiles_v1';
  static const maxProfiles = 256;

  final FlutterSecureStorage _storage;
  final Lock _lock = Lock();

  @override
  Future<List<AgentProviderProfile>> loadAll({
    String? serverProfileId,
    AgentKind? agent,
  }) {
    return _lock.synchronized(() async {
      final profiles = await _readAll();
      return List<AgentProviderProfile>.unmodifiable(
        profiles.where((profile) {
          return (serverProfileId == null ||
                  profile.serverProfileId == serverProfileId) &&
              (agent == null || profile.agent == agent);
        }),
      );
    });
  }

  @override
  Future<void> save(AgentProviderProfile profile) {
    return _lock.synchronized(() async {
      final id = profile.id.trim();
      final serverProfileId = profile.serverProfileId.trim();
      if (id.isEmpty || serverProfileId.isEmpty) {
        throw ArgumentError('Provider profile identity must not be empty');
      }

      final profiles = await _readAll();
      profiles.removeWhere(
        (candidate) =>
            candidate.serverProfileId == serverProfileId &&
            candidate.agent == profile.agent &&
            candidate.id == id,
      );
      profiles.add(
        AgentProviderProfile.fromJson({
          ...profile.toJson(),
          'id': id,
          'serverProfileId': serverProfileId,
        }),
      );
      await _writeAll(profiles);
    });
  }

  @override
  Future<void> delete({
    required String serverProfileId,
    required AgentKind agent,
    required String id,
  }) {
    return _lock.synchronized(() async {
      final profiles = await _readAll();
      profiles.removeWhere(
        (candidate) =>
            candidate.serverProfileId == serverProfileId &&
            candidate.agent == agent &&
            candidate.id == id,
      );
      await _writeAll(profiles);
    });
  }

  Future<List<AgentProviderProfile>> _readAll() async {
    final raw = await _storage.read(key: storageKey);
    if (raw == null || raw.isEmpty) return <AgentProviderProfile>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <AgentProviderProfile>[];
      final profiles = <AgentProviderProfile>[];
      final identities = <String>{};
      for (final value in decoded) {
        final profile = AgentProviderProfile.tryFromJson(value);
        if (profile == null) continue;
        final identity = _identity(profile);
        if (identities.add(identity)) profiles.add(profile);
      }
      return profiles.length <= maxProfiles
          ? profiles
          : profiles.sublist(profiles.length - maxProfiles);
    } on FormatException {
      return <AgentProviderProfile>[];
    }
  }

  Future<void> _writeAll(List<AgentProviderProfile> profiles) async {
    final bounded = profiles.length <= maxProfiles
        ? profiles
        : profiles.sublist(profiles.length - maxProfiles);
    await _storage.write(
      key: storageKey,
      value: jsonEncode(bounded.map((profile) => profile.toJson()).toList()),
    );
  }

  String _identity(AgentProviderProfile profile) =>
      '${profile.serverProfileId}\u0000${profile.agent.storageKeySegment}'
      '\u0000${profile.id}';
}
