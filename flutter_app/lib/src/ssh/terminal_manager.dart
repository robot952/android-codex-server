import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../domain/models.dart';
import 'server_connection_manager.dart';

/// Lifecycle of one interactive SSH terminal.
enum TerminalPhase { disconnected, connecting, connected, failed }

@immutable
class TerminalSessionState {
  const TerminalSessionState({
    required this.profileId,
    required this.profileName,
    required this.endpoint,
    this.phase = TerminalPhase.disconnected,
    this.message = '未连接',
    this.generation = 0,
  });

  final String profileId;
  final String profileName;
  final String endpoint;
  final TerminalPhase phase;
  final String message;
  final int generation;

  TerminalSessionState copyWith({
    String? profileName,
    String? endpoint,
    TerminalPhase? phase,
    String? message,
    int? generation,
  }) => TerminalSessionState(
    profileId: profileId,
    profileName: profileName ?? this.profileName,
    endpoint: endpoint ?? this.endpoint,
    phase: phase ?? this.phase,
    message: message ?? this.message,
    generation: generation ?? this.generation,
  );
}

@immutable
class TerminalOutputEvent {
  const TerminalOutputEvent({
    required this.profileId,
    required this.generation,
    required this.bytes,
  });

  final String profileId;
  final int generation;
  final Uint8List bytes;
}

/// Owns one independent PTY for every server profile.
///
/// The host SSH connection itself remains owned by [ServerConnectionManager].
/// This manager only owns shell channels, keeps a bounded scrollback history,
/// and invalidates all asynchronous callbacks whenever a channel is replaced.
class TerminalManager extends ChangeNotifier {
  TerminalManager(this._connections) {
    _connectionSubscription = _connections.stateChanges.listen(
      _onConnectionStates,
    );
  }

  static const int maxHistoryBytes = 2 * 1024 * 1024;
  static const int maxInputBytes = 512 * 1024;
  static const int maxInputChunks = 256;
  static const int maxInputChunkBytes = 16 * 1024;

  final ServerConnectionManager _connections;
  final Map<String, _TerminalConnection> _sessions = {};
  late final StreamSubscription<Map<String, ConnectionState>>
  _connectionSubscription;
  final StreamController<TerminalOutputEvent> _outputController =
      StreamController<TerminalOutputEvent>.broadcast(sync: true);
  String? _visibleProfileId;
  bool _closed = false;

  Stream<TerminalOutputEvent> get outputChanges => _outputController.stream;

  String? get visibleProfileId => _visibleProfileId;

  Map<String, TerminalSessionState> get states =>
      Map.unmodifiable(<String, TerminalSessionState>{
        for (final entry in _sessions.entries) entry.key: entry.value.state,
      });

  TerminalSessionState? stateFor(String profileId) =>
      _sessions[profileId]?.state;

  /// Returns a copy of the bounded history for a terminal generation.
  List<Uint8List> historyFor(String profileId, int generation) {
    final session = _sessions[profileId];
    if (session == null || session.generation != generation) {
      return const <Uint8List>[];
    }
    return session.history
        .map((chunk) => Uint8List.fromList(chunk))
        .toList(growable: false);
  }

  void open(ServerProfile profile) {
    if (_closed) return;
    var session = _sessions[profile.id];
    if (session == null || !session.matches(profile)) {
      session?.close();
      session = _TerminalConnection(
        _connections,
        profile,
        onStateChanged: _publish,
        onOutput: (event) {
          if (!_closed && !_outputController.isClosed) {
            _outputController.add(event);
          }
        },
      );
      _sessions[profile.id] = session;
    }
    _visibleProfileId = profile.id;
    session.open(profile);
    _publish();
  }

  void hide() {
    if (_closed) return;
    _visibleProfileId = null;
    _publish();
  }

  void closeVisible() {
    final profileId = _visibleProfileId;
    if (profileId != null) closeProfile(profileId);
  }

  void closeProfile(String profileId) {
    final session = _sessions.remove(profileId);
    if (_visibleProfileId == profileId) _visibleProfileId = null;
    session?.close();
    _publish();
  }

  bool send(String profileId, Uint8List bytes) {
    if (_closed) return false;
    return _sessions[profileId]?.send(bytes) ?? false;
  }

  void resize(String profileId, int columns, int rows) {
    if (_closed) return;
    _sessions[profileId]?.resize(columns, rows);
  }

  void retry(String profileId) {
    final session = _sessions[profileId];
    final profile = _connections.profile(profileId);
    if (session != null && profile != null) session.open(profile);
  }

  void _onConnectionStates(Map<String, ConnectionState> states) {
    if (_closed) return;
    // A host disconnect invalidates its channels. Keeping the object in the
    // map lets the UI render a useful disconnected/failed state and retry.
    for (final entry in _sessions.entries.toList(growable: false)) {
      final phase = states[entry.key]?.phase;
      if (phase != ConnectionPhase.connected) entry.value.invalidateHost();
    }
    _publish();
  }

  void _publish() {
    if (!_closed) notifyListeners();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _connectionSubscription.cancel();
    for (final session in _sessions.values) {
      session.dispose();
    }
    _sessions.clear();
    _visibleProfileId = null;
    await _outputController.close();
    dispose();
  }
}

class _TerminalConnection {
  _TerminalConnection(
    this._connections,
    ServerProfile initialProfile, {
    required this.onStateChanged,
    required this.onOutput,
  }) : _profile = initialProfile,
       state = _stateFor(initialProfile);

  final ServerConnectionManager _connections;
  final void Function() onStateChanged;
  final void Function(TerminalOutputEvent event) onOutput;

  ServerProfile _profile;
  TerminalSessionState state;
  SSHSession? _session;
  StreamSubscription<Uint8List>? _stdoutSubscription;
  StreamSubscription<Uint8List>? _stderrSubscription;
  StreamSubscription<Uint8List>? _inputSubscription;
  StreamController<Uint8List>? _inputController;
  final List<Uint8List> history = <Uint8List>[];
  int _historyBytes = 0;
  int _generation = 0;
  int _columns = 80;
  int _rows = 24;
  int _pendingInputBytes = 0;
  int _pendingInputChunks = 0;
  bool _disposed = false;

  int get generation => _generation;

  bool matches(ServerProfile profile) =>
      _profile.hasSameConnectionIdentity(profile);

  void open(ServerProfile profile) {
    if (_disposed) return;
    _profile = profile;
    if (state.phase == TerminalPhase.connected ||
        state.phase == TerminalPhase.connecting) {
      state = state.copyWith(
        profileName: profile.name,
        endpoint: '${profile.username}@${profile.host}:${profile.port}',
      );
      onStateChanged();
      return;
    }
    _generation++;
    final expectedGeneration = _generation;
    _closeChannel();
    history.clear();
    _historyBytes = 0;
    state = _stateFor(
      profile,
      phase: TerminalPhase.connecting,
      message: '正在连接 SSH 终端',
      generation: expectedGeneration,
    );
    onStateChanged();
    unawaited(_connect(expectedGeneration, profile));
  }

  Future<void> _connect(int expectedGeneration, ServerProfile profile) async {
    try {
      final session = await _connections.openTerminalSession(
        profile,
        columns: _columns,
        rows: _rows,
      );
      if (!_isCurrent(expectedGeneration) || _disposed) {
        session.close();
        return;
      }
      _session = session;
      state = _stateFor(
        profile,
        phase: TerminalPhase.connected,
        message: 'SSH 终端已连接',
        generation: expectedGeneration,
      );
      onStateChanged();
      _inputController = StreamController<Uint8List>();
      final input = _inputController!;
      _inputSubscription = input.stream.listen(
        (bytes) {
          try {
            session.write(bytes);
          } catch (error) {
            _fail(expectedGeneration, error);
          } finally {
            _pendingInputBytes = (_pendingInputBytes - bytes.length)
                .clamp(0, TerminalManager.maxInputBytes)
                .toInt();
            _pendingInputChunks = (_pendingInputChunks - 1)
                .clamp(0, TerminalManager.maxInputChunks)
                .toInt();
          }
        },
        onError: (Object error, StackTrace stack) =>
            _fail(expectedGeneration, error),
      );
      _stdoutSubscription = session.stdout.listen(
        (bytes) => _appendOutput(expectedGeneration, bytes),
        onError: (Object error, StackTrace stack) =>
            _fail(expectedGeneration, error),
      );
      _stderrSubscription = session.stderr.listen(
        (bytes) => _appendOutput(expectedGeneration, bytes),
        onError: (Object error, StackTrace stack) =>
            _fail(expectedGeneration, error),
      );
      unawaited(
        session.done
            .then((_) {
              if (_isCurrent(expectedGeneration)) {
                _finish(expectedGeneration, 'SSH 终端已断开');
              }
            })
            .catchError((Object error, StackTrace stack) {
              _fail(expectedGeneration, error);
            }),
      );
      final workspace = profile.workspace.trim();
      if (workspace.isNotEmpty && _isCurrent(expectedGeneration)) {
        send(utf8.encode('cd -- ${posixShellQuote(workspace)}\r'));
      }
    } catch (error) {
      if (_isCurrent(expectedGeneration)) _fail(expectedGeneration, error);
    }
  }

  bool send(List<int> value) {
    if (_disposed || state.phase != TerminalPhase.connected || value.isEmpty) {
      return value.isEmpty;
    }
    final chunkCount =
        (value.length + TerminalManager.maxInputChunkBytes - 1) ~/
        TerminalManager.maxInputChunkBytes;
    if (value.length > TerminalManager.maxInputBytes ||
        _pendingInputBytes + value.length > TerminalManager.maxInputBytes ||
        _pendingInputChunks + chunkCount > TerminalManager.maxInputChunks) {
      return false;
    }
    final controller = _inputController;
    if (controller == null || controller.isClosed) return false;
    final bytes = Uint8List.fromList(value);
    _pendingInputBytes += bytes.length;
    _pendingInputChunks += chunkCount;
    for (var offset = 0; offset < bytes.length;) {
      final end = (offset + TerminalManager.maxInputChunkBytes)
          .clamp(0, bytes.length)
          .toInt();
      final chunk = Uint8List.sublistView(bytes, offset, end);
      // The budget is checked for the complete payload above. Each chunk is
      // still copied so callers may safely reuse their input buffer.
      controller.add(Uint8List.fromList(chunk));
      offset = end;
    }
    return true;
  }

  void resize(int columns, int rows) {
    _columns = columns.clamp(20, 400).toInt();
    _rows = rows.clamp(4, 200).toInt();
    final session = _session;
    if (session == null || state.phase != TerminalPhase.connected) return;
    try {
      session.resizeTerminal(_columns, _rows);
    } catch (error) {
      _fail(_generation, error);
    }
  }

  void invalidateHost() {
    if (_disposed || state.phase == TerminalPhase.disconnected) return;
    _generation++;
    _closeChannel();
    state = _stateFor(
      _profile,
      phase: TerminalPhase.disconnected,
      message: 'SSH 连接已断开',
      generation: _generation,
    );
    onStateChanged();
  }

  void close() {
    if (_disposed) return;
    _generation++;
    _closeChannel();
    state = _stateFor(
      _profile,
      phase: TerminalPhase.disconnected,
      message: '终端已关闭',
      generation: _generation,
    );
    onStateChanged();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _closeChannel();
  }

  void _finish(int expectedGeneration, String message) {
    if (!_isCurrent(expectedGeneration) ||
        state.phase != TerminalPhase.connecting &&
            state.phase != TerminalPhase.connected) {
      return;
    }
    _closeChannel();
    state = _stateFor(
      _profile,
      phase: TerminalPhase.disconnected,
      message: message,
      generation: expectedGeneration,
    );
    onStateChanged();
  }

  void _fail(int expectedGeneration, Object error) {
    if (!_isCurrent(expectedGeneration)) return;
    final detail = _errorMessage(error, 'SSH 终端连接失败');
    _appendOutput(
      expectedGeneration,
      Uint8List.fromList(utf8.encode('\r\n[SSH: $detail]\r\n')),
    );
    _closeChannel();
    state = _stateFor(
      _profile,
      phase: TerminalPhase.failed,
      message: detail,
      generation: expectedGeneration,
    );
    onStateChanged();
  }

  void _appendOutput(int expectedGeneration, Uint8List bytes) {
    if (!_isCurrent(expectedGeneration) || bytes.isEmpty) return;
    final copy = Uint8List.fromList(bytes);
    history.add(copy);
    _historyBytes += copy.length;
    while (_historyBytes > TerminalManager.maxHistoryBytes &&
        history.length > 1) {
      _historyBytes -= history.removeAt(0).length;
    }
    onOutput(
      TerminalOutputEvent(
        profileId: _profile.id,
        generation: expectedGeneration,
        bytes: copy,
      ),
    );
  }

  bool _isCurrent(int expectedGeneration) =>
      !_disposed && expectedGeneration == _generation;

  void _closeChannel() {
    final input = _inputController;
    _inputController = null;
    _pendingInputBytes = 0;
    _pendingInputChunks = 0;
    unawaited(_inputSubscription?.cancel() ?? Future<void>.value());
    _inputSubscription = null;
    if (input != null && !input.isClosed) unawaited(input.close());
    unawaited(_stdoutSubscription?.cancel() ?? Future<void>.value());
    unawaited(_stderrSubscription?.cancel() ?? Future<void>.value());
    _stdoutSubscription = null;
    _stderrSubscription = null;
    final session = _session;
    _session = null;
    if (session != null) {
      try {
        session.channel.destroy();
      } catch (_) {
        try {
          session.close();
        } catch (_) {}
      }
    }
  }
}

TerminalSessionState _stateFor(
  ServerProfile profile, {
  TerminalPhase phase = TerminalPhase.disconnected,
  String message = '未连接',
  int generation = 0,
}) => TerminalSessionState(
  profileId: profile.id,
  profileName: profile.name,
  endpoint: '${profile.username}@${profile.host}:${profile.port}',
  phase: phase,
  message: message,
  generation: generation,
);

String posixShellQuote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";

String _errorMessage(Object error, String fallback) {
  final value = error.toString().replaceFirst(RegExp(r'^[^:]+:\s*'), '').trim();
  return value.isEmpty ? fallback : value;
}
