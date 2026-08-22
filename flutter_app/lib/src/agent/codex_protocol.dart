import 'dart:convert';

import '../domain/models.dart';

/// Payload limits mirror the bounds used by the legacy Kotlin adapter.  They
/// apply to values retained by the domain model, rather than changing the
/// wire-level JSON-RPC contract.
const int codexMaxThreadFieldChars = 16 * 1024;
const int codexMaxTimelineTextChars = 256 * 1024;
const int codexMaxCommandOutputChars = 512 * 1024;
const int codexMaxDiffChars = 512 * 1024;
const int codexMaxMetadataPreviewChars = 16 * 1024;
const int codexMaxAggregateDiffChars = codexMaxDiffChars;
const int codexMaxTimelineMetadataChars = codexMaxMetadataPreviewChars;

const int _maxPayloadListItems = 1024;
const int _maxObjectEntries = 512;
const int _maxThreadListItems = 1024;
const int _maxModelItems = 512;
const int _maxTimelineTurns = 1024;
const int _maxTimelineItemsPerTurn = 4096;
const int _maxTimelineEntries = 4096;
const int _maxReasoningParts = 64;
const int _maxFileChanges = 256;
const int _maxPayloadDepth = 6;

const String codexTextTruncationMarker = '\n\n[内容过长，后续已截断]';
const String codexOutputTruncationMarker = '\n\n[命令输出过长，后续已截断]';
const String codexDiffTruncationMarker = '\n\n[差异内容过长，后续已截断]';

/// Detects the raw object preview emitted by a web-search tool.
///
/// Search results are protocol metadata, not assistant prose. Keeping this
/// check at the protocol boundary prevents an unsupported search payload from
/// being rendered as a huge reasoning paragraph when a provider sends an
/// older or provider-specific item shape.
bool isCodexRawWebSearchPayload(String text) {
  final normalized = text.trim();
  if (normalized.length < 20) return false;
  final lower = normalized.toLowerCase();
  final hasSearchType =
      lower.contains('websearch') || lower.contains('web_search');
  final hasResultShape =
      lower.contains('text_result') ||
      (lower.contains('ref_id') &&
          (lower.contains('snippet') ||
              lower.contains('domain') ||
              lower.contains('url')));
  if (!hasSearchType && !hasResultShape) return false;
  return normalized.startsWith('{') ||
      normalized.startsWith('[') ||
      (hasResultShape &&
          (normalized.contains('{') || normalized.contains('['))) ||
      (hasSearchType && (lower.contains('query') || lower.contains('results')));
}

/// Request identifiers are deliberately type-sensitive: JSON `1` and `"1"`
/// identify different requests.
sealed class CodexRequestId {
  const CodexRequestId();

  const factory CodexRequestId.string(String value) = CodexStringRequestId;
  const factory CodexRequestId.number(num value) = CodexNumericRequestId;

  Object get wireValue;
  bool get isString;

  static CodexRequestId? tryParse(Object? value) => switch (value) {
    String() => CodexRequestId.string(value),
    num() when value.isFinite => CodexRequestId.number(value),
    _ => null,
  };
}

final class CodexStringRequestId extends CodexRequestId {
  const CodexStringRequestId(this.value);

  final String value;

  @override
  String get wireValue => value;

  @override
  bool get isString => true;

  @override
  bool operator ==(Object other) =>
      other is CodexStringRequestId && other.value == value;

  @override
  int get hashCode => Object.hash(CodexStringRequestId, value);

  @override
  String toString() => 'CodexRequestId.string($value)';
}

final class CodexNumericRequestId extends CodexRequestId {
  const CodexNumericRequestId(this.value);

  final num value;

  @override
  num get wireValue => value;

  @override
  bool get isString => false;

  @override
  bool operator ==(Object other) =>
      other is CodexNumericRequestId && other.value == value;

  @override
  int get hashCode => Object.hash(CodexNumericRequestId, value);

  @override
  String toString() => 'CodexRequestId.number($value)';
}

sealed class CodexOutboundMessage {
  const CodexOutboundMessage({required this.generation});

  final int generation;

  Map<String, Object?> toJson();

  /// Encodes one JSON value without a trailing delimiter.
  String encode() => jsonEncode(toJson());

  /// Encodes one complete newline-delimited JSON record.
  String encodeLine() => '${encode()}\n';
}

final class CodexRpcRequest extends CodexOutboundMessage {
  const CodexRpcRequest({
    required super.generation,
    required this.id,
    required this.method,
    this.params = const <String, Object?>{},
  });

  final CodexRequestId id;
  final String method;
  final Map<String, Object?> params;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'method': method,
    'id': id.wireValue,
    'params': params,
  };
}

final class CodexRpcClientNotification extends CodexOutboundMessage {
  const CodexRpcClientNotification({
    required super.generation,
    required this.method,
    this.params = const <String, Object?>{},
  });

  final String method;
  final Map<String, Object?> params;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'method': method,
    'params': params,
  };
}

/// A structured JSON-RPC error returned by the app-server.
final class CodexRpcError {
  const CodexRpcError({required this.code, required this.message, this.data});

  final int code;
  final String message;
  final Object? data;
}

final class CodexRpcException implements Exception {
  const CodexRpcException({
    required this.id,
    required this.generation,
    required this.error,
  });

  final CodexRequestId id;
  final int generation;
  final CodexRpcError error;

  int get code => error.code;
  String get message => error.message;
  Object? get data => error.data;

  @override
  String toString() =>
      'CodexRpcException($code, $message, id: ${id.wireValue})';
}

sealed class CodexInboundMessage {
  const CodexInboundMessage({
    required this.generation,
    required this.raw,
    this.sequence = 0,
  });

  final int generation;
  final Map<String, Object?> raw;
  final int sequence;
}

final class CodexRpcResponse extends CodexInboundMessage {
  const CodexRpcResponse({
    required super.generation,
    required super.raw,
    super.sequence,
    required this.id,
    this.result,
    this.error,
  });

  final CodexRequestId id;
  final Object? result;
  final CodexRpcError? error;

  bool get isError => error != null;

  /// Returns the result or raises a typed exception retaining id, code and data.
  Object? resultOrThrow() {
    final rpcError = error;
    if (rpcError != null) {
      throw CodexRpcException(id: id, generation: generation, error: rpcError);
    }
    return result;
  }
}

final class CodexRpcNotification extends CodexInboundMessage {
  const CodexRpcNotification({
    required super.generation,
    required super.raw,
    super.sequence,
    required this.method,
    required this.params,
    required this.isKnown,
  });

  final String method;
  final Map<String, Object?> params;

  /// Unknown notifications remain available to diagnostics and future reducers.
  final bool isKnown;
}

final class CodexServerRequest extends CodexInboundMessage {
  const CodexServerRequest({
    required super.generation,
    required super.raw,
    super.sequence,
    required this.id,
    required this.method,
    required this.params,
  });

  final CodexRequestId id;
  final String method;
  final Map<String, Object?> params;
}

/// Malformed lines are data, rather than exceptions escaping the read loop.
final class CodexParseError extends CodexInboundMessage {
  const CodexParseError({
    required super.generation,
    super.sequence,
    required this.line,
    required this.message,
    super.raw = const <String, Object?>{},
  });

  final String line;
  final String message;
}

const Set<String> codexKnownNotificationMethods = <String>{
  'turn/started',
  'turn/completed',
  'turn/diff/updated',
  'thread/status/changed',
  'thread/tokenUsage/updated',
  'thread/name/updated',
  'thread/goal/updated',
  'thread/goal/cleared',
  'item/started',
  'item/completed',
  'item/agentMessage/delta',
  'item/reasoning/summaryPartAdded',
  'item/reasoning/summaryTextDelta',
  'item/reasoning/textDelta',
  'item/commandExecution/outputDelta',
  'item/fileChange/patchUpdated',
  'item/plan/delta',
};

/// Stateless decoder for one app-server stdout JSONL record.
final class CodexJsonlDecoder {
  const CodexJsonlDecoder({
    this.knownNotificationMethods = codexKnownNotificationMethods,
  });

  final Set<String> knownNotificationMethods;

  CodexInboundMessage decodeLine(
    String line, {
    required int generation,
    int sequence = 0,
  }) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      return CodexParseError(
        generation: generation,
        sequence: sequence,
        line: line,
        message: 'Codex app-server returned an empty line.',
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException catch (error) {
      return CodexParseError(
        generation: generation,
        sequence: sequence,
        line: line,
        message: 'Invalid JSON: ${error.message}',
      );
    }

    final raw = _asObjectMap(decoded);
    if (raw == null) {
      return CodexParseError(
        generation: generation,
        sequence: sequence,
        line: line,
        message: 'A Codex JSONL record must be an object.',
      );
    }

    final hasMethod = raw.containsKey('method');
    final methodValue = raw['method'];
    if (hasMethod) {
      if (methodValue is! String || methodValue.isEmpty) {
        return CodexParseError(
          generation: generation,
          sequence: sequence,
          line: line,
          raw: raw,
          message: 'The JSON-RPC method must be a non-empty string.',
        );
      }
      final params = _paramsObject(raw['params']);
      if (params == null) {
        return CodexParseError(
          generation: generation,
          sequence: sequence,
          line: line,
          raw: raw,
          message: 'Codex app-server params must be an object.',
        );
      }
      if (!raw.containsKey('id')) {
        return CodexRpcNotification(
          generation: generation,
          sequence: sequence,
          raw: raw,
          method: methodValue,
          params: params,
          isKnown: knownNotificationMethods.contains(methodValue),
        );
      }
      final id = _parseRequestId(raw['id']);
      if (id == null) {
        return CodexParseError(
          generation: generation,
          sequence: sequence,
          line: line,
          raw: raw,
          message: 'A JSON-RPC id must be a string or a finite number.',
        );
      }
      return CodexServerRequest(
        generation: generation,
        sequence: sequence,
        raw: raw,
        id: id,
        method: methodValue,
        params: params,
      );
    }

    if (!raw.containsKey('id')) {
      return CodexParseError(
        generation: generation,
        sequence: sequence,
        line: line,
        raw: raw,
        message: 'The JSON-RPC record has neither a method nor an id.',
      );
    }
    final id = _parseRequestId(raw['id']);
    if (id == null) {
      return CodexParseError(
        generation: generation,
        sequence: sequence,
        line: line,
        raw: raw,
        message: 'A JSON-RPC id must be a string or a finite number.',
      );
    }

    final hasResult = raw.containsKey('result');
    final hasError = raw.containsKey('error');
    if (hasResult == hasError) {
      return CodexParseError(
        generation: generation,
        sequence: sequence,
        line: line,
        raw: raw,
        message: 'A response must contain exactly one of result or error.',
      );
    }
    if (hasError) {
      final errorObject = _asObjectMap(raw['error']);
      final code = _strictInt(errorObject?['code']);
      final message = errorObject?['message'];
      if (errorObject == null || code == null || message is! String) {
        return CodexParseError(
          generation: generation,
          sequence: sequence,
          line: line,
          raw: raw,
          message: 'A JSON-RPC error must contain an integer code and message.',
        );
      }
      return CodexRpcResponse(
        generation: generation,
        sequence: sequence,
        raw: raw,
        id: id,
        error: CodexRpcError(
          code: code,
          message: message,
          data: errorObject['data'],
        ),
      );
    }
    return CodexRpcResponse(
      generation: generation,
      sequence: sequence,
      raw: raw,
      id: id,
      result: raw['result'],
    );
  }
}

/// Owns one monotonically increasing connection generation.
///
/// Callers retain the returned [CodexProtocolGeneration] beside async work. A
/// reconnect starts a new generation, after which old lines, results and state
/// commits are ignored instead of overwriting the new connection.
final class CodexProtocolSession {
  CodexProtocolSession({this.decoder = const CodexJsonlDecoder()});

  final CodexJsonlDecoder decoder;
  int _generation = 0;
  int _nextRequestId = 1;
  int _nextInboundSequence = 0;

  int get currentGeneration => _generation;

  CodexProtocolGeneration beginGeneration() {
    _generation += 1;
    _nextRequestId = 1;
    _nextInboundSequence = 0;
    return CodexProtocolGeneration._(this, _generation);
  }

  /// Invalidates every retained scope without opening another connection.
  void invalidateGeneration() {
    _generation += 1;
    _nextRequestId = 1;
    _nextInboundSequence = 0;
  }

  bool isCurrentGeneration(int generation) => generation == _generation;

  CodexRpcRequest _request(
    int generation,
    String method,
    Map<String, Object?> params, {
    CodexRequestId? id,
  }) {
    _requireCurrent(generation);
    final requestId = id ?? CodexRequestId.number(_nextRequestId++);
    return CodexRpcRequest(
      generation: generation,
      id: requestId,
      method: method,
      params: params,
    );
  }

  CodexInboundMessage? _decodeLine(int generation, String line) {
    if (!isCurrentGeneration(generation)) return null;
    final message = decoder.decodeLine(
      line,
      generation: generation,
      sequence: ++_nextInboundSequence,
    );
    return isCurrentGeneration(generation) ? message : null;
  }

  void _requireCurrent(int generation) {
    if (!isCurrentGeneration(generation)) {
      throw StateError('Codex protocol generation $generation is stale.');
    }
  }
}

final class CodexProtocolGeneration {
  const CodexProtocolGeneration._(this._session, this.value);

  final CodexProtocolSession _session;
  final int value;

  bool get isCurrent => _session.isCurrentGeneration(value);

  CodexRpcRequest request(
    String method, {
    Map<String, Object?> params = const <String, Object?>{},
    CodexRequestId? id,
  }) {
    if (method.trim().isEmpty) {
      throw ArgumentError.value(method, 'method', 'must not be empty');
    }
    return _session._request(value, method, params, id: id);
  }

  CodexRpcRequest initialize({
    required String clientVersion,
    String clientName = 'codex_remote_android',
    String clientTitle = 'Codex Remote Android',
    bool experimentalApi = true,
    List<String> optOutNotificationMethods = const <String>[],
  }) => request(
    'initialize',
    params: <String, Object?>{
      'clientInfo': <String, Object?>{
        'name': clientName,
        'title': clientTitle,
        'version': clientVersion,
      },
      'capabilities': <String, Object?>{
        'optOutNotificationMethods': optOutNotificationMethods,
        'experimentalApi': experimentalApi,
      },
    },
  );

  CodexRpcClientNotification initialized() {
    _session._requireCurrent(value);
    return CodexRpcClientNotification(generation: value, method: 'initialized');
  }

  CodexRpcRequest threadList({
    int limit = 100,
    bool archived = false,
    String sortKey = 'recency_at',
    String sortDirection = 'desc',
    String? searchTerm,
    String? cursor,
    List<String>? modelProviders,
  }) {
    if (limit <= 0) {
      throw ArgumentError.value(limit, 'limit', 'must be greater than zero');
    }
    return request(
      'thread/list',
      params: <String, Object?>{
        'limit': limit,
        'archived': archived,
        'sortKey': sortKey,
        'sortDirection': sortDirection,
        if (searchTerm?.trim().isNotEmpty ?? false)
          'searchTerm': searchTerm!.trim(),
        if (cursor?.isNotEmpty ?? false) 'cursor': cursor,
        if (modelProviders != null && modelProviders.isNotEmpty)
          'modelProviders': modelProviders
              .map((provider) => provider.trim())
              .where((provider) => provider.isNotEmpty)
              .toList(growable: false),
      },
    );
  }

  CodexRpcRequest threadStart({
    String? cwd,
    String? model,
    ApprovalMode approvalMode = ApprovalMode.requestApproval,
    SandboxChoice? sandbox,
    bool ephemeral = false,
  }) => request(
    'thread/start',
    params: <String, Object?>{
      if (cwd?.isNotEmpty ?? false) 'cwd': cwd,
      if (model?.isNotEmpty ?? false) 'model': model,
      'approvalPolicy': approvalMode.approvalPolicy,
      'sandbox': (sandbox ?? approvalMode.sandbox).wireValue,
      'ephemeral': ephemeral,
    },
  );

  CodexRpcRequest threadRead({
    required String threadId,
    bool includeTurns = true,
  }) {
    _requireNonEmpty(threadId, 'threadId');
    return request(
      'thread/read',
      params: <String, Object?>{
        'threadId': threadId,
        'includeTurns': includeTurns,
      },
    );
  }

  CodexRpcRequest threadResume({
    required String threadId,
    ApprovalMode approvalMode = ApprovalMode.requestApproval,
    String itemsView = 'full',
    int limit = 4,
  }) {
    _requireNonEmpty(threadId, 'threadId');
    if (limit <= 0) {
      throw ArgumentError.value(limit, 'limit', 'must be greater than zero');
    }
    return request(
      'thread/resume',
      params: <String, Object?>{
        'threadId': threadId,
        'approvalPolicy': approvalMode.approvalPolicy,
        'excludeTurns': true,
        'initialTurnsPage': <String, Object?>{
          'limit': limit,
          'sortDirection': 'desc',
          'itemsView': itemsView,
        },
      },
    );
  }

  CodexRpcRequest threadTurnsList({
    required String threadId,
    required String cursor,
    String itemsView = 'full',
    int limit = 4,
  }) {
    _requireNonEmpty(threadId, 'threadId');
    _requireNonEmpty(cursor, 'cursor');
    if (limit <= 0) {
      throw ArgumentError.value(limit, 'limit', 'must be greater than zero');
    }
    return request(
      'thread/turns/list',
      params: <String, Object?>{
        'threadId': threadId,
        'cursor': cursor,
        'limit': limit,
        'sortDirection': 'desc',
        'itemsView': itemsView,
      },
    );
  }

  CodexRpcRequest threadCompactStart({required String threadId}) {
    _requireNonEmpty(threadId, 'threadId');
    return request(
      'thread/compact/start',
      params: <String, Object?>{'threadId': threadId},
    );
  }

  CodexRpcRequest threadArchive({required String threadId}) {
    _requireNonEmpty(threadId, 'threadId');
    return request(
      'thread/archive',
      params: <String, Object?>{'threadId': threadId},
    );
  }

  CodexRpcRequest threadRollback({required String threadId, int numTurns = 1}) {
    _requireNonEmpty(threadId, 'threadId');
    if (numTurns <= 0) {
      throw ArgumentError.value(
        numTurns,
        'numTurns',
        'must be greater than zero',
      );
    }
    return request(
      'thread/rollback',
      params: <String, Object?>{'threadId': threadId, 'numTurns': numTurns},
    );
  }

  CodexRpcRequest threadNameSet({
    required String threadId,
    required String name,
  }) {
    _requireNonEmpty(threadId, 'threadId');
    _requireNonEmpty(name, 'name');
    return request(
      'thread/name/set',
      params: <String, Object?>{'threadId': threadId, 'name': name},
    );
  }

  CodexRpcRequest reviewStart({required String threadId}) {
    _requireNonEmpty(threadId, 'threadId');
    return request(
      'review/start',
      params: <String, Object?>{
        'threadId': threadId,
        'target': <String, Object?>{'type': 'uncommittedChanges'},
        'delivery': 'inline',
      },
    );
  }

  CodexRpcRequest threadGoalGet({required String threadId}) {
    _requireNonEmpty(threadId, 'threadId');
    return request(
      'thread/goal/get',
      params: <String, Object?>{'threadId': threadId},
    );
  }

  CodexRpcRequest threadGoalSet({
    required String threadId,
    String? objective,
    ThreadGoalStatus? status,
    int? tokenBudget,
  }) {
    _requireNonEmpty(threadId, 'threadId');
    if (tokenBudget != null && tokenBudget <= 0) {
      throw ArgumentError.value(
        tokenBudget,
        'tokenBudget',
        'must be greater than zero',
      );
    }
    return request(
      'thread/goal/set',
      params: <String, Object?>{
        'threadId': threadId,
        'objective': ?objective,
        'status': ?status?.wireValue,
        'tokenBudget': ?tokenBudget,
      },
    );
  }

  CodexRpcRequest threadGoalClear({required String threadId}) {
    _requireNonEmpty(threadId, 'threadId');
    return request(
      'thread/goal/clear',
      params: <String, Object?>{'threadId': threadId},
    );
  }

  CodexRpcRequest turnStart({
    required String threadId,
    required String text,
    List<PendingAttachment> attachments = const <PendingAttachment>[],
    String? model,
    String? effort,
    ApprovalMode approvalMode = ApprovalMode.requestApproval,
    SandboxChoice? sandbox,
    String? cwd,
  }) => turnStartWithInput(
    threadId: threadId,
    input: buildCodexUserInput(text, attachments),
    model: model,
    effort: effort,
    approvalMode: approvalMode,
    sandbox: sandbox,
    cwd: cwd,
  );

  CodexRpcRequest turnStartWithInput({
    required String threadId,
    required List<Map<String, Object?>> input,
    String? model,
    String? effort,
    ApprovalMode approvalMode = ApprovalMode.requestApproval,
    SandboxChoice? sandbox,
    String? cwd,
  }) {
    _requireNonEmpty(threadId, 'threadId');
    final sandboxChoice = sandbox ?? approvalMode.sandbox;
    return request(
      'turn/start',
      params: <String, Object?>{
        'threadId': threadId,
        'input': input,
        'approvalPolicy': approvalMode.approvalPolicy,
        'sandboxPolicy': <String, Object?>{'type': sandboxChoice.policyType},
        if (model?.isNotEmpty ?? false) 'model': model,
        if (effort?.isNotEmpty ?? false) 'effort': effort,
        if (cwd?.isNotEmpty ?? false) 'cwd': cwd,
      },
    );
  }

  CodexRpcRequest turnInterrupt({
    required String threadId,
    required String turnId,
  }) {
    _requireNonEmpty(threadId, 'threadId');
    _requireNonEmpty(turnId, 'turnId');
    return request(
      'turn/interrupt',
      params: <String, Object?>{'threadId': threadId, 'turnId': turnId},
    );
  }

  CodexRpcRequest turnSteer({
    required String threadId,
    required String turnId,
    required String text,
    List<PendingAttachment> attachments = const <PendingAttachment>[],
  }) {
    _requireNonEmpty(threadId, 'threadId');
    _requireNonEmpty(turnId, 'turnId');
    return request(
      'turn/steer',
      params: <String, Object?>{
        'threadId': threadId,
        'expectedTurnId': turnId,
        'input': buildCodexUserInput(text, attachments),
      },
    );
  }

  CodexInboundMessage? decodeLine(String line) =>
      _session._decodeLine(value, line);

  /// Applies a synchronous state update only while this scope is current.
  T? commit<T>(T Function() update) => isCurrent ? update() : null;

  /// Awaits work and drops its value if a reconnect happened in the meantime.
  Future<T?> guard<T>(Future<T> operation) async {
    final result = await operation;
    return isCurrent ? result : null;
  }
}

List<Map<String, Object?>> buildCodexUserInput(
  String text,
  List<PendingAttachment> attachments,
) => <Map<String, Object?>>[
  if (text.trim().isNotEmpty) <String, Object?>{'type': 'text', 'text': text},
  for (final attachment in attachments)
    if (attachment.mimeType.startsWith('image/'))
      <String, Object?>{'type': 'localImage', 'path': attachment.remotePath}
    else if (attachment.textContent != null)
      <String, Object?>{
        'type': 'text',
        'text': '文本附件 ${attachment.name}:\n${attachment.textContent}',
      }
    else
      <String, Object?>{
        'type': 'text',
        'text': '附件 ${attachment.name}: ${attachment.remotePath}',
      },
];

/// Domain conversion kept beside the wire codec so controllers do not invent
/// their own compatibility parsing.
abstract final class CodexPayloadParser {
  static List<AgentThread> parseThreads(Object? result) =>
      parseThreadList(result).threads;

  static CodexThreadListPage parseThreadList(Object? result) {
    final root = _asObjectMap(result);
    final threads =
        _payloadList(result, const <String>[
              'data',
              'threads',
              'items',
            ], maxItems: _maxThreadListItems)
            .map(_asObjectMap)
            .whereType<Map<String, Object?>>()
            .map(parseThread)
            .whereType<AgentThread>()
            .toList(growable: false);
    return CodexThreadListPage(
      threads: threads,
      nextCursor: _firstString(
        root ?? const <String, Object?>{},
        const <String>['nextCursor', 'next_cursor'],
      ),
      backwardsCursor: _firstString(
        root ?? const <String, Object?>{},
        const <String>[
          'backwardsCursor',
          'backwards_cursor',
          'previousCursor',
          'previous_cursor',
        ],
      ),
    );
  }

  static AgentThread? parseThread(Map<String, Object?> value) {
    final id = _firstString(value, const <String>[
      'id',
      'threadId',
      'thread_id',
    ], marker: '');
    if (id.isEmpty) return null;
    final preview = _firstString(value, const <String>[
      'preview',
      'summary',
      'lastMessage',
      'last_message',
    ]).trim();
    final cwd = _firstString(value, const <String>[
      'cwd',
      'workingDirectory',
      'working_directory',
    ]);
    final name = _firstString(value, const <String>['name', 'title']).trim();
    final explicitActiveTurn = _firstString(value, const <String>[
      'activeTurnId',
      'active_turn_id',
    ], marker: '');
    final activeTurnId = explicitActiveTurn.isNotEmpty
        ? explicitActiveTurn
        : _activeTurnId(value['turns']);
    final source = _sourceLabel(value['source']);
    final modelProvider = _firstString(value, const <String>[
      'modelProvider',
      'model_provider',
    ]);
    final status = _wireType(value['status']);
    return AgentThread(
      id: id,
      title: name.isNotEmpty
          ? name
          : _threadFallbackTitle(preview: preview, cwd: cwd),
      preview: preview,
      cwd: cwd,
      source: source.isNotEmpty
          ? source
          : _firstString(value, const <String>[
              'threadSource',
              'thread_source',
            ]),
      modelProvider: modelProvider,
      status: status.isNotEmpty ? status : 'idle',
      createdAt: _firstInt(value, const <String>['createdAt', 'created_at']),
      updatedAt: _firstInt(value, const <String>['updatedAt', 'updated_at']),
      cliVersion: _firstString(value, const <String>[
        'cliVersion',
        'cli_version',
      ]),
      activeTurnId: activeTurnId.isEmpty ? null : activeTurnId,
    );
  }

  static List<AgentModel> parseModels(Object? result) =>
      _payloadList(result, const <String>[
            'data',
            'models',
            'items',
          ], maxItems: _maxModelItems)
          .map(_asObjectMap)
          .whereType<Map<String, Object?>>()
          .map((value) {
            final id = _firstString(value, const <String>['id', 'model']);
            final model = _firstString(value, const <String>['model', 'id']);
            if (id.isEmpty) return null;
            return AgentModel(
              id: id,
              model: model,
              displayName: _firstString(value, const <String>[
                'displayName',
                'display_name',
                'model',
                'id',
              ]),
              description: _firstString(value, const <String>['description']),
              isDefault: _firstBool(value, const <String>[
                'isDefault',
                'is_default',
              ]),
              defaultEffort: _firstString(value, const <String>[
                'defaultReasoningEffort',
                'defaultEffort',
                'default_reasoning_effort',
              ]),
              efforts: _parseEfforts(
                value['supportedReasoningEfforts'] ??
                    value['supported_reasoning_efforts'] ??
                    value['efforts'],
              ),
              contextWindowTokens: _firstInt(value, const <String>[
                'contextWindowTokens',
                'context_window_tokens',
              ]),
              maxOutputTokens: _firstInt(value, const <String>[
                'maxOutputTokens',
                'max_output_tokens',
              ]),
              isCustom: _firstBool(value, const <String>[
                'isCustom',
                'is_custom',
              ]),
              apiProtocol: switch (_firstString(value, const <String>[
                'apiProtocol',
                'api_protocol',
              ])) {
                'chat_completions' => ModelApiProtocol.chatCompletions,
                'responses' => ModelApiProtocol.responses,
                _ => null,
              },
            );
          })
          .whereType<AgentModel>()
          .toList(growable: false);

  static CodexThreadSnapshot? parseThreadPayload(Object? result) {
    final root = _asObjectMap(result);
    if (root == null) return null;
    final threadObject = _asObjectMap(root['thread']) ?? root;
    final thread = parseThread(threadObject);
    if (thread == null) return null;
    return CodexThreadSnapshot(
      thread: thread,
      timeline: parseTimeline(threadObject),
      tokenUsage: parseTokenUsage(result),
    );
  }

  /// Parses the newest-first page returned by `thread/resume` and restores it
  /// to chronological order before building the domain timeline.
  static CodexThreadSnapshot? parseResumedThread(Object? result) {
    final root = _asObjectMap(result);
    if (root == null) return null;
    final rawThread = _asObjectMap(root['thread']) ?? root;
    final initialPage = _asObjectMap(root['initialTurnsPage']);
    // `thread.turns` is the legacy, chronological response shape. The paged
    // `initialTurnsPage.data` shape is newest-first because the request uses
    // `sortDirection: desc`; retain the legacy turns when a server includes an
    // empty/malformed page wrapper instead of silently dropping the transcript.
    final pageTurns = initialPage == null
        ? const <Object?>[]
        : _asList(initialPage['data'], maxItems: _maxTimelineTurns);
    final turns = pageTurns.isEmpty
        ? _asList(rawThread['turns'], maxItems: _maxTimelineTurns)
        : pageTurns.reversed.toList(growable: false);
    final subAgentCreatedAt = _subAgentCreatedAt(rawThread);
    final visibleTurns = _withoutInheritedSubAgentTurns(
      turns,
      subAgentCreatedAt,
    );
    final reachedInheritedHistory = visibleTurns.length != turns.length;
    final hydratedThread = Map<String, Object?>.from(rawThread)
      ..['turns'] = visibleTurns;
    final thread = parseThread(hydratedThread);
    if (thread == null) return null;
    final nextTurnsCursor = _firstString(
      initialPage ?? const <String, Object?>{},
      const <String>['nextCursor', 'next_cursor'],
      marker: '',
    ).trim();
    final activeTurn = visibleTurns.reversed
        .map(_asObjectMap)
        .whereType<Map<String, Object?>>()
        .firstWhere(
          (turn) => _wireType(turn['status']) == 'inProgress',
          orElse: () => const <String, Object?>{},
        );
    final activeTurnStartedAtMillis = _normalizeEpochMillis(
      _firstInt(activeTurn, const <String>['startedAt', 'started_at']),
    );
    return CodexThreadSnapshot(
      thread: thread,
      timeline: parseTimeline(hydratedThread),
      nextTurnsCursor: nextTurnsCursor.isEmpty || reachedInheritedHistory
          ? null
          : nextTurnsCursor,
      tokenUsage: parseTokenUsage(root),
      activeTurnStartedAtMillis: activeTurnStartedAtMillis,
      turnIds: List<String>.unmodifiable(
        visibleTurns
            .map(_asObjectMap)
            .whereType<Map<String, Object?>>()
            .map((turn) => _firstString(turn, const <String>['id'], marker: ''))
            .where((id) => id.isNotEmpty),
      ),
    );
  }

  static CodexTurnsPage parseTurnsPage(
    Object? result, {
    int? subAgentCreatedAt,
  }) {
    final root = _asObjectMap(result) ?? const <String, Object?>{};
    final rawTurns = _payloadList(root, const <String>[
      'data',
      'turns',
      'items',
    ], maxItems: _maxTimelineTurns);
    final visibleTurns = _withoutInheritedSubAgentTurns(
      rawTurns,
      subAgentCreatedAt,
    );
    final reachedInheritedHistory = visibleTurns.length != rawTurns.length;
    final turns = visibleTurns.reversed.toList(growable: false);
    final timeline = parseTimeline(<String, Object?>{'turns': turns});
    final nextCursor = _firstString(root, const <String>[
      'nextCursor',
      'next_cursor',
    ], marker: '').trim();
    return CodexTurnsPage(
      timeline: timeline,
      nextCursor: nextCursor.isEmpty || reachedInheritedHistory
          ? null
          : nextCursor,
      turnIds: List<String>.unmodifiable(
        turns
            .map(_asObjectMap)
            .whereType<Map<String, Object?>>()
            .map((turn) => _firstString(turn, const <String>['id'], marker: ''))
            .where((id) => id.isNotEmpty),
      ),
    );
  }

  static TokenUsage? parseTokenUsage(Object? result) {
    final root = _asObjectMap(result);
    if (root == null) return null;
    final usage =
        _asObjectMap(root['tokenUsage']) ??
        _asObjectMap(_asObjectMap(root['thread'])?['tokenUsage']);
    if (usage == null) return null;

    TokenUsageBreakdown breakdown(Object? value) {
      final object = _asObjectMap(value) ?? const <String, Object?>{};
      return TokenUsageBreakdown(
        cachedInputTokens: _firstInt(object, const <String>[
          'cachedInputTokens',
          'cached_input_tokens',
        ]),
        inputTokens: _firstInt(object, const <String>[
          'inputTokens',
          'input_tokens',
        ]),
        outputTokens: _firstInt(object, const <String>[
          'outputTokens',
          'output_tokens',
        ]),
        reasoningOutputTokens: _firstInt(object, const <String>[
          'reasoningOutputTokens',
          'reasoning_output_tokens',
        ]),
        totalTokens: _firstInt(object, const <String>[
          'totalTokens',
          'total_tokens',
        ]),
      );
    }

    return TokenUsage(
      last: breakdown(usage['last']),
      total: breakdown(usage['total']),
      modelContextWindow: _firstInt(usage, const <String>[
        'modelContextWindow',
        'model_context_window',
      ]),
    );
  }

  static ThreadGoal? parseThreadGoal(
    Object? value, {
    String fallbackThreadId = '',
  }) {
    final goal = _asObjectMap(value);
    if (goal == null) return null;
    final parsedThreadId = _firstString(goal, const <String>[
      'threadId',
      'thread_id',
    ], marker: '');
    return ThreadGoal(
      threadId: parsedThreadId.isEmpty ? fallbackThreadId : parsedThreadId,
      objective: _firstString(goal, const <String>[
        'objective',
        'goal',
      ], maxChars: codexMaxTimelineMetadataChars),
      status: ThreadGoalStatus.fromWire(
        _firstString(goal, const <String>['status'], marker: ''),
      ),
      createdAt: _firstInt(goal, const <String>['createdAt', 'created_at']),
      updatedAt: _firstInt(goal, const <String>['updatedAt', 'updated_at']),
      timeUsedSeconds: _firstInt(goal, const <String>[
        'timeUsedSeconds',
        'time_used_seconds',
      ]),
      tokensUsed: _firstInt(goal, const <String>['tokensUsed', 'tokens_used']),
      tokenBudget: _firstNullableInt(goal, const <String>[
        'tokenBudget',
        'token_budget',
      ]),
    );
  }

  static List<TimelineEntry> parseTimeline(Map<String, Object?> thread) {
    final result = <TimelineEntry>[];
    final historicalTurnStatuses = <String, String>{};
    for (final turnValue in _asList(
      thread['turns'],
      maxItems: _maxTimelineTurns,
    )) {
      if (result.length >= _maxTimelineEntries) break;
      final turn = _asObjectMap(turnValue);
      if (turn == null) continue;
      final turnId = _firstString(turn, const <String>[
        'id',
        'turnId',
      ], marker: '');
      final turnStatus = _wireType(turn['status']);
      if (turnId.isNotEmpty &&
          turnStatus.isNotEmpty &&
          turnStatus != 'inProgress') {
        historicalTurnStatuses[turnId] = turnStatus;
      }
      final collabItems = <Map<String, Object?>>[];
      for (final itemValue in _asList(
        turn['items'],
        maxItems: _maxTimelineItemsPerTurn,
      )) {
        if (result.length >= _maxTimelineEntries) break;
        final item = _asObjectMap(itemValue);
        if (item == null) continue;
        final entry = parseItem(item, turnId: turnId);
        if (entry != null) result.add(entry);
        if (_firstString(item, const <String>['type']) ==
            'collabAgentToolCall') {
          collabItems.add(item);
        }
      }
      for (final item in collabItems) {
        _applySubAgentStates(result, item, turnId);
      }
    }
    return List<TimelineEntry>.unmodifiable(
      result.map((entry) {
        if (entry.kind != TimelineKind.subAgent ||
            !_isActiveSubAgentStatus(entry.status)) {
          return entry;
        }
        final terminal = _subAgentStatusForTurn(
          historicalTurnStatuses[entry.turnId] ?? '',
        );
        return terminal == null ? entry : entry.copyWith(status: terminal);
      }),
    );
  }

  static TimelineEntry? parseItem(
    Map<String, Object?> item, {
    required String turnId,
  }) {
    final type = _firstString(item, const <String>['type']);
    if (type.isEmpty) return null;
    final parsedId = _firstString(item, const <String>['id'], marker: '');
    final id = parsedId.isNotEmpty ? parsedId : 'item-${item.hashCode}';
    final boundedTurnId = _bounded(turnId, codexMaxThreadFieldChars, '');
    return switch (type) {
      'userMessage' => _parseUserMessage(
        item: item,
        id: id,
        turnId: boundedTurnId,
      ),
      'agentMessage' => TimelineEntry(
        id: id,
        kind: TimelineKind.agentMessage,
        text: _sanitizedAgentText(
          _firstString(item, const <String>[
            'text',
          ], maxChars: codexMaxTimelineTextChars),
        ),
        status: _firstString(item, const <String>['phase', 'status']),
        turnId: boundedTurnId,
      ),
      'reasoning' => _parseReasoningItem(
        item: item,
        id: id,
        turnId: boundedTurnId,
      ),
      'plan' => TimelineEntry(
        id: id,
        kind: TimelineKind.plan,
        title: '计划',
        text: _firstString(item, const <String>[
          'text',
        ], maxChars: codexMaxTimelineTextChars),
        turnId: boundedTurnId,
      ),
      'commandExecution' => TimelineEntry(
        id: id,
        kind: TimelineKind.command,
        title: '终端',
        command: _firstString(item, const <String>[
          'command',
        ], maxChars: codexMaxTimelineTextChars),
        cwd: _firstString(item, const <String>['cwd']),
        output: _firstString(
          item,
          const <String>['aggregatedOutput', 'output'],
          maxChars: codexMaxCommandOutputChars,
          marker: codexOutputTruncationMarker,
        ),
        status: _firstString(item, const <String>['status']),
        turnId: boundedTurnId,
      ),
      'fileChange' => TimelineEntry(
        id: id,
        kind: TimelineKind.fileChange,
        title: '已编辑文件',
        status: _firstString(item, const <String>['status']),
        changes: _parseChanges(item['changes']),
        turnId: boundedTurnId,
      ),
      'subAgentActivity' => TimelineEntry(
        id: id,
        kind: TimelineKind.subAgent,
        text: _firstString(item, const <String>[
          'message',
          'summary',
          'description',
        ], maxChars: codexMaxTimelineTextChars),
        status: _subAgentStatus(_firstString(item, const <String>['kind'])),
        subAgentPath: _firstString(item, const <String>['agentPath']),
        subAgentThreadId: _firstString(item, const <String>[
          'agentThreadId',
        ], marker: ''),
        subAgentActivity: _firstString(item, const <String>['kind']),
        turnId: boundedTurnId,
      ),
      'enteredReviewMode' || 'exitedReviewMode' => TimelineEntry(
        id: id,
        kind: TimelineKind.review,
        title: type == 'enteredReviewMode' ? '开始审核' : '审核完成',
        text: _firstString(item, const <String>[
          'review',
        ], maxChars: codexMaxTimelineTextChars),
        turnId: boundedTurnId,
      ),
      'contextCompaction' => TimelineEntry(
        id: id,
        kind: TimelineKind.notice,
        text: '上下文已压缩',
        turnId: boundedTurnId,
      ),
      'webSearch' || 'web_search' || 'webSearchCall' || 'web_search_call' =>
        _parseToolItem(item: item, id: id, turnId: boundedTurnId),
      'imageView' || 'imageGeneration' || 'sleep' => TimelineEntry(
        id: id,
        kind: TimelineKind.tool,
        title: switch (type) {
          'imageView' => '查看了图片',
          'imageGeneration' => '生成图片',
          _ => '等待',
        },
        text: _firstString(item, const <String>[
          'path',
          'result',
        ], maxChars: codexMaxTimelineTextChars),
        status: _firstString(item, const <String>['status']),
        turnId: boundedTurnId,
      ),
      'mcpToolCall' || 'dynamicToolCall' || 'collabAgentToolCall' =>
        _parseToolItem(item: item, id: id, turnId: boundedTurnId),
      _ =>
        _isWebSearchItem(item)
            ? _parseToolItem(item: item, id: id, turnId: boundedTurnId)
            : TimelineEntry(
                id: id,
                kind: TimelineKind.notice,
                title: type,
                text: _jsonPreview(
                  item,
                  maxChars: codexMaxMetadataPreviewChars,
                ),
                turnId: boundedTurnId,
              ),
    };
  }
}

TimelineEntry _parseToolItem({
  required Map<String, Object?> item,
  required String id,
  required String turnId,
}) {
  final isWebSearch = _isWebSearchItem(item);
  final tool = _firstString(item, const <String>['tool', 'name'], marker: '');
  final status = _firstString(item, const <String>['status'], marker: '');
  return TimelineEntry(
    id: id,
    kind: TimelineKind.tool,
    title: isWebSearch ? '网页搜索' : (tool.isNotEmpty ? tool : '工具调用'),
    text: isWebSearch
        ? _webSearchQuery(item)
        : _jsonPreview(item['result'], maxChars: codexMaxTimelineTextChars),
    status: status.isNotEmpty ? status : (isWebSearch ? 'completed' : ''),
    turnId: turnId,
  );
}

bool _isWebSearchItem(Map<String, Object?> item) {
  final type = _normalizedSearchName(
    _firstString(item, const <String>['type'], marker: ''),
  );
  if (type == 'websearch' ||
      type == 'web_search' ||
      type == 'websearchcall' ||
      type == 'web_search_call') {
    return true;
  }
  if (type.contains('websearch') || type.contains('web_search')) return true;
  final tool = _normalizedSearchName(
    _firstString(item, const <String>['tool', 'name'], marker: ''),
  );
  if (tool.contains('websearch') || tool.contains('web_search')) return true;
  for (final key in const <String>['result', 'results', 'output', 'content']) {
    if (_looksLikeWebSearchResult(item[key])) return true;
  }
  return false;
}

String _normalizedSearchName(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');

bool _looksLikeWebSearchResult(Object? value, [int depth = 0]) {
  if (depth > 3) return false;
  if (value is List) {
    for (final entry in value.take(16)) {
      if (_looksLikeWebSearchResult(entry, depth + 1)) return true;
    }
    return false;
  }
  final object = _asObjectMap(value);
  if (object == null) return false;
  final keys = object.keys.map((key) => key.toLowerCase()).toSet();
  final type = _normalizedSearchName(
    _firstString(object, const <String>['type'], marker: ''),
  );
  if (type == 'text_result' ||
      type == 'websearch' ||
      type == 'web_search_call') {
    return true;
  }
  if (keys.contains('ref_id') &&
      (keys.contains('snippet') ||
          keys.contains('url') ||
          keys.contains('domain'))) {
    return true;
  }
  for (final key in const <String>[
    'result',
    'results',
    'output',
    'content',
    'data',
  ]) {
    if (object.containsKey(key) &&
        _looksLikeWebSearchResult(object[key], depth + 1)) {
      return true;
    }
  }
  return false;
}

String _webSearchQuery(Map<String, Object?> item) {
  final direct = _firstString(
    item,
    const <String>['query', 'searchQuery', 'search_query'],
    maxChars: codexMaxTimelineTextChars,
    marker: '',
  );
  if (direct.isNotEmpty) return direct;
  final action = _asObjectMap(item['action']);
  final nested = action == null
      ? ''
      : _firstString(
          action,
          const <String>['query', 'q'],
          maxChars: codexMaxTimelineTextChars,
          marker: '',
        );
  if (nested.isNotEmpty) return nested;
  final queries =
      item['queries'] ?? (action == null ? null : action['queries']);
  for (final entry in _asList(queries, maxItems: 4)) {
    if (entry is String && entry.trim().isNotEmpty) {
      return _bounded(
        entry.trim(),
        codexMaxTimelineTextChars,
        codexTextTruncationMarker,
      );
    }
    final object = _asObjectMap(entry);
    final query = object == null
        ? ''
        : _firstString(
            object,
            const <String>['query', 'q'],
            maxChars: codexMaxTimelineTextChars,
            marker: '',
          );
    if (query.isNotEmpty) return query;
  }
  return '已完成网页搜索';
}

final class CodexThreadSnapshot {
  const CodexThreadSnapshot({
    required this.thread,
    required this.timeline,
    this.nextTurnsCursor,
    this.tokenUsage,
    this.activeTurnStartedAtMillis,
    this.turnIds = const <String>[],
  });

  final AgentThread thread;
  final List<TimelineEntry> timeline;
  final String? nextTurnsCursor;
  final TokenUsage? tokenUsage;
  final int? activeTurnStartedAtMillis;
  final List<String> turnIds;
}

final class CodexTurnsPage {
  const CodexTurnsPage({
    required this.timeline,
    this.nextCursor,
    this.turnIds = const <String>[],
  });

  final List<TimelineEntry> timeline;
  final String? nextCursor;
  final List<String> turnIds;
}

final class CodexThreadListPage {
  const CodexThreadListPage({
    required this.threads,
    this.nextCursor,
    this.backwardsCursor,
  });

  final List<AgentThread> threads;
  final String? nextCursor;
  final String? backwardsCursor;

  bool get hasNextPage => nextCursor?.isNotEmpty ?? false;
}

void _requireNonEmpty(String value, String name) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, name, 'must not be empty');
  }
}

CodexRequestId? _parseRequestId(Object? value) =>
    CodexRequestId.tryParse(value);

Map<String, Object?>? _paramsObject(Object? value) => switch (value) {
  null => const <String, Object?>{},
  _ => _asObjectMap(value),
};

Map<String, Object?>? _asObjectMap(Object? value) {
  if (value is! Map) return null;
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (result.length >= _maxObjectEntries) break;
    if (entry.key is! String) return null;
    result[entry.key as String] = entry.value;
  }
  return result;
}

int? _strictInt(Object? value) => value is int ? value : null;

List<Object?> _asList(Object? value, {int maxItems = _maxPayloadListItems}) {
  if (value is! List || maxItems <= 0) return const <Object?>[];
  final length = value.length < maxItems ? value.length : maxItems;
  return List<Object?>.generate(
    length,
    (index) => value[index],
    growable: false,
  );
}

List<Object?> _payloadList(
  Object? value,
  List<String> compatibleKeys, {
  int maxItems = _maxPayloadListItems,
  int depth = 0,
}) {
  if (depth >= _maxPayloadDepth) return const <Object?>[];
  if (value is List) return _asList(value, maxItems: maxItems);
  final object = _asObjectMap(value);
  if (object == null) return const <Object?>[];
  for (final key in compatibleKeys) {
    final candidate = object[key];
    if (candidate is List) return _asList(candidate, maxItems: maxItems);
    if (candidate is Map) {
      final nested = _payloadList(
        candidate,
        compatibleKeys,
        maxItems: maxItems,
        depth: depth + 1,
      );
      if (nested.isNotEmpty) return nested;
    }
  }
  final nestedResult = object['result'];
  return identical(nestedResult, value)
      ? const <Object?>[]
      : _payloadList(
          nestedResult,
          compatibleKeys,
          maxItems: maxItems,
          depth: depth + 1,
        );
}

String _firstString(
  Map<String, Object?> value,
  List<String> keys, {
  int maxChars = codexMaxThreadFieldChars,
  String marker = codexTextTruncationMarker,
}) {
  for (final key in keys) {
    final candidate = value[key];
    if (candidate is String && candidate.isNotEmpty) {
      return _bounded(candidate, maxChars, marker);
    }
  }
  return '';
}

int _firstInt(Map<String, Object?> value, List<String> keys) {
  for (final key in keys) {
    final candidate = value[key];
    if (candidate is int) return candidate;
    if (candidate is num && candidate.isFinite) return candidate.toInt();
    if (candidate is String) {
      final parsed = int.tryParse(candidate);
      if (parsed != null) return parsed;
    }
  }
  return 0;
}

int? _firstNullableInt(Map<String, Object?> value, List<String> keys) {
  for (final key in keys) {
    if (!value.containsKey(key) || value[key] == null) continue;
    final candidate = value[key];
    if (candidate is int) return candidate;
    if (candidate is num && candidate.isFinite) return candidate.toInt();
    if (candidate is String) {
      final parsed = int.tryParse(candidate);
      if (parsed != null) return parsed;
    }
  }
  return null;
}

bool _firstBool(Map<String, Object?> value, List<String> keys) {
  for (final key in keys) {
    final candidate = value[key];
    if (candidate is bool) return candidate;
  }
  return false;
}

String _wireType(Object? value) {
  if (value is String) {
    return _bounded(value, codexMaxThreadFieldChars, codexTextTruncationMarker);
  }
  final object = _asObjectMap(value);
  if (object == null) return '';
  return _firstString(object, const <String>['type', 'status']);
}

String _sourceLabel(Object? value) {
  if (value is String) {
    return _bounded(value, codexMaxThreadFieldChars, codexTextTruncationMarker);
  }
  final object = _asObjectMap(value);
  if (object == null) return '';
  final custom = _firstString(object, const <String>['custom', 'type']);
  if (custom.isNotEmpty) return custom;
  if (object.containsKey('subAgent') || object.containsKey('sub_agent')) {
    return 'subAgent';
  }
  return _jsonPreview(value, maxChars: codexMaxMetadataPreviewChars);
}

int? _subAgentCreatedAt(Map<String, Object?> thread) {
  final threadSource = _firstString(thread, const <String>[
    'threadSource',
    'thread_source',
  ], marker: '');
  final source = _sourceLabel(thread['source']);
  final isSubAgent =
      threadSource.toLowerCase() == 'subagent' ||
      source.toLowerCase() == 'subagent';
  if (!isSubAgent) return null;
  final createdAt = _firstInt(thread, const <String>[
    'createdAt',
    'created_at',
  ]);
  return createdAt > 0 ? createdAt : null;
}

List<Object?> _withoutInheritedSubAgentTurns(
  List<Object?> turns,
  int? subAgentCreatedAt,
) {
  final cutoff = subAgentCreatedAt;
  if (cutoff == null || cutoff <= 0) return turns;
  return turns
      .where((value) {
        final turn = _asObjectMap(value);
        if (turn == null) return true;
        final startedAt = _firstInt(turn, const <String>[
          'startedAt',
          'started_at',
        ]);
        // Older servers can omit startedAt. Keep those turns rather than
        // discarding valid child work.
        return startedAt == 0 || startedAt >= cutoff;
      })
      .toList(growable: false);
}

String _threadFallbackTitle({required String preview, required String cwd}) {
  final previewLine = preview.split('\n').first.trim();
  if (previewLine.isNotEmpty) {
    return previewLine.length <= 64
        ? previewLine
        : previewLine.substring(0, 64);
  }
  final segments = cwd.split('/').where((part) => part.isNotEmpty).toList();
  return segments.isEmpty ? '未命名任务' : segments.last;
}

String _activeTurnId(Object? turnsValue) {
  if (turnsValue is! List) return '';
  final firstIndex = turnsValue.length > _maxTimelineTurns
      ? turnsValue.length - _maxTimelineTurns
      : 0;
  for (var index = turnsValue.length - 1; index >= firstIndex; index -= 1) {
    final turn = _asObjectMap(turnsValue[index]);
    if (turn == null) continue;
    final status = _wireType(turn['status']);
    if (status == 'inProgress' ||
        status == 'in_progress' ||
        status == 'running') {
      return _firstString(turn, const <String>[
        'id',
        'turnId',
        'turn_id',
      ], marker: '');
    }
  }
  return '';
}

List<String> _parseEfforts(Object? value) =>
    _asList(value, maxItems: _maxReasoningParts)
        .map((entry) {
          if (entry is String) {
            return _bounded(
              entry,
              codexMaxThreadFieldChars,
              codexTextTruncationMarker,
            );
          }
          final object = _asObjectMap(entry);
          return object == null
              ? ''
              : _firstString(object, const <String>[
                  'reasoningEffort',
                  'effort',
                  'reasoning_effort',
                ]);
        })
        .where((entry) => entry.isNotEmpty)
        .toList(growable: false);

TimelineEntry _parseReasoningItem({
  required Map<String, Object?> item,
  required String id,
  required String turnId,
}) {
  final summary = _reasoningParts(item['summary']);
  final content = _reasoningParts(item['content']);
  return TimelineEntry(
    id: id,
    kind: TimelineKind.reasoning,
    title: '思考过程',
    text: _bounded(
      summary.where((part) => part.isNotEmpty).join('\n'),
      codexMaxTimelineTextChars,
      codexTextTruncationMarker,
    ),
    reasoningSummary: summary,
    reasoningContent: content,
    turnId: turnId,
  );
}

TimelineEntry _parseUserMessage({
  required Map<String, Object?> item,
  required String id,
  required String turnId,
}) {
  final textParts = <String>[];
  final attachments = <MessageAttachment>[];
  for (final entry in _asList(
    item['content'],
    maxItems: _maxTimelineItemsPerTurn,
  )) {
    final content = _asObjectMap(entry);
    if (content == null) continue;
    switch (_firstString(content, const <String>['type'])) {
      case 'text':
        final parsed = _parseUserMessageText(
          _firstString(content, const <String>[
            'text',
          ], maxChars: codexMaxTimelineTextChars),
        );
        if (parsed.text.isNotEmpty) textParts.add(parsed.text);
        attachments.addAll(parsed.attachments);
        break;
      case 'localImage':
        final remotePath = _firstString(content, const <String>['path']);
        if (remotePath.isNotEmpty) {
          final name = remotePath.split('/').last.trim();
          attachments.add(
            MessageAttachment(
              name: name.isEmpty ? '图片' : name,
              remotePath: remotePath,
              mimeType: 'image/*',
            ),
          );
        }
        break;
    }
  }
  return TimelineEntry(
    id: id,
    kind: TimelineKind.userMessage,
    text: _bounded(
      textParts.join('\n'),
      codexMaxTimelineTextChars,
      codexTextTruncationMarker,
    ),
    attachments: List<MessageAttachment>.unmodifiable(attachments),
    turnId: turnId,
  );
}

_ParsedUserMessageText _parseUserMessageText(String text) {
  final markers = _transportAttachmentMarker.allMatches(text).toList();
  if (markers.isEmpty) {
    return _ParsedUserMessageText(text: text);
  }

  final visible = StringBuffer();
  final attachments = <MessageAttachment>[];
  var cursor = 0;
  for (var index = 0; index < markers.length; index++) {
    final marker = markers[index];
    if (marker.start > cursor) {
      visible.write(text.substring(cursor, marker.start));
    }

    final inlineText = marker.group(1)?.isNotEmpty == true;
    final name = (marker.group(inlineText ? 2 : 4) ?? '').trim();
    if (inlineText) {
      if (name.isNotEmpty) {
        attachments.add(MessageAttachment(name: name, mimeType: 'text/plain'));
      }
      cursor = index + 1 < markers.length
          ? markers[index + 1].start
          : text.length;
    } else {
      final remotePath = (marker.group(5) ?? '').trim();
      if (name.isNotEmpty && remotePath.isNotEmpty) {
        attachments.add(MessageAttachment(name: name, remotePath: remotePath));
      }
      cursor = marker.end;
    }
  }
  if (cursor < text.length) visible.write(text.substring(cursor));
  return _ParsedUserMessageText(
    text: visible.toString().trim(),
    attachments: List<MessageAttachment>.unmodifiable(attachments),
  );
}

class _ParsedUserMessageText {
  const _ParsedUserMessageText({
    required this.text,
    this.attachments = const <MessageAttachment>[],
  });

  final String text;
  final List<MessageAttachment> attachments;
}

final RegExp _transportAttachmentMarker = RegExp(
  r'[\t ]*(文本附件) ([^\r\n:]+):\r?\n|^[\t ]*(附件) ([^\r\n:]+):[\t ]+([^\r\n]+)',
  multiLine: true,
);

List<String> _reasoningParts(Object? value) {
  var remaining = codexMaxTimelineTextChars;
  final result = <String>[];
  for (final entry in _asList(value, maxItems: _maxReasoningParts)) {
    final object = _asObjectMap(entry);
    final raw = entry is String
        ? entry
        : object == null
        ? ''
        : _firstString(object, const <String>[
            'text',
          ], maxChars: codexMaxTimelineTextChars);
    if (raw.isEmpty || remaining <= 0 || isCodexRawWebSearchPayload(raw)) {
      continue;
    }
    final part = _bounded(raw, remaining, codexTextTruncationMarker);
    result.add(part);
    remaining -= part.length;
    if (part.endsWith(codexTextTruncationMarker)) break;
  }
  return List<String>.unmodifiable(result);
}

String _sanitizedAgentText(String text) =>
    isCodexRawWebSearchPayload(text) ? '' : text;

List<FileChange> _parseChanges(Object? value) {
  var remainingDiffChars = codexMaxDiffChars;
  final result = <FileChange>[];
  for (final entry in _asList(value, maxItems: _maxFileChanges)) {
    final change = _asObjectMap(entry);
    if (change == null) continue;
    final diff = remainingDiffChars <= 0
        ? ''
        : _firstString(
            change,
            const <String>['diff'],
            maxChars: remainingDiffChars,
            marker: codexDiffTruncationMarker,
          );
    remainingDiffChars -= diff.length;
    result.add(
      FileChange(
        path: _firstString(change, const <String>['path']),
        kind: _wireType(change['kind']),
        diff: diff,
      ),
    );
  }
  return List<FileChange>.unmodifiable(result);
}

String _subAgentStatus(String activity) => switch (activity) {
  'started' || 'interacted' => 'running',
  'interrupted' => 'interrupted',
  _ => 'unknown',
};

const Set<String> _activeSubAgentStatuses = <String>{
  'pendingInit',
  'running',
  'inProgress',
  'started',
  'interacted',
  'unknown',
};

const Set<String> _knownSubAgentStatuses = <String>{
  'pendingInit',
  'running',
  'interrupted',
  'completed',
  'errored',
  'shutdown',
  'notFound',
};

bool _isActiveSubAgentStatus(String status) =>
    _activeSubAgentStatuses.contains(status);

String? _subAgentStatusForTurn(String turnStatus) => switch (turnStatus) {
  '' || 'inProgress' => null,
  'interrupted' => 'interrupted',
  'failed' || 'systemError' => 'errored',
  _ => 'completed',
};

void _applySubAgentStates(
  List<TimelineEntry> entries,
  Map<String, Object?> collabItem,
  String turnId,
) {
  final rawStates = _asObjectMap(
    collabItem['agentsStates'] ?? collabItem['agents_states'],
  );
  if (rawStates == null || rawStates.isEmpty) return;
  final states = <String, String>{};
  for (final entry in rawStates.entries) {
    final value = _asObjectMap(entry.value);
    final status = value == null
        ? ''
        : _firstString(value, const <String>['status'], marker: '');
    if (entry.key.isNotEmpty && _knownSubAgentStatuses.contains(status)) {
      states[entry.key] = status;
    }
  }
  if (states.isEmpty) return;
  for (var index = 0; index < entries.length; index++) {
    final entry = entries[index];
    if (entry.kind != TimelineKind.subAgent ||
        (turnId.isNotEmpty && entry.turnId != turnId)) {
      continue;
    }
    final status = states[entry.subAgentThreadId];
    if (status == null || status.isEmpty) continue;
    final entryIsActive = _isActiveSubAgentStatus(entry.status);
    if (_isActiveSubAgentStatus(status)) {
      if (entryIsActive) entries[index] = entry.copyWith(status: status);
    } else if (entryIsActive) {
      entries[index] = entry.copyWith(status: status);
    }
  }
}

String _jsonPreview(
  Object? value, {
  int maxChars = codexMaxMetadataPreviewChars,
}) {
  if (value == null || maxChars <= 0) return '';
  final result = StringBuffer();
  var truncated = false;

  void append(String text) {
    if (text.isEmpty) return;
    final remaining = maxChars - result.length;
    if (remaining <= 0) {
      truncated = true;
      return;
    }
    if (text.length <= remaining) {
      result.write(text);
      return;
    }
    result.write(text.substring(0, remaining));
    truncated = true;
  }

  void appendValue(Object? element, int depth) {
    if (result.length >= maxChars) {
      truncated = true;
      return;
    }
    if (depth >= _maxPayloadDepth && (element is List || element is Map)) {
      append(element is List ? '[...]' : '{...}');
      return;
    }
    switch (element) {
      case null:
        append('null');
      case String():
        append(element);
      case num() || bool():
        append(element.toString());
      case List():
        append('[');
        final count = element.length < 32 ? element.length : 32;
        for (var index = 0; index < count; index += 1) {
          if (index > 0) append(', ');
          appendValue(element[index], depth + 1);
        }
        if (element.length > count) append(', ...');
        append(']');
      case Map():
        append('{');
        var index = 0;
        for (final entry in element.entries) {
          if (index >= 32) {
            append(', ...');
            break;
          }
          if (index > 0) append(', ');
          append(entry.key.toString());
          append(': ');
          appendValue(entry.value, depth + 1);
          index += 1;
        }
        append('}');
      default:
        append(element.toString());
    }
  }

  appendValue(value, 0);
  final preview = result.toString();
  return truncated
      ? _replaceTailWithMarker(preview, maxChars, codexTextTruncationMarker)
      : preview;
}

String _bounded(String value, int limit, String marker) {
  if (limit <= 0) return '';
  if (value.length <= limit) return value;
  final markerLength = marker.length < limit ? marker.length : limit;
  final contentLength = limit - markerLength;
  return '${value.substring(0, contentLength)}'
      '${marker.substring(0, markerLength)}';
}

String _replaceTailWithMarker(String value, int limit, String marker) {
  if (limit <= 0) return '';
  final markerLength = marker.length < limit ? marker.length : limit;
  final contentLength = limit - markerLength;
  final availableContent = value.length < contentLength
      ? value.length
      : contentLength;
  return '${value.substring(0, availableContent)}'
      '${marker.substring(0, markerLength)}';
}

int? _normalizeEpochMillis(int timestamp) {
  if (timestamp <= 0) return null;
  return timestamp < 100000000000 ? timestamp * 1000 : timestamp;
}

final class CodexJsonRpcEnvelopeHint {
  const CodexJsonRpcEnvelopeHint({this.id, required this.hasMethod});

  final CodexRequestId? id;
  final bool hasMethod;
}

/// Reads only complete top-level fields retained from an oversized JSON line.
/// The full record cannot be decoded because its tail was deliberately
/// discarded, so this bounded scanner recognizes just `id` and `method`.
CodexJsonRpcEnvelopeHint inspectCodexJsonRpcEnvelopePrefix(String value) {
  var index = _skipJsonWhitespace(value, 0);
  if (_characterAt(value, index) != '{') {
    return const CodexJsonRpcEnvelopeHint(hasMethod: false);
  }
  index += 1;
  CodexRequestId? id;
  var hasMethod = false;
  while (index < value.length) {
    index = _skipJsonWhitespace(value, index);
    final current = _characterAt(value, index);
    if (current == '}') break;
    if (current == ',') {
      index += 1;
      continue;
    }
    final key = _parseJsonString(value, index);
    if (key == null) break;
    index = _skipJsonWhitespace(value, key.nextIndex);
    if (_characterAt(value, index) != ':') break;
    index = _skipJsonWhitespace(value, index + 1);
    if (key.value == 'method') hasMethod = true;
    if (key.value == 'id') id = _parseJsonRpcId(value, index);
    final next = _skipJsonValue(value, index);
    if (next == null) break;
    index = next;
  }
  return CodexJsonRpcEnvelopeHint(id: id, hasMethod: hasMethod);
}

({String value, int nextIndex})? _parseJsonString(String value, int start) {
  if (_characterAt(value, start) != '"') return null;
  var escaped = false;
  for (var index = start + 1; index < value.length; index += 1) {
    final character = value[index];
    if (!escaped && character == '"') {
      final token = value.substring(start, index + 1);
      try {
        final decoded = jsonDecode(token);
        return decoded is String
            ? (value: decoded, nextIndex: index + 1)
            : null;
      } on FormatException {
        return null;
      }
    }
    if (character == '\\') {
      escaped = !escaped;
    } else {
      escaped = false;
    }
  }
  return null;
}

CodexRequestId? _parseJsonRpcId(String value, int start) {
  final stringId = _parseJsonString(value, start);
  if (stringId != null) return CodexRequestId.string(stringId.value);
  var end = start;
  while (end < value.length &&
      value[end] != ',' &&
      value[end] != '}' &&
      value[end].trim().isNotEmpty) {
    end += 1;
  }
  final token = value.substring(start, end);
  if (!RegExp(r'^-?(0|[1-9][0-9]*)$').hasMatch(token)) return null;
  final parsed = num.tryParse(token);
  return parsed == null ? null : CodexRequestId.number(parsed);
}

int _skipJsonWhitespace(String value, int start) {
  var index = start;
  while (index < value.length && value[index].trim().isEmpty) {
    index += 1;
  }
  return index;
}

int? _skipJsonValue(String value, int start) {
  final first = _characterAt(value, start);
  if (first == null) return null;
  if (first == '"') return _parseJsonString(value, start)?.nextIndex;
  if (first != '{' && first != '[') {
    var index = start;
    while (index < value.length && value[index] != ',' && value[index] != '}') {
      index += 1;
    }
    return index;
  }
  final closes = <String>[first == '{' ? '}' : ']'];
  var inString = false;
  var escaped = false;
  for (var index = start + 1; index < value.length; index += 1) {
    final character = value[index];
    if (inString) {
      if (!escaped && character == '"') inString = false;
      if (character == '\\') {
        escaped = !escaped;
      } else {
        escaped = false;
      }
      continue;
    }
    switch (character) {
      case '"':
        inString = true;
      case '{':
        closes.add('}');
      case '[':
        closes.add(']');
      case '}' || ']':
        if (closes.isEmpty || closes.removeLast() != character) return null;
        if (closes.isEmpty) return index + 1;
    }
  }
  return null;
}

String? _characterAt(String value, int index) =>
    index >= 0 && index < value.length ? value[index] : null;
