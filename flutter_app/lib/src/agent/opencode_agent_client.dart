import 'dart:async';

import '../domain/model_catalog.dart';
import '../domain/models.dart';
import '../ssh/ssh_server_client.dart';
import 'codex_agent_client.dart';
import 'codex_global_settings.dart';
import 'open_code_bootstrap.dart';
import 'open_code_bridge_asset.dart';
import 'remote_agent_client.dart';
import 'remote_bootstrap.dart';

typedef OpenCodeBridgeLoader = Future<String> Function();

const Duration _openCodeSettingsTimeout = Duration(seconds: 30);
const Duration _openCodeInstallTimeout = Duration(minutes: 30);

/// OpenCode adapter backed by the app-owned JSONL compatibility bridge.
///
/// The bridge deliberately mirrors the Codex app-server protocol, so thread,
/// turn, approval, notification, and generation handling stay in
/// [CodexAgentClient]. Only OpenCode-owned runtime and configuration behavior
/// lives here.
class OpenCodeAgentClient extends CodexAgentClient
    implements RemoteAgentCustomModelClient {
  OpenCodeAgentClient({
    super.clientVersion,
    super.requestTimeout,
    super.threadRequestTimeout,
    super.maxLineChars,
    super.sessionOpener,
    super.dedicatedHostFactory,
    OpenCodeBridgeLoader? bridgeLoader,
  }) : _bridgeLoader = bridgeLoader ?? OpenCodeBridgeAsset.load;

  final OpenCodeBridgeLoader _bridgeLoader;
  final Map<String, String> _ensuredCustomModels = <String, String>{};

  String _settingsProviderId = openCodeManagedProviderId;
  int _connectionEpoch = 0;

  @override
  AgentKind get kind => AgentKind.openCode;

  @override
  AgentCapabilities get capabilities => AgentCapabilities.openCode;

  @override
  Future<AgentRuntimeInspection> inspectRuntime(
    ServerProfile profile,
    RemoteServerClient host,
  ) async {
    final scriptHost = host is RemoteServerScriptClient
        ? host as RemoteServerScriptClient
        : throw UnsupportedError('当前 SSH 客户端不支持安全执行探测脚本');
    final bridgeSource = await _bridgeLoader();
    final output = await scriptHost.runShellScript(
      OpenCodeBootstrap.combinedProbeScript,
      timeout: const Duration(seconds: 30),
      maxOutputBytes: 64 * 1024,
    );
    return OpenCodeBootstrap.inspect(output, bridgeSource: bridgeSource);
  }

  @override
  Future<void> installRuntime(
    ServerProfile profile,
    RemoteServerClient host, {
    required void Function(RemoteInstallProgress progress) onProgress,
  }) async {
    final scriptHost = host is RemoteServerStreamingScriptClient
        ? host as RemoteServerStreamingScriptClient
        : throw UnsupportedError('当前 SSH 客户端不支持流式执行安装脚本');
    final bridgeSource = await _bridgeLoader();

    await scriptHost.runStreamingShellScript(
      OpenCodeBootstrap.installNodeRuntimeScript(proxyUrl: profile.proxyUrl),
      command: remoteInstallCommand,
      timeout: _openCodeInstallTimeout,
      maxOutputBytes: 8 * 1024 * 1024,
      onStdoutLine: (line) {
        final progress = parseRemoteInstallProgressLine(line);
        if (progress == null) return;
        onProgress(
          RemoteInstallProgress(
            percent: (progress.percent * openCodeSharedRuntimePercent ~/ 100)
                .clamp(0, openCodeSharedRuntimePercent),
            message: '准备 OpenCode 运行时 · ${progress.message}',
            detail: progress.detail,
            downloadPercent: progress.downloadPercent,
          ),
        );
      },
    );

    await scriptHost.runStreamingShellScript(
      OpenCodeBootstrap.installScript(
        proxyUrl: profile.proxyUrl,
        bridgeSource: bridgeSource,
      ),
      command: remoteInstallCommand,
      timeout: _openCodeInstallTimeout,
      maxOutputBytes: 8 * 1024 * 1024,
      onStdoutLine: (line) {
        final progress = parseRemoteInstallProgressLine(line);
        if (progress != null) onProgress(progress);
      },
    );
  }

  @override
  Future<void> uninstallRuntime(
    ServerProfile profile,
    RemoteServerClient host,
  ) async {
    await disconnect();
    final scriptHost = host is RemoteServerScriptClient
        ? host as RemoteServerScriptClient
        : throw UnsupportedError('当前 SSH 客户端不支持安全执行卸载脚本');
    await scriptHost.runShellScript(
      OpenCodeBootstrap.uninstallScript,
      timeout: const Duration(minutes: 1),
      maxOutputBytes: 64 * 1024,
    );
  }

  @override
  Future<void> connect(ServerProfile profile, RemoteServerClient host) async {
    _invalidateCustomModelCache();
    final command = buildOpenCodeBridgeCommand(profile.workspace);
    try {
      await super.connect(
        profile.copyWith(workspace: '', remoteCommand: command),
        host,
      );
    } catch (_) {
      _invalidateCustomModelCache();
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    _invalidateCustomModelCache();
    await super.disconnect();
  }

  @override
  Future<AgentGlobalSettings> readGlobalSettings(ServerProfile profile) async {
    final result = await requestAdapterExtension(
      'agent/settings/read',
      timeout: _openCodeSettingsTimeout,
    );
    final settings = parseOpenCodeGlobalSettings(result);
    _settingsProviderId = settings.modelProvider.trim().isEmpty
        ? openCodeManagedProviderId
        : settings.modelProvider.trim();
    return settings;
  }

  @override
  Future<void> writeGlobalSettings(
    ServerProfile profile, {
    required String baseUrl,
    required String apiKey,
    required String proxyUrl,
    required String defaultModel,
    required String defaultReasoningEffort,
    required bool preserveCurrentProvider,
  }) async {
    final normalizedBaseUrl = normalizeCodexBaseUrl(baseUrl);
    final normalizedApiKey = normalizeCodexApiKey(apiKey);
    final normalizedProxyUrl = normalizeCodexProxyUrl(proxyUrl);
    final normalizedDefaultModel = normalizeOpenCodeModelId(defaultModel);
    final normalizedEffort = normalizeCodexReasoningEffort(
      defaultReasoningEffort,
    );
    final effectivePreserveCurrentProvider =
        preserveCurrentProvider &&
        (normalizedDefaultModel.isEmpty ||
            normalizedDefaultModel.startsWith('$_settingsProviderId/'));
    final definitions = profile
        .modelSettings(AgentKind.openCode)
        .customModels
        .map(
          (definition) => normalizeCustomModelDefinitionForAgent(
            AgentKind.openCode,
            definition,
          ),
        )
        .toList(growable: false);

    final result = await requestAdapterExtension(
      'agent/settings/write',
      params: <String, Object?>{
        'baseUrl': normalizedBaseUrl,
        'apiKey': normalizedApiKey,
        'proxyUrl': normalizedProxyUrl,
        'defaultModel': normalizedDefaultModel,
        'defaultReasoningEffort': normalizedEffort,
        'preserveCurrentProvider': effectivePreserveCurrentProvider,
        'customModels': definitions.map(openCodeCustomModelParams).toList(),
      },
      timeout: _openCodeSettingsTimeout,
    );
    _settingsProviderId = openCodeSettingsProviderId(result);
    _invalidateCustomModelCache();
  }

  @override
  Future<AgentConnectionTestResult> testGlobalSettings(
    ServerProfile profile, {
    required String baseUrl,
    required String apiKey,
    required String proxyUrl,
    required String testModel,
    ModelApiProtocol? apiProtocol,
  }) {
    final definitions = profile.modelSettings(AgentKind.openCode).customModels;
    final resolvedProtocol =
        apiProtocol ?? resolveOpenCodeModelApiProtocol(testModel, definitions);
    return super.testGlobalSettings(
      profile,
      baseUrl: baseUrl,
      apiKey: apiKey,
      proxyUrl: proxyUrl,
      testModel: openCodeApiModelId(testModel),
      apiProtocol: resolvedProtocol,
    );
  }

  @override
  Future<List<ApiModelOption>> fetchApiModels(
    ServerProfile profile, {
    required String baseUrl,
    required String apiKey,
    required String proxyUrl,
  }) async {
    final options = await super.fetchApiModels(
      profile,
      baseUrl: baseUrl,
      apiKey: apiKey,
      proxyUrl: proxyUrl,
    );
    return List<ApiModelOption>.unmodifiable(
      options.map(
        (option) => option.copyWith(
          modelId: openCodeProviderModelId(_settingsProviderId, option.modelId),
        ),
      ),
    );
  }

  @override
  Future<void> ensureCustomModel(
    ServerProfile profile,
    CustomModelDefinition definition,
  ) async {
    final normalized = normalizeCustomModelDefinitionForAgent(
      AgentKind.openCode,
      definition,
    );
    if (_ensuredCustomModels.containsKey(
      openCodeCustomModelCacheKey(normalized),
    )) {
      return;
    }
    await syncCustomModels(
      profile,
      definitions: <CustomModelDefinition>[normalized],
      removedModelIds: const <String>[],
    );
  }

  @override
  Future<void> syncCustomModels(
    ServerProfile profile, {
    required List<CustomModelDefinition> definitions,
    required List<String> removedModelIds,
  }) async {
    if (!isConnected) return;
    final normalizedDefinitions = <CustomModelDefinition>[];
    final definitionKeys = <String>{};
    for (final definition in definitions) {
      final normalized = normalizeCustomModelDefinitionForAgent(
        AgentKind.openCode,
        definition,
      );
      if (definitionKeys.add(openCodeCustomModelCacheKey(normalized))) {
        normalizedDefinitions.add(normalized);
      }
    }
    final normalizedRemovedIds = <String>[];
    final removalIds = <String>{};
    for (final modelId in removedModelIds) {
      final normalized = normalizeOpenCodeModelId(modelId);
      if (normalized.isNotEmpty && removalIds.add(normalized)) {
        normalizedRemovedIds.add(normalized);
      }
    }
    final pendingDefinitions = normalizedDefinitions
        .where(
          (definition) => !_ensuredCustomModels.containsKey(
            openCodeCustomModelCacheKey(definition),
          ),
        )
        .toList(growable: false);
    if (pendingDefinitions.isEmpty && normalizedRemovedIds.isEmpty) return;

    final epoch = _connectionEpoch;
    await requestAdapterExtension(
      'agent/models/sync',
      params: <String, Object?>{
        'models': pendingDefinitions.map(openCodeCustomModelParams).toList(),
        'removeModelIds': normalizedRemovedIds,
      },
      timeout: _openCodeSettingsTimeout,
    );
    if (!isConnected || epoch != _connectionEpoch) return;

    for (final modelId in normalizedRemovedIds) {
      _removeCachedModel(modelId);
    }
    for (final definition in pendingDefinitions) {
      _removeCachedModel(definition.modelId);
      _ensuredCustomModels[openCodeCustomModelCacheKey(definition)] =
          definition.modelId;
    }
  }

  @override
  void close() {
    _invalidateCustomModelCache();
    super.close();
  }

  void _removeCachedModel(String modelId) {
    _ensuredCustomModels.removeWhere((_, cachedId) => cachedId == modelId);
  }

  void _invalidateCustomModelCache() {
    _ensuredCustomModels.clear();
    _connectionEpoch += 1;
  }
}

String buildOpenCodeBridgeCommand(String workspace) {
  final directory = workspace.trim();
  return directory.isEmpty
      ? managedOpenCodeBridgeCommand
      : '$managedOpenCodeBridgeCommand --directory ${shellQuote(directory)}';
}

AgentGlobalSettings parseOpenCodeGlobalSettings(Object? value) {
  final result = _stringKeyedMap(value);
  final provider = _mapString(result, 'modelProvider');
  return AgentGlobalSettings(
    baseUrl: _mapString(result, 'baseUrl'),
    model: _mapString(result, 'model'),
    reasoningEffort: _mapString(result, 'reasoningEffort'),
    modelProvider: provider.isEmpty ? openCodeManagedProviderId : provider,
    hasStoredAuthentication: result['hasStoredAuthentication'] == true,
    apiKey: _mapString(result, 'apiKey'),
    proxyUrl: _mapString(result, 'proxyUrl'),
  );
}

String openCodeSettingsProviderId(Object? value) {
  if (value is! Map) return openCodeManagedProviderId;
  final provider = _mapString(_stringKeyedMap(value), 'modelProvider');
  return provider.isEmpty ? openCodeManagedProviderId : provider;
}

Map<String, Object?> openCodeCustomModelParams(
  CustomModelDefinition definition,
) => <String, Object?>{
  'modelId': definition.modelId,
  'displayName': definition.displayName,
  'contextWindowTokens': definition.contextWindowTokens,
  'maxOutputTokens': definition.maxOutputTokens,
  'apiProtocol': switch (definition.apiProtocol) {
    ModelApiProtocol.chatCompletions => 'chat_completions',
    ModelApiProtocol.responses => 'responses',
  },
};

String openCodeCustomModelCacheKey(CustomModelDefinition definition) =>
    <String>[
      normalizeOpenCodeModelId(definition.modelId),
      definition.displayName.trim(),
      definition.contextWindowTokens.toString(),
      definition.maxOutputTokens.toString(),
      switch (definition.apiProtocol) {
        ModelApiProtocol.chatCompletions => 'chat_completions',
        ModelApiProtocol.responses => 'responses',
      },
    ].join('\u0000');

ModelApiProtocol resolveOpenCodeModelApiProtocol(
  String modelId,
  List<CustomModelDefinition> definitions,
) {
  final normalizedModelId = normalizeOpenCodeModelId(modelId);
  for (final definition in definitions) {
    if (normalizeOpenCodeModelId(definition.modelId) == normalizedModelId) {
      return definition.apiProtocol;
    }
  }
  return ModelApiProtocol.chatCompletions;
}

String openCodeApiModelId(String value) {
  final normalized = normalizeCodexModel(value, '测试模型');
  final separator = normalized.indexOf('/');
  return separator < 0 ? normalized : normalized.substring(separator + 1);
}

String openCodeProviderModelId(String providerId, String value) {
  final provider = providerId.trim().isEmpty
      ? openCodeManagedProviderId
      : providerId.trim();
  final normalized = normalizeCodexModel(value, '模型');
  if (normalized.isEmpty || normalized.startsWith('$provider/')) {
    return normalized;
  }
  return '$provider/$normalized';
}

Map<String, Object?> _stringKeyedMap(Object? value) {
  if (value is! Map) throw StateError('OpenCode 设置返回格式错误');
  return <String, Object?>{
    for (final entry in value.entries)
      if (entry.key is String) entry.key as String: entry.value,
  };
}

String _mapString(Map<String, Object?> value, String key) {
  final item = value[key];
  return item is String ? item.trim() : '';
}
