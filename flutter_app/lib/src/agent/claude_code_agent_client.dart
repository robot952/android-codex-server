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
  Future<AgentGlobalSettings> readGlobalSettings(ServerProfile profile) =>
      throw UnsupportedError('Claude Code 使用服务器上的 Claude 配置，不支持在应用内改写全局设置');

  @override
  Future<void> writeGlobalSettings(
    ServerProfile profile, {
    required String baseUrl,
    required String apiKey,
    required String proxyUrl,
    required String defaultModel,
    required String defaultReasoningEffort,
    String? websocketPolicy,
    required bool preserveCurrentProvider,
  }) => throw UnsupportedError('Claude Code 全局设置请使用 Claude Code CLI 管理');

  @override
  Future<AgentConnectionTestResult> testGlobalSettings(
    ServerProfile profile, {
    required String baseUrl,
    required String apiKey,
    required String proxyUrl,
    required String testModel,
    ModelApiProtocol? apiProtocol,
  }) => throw UnsupportedError('Claude Code 不使用应用内 API 测试');

  @override
  Future<List<ApiModelOption>> fetchApiModels(
    ServerProfile profile, {
    required String baseUrl,
    required String apiKey,
    required String proxyUrl,
  }) => throw UnsupportedError('Claude Code 模型由 CLI 管理');
}

String buildClaudeCodeBridgeCommand(String workspace) {
  final directory = workspace.trim();
  return directory.isEmpty
      ? managedClaudeCodeBridgeCommand
      : '$managedClaudeCodeBridgeCommand --directory ${shellQuote(directory)}';
}
