import 'package:codex_remote/src/domain/model_catalog.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'keeps a persisted model and effort while the remote catalog is empty',
    () {
      final selection = resolveModelSelection(
        const <AgentModel>[],
        ' custom/provider-model ',
        ' high ',
      );

      expect(selection.model, 'custom/provider-model');
      expect(selection.effort, 'high');
    },
  );

  test('keeps an unqualified persisted model while the catalog is empty', () {
    final selection = resolveModelSelection(
      const <AgentModel>[],
      'root-model',
      'high',
    );

    expect(selection.model, 'root-model');
    expect(selection.effort, 'high');
  });

  test('keeps a persisted model absent from the current remote catalog', () {
    final selection = resolveModelSelection(
      const <AgentModel>[
        AgentModel(
          id: 'remote-default',
          model: 'remote-default',
          isDefault: true,
        ),
      ],
      'custom/provider-model',
      'medium',
    );

    expect(selection.model, 'custom/provider-model');
    expect(selection.effort, 'medium');
  });

  test('normalizes custom model definitions within supported bounds', () {
    final normalized = normalizeCustomModelDefinition(
      const CustomModelDefinition(
        modelId: ' gpt-5.2/custom@provider ',
        displayName: ' My model ',
        contextWindowTokens: maxModelTokenLimit,
        maxOutputTokens: maxModelTokenLimit,
      ),
    );

    expect(normalized.modelId, 'gpt-5.2/custom@provider');
    expect(normalized.displayName, 'My model');
    expect(isValidCustomModelDisplayName(' My model '), isTrue);
    expect(isValidCustomModelDisplayName('bad\nname'), isFalse);
    expect(
      isValidCustomModelDisplayName('x' * (maxCustomModelNameChars + 1)),
      isFalse,
    );
  });

  test('rejects invalid custom model ids, names, and token limits', () {
    expect(
      () => normalizeCustomModelDefinition(const CustomModelDefinition()),
      throwsArgumentError,
    );
    expect(
      () => normalizeCustomModelDefinition(
        const CustomModelDefinition(modelId: 'not valid'),
      ),
      throwsArgumentError,
    );
    expect(
      () => normalizeCustomModelDefinition(
        CustomModelDefinition(modelId: 'x' * (maxCustomModelIdChars + 1)),
      ),
      throwsArgumentError,
    );
    expect(
      () => normalizeCustomModelDefinition(
        CustomModelDefinition(
          modelId: 'valid',
          displayName: 'x' * (maxCustomModelNameChars + 1),
        ),
      ),
      throwsArgumentError,
    );
    expect(
      () => normalizeCustomModelDefinition(
        const CustomModelDefinition(modelId: 'valid', displayName: 'bad\nname'),
      ),
      throwsArgumentError,
    );
    expect(
      () => normalizeCustomModelDefinition(
        const CustomModelDefinition(modelId: 'valid', contextWindowTokens: -1),
      ),
      throwsArgumentError,
    );
    expect(
      () => normalizeCustomModelDefinition(
        CustomModelDefinition(
          modelId: 'valid',
          maxOutputTokens: maxModelTokenLimit + 1,
        ),
      ),
      throwsArgumentError,
    );
  });

  test('normalizes OpenCode model ids and Agent-scoped settings', () {
    expect(normalizeOpenCodeModelId(' gpt-5.2 '), 'custom-api/gpt-5.2');
    expect(
      normalizeOpenCodeModelId('codex-remote/gpt-5.1'),
      'custom-api/gpt-5.1',
    );
    expect(normalizeOpenCodeModelId('openai/gpt-5'), 'openai/gpt-5');
    expect(openCodeReasoningEfforts('custom-api/gpt-5.2'), [
      'minimal',
      'low',
      'medium',
      'high',
      'xhigh',
    ]);
    expect(openCodeReasoningEfforts('custom-api/claude'), isEmpty);

    final normalized = normalizeAgentModelSettings(
      AgentKind.openCode,
      const AgentModelSettings(
        preferredModel: 'gpt-5.2',
        preferredEffort: ' high ',
        testModel: 'codex-remote/test',
        customModels: <CustomModelDefinition>[
          CustomModelDefinition(modelId: 'gpt-5.2', displayName: 'First'),
          CustomModelDefinition(
            modelId: 'custom-api/gpt-5.2',
            displayName: 'Duplicate',
          ),
          CustomModelDefinition(modelId: 'not valid'),
        ],
        hiddenModelIds: <String>['gpt-5.2', 'custom-api/gpt-5.2', 'bad id'],
        managedModelIds: <String>['codex-remote/removed'],
      ),
    );

    expect(normalized.preferredModel, 'custom-api/gpt-5.2');
    expect(normalized.preferredEffort, 'high');
    expect(normalized.testModel, 'custom-api/test');
    expect(normalized.customModels, hasLength(1));
    expect(normalized.customModels.single.modelId, 'custom-api/gpt-5.2');
    expect(normalized.hiddenModelIds, <String>['custom-api/gpt-5.2']);
    expect(normalized.managedModelIds, <String>[
      'custom-api/gpt-5.2',
      'custom-api/removed',
    ]);
  });

  test(
    'merges remote and custom models while preserving remote capabilities',
    () {
      final catalog = buildModelCatalog(
        const <AgentModel>[
          AgentModel(
            id: 'remote-gpt',
            model: 'gpt-remote',
            displayName: 'Remote GPT',
            efforts: <String>['low', 'high'],
            contextWindowTokens: 128000,
            maxOutputTokens: 32000,
          ),
          AgentModel(id: 'duplicate', model: 'gpt-remote'),
        ],
        const <CustomModelDefinition>[
          CustomModelDefinition(
            modelId: 'gpt-remote',
            displayName: 'Configured GPT',
            contextWindowTokens: 256000,
            apiProtocol: ModelApiProtocol.responses,
          ),
          CustomModelDefinition(modelId: 'local-model'),
        ],
        const <String>[],
        customReasoningEfforts: (modelId) => modelId == 'local-model'
            ? const <String>['medium']
            : const <String>['minimal'],
      );

      expect(catalog, hasLength(2));
      expect(catalog.first.id, 'remote-gpt');
      expect(catalog.first.model, 'gpt-remote');
      expect(catalog.first.displayName, 'Configured GPT');
      expect(catalog.first.contextWindowTokens, 256000);
      expect(catalog.first.maxOutputTokens, 32000);
      expect(catalog.first.efforts, <String>['low', 'high']);
      expect(catalog.first.isCustom, isTrue);
      expect(catalog.first.apiProtocol, ModelApiProtocol.responses);
      expect(catalog.last.model, 'local-model');
      expect(catalog.last.displayName, 'local-model');
      expect(catalog.last.efforts, <String>['medium']);
    },
  );

  test(
    'hides remote models by either catalog id or wire name, not custom models',
    () {
      final catalog = buildModelCatalog(
        const <AgentModel>[
          AgentModel(id: 'hidden-id', model: 'wire-one'),
          AgentModel(id: 'visible-id', model: 'wire-two'),
        ],
        const <CustomModelDefinition>[
          CustomModelDefinition(modelId: 'wire-one'),
        ],
        const <String>['hidden-id', 'wire-two'],
      );

      expect(catalog, hasLength(1));
      expect(catalog.single.model, 'wire-one');
      expect(catalog.single.isCustom, isTrue);
    },
  );

  test('restores editable definitions from discovered custom models', () {
    final definitions = editableCustomModelDefinitions(
      const <AgentModel>[
        AgentModel(
          id: 'stored',
          model: 'stored',
          displayName: 'Discovered name',
          contextWindowTokens: 128000,
          maxOutputTokens: 16000,
          isCustom: true,
          apiProtocol: ModelApiProtocol.responses,
        ),
        AgentModel(
          id: 'recovered',
          model: 'recovered',
          displayName: 'recovered',
          isCustom: true,
        ),
        AgentModel(id: 'remote', model: 'remote'),
      ],
      const <CustomModelDefinition>[
        CustomModelDefinition(
          modelId: ' stored ',
          displayName: 'Stored name',
          contextWindowTokens: 64000,
          maxOutputTokens: 8000,
        ),
        CustomModelDefinition(modelId: 'missing', displayName: 'Keep me'),
      ],
    );

    expect(definitions, hasLength(3));
    expect(definitions[0].modelId, 'stored');
    expect(definitions[0].displayName, 'Discovered name');
    expect(definitions[0].contextWindowTokens, 128000);
    expect(definitions[0].maxOutputTokens, 16000);
    expect(definitions[0].apiProtocol, ModelApiProtocol.responses);
    expect(definitions[1].displayName, 'Keep me');
    expect(definitions[2].modelId, 'recovered');
    expect(definitions[2].displayName, isEmpty);
    expect(definitions[2].apiProtocol, ModelApiProtocol.chatCompletions);
  });

  test(
    'filters API model options case-insensitively and applies useful fields',
    () {
      const options = <ApiModelOption>[
        ApiModelOption(
          modelId: 'gpt-5',
          displayName: 'Flagship',
          contextWindowTokens: 128000,
          maxOutputTokens: 16000,
        ),
        ApiModelOption(modelId: 'mini', displayName: 'GPT Small'),
        ApiModelOption(modelId: 'other', displayName: 'Other'),
      ];

      expect(
        filterApiModelOptions(options, ' gPt ', limit: 1),
        <ApiModelOption>[options.first],
      );
      expect(filterApiModelOptions(options, '', limit: -1), isEmpty);

      final populated = applyApiModelOption(
        options.first,
        currentDisplayName: '',
        currentContextWindow: '',
        currentMaxOutput: '8192',
      );
      expect(populated.modelId, 'gpt-5');
      expect(populated.displayName, 'Flagship');
      expect(populated.contextWindow, '128000');
      expect(populated.maxOutput, '16000');

      final preserved = applyApiModelOption(
        options[1],
        currentDisplayName: 'My model',
        currentContextWindow: '64000',
        currentMaxOutput: '4096',
      );
      expect(preserved.displayName, 'My model');
      expect(preserved.contextWindow, '64000');
      expect(preserved.maxOutput, '4096');
    },
  );
}
