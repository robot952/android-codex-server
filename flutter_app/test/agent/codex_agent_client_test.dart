import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:codex_remote/src/agent/codex_agent_client.dart';
import 'package:codex_remote/src/agent/codex_protocol.dart';
import 'package:codex_remote/src/agent/opencode_agent_client.dart';
import 'package:codex_remote/src/agent/remote_agent_client.dart';
import 'package:codex_remote/src/domain/model_catalog.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/ssh/ssh_server_client.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeCodexHost
    implements RemoteServerClient, RemoteServerKeepAliveClient {
  _FakeCodexHost({this.connected = true, this.keepAliveGate});

  bool connected;
  final Completer<void>? keepAliveGate;
  final Completer<void> closed = Completer<void>();
  int connectCount = 0;
  int disconnectCount = 0;
  int closeCount = 0;
  int runCount = 0;
  int keepAliveCount = 0;

  @override
  Future<void> connect(ServerProfile profile) async {
    connectCount++;
    connected = true;
  }

  @override
  Future<void> disconnect() async {
    disconnectCount++;
    connected = false;
    if (!closed.isCompleted) closed.complete();
  }

  @override
  Future<void> get done => closed.future;

  @override
  bool get isConnected => connected;

  @override
  Future<void> keepAlive() async {
    keepAliveCount++;
    await keepAliveGate?.future;
  }

  @override
  Future<ServerMetrics> readServerMetrics(ServerProfile profile) {
    throw UnimplementedError();
  }

  @override
  SSHClient requireSshClient() => throw UnimplementedError();

  @override
  Future<String> probeFingerprint(ServerProfile profile) {
    throw UnimplementedError();
  }

  @override
  Future<String> run(
    String command, {
    Duration timeout = const Duration(seconds: 15),
    int maxOutputBytes = 1024 * 1024,
  }) {
    runCount++;
    throw UnimplementedError();
  }

  @override
  void close() {
    closeCount++;
    connected = false;
    if (!closed.isCompleted) closed.complete();
  }

  void fail(Object error) {
    connected = false;
    if (!closed.isCompleted) closed.completeError(error);
  }
}

class _FakeCodexSession implements CodexSession, RemoteServerProcessSession {
  _FakeCodexSession({
    this.models = const [],
    this.results = const {},
    this.replyFor,
  });

  final List<Map<String, Object?>> models;
  final Map<String, Object?> results;
  final Map<String, Object?> Function(Map<String, Object?> request)? replyFor;
  final StreamController<Uint8List> _stdout = StreamController<Uint8List>(
    sync: true,
  );
  final StreamController<Uint8List> _stderr = StreamController<Uint8List>(
    sync: true,
  );
  final List<String> writes = <String>[];
  final Completer<void> _done = Completer<void>();
  int flushCount = 0;
  bool terminated = false;

  @override
  Stream<Uint8List> get stdout => _stdout.stream;

  @override
  Stream<Uint8List> get stderr => _stderr.stream;

  @override
  Future<void> get done => _done.future;

  @override
  void write(Uint8List data) {
    final line = utf8.decode(data);
    writes.add(line);
    final payload = jsonDecode(line) as Map<String, Object?>;
    final id = payload['id'];
    if (id == null) return;
    final result = payload['method'] == 'model/list'
        ? <String, Object?>{
            'data': models
                .where(
                  (model) =>
                      (payload['params'] as Map?)?['includeHidden'] == true ||
                      model['hidden'] != true,
                )
                .toList(),
            'nextCursor': null,
          }
        : results[payload['method']] ?? <String, Object?>{};
    scheduleMicrotask(() {
      if (!_stdout.isClosed) {
        _stdout.add(
          Uint8List.fromList(
            utf8.encode(
              '${jsonEncode(<String, Object?>{'id': id, ...?replyFor?.call(payload), if (replyFor == null) 'result': result})}\n',
            ),
          ),
        );
      }
    });
  }

  @override
  void terminate() {
    terminated = true;
    if (!_done.isCompleted) _done.complete();
    unawaited(_stdout.close());
    unawaited(_stderr.close());
  }
}

class _FakeLocalCodexHost extends _FakeCodexHost
    implements LocalRemoteServerClient, RemoteServerCodexProcessClient {
  _FakeLocalCodexHost(this.session);

  final RemoteServerProcessSession session;
  int openCount = 0;

  @override
  Future<RemoteServerProcessSession> openCodexAppServer() async {
    openCount++;
    return session;
  }
}

class _FakeLocalOpenCodeHost extends _FakeCodexHost
    implements LocalRemoteServerClient, RemoteServerAgentProcessClient {
  _FakeLocalOpenCodeHost(this.session);

  final RemoteServerProcessSession session;
  int openCount = 0;
  AgentKind? openedAgent;

  @override
  Future<RemoteServerProcessSession> openAgentAppServer(AgentKind agent) async {
    openCount++;
    openedAgent = agent;
    return session;
  }
}

class _FakeSshSocket implements SSHSocket {
  final StreamController<Uint8List> _incoming = StreamController<Uint8List>(
    sync: true,
  );
  final StreamController<List<int>> _outgoing = StreamController<List<int>>(
    sync: true,
  );
  final Completer<void> _done = Completer<void>();
  final List<Uint8List> writes = <Uint8List>[];

  _FakeSshSocket() {
    _outgoing.stream.listen((bytes) => writes.add(Uint8List.fromList(bytes)));
  }

  @override
  Stream<Uint8List> get stream => _incoming.stream;

  @override
  StreamSink<List<int>> get sink => _outgoing.sink;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() async => destroy();

  @override
  void destroy() {
    if (!_done.isCompleted) _done.complete();
    unawaited(_incoming.close());
    unawaited(_outgoing.close());
  }

  @override
  Future<void> flush() async {}

  void add(List<int> bytes) => _incoming.add(Uint8List.fromList(bytes));
}

void main() {
  test(
    'writer collision reads bounded history and retry reacquires input',
    () async {
      var occupied = true;
      final session = _FakeCodexSession(
        replyFor: (request) {
          switch (request['method']) {
            case 'thread/resume':
              return occupied
                  ? {
                      'error': {
                        'code': -32600,
                        'message': 'thread root already has an active writer',
                      },
                    }
                  : {
                      'result': {
                        'thread': {
                          'id': 'root',
                          'status': {'type': 'idle'},
                        },
                      },
                    };
            case 'thread/read':
              return {
                'result': {
                  'thread': {
                    'id': 'root',
                    'status': {'type': 'notLoaded'},
                  },
                },
              };
            case 'thread/turns/list':
              return {
                'result': {
                  'data': [
                    {
                      'id': 'root-turn',
                      'items': [
                        {
                          'id': 'answer',
                          'type': 'agentMessage',
                          'text': 'Existing conversation',
                        },
                      ],
                      'status': 'completed',
                    },
                  ],
                  'nextCursor': 'older',
                },
              };
            default:
              return {'result': <String, Object?>{}};
          }
        },
      );
      final client = CodexAgentClient(sessionOpener: (_, _) async => session);
      addTearDown(() async {
        await client.disconnect();
        client.close();
      });
      await client.connect(
        const ServerProfile(id: 'server', remoteCommand: 'codex app-server'),
        _FakeCodexHost(),
      );
      final readOnly = await client.resumeThread('root');
      expect(readOnly.thread.isExternallyOwned, isTrue);
      expect(readOnly.timeline.single.text, 'Existing conversation');
      expect(readOnly.nextTurnsCursor, 'older');
      final requests = session.writes
          .map(jsonDecode)
          .where(
            (x) =>
                x['method'] == 'thread/resume' ||
                x['method'] == 'thread/read' ||
                x['method'] == 'thread/turns/list',
          )
          .toList();
      expect(requests.map((x) => x['method']), [
        'thread/resume',
        'thread/read',
        'thread/turns/list',
      ]);
      expect(requests[1]['params'], {
        'threadId': 'root',
        'includeTurns': false,
      });
      expect(requests[2]['params'], {
        'threadId': 'root',
        'limit': 4,
        'sortDirection': 'desc',
        'itemsView': 'full',
      });
      occupied = false;
      final resumed = await client.resumeThread('root');
      expect(resumed.thread.isExternallyOwned, isFalse);
    },
  );

  test(
    'writer collision survives a read failure as a typed ownership error',
    () async {
      final session = _FakeCodexSession(
        replyFor: (request) => switch (request['method']) {
          'thread/resume' => {
            'error': {
              'code': -32600,
              'message': 'thread root already has an active writer',
            },
          },
          'thread/read' => {
            'error': {'code': -32603, 'message': 'history unavailable'},
          },
          _ => {'result': <String, Object?>{}},
        },
      );
      final client = CodexAgentClient(sessionOpener: (_, _) async => session);
      addTearDown(() async {
        await client.disconnect();
        client.close();
      });
      await client.connect(
        const ServerProfile(id: 'server', remoteCommand: 'codex app-server'),
        _FakeCodexHost(),
      );
      await expectLater(
        client.resumeThread('root'),
        throwsA(
          isA<CodexThreadOwnedException>()
              .having((x) => x.threadId, 'thread', 'root')
              .having(
                (x) => isCodexThreadOwnershipError(x, threadId: 'root'),
                'ownership retained',
                isTrue,
              )
              .having(
                (x) => x.readError,
                'underlying read error',
                isA<CodexRpcException>(),
              ),
        ),
      );
    },
  );

  test(
    'unrelated resume failures do not switch to read-only history',
    () async {
      final session = _FakeCodexSession(
        replyFor: (request) => request['method'] == 'thread/resume'
            ? {
                'error': {'code': -32600, 'message': 'thread root not found'},
              }
            : {'result': <String, Object?>{}},
      );
      final client = CodexAgentClient(sessionOpener: (_, _) async => session);
      addTearDown(() async {
        await client.disconnect();
        client.close();
      });
      await client.connect(
        const ServerProfile(id: 'server', remoteCommand: 'codex app-server'),
        _FakeCodexHost(),
      );
      await expectLater(
        client.resumeThread('root'),
        throwsA(isA<CodexRpcException>()),
      );
      expect(
        session.writes.map(jsonDecode).any((x) => x['method'] == 'thread/read'),
        isFalse,
      );
    },
  );

  test(
    'reads an unloaded real child snapshot without resuming parent or child',
    () async {
      final fixture =
          jsonDecode(
                File(
                  'test/fixtures/subagent_child_history_live.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final snapshots = fixture['snapshots'] as List;
      final payload = snapshots.last['response'] as Map<String, dynamic>;
      final thread = payload['thread'] as Map<String, dynamic>;
      final session = _FakeCodexSession(
        results: {
          'thread/read': payload,
          'thread/turns/list': {
            'data': (thread['turns'] as List).reversed.toList(),
          },
        },
      );
      final client = CodexAgentClient(sessionOpener: (_, _) async => session);
      addTearDown(() async {
        await client.disconnect();
        client.close();
      });
      await client.connect(
        const ServerProfile(id: 'server', remoteCommand: 'codex app-server'),
        _FakeCodexHost(),
      );
      final result = await client.readThread(thread['id'] as String);
      expect(result.thread.id, thread['id']);
      expect(result.thread.source, 'subAgent');
      expect(result.timeline, isNotEmpty);
      final reads = session.writes
          .map(jsonDecode)
          .where((x) => x['method'] == 'thread/read');
      expect(reads.first['params'], {
        'threadId': thread['id'],
        'includeTurns': false,
      });
      expect(
        session.writes
            .map(jsonDecode)
            .any((x) => x['method'] == 'thread/resume'),
        isFalse,
      );
      expect(
        session.writes
            .map(jsonDecode)
            .any((x) => (x['params'] as Map?)?.containsKey('config') == true),
        isFalse,
      );
    },
  );

  test(
    'read-only history bounds oversized pages through all four views',
    () async {
      final session = _FakeCodexSession(
        replyFor: (request) {
          if (request['method'] == 'thread/read') {
            return {
              'result': {
                'thread': {'id': 'child', 'parentThreadId': 'parent'},
              },
            };
          }
          if (request['method'] == 'thread/turns/list') {
            final params = request['params'] as Map;
            return {
              'result': params['itemsView'] == 'notLoaded'
                  ? {
                      'data': [
                        {'id': 'child-turn', 'items': []},
                      ],
                      'nextCursor': 'older',
                    }
                  : {'padding': 'x' * 2048},
            };
          }
          return {'result': <String, Object?>{}};
        },
      );
      final client = CodexAgentClient(
        sessionOpener: (_, _) async => session,
        maxLineChars: 1024,
      );
      addTearDown(() async {
        await client.disconnect();
        client.close();
      });
      await client.connect(
        const ServerProfile(id: 'server', remoteCommand: 'codex app-server'),
        _FakeCodexHost(),
      );
      final result = await client.readThread('child');
      expect(result.itemsView, 'notLoaded');
      expect(result.turnIds, ['child-turn']);
      expect(result.nextTurnsCursor, 'older');
      final pages = session.writes
          .map(jsonDecode)
          .where((x) => x['method'] == 'thread/turns/list')
          .toList();
      expect(pages.map((x) => (x['params'] as Map)['limit']), [4, 1, 1, 1]);
      expect(pages.map((x) => (x['params'] as Map)['itemsView']), [
        'full',
        'full',
        'summary',
        'notLoaded',
      ]);
      expect(
        session.writes
            .map(jsonDecode)
            .any((x) => x['method'] == 'thread/resume'),
        isFalse,
      );
    },
  );

  test(
    'unsupported read endpoint never falls back to resuming a child',
    () async {
      final session = _FakeCodexSession(
        replyFor: (request) => request['method'] == 'thread/read'
            ? {
                'error': {'code': -32601, 'message': 'unsupported'},
              }
            : {'result': <String, Object?>{}},
      );
      final client = CodexAgentClient(sessionOpener: (_, _) async => session);
      addTearDown(() async {
        await client.disconnect();
        client.close();
      });
      await client.connect(
        const ServerProfile(id: 'server', remoteCommand: 'codex app-server'),
        _FakeCodexHost(),
      );
      await expectLater(client.readThread('child'), throwsA(isA<Exception>()));
      expect(
        session.writes
            .map(jsonDecode)
            .any((x) => x['method'] == 'thread/resume'),
        isFalse,
      );
    },
  );

  test('legacy read endpoint is used when pagination is unavailable', () async {
    final session = _FakeCodexSession(
      replyFor: (request) {
        if (request['method'] == 'thread/turns/list') {
          return {
            'error': {'code': -32601, 'message': 'unsupported'},
          };
        }
        if (request['method'] == 'thread/read') {
          final includeTurns =
              (request['params'] as Map)['includeTurns'] == true;
          return {
            'result': {
              'thread': {
                'id': 'child',
                'parentThreadId': 'parent',
                'turns': includeTurns
                    ? [
                        {
                          'id': 'child-turn',
                          'items': [
                            {
                              'id': 'child-item',
                              'type': 'agentMessage',
                              'text': 'child',
                            },
                          ],
                        },
                      ]
                    : [],
              },
            },
          };
        }
        return {'result': <String, Object?>{}};
      },
    );
    final client = CodexAgentClient(sessionOpener: (_, _) async => session);
    addTearDown(() async {
      await client.disconnect();
      client.close();
    });
    await client.connect(
      const ServerProfile(id: 'server', remoteCommand: 'codex app-server'),
      _FakeCodexHost(),
    );
    final result = await client.readThread('child');
    expect(result.timeline.map((item) => item.text), ['child']);
    expect(
      session.writes.map(jsonDecode).any((x) => x['method'] == 'thread/resume'),
      isFalse,
    );
  });

  test(
    'child pagination keeps the verified history boundary from resume',
    () async {
      const childId = '01a0b573-91cc-7ad3-ad41-72bd0b489c52';
      const childTurnId = '01a0b573-91f2-7523-b25d-4fd4bc1fdc8e';
      const parentTurnId = '01a0b573-9000-7c51-a2e0-4389f0c8c6b2';
      Map<String, Object?> turn(String id, String text) => {
        'id': id,
        'items': [
          {'id': '$text-item', 'type': 'agentMessage', 'text': text},
        ],
      };
      final session = _FakeCodexSession(
        results: {
          'thread/resume': {
            'thread': {
              'id': childId,
              'source': 'vscode',
              'parentThreadId': 'parent',
              'createdAt': 1789750645,
              'turns': [turn(childTurnId, 'child')],
            },
          },
          'thread/turns/list': {
            'nextCursor': 'older',
            'data': [turn(childTurnId, 'child'), turn(parentTurnId, 'parent')],
          },
        },
      );
      final client = CodexAgentClient(sessionOpener: (_, _) async => session);
      addTearDown(() async {
        await client.disconnect();
        client.close();
      });
      await client.connect(
        const ServerProfile(id: 'server', remoteCommand: 'codex app-server'),
        _FakeCodexHost(),
      );
      await client.resumeThread(childId);
      final page = await client.loadOlderTurns(
        threadId: childId,
        cursor: 'first',
      );
      expect(page.timeline.map((entry) => entry.text), ['child']);
      expect(page.nextCursor, isNull);
      final ordinaryPage = await client.loadOlderTurns(
        threadId: 'ordinary-thread',
        cursor: 'first',
      );
      expect(ordinaryPage.timeline.map((entry) => entry.text), [
        'parent',
        'child',
      ]);
      expect(ordinaryPage.nextCursor, 'older');
    },
  );

  test(
    'lists all server-hidden models and preserves custom model efforts',
    () async {
      final session = _FakeCodexSession(
        models: [
          {
            'id': 'gpt-6-astra',
            'model': 'gpt-6-astra',
            'displayName': 'GPT-6-Astra',
            'hidden': true,
            'defaultReasoningEffort': 'medium',
            'supportedReasoningEfforts': [
              {'reasoningEffort': 'low'},
              {'reasoningEffort': 'medium'},
              {'reasoningEffort': 'high'},
              {'reasoningEffort': 'xhigh'},
              {'reasoningEffort': 'max'},
              {'reasoningEffort': 'ultra'},
            ],
          },
          {
            'id': 'another-hidden-model',
            'hidden': true,
            'supportedReasoningEfforts': [
              {'reasoningEffort': 'low'},
              {'reasoningEffort': 'high'},
            ],
          },
          {'id': 'visible-model', 'hidden': false, 'isDefault': true},
          {'id': 'legacy-model'},
        ],
      );
      final client = CodexAgentClient(sessionOpener: (_, _) async => session);
      addTearDown(client.close);
      await client.connect(
        const ServerProfile(id: 'server', remoteCommand: 'codex app-server'),
        _FakeCodexHost(),
      );

      final models = await client.listModels();
      expect(models.map((model) => model.model), [
        'gpt-6-astra',
        'another-hidden-model',
        'visible-model',
        'legacy-model',
      ]);
      expect(models[1].efforts, ['low', 'high']);
      expect(models[2].isDefault, isTrue);
      expect(models[2].efforts, isEmpty);

      final catalog = buildModelCatalog(
        models,
        const [
          CustomModelDefinition(
            modelId: 'gpt-6-astra',
            displayName: 'My Astra',
          ),
        ],
        const ['another-hidden-model'],
      );
      expect(catalog.map((model) => model.model), [
        'gpt-6-astra',
        'visible-model',
        'legacy-model',
      ]);
      expect(catalog.first.displayName, 'My Astra');
      expect(catalog.first.defaultEffort, 'medium');
      expect(catalog.first.efforts, [
        'low',
        'medium',
        'high',
        'xhigh',
        'max',
        'ultra',
      ]);
      expect(catalog.first.isCustom, isTrue);
      await client.disconnect();
    },
  );

  test('builds the app-server command with env and a quoted workspace', () {
    const profile = ServerProfile(
      id: 'server',
      workspace: "/srv/team's app",
      remoteCommand: '~/.local/bin/codex-remote app-server --listen stdio://',
    );

    final command = buildCodexAppServerCommand(profile);

    expect(command, contains(r'. "$HOME/.codex/codex-remote.env"'));
    expect(
      command,
      endsWith('exec ~/.local/bin/codex-remote app-server --listen stdio://'),
    );
  });

  test('rejects an empty remote command', () {
    expect(
      () => buildCodexAppServerCommand(
        const ServerProfile(id: 'server', remoteCommand: '  '),
      ),
      throwsStateError,
    );
  });

  test('keeps legacy stdio as the default Agent transport', () async {
    final host = _FakeCodexHost();
    final client = CodexAgentClient();
    const profile = ServerProfile(
      id: 'server',
      host: 'example.com',
      username: 'root',
      hostFingerprint: 'SHA256:verified',
      remoteCommand: 'codex app-server --listen stdio://',
    );

    expect(client.useDurableTransport, isFalse);
    await expectLater(client.connect(profile, host), throwsA(anything));
    expect(host.runCount, 0);
    client.close();
  });

  test('builds a stable detached Unix-socket app-server command', () async {
    const profile = ServerProfile(
      id: 'server',
      workspace: "/srv/team's app",
      remoteCommand: 'codex app-server --listen stdio://',
    );

    final first = buildDurableCodexAppServerCommands(profile);
    final second = buildDurableCodexAppServerCommands(profile);

    expect(first.key, hasLength(24));
    expect(first.key, second.key);
    expect(first.startCommand, startsWith("sh -c '"));
    expect(first.startCommand, contains('nohup'));
    expect(first.startCommand, contains('setsid'));
    expect(first.startCommand, contains(r'CODEX_REMOTE_SOCKET'));
    expect(first.startCommand, isNot(contains('stdio://')));
    expect(first.stopCommand, contains('kill -9'));
    final syntax = await Process.run('sh', <String>[
      '-n',
      '-c',
      first.startCommand,
    ]);
    expect(syntax.exitCode, 0, reason: syntax.stderr.toString());
    expect(supportsDurableCodexAppServer(profile.remoteCommand), isTrue);
    expect(supportsDurableCodexAppServer('bridge --listen stdio://'), isFalse);
  });

  test(
    'force takeover cleanup script has valid shell syntax and narrow markers',
    () async {
      final script = buildCodexForceTakeoverScript();
      expect(script, contains('CODEX_TAKEOVER|terminated|'));
      expect(script, contains('opencode'));
      expect(script, contains('app-server'));
      final directory = await Directory.systemTemp.createTemp(
        'codex-force-takeover-test-',
      );
      final file = File('${directory.path}/takeover.sh');
      try {
        await file.writeAsString(script);
        final syntax = await Process.run('sh', <String>['-n', file.path]);
        expect(syntax.exitCode, 0, reason: syntax.stderr.toString());
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test('bridges JSONL over a masked WebSocket text frame', () async {
    const key = 'dGhlIHNhbXBsZSBub25jZQ==';
    final socket = _FakeSshSocket();
    final opening = openCodexWebSocketSession(socket, webSocketKey: key);
    await Future<void>.delayed(Duration.zero);

    expect(ascii.decode(socket.writes.single), contains('GET / HTTP/1.1'));
    socket.add(
      ascii.encode(
        'HTTP/1.1 101 Switching Protocols\r\n'
        'Upgrade: websocket\r\n'
        'Connection: Upgrade\r\n'
        'Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n'
        '\r\n',
      ),
    );
    final session = await opening;

    session.write(Uint8List.fromList(utf8.encode('{"id":1}\n')));
    final frame = socket.writes.last;
    expect(frame[0], 0x81);
    expect(frame[1] & 0x80, 0x80, reason: 'client frames must be masked');
    final payloadLength = frame[1] & 0x7f;
    final mask = frame.sublist(2, 6);
    final decoded = List<int>.generate(
      payloadLength,
      (index) => frame[6 + index] ^ mask[index % 4],
    );
    expect(utf8.decode(decoded), '{"id":1}');

    final response = utf8.encode('{"id":1,"result":{}}');
    final stdout = session.stdout.first;
    socket.add(<int>[0x81, response.length, ...response]);
    expect(utf8.decode(await stdout), '{"id":1,"result":{}}\n');

    session.terminate();
    await session.done;
  });

  test('writes JSONL without flushing the shared SSH socket', () async {
    final session = _FakeCodexSession();
    final client = CodexAgentClient(sessionOpener: (_, _) async => session);
    const profile = ServerProfile(
      id: 'server',
      host: 'example.com',
      username: 'root',
      hostFingerprint: 'SHA256:verified',
      remoteCommand: 'codex app-server --listen stdio://',
    );

    await client.connect(profile, _FakeCodexHost());
    await client.disconnect();

    expect(session.writes.length, 2);
    expect(session.flushCount, 0);
    expect(session.terminated, isTrue);
  });

  test('keeps the Agent on a dedicated SSH transport', () async {
    final session = _FakeCodexSession();
    final host = _FakeCodexHost();
    final dedicatedHost = _FakeCodexHost(connected: false);
    RemoteServerClient? openedHost;
    final client = CodexAgentClient(
      dedicatedHostFactory: () => dedicatedHost,
      sessionOpener: (sessionHost, _) async {
        openedHost = sessionHost;
        return session;
      },
    );
    const profile = ServerProfile(
      id: 'server',
      host: 'example.com',
      username: 'root',
      hostFingerprint: 'SHA256:verified',
      remoteCommand: 'codex app-server --listen stdio://',
    );

    await client.connect(profile, host);
    await client.keepAlive();

    expect(openedHost, same(dedicatedHost));
    expect(dedicatedHost.connectCount, 1);
    expect(dedicatedHost.keepAliveCount, 1);
    expect(host.connectCount, 0);
    expect(host.keepAliveCount, 0);

    await client.disconnect();

    expect(session.terminated, isTrue);
    expect(dedicatedHost.disconnectCount, 1);
    expect(host.disconnectCount, 0);
  });

  test('reuses JSONL protocol over a native Host process session', () async {
    final session = _FakeCodexSession();
    final host = _FakeLocalCodexHost(session);
    final dedicatedHost = _FakeCodexHost(connected: false);
    final client = CodexAgentClient(dedicatedHostFactory: () => dedicatedHost);
    const profile = ServerProfile(
      id: 'agent-local-windows',
      host: 'local-windows',
      port: 1,
      username: 'local',
      hostFingerprint: 'local-windows',
    );

    await client.connect(profile, host);

    expect(host.openCount, 1);
    expect(dedicatedHost.connectCount, 0);
    expect(client.usesIndependentConnection, isFalse);
    expect(session.writes, hasLength(2));
    expect(
      jsonDecode(session.writes.first),
      containsPair('method', 'initialize'),
    );
    expect(
      jsonDecode(session.writes.last),
      containsPair('method', 'initialized'),
    );

    await client.disconnect();
    expect(session.terminated, isTrue);
  });

  test(
    'OpenCode selects the native OpenCode process on a local Host',
    () async {
      final session = _FakeCodexSession();
      final host = _FakeLocalOpenCodeHost(session);
      final client = OpenCodeAgentClient(bridgeLoader: () async => 'bridge');
      const profile = ServerProfile(
        id: 'agent-local-windows',
        host: 'local-windows',
        port: 1,
        username: 'local',
        hostFingerprint: 'local-windows',
      );

      await client.connect(profile, host);

      expect(host.openCount, 1);
      expect(host.openedAgent, AgentKind.openCode);
      expect(session.writes, hasLength(2));

      await client.disconnect();
      client.close();
    },
  );

  test(
    'coalesces Agent heartbeats while the previous ping is pending',
    () async {
      final session = _FakeCodexSession();
      final gate = Completer<void>();
      final dedicatedHost = _FakeCodexHost(
        connected: false,
        keepAliveGate: gate,
      );
      final client = CodexAgentClient(
        dedicatedHostFactory: () => dedicatedHost,
        sessionOpener: (_, _) async => session,
      );
      const profile = ServerProfile(
        id: 'server',
        host: 'example.com',
        username: 'root',
        hostFingerprint: 'SHA256:verified',
        remoteCommand: 'codex app-server --listen stdio://',
      );

      await client.connect(profile, _FakeCodexHost());
      final first = client.keepAlive();
      final second = client.keepAlive();
      await Future<void>.delayed(Duration.zero);

      expect(dedicatedHost.keepAliveCount, 1);
      gate.complete();
      await Future.wait<void>([first, second]);
      expect(dedicatedHost.keepAliveCount, 1);

      await client.disconnect();
    },
  );

  test('sanitizes ANSI control sequences from Agent diagnostics', () {
    expect(
      sanitizeAgentDiagnostic(
        '\u001b[2m2026-08-10T10:45:20Z\u001b[0m '
        '\u001b[31mERROR\u001b[0m codex_app_server',
      ),
      '2026-08-10T10:45:20Z ERROR codex_app_server',
    );
  });

  test('retains provider fallback detail without closing the Agent', () async {
    final session = _FakeCodexSession();
    final client = CodexAgentClient(sessionOpener: (_, _) async => session);
    final events = <RemoteAgentEvent>[];
    final subscription = client.events.listen(events.add);
    addTearDown(subscription.cancel);
    addTearDown(client.disconnect);
    await client.connect(
      const ServerProfile(id: 'server', remoteCommand: 'codex app-server'),
      _FakeCodexHost(),
    );
    const warning =
        'Falling back from WebSockets to HTTPS transport. '
        'websocket closed by server before response.completed';
    session._stdout.add(
      Uint8List.fromList(
        utf8.encode(
          '${jsonEncode({
            'method': 'warning',
            'params': {'threadId': 'thread-1', 'message': warning},
          })}\n',
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(events.whereType<RemoteAgentDiagnostic>().last.message, warning);
    expect(events.whereType<RemoteAgentDiagnostic>().last.isStderr, isTrue);
    expect(session.terminated, isFalse);
    expect(
      events.whereType<RemoteAgentNotification>().last.message.method,
      'warning',
    );
  });

  test('reports the dedicated SSH transport close reason', () async {
    final session = _FakeCodexSession();
    final dedicatedHost = _FakeCodexHost(connected: false);
    final client = CodexAgentClient(
      dedicatedHostFactory: () => dedicatedHost,
      sessionOpener: (_, _) async => session,
    );
    const profile = ServerProfile(
      id: 'server',
      host: 'example.com',
      username: 'root',
      hostFingerprint: 'SHA256:verified',
      remoteCommand: 'codex app-server --listen stdio://',
    );

    await client.connect(profile, _FakeCodexHost());
    final diagnostic = client.events
        .where((event) => event is RemoteAgentDiagnostic)
        .cast<RemoteAgentDiagnostic>()
        .firstWhere((event) => event.isTransport);
    dedicatedHost.fail(StateError('socket aborted'));

    final event = await diagnostic;
    expect(event.message, contains('transport_error'));
    expect(event.message, contains('socket aborted'));

    await client.disconnect();
  });
}
