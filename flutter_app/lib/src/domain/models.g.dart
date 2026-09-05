// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'models.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_CustomModelDefinition _$CustomModelDefinitionFromJson(
  Map<String, dynamic> json,
) => _CustomModelDefinition(
  modelId: json['modelId'] as String? ?? '',
  displayName: json['displayName'] as String? ?? '',
  contextWindowTokens: (json['contextWindowTokens'] as num?)?.toInt() ?? 0,
  maxOutputTokens: (json['maxOutputTokens'] as num?)?.toInt() ?? 0,
  apiProtocol:
      $enumDecodeNullable(_$ModelApiProtocolEnumMap, json['apiProtocol']) ??
      ModelApiProtocol.chatCompletions,
);

Map<String, dynamic> _$CustomModelDefinitionToJson(
  _CustomModelDefinition instance,
) => <String, dynamic>{
  'modelId': instance.modelId,
  'displayName': instance.displayName,
  'contextWindowTokens': instance.contextWindowTokens,
  'maxOutputTokens': instance.maxOutputTokens,
  'apiProtocol': _$ModelApiProtocolEnumMap[instance.apiProtocol]!,
};

const _$ModelApiProtocolEnumMap = {
  ModelApiProtocol.chatCompletions: 'chat_completions',
  ModelApiProtocol.responses: 'responses',
};

_AgentModelSettings _$AgentModelSettingsFromJson(Map<String, dynamic> json) =>
    _AgentModelSettings(
      preferredModel: json['preferredModel'] as String? ?? '',
      preferredEffort: json['preferredEffort'] as String? ?? '',
      testModel: json['testModel'] as String? ?? '',
      customModels:
          (json['customModels'] as List<dynamic>?)
              ?.map(
                (e) =>
                    CustomModelDefinition.fromJson(e as Map<String, dynamic>),
              )
              .toList() ??
          const <CustomModelDefinition>[],
      hiddenModelIds:
          (json['hiddenModelIds'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const <String>[],
      managedModelIds:
          (json['managedModelIds'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const <String>[],
    );

Map<String, dynamic> _$AgentModelSettingsToJson(_AgentModelSettings instance) =>
    <String, dynamic>{
      'preferredModel': instance.preferredModel,
      'preferredEffort': instance.preferredEffort,
      'testModel': instance.testModel,
      'customModels': instance.customModels,
      'hiddenModelIds': instance.hiddenModelIds,
      'managedModelIds': instance.managedModelIds,
    };

_ServerProfile _$ServerProfileFromJson(Map<String, dynamic> json) =>
    _ServerProfile(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '我的服务器',
      host: json['host'] as String? ?? '',
      port: (json['port'] as num?)?.toInt() ?? 22,
      username: json['username'] as String? ?? 'root',
      authMode:
          $enumDecodeNullable(_$AuthModeEnumMap, json['authMode']) ??
          AuthMode.privateKey,
      password: json['password'] as String? ?? '',
      privateKeyPem: json['privateKeyPem'] as String? ?? '',
      privateKeyPassphrase: json['privateKeyPassphrase'] as String? ?? '',
      hostFingerprint: json['hostFingerprint'] as String? ?? '',
      workspace: json['workspace'] as String? ?? '',
      proxyUrl: json['proxyUrl'] as String? ?? '',
      approvalMode:
          $enumDecodeNullable(_$ApprovalModeEnumMap, json['approvalMode']) ??
          ApprovalMode.requestApproval,
      remoteCommand:
          json['remoteCommand'] as String? ??
          '~/.local/bin/codex-remote app-server --listen stdio://',
      codexVersion: json['codexVersion'] as String? ?? defaultCodexVersion,
      workspacePromptShown: json['workspacePromptShown'] as bool? ?? false,
      preferredModel: json['preferredModel'] as String? ?? '',
      preferredEffort: json['preferredEffort'] as String? ?? '',
      testModel: json['testModel'] as String? ?? '',
      customModels:
          (json['customModels'] as List<dynamic>?)
              ?.map(
                (e) =>
                    CustomModelDefinition.fromJson(e as Map<String, dynamic>),
              )
              .toList() ??
          const <CustomModelDefinition>[],
      hiddenModelIds:
          (json['hiddenModelIds'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const <String>[],
      agentMode:
          $enumDecodeNullable(_$AgentModeEnumMap, json['agentMode']) ??
          AgentMode.codex,
      activeAgent:
          $enumDecodeNullable(_$AgentKindEnumMap, json['activeAgent']) ??
          AgentKind.codex,
      agentModelSettings:
          (json['agentModelSettings'] as Map<String, dynamic>?)?.map(
            (k, e) => MapEntry(
              $enumDecode(_$AgentKindEnumMap, k),
              AgentModelSettings.fromJson(e as Map<String, dynamic>),
            ),
          ) ??
          const <AgentKind, AgentModelSettings>{},
    );

Map<String, dynamic> _$ServerProfileToJson(_ServerProfile instance) =>
    <String, dynamic>{
      'id': instance.id,
      'name': instance.name,
      'host': instance.host,
      'port': instance.port,
      'username': instance.username,
      'authMode': _$AuthModeEnumMap[instance.authMode]!,
      'password': instance.password,
      'privateKeyPem': instance.privateKeyPem,
      'privateKeyPassphrase': instance.privateKeyPassphrase,
      'hostFingerprint': instance.hostFingerprint,
      'workspace': instance.workspace,
      'proxyUrl': instance.proxyUrl,
      'approvalMode': _$ApprovalModeEnumMap[instance.approvalMode]!,
      'remoteCommand': instance.remoteCommand,
      'codexVersion': instance.codexVersion,
      'workspacePromptShown': instance.workspacePromptShown,
      'preferredModel': instance.preferredModel,
      'preferredEffort': instance.preferredEffort,
      'testModel': instance.testModel,
      'customModels': instance.customModels,
      'hiddenModelIds': instance.hiddenModelIds,
      'agentMode': _$AgentModeEnumMap[instance.agentMode]!,
      'activeAgent': _$AgentKindEnumMap[instance.activeAgent]!,
      'agentModelSettings': instance.agentModelSettings.map(
        (k, e) => MapEntry(_$AgentKindEnumMap[k]!, e),
      ),
    };

const _$AuthModeEnumMap = {
  AuthMode.password: 'Password',
  AuthMode.privateKey: 'PrivateKey',
};

const _$ApprovalModeEnumMap = {
  ApprovalMode.requestApproval: 'RequestApproval',
  ApprovalMode.autoApprove: 'AutoApprove',
  ApprovalMode.fullAccess: 'FullAccess',
};

const _$AgentModeEnumMap = {
  AgentMode.codex: 'Codex',
  AgentMode.openCode: 'OpenCode',
  AgentMode.both: 'Both',
};

const _$AgentKindEnumMap = {
  AgentKind.codex: 'Codex',
  AgentKind.openCode: 'OpenCode',
};

_ThreadModelPreference _$ThreadModelPreferenceFromJson(
  Map<String, dynamic> json,
) => _ThreadModelPreference(
  model: json['model'] as String? ?? '',
  effort: json['effort'] as String? ?? '',
);

Map<String, dynamic> _$ThreadModelPreferenceToJson(
  _ThreadModelPreference instance,
) => <String, dynamic>{'model': instance.model, 'effort': instance.effort};

_TurnTiming _$TurnTimingFromJson(Map<String, dynamic> json) => _TurnTiming(
  threadId: json['threadId'] as String,
  turnId: json['turnId'] as String?,
  startedAtMillis: (json['startedAtMillis'] as num).toInt(),
  completedAtMillis: (json['completedAtMillis'] as num?)?.toInt(),
  stopped: json['stopped'] as bool? ?? false,
);

Map<String, dynamic> _$TurnTimingToJson(_TurnTiming instance) =>
    <String, dynamic>{
      'threadId': instance.threadId,
      'turnId': instance.turnId,
      'startedAtMillis': instance.startedAtMillis,
      'completedAtMillis': instance.completedAtMillis,
      'stopped': instance.stopped,
    };

_StoredProfiles _$StoredProfilesFromJson(Map<String, dynamic> json) =>
    _StoredProfiles(
      profiles:
          (json['profiles'] as List<dynamic>?)
              ?.map((e) => ServerProfile.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const <ServerProfile>[],
      selectedProfileId: json['selectedProfileId'] as String?,
      composerDrafts:
          (json['composerDrafts'] as Map<String, dynamic>?)?.map(
            (k, e) => MapEntry(k, e as String),
          ) ??
          const <String, String>{},
      threadModelPreferences:
          (json['threadModelPreferences'] as Map<String, dynamic>?)?.map(
            (k, e) => MapEntry(
              k,
              ThreadModelPreference.fromJson(e as Map<String, dynamic>),
            ),
          ) ??
          const <String, ThreadModelPreference>{},
      completedTurnTimings:
          (json['completedTurnTimings'] as Map<String, dynamic>?)?.map(
            (k, e) =>
                MapEntry(k, TurnTiming.fromJson(e as Map<String, dynamic>)),
          ) ??
          const <String, TurnTiming>{},
    );

Map<String, dynamic> _$StoredProfilesToJson(_StoredProfiles instance) =>
    <String, dynamic>{
      'profiles': instance.profiles,
      'selectedProfileId': instance.selectedProfileId,
      'composerDrafts': instance.composerDrafts,
      'threadModelPreferences': instance.threadModelPreferences,
      'completedTurnTimings': instance.completedTurnTimings,
    };
