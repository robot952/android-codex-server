import 'dart:convert';

import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/persistence/profile_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _LegacyImporter implements LegacyProfileImporter {
  _LegacyImporter(this.value, {this.readError, this.clearError});

  final String? value;
  final Object? readError;
  final Object? clearError;
  int calls = 0;
  int clearCalls = 0;

  @override
  Future<String?> readLegacyJson() async {
    calls++;
    if (readError != null) throw readError!;
    return value;
  }

  @override
  Future<void> clearLegacyJson() async {
    clearCalls++;
    if (clearError != null) throw clearError!;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('normalizes invalid profiles and keeps selection valid', () {
    final normalized = normalizeStoredProfiles(
      const StoredProfiles(
        profiles: [
          ServerProfile(id: '', name: '', username: '', port: 0),
          ServerProfile(id: 'same'),
          ServerProfile(id: 'same', name: 'duplicate'),
        ],
        selectedProfileId: 'missing',
      ),
    );

    expect(normalized.profiles, hasLength(2));
    expect(normalized.profiles.first.id, isNotEmpty);
    expect(normalized.profiles.first.name, '我的服务器');
    expect(normalized.profiles.first.username, 'root');
    expect(normalized.profiles.first.port, 1);
    expect(normalized.selectedProfileId, normalized.profiles.first.id);
  });

  test('matches native limits and keeps the beginning of oversized drafts', () {
    final oversizedDraft =
        'draft-start${'x' * SecureProfileStore.maxDraftLength}draft-end';
    final drafts = <String, String>{
      for (
        var index = 0;
        index < SecureProfileStore.maxComposerDrafts + 5;
        index++
      )
        'draft-$index': index == SecureProfileStore.maxComposerDrafts + 4
            ? oversizedDraft
            : 'draft $index',
    };
    final preferences = <String, ThreadModelPreference>{
      for (
        var index = 0;
        index < SecureProfileStore.maxThreadModelPreferences + 5;
        index++
      )
        'preference-$index': ThreadModelPreference(model: 'model-$index'),
    };
    final timings = <String, TurnTiming>{
      for (
        var index = 0;
        index < SecureProfileStore.maxCompletedTurnTimings + 5;
        index++
      )
        'timing-$index': TurnTiming(
          threadId: 'thread-$index',
          startedAtMillis: index,
          completedAtMillis: index + 1,
        ),
    };

    final normalized = normalizeStoredProfiles(
      StoredProfiles(
        composerDrafts: drafts,
        threadModelPreferences: preferences,
        completedTurnTimings: timings,
      ),
    );

    expect(
      normalized.composerDrafts,
      hasLength(SecureProfileStore.maxComposerDrafts),
    );
    expect(normalized.composerDrafts.containsKey('draft-0'), isFalse);
    final boundedDraft = normalized.composerDrafts.values.last;
    expect(boundedDraft, hasLength(SecureProfileStore.maxDraftLength));
    expect(boundedDraft, oversizedDraft.substring(0, boundedDraft.length));
    expect(boundedDraft, startsWith('draft-start'));
    expect(boundedDraft, isNot(endsWith('draft-end')));
    expect(
      normalized.threadModelPreferences,
      hasLength(SecureProfileStore.maxThreadModelPreferences),
    );
    expect(
      normalized.threadModelPreferences.containsKey('preference-0'),
      false,
    );
    expect(
      normalized.completedTurnTimings,
      hasLength(SecureProfileStore.maxCompletedTurnTimings),
    );
    expect(normalized.completedTurnTimings.containsKey('timing-0'), false);
  });

  test('migrates early Flutter agent key segments to stable native names', () {
    const codexKey = 'server\u0000Codex\u0000thread';
    const earlyCodexKey = 'server\u0000codex\u0000thread';
    const openCodeKey = 'server\u0000OpenCode\u0000thread';
    const earlyOpenCodeKey = 'server\u0000openCode\u0000thread';
    const legacyCodexKey = 'server\u0000thread';

    final normalized = normalizeStoredProfiles(
      const StoredProfiles(
        composerDrafts: {
          earlyCodexKey: 'early value',
          codexKey: 'canonical value',
          earlyOpenCodeKey: 'open value',
          legacyCodexKey: 'legacy value',
        },
        threadModelPreferences: {
          earlyOpenCodeKey: ThreadModelPreference(model: 'open-model'),
        },
        completedTurnTimings: {
          earlyCodexKey: TurnTiming(
            threadId: 'thread',
            startedAtMillis: 1,
            completedAtMillis: 2,
          ),
        },
      ),
    );

    expect(normalized.composerDrafts[codexKey], 'canonical value');
    expect(normalized.composerDrafts[openCodeKey], 'open value');
    expect(normalized.composerDrafts[legacyCodexKey], 'legacy value');
    expect(normalized.composerDrafts.containsKey(earlyCodexKey), isFalse);
    expect(normalized.composerDrafts.containsKey(earlyOpenCodeKey), isFalse);
    expect(normalized.threadModelPreferences[openCodeKey]?.model, 'open-model');
    expect(normalized.completedTurnTimings[codexKey]?.threadId, 'thread');
  });

  test('imports legacy encrypted payload once and persists v2', () async {
    final legacy = _LegacyImporter(
      jsonEncode({
        'profiles': [
          {'id': 'legacy', 'name': '旧服务器', 'authMode': 'Password'},
        ],
        'selectedProfileId': 'legacy',
      }),
    );
    final storage = const FlutterSecureStorage();
    final store = SecureProfileStore(storage: storage, legacyImporter: legacy);

    final loaded = await store.load();
    expect(loaded.profiles.single.name, '旧服务器');
    expect(loaded.profiles.single.authMode, AuthMode.password);
    expect(legacy.calls, 1);
    expect(legacy.clearCalls, 1);

    final persisted = await storage.read(key: SecureProfileStore.storageKey);
    expect(persisted, isNotNull);
    expect(
      await storage.read(key: SecureProfileStore.migrationMarkerKey),
      SecureProfileStore.migrationMarkerValue,
    );

    final secondImporter = _LegacyImporter(null);
    final second = SecureProfileStore(
      storage: storage,
      legacyImporter: secondImporter,
    );
    expect((await second.load()).profiles.single.id, 'legacy');
    expect(secondImporter.calls, 0);
    expect(secondImporter.clearCalls, 0);
  });

  test('marks a genuinely absent legacy store as migrated', () async {
    final legacy = _LegacyImporter(null);
    const storage = FlutterSecureStorage();
    final store = SecureProfileStore(storage: storage, legacyImporter: legacy);

    expect(await store.load(), const StoredProfiles());
    expect(legacy.calls, 1);
    expect(legacy.clearCalls, 0);
    expect(
      await storage.read(key: SecureProfileStore.migrationMarkerKey),
      SecureProfileStore.migrationMarkerValue,
    );
    expect(await storage.read(key: SecureProfileStore.storageKey), isNull);
  });

  test(
    'propagates legacy platform errors without committing migration',
    () async {
      final legacy = _LegacyImporter(
        null,
        readError: PlatformException(code: 'legacy_read_failed'),
      );
      const storage = FlutterSecureStorage();
      final store = SecureProfileStore(
        storage: storage,
        legacyImporter: legacy,
      );

      await expectLater(store.load(), throwsA(isA<PlatformException>()));
      expect(legacy.calls, 1);
      expect(legacy.clearCalls, 0);
      expect(await storage.read(key: SecureProfileStore.storageKey), isNull);
      expect(
        await storage.read(key: SecureProfileStore.migrationMarkerKey),
        isNull,
      );
    },
  );

  test('existing v2 content completes cleanup without reading v1', () async {
    FlutterSecureStorage.setMockInitialValues({
      SecureProfileStore.storageKey: jsonEncode({
        'profiles': [
          {'id': 'current'},
        ],
      }),
    });
    final legacy = _LegacyImporter(
      null,
      readError: StateError('v1 should not be read'),
    );
    const storage = FlutterSecureStorage();
    final store = SecureProfileStore(storage: storage, legacyImporter: legacy);

    expect((await store.load()).profiles.single.id, 'current');
    expect(legacy.calls, 0);
    expect(legacy.clearCalls, 1);
    expect(
      await storage.read(key: SecureProfileStore.migrationMarkerKey),
      SecureProfileStore.migrationMarkerValue,
    );
  });

  test(
    'migration marker prevents stale v1 content from being restored',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        SecureProfileStore.migrationMarkerKey:
            SecureProfileStore.migrationMarkerValue,
      });
      final legacy = _LegacyImporter(
        jsonEncode({
          'profiles': [
            {'id': 'stale'},
          ],
        }),
      );
      const storage = FlutterSecureStorage();
      final store = SecureProfileStore(
        storage: storage,
        legacyImporter: legacy,
      );

      expect(await store.load(), const StoredProfiles());
      expect(legacy.calls, 0);
      expect(legacy.clearCalls, 0);
      expect(await storage.read(key: SecureProfileStore.storageKey), isNull);
    },
  );

  test('retries cleanup before writing the migration marker', () async {
    final payload = jsonEncode({
      'profiles': [
        {'id': 'legacy'},
      ],
    });
    final failingImporter = _LegacyImporter(
      payload,
      clearError: StateError('clear failed'),
    );
    const storage = FlutterSecureStorage();
    final firstStore = SecureProfileStore(
      storage: storage,
      legacyImporter: failingImporter,
    );

    await expectLater(firstStore.load(), throwsStateError);
    expect(failingImporter.calls, 1);
    expect(failingImporter.clearCalls, 1);
    expect(await storage.read(key: SecureProfileStore.storageKey), isNotNull);
    expect(
      await storage.read(key: SecureProfileStore.migrationMarkerKey),
      isNull,
    );

    final retryImporter = _LegacyImporter(null);
    final retryStore = SecureProfileStore(
      storage: storage,
      legacyImporter: retryImporter,
    );
    expect((await retryStore.load()).profiles.single.id, 'legacy');
    expect(retryImporter.calls, 0);
    expect(retryImporter.clearCalls, 1);
    expect(
      await storage.read(key: SecureProfileStore.migrationMarkerKey),
      SecureProfileStore.migrationMarkerValue,
    );
  });

  test('corrupt persisted content degrades to an empty store', () async {
    FlutterSecureStorage.setMockInitialValues({
      SecureProfileStore.storageKey: '{not-json',
    });
    final store = SecureProfileStore(legacyImporter: _LegacyImporter(null));

    expect(await store.load(), const StoredProfiles());
  });

  test('corrupt legacy content remains available for a future retry', () async {
    final legacy = _LegacyImporter('{not-json');
    const storage = FlutterSecureStorage();
    final store = SecureProfileStore(storage: storage, legacyImporter: legacy);

    expect(await store.load(), const StoredProfiles());
    expect(legacy.calls, 1);
    expect(legacy.clearCalls, 0);
    expect(await storage.read(key: SecureProfileStore.storageKey), isNull);
    expect(
      await storage.read(key: SecureProfileStore.migrationMarkerKey),
      isNull,
    );
  });
}
