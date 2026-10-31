import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:codex_remote/src/agent/codex_agent_client.dart';
import 'package:codex_remote/src/agent/remote_agent_client.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/ssh/ssh_server_client.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

const _profile = ServerProfile(
  id: 'timing-server',
  host: 'private-host.invalid',
  username: 'private-user',
  password: 'private-password',
  workspace: '/private/workspace',
  remoteCommand: 'codex app-server --listen stdio://',
);

void main() {
  test(
    'startup stages preserve order, protocol and bounded metadata',
    () async {
      final host = _Host();
      final dedicated = _Host(connected: false);
      final session = _Session();
      final client = CodexAgentClient(
        dedicatedHostFactory: () => dedicated,
        metricsRelayLoader: () async => 'function runRelay(command) {}',
        sessionOpener: (openedHost, command) async {
          expect(openedHost, same(dedicated));
          expect(command, contains('exec "\$metrics_node" -e'));
          return session;
        },
      );
      final logs = _recordTimings(client);
      addTearDown(client.disconnect);

      await client.connect(_profile, host);

      const stages = [
        'agent_previous_disconnect',
        'agent_ssh_connect',
        'agent_metrics_asset',
        'agent_session_open',
        'agent_initialize',
        'agent_provider_settings',
      ];
      expect(logs, hasLength(stages.length * 2));
      for (var index = 0; index < stages.length; index++) {
        final start = logs[index * 2];
        final finish = logs[index * 2 + 1];
        expect(start, contains('stage=${stages[index]} '));
        expect(start, contains('status=started'));
        expect(finish, contains('stage=${stages[index]} '));
        expect(finish, contains('status=success'));
        expect(_field(start, 'operation'), _field(finish, 'operation'));
        expect(_field(start, 'generation'), _field(finish, 'generation'));
      }
      for (final log in logs) {
        expect(log, contains('profile=timing-server agent=codex'));
        expect(int.tryParse(_field(log, 'elapsedMs')), isNonNegative);
        expect(log.length, lessThanOrEqualTo(240));
        expect(log, isNot(contains('private-')));
        expect(log, isNot(contains('/private/workspace')));
        expect(log, isNot(contains('function runRelay')));
        expect(log, isNot(contains('private-provider')));
      }
      expect(client.isConnected, isTrue);
      expect(session.methods, ['initialize', 'initialized']);
      expect(host.connectCalls, 0);
      expect(host.settingsCalls, 1);
      expect(dedicated.connectCalls, 1);
      expect(dedicated.settingsCalls, 0);
      expect(host.settingsTimeout, const Duration(seconds: 30));
    },
  );

  test('dedicated SSH failure retains error and closes failed host', () async {
    final error = StateError('private-connect-error');
    final dedicated = _Host(connected: false, connectError: error);
    final client = CodexAgentClient(
      dedicatedHostFactory: () => dedicated,
      sessionOpener: (_, _) async => throw StateError('unexpected open'),
    );
    final logs = _recordTimings(client);
    addTearDown(client.disconnect);

    await expectLater(client.connect(_profile, _Host()), throwsA(same(error)));

    expect(_stage(logs, 'agent_ssh_connect').last, contains('status=failed'));
    expect(_stage(logs, 'agent_session_open'), isEmpty);
    expect(logs.join('\n'), isNot(contains('private-connect-error')));
    expect(dedicated.closeCalls, 1);
    expect(client.isConnected, isFalse);
  });

  test('session open failure preserves dedicated-host cleanup', () async {
    final error = StateError('private-session-error');
    final dedicated = _Host(connected: false);
    final client = CodexAgentClient(
      dedicatedHostFactory: () => dedicated,
      sessionOpener: (_, _) async => throw error,
    );
    final logs = _recordTimings(client);
    addTearDown(client.disconnect);

    await expectLater(client.connect(_profile, _Host()), throwsA(same(error)));

    expect(_stage(logs, 'agent_session_open').last, contains('status=failed'));
    expect(_stage(logs, 'agent_initialize'), isEmpty);
    expect(logs.join('\n'), isNot(contains('private-session-error')));
    expect(dedicated.disconnectCalls, 1);
    expect(client.currentGeneration, isNull);
  });

  test(
    'optional metrics failure is timed without blocking connection',
    () async {
      final session = _Session();
      String? launch;
      final client = CodexAgentClient(
        metricsRelayLoader: () async => throw StateError('private-asset-error'),
        sessionOpener: (_, command) async {
          launch = command;
          return session;
        },
      );
      final logs = _recordTimings(client);
      addTearDown(client.disconnect);

      await client.connect(_profile, _Host());

      expect(
        _stage(logs, 'agent_metrics_asset').last,
        contains('status=failed'),
      );
      expect(_stage(logs, 'agent_initialize').last, contains('status=success'));
      expect(logs.join('\n'), isNot(contains('private-asset-error')));
      expect(launch, isNot(contains('exec "\$metrics_node" -e')));
      expect(client.isConnected, isTrue);
    },
  );

  test('initialize timeout is recorded and still disconnects', () async {
    final session = _Session(replyToInitialize: false);
    final dedicated = _Host(connected: false);
    final client = CodexAgentClient(
      requestTimeout: const Duration(milliseconds: 20),
      dedicatedHostFactory: () => dedicated,
      sessionOpener: (_, _) async => session,
    );
    final logs = _recordTimings(client);
    addTearDown(client.disconnect);
    await expectLater(
      client.connect(_profile, _Host()),
      throwsA(isA<TimeoutException>()),
    );

    expect(_stage(logs, 'agent_initialize').last, contains('status=timeout'));
    expect(_stage(logs, 'agent_provider_settings'), isEmpty);
    expect(session.terminated, isTrue);
    expect(dedicated.disconnectCalls, 1);
    expect(client.isConnected, isFalse);
  });

  test('provider timeout is recorded despite best-effort fallback', () async {
    final settingsGate = Completer<String>();
    final host = _Host(settingsGate: settingsGate);
    final session = _Session();
    final client = CodexAgentClient(sessionOpener: (_, _) async => session);
    final logs = _recordTimings(client);
    addTearDown(client.disconnect);
    await client.connect(_profile, host);

    expect(
      _stage(logs, 'agent_provider_settings').last,
      contains('status=timeout'),
    );
    expect(client.isConnected, isTrue);
    expect(session.terminated, isFalse);
    settingsGate.complete('MODEL_PROVIDER=private-provider');
    await Future<void>.delayed(Duration.zero);
    expect(_stage(logs, 'agent_provider_settings'), hasLength(2));
  });

  test(
    'provider error is recorded without changing connection success',
    () async {
      final session = _Session();
      final client = CodexAgentClient(sessionOpener: (_, _) async => session);
      final logs = _recordTimings(client);
      addTearDown(client.disconnect);

      await client.connect(
        _profile,
        _Host(settingsError: StateError('private-settings-error')),
      );

      expect(
        _stage(logs, 'agent_provider_settings').last,
        contains('status=failed'),
      );
      expect(logs.join('\n'), isNot(contains('private-settings-error')));
      expect(client.isConnected, isTrue);
    },
  );
}

List<String> _recordTimings(CodexAgentClient client) {
  final logs = <String>[];
  final subscription = client.events.listen((event) {
    if (event is RemoteAgentDiagnostic && event.message.startsWith('timing ')) {
      expectSync(event.isTransport, isTrue);
      logs.add(event.message);
    }
  });
  addTearDown(subscription.cancel);
  return logs;
}

List<String> _stage(List<String> logs, String stage) =>
    logs.where((line) => line.contains('stage=$stage ')).toList();

String _field(String line, String field) =>
    RegExp('(?:^| )$field=([^ ]+)').firstMatch(line)!.group(1)!;

class _Host implements RemoteServerClient, RemoteServerScriptClient {
  _Host({
    this.connected = true,
    this.connectError,
    this.settingsError,
    this.settingsGate,
  });

  bool connected;
  final Object? connectError;
  final Object? settingsError;
  final Completer<String>? settingsGate;
  final closed = Completer<void>();
  int connectCalls = 0;
  int disconnectCalls = 0;
  int closeCalls = 0;
  int settingsCalls = 0;
  Duration? settingsTimeout;

  @override
  Future<void> connect(ServerProfile profile) async {
    connectCalls++;
    if (connectError case final error?) throw error;
    connected = true;
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    connected = false;
    if (!closed.isCompleted) closed.complete();
  }

  @override
  Future<void> get done => closed.future;

  @override
  bool get isConnected => connected;

  @override
  void close() {
    closeCalls++;
    connected = false;
    if (!closed.isCompleted) closed.complete();
  }

  @override
  Future<String> runShellScript(
    String script, {
    Duration timeout = const Duration(seconds: 15),
    int maxOutputBytes = 1024 * 1024,
  }) async {
    settingsCalls++;
    settingsTimeout = timeout;
    if (settingsError case final error?) throw error;
    return settingsGate?.future ?? 'MODEL_PROVIDER=private-provider';
  }

  @override
  Future<String> run(
    String command, {
    Duration timeout = const Duration(seconds: 15),
    int maxOutputBytes = 1024 * 1024,
  }) => throw UnsupportedError('not used');

  @override
  Future<String> probeFingerprint(ServerProfile profile) =>
      throw UnsupportedError('not used');

  @override
  Future<ServerMetrics> readServerMetrics(ServerProfile profile) =>
      throw UnsupportedError('not used');

  @override
  SSHClient requireSshClient() => throw UnsupportedError('not used');
}

class _Session implements CodexSession {
  _Session({this.replyToInitialize = true});

  final bool replyToInitialize;
  final output = StreamController<Uint8List>(sync: true);
  final errors = StreamController<Uint8List>(sync: true);
  final closed = Completer<void>();
  final methods = <String>[];
  bool terminated = false;

  @override
  Stream<Uint8List> get stdout => output.stream;

  @override
  Stream<Uint8List> get stderr => errors.stream;

  @override
  Future<void> get done => closed.future;

  @override
  void write(Uint8List data) {
    final request = jsonDecode(utf8.decode(data)) as Map<String, Object?>;
    methods.add(request['method']! as String);
    if (request['method'] == 'initialize' && replyToInitialize) {
      scheduleMicrotask(() {
        output.add(
          Uint8List.fromList(
            utf8.encode('${jsonEncode({'id': request['id'], 'result': {}})}\n'),
          ),
        );
      });
    }
  }

  @override
  void terminate() {
    terminated = true;
    if (!closed.isCompleted) closed.complete();
    unawaited(output.close());
    unawaited(errors.close());
  }
}
