import 'models.dart';

const int maxCustomModels = 100;
const int maxCustomModelIdChars = 200;
const int maxCustomModelNameChars = 120;
const int maxModelTokenLimit = 10000000;
const int maxHiddenModelIds = 500;
const int maxManagedModelIds = 512;
const String openCodeManagedProviderId = 'custom-api';
const String openCodeLegacyManagedProviderId = 'codex-remote';

const List<String> openCodeReasoningEffortValues = <String>[
  'minimal',
  'low',
  'medium',
  'high',
  'xhigh',
];

final RegExp _customModelIdPattern = RegExp(r'^[A-Za-z0-9._:/@+\-]+$');
final RegExp _controlCharacterPattern = RegExp(r'[\x00-\x1F\x7F-\x9F]');
final RegExp _openCodeReasoningModelPattern = RegExp(
  r'(^|/)gpt-5(?:[._-]|$)|(^|/)o(?:1|3|4)(?:[._-]|$)',
  caseSensitive: false,
);

final class ResolvedModelSelection {
  const ResolvedModelSelection({this.model, this.effort});

  final String? model;
  final String? effort;
}

String modelWireName(AgentModel model) => _agentModelIdentity(model);

String normalizeAgentModelId(AgentKind agent, String value) => switch (agent) {
  AgentKind.codex => _normalizeOptionalModelId(value, '模型'),
  AgentKind.openCode => normalizeOpenCodeModelId(value),
};

String normalizeOpenCodeModelId(String value) {
  final normalized = _normalizeOptionalModelId(value, 'OpenCode 模型');
  if (normalized.isEmpty) return '';
  if (normalized.startsWith('$openCodeLegacyManagedProviderId/')) {
    return '$openCodeManagedProviderId/${normalized.substring(normalized.indexOf('/') + 1)}';
  }
  return normalized.contains('/')
      ? normalized
      : '$openCodeManagedProviderId/$normalized';
}

List<String> openCodeReasoningEfforts(String modelId) =>
    _openCodeReasoningModelPattern.hasMatch(modelId.trim())
    ? openCodeReasoningEffortValues
    : const <String>[];

bool isValidCustomModelDisplayName(String value) {
  final displayName = value.trim();
  return displayName.length <= maxCustomModelNameChars &&
      !_controlCharacterPattern.hasMatch(displayName);
}

ResolvedModelSelection resolveModelSelection(
  List<AgentModel> models,
  String preferredModel,
  String preferredEffort,
) {
  final preferred = preferredModel.trim();
  AgentModel? selected;
  for (final model in models) {
    if (_agentModelIdentity(model) == preferred ||
        model.id.trim() == preferred) {
      selected = model;
      break;
    }
  }
  if (selected == null) {
    for (final model in models) {
      if (model.isDefault) {
        selected = model;
        break;
      }
    }
  }
  // A persisted custom/provider model may not be advertised until the remote
  // catalog is available. Keep the user's selection stable across reconnects
  // instead of silently switching the session to another model.
  if (selected == null && preferred.isNotEmpty) {
    final requestedEffort = preferredEffort.trim();
    return ResolvedModelSelection(
      model: preferred,
      effort: requestedEffort.isEmpty ? null : requestedEffort,
    );
  }
  selected ??= models.isEmpty ? null : models.first;
  if (selected == null) return const ResolvedModelSelection();

  final requestedEffort = preferredEffort.trim();
  final effort =
      requestedEffort.isNotEmpty &&
          (selected.efforts.isEmpty ||
              selected.efforts.contains(requestedEffort))
      ? requestedEffort
      : selected.defaultEffort.trim().isEmpty
      ? null
      : selected.defaultEffort.trim();
  return ResolvedModelSelection(
    model: _agentModelIdentity(selected),
    effort: effort,
  );
}

/// Merges remote models with profile-local custom model definitions.
List<AgentModel> buildModelCatalog(
  List<AgentModel> remoteModels,
  List<CustomModelDefinition> customModels,
  Iterable<String> hiddenModelIds, {
  List<String> Function(String modelId) customReasoningEfforts =
      _emptyCustomReasoningEfforts,
}) {
  final hidden = hiddenModelIds
      .map((modelId) => modelId.trim())
      .where((modelId) => modelId.isNotEmpty)
      .toSet();
  final models = <AgentModel>[];
  final remoteIdentities = <String>{};

  for (final remote in remoteModels) {
    if (hidden.contains(remote.id) || hidden.contains(remote.model)) continue;
    final identity = _agentModelIdentity(remote);
    if (remoteIdentities.add(identity)) models.add(remote);
  }

  for (final custom in customModels) {
    final modelId = custom.modelId.trim();
    if (modelId.isEmpty) continue;
    final inferredEfforts = customReasoningEfforts(modelId);
    final index = models.indexWhere(
      (model) => model.model == modelId || model.id == modelId,
    );
    if (index >= 0) {
      final remote = models[index];
      models[index] = remote.copyWith(
        model: modelId,
        displayName: custom.displayName.trim().isEmpty
            ? remote.displayName
            : custom.displayName,
        contextWindowTokens: custom.contextWindowTokens > 0
            ? custom.contextWindowTokens
            : remote.contextWindowTokens,
        maxOutputTokens: custom.maxOutputTokens > 0
            ? custom.maxOutputTokens
            : remote.maxOutputTokens,
        efforts: remote.efforts.isEmpty ? inferredEfforts : remote.efforts,
        isCustom: true,
        apiProtocol: custom.apiProtocol,
      );
    } else {
      models.add(
        AgentModel(
          id: modelId,
          model: modelId,
          displayName: custom.displayName.trim().isEmpty
              ? modelId
              : custom.displayName,
          description: '自定义模型',
          efforts: inferredEfforts,
          contextWindowTokens: custom.contextWindowTokens,
          maxOutputTokens: custom.maxOutputTokens,
          isCustom: true,
          apiProtocol: custom.apiProtocol,
        ),
      );
    }
  }
  return models;
}

/// Validates editor input before it becomes durable profile metadata.
CustomModelDefinition normalizeCustomModelDefinition(
  CustomModelDefinition value,
) {
  final modelId = value.modelId.trim();
  if (modelId.isEmpty) {
    throw ArgumentError.value(value.modelId, 'modelId', '请输入模型 ID');
  }
  if (modelId.length > maxCustomModelIdChars ||
      !_customModelIdPattern.hasMatch(modelId)) {
    throw ArgumentError.value(
      value.modelId,
      'modelId',
      '模型 ID 只能包含字母、数字及 . _ - / : @ +',
    );
  }

  final displayName = value.displayName.trim();
  if (!isValidCustomModelDisplayName(displayName)) {
    throw ArgumentError.value(
      value.displayName,
      'displayName',
      '显示名称不能超过 $maxCustomModelNameChars 个字符或包含控制字符',
    );
  }
  if (value.contextWindowTokens < 0 ||
      value.contextWindowTokens > maxModelTokenLimit) {
    throw ArgumentError.value(
      value.contextWindowTokens,
      'contextWindowTokens',
      '上下文长度必须在 0 到 $maxModelTokenLimit 之间',
    );
  }
  if (value.maxOutputTokens < 0 || value.maxOutputTokens > maxModelTokenLimit) {
    throw ArgumentError.value(
      value.maxOutputTokens,
      'maxOutputTokens',
      '最大输出长度必须在 0 到 $maxModelTokenLimit 之间',
    );
  }
  return value.copyWith(modelId: modelId, displayName: displayName);
}

CustomModelDefinition normalizeCustomModelDefinitionForAgent(
  AgentKind agent,
  CustomModelDefinition value,
) => normalizeCustomModelDefinition(
  value.copyWith(modelId: normalizeAgentModelId(agent, value.modelId)),
);

AgentModelSettings normalizeAgentModelSettings(
  AgentKind agent,
  AgentModelSettings settings,
) {
  final customModels = <CustomModelDefinition>[];
  final customIds = <String>{};
  for (final definition in settings.customModels) {
    try {
      final normalized = normalizeCustomModelDefinitionForAgent(
        agent,
        definition,
      );
      if (customIds.add(normalized.modelId)) customModels.add(normalized);
    } on ArgumentError {
      continue;
    }
    if (customModels.length >= maxCustomModels) break;
  }

  List<String> normalizeIds(Iterable<String> values, int limit) {
    final result = <String>[];
    final seen = <String>{};
    for (final value in values) {
      try {
        final normalized = normalizeAgentModelId(agent, value);
        if (normalized.isNotEmpty && seen.add(normalized)) {
          result.add(normalized);
        }
      } on ArgumentError {
        continue;
      }
      if (result.length >= limit) break;
    }
    return List<String>.unmodifiable(result);
  }

  String normalizeSelected(String value) {
    try {
      return normalizeAgentModelId(agent, value);
    } on ArgumentError {
      return '';
    }
  }

  return settings.copyWith(
    preferredModel: normalizeSelected(settings.preferredModel),
    preferredEffort: settings.preferredEffort.trim(),
    testModel: normalizeSelected(settings.testModel),
    customModels: List<CustomModelDefinition>.unmodifiable(customModels),
    hiddenModelIds: normalizeIds(settings.hiddenModelIds, maxHiddenModelIds),
    managedModelIds: normalizeIds(<String>[
      ...customModels.map((model) => model.modelId),
      ...settings.managedModelIds,
    ], maxManagedModelIds),
  );
}

/// Restores editor access for custom models discovered from an active catalog.
List<CustomModelDefinition> editableCustomModelDefinitions(
  List<AgentModel> models,
  List<CustomModelDefinition> storedDefinitions,
) {
  final discovered = <String, AgentModel>{
    for (final model in models)
      if (model.isCustom) _agentModelIdentity(model): model,
  };
  final storedIds = storedDefinitions
      .map((definition) => definition.modelId.trim())
      .toSet();
  final definitions = <CustomModelDefinition>[];

  for (final stored in storedDefinitions) {
    final modelId = stored.modelId.trim();
    final model = discovered[modelId];
    if (model == null) {
      definitions.add(stored);
      continue;
    }
    definitions.add(
      CustomModelDefinition(
        modelId: modelId,
        displayName: model.displayName == modelId
            ? stored.displayName
            : model.displayName,
        contextWindowTokens: model.contextWindowTokens > 0
            ? model.contextWindowTokens
            : stored.contextWindowTokens,
        maxOutputTokens: model.maxOutputTokens > 0
            ? model.maxOutputTokens
            : stored.maxOutputTokens,
        apiProtocol: model.apiProtocol ?? stored.apiProtocol,
      ),
    );
  }
  for (final entry in discovered.entries) {
    if (storedIds.contains(entry.key)) continue;
    final model = entry.value;
    definitions.add(
      CustomModelDefinition(
        modelId: entry.key,
        displayName: model.displayName == entry.key ? '' : model.displayName,
        contextWindowTokens: model.contextWindowTokens,
        maxOutputTokens: model.maxOutputTokens,
        apiProtocol: model.apiProtocol ?? ModelApiProtocol.chatCompletions,
      ),
    );
  }
  return definitions;
}

List<ApiModelOption> filterApiModelOptions(
  List<ApiModelOption> options,
  String query, {
  int limit = 80,
}) {
  final normalizedQuery = query.trim().toLowerCase();
  return options
      .where(
        (option) =>
            normalizedQuery.isEmpty ||
            option.modelId.toLowerCase().contains(normalizedQuery) ||
            option.displayName.toLowerCase().contains(normalizedQuery),
      )
      .take(limit < 0 ? 0 : limit)
      .toList(growable: false);
}

class ApiModelEditorSelection {
  const ApiModelEditorSelection({
    required this.modelId,
    required this.displayName,
    required this.contextWindow,
    required this.maxOutput,
  });

  final String modelId;
  final String displayName;
  final String contextWindow;
  final String maxOutput;
}

ApiModelEditorSelection applyApiModelOption(
  ApiModelOption option, {
  required String currentDisplayName,
  required String currentContextWindow,
  required String currentMaxOutput,
}) => ApiModelEditorSelection(
  modelId: option.modelId,
  displayName: currentDisplayName.trim().isEmpty
      ? option.displayName
      : currentDisplayName,
  contextWindow: option.contextWindowTokens > 0
      ? '${option.contextWindowTokens}'
      : currentContextWindow,
  maxOutput: option.maxOutputTokens > 0
      ? '${option.maxOutputTokens}'
      : currentMaxOutput,
);

List<String> _emptyCustomReasoningEfforts(String _) => const <String>[];

String _normalizeOptionalModelId(String value, String fieldName) {
  final modelId = value.trim();
  if (modelId.isEmpty) return '';
  if (modelId.length > maxCustomModelIdChars ||
      !_customModelIdPattern.hasMatch(modelId)) {
    throw ArgumentError.value(
      value,
      fieldName,
      '$fieldName只能包含字母、数字及 . _ - / : @ +',
    );
  }
  return modelId;
}

String _agentModelIdentity(AgentModel model) {
  final wireName = model.model.trim();
  return wireName.isEmpty ? model.id.trim() : wireName;
}
