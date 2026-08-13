import 'dart:typed_data';

import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:uuid/uuid.dart';

part 'models.freezed.dart';
part 'models.g.dart';

@JsonEnum(alwaysCreate: true)
enum AuthMode {
  @JsonValue('Password')
  password,
  @JsonValue('PrivateKey')
  privateKey,
}

@JsonEnum(alwaysCreate: true)
enum AgentKind {
  @JsonValue('Codex')
  codex,
  @JsonValue('OpenCode')
  openCode,
}

extension AgentKindDisplay on AgentKind {
  String get label => switch (this) {
    AgentKind.codex => 'Codex',
    AgentKind.openCode => 'OpenCode',
  };
}

extension AgentKindStorage on AgentKind {
  String get storageKeySegment => switch (this) {
    AgentKind.codex => 'Codex',
    AgentKind.openCode => 'OpenCode',
  };
}

@Deprecated('Kept only for profiles written by older app versions.')
@JsonEnum(alwaysCreate: true)
enum AgentMode {
  @JsonValue('Codex')
  codex,
  @JsonValue('OpenCode')
  openCode,
  @JsonValue('Both')
  both,
}

@JsonEnum(alwaysCreate: true)
enum ModelApiProtocol {
  @JsonValue('chat_completions')
  chatCompletions,
  @JsonValue('responses')
  responses,
}

extension ModelApiProtocolDisplay on ModelApiProtocol {
  String get label => switch (this) {
    ModelApiProtocol.chatCompletions => 'Chat Completions',
    ModelApiProtocol.responses => 'Responses',
  };
}

@freezed
abstract class CustomModelDefinition with _$CustomModelDefinition {
  const factory CustomModelDefinition({
    @Default('') String modelId,
    @Default('') String displayName,
    @Default(0) int contextWindowTokens,
    @Default(0) int maxOutputTokens,
    @Default(ModelApiProtocol.chatCompletions) ModelApiProtocol apiProtocol,
  }) = _CustomModelDefinition;

  factory CustomModelDefinition.fromJson(Map<String, Object?> json) =>
      _$CustomModelDefinitionFromJson(_normalizeCustomModelJson(json));
}

@freezed
abstract class AgentModelSettings with _$AgentModelSettings {
  const factory AgentModelSettings({
    @Default('') String preferredModel,
    @Default('') String preferredEffort,
    @Default('') String testModel,
    @Default(<CustomModelDefinition>[])
    List<CustomModelDefinition> customModels,
    @Default(<String>[]) List<String> hiddenModelIds,
    @Default(<String>[]) List<String> managedModelIds,
  }) = _AgentModelSettings;

  factory AgentModelSettings.fromJson(Map<String, Object?> json) =>
      _$AgentModelSettingsFromJson(json);
}

@freezed
abstract class ServerProfile with _$ServerProfile {
  const ServerProfile._();

  const factory ServerProfile({
    @Default('') String id,
    @Default('我的服务器') String name,
    @Default('') String host,
    @Default(22) int port,
    @Default('root') String username,
    @Default(AuthMode.privateKey) AuthMode authMode,
    @Default('') String password,
    @Default('') String privateKeyPem,
    @Default('') String privateKeyPassphrase,
    @Default('') String hostFingerprint,
    @Default('') String workspace,
    @Default('') String proxyUrl,
    @Default(ApprovalMode.requestApproval) ApprovalMode approvalMode,
    @Default('~/.local/bin/codex-remote app-server --listen stdio://')
    String remoteCommand,
    @Default(false) bool workspacePromptShown,
    @Default('') String preferredModel,
    @Default('') String preferredEffort,
    @Default('') String testModel,
    @Default(<CustomModelDefinition>[])
    List<CustomModelDefinition> customModels,
    @Default(<String>[]) List<String> hiddenModelIds,
    @Deprecated('Kept only for profiles written by older app versions.')
    @Default(AgentMode.codex)
    AgentMode agentMode,
    @Default(AgentKind.codex) AgentKind activeAgent,
    @Default(<AgentKind, AgentModelSettings>{})
    Map<AgentKind, AgentModelSettings> agentModelSettings,
  }) = _ServerProfile;

  factory ServerProfile.create({String name = '我的服务器'}) =>
      ServerProfile(id: const Uuid().v4(), name: name);

  factory ServerProfile.fromJson(Map<String, Object?> json) =>
      _$ServerProfileFromJson(_normalizeServerProfileJson(json));

  AgentModelSettings modelSettings(AgentKind agent) {
    final current = agentModelSettings[agent];
    if (current != null) return current;
    if (agent != AgentKind.codex) return const AgentModelSettings();
    return AgentModelSettings(
      preferredModel: preferredModel,
      preferredEffort: preferredEffort,
      testModel: testModel,
      customModels: customModels,
      hiddenModelIds: hiddenModelIds,
      managedModelIds: customModels.map((model) => model.modelId).toList(),
    );
  }

  ServerProfile withModelSettings(
    AgentKind agent,
    AgentModelSettings settings,
  ) => copyWith(
    agentModelSettings: {...agentModelSettings, agent: settings},
    preferredModel: agent == AgentKind.codex
        ? settings.preferredModel
        : preferredModel,
    preferredEffort: agent == AgentKind.codex
        ? settings.preferredEffort
        : preferredEffort,
    testModel: agent == AgentKind.codex ? settings.testModel : testModel,
    customModels: agent == AgentKind.codex
        ? settings.customModels
        : customModels,
    hiddenModelIds: agent == AgentKind.codex
        ? settings.hiddenModelIds
        : hiddenModelIds,
  );

  bool hasSameConnectionIdentity(ServerProfile other) =>
      host == other.host &&
      port == other.port &&
      username == other.username &&
      authMode == other.authMode &&
      password == other.password &&
      privateKeyPem == other.privateKeyPem &&
      privateKeyPassphrase == other.privateKeyPassphrase &&
      hostFingerprint == other.hostFingerprint;
}

@freezed
abstract class ThreadModelPreference with _$ThreadModelPreference {
  const factory ThreadModelPreference({
    @Default('') String model,
    @Default('') String effort,
  }) = _ThreadModelPreference;

  factory ThreadModelPreference.fromJson(Map<String, Object?> json) =>
      _$ThreadModelPreferenceFromJson(json);
}

@freezed
abstract class TurnTiming with _$TurnTiming {
  const factory TurnTiming({
    required String threadId,
    String? turnId,
    required int startedAtMillis,
    int? completedAtMillis,
    @Default(false) bool stopped,
  }) = _TurnTiming;

  factory TurnTiming.fromJson(Map<String, Object?> json) =>
      _$TurnTimingFromJson(json);
}

@freezed
abstract class StoredProfiles with _$StoredProfiles {
  const factory StoredProfiles({
    @Default(<ServerProfile>[]) List<ServerProfile> profiles,
    String? selectedProfileId,
    @Default(<String, String>{}) Map<String, String> composerDrafts,
    @Default(<String, ThreadModelPreference>{})
    Map<String, ThreadModelPreference> threadModelPreferences,
    @Default(<String, TurnTiming>{})
    Map<String, TurnTiming> completedTurnTimings,
  }) = _StoredProfiles;

  factory StoredProfiles.fromJson(Map<String, Object?> json) =>
      _$StoredProfilesFromJson(json);
}

enum ConnectionPhase {
  disconnected,
  probing,
  connecting,
  installing,
  connected,
  failed,
}

@freezed
abstract class ConnectionState with _$ConnectionState {
  const factory ConnectionState({
    @Default(ConnectionPhase.disconnected) ConnectionPhase phase,
    @Default('未连接') String message,
    String? cliVersion,
  }) = _ConnectionState;
}

@freezed
abstract class AgentConnectionKey with _$AgentConnectionKey {
  const factory AgentConnectionKey({
    required String profileId,
    required AgentKind agent,
  }) = _AgentConnectionKey;
}

@freezed
abstract class AgentCapabilities with _$AgentCapabilities {
  const factory AgentCapabilities({
    @Default(true) bool models,
    @Default(<ModelApiProtocol>[]) List<ModelApiProtocol> modelApiProtocols,
    @Default(false) bool reasoningEffort,
    @Default(false) bool approvals,
    @Default(true) bool archiveThread,
    @Default(true) bool renameThread,
    @Default(true) bool interruptTurn,
    @Default(false) bool steerTurn,
    @Default(false) bool rollbackThread,
    @Default(false) bool reviewChanges,
    @Default(false) bool compactThread,
    @Default(false) bool threadGoals,
    @Default(false) bool subAgents,
    @Default(false) bool globalSettings,
  }) = _AgentCapabilities;

  static const none = AgentCapabilities(
    models: false,
    archiveThread: false,
    renameThread: false,
    interruptTurn: false,
  );

  static const codex = AgentCapabilities(
    reasoningEffort: true,
    approvals: true,
    steerTurn: true,
    rollbackThread: true,
    reviewChanges: true,
    compactThread: true,
    threadGoals: true,
    subAgents: true,
    globalSettings: true,
  );

  static const openCode = AgentCapabilities(
    modelApiProtocols: [
      ModelApiProtocol.chatCompletions,
      ModelApiProtocol.responses,
    ],
    reasoningEffort: true,
    approvals: true,
    archiveThread: false,
    steerTurn: true,
    compactThread: true,
    globalSettings: true,
  );
}

@freezed
abstract class ServerMetrics with _$ServerMetrics {
  const factory ServerMetrics({
    int? cpuPercent,
    int? cpuCoreCount,
    int? memoryPercent,
    int? memoryTotalKiB,
    int? memoryUsedKiB,
    int? diskPercent,
    int? diskTotalKiB,
    int? diskUsedKiB,
    int? networkDownloadBytesPerSecond,
    int? networkUploadBytesPerSecond,
    @Default(0) int sampledAtEpochMillis,
    String? error,
  }) = _ServerMetrics;
}

@freezed
abstract class ApiModelOption with _$ApiModelOption {
  const factory ApiModelOption({
    required String modelId,
    @Default('') String displayName,
    @Default(0) int contextWindowTokens,
    @Default(0) int maxOutputTokens,
  }) = _ApiModelOption;
}

@freezed
abstract class AgentThread with _$AgentThread {
  const factory AgentThread({
    required String id,
    @Default('') String title,
    @Default('') String preview,
    @Default('') String cwd,
    @Default('') String source,
    @Default('idle') String status,
    @Default(0) int createdAt,
    @Default(0) int updatedAt,
    @Default('') String cliVersion,
    String? activeTurnId,
  }) = _AgentThread;
}

@freezed
abstract class AgentModel with _$AgentModel {
  const factory AgentModel({
    required String id,
    @Default('') String model,
    @Default('') String displayName,
    @Default('') String description,
    @Default(false) bool isDefault,
    @Default('') String defaultEffort,
    @Default(<String>[]) List<String> efforts,
    @Default(0) int contextWindowTokens,
    @Default(0) int maxOutputTokens,
    @Default(false) bool isCustom,
    ModelApiProtocol? apiProtocol,
  }) = _AgentModel;
}

enum ThreadGoalStatus {
  active,
  paused,
  blocked,
  usageLimited,
  budgetLimited,
  complete,
  unknown;

  String get wireValue => switch (this) {
    ThreadGoalStatus.active => 'active',
    ThreadGoalStatus.paused => 'paused',
    ThreadGoalStatus.blocked => 'blocked',
    ThreadGoalStatus.usageLimited => 'usageLimited',
    ThreadGoalStatus.budgetLimited => 'budgetLimited',
    ThreadGoalStatus.complete => 'complete',
    ThreadGoalStatus.unknown => 'unknown',
  };

  static ThreadGoalStatus fromWire(String value) => switch (value) {
    'active' => active,
    'paused' => paused,
    'blocked' => blocked,
    'usageLimited' => usageLimited,
    'budgetLimited' => budgetLimited,
    'complete' => complete,
    _ => unknown,
  };
}

@freezed
abstract class ThreadGoal with _$ThreadGoal {
  const factory ThreadGoal({
    required String threadId,
    required String objective,
    required ThreadGoalStatus status,
    @Default(0) int createdAt,
    @Default(0) int updatedAt,
    @Default(0) int timeUsedSeconds,
    @Default(0) int tokensUsed,
    int? tokenBudget,
  }) = _ThreadGoal;
}

@freezed
abstract class TokenUsageBreakdown with _$TokenUsageBreakdown {
  const factory TokenUsageBreakdown({
    @Default(0) int cachedInputTokens,
    @Default(0) int inputTokens,
    @Default(0) int outputTokens,
    @Default(0) int reasoningOutputTokens,
    @Default(0) int totalTokens,
  }) = _TokenUsageBreakdown;
}

@freezed
abstract class TokenUsage with _$TokenUsage {
  const TokenUsage._();

  const factory TokenUsage({
    @Default(TokenUsageBreakdown()) TokenUsageBreakdown last,
    @Default(TokenUsageBreakdown()) TokenUsageBreakdown total,
    @Default(0) int modelContextWindow,
  }) = _TokenUsage;

  bool get hasKnownContextWindow => modelContextWindow > 0;
}

enum TimelineKind {
  userMessage,
  agentMessage,
  reasoning,
  plan,
  command,
  fileChange,
  tool,
  subAgent,
  review,
  notice,
}

@freezed
abstract class FileChange with _$FileChange {
  const FileChange._();

  const factory FileChange({
    required String path,
    @Default('') String kind,
    @Default('') String diff,
  }) = _FileChange;

  int get additions => diff
      .split('\n')
      .where((line) => line.startsWith('+') && !line.startsWith('+++'))
      .length;

  int get deletions => diff
      .split('\n')
      .where((line) => line.startsWith('-') && !line.startsWith('---'))
      .length;
}

@freezed
abstract class MessageAttachment with _$MessageAttachment {
  const factory MessageAttachment({
    required String name,
    @Default('') String remotePath,
    @Default('application/octet-stream') String mimeType,
  }) = _MessageAttachment;
}

@freezed
abstract class TimelineEntry with _$TimelineEntry {
  const factory TimelineEntry({
    required String id,
    required TimelineKind kind,
    @Default('') String title,
    @Default('') String text,
    @Default('') String status,
    @Default('') String command,
    @Default('') String cwd,
    @Default('') String output,
    @Default(<FileChange>[]) List<FileChange> changes,
    @Default(<MessageAttachment>[]) List<MessageAttachment> attachments,
    @Default('') String turnId,
    @Default('') String subAgentPath,
    @Default('') String subAgentThreadId,
    @Default('') String subAgentActivity,
    @Default(<String>[]) List<String> reasoningSummary,
    @Default(<String>[]) List<String> reasoningContent,
  }) = _TimelineEntry;
}

enum ApprovalKind { command, fileChange, permission, userInput }

@freezed
abstract class InputOption with _$InputOption {
  const factory InputOption({
    required String label,
    @Default('') String description,
  }) = _InputOption;
}

@freezed
abstract class InputQuestion with _$InputQuestion {
  const factory InputQuestion({
    required String id,
    required String header,
    required String question,
    @Default(<InputOption>[]) List<InputOption> options,
    @Default(false) bool isSecret,
  }) = _InputQuestion;
}

@freezed
abstract class ApprovalPrompt with _$ApprovalPrompt {
  const factory ApprovalPrompt({
    required String requestId,
    required bool requestIdIsString,
    required ApprovalKind kind,
    required String threadId,
    required String turnId,
    required String itemId,
    required String title,
    required String detail,
    @Default('') String command,
    @Default('') String cwd,
    @Default(<InputQuestion>[]) List<InputQuestion> questions,
  }) = _ApprovalPrompt;
}

@freezed
abstract class PendingAttachment with _$PendingAttachment {
  const factory PendingAttachment({
    required String name,
    required String remotePath,
    required String mimeType,
    String? textContent,
  }) = _PendingAttachment;
}

const int maxLocalAttachmentBytes = 20 * 1024 * 1024;
const int maxInlineTextAttachmentBytes = 512 * 1024;
const int maxPendingAttachmentCount = 8;
const int maxPendingAttachmentTotalBytes = 40 * 1024 * 1024;

/// Bounded local content waiting to be staged through the active SSH lane.
class LocalAttachmentUpload {
  LocalAttachmentUpload({
    required this.name,
    required this.bytes,
    required this.mimeType,
    this.textContent,
  });

  final String name;
  final Uint8List bytes;
  final String mimeType;
  final String? textContent;
}

/// One locally selected document streamed into the remote file manager.
/// Unlike conversation attachments this object is intentionally transient and
/// never persisted or compared as part of [AppUiState].
class LocalRemoteFileUpload {
  const LocalRemoteFileUpload({
    required this.name,
    required this.sizeBytes,
    required this.chunks,
  });

  final String name;
  final int sizeBytes;
  final Stream<List<int>> chunks;
}

enum AppScreen { servers, threads, work, agentWork, fileManager, terminal }

enum SandboxChoice {
  readOnly('read-only', 'readOnly', '只读'),
  workspaceWrite('workspace-write', 'workspaceWrite', '工作区'),
  fullAccess('danger-full-access', 'dangerFullAccess', '完全访问');

  const SandboxChoice(this.wireValue, this.policyType, this.label);
  final String wireValue;
  final String policyType;
  final String label;
}

@JsonEnum(alwaysCreate: true)
enum ApprovalMode {
  @JsonValue('RequestApproval')
  requestApproval(
    'untrusted',
    SandboxChoice.workspaceWrite,
    '请求批准',
    '编辑外部文件和使用互联网时始终询问',
  ),
  @JsonValue('AutoApprove')
  autoApprove(
    'on-request',
    SandboxChoice.workspaceWrite,
    '替我审批',
    '仅对检测到的风险操作请求批准',
  ),
  @JsonValue('FullAccess')
  fullAccess(
    'never',
    SandboxChoice.fullAccess,
    '完全访问权限',
    '可不受限制地访问互联网和服务器上的任何文件',
  );

  const ApprovalMode(
    this.approvalPolicy,
    this.sandbox,
    this.label,
    this.description,
  );

  final String approvalPolicy;
  final SandboxChoice sandbox;
  final String label;
  final String description;
}

@freezed
abstract class RemoteDirectory with _$RemoteDirectory {
  const factory RemoteDirectory({required String name, required String path}) =
      _RemoteDirectory;
}

@freezed
abstract class RemoteDirectoryListing with _$RemoteDirectoryListing {
  const factory RemoteDirectoryListing({
    required String currentPath,
    String? parentPath,
    @Default(<RemoteDirectory>[]) List<RemoteDirectory> directories,
  }) = _RemoteDirectoryListing;
}

enum RemoteFileKind { directory, file, symbolicLink, other }

@freezed
abstract class RemoteFileEntry with _$RemoteFileEntry {
  const factory RemoteFileEntry({
    required String name,
    required String path,
    required RemoteFileKind kind,
    @Default(0) int sizeBytes,
    int? modifiedAtEpochMillis,
    @Default('') String permissions,
  }) = _RemoteFileEntry;
}

@freezed
abstract class RemoteFileListing with _$RemoteFileListing {
  const factory RemoteFileListing({
    required String currentPath,
    String? parentPath,
    @Default(<RemoteFileEntry>[]) List<RemoteFileEntry> entries,
  }) = _RemoteFileListing;
}

enum RemoteFileTransferMode { copy, move }

@freezed
abstract class RemoteFileClipboard with _$RemoteFileClipboard {
  const factory RemoteFileClipboard({
    required List<RemoteFileEntry> entries,
    required RemoteFileTransferMode mode,
  }) = _RemoteFileClipboard;
}

@freezed
abstract class RemoteSetupPrompt with _$RemoteSetupPrompt {
  const factory RemoteSetupPrompt({
    required String title,
    required String detail,
    required String os,
    required String architecture,
    required String home,
    String? detectedVersion,
    @Default(AgentKind.codex) AgentKind agent,
  }) = _RemoteSetupPrompt;
}

@freezed
abstract class AgentSetupState with _$AgentSetupState {
  const factory AgentSetupState({
    RemoteSetupPrompt? prompt,
    @Default(false) bool inProgress,
    @Default('') String progress,
    @Default(0) int percent,
    @Default('') String detail,
    int? downloadPercent,
    int? downloadedBytes,
    int? totalBytes,
    int? bytesPerSecond,
    int? elapsedSeconds,
    @Default(false) bool progressIndeterminate,
    @Default(false) bool minimized,
  }) = _AgentSetupState;
}

@freezed
abstract class AgentGlobalSettings with _$AgentGlobalSettings {
  const factory AgentGlobalSettings({
    @Default('') String baseUrl,
    @Default('') String model,
    @Default('') String reasoningEffort,
    @Default('openai') String modelProvider,
    @Default(false) bool hasStoredAuthentication,
    @Default('') String apiKey,
    @Default('') String proxyUrl,
  }) = _AgentGlobalSettings;
}

@freezed
abstract class AgentConnectionTestResult with _$AgentConnectionTestResult {
  const factory AgentConnectionTestResult({
    required bool successful,
    required String message,
  }) = _AgentConnectionTestResult;
}

@freezed
abstract class AppUiState with _$AppUiState {
  const factory AppUiState({
    @Default(AppScreen.servers) AppScreen screen,
    @Default(false) bool subAgentBackNavigation,
    @Default(false) bool debugModeEnabled,
    @Default(<ServerProfile>[]) List<ServerProfile> profiles,
    String? selectedProfileId,
    @Default(ConnectionState()) ConnectionState connection,
    @Default(<String, ConnectionState>{})
    Map<String, ConnectionState> connectionStates,
    @Default(<AgentConnectionKey, ConnectionState>{})
    Map<AgentConnectionKey, ConnectionState> agentConnectionStates,
    @Default(AgentKind.codex) AgentKind activeAgent,
    @Default(AgentCapabilities.none) AgentCapabilities activeAgentCapabilities,
    @Default(<String, ServerMetrics>{})
    Map<String, ServerMetrics> serverMetrics,
    String? pendingFingerprint,
    RemoteSetupPrompt? remoteSetup,
    @Default(false) bool setupInProgress,
    @Default('') String setupProgress,
    @Default(0) int setupProgressPercent,
    @Default('') String setupProgressDetail,
    int? setupDownloadPercent,
    int? setupDownloadedBytes,
    int? setupTotalBytes,
    int? setupBytesPerSecond,
    int? setupElapsedSeconds,
    @Default(false) bool setupProgressIndeterminate,
    @Default(<AgentConnectionKey, AgentSetupState>{})
    Map<AgentConnectionKey, AgentSetupState> agentSetupStates,
    @Default(<AgentConnectionKey, List<AgentThread>>{})
    Map<AgentConnectionKey, List<AgentThread>> agentThreadLists,
    @Default(<AgentConnectionKey, List<AgentModel>>{})
    Map<AgentConnectionKey, List<AgentModel>> agentModelLists,
    @Default(<AgentConnectionKey, bool>{})
    Map<AgentConnectionKey, bool> agentLoadingStates,
    @Default(<AgentThread>[]) List<AgentThread> threads,
    @Default('') String threadSearch,
    AgentThread? activeThread,
    String? activeAgentName,
    ThreadGoal? activeGoal,
    @Default(<TimelineEntry>[]) List<TimelineEntry> timeline,
    String? olderTurnsCursor,
    @Default(false) bool olderTurnsLoading,
    String? activeTurnId,
    @Default(false) bool running,
    TurnTiming? turnTiming,
    @Default(false) bool submitting,
    @Default(false) bool loading,
    @Default(<AgentModel>[]) List<AgentModel> models,
    @Default(<ApiModelOption>[]) List<ApiModelOption> apiModelOptions,
    String? apiModelOptionsProfileId,
    @Default(false) bool apiModelOptionsLoading,
    String? apiModelOptionsError,
    String? selectedModel,
    String? selectedEffort,
    @Default(ApprovalMode.requestApproval) ApprovalMode approvalMode,
    @Default(SandboxChoice.workspaceWrite) SandboxChoice sandbox,
    @Default(false) bool workspacePickerVisible,
    @Default(false) bool workspaceLoading,
    @Default('') String workspaceCurrentPath,
    String? workspaceParentPath,
    @Default(<RemoteDirectory>[]) List<RemoteDirectory> workspaceDirectories,
    String? workspaceError,
    String? fileManagerProfileId,
    @Default(false) bool fileManagerLoading,
    @Default('') String fileManagerCurrentPath,
    String? fileManagerParentPath,
    @Default(<RemoteFileEntry>[]) List<RemoteFileEntry> fileManagerEntries,
    RemoteFileClipboard? fileManagerClipboard,
    String? fileManagerOperation,
    String? fileManagerError,
    @Default(false) bool agentSettingsVisible,
    @Default(false) bool agentSettingsLoading,
    @Default(false) bool agentSettingsSaving,
    @Default(false) bool agentSettingsTesting,
    AgentGlobalSettings? agentSettings,
    AgentConnectionTestResult? agentSettingsTestResult,
    String? agentSettingsError,
    ApprovalPrompt? approval,
    @Default(<ApprovalPrompt>[]) List<ApprovalPrompt> approvalQueue,
    @Default(<PendingAttachment>[]) List<PendingAttachment> attachments,
    @Default(false) bool attachmentUploading,
    @Default(0) int composerClearNonce,
    @Default('') String composerDraft,
    @Default('') String aggregateDiff,
    TokenUsage? tokenUsage,
    String? error,
    String? diagnostic,
  }) = _AppUiState;
}

String sessionKey(String profileId, AgentKind agent) =>
    '$profileId\u0000${agent.storageKeySegment}';

String threadPreferenceKey(
  String profileId,
  AgentKind agent,
  String threadId,
) => '${sessionKey(profileId, agent)}\u0000$threadId';

Map<String, Object?> _normalizeCustomModelJson(Map<String, Object?> json) {
  final normalized = Map<String, Object?>.from(json);
  _defaultUnknownEnum(normalized, 'apiProtocol', const {
    'chat_completions',
    'responses',
  }, 'chat_completions');
  return normalized;
}

Map<String, Object?> _normalizeServerProfileJson(Map<String, Object?> json) {
  final normalized = Map<String, Object?>.from(json);
  _defaultUnknownEnum(normalized, 'authMode', const {
    'Password',
    'PrivateKey',
  }, 'PrivateKey');
  _defaultUnknownEnum(normalized, 'approvalMode', const {
    'RequestApproval',
    'AutoApprove',
    'FullAccess',
  }, 'RequestApproval');
  _defaultUnknownEnum(normalized, 'agentMode', const {
    'Codex',
    'OpenCode',
    'Both',
  }, 'Codex');
  _defaultUnknownEnum(normalized, 'activeAgent', const {
    'Codex',
    'OpenCode',
  }, 'Codex');

  final settings = normalized['agentModelSettings'];
  if (settings is Map) {
    normalized['agentModelSettings'] = <String, Object?>{
      for (final entry in settings.entries)
        if (entry.key == 'Codex' || entry.key == 'OpenCode')
          entry.key as String: entry.value,
    };
  }
  return normalized;
}

void _defaultUnknownEnum(
  Map<String, Object?> json,
  String key,
  Set<String> knownValues,
  String fallback,
) {
  final value = json[key];
  if (value != null && !knownValues.contains(value)) json[key] = fallback;
}
