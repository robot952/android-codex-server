import '../domain/models.dart';
export '../domain/model_catalog.dart';

AgentModel? selectedAgentModel(List<AgentModel> models, String? selectedModel) {
  final selected = selectedModel?.trim() ?? '';
  if (selected.isEmpty) return null;
  for (final model in models) {
    if (model.id == selected || model.model == selected) return model;
  }
  return null;
}

String agentModelWireName(AgentModel model) {
  final wireName = model.model.trim();
  return wireName.isEmpty ? model.id.trim() : wireName;
}

String modelSelectionLabel(
  List<AgentModel> models,
  String? selectedModel,
  String? selectedEffort,
) {
  final selected = selectedAgentModel(models, selectedModel);
  final rawName = selected?.displayName.trim().isNotEmpty == true
      ? selected!.displayName.trim()
      : selectedModel?.trim().isNotEmpty == true
      ? selectedModel!.trim()
      : '模型';
  final name = rawName.startsWith('GPT-') ? rawName.substring(4) : rawName;
  final effort = reasoningEffortDisplayLabel(selectedEffort ?? '');
  return <String>[name, if (effort.isNotEmpty) effort].join(' ');
}

String reasoningEffortDisplayLabel(String effort) => switch (effort.trim()) {
  'minimal' => '极低',
  'low' => '低',
  'medium' => '中',
  'high' => '高',
  'xhigh' => '极高',
  'max' => '最高',
  final value => value,
};

String modelCapabilityLabel(AgentModel model) {
  final details = <String>[
    if (model.contextWindowTokens > 0)
      '上下文 ${formatModelTokenLimit(model.contextWindowTokens)}',
    if (model.maxOutputTokens > 0)
      '输出 ${formatModelTokenLimit(model.maxOutputTokens)}',
  ];
  return details.join(' · ');
}

String formatModelTokenLimit(int value) =>
    value >= 1000 && value % 1000 == 0 ? '${value ~/ 1000}K' : '$value';

/// Usage does not identify its source model. A newly selected model cannot be
/// used to reinterpret a sample captured before that selection.
TokenUsage? displayedContextUsage({
  required AgentKind agent,
  required TokenUsage? usage,
}) {
  if (agent != AgentKind.claudeCode) return usage;
  if (usage == null || usage.last.totalTokens <= 0) return null;
  return usage;
}

int explicitCustomContextWindow(
  AgentModel? model,
  Iterable<CustomModelDefinition> customModels,
) {
  if (model?.isCustom != true) return 0;
  for (final custom in customModels) {
    if (custom.modelId == model!.model || custom.modelId == model.id) {
      return custom.contextWindowTokens;
    }
  }
  return 0;
}
