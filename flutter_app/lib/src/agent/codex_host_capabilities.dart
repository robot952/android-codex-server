import '../domain/models.dart';
import 'remote_bootstrap.dart';

/// Native Host operations that replace the POSIX bootstrap scripts.
abstract interface class RemoteServerCodexRuntimeClient {
  Future<AgentRuntimeInspection> inspectCodexRuntime(ServerProfile profile);

  Future<void> installCodexRuntime(
    ServerProfile profile, {
    required void Function(RemoteInstallProgress progress) onProgress,
  });

  Future<void> uninstallCodexRuntime(ServerProfile profile);
}

/// Native Host operations for the app-owned OpenCode bridge and runtime.
abstract interface class RemoteServerOpenCodeRuntimeClient {
  Future<AgentRuntimeInspection> inspectOpenCodeRuntime(
    ServerProfile profile, {
    required String bridgeSource,
  });

  Future<void> installOpenCodeRuntime(
    ServerProfile profile, {
    required String bridgeSource,
    required void Function(RemoteInstallProgress progress) onProgress,
  });

  Future<void> uninstallOpenCodeRuntime(ServerProfile profile);
}

/// Native Host operations for the user's Codex configuration and API access.
abstract interface class RemoteServerCodexSettingsClient {
  Future<AgentGlobalSettings> readCodexSettings(ServerProfile profile);

  Future<void> writeCodexSettings(
    ServerProfile profile, {
    required String baseUrl,
    required String apiKey,
    required String proxyUrl,
    required String defaultModel,
    required String defaultReasoningEffort,
    String? websocketPolicy,
    required bool preserveCurrentProvider,
  });

  Future<AgentConnectionTestResult> testCodexSettings(
    ServerProfile profile, {
    required String baseUrl,
    required String apiKey,
    required String proxyUrl,
    required String testModel,
    ModelApiProtocol? apiProtocol,
  });

  Future<List<ApiModelOption>> fetchCodexApiModels(
    ServerProfile profile, {
    required String baseUrl,
    required String apiKey,
    required String proxyUrl,
  });
}
