import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:uuid/uuid.dart';

import '../domain/models.dart';

abstract interface class ProfileStore {
  Future<StoredProfiles> load();
  Future<void> save(StoredProfiles value);
}

abstract interface class LegacyProfileImporter {
  Future<String?> readLegacyJson();
  Future<void> clearLegacyJson();
}

class NativeLegacyProfileImporter implements LegacyProfileImporter {
  const NativeLegacyProfileImporter();

  static const _channel = MethodChannel('top.asdb.codexremote/legacy');

  @override
  Future<String?> readLegacyJson() async {
    try {
      return await _channel.invokeMethod<String>('readLegacyProfiles');
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<void> clearLegacyJson() async {
    try {
      await _channel.invokeMethod<void>('clearLegacyProfiles');
    } on MissingPluginException {
      // Non-Android platforms never had the native profile store.
    }
  }
}

class SecureProfileStore implements ProfileStore {
  SecureProfileStore({
    FlutterSecureStorage? storage,
    LegacyProfileImporter? legacyImporter,
  }) : _storage =
           storage ??
           const FlutterSecureStorage(
             aOptions: AndroidOptions(storageNamespace: 'codex_remote'),
             iOptions: IOSOptions(
               accessibility: KeychainAccessibility.first_unlock_this_device,
             ),
           ),
       _legacyImporter = legacyImporter ?? const NativeLegacyProfileImporter();

  static const storageKey = 'profiles_v2';
  static const migrationMarkerKey = 'profiles_v1_migration_complete';
  static const migrationMarkerValue = '1';
  static const maxComposerDrafts = 64;
  static const maxDraftLength = 100_000;
  static const maxThreadModelPreferences = 512;
  static const maxCompletedTurnTimings = 512;

  final FlutterSecureStorage _storage;
  final LegacyProfileImporter _legacyImporter;

  @override
  Future<StoredProfiles> load() async {
    final raw = await _storage.read(key: storageKey);
    final migrationComplete =
        await _storage.read(key: migrationMarkerKey) == migrationMarkerValue;
    if (raw != null && raw.isNotEmpty) {
      final decoded = _decodeStoredProfiles(raw);
      if (decoded == null) return const StoredProfiles();
      if (!migrationComplete) await _completeLegacyMigration();
      return decoded;
    }
    if (migrationComplete) return const StoredProfiles();

    final legacyRaw = await _legacyImporter.readLegacyJson();
    if (legacyRaw == null || legacyRaw.isEmpty) {
      await _markLegacyMigrationComplete();
      return const StoredProfiles();
    }
    final decoded = _decodeStoredProfiles(legacyRaw);
    if (decoded == null) return const StoredProfiles();
    await save(decoded);
    await _completeLegacyMigration();
    return decoded;
  }

  StoredProfiles? _decodeStoredProfiles(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) return null;
      return normalizeStoredProfiles(StoredProfiles.fromJson(decoded));
    } on FormatException {
      return null;
    } on CheckedFromJsonException {
      return null;
    } on TypeError {
      return null;
    } on ArgumentError {
      return null;
    }
  }

  Future<void> _completeLegacyMigration() async {
    await _legacyImporter.clearLegacyJson();
    await _markLegacyMigrationComplete();
  }

  Future<void> _markLegacyMigrationComplete() =>
      _storage.write(key: migrationMarkerKey, value: migrationMarkerValue);

  @override
  Future<void> save(StoredProfiles value) async {
    final normalized = normalizeStoredProfiles(value);
    await _storage.write(
      key: storageKey,
      value: jsonEncode(normalized.toJson()),
    );
  }
}

StoredProfiles normalizeStoredProfiles(StoredProfiles value) {
  final seen = <String>{};
  final profiles = <ServerProfile>[];
  for (final profile in value.profiles) {
    final id = profile.id.trim().isEmpty
        ? const Uuid().v4()
        : profile.id.trim();
    if (!seen.add(id)) continue;
    profiles.add(
      profile.copyWith(
        id: id,
        name: profile.name.trim().isEmpty ? '我的服务器' : profile.name.trim(),
        port: profile.port.clamp(1, 65535),
        username: profile.username.trim().isEmpty
            ? 'root'
            : profile.username.trim(),
      ),
    );
  }

  final selected =
      value.selectedProfileId?.takeIf(seen.contains) ??
      profiles.firstOrNull?.id;
  return value.copyWith(
    profiles: profiles,
    selectedProfileId: selected,
    composerDrafts: _boundedMap(
      _normalizeAgentStorageKeys(
        value.composerDrafts.map(
          (key, draft) => MapEntry(
            key,
            draft.length <= SecureProfileStore.maxDraftLength
                ? draft
                : draft.substring(0, SecureProfileStore.maxDraftLength),
          ),
        ),
      ),
      SecureProfileStore.maxComposerDrafts,
    ),
    threadModelPreferences: _boundedMap(
      _normalizeAgentStorageKeys(value.threadModelPreferences),
      SecureProfileStore.maxThreadModelPreferences,
    ),
    completedTurnTimings: _boundedMap(
      _normalizeAgentStorageKeys(value.completedTurnTimings),
      SecureProfileStore.maxCompletedTurnTimings,
    ),
  );
}

Map<String, V> _normalizeAgentStorageKeys<V>(Map<String, V> source) {
  final result = <String, V>{};
  for (final entry in source.entries) {
    final key = _normalizeAgentStorageKey(entry.key);
    if (key == entry.key) {
      // Canonical entries win if an early Flutter alias is also present.
      result.remove(key);
      result[key] = entry.value;
    } else {
      result.putIfAbsent(key, () => entry.value);
    }
  }
  return result;
}

String _normalizeAgentStorageKey(String key) {
  final profileSeparator = key.indexOf('\u0000');
  if (profileSeparator < 0) return key;
  final agentSeparator = key.indexOf('\u0000', profileSeparator + 1);
  if (agentSeparator < 0) return key;

  final agent = key.substring(profileSeparator + 1, agentSeparator);
  final stableAgent = switch (agent) {
    'codex' => AgentKind.codex.storageKeySegment,
    'openCode' => AgentKind.openCode.storageKeySegment,
    _ => agent,
  };
  if (stableAgent == agent) return key;
  return '${key.substring(0, profileSeparator + 1)}$stableAgent'
      '${key.substring(agentSeparator)}';
}

Map<K, V> _boundedMap<K, V>(Map<K, V> source, int maximumEntries) {
  if (source.length <= maximumEntries) {
    return Map<K, V>.unmodifiable(source);
  }
  return Map<K, V>.unmodifiable(
    Map<K, V>.fromEntries(source.entries.skip(source.length - maximumEntries)),
  );
}

extension _NullableTakeIf<T> on T? {
  T? takeIf(bool Function(T value) predicate) {
    final value = this;
    return value != null && predicate(value) ? value : null;
  }
}
