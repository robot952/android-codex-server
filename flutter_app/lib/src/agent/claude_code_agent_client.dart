import 'dart:async';

import '../domain/models.dart';
import '../ssh/ssh_server_client.dart';
import 'claude_code_bootstrap.dart';
import 'claude_code_bridge_asset.dart';
import 'codex_agent_client.dart';
import 'remote_agent_client.dart';
import 'remote_bootstrap.dart';

typedef ClaudeCodeBridgeLoader = Future<String> Function();

class ClaudeCodeAgentClient extends CodexAgentClient
    implements RemoteAgentRuntimeClient {
  ClaudeCodeAgentClient({
    super.clientVersion,
    super.requestTimeout,
    super.threadRequestTimeout,
    super.maxLineChars,
    super.sessionOpener,
    super.dedicatedHostFactory,
    ClaudeCodeBridgeLoader? bridgeLoader,
  }) : _bridgeLoader = bridgeLoader ?? ClaudeCodeBridgeAsset.load,
       super(processAgent: AgentKind.claudeCode);

  final ClaudeCodeBridgeLoader _bridgeLoader;

  @override
  AgentKind get kind => AgentKind.claudeCode;

  @override
  AgentCapabilities get capabilities => AgentCapabilities.claudeCode;

  @override
  Future<AgentRuntimeInspection> inspectRuntime(
    ServerProfile profile,
    RemoteServerClient host,
  ) async {
    if (host is LocalRemoteServerClient) {
      throw UnsupportedError('Claude Code 本机启动暂不支持，请使用 SSH 服务器');
    }
    final scriptHost = host is RemoteServerScriptClient
        ? host as RemoteServerScriptClient
        : throw UnsupportedError('当前 SSH 客户端不支持安全执行探测脚本');
    final source = await _bridgeLoader();
    final output = await scriptHost.runShellScript(
      ClaudeCodeBootstrap.combinedProbeScript,
      timeout: const Duration(seconds: 30),
      maxOutputBytes: 64 * 1024,
    );
    return ClaudeCodeBootstrap.inspect(output, bridgeSource: source);
  }

  @override
  Future<void> installRuntime(
    ServerProfile profile,
    RemoteServerClient host, {
    required void Function(RemoteInstallProgress progress) onProgress,
  }) async {
    if (host is LocalRemoteServerClient) {
      throw UnsupportedError('Claude Code 本机启动暂不支持，请使用 SSH 服务器');
    }
    final scriptHost = host is RemoteServerStreamingScriptClient
        ? host as RemoteServerStreamingScriptClient
        : throw UnsupportedError('当前 SSH 客户端不支持流式执行安装脚本');
    final source = await _bridgeLoader();
    onProgress(
      const RemoteInstallProgress(percent: 5, message: '检查 Claude Code CLI'),
    );
    await scriptHost.runStreamingShellScript(
      ClaudeCodeBootstrap.installScript(bridgeSource: source),
      command: remoteInstallCommand,
      timeout: const Duration(minutes: 5),
      maxOutputBytes: 2 * 1024 * 1024,
      onStdoutLine: (line) {
        final progress = parseRemoteInstallProgressLine(line);
        if (progress != null) onProgress(progress);
      },
    );
    onProgress(
      const RemoteInstallProgress(
        percent: 100,
        message: 'Claude Code bridge 安装完成',
      ),
    );
  }

  @override
  Future<void> uninstallRuntime(
    ServerProfile profile,
    RemoteServerClient host,
  ) async {
    await disconnect();
    if (host is LocalRemoteServerClient) {
      throw UnsupportedError('Claude Code 本机启动暂不支持，请使用 SSH 服务器');
    }
    final scriptHost = host is RemoteServerScriptClient
        ? host as RemoteServerScriptClient
        : throw UnsupportedError('当前 SSH 客户端不支持安全执行卸载脚本');
    await scriptHost.runShellScript(
      ClaudeCodeBootstrap.uninstallScript,
      timeout: const Duration(minutes: 1),
      maxOutputBytes: 64 * 1024,
    );
  }

  @override
  Future<void> connect(ServerProfile profile, RemoteServerClient host) {
    if (host is LocalRemoteServerClient) {
      throw UnsupportedError('Claude Code 本机启动暂不支持，请使用 SSH 服务器');
    }
    final command = buildClaudeCodeBridgeCommand(profile.workspace);
    final connectionProfile = profile.copyWith(
      workspace: '',
      remoteCommand: command,
    );
    return super.connect(connectionProfile, host);
  }

  @override
  String buildSessionCommand(ServerProfile profile) =>
      'exec ${profile.remoteCommand}';

  @override
  Future<AgentGlobalSettings> readGlobalSettings(ServerProfile profile) async {
    final value = _settingsMap(
      await requestAdapterExtension(
        'agent/settings/read',
        timeout: const Duration(seconds: 30),
      ),
    );
    return AgentGlobalSettings(
      baseUrl: _settingsString(value, 'baseUrl'),
      model: _settingsString(value, 'model'),
      subagentModel: _settingsString(value, 'subagentModel'),
      reasoningEffort: _settingsString(value, 'reasoningEffort'),
      modelProvider: 'anthropic',
      apiKey: _settingsString(value, 'apiKey'),
      proxyUrl: _settingsString(value, 'proxyUrl'),
      hasStoredAuthentication: value['hasStoredAuthentication'] == true,
      contextWindowTokens: _settingsTokens(value['contextWindowTokens']),
    );
  }

  @override
  Future<void> writeGlobalSettings(
    ServerProfile profile, {
    required String baseUrl,
    required String apiKey,
    required String proxyUrl,
    required String defaultModel,
    String defaultSubagentModel = '',
    required String defaultReasoningEffort,
    String? websocketPolicy,
    required bool preserveCurrentProvider,
    int contextLimit = 0,
  }) async {
    await requestAdapterExtension(
      'agent/settings/write',
      params: <String, Object?>{
        'baseUrl': baseUrl.trim(),
        'apiKey': apiKey.trim(),
        'proxyUrl': proxyUrl.trim(),
        'defaultModel': defaultModel.trim(),
        'defaultSubagentModel': defaultSubagentModel.trim(),
        'defaultReasoningEffort': defaultReasoningEffort.trim(),
        'contextLimit': contextLimit,
      },
      timeout: const Duration(seconds: 30),
    );
  }

  @override
  Future<AgentConnectionTestResult> testGlobalSettings(
    ServerProfile profile, {
    required String baseUrl,
    required String apiKey,
    required String proxyUrl,
    required String testModel,
    ModelApiProtocol? apiProtocol,
  }) async {
    final value = _settingsMap(
      await requestAdapterExtension(
        'agent/settings/test',
        params: <String, Object?>{
          'baseUrl': baseUrl.trim(),
          'apiKey': apiKey.trim(),
          'proxyUrl': proxyUrl.trim(),
          'testModel': testModel.trim(),
        },
        timeout: const Duration(seconds: 45),
      ),
    );
    return AgentConnectionTestResult(
      successful: value['successful'] == true,
      message: _settingsString(value, 'message'),
    );
  }

  @override
  Future<List<ApiModelOption>> fetchApiModels(
    ServerProfile profile, {
    required String baseUrl,
    required String apiKey,
    required String proxyUrl,
  }) async {
    final value = await requestAdapterExtension(
      'agent/models/list',
      params: <String, Object?>{
        'baseUrl': baseUrl.trim(),
        'apiKey': apiKey.trim(),
        'proxyUrl': proxyUrl.trim(),
      },
      timeout: const Duration(seconds: 45),
    );
    if (value is! List) throw const FormatException('Claude Code 模型列表无效');
    final ids = <String>{};
    final options = <ApiModelOption>[];
    for (final item in value.take(2000)) {
      if (item is! Map) continue;
      final modelId = _settingsString(item, 'modelId').trim();
      if (modelId.isEmpty || modelId.length > 256 || !ids.add(modelId)) {
        continue;
      }
      options.add(
        ApiModelOption(
          modelId: modelId,
          displayName: _settingsString(item, 'displayName'),
          contextWindowTokens: _settingsTokens(item['contextWindowTokens']),
          maxOutputTokens: _settingsTokens(item['maxOutputTokens']),
        ),
      );
    }
    return options;
  }
}

Map<dynamic, dynamic> _settingsMap(Object? value) {
  if (value is! Map) throw const FormatException('Claude Code 配置响应无效');
  return value;
}

String _settingsString(Map<dynamic, dynamic> value, String key) =>
    value[key] is String ? value[key] as String : '';

int _settingsTokens(Object? value) =>
    value is int && value > 0 && value <= 100000000 ? value : 0;

String buildClaudeCodeBridgeCommand(String workspace) {
  final directory = workspace.trim();
  return directory.isEmpty
      ? managedClaudeCodeBridgeCommand
      : '$managedClaudeCodeBridgeCommand --directory ${shellQuote(directory)}';
}
