import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:synchronized/synchronized.dart';

import '../domain/models.dart';

abstract interface class ThreadListCacheStore {
  Future<Map<AgentConnectionKey, List<AgentThread>>> readAll();

  Future<void> write(AgentConnectionKey key, List<AgentThread> threads);

  Future<void> remove(AgentConnectionKey key);
}

class NoopThreadListCacheStore implements ThreadListCacheStore {
  const NoopThreadListCacheStore();

  @override
  Future<Map<AgentConnectionKey, List<AgentThread>>> readAll() async =>
      const <AgentConnectionKey, List<AgentThread>>{};

  @override
  Future<void> write(AgentConnectionKey key, List<AgentThread> threads) async {}

  @override
  Future<void> remove(AgentConnectionKey key) async {}
}

/// A small, disposable cache for the most recently listed threads.
///
/// It is intentionally separate from the encrypted transcript cache: thread
/// titles and previews are not credentials, and SharedPreferences lets the
/// thread list render before an SSH connection is ready.
class SharedPreferencesThreadListCacheStore implements ThreadListCacheStore {
  SharedPreferencesThreadListCacheStore({
    Future<SharedPreferences> Function()? preferencesProvider,
    int Function()? nowEpochMillis,
    this.ttl = const Duration(days: 7),
    this.maxThreadsPerLane = 100,
    this.maxLanes = 64,
  }) : _preferencesProvider =
           preferencesProvider ?? SharedPreferences.getInstance,
       _nowEpochMillis = nowEpochMillis ?? _now {
    if (ttl <= Duration.zero || maxThreadsPerLane < 1 || maxLanes < 1) {
      throw ArgumentError('Invalid thread list cache limits');
    }
  }

  static const _storageKey = 'thread_list_cache_v1';

  final Future<SharedPreferences> Function() _preferencesProvider;
  final int Function() _nowEpochMillis;
  final Duration ttl;
  final int maxThreadsPerLane;
  final int maxLanes;
  final Lock _lock = Lock();

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  @override
  Future<Map<AgentConnectionKey, List<AgentThread>>> readAll() {
    return _lock.synchronized(() async {
      final preferences = await _preferencesProvider();
      final raw = preferences.getString(_storageKey);
      if (raw == null || raw.isEmpty) {
        return const <AgentConnectionKey, List<AgentThread>>{};
      }
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map) {
          return const <AgentConnectionKey, List<AgentThread>>{};
        }
        final now = _nowEpochMillis();
        final result = <AgentConnectionKey, List<AgentThread>>{};
        for (final entry in decoded.entries) {
          if (entry.key is! String || entry.value is! Map) continue;
          final record = Map<Object?, Object?>.from(entry.value as Map);
          final savedAt = _asInt(record['savedAt']);
          if (savedAt == null || now - savedAt > ttl.inMilliseconds) continue;
          final key = _decodeKey(entry.key as String);
          if (key == null || record['threads'] is! List) continue;
          final threads = <AgentThread>[];
          for (final item in record['threads'] as List) {
            if (item is! Map) continue;
            final thread = _decodeThread(Map<Object?, Object?>.from(item));
            if (thread != null) threads.add(thread);
          }
          if (threads.isNotEmpty) {
            result[key] = List<AgentThread>.unmodifiable(threads);
          }
        }
        return Map<AgentConnectionKey, List<AgentThread>>.unmodifiable(result);
      } catch (_) {
        return const <AgentConnectionKey, List<AgentThread>>{};
      }
    });
  }

  @override
  Future<void> write(AgentConnectionKey key, List<AgentThread> threads) {
    return _lock.synchronized(() async {
      final preferences = await _preferencesProvider();
      final records = await _readRecords(preferences);
      final limited = threads
          .take(maxThreadsPerLane)
          .map(_encodeThread)
          .toList();
      records[_encodeKey(key)] = <String, Object?>{
        'savedAt': _nowEpochMillis(),
        'threads': limited,
      };
      await preferences.setString(
        _storageKey,
        jsonEncode(_trimRecords(records)),
      );
    });
  }

  @override
  Future<void> remove(AgentConnectionKey key) {
    return _lock.synchronized(() async {
      final preferences = await _preferencesProvider();
      final records = await _readRecords(preferences);
      records.remove(_encodeKey(key));
      await preferences.setString(_storageKey, jsonEncode(records));
    });
  }

  Future<Map<String, Map<String, Object?>>> _readRecords(
    SharedPreferences preferences,
  ) async {
    final raw = preferences.getString(_storageKey);
    if (raw == null || raw.isEmpty) return <String, Map<String, Object?>>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, Map<String, Object?>>{};
      final records = <String, Map<String, Object?>>{};
      for (final entry in decoded.entries) {
        if (entry.key is String && entry.value is Map) {
          records[entry.key as String] = Map<String, Object?>.from(
            entry.value as Map,
          );
        }
      }
      return records;
    } catch (_) {
      return <String, Map<String, Object?>>{};
    }
  }

  Map<String, Map<String, Object?>> _trimRecords(
    Map<String, Map<String, Object?>> records,
  ) {
    final valid = records.entries.where((entry) {
      final savedAt = _asInt(entry.value['savedAt']);
      return savedAt != null &&
          _nowEpochMillis() - savedAt <= ttl.inMilliseconds;
    }).toList();
    valid.sort(
      (a, b) => (_asInt(b.value['savedAt']) ?? 0).compareTo(
        _asInt(a.value['savedAt']) ?? 0,
      ),
    );
    return <String, Map<String, Object?>>{
      for (final entry in valid.take(maxLanes)) entry.key: entry.value,
    };
  }

  static String _encodeKey(AgentConnectionKey key) =>
      '${key.profileId}\u0000${key.agent.name}';

  static AgentConnectionKey? _decodeKey(String value) {
    final separator = value.lastIndexOf('\u0000');
    if (separator <= 0 || separator >= value.length - 1) return null;
    final profileId = value.substring(0, separator);
    final agentName = value.substring(separator + 1);
    for (final agent in AgentKind.values) {
      if (agent.name == agentName) {
        return AgentConnectionKey(profileId: profileId, agent: agent);
      }
    }
    return null;
  }

  static Map<String, Object?> _encodeThread(AgentThread thread) => {
    'id': thread.id,
    'title': thread.title,
    'preview': thread.preview,
    'cwd': thread.cwd,
    'source': thread.source,
    'modelProvider': thread.modelProvider,
    'status': thread.status,
    'createdAt': thread.createdAt,
    'updatedAt': thread.updatedAt,
    'cliVersion': thread.cliVersion,
    'activeTurnId': thread.activeTurnId,
    'isExternallyOwned': thread.isExternallyOwned,
  };

  static AgentThread? _decodeThread(Map<Object?, Object?> map) {
    final id = _asString(map['id']);
    if (id == null || id.isEmpty) return null;
    return AgentThread(
      id: id,
      title: _asString(map['title']) ?? '',
      preview: _asString(map['preview']) ?? '',
      cwd: _asString(map['cwd']) ?? '',
      source: _asString(map['source']) ?? '',
      modelProvider: _asString(map['modelProvider']) ?? '',
      status: _asString(map['status']) ?? 'idle',
      createdAt: _asInt(map['createdAt']) ?? 0,
      updatedAt: _asInt(map['updatedAt']) ?? 0,
      cliVersion: _asString(map['cliVersion']) ?? '',
      activeTurnId: _asString(map['activeTurnId']),
      isExternallyOwned: _asBool(map['isExternallyOwned']) ?? false,
    );
  }

  static String? _asString(Object? value) => value is String ? value : null;

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  static bool? _asBool(Object? value) => value is bool ? value : null;
}
