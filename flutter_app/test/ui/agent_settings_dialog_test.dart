import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/ui/agent_settings_dialog.dart';
import 'package:codex_remote/src/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const claudeModels = [
    AgentModel(
      id: 'claude-opus-5-5',
      model: 'claude-opus-5-5',
      displayName: 'Opus 5.5',
      efforts: ['low', 'medium', 'high', 'xhigh', 'max'],
      defaultEffort: 'high',
    ),
    AgentModel(id: 'claude-haiku-4-5', displayName: 'Haiku 4.5'),
  ];
  const claudeState = AppUiState(
    selectedProfileId: 'server-one',
    profiles: [ServerProfile(id: 'server-one')],
    activeAgent: AgentKind.claudeCode,
    activeAgentCapabilities: AgentCapabilities.claudeCode,
    models: claudeModels,
    agentSettingsVisible: true,
    agentSettings: AgentGlobalSettings(
      baseUrl: 'https://claude.example.test',
      model: 'claude-opus-5-5',
      modelProvider: 'anthropic',
      reasoningEffort: 'high',
      apiKey: 'fixture-only-key',
      hasStoredAuthentication: true,
    ),
  );

  testWidgets(
    'Claude settings use Messages and preserve unchanged credentials',
    (tester) async {
      String? savedKey;
      String? savedUrl;
      String? savedModel;
      String? savedEffort;
      await tester.pumpWidget(
        _DialogHarness(
          state: claudeState,
          onSave:
              ({
                required baseUrl,
                required apiKey,
                required proxyUrl,
                required defaultModel,
                required defaultSubagentModel,
                required defaultReasoningEffort,
                required testModel,
                required websocketPolicy,
                required preserveCurrentProvider,
                required contextLimit,
              }) {
                savedKey = apiKey;
                savedUrl = baseUrl;
                savedModel = defaultModel;
                savedEffort = defaultReasoningEffort;
                expect(preserveCurrentProvider, isTrue);
              },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('配置 Claude Code'), findsOneWidget);
      expect(find.text('协议：Anthropic Messages'), findsOneWidget);
      expect(find.textContaining('OpenAI'), findsNothing);
      expect(find.textContaining('OpenCode'), findsNothing);
      expect(find.textContaining('Provider：'), findsNothing);
      expect(
        find.byKey(const ValueKey('agent-settings-websocket-policy')),
        findsNothing,
      );
      final effort = tester.widget<DropdownButton<String>>(
        find.byKey(const ValueKey('agent-settings-reasoning-effort')),
      );
      expect(effort.items!.map((item) => item.value), [
        '',
        'low',
        'medium',
        'high',
        'xhigh',
        'max',
      ]);
      await _enterText(
        tester,
        'agent-settings-base-url',
        'https://new.example.test',
      );
      await tester.tap(find.byKey(const ValueKey('agent-settings-save')));
      await tester.pumpAndSettle();
      expect(find.textContaining('重新连接 Claude Code'), findsWidgets);
      await tester.tap(
        find.byKey(const ValueKey('agent-settings-confirm-save')),
      );
      await tester.pumpAndSettle();
      expect(savedKey, '');
      expect(savedUrl, 'https://new.example.test');
      expect(savedModel, 'claude-opus-5-5');
      expect(savedEffort, 'high');
    },
  );

  testWidgets(
    'Claude effort options follow model changes and unknown aliases',
    (tester) async {
      await tester.pumpWidget(const _DialogHarness(state: claudeState));
      await tester.pumpAndSettle();
      await _enterText(
        tester,
        'agent-settings-default-model',
        'claude-haiku-4-5',
      );
      var effort = tester.widget<DropdownButton<String>>(
        find.byKey(const ValueKey('agent-settings-reasoning-effort')),
      );
      // Haiku ships without effort metadata upstream, but Claude Code accepts
      // the flag for it, so the standard 档位 和已选值 都必须保留。
      expect(effort.value, 'high');
      expect(effort.items!.map((item) => item.value), [
        '',
        'low',
        'medium',
        'high',
        'xhigh',
        'max',
      ]);
      await _enterText(
        tester,
        'agent-settings-default-model',
        'provider-custom-alias',
      );
      effort = tester.widget<DropdownButton<String>>(
        find.byKey(const ValueKey('agent-settings-reasoning-effort')),
      );
      // 目录里没有这个别名时不能凭空选档位，已选值也一并清掉。
      expect(effort.value, '');
      expect(effort.items!.map((item) => item.value), ['']);
      await _enterText(
        tester,
        'agent-settings-default-model',
        'claude-opus-5-5',
      );
      effort = tester.widget<DropdownButton<String>>(
        find.byKey(const ValueKey('agent-settings-reasoning-effort')),
      );
      expect(effort.items!.map((item) => item.value), contains('max'));
      expect(
        effort.items!.map((item) => item.value),
        isNot(contains('minimal')),
      );
    },
  );

  testWidgets('Claude unknown model saves default effort only', (tester) async {
    String? savedEffort;
    await tester.pumpWidget(
      _DialogHarness(
        state: claudeState,
        onSave:
            ({
              required baseUrl,
              required apiKey,
              required proxyUrl,
              required defaultModel,
              required defaultSubagentModel,
              required defaultReasoningEffort,
              required testModel,
              required websocketPolicy,
              required preserveCurrentProvider,
              required contextLimit,
            }) {
              savedEffort = defaultReasoningEffort;
              expect(defaultModel, 'provider-custom-alias');
            },
      ),
    );
    await tester.pumpAndSettle();
    await _enterText(
      tester,
      'agent-settings-default-model',
      'provider-custom-alias',
    );
    await tester.tap(find.byKey(const ValueKey('agent-settings-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('agent-settings-confirm-save')));
    await tester.pumpAndSettle();
    expect(savedEffort, isEmpty);
  });

  testWidgets(
    'Claude default sub-agent model round-trips and trims input',
    (tester) async {
      AgentSettingsSaveValues? saved;
      String? savedSubagentModel;
      await tester.pumpWidget(
        _DialogHarness(
          state: claudeState.copyWith(
            agentSettings: claudeState.agentSettings!.copyWith(
              subagentModel: 'claude-haiku-4-5',
            ),
          ),
          onSave:
              ({
                required baseUrl,
                required apiKey,
                required proxyUrl,
                required defaultModel,
                required defaultSubagentModel,
                required defaultReasoningEffort,
                required testModel,
                required websocketPolicy,
                required preserveCurrentProvider,
                required contextLimit,
              }) {
                saved = AgentSettingsSaveValues(
                  baseUrl: baseUrl,
                  apiKey: apiKey,
                  proxyUrl: proxyUrl,
                  defaultModel: defaultModel,
                  defaultReasoningEffort: defaultReasoningEffort,
                  testModel: testModel,
                  websocketPolicy: websocketPolicy,
                  preserveCurrentProvider: preserveCurrentProvider,
                );
                savedSubagentModel = defaultSubagentModel;
              },
        ),
      );
      await tester.pumpAndSettle();

      expect(
        _text(tester, 'agent-settings-default-subagent-model'),
        'claude-haiku-4-5',
      );
      expect(
        find.text('子 Agent 默认使用的模型；留空则跟随主模型。子 Agent 的思考强度始终跟随主模型。'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('agent-settings-fetch-default-subagent-models')),
        findsOneWidget,
      );
      // 子模型字段排在默认思考强度之后、Provider 分组之前。
      expect(
        tester
            .getTopLeft(
              find.byKey(const ValueKey('agent-settings-default-subagent-model')),
            )
            .dy,
        greaterThan(
          tester
              .getTopLeft(
                find.byKey(const ValueKey('agent-settings-reasoning-effort')),
              )
              .dy,
        ),
      );

      await _enterText(
        tester,
        'agent-settings-default-subagent-model',
        '  claude-sonnet-4-6  ',
      );
      await tester.tap(find.byKey(const ValueKey('agent-settings-save')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('agent-settings-confirm-save')));
      await tester.pumpAndSettle();
      expect(savedSubagentModel, '  claude-sonnet-4-6  ');
      expect(saved?.defaultModel, 'claude-opus-5-5');
    },
  );

  testWidgets('Claude sub-agent fetch fills only the sub-agent field', (
    tester,
  ) async {
    var fetches = 0;
    await tester.pumpWidget(
      _DialogHarness(
        state: claudeState,
        onFetchModels:
            ({required baseUrl, required apiKey, required proxyUrl}) async {
              fetches += 1;
              return const [
                ApiModelOption(
                  modelId: 'claude-haiku-4-5',
                  displayName: 'Haiku 4.5',
                ),
              ];
            },
      ),
    );
    await tester.pumpAndSettle();

    final fetch = find.byKey(
      const ValueKey('agent-settings-fetch-default-subagent-models'),
    );
    await tester.ensureVisible(fetch);
    await tester.tap(fetch);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('agent-settings-model-option-claude-haiku-4-5')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(fetches, 1);
    expect(_text(tester, 'agent-settings-default-subagent-model'), 'claude-haiku-4-5');
    // 子模型选择不得顺带改写默认主模型。
    expect(_text(tester, 'agent-settings-default-model'), 'claude-opus-5-5');
  });

  testWidgets('only Claude Code offers a default sub-agent model', (
    tester,
  ) async {
    await tester.pumpWidget(
      const _DialogHarness(
        state: AppUiState(
          selectedProfileId: 'server-one',
          profiles: [ServerProfile(id: 'server-one')],
          activeAgent: AgentKind.codex,
          activeAgentCapabilities: AgentCapabilities.codex,
          agentSettingsVisible: true,
          agentSettings: AgentGlobalSettings(model: 'gpt-default'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('agent-settings-default-subagent-model')),
      findsNothing,
    );

    await tester.pumpWidget(
      const _DialogHarness(
        state: AppUiState(
          selectedProfileId: 'server-one',
          profiles: [ServerProfile(id: 'server-one')],
          activeAgent: AgentKind.openCode,
          activeAgentCapabilities: AgentCapabilities.openCode,
          agentSettingsVisible: true,
          agentSettings: AgentGlobalSettings(model: 'custom-api/gpt-test'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('agent-settings-default-subagent-model')),
      findsNothing,
    );
  });

  testWidgets(
    'Claude draft model discovery, testing and keyboard remain usable',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 800);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      AgentSettingsTestValues? tested;
      await tester.pumpWidget(
        _DialogHarness(
          state: claudeState,
          onFetchModels:
              ({required baseUrl, required apiKey, required proxyUrl}) async {
                expect(baseUrl, 'https://claude.example.test');
                expect(apiKey, 'fixture-only-key');
                return const [
                  ApiModelOption(
                    modelId: 'claude-opus-5-5',
                    displayName: 'Opus 5.5',
                  ),
                ];
              },
          onTest:
              ({
                required baseUrl,
                required apiKey,
                required proxyUrl,
                required testModel,
              }) {
                tested = AgentSettingsTestValues(
                  baseUrl: baseUrl,
                  apiKey: apiKey,
                  proxyUrl: proxyUrl,
                  testModel: testModel,
                );
              },
        ),
      );
      await tester.pumpAndSettle();
      final fetch = find.byKey(
        const ValueKey('agent-settings-fetch-test-models'),
      );
      await tester.ensureVisible(fetch);
      await tester.tap(fetch);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          const ValueKey('agent-settings-model-option-claude-opus-5-5'),
        ),
      );
      await tester.pumpAndSettle();
      final modelField = find.byKey(
        const ValueKey('agent-settings-test-model'),
      );
      expect(_text(tester, 'agent-settings-test-model'), 'claude-opus-5-5');
      await tester.ensureVisible(modelField);
      await tester.tap(modelField);
      await tester.pump();
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      expect(tester.getRect(modelField).bottom, lessThanOrEqualTo(500));
      await tester.ensureVisible(
        find.byKey(const ValueKey('agent-settings-test')),
      );
      await tester.tap(find.byKey(const ValueKey('agent-settings-test')));
      await tester.pump();
      expect(tested?.testModel, 'claude-opus-5-5');
      expect(tested?.apiKey, 'fixture-only-key');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'shows the Codex fields in Compose order and reveals the API key',
    (tester) async {
      await tester.pumpWidget(
        const _DialogHarness(
          state: AppUiState(
            selectedProfileId: 'server-one',
            profiles: [
              ServerProfile(
                id: 'server-one',
                agentModelSettings: {
                  AgentKind.codex: AgentModelSettings(testModel: 'gpt-test'),
                },
              ),
            ],
            activeAgent: AgentKind.codex,
            activeAgentCapabilities: AgentCapabilities.codex,
            agentSettingsVisible: true,
            agentSettings: AgentGlobalSettings(
              baseUrl: 'https://relay.example.com/v1',
              model: 'gpt-default',
              reasoningEffort: 'high',
              modelProvider: 'relay',
              hasStoredAuthentication: true,
              apiKey: 'sk-visible-value',
              proxyUrl: 'http://127.0.0.1:7890',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('配置 Codex'), findsOneWidget);
      expect(
        find.text('这些设置作用于当前服务器用户的全部 Codex CLI、IDE 插件和本应用会话。'),
        findsOneWidget,
      );
      expect(find.text('Provider：relay'), findsOneWidget);
      expect(find.text('默认模型：gpt-default'), findsOneWidget);
      expect(find.text('默认思考强度：高'), findsOneWidget);
      expect(find.text('模型 API 传输'), findsOneWidget);
      expect(
        find.text('仅影响当前自定义 Provider；WebSocket 连接不稳定时可选择“仅 HTTPS”。'),
        findsOneWidget,
      );
      expect(find.text('测试 HTTP API'), findsOneWidget);
      expect(
        find.text('修改模型 URL 只会更新当前 Provider；Provider 名称保持不变。'),
        findsOneWidget,
      );
      expect(find.text('支持 HTTP/HTTPS；留空会清除 Codex 代理'), findsOneWidget);

      expect(_text(tester, 'agent-settings-default-model'), 'gpt-default');
      expect(
        _text(tester, 'agent-settings-base-url'),
        'https://relay.example.com/v1',
      );
      expect(_text(tester, 'agent-settings-api-key'), 'sk-visible-value');
      expect(
        _text(tester, 'agent-settings-proxy-url'),
        'http://127.0.0.1:7890',
      );
      expect(_text(tester, 'agent-settings-test-model'), 'gpt-test');

      final orderedKeys = [
        'agent-settings-default-model',
        'agent-settings-reasoning-effort',
        'agent-settings-websocket-policy',
        'agent-settings-base-url',
        'agent-settings-api-key',
        'agent-settings-proxy-url',
        'agent-settings-test-model',
        'agent-settings-test',
        'agent-settings-save-note',
      ];
      final positions = orderedKeys
          .map((key) => tester.getTopLeft(find.byKey(ValueKey(key))).dy)
          .toList();
      expect(positions, orderedEquals([...positions]..sort()));

      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('agent-settings-api-key')),
            )
            .obscureText,
        isTrue,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('agent-settings-api-key-visibility')),
      );
      await tester.tap(
        find.byKey(const ValueKey('agent-settings-api-key-visibility')),
      );
      await tester.pump();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('agent-settings-api-key')),
            )
            .obscureText,
        isFalse,
      );
      expect(find.byTooltip('隐藏 API 密钥'), findsOneWidget);
    },
  );

  testWidgets('testing uses the edited draft and hides a stale result', (
    tester,
  ) async {
    AgentSettingsTestValues? tested;
    const state = AppUiState(
      selectedProfileId: 'server-one',
      profiles: [ServerProfile(id: 'server-one')],
      activeAgent: AgentKind.codex,
      activeAgentCapabilities: AgentCapabilities.codex,
      agentSettingsVisible: true,
      agentSettings: AgentGlobalSettings(
        baseUrl: 'https://old.example.com/v1',
        model: 'gpt-old',
        apiKey: 'sk-old',
      ),
      agentSettingsTestResult: AgentConnectionTestResult(
        successful: true,
        message: '模型 gpt-old 可用（Responses）（HTTP 200）',
      ),
    );

    await tester.pumpWidget(
      _DialogHarness(
        state: state,
        onTest:
            ({
              required baseUrl,
              required apiKey,
              required proxyUrl,
              required testModel,
            }) {
              tested = AgentSettingsTestValues(
                baseUrl: baseUrl,
                apiKey: apiKey,
                proxyUrl: proxyUrl,
                testModel: testModel,
              );
            },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('模型 gpt-old 可用（Responses）（HTTP 200）'), findsOneWidget);

    await _enterText(
      tester,
      'agent-settings-base-url',
      'https://new.example.com/v1',
    );
    await _enterText(tester, 'agent-settings-api-key', 'sk-new');
    await _enterText(
      tester,
      'agent-settings-proxy-url',
      'https://proxy.example.com:8443',
    );
    await _enterText(tester, 'agent-settings-test-model', 'gpt-new');

    expect(find.text('模型 gpt-old 可用（Responses）（HTTP 200）'), findsNothing);
    await tester.ensureVisible(
      find.byKey(const ValueKey('agent-settings-test')),
    );
    await tester.tap(find.byKey(const ValueKey('agent-settings-test')));
    await tester.pump();

    expect(
      tested,
      const AgentSettingsTestValues(
        baseUrl: 'https://new.example.com/v1',
        apiKey: 'sk-new',
        proxyUrl: 'https://proxy.example.com:8443',
        testModel: 'gpt-new',
      ),
    );
  });

  testWidgets('fetches draft API models and fills both model fields', (
    tester,
  ) async {
    final fetches = <AgentSettingsFetchValues>[];
    await tester.pumpWidget(
      _DialogHarness(
        state: const AppUiState(
          selectedProfileId: 'server-one',
          profiles: [ServerProfile(id: 'server-one')],
          activeAgent: AgentKind.codex,
          activeAgentCapabilities: AgentCapabilities.codex,
          agentSettingsVisible: true,
          agentSettings: AgentGlobalSettings(
            baseUrl: 'https://relay.example.com/v1',
            apiKey: 'sk-draft',
            proxyUrl: 'http://127.0.0.1:7890',
          ),
        ),
        onFetchModels:
            ({required baseUrl, required apiKey, required proxyUrl}) async {
              fetches.add(
                AgentSettingsFetchValues(
                  baseUrl: baseUrl,
                  apiKey: apiKey,
                  proxyUrl: proxyUrl,
                ),
              );
              return const [
                ApiModelOption(
                  modelId: 'deepseek-v4',
                  displayName: 'DeepSeek V4',
                ),
                ApiModelOption(modelId: 'gpt-5.6-sol'),
              ];
            },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('agent-settings-fetch-default-models')),
    );
    await tester.pumpAndSettle();
    expect(find.text('DeepSeek V4'), findsOneWidget);
    expect(find.text('deepseek-v4'), findsOneWidget);
    await tester.tap(find.text('DeepSeek V4'));
    await tester.pumpAndSettle();
    expect(_text(tester, 'agent-settings-default-model'), 'deepseek-v4');

    await tester.ensureVisible(
      find.byKey(const ValueKey('agent-settings-fetch-test-models')),
    );
    await tester.tap(
      find.byKey(const ValueKey('agent-settings-fetch-test-models')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('agent-settings-model-option-gpt-5.6-sol')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(_text(tester, 'agent-settings-test-model'), 'gpt-5.6-sol');
    expect(fetches, hasLength(2));
    expect(fetches.first.baseUrl, 'https://relay.example.com/v1');
    expect(fetches.first.apiKey, 'sk-draft');
    expect(fetches.first.proxyUrl, 'http://127.0.0.1:7890');
  });

  testWidgets('failed tests keep their icon and message readable', (
    tester,
  ) async {
    await tester.pumpWidget(
      const _DialogHarness(
        state: AppUiState(
          selectedProfileId: 'server-one',
          profiles: [ServerProfile(id: 'server-one')],
          activeAgent: AgentKind.codex,
          activeAgentCapabilities: AgentCapabilities.codex,
          agentSettingsVisible: true,
          agentSettings: AgentGlobalSettings(),
          agentSettingsTestResult: AgentConnectionTestResult(
            successful: false,
            message: '请输入 API 密钥后再测试',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final feedback = find.byKey(const ValueKey('agent-settings-test-feedback'));
    expect(feedback, findsOneWidget);
    expect(
      find.descendant(of: feedback, matching: find.byIcon(Icons.close)),
      findsOneWidget,
    );
    final message = tester.widget<Text>(
      find.descendant(of: feedback, matching: find.text('请输入 API 密钥后再测试')),
    );
    expect(message.style?.color, codexText);
    final decoration =
        tester.widget<Container>(feedback).decoration! as BoxDecoration;
    expect(decoration.color, codexRed.withValues(alpha: 0.14));
  });

  testWidgets('save confirms and omits an unchanged key', (tester) async {
    final saves = <AgentSettingsSaveValues>[];
    const state = AppUiState(
      selectedProfileId: 'server-one',
      profiles: [ServerProfile(id: 'server-one')],
      activeAgent: AgentKind.codex,
      activeAgentCapabilities: AgentCapabilities.codex,
      agentSettingsVisible: true,
      agentSettings: AgentGlobalSettings(
        baseUrl: 'https://relay.example.com/v1',
        model: 'gpt-default',
        reasoningEffort: 'high',
        modelProvider: 'relay',
        apiKey: 'sk-current',
      ),
    );

    await tester.pumpWidget(
      _DialogHarness(
        state: state,
        onSave:
            ({
              required baseUrl,
              required apiKey,
              required proxyUrl,
              required defaultModel,
              required defaultSubagentModel,
              required defaultReasoningEffort,
              required testModel,
              required websocketPolicy,
              required preserveCurrentProvider,
              required contextLimit,
            }) {
              saves.add(
                AgentSettingsSaveValues(
                  baseUrl: baseUrl,
                  apiKey: apiKey,
                  proxyUrl: proxyUrl,
                  defaultModel: defaultModel,
                  defaultReasoningEffort: defaultReasoningEffort,
                  testModel: testModel,
                  websocketPolicy: websocketPolicy,
                  preserveCurrentProvider: preserveCurrentProvider,
                ),
              );
            },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('agent-settings-save')));
    await tester.pumpAndSettle();
    expect(find.text('确认保存全局配置'), findsOneWidget);
    expect(
      find.text('保存会更新此服务器用户的 Codex 配置并断开当前连接。已填写的 API 密钥会替换现有登录。'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('agent-settings-confirm-back')));
    await tester.pumpAndSettle();
    expect(saves, isEmpty);

    await tester.tap(find.byKey(const ValueKey('agent-settings-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('agent-settings-confirm-save')));
    await tester.pumpAndSettle();
    expect(saves, hasLength(1));
    expect(saves.single.apiKey, isEmpty);
    expect(saves.single.websocketPolicy, 'auto');
    expect(saves.single.preserveCurrentProvider, isTrue);

    await _enterText(
      tester,
      'agent-settings-base-url',
      'https://other.example.com/v1',
    );
    await _enterText(tester, 'agent-settings-api-key', 'sk-replacement');
    await tester.tap(find.byKey(const ValueKey('agent-settings-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('agent-settings-confirm-save')));
    await tester.pumpAndSettle();

    expect(saves, hasLength(2));
    expect(saves.last.apiKey, 'sk-replacement');
    expect(saves.last.preserveCurrentProvider, isTrue);
    expect(saves.last.baseUrl, 'https://other.example.com/v1');
  });

  testWidgets('saving and testing block dismissal while loading can close', (
    tester,
  ) async {
    var dismissed = false;
    await tester.pumpWidget(
      _DialogHarness(
        state: const AppUiState(
          activeAgent: AgentKind.codex,
          activeAgentCapabilities: AgentCapabilities.codex,
          agentSettingsVisible: true,
          agentSettingsLoading: true,
        ),
        onDismiss: () => dismissed = true,
      ),
    );
    await tester.pump();

    expect(find.text('正在读取服务器上的全局配置'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('agent-settings-default-model')),
      findsNothing,
    );
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey('agent-settings-dismiss')),
          )
          .onPressed,
      isNotNull,
    );
    await tester.tapAt(const Offset(2, 2));
    await tester.pump();
    expect(dismissed, isTrue);

    dismissed = false;

    await tester.pumpWidget(
      _DialogHarness(
        state: const AppUiState(
          activeAgent: AgentKind.codex,
          activeAgentCapabilities: AgentCapabilities.codex,
          agentSettingsVisible: true,
          agentSettingsTesting: true,
          agentSettings: AgentGlobalSettings(model: 'gpt-test'),
        ),
        onDismiss: () => dismissed = true,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(find.text('正在测试'), findsOneWidget);
    final progress = tester.widget<CircularProgressIndicator>(
      find.descendant(
        of: find.byKey(const ValueKey('agent-settings-test')),
        matching: find.byType(CircularProgressIndicator),
      ),
    );
    expect(progress.value, isNull);
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('agent-settings-test')),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('agent-settings-base-url')),
          )
          .enabled,
      isFalse,
    );
  });

  testWidgets(
    'OpenCode copy and keyboard inset keep the focused field visible',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 800);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      await tester.pumpWidget(
        const _DialogHarness(
          state: AppUiState(
            selectedProfileId: 'server-one',
            profiles: [ServerProfile(id: 'server-one')],
            activeAgent: AgentKind.openCode,
            activeAgentCapabilities: AgentCapabilities.openCode,
            agentSettingsVisible: true,
            agentSettings: AgentGlobalSettings(
              modelProvider: 'custom-api',
              model: 'custom-api/gpt-test',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('配置 OpenCode'), findsOneWidget);
      expect(find.text('这些设置作用于当前服务器用户的 OpenCode CLI 和本应用会话。'), findsOneWidget);
      expect(find.text('支持 HTTP/HTTPS；留空会清除 OpenCode 代理'), findsOneWidget);

      final testModel = find.byKey(const ValueKey('agent-settings-test-model'));
      await tester.ensureVisible(testModel);
      await tester.tap(testModel);
      await tester.pump();
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();

      final focusedField = tester.getRect(testModel);
      expect(focusedField.bottom, lessThanOrEqualTo(500));
      expect(tester.takeException(), isNull);
    },
  );
}

class _DialogHarness extends StatelessWidget {
  const _DialogHarness({
    required this.state,
    this.onFetchModels = _noopFetchModels,
    this.onTest = _noopTest,
    this.onSave = _noopSave,
    this.onDismiss = _noop,
  });

  final AppUiState state;
  final AgentSettingsFetchModelsCallback onFetchModels;
  final AgentSettingsTestCallback onTest;
  final AgentSettingsSaveCallback onSave;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: buildCodexTheme(),
      home: Scaffold(
        body: Stack(
          fit: StackFit.expand,
          children: [
            const SizedBox.expand(),
            AgentSettingsDialog(
              state: state,
              onFetchModels: onFetchModels,
              onTest: onTest,
              onSave: onSave,
              onDismiss: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}

@immutable
class AgentSettingsFetchValues {
  const AgentSettingsFetchValues({
    required this.baseUrl,
    required this.apiKey,
    required this.proxyUrl,
  });

  final String baseUrl;
  final String apiKey;
  final String proxyUrl;
}

@immutable
class AgentSettingsTestValues {
  const AgentSettingsTestValues({
    required this.baseUrl,
    required this.apiKey,
    required this.proxyUrl,
    required this.testModel,
  });

  final String baseUrl;
  final String apiKey;
  final String proxyUrl;
  final String testModel;

  @override
  bool operator ==(Object other) =>
      other is AgentSettingsTestValues &&
      baseUrl == other.baseUrl &&
      apiKey == other.apiKey &&
      proxyUrl == other.proxyUrl &&
      testModel == other.testModel;

  @override
  int get hashCode => Object.hash(baseUrl, apiKey, proxyUrl, testModel);
}

@immutable
class AgentSettingsSaveValues {
  const AgentSettingsSaveValues({
    required this.baseUrl,
    required this.apiKey,
    required this.proxyUrl,
    required this.defaultModel,
    required this.defaultReasoningEffort,
    required this.testModel,
    required this.websocketPolicy,
    required this.preserveCurrentProvider,
  });

  final String baseUrl;
  final String apiKey;
  final String proxyUrl;
  final String defaultModel;
  final String defaultReasoningEffort;
  final String testModel;
  final String websocketPolicy;
  final bool preserveCurrentProvider;
}

String _text(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;

Future<void> _enterText(WidgetTester tester, String key, String value) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.enterText(finder, value);
  await tester.pump();
}

void _noop() {}

Future<List<ApiModelOption>> _noopFetchModels({
  required String baseUrl,
  required String apiKey,
  required String proxyUrl,
}) async => const <ApiModelOption>[];

void _noopTest({
  required String baseUrl,
  required String apiKey,
  required String proxyUrl,
  required String testModel,
}) {}

void _noopSave({
  required String baseUrl,
  required String apiKey,
  required String proxyUrl,
  required String defaultModel,
  required String defaultSubagentModel,
  required String defaultReasoningEffort,
  required String testModel,
  required String websocketPolicy,
  required bool preserveCurrentProvider,
  required int contextLimit,
}) {}
