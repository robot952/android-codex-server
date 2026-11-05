import 'package:codex_remote/src/domain/models.dart';

/// A provider configuration saved for one server and agent lane.
///
/// Instances containing [apiKey] should only be persisted in secure storage.
class AgentProviderProfile {
  const AgentProviderProfile({
    required this.id,
    required this.serverProfileId,
    required this.agent,
    required this.name,
    this.baseUrl = '',
    this.apiKey = '',
    this.proxyUrl = '',
    this.defaultModel = '',
    this.defaultSubagentModel = '',
    this.defaultReasoningEffort = '',
    this.websocketPolicy,
    this.contextWindowTokens = 0,
    this.preserveCurrentProvider = true,
  });

  final String id;
  final String serverProfileId;
  final AgentKind agent;
  final String name;
  final String baseUrl;
  final String apiKey;
  final String proxyUrl;
  final String defaultModel;
  final String defaultSubagentModel;
  final String defaultReasoningEffort;
  final String? websocketPolicy;
  final int contextWindowTokens;
  final bool preserveCurrentProvider;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'serverProfileId': serverProfileId,
    'agent': agent.storageKeySegment,
    'name': name,
    'baseUrl': baseUrl,
    'apiKey': apiKey,
    'proxyUrl': proxyUrl,
    'defaultModel': defaultModel,
    'defaultSubagentModel': defaultSubagentModel,
    'defaultReasoningEffort': defaultReasoningEffort,
    'websocketPolicy': websocketPolicy,
    'contextWindowTokens': contextWindowTokens,
    'preserveCurrentProvider': preserveCurrentProvider,
  };

  factory AgentProviderProfile.fromJson(Map<String, Object?> json) {
    final id = _boundedString(json['id'], 128).trim();
    final serverProfileId = _boundedString(json['serverProfileId'], 128).trim();
    final agentValue = json['agent'];
    AgentKind? agent;
    for (final candidate in AgentKind.values) {
      if (agentValue == candidate.storageKeySegment ||
          agentValue == candidate.name ||
          agentValue == candidate.label) {
        agent = candidate;
        break;
      }
    }
    if (id.isEmpty || serverProfileId.isEmpty || agent == null) {
      throw const FormatException('Invalid provider profile identity');
    }

    return AgentProviderProfile(
      id: id,
      serverProfileId: serverProfileId,
      agent: agent,
      name: _boundedString(json['name'], 120).trim(),
      baseUrl: _boundedString(json['baseUrl'], 2048).trim(),
      apiKey: _boundedString(json['apiKey'], 8192),
      proxyUrl: _boundedString(json['proxyUrl'], 2048).trim(),
      defaultModel: _boundedString(json['defaultModel'], 256).trim(),
      defaultSubagentModel: _boundedString(
        json['defaultSubagentModel'],
        256,
      ).trim(),
      defaultReasoningEffort: _boundedString(
        json['defaultReasoningEffort'],
        64,
      ).trim(),
      websocketPolicy: _nullableBoundedString(json['websocketPolicy'], 64),
      contextWindowTokens: _boundedInt(
        json['contextWindowTokens'],
        max: 1_000_000_000,
      ),
      preserveCurrentProvider: json['preserveCurrentProvider'] is bool
          ? json['preserveCurrentProvider']! as bool
          : true,
    );
  }

  static AgentProviderProfile? tryFromJson(Object? value) {
    if (value is! Map) return null;
    try {
      return AgentProviderProfile.fromJson(Map<String, Object?>.from(value));
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  AgentProviderProfile copyWith({
    String? id,
    String? serverProfileId,
    AgentKind? agent,
    String? name,
    String? baseUrl,
    String? apiKey,
    String? proxyUrl,
    String? defaultModel,
    String? defaultSubagentModel,
    String? defaultReasoningEffort,
    String? websocketPolicy,
    bool clearWebsocketPolicy = false,
    int? contextWindowTokens,
    bool? preserveCurrentProvider,
  }) {
    return AgentProviderProfile(
      id: id ?? this.id,
      serverProfileId: serverProfileId ?? this.serverProfileId,
      agent: agent ?? this.agent,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: apiKey ?? this.apiKey,
      proxyUrl: proxyUrl ?? this.proxyUrl,
      defaultModel: defaultModel ?? this.defaultModel,
      defaultSubagentModel: defaultSubagentModel ?? this.defaultSubagentModel,
      defaultReasoningEffort:
          defaultReasoningEffort ?? this.defaultReasoningEffort,
      websocketPolicy: clearWebsocketPolicy
          ? null
          : websocketPolicy ?? this.websocketPolicy,
      contextWindowTokens: contextWindowTokens ?? this.contextWindowTokens,
      preserveCurrentProvider:
          preserveCurrentProvider ?? this.preserveCurrentProvider,
    );
  }

  static String _boundedString(Object? value, int maxLength) {
    if (value is! String) return '';
    return value.length <= maxLength ? value : value.substring(0, maxLength);
  }

  static String? _nullableBoundedString(Object? value, int maxLength) {
    if (value == null) return null;
    final result = _boundedString(value, maxLength).trim();
    return result.isEmpty ? null : result;
  }

  static int _boundedInt(Object? value, {required int max}) {
    if (value is! num || !value.isFinite) return 0;
    return value.toInt().clamp(0, max);
  }
}
