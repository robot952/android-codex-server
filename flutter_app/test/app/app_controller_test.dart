import 'dart:async';

import 'package:codex_remote/src/app/app_controller.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/persistence/profile_store.dart';
import 'package:codex_remote/src/ssh/server_connection_manager.dart';
import 'package:codex_remote/src/ssh/ssh_server_client.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryProfileStore implements ProfileStore {
  _MemoryProfileStore(this.value);

  StoredProfiles value;
  final List<StoredProfiles> writes = [];

  @override
  Future<StoredProfiles> load() async => value;

  @override
  Future<void> save(StoredProfiles value) async {
    this.value = value;
    writes.add(value);
  }
}

class _GatedLoadProfileStore extends _MemoryProfileStore {
  _GatedLoadProfileStore() : super(const StoredProfiles());

  final Completer<StoredProfiles> loadResult = Completer<StoredProfiles>();

  @override
  Future<StoredProfiles> load() => loadResult.future;
}

class _BlockingFirstSaveProfileStore extends _MemoryProfileStore {
  _BlockingFirstSaveProfileStore(super.value);

  final Completer<void> firstSaveStarted = Completer<void>();
  final Completer<void> releaseFirstSave = Completer<void>();
  int saveCalls = 0;
  int activeSaves = 0;
  int maximumActiveSaves = 0;

  @override
  Future<void> save(StoredProfiles value) async {
    final call = ++saveCalls;
    activeSaves++;
    maximumActiveSaves = maximumActiveSaves < activeSaves
        ? activeSaves
        : maximumActiveSaves;
    try {
      if (call == 1) {
        firstSaveStarted.complete();
        await releaseFirstSave.future;
      }
      await super.save(value);
    } finally {
      activeSaves--;
    }
  }
}

class _FingerprintClient implements RemoteServerClient {
  final Completer<String> fingerprint = Completer<String>();
  final Completer<void> closed = Completer<void>();
  bool connected = false;

  @override
  Future<void> connect(ServerProfile profile) async {
    connected = true;
  }

  @override
  Future<void> disconnect() async {
    connected = false;
    if (!closed.isCompleted) closed.complete();
  }

  @override
  Future<void> get done => closed.future;

  @override
  bool get isConnected => connected;

  @override
  Future<String> probeFingerprint(ServerProfile profile) => fingerprint.future;

  @override
  SSHClient requireSshClient() => throw UnimplementedError();

  @override
  Future<String> run(
    String command, {
    Duration timeout = const Duration(seconds: 15),
    int maxOutputBytes = 1024 * 1024,
  }) async => '';

  @override
  void close() {
    connected = false;
    if (!closed.isCompleted) closed.complete();
  }
}

const _firstProfile = ServerProfile(
  id: 'first',
  name: 'First',
  host: 'first.example',
  username: 'root',
  authMode: AuthMode.password,
  password: 'secret',
  hostFingerprint: 'SHA256:first',
);

const _secondProfile = ServerProfile(
  id: 'second',
  name: 'Second',
  host: 'second.example',
  username: 'root',
  authMode: AuthMode.password,
  password: 'secret',
  hostFingerprint: 'SHA256:second',
);

void main() {
  test('waits for initialization before applying a profile save', () async {
    final store = _GatedLoadProfileStore();
    final connections = ServerConnectionManager();
    final controller = AppController(store, connections);
    addTearDown(() async {
      controller.dispose();
      await connections.close();
    });

    final pendingSave = controller.saveProfile(_secondProfile);
    await Future<void>.delayed(Duration.zero);
    expect(store.writes, isEmpty);

    store.loadResult.complete(
      const StoredProfiles(
        profiles: [_firstProfile],
        selectedProfileId: 'first',
      ),
    );
    await pendingSave;

    expect(store.value.profiles.map((profile) => profile.id), [
      'first',
      'second',
    ]);
    expect(controller.state.profiles, hasLength(2));
  });

  test('serializes writes so an older snapshot cannot finish last', () async {
    final store = _BlockingFirstSaveProfileStore(const StoredProfiles());
    final connections = ServerConnectionManager();
    final controller = AppController(store, connections);
    addTearDown(() async {
      controller.dispose();
      await connections.close();
    });
    await _waitUntilInitialized(controller);

    final firstSave = controller.saveProfile(_firstProfile);
    await store.firstSaveStarted.future;
    final secondSave = controller.saveProfile(_secondProfile);
    await Future<void>.delayed(Duration.zero);

    expect(store.saveCalls, 1);
    expect(store.maximumActiveSaves, 1);

    store.releaseFirstSave.complete();
    await Future.wait([firstSave, secondSave]);

    expect(store.saveCalls, 2);
    expect(store.maximumActiveSaves, 1);
    expect(store.value.profiles.map((profile) => profile.id), [
      'first',
      'second',
    ]);
  });

  test('deleting a profile removes only its scoped persisted data', () async {
    final store = _MemoryProfileStore(
      StoredProfiles(
        profiles: const [_firstProfile, _secondProfile],
        selectedProfileId: 'first',
        composerDrafts: {
          threadPreferenceKey('first', AgentKind.codex, 'thread'): 'first',
          'first\u0000legacy-thread': 'legacy',
          threadPreferenceKey('second', AgentKind.codex, 'thread'): 'second',
        },
        threadModelPreferences: {
          threadPreferenceKey('first', AgentKind.openCode, 'thread'):
              const ThreadModelPreference(model: 'first-model'),
          threadPreferenceKey('second', AgentKind.openCode, 'thread'):
              const ThreadModelPreference(model: 'second-model'),
        },
        completedTurnTimings: {
          threadPreferenceKey(
            'first',
            AgentKind.codex,
            'thread',
          ): const TurnTiming(
            threadId: 'thread',
            startedAtMillis: 1,
            completedAtMillis: 2,
          ),
          threadPreferenceKey(
            'second',
            AgentKind.codex,
            'thread',
          ): const TurnTiming(
            threadId: 'thread',
            startedAtMillis: 3,
            completedAtMillis: 4,
          ),
        },
      ),
    );
    final connections = ServerConnectionManager();
    final controller = AppController(store, connections);
    addTearDown(() async {
      controller.dispose();
      await connections.close();
    });
    await _waitUntilInitialized(controller);

    await controller.deleteProfile('first');

    expect(store.value.profiles, [_secondProfile]);
    _expectNoProfileData(store.value, 'first');
    expect(
      store.value.composerDrafts.keys.any(
        (key) => key.startsWith('second\u0000'),
      ),
      isTrue,
    );
    expect(
      store.value.threadModelPreferences.keys.any(
        (key) => key.startsWith('second\u0000'),
      ),
      isTrue,
    );
    expect(
      store.value.completedTurnTimings.keys.any(
        (key) => key.startsWith('second\u0000'),
      ),
      isTrue,
    );
  });

  test('connection identity changes clear scoped data atomically', () async {
    final draftKey = threadPreferenceKey('first', AgentKind.codex, 'thread');
    final store = _MemoryProfileStore(
      StoredProfiles(
        profiles: const [_firstProfile],
        selectedProfileId: 'first',
        composerDrafts: {draftKey: 'draft'},
        threadModelPreferences: {
          draftKey: const ThreadModelPreference(model: 'model'),
        },
        completedTurnTimings: {
          draftKey: const TurnTiming(
            threadId: 'thread',
            startedAtMillis: 1,
            completedAtMillis: 2,
          ),
        },
      ),
    );
    final connections = ServerConnectionManager();
    final controller = AppController(store, connections);
    addTearDown(() async {
      controller.dispose();
      await connections.close();
    });
    await _waitUntilInitialized(controller);

    await controller.saveProfile(_firstProfile.copyWith(name: 'Renamed'));
    expect(store.value.composerDrafts[draftKey], 'draft');

    await controller.saveProfile(
      _firstProfile.copyWith(host: 'replacement.example'),
    );

    expect(store.writes.last.profiles.single.host, 'replacement.example');
    expect(store.writes.last.profiles.single.hostFingerprint, isEmpty);
    _expectNoProfileData(store.writes.last, 'first');
  });

  test('fingerprint confirmation keeps newer display-only edits', () async {
    final profile = _firstProfile.copyWith(hostFingerprint: '');
    final store = _MemoryProfileStore(
      StoredProfiles(profiles: [profile], selectedProfileId: profile.id),
    );
    final client = _FingerprintClient();
    final connections = ServerConnectionManager(clientFactory: () => client);
    final controller = AppController(store, connections);
    addTearDown(() async {
      controller.dispose();
      await connections.close();
    });
    await _waitUntilInitialized(controller);

    final pendingConnect = controller.requestConnect(profile);
    await Future<void>.delayed(Duration.zero);
    await controller.saveProfile(profile.copyWith(name: 'Renamed'));
    client.fingerprint.complete('SHA256:verified');
    await pendingConnect;

    expect(controller.state.pendingFingerprint, 'SHA256:verified');
    await controller.confirmFingerprint();

    expect(store.value.profiles.single.name, 'Renamed');
    expect(store.value.profiles.single.hostFingerprint, 'SHA256:verified');
    expect(controller.state.connection.phase, ConnectionPhase.connected);
  });
}

Future<void> _waitUntilInitialized(AppController controller) async {
  while (controller.state.loading) {
    await Future<void>.delayed(Duration.zero);
  }
}

void _expectNoProfileData(StoredProfiles stored, String profileId) {
  final prefix = '$profileId\u0000';
  expect(
    stored.composerDrafts.keys.where((key) => key.startsWith(prefix)),
    isEmpty,
  );
  expect(
    stored.threadModelPreferences.keys.where((key) => key.startsWith(prefix)),
    isEmpty,
  );
  expect(
    stored.completedTurnTimings.keys.where((key) => key.startsWith(prefix)),
    isEmpty,
  );
}
