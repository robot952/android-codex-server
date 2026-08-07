import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/ui/model_selection_presentation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const models = <AgentModel>[
    AgentModel(
      id: 'catalog-entry',
      model: 'gpt-5.2-codex',
      displayName: 'GPT-5.2-Codex',
      defaultEffort: 'medium',
      efforts: <String>['low', 'medium', 'high'],
      contextWindowTokens: 128000,
      maxOutputTokens: 32000,
    ),
    AgentModel(id: 'fallback-id', displayName: 'Fallback'),
  ];

  test('matches selected models by wire model or catalog id', () {
    expect(selectedAgentModel(models, 'gpt-5.2-codex'), same(models.first));
    expect(selectedAgentModel(models, 'catalog-entry'), same(models.first));
    expect(selectedAgentModel(models, 'missing'), isNull);
  });

  test('uses the wire model and falls back to the catalog id', () {
    expect(agentModelWireName(models.first), 'gpt-5.2-codex');
    expect(agentModelWireName(models.last), 'fallback-id');
  });

  test('builds the same compact model and effort label as Work', () {
    expect(modelSelectionLabel(models, 'gpt-5.2-codex', 'high'), '5.2-Codex 高');
    expect(modelSelectionLabel(models, null, null), '模型');
    expect(reasoningEffortDisplayLabel('xhigh'), '极高');
    expect(reasoningEffortDisplayLabel('custom'), 'custom');
  });

  test('formats model capability limits without inventing precision', () {
    expect(modelCapabilityLabel(models.first), '上下文 128K · 输出 32K');
    expect(formatModelTokenLimit(8192), '8192');
    expect(modelCapabilityLabel(models.last), isEmpty);
  });
}
