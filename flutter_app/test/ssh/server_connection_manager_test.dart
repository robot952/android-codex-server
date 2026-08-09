import 'dart:async';
import 'dart:typed_data';

import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/ssh/server_connection_manager.dart';
import 'package:codex_remote/src/ssh/ssh_server_client.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeClient implements RemoteServerClient {
  _FakeClient({
    this.connectError,
    this.probeResult,
    List<Future<ServerMetrics>>? metricsResults,
    this.metricsError,
  }) : metricsResults = List.of(metricsResults ?? const []);

  final Object? connectError;
  final Future<String>? probeResult;
  final List<Future<ServerMetrics>> metricsResults;
  final Object? metricsError;
  final Completer<void> closed = Completer<void>();
  bool connected = false;
  bool wasClosed = false;
  int connectCount = 0;
  int metricsReadCount = 0;

  @override
  Future<void> connect(ServerProfile profile) async {
    connectCount++;
    if (connectError case final error?) throw error;
    connected = true;
  }

  @override
  Future<void> disconnect() async {
    connected = false;
    if (!closed.isCompleted) closed.complete();
  }

  @override
  Future<void> get done => closed.future;

  void failConnection(Object error) {
    connected = false;
    if (!closed.isCompleted) {
      closed.completeError(error, StackTrace.current);
    }
  }

  @override
  bool get isConnected => connected;

  @override
  Future<String> probeFingerprint(ServerProfile profile) async =>
      probeResult == null ? 'SHA256:test' : await probeResult!;

  @override
  Future<ServerMetrics> readServerMetrics(ServerProfile profile) async {
    metricsReadCount++;
    if (metricsError case final error?) throw error;
    if (metricsResults.isEmpty) return const ServerMetrics();
    return metricsResults.removeAt(0);
  }

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
    wasClosed = true;
    connected = false;
    if (!closed.isCompleted) closed.complete();
  }
}

class _FakeImageClient extends _FakeClient implements RemoteServerImageClient {
  _FakeImageClient(this.imageResult);

  final Future<Uint8List> imageResult;
  String? requestedPath;
  int? requestedLimit;

  @override
  Future<Uint8List> readRemoteImage(
    String path, {
    int maxBytes = maxRemoteImageBytes,
  }) {
    requestedPath = path;
    requestedLimit = maxBytes;
    return imageResult;
  }
}

class _FakeAttachmentClient extends _FakeClient
    implements RemoteServerAttachmentClient {
  _FakeAttachmentClient(this.uploadResult);

  final Future<String> uploadResult;
  String? uploadedName;
  Uint8List? uploadedBytes;
  int? uploadedLimit;
  int uploadCount = 0;

  @override
  Future<String> uploadAttachment(
    String name,
    Uint8List bytes, {
    int maxBytes = maxRemoteAttachmentBytes,
  }) {
    uploadCount++;
    uploadedName = name;
    uploadedBytes = bytes;
    uploadedLimit = maxBytes;
    return uploadResult;
  }
}

class _FakeFileClient extends _FakeClient implements RemoteServerFileClient {
  _FakeFileClient({this.chunks = const []});

  final List<Uint8List> chunks;
  String? requestedPath;
  int? requestedLimit;
  int emittedChunkCount = 0;

  @override
  Future<int> downloadRemoteFile(
    String path, {
    required Future<void> Function(Uint8List chunk) writeChunk,
    int maxBytes = maxRemoteFileBytes,
  }) async {
    requestedPath = path;
    requestedLimit = maxBytes;
    var total = 0;
    for (final chunk in chunks) {
      emittedChunkCount++;
      await writeChunk(chunk);
      total += chunk.length;
    }
    return total;
  }
}

class _FakeFileManagerClient extends _FakeClient
    implements RemoteServerFileManagerClient {
  _FakeFileManagerClient({
    this.listing = const RemoteFileListing(currentPath: '/srv'),
  });

  RemoteFileListing listing;
  final List<String?> listedPaths = <String?>[];
  final List<int> uploadedBytes = <int>[];
  String? uploadedDirectory;
  String? uploadedName;
  int? uploadedDeclaredSize;
  int? uploadedMaxBytes;
  String? renamedPath;
  String? renamedName;
  List<String>? deletedPaths;
  List<String>? transferredPaths;
  String? transferDestination;
  RemoteFileTransferMode? transferMode;
  Future<void> Function(int chunkIndex)? afterUploadChunk;

  @override
  Future<RemoteFileListing> listRemoteFiles(String? path) async {
    listedPaths.add(path);
    return listing;
  }

  @override
  Future<void> uploadRemoteFile(
    String directory,
    String name,
    Stream<List<int>> chunks, {
    int? declaredSize,
    int maxBytes = maxRemoteFileBytes,
  }) async {
    uploadedDirectory = directory;
    uploadedName = name;
    uploadedDeclaredSize = declaredSize;
    uploadedMaxBytes = maxBytes;
    var index = 0;
    await for (final chunk in chunks) {
      uploadedBytes.addAll(chunk);
      await afterUploadChunk?.call(index++);
    }
  }

  @override
  Future<void> renameRemoteFile(String path, String newName) async {
    renamedPath = path;
    renamedName = newName;
  }

  @override
  Future<void> deleteRemoteFiles(List<String> paths) async {
    deletedPaths = List<String>.of(paths);
  }

  @override
  Future<void> transferRemoteFiles(
    List<String> paths,
    String destinationDirectory,
    RemoteFileTransferMode mode,
  ) async {
    transferredPaths = List<String>.of(paths);
    transferDestination = destinationDirectory;
    transferMode = mode;
  }
}

class _FakeDirectoryClient extends _FakeClient
    implements RemoteServerDirectoryClient {
  _FakeDirectoryClient(this.listingResult);

  final Future<RemoteDirectoryListing> listingResult;
  String? requestedPath;
  int requestCount = 0;

  @override
  Future<RemoteDirectoryListing> listDirectories(String? path) {
    requestCount++;
    requestedPath = path;
    return listingResult;
  }
}

void main() {
  const first = ServerProfile(
    id: 'first',
    host: 'one.example',
    username: 'root',
    password: 'secret',
    authMode: AuthMode.password,
    hostFingerprint: 'SHA256:first',
  );

  test('normalizes OpenSSH SHA-256 fingerprints', () {
    expect(normalizeSshFingerprint(' abc== '), 'SHA256:abc');
    expect(normalizeSshFingerprint('sha256:abc='), 'SHA256:abc');
    expect(normalizeSshFingerprint(''), isEmpty);
  });

  test('reuses a client for display-only profile changes', () async {
    final created = <_FakeClient>[];
    final manager = ServerConnectionManager(
      clientFactory: () {
        final client = _FakeClient();
        created.add(client);
        return client;
      },
    );

    final original = manager.registerProfile(first);
    final renamed = manager.registerProfile(
      first.copyWith(name: 'Renamed', workspace: '/workspace'),
    );

    expect(identical(original, renamed), isTrue);
    expect(created, hasLength(1));
    await manager.close();
  });

  test('reads a bounded image through the connected host lane', () async {
    final bytes = Uint8List.fromList(<int>[1, 2, 3]);
    final client = _FakeImageClient(Future<Uint8List>.value(bytes));
    final manager = ServerConnectionManager(clientFactory: () => client);
    await manager.connect(first);

    final result = await manager.readRemoteImage(first.id, '/tmp/screen.png');

    expect(result, bytes);
    expect(client.requestedPath, '/tmp/screen.png');
    expect(client.requestedLimit, maxRemoteImageBytes);
    await manager.close();
  });

  test('lists remote directories through the connected host lane', () async {
    const listing = RemoteDirectoryListing(
      currentPath: '/srv',
      parentPath: '/',
      directories: [RemoteDirectory(name: 'app', path: '/srv/app')],
    );
    final client = _FakeDirectoryClient(Future.value(listing));
    final manager = ServerConnectionManager(clientFactory: () => client);
    await manager.connect(first);

    final result = await manager.listDirectories(first, '/srv');

    expect(result, listing);
    expect(client.requestedPath, '/srv');
    expect(client.requestCount, 1);
    await manager.close();
  });

  test('requires the optional remote directory capability', () async {
    final client = _FakeClient();
    final manager = ServerConnectionManager(clientFactory: () => client);
    await manager.connect(first);

    await expectLater(
      manager.listDirectories(first, null),
      throwsUnsupportedError,
    );
    await manager.close();
  });

  test('rejects directory browsing from a stale profile identity', () async {
    const listing = RemoteDirectoryListing(currentPath: '/');
    final client = _FakeDirectoryClient(Future.value(listing));
    final manager = ServerConnectionManager(clientFactory: () => client);
    await manager.connect(first);

    await expectLater(
      manager.listDirectories(first.copyWith(host: 'replacement.example'), '/'),
      throwsStateError,
    );
    expect(client.requestCount, 0);
    await manager.close();
  });

  test('drops a directory result after its host lane is replaced', () async {
    final pending = Completer<RemoteDirectoryListing>();
    final clients = <_FakeClient>[
      _FakeDirectoryClient(pending.future),
      _FakeClient(),
    ];
    final manager = ServerConnectionManager(
      clientFactory: () => clients.removeAt(0),
    );
    await manager.connect(first);

    final request = manager.listDirectories(first, '/srv');
    manager.registerProfile(first.copyWith(host: 'replacement.example'));
    pending.complete(const RemoteDirectoryListing(currentPath: '/srv'));

    await expectLater(request, throwsStateError);
    await manager.close();
  });

  test(
    'drops a directory result after disconnect changes generation',
    () async {
      final pending = Completer<RemoteDirectoryListing>();
      final client = _FakeDirectoryClient(pending.future);
      final manager = ServerConnectionManager(clientFactory: () => client);
      await manager.connect(first);

      final request = manager.listDirectories(first, '/srv');
      await manager.disconnect(first.id);
      pending.complete(const RemoteDirectoryListing(currentPath: '/srv'));

      await expectLater(request, throwsStateError);
      await manager.close();
    },
  );

  test('rejects invalid remote directory paths before opening SSH', () async {
    final client = DartSshServerClient();

    await expectLater(
      client.listDirectories('/srv/bad\nname'),
      throwsArgumentError,
    );
    await expectLater(
      client.listDirectories(
        List<String>.filled(maxRemotePathChars + 1, 'x').join(),
      ),
      throwsArgumentError,
    );
    client.close();
  });

  test('sorts and limits remote directory results', () {
    final sorted = sortAndLimitRemoteDirectories(const [
      RemoteDirectory(name: 'zeta', path: '/zeta'),
      RemoteDirectory(name: 'Alpha', path: '/Alpha'),
      RemoteDirectory(name: 'beta', path: '/beta'),
    ]);

    expect(sorted.map((entry) => entry.name), ['Alpha', 'beta', 'zeta']);

    final overflow = List<RemoteDirectory>.generate(
      maxRemoteDirectoryEntries + 1,
      (index) => RemoteDirectory(
        name: index.toString().padLeft(4, '0'),
        path: '/$index',
      ),
    );
    final bounded = sortAndLimitRemoteDirectories(overflow);
    expect(bounded, hasLength(maxRemoteDirectoryEntries));
    expect(bounded, isNot(contains(overflow.last)));
  });

  test('validates and formats remote file manager metadata', () {
    expect(validateRemoteFileManagerPath('/srv/app', '文件'), '/srv/app');
    expect(
      () => validateRemoteFileManagerPath('/srv/../etc', '文件'),
      throwsArgumentError,
    );
    expect(validateRemoteFileManagerName('report.txt'), 'report.txt');
    expect(
      () => validateRemoteFileManagerName('../report.txt'),
      throwsArgumentError,
    );
    expect(
      formatRemoteFilePermissions(RemoteFileKind.directory, 0x1ed),
      'drwxr-xr-x',
    );

    final sorted = sortAndLimitRemoteFiles(const <RemoteFileEntry>[
      RemoteFileEntry(
        name: 'zeta.txt',
        path: '/zeta.txt',
        kind: RemoteFileKind.file,
      ),
      RemoteFileEntry(
        name: 'Beta',
        path: '/Beta',
        kind: RemoteFileKind.directory,
      ),
      RemoteFileEntry(
        name: 'alpha',
        path: '/alpha',
        kind: RemoteFileKind.directory,
      ),
    ]);
    expect(sorted.map((entry) => entry.name), <String>[
      'alpha',
      'Beta',
      'zeta.txt',
    ]);
  });

  test(
    'routes complete file manager operations through the connected lane',
    () async {
      const listing = RemoteFileListing(
        currentPath: '/srv',
        parentPath: '/',
        entries: <RemoteFileEntry>[
          RemoteFileEntry(
            name: 'app',
            path: '/srv/app',
            kind: RemoteFileKind.directory,
          ),
        ],
      );
      final client = _FakeFileManagerClient(listing: listing);
      final manager = ServerConnectionManager(clientFactory: () => client);
      await manager.connect(first);

      expect(await manager.listRemoteFiles(first, '/srv'), listing);
      await manager.uploadRemoteFile(
        first,
        '/srv',
        'notes.txt',
        Stream<List<int>>.fromIterable(const <List<int>>[
          <int>[1, 2],
          <int>[3],
        ]),
        declaredSize: 3,
        maxBytes: 128,
      );
      await manager.renameRemoteFile(first, '/srv/notes.txt', 'renamed.txt');
      await manager.deleteRemoteFiles(first, const <String>['/srv/old.txt']);
      await manager.transferRemoteFiles(
        first,
        const <String>['/srv/renamed.txt'],
        '/tmp',
        RemoteFileTransferMode.move,
      );

      expect(client.listedPaths, <String?>['/srv']);
      expect(client.uploadedDirectory, '/srv');
      expect(client.uploadedName, 'notes.txt');
      expect(client.uploadedBytes, <int>[1, 2, 3]);
      expect(client.uploadedDeclaredSize, 3);
      expect(client.uploadedMaxBytes, 128);
      expect(client.renamedPath, '/srv/notes.txt');
      expect(client.renamedName, 'renamed.txt');
      expect(client.deletedPaths, <String>['/srv/old.txt']);
      expect(client.transferredPaths, <String>['/srv/renamed.txt']);
      expect(client.transferDestination, '/tmp');
      expect(client.transferMode, RemoteFileTransferMode.move);
      await manager.close();
    },
  );

  test('stops a streamed file-manager upload after disconnect', () async {
    final client = _FakeFileManagerClient();
    final manager = ServerConnectionManager(clientFactory: () => client);
    await manager.connect(first);
    client.afterUploadChunk = (index) async {
      if (index == 0) await manager.disconnect(first.id);
    };

    final request = manager.uploadRemoteFile(
      first,
      '/srv',
      'notes.txt',
      Stream<List<int>>.fromIterable(const <List<int>>[
        <int>[1],
        <int>[2],
      ]),
      declaredSize: 2,
    );

    await expectLater(request, throwsStateError);
    expect(client.uploadedBytes, <int>[1]);
    await manager.close();
  });

  test('requires the optional remote file manager capability', () async {
    final client = _FakeClient();
    final manager = ServerConnectionManager(clientFactory: () => client);
    await manager.connect(first);

    await expectLater(
      manager.listRemoteFiles(first, '/srv'),
      throwsUnsupportedError,
    );
    await manager.close();
  });

  test('drops an image result after its host lane is replaced', () async {
    final pending = Completer<Uint8List>();
    final clients = <_FakeClient>[
      _FakeImageClient(pending.future),
      _FakeClient(),
    ];
    final manager = ServerConnectionManager(
      clientFactory: () => clients.removeAt(0),
    );
    await manager.connect(first);

    final request = manager.readRemoteImage(first.id, '/tmp/screen.png');
    manager.registerProfile(first.copyWith(host: 'replacement.example'));
    pending.complete(Uint8List.fromList(<int>[1, 2, 3]));

    await expectLater(request, throwsStateError);
    await manager.close();
  });

  test(
    'uploads a bounded attachment through the connected host lane',
    () async {
      final bytes = Uint8List.fromList(<int>[4, 5, 6]);
      final client = _FakeAttachmentClient(
        Future<String>.value('/home/root/.codex-mobile/uploads/attachment.bin'),
      );
      final manager = ServerConnectionManager(clientFactory: () => client);
      await manager.connect(first);

      final result = await manager.uploadAttachment(
        first,
        'screen.png',
        bytes,
        maxBytes: 128,
      );

      expect(result, '/home/root/.codex-mobile/uploads/attachment.bin');
      expect(client.uploadedName, 'screen.png');
      expect(client.uploadedBytes, same(bytes));
      expect(client.uploadedLimit, 128);
      expect(client.uploadCount, 1);
      await manager.close();
    },
  );

  test('rejects an attachment from a stale profile identity', () async {
    final client = _FakeAttachmentClient(Future<String>.value('/tmp/file'));
    final manager = ServerConnectionManager(clientFactory: () => client);
    await manager.connect(first);

    final staleProfile = first.copyWith(host: 'changed.example');
    await expectLater(
      manager.uploadAttachment(
        staleProfile,
        'file.txt',
        Uint8List.fromList(<int>[1]),
      ),
      throwsStateError,
    );
    expect(client.uploadCount, 0);
    await manager.close();
  });

  test('drops an attachment result after its host lane is replaced', () async {
    final pending = Completer<String>();
    final oldClient = _FakeAttachmentClient(pending.future);
    final clients = <_FakeClient>[
      oldClient,
      _FakeAttachmentClient(Future.value('/tmp/new')),
    ];
    final manager = ServerConnectionManager(
      clientFactory: () => clients.removeAt(0),
    );
    await manager.connect(first);

    final request = manager.uploadAttachment(
      first,
      'file.txt',
      Uint8List.fromList(<int>[1, 2]),
    );
    manager.registerProfile(first.copyWith(host: 'replacement.example'));
    pending.complete('/tmp/stale');

    await expectLater(request, throwsStateError);
    await manager.close();
  });

  test(
    'drops an attachment result after disconnect increments generation',
    () async {
      final pending = Completer<String>();
      final client = _FakeAttachmentClient(pending.future);
      final manager = ServerConnectionManager(clientFactory: () => client);
      await manager.connect(first);

      final request = manager.uploadAttachment(
        first,
        'file.txt',
        Uint8List.fromList(<int>[1, 2]),
      );
      await manager.disconnect(first.id);
      pending.complete('/tmp/stale');

      await expectLater(request, throwsStateError);
      await manager.close();
    },
  );

  test('rejects invalid attachment bounds before opening SSH', () async {
    final client = DartSshServerClient();

    await expectLater(
      client.uploadAttachment(
        'file.txt',
        Uint8List.fromList(<int>[1, 2, 3]),
        maxBytes: 2,
      ),
      throwsStateError,
    );
    await expectLater(
      client.uploadAttachment(
        'file.txt',
        Uint8List.fromList(<int>[1]),
        maxBytes: maxRemoteAttachmentBytes + 1,
      ),
      throwsArgumentError,
    );
    await expectLater(
      client.uploadAttachment('file.txt', Uint8List(0)),
      throwsStateError,
    );
    client.close();
  });

  test('streams a remote file through the connected host lane', () async {
    final client = _FakeFileClient(
      chunks: [
        Uint8List.fromList(<int>[1, 2]),
        Uint8List.fromList(<int>[3, 4, 5]),
      ],
    );
    final manager = ServerConnectionManager(clientFactory: () => client);
    await manager.connect(first);
    final received = <int>[];

    final downloaded = await manager.downloadRemoteFile(
      first,
      '/tmp/report.zip',
      maxBytes: 128,
      writeChunk: (chunk) async => received.addAll(chunk),
    );

    expect(downloaded, 5);
    expect(received, <int>[1, 2, 3, 4, 5]);
    expect(client.requestedPath, '/tmp/report.zip');
    expect(client.requestedLimit, 128);
    await manager.close();
  });

  test('rejects directories, symbolic links, and special files', () {
    final directory = SftpFileAttrs(
      size: 0,
      mode: const SftpFileMode.value(1 << 14),
    );
    final symbolicLink = SftpFileAttrs(
      size: 1,
      mode: const SftpFileMode.value((1 << 15) | (1 << 13)),
    );
    final pipe = SftpFileAttrs(
      size: 1,
      mode: const SftpFileMode.value(1 << 12),
    );

    expect(
      () => validateRemoteFileForDownload('/tmp/folder', directory),
      throwsStateError,
    );
    expect(
      () => validateRemoteFileForDownload('/tmp/link', symbolicLink),
      throwsStateError,
    );
    expect(
      () => validateRemoteFileForDownload('/tmp/pipe', pipe),
      throwsStateError,
    );
  });

  test('validates remote file paths and declared size boundaries', () {
    final emptyFile = SftpFileAttrs(
      size: 0,
      mode: const SftpFileMode.value(1 << 15),
    );
    final boundaryFile = SftpFileAttrs(
      size: 8,
      mode: const SftpFileMode.value(1 << 15),
    );
    final oversizedFile = SftpFileAttrs(
      size: 9,
      mode: const SftpFileMode.value(1 << 15),
    );

    expect(validateRemoteFileForDownload('/tmp/empty', emptyFile), 0);
    expect(
      validateRemoteFileForDownload('/tmp/boundary', boundaryFile, maxBytes: 8),
      8,
    );
    expect(
      () => validateRemoteFileForDownload(
        '/tmp/oversized',
        oversizedFile,
        maxBytes: 8,
      ),
      throwsStateError,
    );
    expect(
      () => validateRemoteFileForDownload('relative.txt', emptyFile),
      throwsArgumentError,
    );
    expect(
      () => validateRemoteFileForDownload('/tmp/bad\nname', emptyFile),
      throwsArgumentError,
    );
    expect(
      () => validateRemoteFileForDownload(
        '/${List<String>.filled(maxRemotePathChars, 'x').join()}',
        emptyFile,
      ),
      throwsArgumentError,
    );
    expect(
      () => validateRemoteFileForDownload(
        '/tmp/file',
        emptyFile,
        maxBytes: maxRemoteFileBytes + 1,
      ),
      throwsArgumentError,
    );
  });

  test('stops a remote download when disconnected between chunks', () async {
    final client = _FakeFileClient(
      chunks: [
        Uint8List.fromList(<int>[1]),
        Uint8List.fromList(<int>[2]),
      ],
    );
    final manager = ServerConnectionManager(clientFactory: () => client);
    await manager.connect(first);
    final received = <int>[];

    final request = manager.downloadRemoteFile(
      first,
      '/tmp/report.zip',
      writeChunk: (chunk) async {
        received.addAll(chunk);
        await manager.disconnect(first.id);
      },
    );

    await expectLater(request, throwsStateError);
    expect(received, <int>[1]);
    expect(client.emittedChunkCount, 1);
    await manager.close();
  });

  test('stops a remote download when its host lane is replaced', () async {
    final oldClient = _FakeFileClient(
      chunks: [
        Uint8List.fromList(<int>[1]),
        Uint8List.fromList(<int>[2]),
      ],
    );
    final clients = <_FakeClient>[oldClient, _FakeClient()];
    final manager = ServerConnectionManager(
      clientFactory: () => clients.removeAt(0),
    );
    await manager.connect(first);
    final received = <int>[];

    final request = manager.downloadRemoteFile(
      first,
      '/tmp/report.zip',
      writeChunk: (chunk) async {
        received.addAll(chunk);
        manager.registerProfile(first.copyWith(host: 'replacement.example'));
      },
    );

    await expectLater(request, throwsStateError);
    expect(received, <int>[1]);
    expect(oldClient.emittedChunkCount, 1);
    await manager.close();
  });

  test(
    'replaces and closes a client when connection identity changes',
    () async {
      final created = <_FakeClient>[];
      final manager = ServerConnectionManager(
        clientFactory: () {
          final client = _FakeClient();
          created.add(client);
          return client;
        },
      );

      manager.registerProfile(first);
      manager.registerProfile(first.copyWith(host: 'two.example'));

      expect(created, hasLength(2));
      expect(created.first.wasClosed, isTrue);
      await manager.close();
    },
  );

  test('keeps multiple server states independent', () async {
    final manager = ServerConnectionManager(clientFactory: _FakeClient.new);
    const second = ServerProfile(
      id: 'second',
      host: 'two.example',
      username: 'root',
      password: 'secret',
      authMode: AuthMode.password,
      hostFingerprint: 'SHA256:second',
    );

    await Future.wait([manager.connect(first), manager.connect(second)]);

    expect(manager.states['first']?.phase, ConnectionPhase.connected);
    expect(manager.states['second']?.phase, ConnectionPhase.connected);
    await manager.disconnect('first');
    expect(manager.states['first']?.phase, ConnectionPhase.disconnected);
    expect(manager.states['second']?.phase, ConnectionPhase.connected);
    await manager.close();
  });

  test('stale close cannot overwrite a replacement connection', () async {
    final created = <_FakeClient>[];
    final manager = ServerConnectionManager(
      clientFactory: () {
        final client = _FakeClient();
        created.add(client);
        return client;
      },
    );
    await manager.connect(first);
    final replacement = first.copyWith(host: 'replacement.example');
    manager.registerProfile(replacement);
    await manager.connect(replacement);

    if (!created.first.closed.isCompleted) created.first.closed.complete();
    await Future<void>.delayed(Duration.zero);

    expect(manager.states['first']?.phase, ConnectionPhase.connected);
    await manager.close();
  });

  test('reports the transport reason for an unexpected disconnect', () async {
    final client = _FakeClient();
    final manager = ServerConnectionManager(clientFactory: () => client);
    await manager.connect(first);

    client.failConnection(StateError('network unreachable'));
    await Future<void>.delayed(Duration.zero);

    expect(manager.states['first']?.phase, ConnectionPhase.disconnected);
    expect(manager.states['first']?.message, contains('network unreachable'));
    await manager.close();
  });

  test('stale fingerprint probe cannot overwrite a replacement', () async {
    final oldFingerprint = Completer<String>();
    final clients = <_FakeClient>[
      _FakeClient(probeResult: oldFingerprint.future),
      _FakeClient(),
    ];
    final manager = ServerConnectionManager(
      clientFactory: () => clients.removeAt(0),
    );

    final staleProbe = manager.probeFingerprint(first);
    await Future<void>.delayed(Duration.zero);
    expect(manager.states['first']?.phase, ConnectionPhase.probing);

    final replacement = first.copyWith(host: 'replacement.example');
    manager.registerProfile(replacement);
    await manager.connect(replacement);
    oldFingerprint.complete('SHA256:old-host');

    await expectLater(staleProbe, throwsStateError);
    expect(manager.states['first']?.phase, ConnectionPhase.connected);
    await manager.close();
  });

  test('reports connection failures without affecting other entries', () async {
    final clients = <_FakeClient>[
      _FakeClient(connectError: StateError('认证失败')),
      _FakeClient(),
    ];
    final manager = ServerConnectionManager(
      clientFactory: () => clients.removeAt(0),
    );
    const second = ServerProfile(
      id: 'second',
      host: 'two.example',
      username: 'root',
      authMode: AuthMode.password,
      password: 'secret',
      hostFingerprint: 'SHA256:second',
    );

    await expectLater(manager.connect(first), throwsStateError);
    await manager.connect(second);

    expect(manager.states['first']?.phase, ConnectionPhase.failed);
    expect(manager.states['first']?.message, contains('认证失败'));
    expect(manager.states['second']?.phase, ConnectionPhase.connected);
    await manager.close();
  });

  test('deduplicates concurrent server metrics reads', () async {
    final metricsResult = Completer<ServerMetrics>();
    final client = _FakeClient(metricsResults: [metricsResult.future]);
    final manager = ServerConnectionManager(clientFactory: () => client);
    await manager.connect(first);

    final firstRefresh = manager.refreshServerMetrics(first.id);
    final duplicateRefresh = manager.refreshServerMetrics(first.id);

    expect(identical(firstRefresh, duplicateRefresh), isTrue);
    expect(client.metricsReadCount, 1);

    const metrics = ServerMetrics(
      cpuPercent: 42,
      memoryPercent: 51,
      sampledAtEpochMillis: 123,
    );
    metricsResult.complete(metrics);
    await Future.wait([firstRefresh, duplicateRefresh]);

    expect(manager.serverMetrics[first.id], metrics);
    await manager.refreshServerMetrics(first.id);
    expect(client.metricsReadCount, 2);
    await manager.close();
  });

  test('disconnect clears metrics and ignores an in-flight result', () async {
    final staleResult = Completer<ServerMetrics>();
    final client = _FakeClient(
      metricsResults: [
        Future.value(
          const ServerMetrics(cpuPercent: 20, sampledAtEpochMillis: 1),
        ),
        staleResult.future,
      ],
    );
    final manager = ServerConnectionManager(clientFactory: () => client);
    await manager.connect(first);
    await manager.refreshServerMetrics(first.id);
    expect(manager.serverMetrics[first.id]?.cpuPercent, 20);

    final staleRefresh = manager.refreshServerMetrics(first.id);
    expect(client.metricsReadCount, 2);
    await manager.disconnect(first.id);
    expect(manager.serverMetrics, isNot(contains(first.id)));

    staleResult.complete(
      const ServerMetrics(cpuPercent: 99, sampledAtEpochMillis: 2),
    );
    await staleRefresh;
    expect(manager.serverMetrics, isNot(contains(first.id)));
    await manager.close();
  });

  test(
    'an old client metrics result cannot overwrite its replacement',
    () async {
      final oldResult = Completer<ServerMetrics>();
      final clients = <_FakeClient>[
        _FakeClient(metricsResults: [oldResult.future]),
        _FakeClient(
          metricsResults: [
            Future.value(
              const ServerMetrics(cpuPercent: 35, sampledAtEpochMillis: 2),
            ),
          ],
        ),
      ];
      final manager = ServerConnectionManager(
        clientFactory: () => clients.removeAt(0),
      );
      await manager.connect(first);
      final staleRefresh = manager.refreshServerMetrics(first.id);

      final replacement = first.copyWith(host: 'replacement.example');
      manager.registerProfile(replacement);
      await manager.connect(replacement);
      oldResult.complete(
        const ServerMetrics(cpuPercent: 99, sampledAtEpochMillis: 1),
      );
      await staleRefresh;

      expect(manager.serverMetrics, isNot(contains(first.id)));
      await manager.refreshServerMetrics(first.id);
      expect(manager.serverMetrics[first.id]?.cpuPercent, 35);
      await manager.close();
    },
  );

  test('metrics failures do not change the connection state', () async {
    final client = _FakeClient(metricsError: StateError('资源采样失败'));
    final manager = ServerConnectionManager(clientFactory: () => client);
    await manager.connect(first);

    await manager.refreshServerMetrics(first.id);

    expect(manager.states[first.id]?.phase, ConnectionPhase.connected);
    expect(manager.states[first.id]?.message, 'SSH 已连接');
    expect(manager.serverMetrics[first.id]?.error, contains('资源采样失败'));
    await manager.close();
  });
}
