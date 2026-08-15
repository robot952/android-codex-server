import 'package:flutter/material.dart';

import '../domain/models.dart';
import 'theme.dart';

typedef AgentSettingsTestCallback =
    void Function({
      required String baseUrl,
      required String apiKey,
      required String proxyUrl,
      required String testModel,
    });

typedef AgentSettingsSaveCallback =
    void Function({
      required String baseUrl,
      required String apiKey,
      required String proxyUrl,
      required String defaultModel,
      required String defaultReasoningEffort,
      required String testModel,
      required bool preserveCurrentProvider,
    });

class AgentSettingsDialog extends StatefulWidget {
  const AgentSettingsDialog({
    required this.state,
    required this.onTest,
    required this.onSave,
    required this.onDismiss,
    super.key,
  });

  final AppUiState state;
  final AgentSettingsTestCallback onTest;
  final AgentSettingsSaveCallback onSave;
  final VoidCallback onDismiss;

  @override
  State<AgentSettingsDialog> createState() => _AgentSettingsDialogState();
}

class _AgentSettingsDialogState extends State<AgentSettingsDialog> {
  final _scrollController = ScrollController();
  late final TextEditingController _defaultModelController;
  late final TextEditingController _baseUrlController;
  late final TextEditingController _apiKeyController;
  late final TextEditingController _proxyUrlController;
  late final TextEditingController _testModelController;

  String _defaultReasoningEffort = '';
  bool _apiKeyVisible = false;
  bool _testResultStale = false;

  @override
  void initState() {
    super.initState();
    _defaultModelController = TextEditingController();
    _baseUrlController = TextEditingController();
    _apiKeyController = TextEditingController();
    _proxyUrlController = TextEditingController();
    _testModelController = TextEditingController();
    _applyRemoteSettings();
    if (_testFeedback != null) _scrollToFeedback();
  }

  @override
  void didUpdateWidget(covariant AgentSettingsDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldAgent = oldWidget.state.activeAgent;
    final oldSettings = oldWidget.state.agentSettings;
    final oldSavedTestModel = _savedTestModel(oldWidget.state);
    final oldFeedback = _feedbackFor(oldWidget.state, stale: _testResultStale);

    if (oldAgent != widget.state.activeAgent ||
        oldSettings != widget.state.agentSettings) {
      _applyRemoteSettings();
      _apiKeyVisible = false;
      _testResultStale = false;
    } else if (oldSavedTestModel != _savedTestModel(widget.state)) {
      _testModelController.text = _initialTestModel(widget.state);
      _testResultStale = false;
    }

    final feedback = _testFeedback;
    if (feedback != null && feedback != oldFeedback) _scrollToFeedback();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _defaultModelController.dispose();
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    _proxyUrlController.dispose();
    _testModelController.dispose();
    super.dispose();
  }

  bool get _busy {
    final state = widget.state;
    return state.agentSettingsLoading ||
        state.agentSettingsSaving ||
        state.agentSettingsTesting;
  }

  bool get _canDismiss {
    final state = widget.state;
    return !state.agentSettingsSaving && !state.agentSettingsTesting;
  }

  String? get _testFeedback =>
      _feedbackFor(widget.state, stale: _testResultStale);

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final settings = state.agentSettings;
    final settingsReady = settings != null;
    final agent = state.activeAgent;
    final agentName = agent.label;
    final defaultProviderId = agent == AgentKind.codex
        ? 'openai'
        : 'custom-api';
    final configuredProvider = settings?.modelProvider.trim();
    final customProviderInUse =
        settings != null &&
        configuredProvider != null &&
        configuredProvider != defaultProviderId;
    final preserveCurrentProvider = agent == AgentKind.codex
        ? settingsReady
        : customProviderInUse &&
              _normalizedUrl(_baseUrlController.text) ==
                  _normalizedUrl(settings.baseUrl);

    return Positioned.fill(
      key: const ValueKey('agent-settings-overlay'),
      child: Semantics(
        container: true,
        scopesRoute: true,
        explicitChildNodes: true,
        label: '配置 $agentName',
        child: Stack(
          children: [
            ModalBarrier(
              dismissible: _canDismiss,
              onDismiss: _canDismiss ? widget.onDismiss : null,
              color: Colors.black.withValues(alpha: 0.58),
            ),
            Center(
              child: SafeArea(
                minimum: const EdgeInsets.all(16),
                child: Dialog(
                  insetPadding: EdgeInsets.zero,
                  clipBehavior: Clip.antiAlias,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: 560,
                      maxHeight: 720,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _DialogHeading(agentName: agentName),
                        const Divider(height: 1),
                        Flexible(
                          child: Scrollbar(
                            controller: _scrollController,
                            child: SingleChildScrollView(
                              key: const ValueKey('agent-settings-scroll'),
                              controller: _scrollController,
                              keyboardDismissBehavior:
                                  ScrollViewKeyboardDismissBehavior.onDrag,
                              padding: const EdgeInsets.fromLTRB(
                                18,
                                16,
                                18,
                                18,
                              ),
                              child: state.agentSettingsLoading
                                  ? const _LoadingSettings()
                                  : _SettingsForm(
                                      agent: agent,
                                      settings: settings,
                                      enabled: !_busy && settingsReady,
                                      customProviderInUse: customProviderInUse,
                                      preserveCurrentProvider:
                                          preserveCurrentProvider,
                                      defaultProviderId: defaultProviderId,
                                      defaultModelController:
                                          _defaultModelController,
                                      baseUrlController: _baseUrlController,
                                      apiKeyController: _apiKeyController,
                                      proxyUrlController: _proxyUrlController,
                                      testModelController: _testModelController,
                                      defaultReasoningEffort:
                                          _defaultReasoningEffort,
                                      apiKeyVisible: _apiKeyVisible,
                                      testFeedback: _testFeedback,
                                      testSuccessful:
                                          !_testResultStale &&
                                          state
                                                  .agentSettingsTestResult
                                                  ?.successful ==
                                              true,
                                      testing: state.agentSettingsTesting,
                                      reasoningSettingsAvailable: state
                                          .activeAgentCapabilities
                                          .reasoningEffort,
                                      onDefaultReasoningEffortChanged: (value) {
                                        setState(() {
                                          _defaultReasoningEffort = value;
                                        });
                                      },
                                      onApiKeyVisibilityChanged: () {
                                        setState(() {
                                          _apiKeyVisible = !_apiKeyVisible;
                                        });
                                      },
                                      onTestRelevantValueChanged:
                                          _markTestResultStale,
                                      onTest: _testSettings,
                                    ),
                            ),
                          ),
                        ),
                        const Divider(height: 1),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                          child: Wrap(
                            alignment: WrapAlignment.end,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              TextButton(
                                key: const ValueKey('agent-settings-dismiss'),
                                onPressed: _canDismiss
                                    ? widget.onDismiss
                                    : null,
                                child: const Text('取消'),
                              ),
                              FilledButton(
                                key: const ValueKey('agent-settings-save'),
                                onPressed: !_busy && settingsReady
                                    ? () => _confirmSave(
                                        preserveCurrentProvider:
                                            preserveCurrentProvider,
                                      )
                                    : null,
                                child: const Text('保存'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _applyRemoteSettings() {
    final settings = widget.state.agentSettings;
    _defaultModelController.text = settings?.model ?? '';
    _baseUrlController.text = settings?.baseUrl ?? '';
    _apiKeyController.text = settings?.apiKey ?? '';
    _proxyUrlController.text = settings?.proxyUrl ?? '';
    _defaultReasoningEffort = settings?.reasoningEffort ?? '';
    _testModelController.text = _initialTestModel(widget.state);
  }

  void _markTestResultStale() {
    if (_testResultStale) {
      setState(() {});
    } else {
      setState(() => _testResultStale = true);
    }
  }

  void _testSettings() {
    if (_busy || widget.state.agentSettings == null) return;
    setState(() => _testResultStale = false);
    widget.onTest(
      baseUrl: _baseUrlController.text,
      apiKey: _apiKeyController.text,
      proxyUrl: _proxyUrlController.text,
      testModel: _testModelController.text,
    );
  }

  Future<void> _confirmSave({required bool preserveCurrentProvider}) async {
    if (_busy || widget.state.agentSettings == null) return;
    FocusScope.of(context).unfocus();
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('agent-settings-save-confirmation'),
        title: const Text('确认保存全局配置'),
        content: Text(
          '保存会更新此服务器用户的 ${widget.state.activeAgent.label} 配置并断开当前连接。'
          '已填写的 API 密钥会替换现有登录。',
        ),
        actions: [
          TextButton(
            key: const ValueKey('agent-settings-confirm-back'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('返回修改'),
          ),
          FilledButton(
            key: const ValueKey('agent-settings-confirm-save'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('确认保存'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;

    final remoteApiKey = widget.state.agentSettings?.apiKey ?? '';
    final enteredApiKey = _apiKeyController.text;
    widget.onSave(
      baseUrl: _baseUrlController.text,
      apiKey: preserveCurrentProvider && enteredApiKey == remoteApiKey
          ? ''
          : enteredApiKey,
      proxyUrl: _proxyUrlController.text,
      defaultModel: _defaultModelController.text,
      defaultReasoningEffort: _defaultReasoningEffort,
      testModel: _testModelController.text,
      preserveCurrentProvider: preserveCurrentProvider,
    );
  }

  void _scrollToFeedback() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
  }
}

class _DialogHeading extends StatelessWidget {
  const _DialogHeading({required this.agentName});

  final String agentName;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 15, 14, 14),
      child: Row(
        children: [
          Icon(
            Icons.settings_outlined,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '配置 $agentName',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
        ],
      ),
    );
  }
}

class _LoadingSettings extends StatelessWidget {
  const _LoadingSettings();

  @override
  Widget build(BuildContext context) {
    return const Row(
      key: ValueKey('agent-settings-loading'),
      children: [
        SizedBox.square(
          dimension: 19,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        SizedBox(width: 10),
        Expanded(child: Text('正在读取服务器上的全局配置')),
      ],
    );
  }
}

class _SettingsForm extends StatelessWidget {
  const _SettingsForm({
    required this.agent,
    required this.settings,
    required this.enabled,
    required this.customProviderInUse,
    required this.preserveCurrentProvider,
    required this.defaultProviderId,
    required this.defaultModelController,
    required this.baseUrlController,
    required this.apiKeyController,
    required this.proxyUrlController,
    required this.testModelController,
    required this.defaultReasoningEffort,
    required this.apiKeyVisible,
    required this.testFeedback,
    required this.testSuccessful,
    required this.testing,
    required this.reasoningSettingsAvailable,
    required this.onDefaultReasoningEffortChanged,
    required this.onApiKeyVisibilityChanged,
    required this.onTestRelevantValueChanged,
    required this.onTest,
  });

  final AgentKind agent;
  final AgentGlobalSettings? settings;
  final bool enabled;
  final bool customProviderInUse;
  final bool preserveCurrentProvider;
  final String defaultProviderId;
  final TextEditingController defaultModelController;
  final TextEditingController baseUrlController;
  final TextEditingController apiKeyController;
  final TextEditingController proxyUrlController;
  final TextEditingController testModelController;
  final String defaultReasoningEffort;
  final bool apiKeyVisible;
  final String? testFeedback;
  final bool testSuccessful;
  final bool testing;
  final bool reasoningSettingsAvailable;
  final ValueChanged<String> onDefaultReasoningEffortChanged;
  final VoidCallback onApiKeyVisibilityChanged;
  final VoidCallback onTestRelevantValueChanged;
  final VoidCallback onTest;

  @override
  Widget build(BuildContext context) {
    final agentName = agent.label;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          agent == AgentKind.codex
              ? '这些设置作用于当前服务器用户的全部 Codex CLI、IDE 插件和本应用会话。'
              : '这些设置作用于当前服务器用户的 OpenCode CLI 和本应用会话。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 11),
        _CurrentSettingsPanel(
          agent: agent,
          settings: settings,
          defaultProviderId: defaultProviderId,
          customProviderInUse: customProviderInUse,
          preserveCurrentProvider: preserveCurrentProvider,
          reasoningSettingsAvailable: reasoningSettingsAvailable,
        ),
        const SizedBox(height: 11),
        TextField(
          key: const ValueKey('agent-settings-default-model'),
          controller: defaultModelController,
          enabled: enabled,
          autocorrect: false,
          enableSuggestions: false,
          scrollPadding: _fieldScrollPadding,
          decoration: InputDecoration(
            labelText: '默认模型',
            hintText: agent == AgentKind.codex
                ? 'gpt-5.6-sol'
                : 'custom-api/model-id',
            helperText: '留空使用 $agentName 默认模型；保存后对新会话生效',
            helperMaxLines: 3,
          ),
        ),
        if (reasoningSettingsAvailable) ...[
          const SizedBox(height: 11),
          Text('默认思考强度', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 7),
          _ReasoningEffortSelector(
            value: defaultReasoningEffort,
            enabled: enabled,
            onChanged: onDefaultReasoningEffortChanged,
          ),
          const SizedBox(height: 5),
          Text(
            '留空使用当前 Agent 的默认思考强度。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: 11),
        TextField(
          key: const ValueKey('agent-settings-base-url'),
          controller: baseUrlController,
          enabled: enabled,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.url,
          scrollPadding: _fieldScrollPadding,
          onChanged: (_) => onTestRelevantValueChanged(),
          decoration: InputDecoration(
            labelText: '模型 URL',
            hintText: 'https://api.openai.com/v1',
            helperText: agent == AgentKind.codex
                ? '留空使用 Codex 默认 OpenAI 地址'
                : 'OpenAI 兼容地址；用于 OpenCode 的 Codex Remote Provider',
            helperMaxLines: 3,
          ),
        ),
        const SizedBox(height: 11),
        TextField(
          key: const ValueKey('agent-settings-api-key'),
          controller: apiKeyController,
          enabled: enabled,
          autocorrect: false,
          enableSuggestions: false,
          obscureText: !apiKeyVisible,
          keyboardType: TextInputType.visiblePassword,
          scrollPadding: _fieldScrollPadding,
          onChanged: (_) => onTestRelevantValueChanged(),
          decoration: InputDecoration(
            labelText: 'API 密钥',
            helperText: _apiKeySupportingText(settings),
            helperMaxLines: 3,
            suffixIcon: IconButton(
              key: const ValueKey('agent-settings-api-key-visibility'),
              tooltip: apiKeyVisible ? '隐藏 API 密钥' : '显示 API 密钥',
              onPressed: enabled ? onApiKeyVisibilityChanged : null,
              icon: Icon(
                apiKeyVisible ? Icons.visibility_off : Icons.visibility,
              ),
            ),
          ),
        ),
        const SizedBox(height: 11),
        TextField(
          key: const ValueKey('agent-settings-proxy-url'),
          controller: proxyUrlController,
          enabled: enabled,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.url,
          scrollPadding: _fieldScrollPadding,
          onChanged: (_) => onTestRelevantValueChanged(),
          decoration: InputDecoration(
            labelText: '$agentName 代理（可选）',
            hintText: 'http://127.0.0.1:7890',
            helperText: '支持 HTTP/HTTPS；留空会清除 $agentName 代理',
            helperMaxLines: 3,
          ),
        ),
        const SizedBox(height: 11),
        TextField(
          key: const ValueKey('agent-settings-test-model'),
          controller: testModelController,
          enabled: enabled,
          autocorrect: false,
          enableSuggestions: false,
          scrollPadding: _fieldScrollPadding,
          onChanged: (_) => onTestRelevantValueChanged(),
          decoration: InputDecoration(
            labelText: '测试模型',
            hintText: agent == AgentKind.codex
                ? 'gpt-5.6-sol'
                : 'custom-api/model-id',
            helperText: '保存后按当前服务器记住',
            helperMaxLines: 2,
          ),
        ),
        const SizedBox(height: 11),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            key: const ValueKey('agent-settings-test'),
            onPressed: enabled ? onTest : null,
            icon: testing
                ? const SizedBox.square(
                    dimension: 17,
                    // A determinate ring keeps this compact button visually
                    // busy without an unbounded ticker while the RPC runs.
                    child: CircularProgressIndicator(
                      value: 0.32,
                      strokeWidth: 2,
                    ),
                  )
                : const Icon(Icons.network_check, size: 18),
            label: Text(testing ? '正在测试' : '测试连接'),
          ),
        ),
        if (testFeedback != null) ...[
          const SizedBox(height: 11),
          _TestFeedback(message: testFeedback!, successful: testSuccessful),
        ],
        const SizedBox(height: 11),
        Container(
          key: const ValueKey('agent-settings-save-note'),
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
            color: codexSurface,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            '测试不会保存或断开连接。保存后会断开当前服务器；修改 API 密钥才会替换该用户现有的 $agentName 登录。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

class _CurrentSettingsPanel extends StatelessWidget {
  const _CurrentSettingsPanel({
    required this.agent,
    required this.settings,
    required this.defaultProviderId,
    required this.customProviderInUse,
    required this.preserveCurrentProvider,
    required this.reasoningSettingsAvailable,
  });

  final AgentKind agent;
  final AgentGlobalSettings? settings;
  final String defaultProviderId;
  final bool customProviderInUse;
  final bool preserveCurrentProvider;
  final bool reasoningSettingsAvailable;

  @override
  Widget build(BuildContext context) {
    final provider = settings?.modelProvider.trim();
    final model = settings?.model.trim();
    return Container(
      key: const ValueKey('agent-settings-current-configuration'),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: codexSurface,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('服务器当前配置', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
          Text(
            'Provider：${provider?.isNotEmpty == true ? provider : defaultProviderId}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          Text(
            '默认模型：${model?.isNotEmpty == true ? model : '未配置，使用 ${agent.label} 默认值'}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (reasoningSettingsAvailable) ...[
            const SizedBox(height: 4),
            Text(
              '默认思考强度：${reasoningEffortLabel(settings?.reasoningEffort ?? '')}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          if (customProviderInUse) ...[
            const SizedBox(height: 4),
            Text(
              agent == AgentKind.codex
                  ? '修改模型 URL 只会更新当前 Provider；Provider 名称保持不变。'
                  : preserveCurrentProvider
                  ? '当前使用自定义 Provider；保持模型 URL 不变会继续使用该 Provider。'
                  : '修改模型 URL 后会切换到 Codex Remote 管理的 OpenCode Provider。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ReasoningEffortSelector extends StatelessWidget {
  const _ReasoningEffortSelector({
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final String value;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final options = <String>[...reasoningEffortOptions];
    if (!options.contains(value)) options.add(value);
    return Container(
      decoration: BoxDecoration(
        color: codexSurface,
        border: Border.all(color: codexBorder),
        borderRadius: BorderRadius.circular(6),
      ),
      padding: const EdgeInsets.only(left: 12),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          key: const ValueKey('agent-settings-reasoning-effort'),
          value: value,
          isExpanded: true,
          borderRadius: BorderRadius.circular(6),
          dropdownColor: codexRaised,
          onChanged: enabled
              ? (selected) {
                  if (selected != null) onChanged(selected);
                }
              : null,
          items: options
              .map(
                (effort) => DropdownMenuItem<String>(
                  value: effort,
                  child: Text(
                    reasoningEffortLabel(effort),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}

class _TestFeedback extends StatelessWidget {
  const _TestFeedback({required this.message, required this.successful});

  final String message;
  final bool successful;

  @override
  Widget build(BuildContext context) {
    final accent = successful ? codexGreen : codexRed;
    return Container(
      key: const ValueKey('agent-settings-test-feedback'),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.14),
        border: Border.all(color: accent.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(successful ? Icons.check : Icons.close, size: 18, color: accent),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              message,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: codexText),
            ),
          ),
        ],
      ),
    );
  }
}

const reasoningEffortOptions = <String>[
  '',
  'minimal',
  'low',
  'medium',
  'high',
  'xhigh',
];

String reasoningEffortLabel(String effort) => switch (effort) {
  '' => '默认（由 Agent 决定）',
  'minimal' => '极低',
  'low' => '低',
  'medium' => '中',
  'high' => '高',
  'xhigh' => '极高',
  _ => effort,
};

const _fieldScrollPadding = EdgeInsets.only(bottom: 140);

String _apiKeySupportingText(AgentGlobalSettings? settings) {
  if (settings?.apiKey.isNotEmpty == true) {
    return '已读取服务器 API 密钥，仅在当前设置页面的内存中保留。';
  }
  if (settings?.hasStoredAuthentication == true) {
    return '服务器使用非 API 密钥登录，无法显示密钥；填写可替换登录。';
  }
  return '留空不会创建或修改登录信息。';
}

String _initialTestModel(AppUiState state) {
  final saved = _savedTestModel(state);
  return saved.trim().isNotEmpty ? saved : state.agentSettings?.model ?? '';
}

String _savedTestModel(AppUiState state) {
  final selectedProfileId = state.selectedProfileId;
  if (selectedProfileId == null) return '';
  for (final profile in state.profiles) {
    if (profile.id == selectedProfileId) {
      return profile.modelSettings(state.activeAgent).testModel;
    }
  }
  return '';
}

String? _feedbackFor(AppUiState state, {required bool stale}) {
  if (!stale) {
    final result = state.agentSettingsTestResult;
    if (result != null) return result.message;
  }
  final error = state.agentSettingsError?.trim();
  return error?.isNotEmpty == true ? error : null;
}

String _normalizedUrl(String value) =>
    value.trim().replaceFirst(RegExp(r'/+$'), '');
