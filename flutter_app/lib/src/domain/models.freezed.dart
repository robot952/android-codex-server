// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'models.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$CustomModelDefinition {

 String get modelId; String get displayName; int get contextWindowTokens; int get maxOutputTokens; ModelApiProtocol get apiProtocol;
/// Create a copy of CustomModelDefinition
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CustomModelDefinitionCopyWith<CustomModelDefinition> get copyWith => _$CustomModelDefinitionCopyWithImpl<CustomModelDefinition>(this as CustomModelDefinition, _$identity);

  /// Serializes this CustomModelDefinition to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is CustomModelDefinition&&(identical(other.modelId, modelId) || other.modelId == modelId)&&(identical(other.displayName, displayName) || other.displayName == displayName)&&(identical(other.contextWindowTokens, contextWindowTokens) || other.contextWindowTokens == contextWindowTokens)&&(identical(other.maxOutputTokens, maxOutputTokens) || other.maxOutputTokens == maxOutputTokens)&&(identical(other.apiProtocol, apiProtocol) || other.apiProtocol == apiProtocol));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,modelId,displayName,contextWindowTokens,maxOutputTokens,apiProtocol);

@override
String toString() {
  return 'CustomModelDefinition(modelId: $modelId, displayName: $displayName, contextWindowTokens: $contextWindowTokens, maxOutputTokens: $maxOutputTokens, apiProtocol: $apiProtocol)';
}


}

/// @nodoc
abstract mixin class $CustomModelDefinitionCopyWith<$Res>  {
  factory $CustomModelDefinitionCopyWith(CustomModelDefinition value, $Res Function(CustomModelDefinition) _then) = _$CustomModelDefinitionCopyWithImpl;
@useResult
$Res call({
 String modelId, String displayName, int contextWindowTokens, int maxOutputTokens, ModelApiProtocol apiProtocol
});




}
/// @nodoc
class _$CustomModelDefinitionCopyWithImpl<$Res>
    implements $CustomModelDefinitionCopyWith<$Res> {
  _$CustomModelDefinitionCopyWithImpl(this._self, this._then);

  final CustomModelDefinition _self;
  final $Res Function(CustomModelDefinition) _then;

/// Create a copy of CustomModelDefinition
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? modelId = null,Object? displayName = null,Object? contextWindowTokens = null,Object? maxOutputTokens = null,Object? apiProtocol = null,}) {
  return _then(_self.copyWith(
modelId: null == modelId ? _self.modelId : modelId // ignore: cast_nullable_to_non_nullable
as String,displayName: null == displayName ? _self.displayName : displayName // ignore: cast_nullable_to_non_nullable
as String,contextWindowTokens: null == contextWindowTokens ? _self.contextWindowTokens : contextWindowTokens // ignore: cast_nullable_to_non_nullable
as int,maxOutputTokens: null == maxOutputTokens ? _self.maxOutputTokens : maxOutputTokens // ignore: cast_nullable_to_non_nullable
as int,apiProtocol: null == apiProtocol ? _self.apiProtocol : apiProtocol // ignore: cast_nullable_to_non_nullable
as ModelApiProtocol,
  ));
}

}


/// Adds pattern-matching-related methods to [CustomModelDefinition].
extension CustomModelDefinitionPatterns on CustomModelDefinition {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _CustomModelDefinition value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _CustomModelDefinition() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _CustomModelDefinition value)  $default,){
final _that = this;
switch (_that) {
case _CustomModelDefinition():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _CustomModelDefinition value)?  $default,){
final _that = this;
switch (_that) {
case _CustomModelDefinition() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String modelId,  String displayName,  int contextWindowTokens,  int maxOutputTokens,  ModelApiProtocol apiProtocol)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _CustomModelDefinition() when $default != null:
return $default(_that.modelId,_that.displayName,_that.contextWindowTokens,_that.maxOutputTokens,_that.apiProtocol);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String modelId,  String displayName,  int contextWindowTokens,  int maxOutputTokens,  ModelApiProtocol apiProtocol)  $default,) {final _that = this;
switch (_that) {
case _CustomModelDefinition():
return $default(_that.modelId,_that.displayName,_that.contextWindowTokens,_that.maxOutputTokens,_that.apiProtocol);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String modelId,  String displayName,  int contextWindowTokens,  int maxOutputTokens,  ModelApiProtocol apiProtocol)?  $default,) {final _that = this;
switch (_that) {
case _CustomModelDefinition() when $default != null:
return $default(_that.modelId,_that.displayName,_that.contextWindowTokens,_that.maxOutputTokens,_that.apiProtocol);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _CustomModelDefinition implements CustomModelDefinition {
  const _CustomModelDefinition({this.modelId = '', this.displayName = '', this.contextWindowTokens = 0, this.maxOutputTokens = 0, this.apiProtocol = ModelApiProtocol.chatCompletions});
  factory _CustomModelDefinition.fromJson(Map<String, dynamic> json) => _$CustomModelDefinitionFromJson(json);

@override@JsonKey() final  String modelId;
@override@JsonKey() final  String displayName;
@override@JsonKey() final  int contextWindowTokens;
@override@JsonKey() final  int maxOutputTokens;
@override@JsonKey() final  ModelApiProtocol apiProtocol;

/// Create a copy of CustomModelDefinition
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$CustomModelDefinitionCopyWith<_CustomModelDefinition> get copyWith => __$CustomModelDefinitionCopyWithImpl<_CustomModelDefinition>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$CustomModelDefinitionToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _CustomModelDefinition&&(identical(other.modelId, modelId) || other.modelId == modelId)&&(identical(other.displayName, displayName) || other.displayName == displayName)&&(identical(other.contextWindowTokens, contextWindowTokens) || other.contextWindowTokens == contextWindowTokens)&&(identical(other.maxOutputTokens, maxOutputTokens) || other.maxOutputTokens == maxOutputTokens)&&(identical(other.apiProtocol, apiProtocol) || other.apiProtocol == apiProtocol));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,modelId,displayName,contextWindowTokens,maxOutputTokens,apiProtocol);

@override
String toString() {
  return 'CustomModelDefinition(modelId: $modelId, displayName: $displayName, contextWindowTokens: $contextWindowTokens, maxOutputTokens: $maxOutputTokens, apiProtocol: $apiProtocol)';
}


}

/// @nodoc
abstract mixin class _$CustomModelDefinitionCopyWith<$Res> implements $CustomModelDefinitionCopyWith<$Res> {
  factory _$CustomModelDefinitionCopyWith(_CustomModelDefinition value, $Res Function(_CustomModelDefinition) _then) = __$CustomModelDefinitionCopyWithImpl;
@override @useResult
$Res call({
 String modelId, String displayName, int contextWindowTokens, int maxOutputTokens, ModelApiProtocol apiProtocol
});




}
/// @nodoc
class __$CustomModelDefinitionCopyWithImpl<$Res>
    implements _$CustomModelDefinitionCopyWith<$Res> {
  __$CustomModelDefinitionCopyWithImpl(this._self, this._then);

  final _CustomModelDefinition _self;
  final $Res Function(_CustomModelDefinition) _then;

/// Create a copy of CustomModelDefinition
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? modelId = null,Object? displayName = null,Object? contextWindowTokens = null,Object? maxOutputTokens = null,Object? apiProtocol = null,}) {
  return _then(_CustomModelDefinition(
modelId: null == modelId ? _self.modelId : modelId // ignore: cast_nullable_to_non_nullable
as String,displayName: null == displayName ? _self.displayName : displayName // ignore: cast_nullable_to_non_nullable
as String,contextWindowTokens: null == contextWindowTokens ? _self.contextWindowTokens : contextWindowTokens // ignore: cast_nullable_to_non_nullable
as int,maxOutputTokens: null == maxOutputTokens ? _self.maxOutputTokens : maxOutputTokens // ignore: cast_nullable_to_non_nullable
as int,apiProtocol: null == apiProtocol ? _self.apiProtocol : apiProtocol // ignore: cast_nullable_to_non_nullable
as ModelApiProtocol,
  ));
}


}


/// @nodoc
mixin _$AgentModelSettings {

 String get preferredModel; String get preferredEffort; String get testModel; List<CustomModelDefinition> get customModels; List<String> get hiddenModelIds; List<String> get managedModelIds;
/// Create a copy of AgentModelSettings
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AgentModelSettingsCopyWith<AgentModelSettings> get copyWith => _$AgentModelSettingsCopyWithImpl<AgentModelSettings>(this as AgentModelSettings, _$identity);

  /// Serializes this AgentModelSettings to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AgentModelSettings&&(identical(other.preferredModel, preferredModel) || other.preferredModel == preferredModel)&&(identical(other.preferredEffort, preferredEffort) || other.preferredEffort == preferredEffort)&&(identical(other.testModel, testModel) || other.testModel == testModel)&&const DeepCollectionEquality().equals(other.customModels, customModels)&&const DeepCollectionEquality().equals(other.hiddenModelIds, hiddenModelIds)&&const DeepCollectionEquality().equals(other.managedModelIds, managedModelIds));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,preferredModel,preferredEffort,testModel,const DeepCollectionEquality().hash(customModels),const DeepCollectionEquality().hash(hiddenModelIds),const DeepCollectionEquality().hash(managedModelIds));

@override
String toString() {
  return 'AgentModelSettings(preferredModel: $preferredModel, preferredEffort: $preferredEffort, testModel: $testModel, customModels: $customModels, hiddenModelIds: $hiddenModelIds, managedModelIds: $managedModelIds)';
}


}

/// @nodoc
abstract mixin class $AgentModelSettingsCopyWith<$Res>  {
  factory $AgentModelSettingsCopyWith(AgentModelSettings value, $Res Function(AgentModelSettings) _then) = _$AgentModelSettingsCopyWithImpl;
@useResult
$Res call({
 String preferredModel, String preferredEffort, String testModel, List<CustomModelDefinition> customModels, List<String> hiddenModelIds, List<String> managedModelIds
});




}
/// @nodoc
class _$AgentModelSettingsCopyWithImpl<$Res>
    implements $AgentModelSettingsCopyWith<$Res> {
  _$AgentModelSettingsCopyWithImpl(this._self, this._then);

  final AgentModelSettings _self;
  final $Res Function(AgentModelSettings) _then;

/// Create a copy of AgentModelSettings
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? preferredModel = null,Object? preferredEffort = null,Object? testModel = null,Object? customModels = null,Object? hiddenModelIds = null,Object? managedModelIds = null,}) {
  return _then(_self.copyWith(
preferredModel: null == preferredModel ? _self.preferredModel : preferredModel // ignore: cast_nullable_to_non_nullable
as String,preferredEffort: null == preferredEffort ? _self.preferredEffort : preferredEffort // ignore: cast_nullable_to_non_nullable
as String,testModel: null == testModel ? _self.testModel : testModel // ignore: cast_nullable_to_non_nullable
as String,customModels: null == customModels ? _self.customModels : customModels // ignore: cast_nullable_to_non_nullable
as List<CustomModelDefinition>,hiddenModelIds: null == hiddenModelIds ? _self.hiddenModelIds : hiddenModelIds // ignore: cast_nullable_to_non_nullable
as List<String>,managedModelIds: null == managedModelIds ? _self.managedModelIds : managedModelIds // ignore: cast_nullable_to_non_nullable
as List<String>,
  ));
}

}


/// Adds pattern-matching-related methods to [AgentModelSettings].
extension AgentModelSettingsPatterns on AgentModelSettings {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _AgentModelSettings value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _AgentModelSettings() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _AgentModelSettings value)  $default,){
final _that = this;
switch (_that) {
case _AgentModelSettings():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _AgentModelSettings value)?  $default,){
final _that = this;
switch (_that) {
case _AgentModelSettings() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String preferredModel,  String preferredEffort,  String testModel,  List<CustomModelDefinition> customModels,  List<String> hiddenModelIds,  List<String> managedModelIds)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _AgentModelSettings() when $default != null:
return $default(_that.preferredModel,_that.preferredEffort,_that.testModel,_that.customModels,_that.hiddenModelIds,_that.managedModelIds);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String preferredModel,  String preferredEffort,  String testModel,  List<CustomModelDefinition> customModels,  List<String> hiddenModelIds,  List<String> managedModelIds)  $default,) {final _that = this;
switch (_that) {
case _AgentModelSettings():
return $default(_that.preferredModel,_that.preferredEffort,_that.testModel,_that.customModels,_that.hiddenModelIds,_that.managedModelIds);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String preferredModel,  String preferredEffort,  String testModel,  List<CustomModelDefinition> customModels,  List<String> hiddenModelIds,  List<String> managedModelIds)?  $default,) {final _that = this;
switch (_that) {
case _AgentModelSettings() when $default != null:
return $default(_that.preferredModel,_that.preferredEffort,_that.testModel,_that.customModels,_that.hiddenModelIds,_that.managedModelIds);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _AgentModelSettings implements AgentModelSettings {
  const _AgentModelSettings({this.preferredModel = '', this.preferredEffort = '', this.testModel = '', final  List<CustomModelDefinition> customModels = const <CustomModelDefinition>[], final  List<String> hiddenModelIds = const <String>[], final  List<String> managedModelIds = const <String>[]}): _customModels = customModels,_hiddenModelIds = hiddenModelIds,_managedModelIds = managedModelIds;
  factory _AgentModelSettings.fromJson(Map<String, dynamic> json) => _$AgentModelSettingsFromJson(json);

@override@JsonKey() final  String preferredModel;
@override@JsonKey() final  String preferredEffort;
@override@JsonKey() final  String testModel;
 final  List<CustomModelDefinition> _customModels;
@override@JsonKey() List<CustomModelDefinition> get customModels {
  if (_customModels is EqualUnmodifiableListView) return _customModels;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_customModels);
}

 final  List<String> _hiddenModelIds;
@override@JsonKey() List<String> get hiddenModelIds {
  if (_hiddenModelIds is EqualUnmodifiableListView) return _hiddenModelIds;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_hiddenModelIds);
}

 final  List<String> _managedModelIds;
@override@JsonKey() List<String> get managedModelIds {
  if (_managedModelIds is EqualUnmodifiableListView) return _managedModelIds;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_managedModelIds);
}


/// Create a copy of AgentModelSettings
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$AgentModelSettingsCopyWith<_AgentModelSettings> get copyWith => __$AgentModelSettingsCopyWithImpl<_AgentModelSettings>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$AgentModelSettingsToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _AgentModelSettings&&(identical(other.preferredModel, preferredModel) || other.preferredModel == preferredModel)&&(identical(other.preferredEffort, preferredEffort) || other.preferredEffort == preferredEffort)&&(identical(other.testModel, testModel) || other.testModel == testModel)&&const DeepCollectionEquality().equals(other._customModels, _customModels)&&const DeepCollectionEquality().equals(other._hiddenModelIds, _hiddenModelIds)&&const DeepCollectionEquality().equals(other._managedModelIds, _managedModelIds));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,preferredModel,preferredEffort,testModel,const DeepCollectionEquality().hash(_customModels),const DeepCollectionEquality().hash(_hiddenModelIds),const DeepCollectionEquality().hash(_managedModelIds));

@override
String toString() {
  return 'AgentModelSettings(preferredModel: $preferredModel, preferredEffort: $preferredEffort, testModel: $testModel, customModels: $customModels, hiddenModelIds: $hiddenModelIds, managedModelIds: $managedModelIds)';
}


}

/// @nodoc
abstract mixin class _$AgentModelSettingsCopyWith<$Res> implements $AgentModelSettingsCopyWith<$Res> {
  factory _$AgentModelSettingsCopyWith(_AgentModelSettings value, $Res Function(_AgentModelSettings) _then) = __$AgentModelSettingsCopyWithImpl;
@override @useResult
$Res call({
 String preferredModel, String preferredEffort, String testModel, List<CustomModelDefinition> customModels, List<String> hiddenModelIds, List<String> managedModelIds
});




}
/// @nodoc
class __$AgentModelSettingsCopyWithImpl<$Res>
    implements _$AgentModelSettingsCopyWith<$Res> {
  __$AgentModelSettingsCopyWithImpl(this._self, this._then);

  final _AgentModelSettings _self;
  final $Res Function(_AgentModelSettings) _then;

/// Create a copy of AgentModelSettings
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? preferredModel = null,Object? preferredEffort = null,Object? testModel = null,Object? customModels = null,Object? hiddenModelIds = null,Object? managedModelIds = null,}) {
  return _then(_AgentModelSettings(
preferredModel: null == preferredModel ? _self.preferredModel : preferredModel // ignore: cast_nullable_to_non_nullable
as String,preferredEffort: null == preferredEffort ? _self.preferredEffort : preferredEffort // ignore: cast_nullable_to_non_nullable
as String,testModel: null == testModel ? _self.testModel : testModel // ignore: cast_nullable_to_non_nullable
as String,customModels: null == customModels ? _self._customModels : customModels // ignore: cast_nullable_to_non_nullable
as List<CustomModelDefinition>,hiddenModelIds: null == hiddenModelIds ? _self._hiddenModelIds : hiddenModelIds // ignore: cast_nullable_to_non_nullable
as List<String>,managedModelIds: null == managedModelIds ? _self._managedModelIds : managedModelIds // ignore: cast_nullable_to_non_nullable
as List<String>,
  ));
}


}


/// @nodoc
mixin _$ServerProfile {

 String get id; String get name; String get host; int get port; String get username; AuthMode get authMode; String get password; String get privateKeyPem; String get privateKeyPassphrase; String get hostFingerprint; String get workspace; String get proxyUrl; ApprovalMode get approvalMode; String get remoteCommand; bool get workspacePromptShown; String get preferredModel; String get preferredEffort; String get testModel; List<CustomModelDefinition> get customModels; List<String> get hiddenModelIds;@Deprecated('Kept only for profiles written by older app versions.') AgentMode get agentMode; AgentKind get activeAgent; Map<AgentKind, AgentModelSettings> get agentModelSettings;
/// Create a copy of ServerProfile
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ServerProfileCopyWith<ServerProfile> get copyWith => _$ServerProfileCopyWithImpl<ServerProfile>(this as ServerProfile, _$identity);

  /// Serializes this ServerProfile to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ServerProfile&&(identical(other.id, id) || other.id == id)&&(identical(other.name, name) || other.name == name)&&(identical(other.host, host) || other.host == host)&&(identical(other.port, port) || other.port == port)&&(identical(other.username, username) || other.username == username)&&(identical(other.authMode, authMode) || other.authMode == authMode)&&(identical(other.password, password) || other.password == password)&&(identical(other.privateKeyPem, privateKeyPem) || other.privateKeyPem == privateKeyPem)&&(identical(other.privateKeyPassphrase, privateKeyPassphrase) || other.privateKeyPassphrase == privateKeyPassphrase)&&(identical(other.hostFingerprint, hostFingerprint) || other.hostFingerprint == hostFingerprint)&&(identical(other.workspace, workspace) || other.workspace == workspace)&&(identical(other.proxyUrl, proxyUrl) || other.proxyUrl == proxyUrl)&&(identical(other.approvalMode, approvalMode) || other.approvalMode == approvalMode)&&(identical(other.remoteCommand, remoteCommand) || other.remoteCommand == remoteCommand)&&(identical(other.workspacePromptShown, workspacePromptShown) || other.workspacePromptShown == workspacePromptShown)&&(identical(other.preferredModel, preferredModel) || other.preferredModel == preferredModel)&&(identical(other.preferredEffort, preferredEffort) || other.preferredEffort == preferredEffort)&&(identical(other.testModel, testModel) || other.testModel == testModel)&&const DeepCollectionEquality().equals(other.customModels, customModels)&&const DeepCollectionEquality().equals(other.hiddenModelIds, hiddenModelIds)&&(identical(other.agentMode, agentMode) || other.agentMode == agentMode)&&(identical(other.activeAgent, activeAgent) || other.activeAgent == activeAgent)&&const DeepCollectionEquality().equals(other.agentModelSettings, agentModelSettings));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hashAll([runtimeType,id,name,host,port,username,authMode,password,privateKeyPem,privateKeyPassphrase,hostFingerprint,workspace,proxyUrl,approvalMode,remoteCommand,workspacePromptShown,preferredModel,preferredEffort,testModel,const DeepCollectionEquality().hash(customModels),const DeepCollectionEquality().hash(hiddenModelIds),agentMode,activeAgent,const DeepCollectionEquality().hash(agentModelSettings)]);

@override
String toString() {
  return 'ServerProfile(id: $id, name: $name, host: $host, port: $port, username: $username, authMode: $authMode, password: $password, privateKeyPem: $privateKeyPem, privateKeyPassphrase: $privateKeyPassphrase, hostFingerprint: $hostFingerprint, workspace: $workspace, proxyUrl: $proxyUrl, approvalMode: $approvalMode, remoteCommand: $remoteCommand, workspacePromptShown: $workspacePromptShown, preferredModel: $preferredModel, preferredEffort: $preferredEffort, testModel: $testModel, customModels: $customModels, hiddenModelIds: $hiddenModelIds, agentMode: $agentMode, activeAgent: $activeAgent, agentModelSettings: $agentModelSettings)';
}


}

/// @nodoc
abstract mixin class $ServerProfileCopyWith<$Res>  {
  factory $ServerProfileCopyWith(ServerProfile value, $Res Function(ServerProfile) _then) = _$ServerProfileCopyWithImpl;
@useResult
$Res call({
 String id, String name, String host, int port, String username, AuthMode authMode, String password, String privateKeyPem, String privateKeyPassphrase, String hostFingerprint, String workspace, String proxyUrl, ApprovalMode approvalMode, String remoteCommand, bool workspacePromptShown, String preferredModel, String preferredEffort, String testModel, List<CustomModelDefinition> customModels, List<String> hiddenModelIds,@Deprecated('Kept only for profiles written by older app versions.') AgentMode agentMode, AgentKind activeAgent, Map<AgentKind, AgentModelSettings> agentModelSettings
});




}
/// @nodoc
class _$ServerProfileCopyWithImpl<$Res>
    implements $ServerProfileCopyWith<$Res> {
  _$ServerProfileCopyWithImpl(this._self, this._then);

  final ServerProfile _self;
  final $Res Function(ServerProfile) _then;

/// Create a copy of ServerProfile
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? name = null,Object? host = null,Object? port = null,Object? username = null,Object? authMode = null,Object? password = null,Object? privateKeyPem = null,Object? privateKeyPassphrase = null,Object? hostFingerprint = null,Object? workspace = null,Object? proxyUrl = null,Object? approvalMode = null,Object? remoteCommand = null,Object? workspacePromptShown = null,Object? preferredModel = null,Object? preferredEffort = null,Object? testModel = null,Object? customModels = null,Object? hiddenModelIds = null,Object? agentMode = null,Object? activeAgent = null,Object? agentModelSettings = null,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,host: null == host ? _self.host : host // ignore: cast_nullable_to_non_nullable
as String,port: null == port ? _self.port : port // ignore: cast_nullable_to_non_nullable
as int,username: null == username ? _self.username : username // ignore: cast_nullable_to_non_nullable
as String,authMode: null == authMode ? _self.authMode : authMode // ignore: cast_nullable_to_non_nullable
as AuthMode,password: null == password ? _self.password : password // ignore: cast_nullable_to_non_nullable
as String,privateKeyPem: null == privateKeyPem ? _self.privateKeyPem : privateKeyPem // ignore: cast_nullable_to_non_nullable
as String,privateKeyPassphrase: null == privateKeyPassphrase ? _self.privateKeyPassphrase : privateKeyPassphrase // ignore: cast_nullable_to_non_nullable
as String,hostFingerprint: null == hostFingerprint ? _self.hostFingerprint : hostFingerprint // ignore: cast_nullable_to_non_nullable
as String,workspace: null == workspace ? _self.workspace : workspace // ignore: cast_nullable_to_non_nullable
as String,proxyUrl: null == proxyUrl ? _self.proxyUrl : proxyUrl // ignore: cast_nullable_to_non_nullable
as String,approvalMode: null == approvalMode ? _self.approvalMode : approvalMode // ignore: cast_nullable_to_non_nullable
as ApprovalMode,remoteCommand: null == remoteCommand ? _self.remoteCommand : remoteCommand // ignore: cast_nullable_to_non_nullable
as String,workspacePromptShown: null == workspacePromptShown ? _self.workspacePromptShown : workspacePromptShown // ignore: cast_nullable_to_non_nullable
as bool,preferredModel: null == preferredModel ? _self.preferredModel : preferredModel // ignore: cast_nullable_to_non_nullable
as String,preferredEffort: null == preferredEffort ? _self.preferredEffort : preferredEffort // ignore: cast_nullable_to_non_nullable
as String,testModel: null == testModel ? _self.testModel : testModel // ignore: cast_nullable_to_non_nullable
as String,customModels: null == customModels ? _self.customModels : customModels // ignore: cast_nullable_to_non_nullable
as List<CustomModelDefinition>,hiddenModelIds: null == hiddenModelIds ? _self.hiddenModelIds : hiddenModelIds // ignore: cast_nullable_to_non_nullable
as List<String>,agentMode: null == agentMode ? _self.agentMode : agentMode // ignore: cast_nullable_to_non_nullable
as AgentMode,activeAgent: null == activeAgent ? _self.activeAgent : activeAgent // ignore: cast_nullable_to_non_nullable
as AgentKind,agentModelSettings: null == agentModelSettings ? _self.agentModelSettings : agentModelSettings // ignore: cast_nullable_to_non_nullable
as Map<AgentKind, AgentModelSettings>,
  ));
}

}


/// Adds pattern-matching-related methods to [ServerProfile].
extension ServerProfilePatterns on ServerProfile {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ServerProfile value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ServerProfile() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ServerProfile value)  $default,){
final _that = this;
switch (_that) {
case _ServerProfile():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ServerProfile value)?  $default,){
final _that = this;
switch (_that) {
case _ServerProfile() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String name,  String host,  int port,  String username,  AuthMode authMode,  String password,  String privateKeyPem,  String privateKeyPassphrase,  String hostFingerprint,  String workspace,  String proxyUrl,  ApprovalMode approvalMode,  String remoteCommand,  bool workspacePromptShown,  String preferredModel,  String preferredEffort,  String testModel,  List<CustomModelDefinition> customModels,  List<String> hiddenModelIds, @Deprecated('Kept only for profiles written by older app versions.')  AgentMode agentMode,  AgentKind activeAgent,  Map<AgentKind, AgentModelSettings> agentModelSettings)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ServerProfile() when $default != null:
return $default(_that.id,_that.name,_that.host,_that.port,_that.username,_that.authMode,_that.password,_that.privateKeyPem,_that.privateKeyPassphrase,_that.hostFingerprint,_that.workspace,_that.proxyUrl,_that.approvalMode,_that.remoteCommand,_that.workspacePromptShown,_that.preferredModel,_that.preferredEffort,_that.testModel,_that.customModels,_that.hiddenModelIds,_that.agentMode,_that.activeAgent,_that.agentModelSettings);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String name,  String host,  int port,  String username,  AuthMode authMode,  String password,  String privateKeyPem,  String privateKeyPassphrase,  String hostFingerprint,  String workspace,  String proxyUrl,  ApprovalMode approvalMode,  String remoteCommand,  bool workspacePromptShown,  String preferredModel,  String preferredEffort,  String testModel,  List<CustomModelDefinition> customModels,  List<String> hiddenModelIds, @Deprecated('Kept only for profiles written by older app versions.')  AgentMode agentMode,  AgentKind activeAgent,  Map<AgentKind, AgentModelSettings> agentModelSettings)  $default,) {final _that = this;
switch (_that) {
case _ServerProfile():
return $default(_that.id,_that.name,_that.host,_that.port,_that.username,_that.authMode,_that.password,_that.privateKeyPem,_that.privateKeyPassphrase,_that.hostFingerprint,_that.workspace,_that.proxyUrl,_that.approvalMode,_that.remoteCommand,_that.workspacePromptShown,_that.preferredModel,_that.preferredEffort,_that.testModel,_that.customModels,_that.hiddenModelIds,_that.agentMode,_that.activeAgent,_that.agentModelSettings);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String name,  String host,  int port,  String username,  AuthMode authMode,  String password,  String privateKeyPem,  String privateKeyPassphrase,  String hostFingerprint,  String workspace,  String proxyUrl,  ApprovalMode approvalMode,  String remoteCommand,  bool workspacePromptShown,  String preferredModel,  String preferredEffort,  String testModel,  List<CustomModelDefinition> customModels,  List<String> hiddenModelIds, @Deprecated('Kept only for profiles written by older app versions.')  AgentMode agentMode,  AgentKind activeAgent,  Map<AgentKind, AgentModelSettings> agentModelSettings)?  $default,) {final _that = this;
switch (_that) {
case _ServerProfile() when $default != null:
return $default(_that.id,_that.name,_that.host,_that.port,_that.username,_that.authMode,_that.password,_that.privateKeyPem,_that.privateKeyPassphrase,_that.hostFingerprint,_that.workspace,_that.proxyUrl,_that.approvalMode,_that.remoteCommand,_that.workspacePromptShown,_that.preferredModel,_that.preferredEffort,_that.testModel,_that.customModels,_that.hiddenModelIds,_that.agentMode,_that.activeAgent,_that.agentModelSettings);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ServerProfile extends ServerProfile {
  const _ServerProfile({this.id = '', this.name = '我的服务器', this.host = '', this.port = 22, this.username = 'root', this.authMode = AuthMode.privateKey, this.password = '', this.privateKeyPem = '', this.privateKeyPassphrase = '', this.hostFingerprint = '', this.workspace = '', this.proxyUrl = '', this.approvalMode = ApprovalMode.requestApproval, this.remoteCommand = '~/.local/bin/codex-remote app-server --listen stdio://', this.workspacePromptShown = false, this.preferredModel = '', this.preferredEffort = '', this.testModel = '', final  List<CustomModelDefinition> customModels = const <CustomModelDefinition>[], final  List<String> hiddenModelIds = const <String>[], @Deprecated('Kept only for profiles written by older app versions.') this.agentMode = AgentMode.codex, this.activeAgent = AgentKind.codex, final  Map<AgentKind, AgentModelSettings> agentModelSettings = const <AgentKind, AgentModelSettings>{}}): _customModels = customModels,_hiddenModelIds = hiddenModelIds,_agentModelSettings = agentModelSettings,super._();
  factory _ServerProfile.fromJson(Map<String, dynamic> json) => _$ServerProfileFromJson(json);

@override@JsonKey() final  String id;
@override@JsonKey() final  String name;
@override@JsonKey() final  String host;
@override@JsonKey() final  int port;
@override@JsonKey() final  String username;
@override@JsonKey() final  AuthMode authMode;
@override@JsonKey() final  String password;
@override@JsonKey() final  String privateKeyPem;
@override@JsonKey() final  String privateKeyPassphrase;
@override@JsonKey() final  String hostFingerprint;
@override@JsonKey() final  String workspace;
@override@JsonKey() final  String proxyUrl;
@override@JsonKey() final  ApprovalMode approvalMode;
@override@JsonKey() final  String remoteCommand;
@override@JsonKey() final  bool workspacePromptShown;
@override@JsonKey() final  String preferredModel;
@override@JsonKey() final  String preferredEffort;
@override@JsonKey() final  String testModel;
 final  List<CustomModelDefinition> _customModels;
@override@JsonKey() List<CustomModelDefinition> get customModels {
  if (_customModels is EqualUnmodifiableListView) return _customModels;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_customModels);
}

 final  List<String> _hiddenModelIds;
@override@JsonKey() List<String> get hiddenModelIds {
  if (_hiddenModelIds is EqualUnmodifiableListView) return _hiddenModelIds;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_hiddenModelIds);
}

@override@JsonKey()@Deprecated('Kept only for profiles written by older app versions.') final  AgentMode agentMode;
@override@JsonKey() final  AgentKind activeAgent;
 final  Map<AgentKind, AgentModelSettings> _agentModelSettings;
@override@JsonKey() Map<AgentKind, AgentModelSettings> get agentModelSettings {
  if (_agentModelSettings is EqualUnmodifiableMapView) return _agentModelSettings;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_agentModelSettings);
}


/// Create a copy of ServerProfile
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ServerProfileCopyWith<_ServerProfile> get copyWith => __$ServerProfileCopyWithImpl<_ServerProfile>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ServerProfileToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ServerProfile&&(identical(other.id, id) || other.id == id)&&(identical(other.name, name) || other.name == name)&&(identical(other.host, host) || other.host == host)&&(identical(other.port, port) || other.port == port)&&(identical(other.username, username) || other.username == username)&&(identical(other.authMode, authMode) || other.authMode == authMode)&&(identical(other.password, password) || other.password == password)&&(identical(other.privateKeyPem, privateKeyPem) || other.privateKeyPem == privateKeyPem)&&(identical(other.privateKeyPassphrase, privateKeyPassphrase) || other.privateKeyPassphrase == privateKeyPassphrase)&&(identical(other.hostFingerprint, hostFingerprint) || other.hostFingerprint == hostFingerprint)&&(identical(other.workspace, workspace) || other.workspace == workspace)&&(identical(other.proxyUrl, proxyUrl) || other.proxyUrl == proxyUrl)&&(identical(other.approvalMode, approvalMode) || other.approvalMode == approvalMode)&&(identical(other.remoteCommand, remoteCommand) || other.remoteCommand == remoteCommand)&&(identical(other.workspacePromptShown, workspacePromptShown) || other.workspacePromptShown == workspacePromptShown)&&(identical(other.preferredModel, preferredModel) || other.preferredModel == preferredModel)&&(identical(other.preferredEffort, preferredEffort) || other.preferredEffort == preferredEffort)&&(identical(other.testModel, testModel) || other.testModel == testModel)&&const DeepCollectionEquality().equals(other._customModels, _customModels)&&const DeepCollectionEquality().equals(other._hiddenModelIds, _hiddenModelIds)&&(identical(other.agentMode, agentMode) || other.agentMode == agentMode)&&(identical(other.activeAgent, activeAgent) || other.activeAgent == activeAgent)&&const DeepCollectionEquality().equals(other._agentModelSettings, _agentModelSettings));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hashAll([runtimeType,id,name,host,port,username,authMode,password,privateKeyPem,privateKeyPassphrase,hostFingerprint,workspace,proxyUrl,approvalMode,remoteCommand,workspacePromptShown,preferredModel,preferredEffort,testModel,const DeepCollectionEquality().hash(_customModels),const DeepCollectionEquality().hash(_hiddenModelIds),agentMode,activeAgent,const DeepCollectionEquality().hash(_agentModelSettings)]);

@override
String toString() {
  return 'ServerProfile(id: $id, name: $name, host: $host, port: $port, username: $username, authMode: $authMode, password: $password, privateKeyPem: $privateKeyPem, privateKeyPassphrase: $privateKeyPassphrase, hostFingerprint: $hostFingerprint, workspace: $workspace, proxyUrl: $proxyUrl, approvalMode: $approvalMode, remoteCommand: $remoteCommand, workspacePromptShown: $workspacePromptShown, preferredModel: $preferredModel, preferredEffort: $preferredEffort, testModel: $testModel, customModels: $customModels, hiddenModelIds: $hiddenModelIds, agentMode: $agentMode, activeAgent: $activeAgent, agentModelSettings: $agentModelSettings)';
}


}

/// @nodoc
abstract mixin class _$ServerProfileCopyWith<$Res> implements $ServerProfileCopyWith<$Res> {
  factory _$ServerProfileCopyWith(_ServerProfile value, $Res Function(_ServerProfile) _then) = __$ServerProfileCopyWithImpl;
@override @useResult
$Res call({
 String id, String name, String host, int port, String username, AuthMode authMode, String password, String privateKeyPem, String privateKeyPassphrase, String hostFingerprint, String workspace, String proxyUrl, ApprovalMode approvalMode, String remoteCommand, bool workspacePromptShown, String preferredModel, String preferredEffort, String testModel, List<CustomModelDefinition> customModels, List<String> hiddenModelIds,@Deprecated('Kept only for profiles written by older app versions.') AgentMode agentMode, AgentKind activeAgent, Map<AgentKind, AgentModelSettings> agentModelSettings
});




}
/// @nodoc
class __$ServerProfileCopyWithImpl<$Res>
    implements _$ServerProfileCopyWith<$Res> {
  __$ServerProfileCopyWithImpl(this._self, this._then);

  final _ServerProfile _self;
  final $Res Function(_ServerProfile) _then;

/// Create a copy of ServerProfile
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? name = null,Object? host = null,Object? port = null,Object? username = null,Object? authMode = null,Object? password = null,Object? privateKeyPem = null,Object? privateKeyPassphrase = null,Object? hostFingerprint = null,Object? workspace = null,Object? proxyUrl = null,Object? approvalMode = null,Object? remoteCommand = null,Object? workspacePromptShown = null,Object? preferredModel = null,Object? preferredEffort = null,Object? testModel = null,Object? customModels = null,Object? hiddenModelIds = null,Object? agentMode = null,Object? activeAgent = null,Object? agentModelSettings = null,}) {
  return _then(_ServerProfile(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,host: null == host ? _self.host : host // ignore: cast_nullable_to_non_nullable
as String,port: null == port ? _self.port : port // ignore: cast_nullable_to_non_nullable
as int,username: null == username ? _self.username : username // ignore: cast_nullable_to_non_nullable
as String,authMode: null == authMode ? _self.authMode : authMode // ignore: cast_nullable_to_non_nullable
as AuthMode,password: null == password ? _self.password : password // ignore: cast_nullable_to_non_nullable
as String,privateKeyPem: null == privateKeyPem ? _self.privateKeyPem : privateKeyPem // ignore: cast_nullable_to_non_nullable
as String,privateKeyPassphrase: null == privateKeyPassphrase ? _self.privateKeyPassphrase : privateKeyPassphrase // ignore: cast_nullable_to_non_nullable
as String,hostFingerprint: null == hostFingerprint ? _self.hostFingerprint : hostFingerprint // ignore: cast_nullable_to_non_nullable
as String,workspace: null == workspace ? _self.workspace : workspace // ignore: cast_nullable_to_non_nullable
as String,proxyUrl: null == proxyUrl ? _self.proxyUrl : proxyUrl // ignore: cast_nullable_to_non_nullable
as String,approvalMode: null == approvalMode ? _self.approvalMode : approvalMode // ignore: cast_nullable_to_non_nullable
as ApprovalMode,remoteCommand: null == remoteCommand ? _self.remoteCommand : remoteCommand // ignore: cast_nullable_to_non_nullable
as String,workspacePromptShown: null == workspacePromptShown ? _self.workspacePromptShown : workspacePromptShown // ignore: cast_nullable_to_non_nullable
as bool,preferredModel: null == preferredModel ? _self.preferredModel : preferredModel // ignore: cast_nullable_to_non_nullable
as String,preferredEffort: null == preferredEffort ? _self.preferredEffort : preferredEffort // ignore: cast_nullable_to_non_nullable
as String,testModel: null == testModel ? _self.testModel : testModel // ignore: cast_nullable_to_non_nullable
as String,customModels: null == customModels ? _self._customModels : customModels // ignore: cast_nullable_to_non_nullable
as List<CustomModelDefinition>,hiddenModelIds: null == hiddenModelIds ? _self._hiddenModelIds : hiddenModelIds // ignore: cast_nullable_to_non_nullable
as List<String>,agentMode: null == agentMode ? _self.agentMode : agentMode // ignore: cast_nullable_to_non_nullable
as AgentMode,activeAgent: null == activeAgent ? _self.activeAgent : activeAgent // ignore: cast_nullable_to_non_nullable
as AgentKind,agentModelSettings: null == agentModelSettings ? _self._agentModelSettings : agentModelSettings // ignore: cast_nullable_to_non_nullable
as Map<AgentKind, AgentModelSettings>,
  ));
}


}


/// @nodoc
mixin _$ThreadModelPreference {

 String get model; String get effort;
/// Create a copy of ThreadModelPreference
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ThreadModelPreferenceCopyWith<ThreadModelPreference> get copyWith => _$ThreadModelPreferenceCopyWithImpl<ThreadModelPreference>(this as ThreadModelPreference, _$identity);

  /// Serializes this ThreadModelPreference to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ThreadModelPreference&&(identical(other.model, model) || other.model == model)&&(identical(other.effort, effort) || other.effort == effort));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,model,effort);

@override
String toString() {
  return 'ThreadModelPreference(model: $model, effort: $effort)';
}


}

/// @nodoc
abstract mixin class $ThreadModelPreferenceCopyWith<$Res>  {
  factory $ThreadModelPreferenceCopyWith(ThreadModelPreference value, $Res Function(ThreadModelPreference) _then) = _$ThreadModelPreferenceCopyWithImpl;
@useResult
$Res call({
 String model, String effort
});




}
/// @nodoc
class _$ThreadModelPreferenceCopyWithImpl<$Res>
    implements $ThreadModelPreferenceCopyWith<$Res> {
  _$ThreadModelPreferenceCopyWithImpl(this._self, this._then);

  final ThreadModelPreference _self;
  final $Res Function(ThreadModelPreference) _then;

/// Create a copy of ThreadModelPreference
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? model = null,Object? effort = null,}) {
  return _then(_self.copyWith(
model: null == model ? _self.model : model // ignore: cast_nullable_to_non_nullable
as String,effort: null == effort ? _self.effort : effort // ignore: cast_nullable_to_non_nullable
as String,
  ));
}

}


/// Adds pattern-matching-related methods to [ThreadModelPreference].
extension ThreadModelPreferencePatterns on ThreadModelPreference {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ThreadModelPreference value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ThreadModelPreference() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ThreadModelPreference value)  $default,){
final _that = this;
switch (_that) {
case _ThreadModelPreference():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ThreadModelPreference value)?  $default,){
final _that = this;
switch (_that) {
case _ThreadModelPreference() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String model,  String effort)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ThreadModelPreference() when $default != null:
return $default(_that.model,_that.effort);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String model,  String effort)  $default,) {final _that = this;
switch (_that) {
case _ThreadModelPreference():
return $default(_that.model,_that.effort);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String model,  String effort)?  $default,) {final _that = this;
switch (_that) {
case _ThreadModelPreference() when $default != null:
return $default(_that.model,_that.effort);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ThreadModelPreference implements ThreadModelPreference {
  const _ThreadModelPreference({this.model = '', this.effort = ''});
  factory _ThreadModelPreference.fromJson(Map<String, dynamic> json) => _$ThreadModelPreferenceFromJson(json);

@override@JsonKey() final  String model;
@override@JsonKey() final  String effort;

/// Create a copy of ThreadModelPreference
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ThreadModelPreferenceCopyWith<_ThreadModelPreference> get copyWith => __$ThreadModelPreferenceCopyWithImpl<_ThreadModelPreference>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ThreadModelPreferenceToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ThreadModelPreference&&(identical(other.model, model) || other.model == model)&&(identical(other.effort, effort) || other.effort == effort));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,model,effort);

@override
String toString() {
  return 'ThreadModelPreference(model: $model, effort: $effort)';
}


}

/// @nodoc
abstract mixin class _$ThreadModelPreferenceCopyWith<$Res> implements $ThreadModelPreferenceCopyWith<$Res> {
  factory _$ThreadModelPreferenceCopyWith(_ThreadModelPreference value, $Res Function(_ThreadModelPreference) _then) = __$ThreadModelPreferenceCopyWithImpl;
@override @useResult
$Res call({
 String model, String effort
});




}
/// @nodoc
class __$ThreadModelPreferenceCopyWithImpl<$Res>
    implements _$ThreadModelPreferenceCopyWith<$Res> {
  __$ThreadModelPreferenceCopyWithImpl(this._self, this._then);

  final _ThreadModelPreference _self;
  final $Res Function(_ThreadModelPreference) _then;

/// Create a copy of ThreadModelPreference
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? model = null,Object? effort = null,}) {
  return _then(_ThreadModelPreference(
model: null == model ? _self.model : model // ignore: cast_nullable_to_non_nullable
as String,effort: null == effort ? _self.effort : effort // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}


/// @nodoc
mixin _$TurnTiming {

 String get threadId; String? get turnId; int get startedAtMillis; int? get completedAtMillis; bool get stopped;
/// Create a copy of TurnTiming
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$TurnTimingCopyWith<TurnTiming> get copyWith => _$TurnTimingCopyWithImpl<TurnTiming>(this as TurnTiming, _$identity);

  /// Serializes this TurnTiming to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is TurnTiming&&(identical(other.threadId, threadId) || other.threadId == threadId)&&(identical(other.turnId, turnId) || other.turnId == turnId)&&(identical(other.startedAtMillis, startedAtMillis) || other.startedAtMillis == startedAtMillis)&&(identical(other.completedAtMillis, completedAtMillis) || other.completedAtMillis == completedAtMillis)&&(identical(other.stopped, stopped) || other.stopped == stopped));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,threadId,turnId,startedAtMillis,completedAtMillis,stopped);

@override
String toString() {
  return 'TurnTiming(threadId: $threadId, turnId: $turnId, startedAtMillis: $startedAtMillis, completedAtMillis: $completedAtMillis, stopped: $stopped)';
}


}

/// @nodoc
abstract mixin class $TurnTimingCopyWith<$Res>  {
  factory $TurnTimingCopyWith(TurnTiming value, $Res Function(TurnTiming) _then) = _$TurnTimingCopyWithImpl;
@useResult
$Res call({
 String threadId, String? turnId, int startedAtMillis, int? completedAtMillis, bool stopped
});




}
/// @nodoc
class _$TurnTimingCopyWithImpl<$Res>
    implements $TurnTimingCopyWith<$Res> {
  _$TurnTimingCopyWithImpl(this._self, this._then);

  final TurnTiming _self;
  final $Res Function(TurnTiming) _then;

/// Create a copy of TurnTiming
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? threadId = null,Object? turnId = freezed,Object? startedAtMillis = null,Object? completedAtMillis = freezed,Object? stopped = null,}) {
  return _then(_self.copyWith(
threadId: null == threadId ? _self.threadId : threadId // ignore: cast_nullable_to_non_nullable
as String,turnId: freezed == turnId ? _self.turnId : turnId // ignore: cast_nullable_to_non_nullable
as String?,startedAtMillis: null == startedAtMillis ? _self.startedAtMillis : startedAtMillis // ignore: cast_nullable_to_non_nullable
as int,completedAtMillis: freezed == completedAtMillis ? _self.completedAtMillis : completedAtMillis // ignore: cast_nullable_to_non_nullable
as int?,stopped: null == stopped ? _self.stopped : stopped // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}

}


/// Adds pattern-matching-related methods to [TurnTiming].
extension TurnTimingPatterns on TurnTiming {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _TurnTiming value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _TurnTiming() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _TurnTiming value)  $default,){
final _that = this;
switch (_that) {
case _TurnTiming():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _TurnTiming value)?  $default,){
final _that = this;
switch (_that) {
case _TurnTiming() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String threadId,  String? turnId,  int startedAtMillis,  int? completedAtMillis,  bool stopped)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _TurnTiming() when $default != null:
return $default(_that.threadId,_that.turnId,_that.startedAtMillis,_that.completedAtMillis,_that.stopped);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String threadId,  String? turnId,  int startedAtMillis,  int? completedAtMillis,  bool stopped)  $default,) {final _that = this;
switch (_that) {
case _TurnTiming():
return $default(_that.threadId,_that.turnId,_that.startedAtMillis,_that.completedAtMillis,_that.stopped);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String threadId,  String? turnId,  int startedAtMillis,  int? completedAtMillis,  bool stopped)?  $default,) {final _that = this;
switch (_that) {
case _TurnTiming() when $default != null:
return $default(_that.threadId,_that.turnId,_that.startedAtMillis,_that.completedAtMillis,_that.stopped);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _TurnTiming implements TurnTiming {
  const _TurnTiming({required this.threadId, this.turnId, required this.startedAtMillis, this.completedAtMillis, this.stopped = false});
  factory _TurnTiming.fromJson(Map<String, dynamic> json) => _$TurnTimingFromJson(json);

@override final  String threadId;
@override final  String? turnId;
@override final  int startedAtMillis;
@override final  int? completedAtMillis;
@override@JsonKey() final  bool stopped;

/// Create a copy of TurnTiming
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$TurnTimingCopyWith<_TurnTiming> get copyWith => __$TurnTimingCopyWithImpl<_TurnTiming>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$TurnTimingToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _TurnTiming&&(identical(other.threadId, threadId) || other.threadId == threadId)&&(identical(other.turnId, turnId) || other.turnId == turnId)&&(identical(other.startedAtMillis, startedAtMillis) || other.startedAtMillis == startedAtMillis)&&(identical(other.completedAtMillis, completedAtMillis) || other.completedAtMillis == completedAtMillis)&&(identical(other.stopped, stopped) || other.stopped == stopped));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,threadId,turnId,startedAtMillis,completedAtMillis,stopped);

@override
String toString() {
  return 'TurnTiming(threadId: $threadId, turnId: $turnId, startedAtMillis: $startedAtMillis, completedAtMillis: $completedAtMillis, stopped: $stopped)';
}


}

/// @nodoc
abstract mixin class _$TurnTimingCopyWith<$Res> implements $TurnTimingCopyWith<$Res> {
  factory _$TurnTimingCopyWith(_TurnTiming value, $Res Function(_TurnTiming) _then) = __$TurnTimingCopyWithImpl;
@override @useResult
$Res call({
 String threadId, String? turnId, int startedAtMillis, int? completedAtMillis, bool stopped
});




}
/// @nodoc
class __$TurnTimingCopyWithImpl<$Res>
    implements _$TurnTimingCopyWith<$Res> {
  __$TurnTimingCopyWithImpl(this._self, this._then);

  final _TurnTiming _self;
  final $Res Function(_TurnTiming) _then;

/// Create a copy of TurnTiming
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? threadId = null,Object? turnId = freezed,Object? startedAtMillis = null,Object? completedAtMillis = freezed,Object? stopped = null,}) {
  return _then(_TurnTiming(
threadId: null == threadId ? _self.threadId : threadId // ignore: cast_nullable_to_non_nullable
as String,turnId: freezed == turnId ? _self.turnId : turnId // ignore: cast_nullable_to_non_nullable
as String?,startedAtMillis: null == startedAtMillis ? _self.startedAtMillis : startedAtMillis // ignore: cast_nullable_to_non_nullable
as int,completedAtMillis: freezed == completedAtMillis ? _self.completedAtMillis : completedAtMillis // ignore: cast_nullable_to_non_nullable
as int?,stopped: null == stopped ? _self.stopped : stopped // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}


/// @nodoc
mixin _$StoredProfiles {

 List<ServerProfile> get profiles; String? get selectedProfileId; Map<String, String> get composerDrafts; Map<String, ThreadModelPreference> get threadModelPreferences; Map<String, TurnTiming> get completedTurnTimings;
/// Create a copy of StoredProfiles
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$StoredProfilesCopyWith<StoredProfiles> get copyWith => _$StoredProfilesCopyWithImpl<StoredProfiles>(this as StoredProfiles, _$identity);

  /// Serializes this StoredProfiles to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is StoredProfiles&&const DeepCollectionEquality().equals(other.profiles, profiles)&&(identical(other.selectedProfileId, selectedProfileId) || other.selectedProfileId == selectedProfileId)&&const DeepCollectionEquality().equals(other.composerDrafts, composerDrafts)&&const DeepCollectionEquality().equals(other.threadModelPreferences, threadModelPreferences)&&const DeepCollectionEquality().equals(other.completedTurnTimings, completedTurnTimings));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(profiles),selectedProfileId,const DeepCollectionEquality().hash(composerDrafts),const DeepCollectionEquality().hash(threadModelPreferences),const DeepCollectionEquality().hash(completedTurnTimings));

@override
String toString() {
  return 'StoredProfiles(profiles: $profiles, selectedProfileId: $selectedProfileId, composerDrafts: $composerDrafts, threadModelPreferences: $threadModelPreferences, completedTurnTimings: $completedTurnTimings)';
}


}

/// @nodoc
abstract mixin class $StoredProfilesCopyWith<$Res>  {
  factory $StoredProfilesCopyWith(StoredProfiles value, $Res Function(StoredProfiles) _then) = _$StoredProfilesCopyWithImpl;
@useResult
$Res call({
 List<ServerProfile> profiles, String? selectedProfileId, Map<String, String> composerDrafts, Map<String, ThreadModelPreference> threadModelPreferences, Map<String, TurnTiming> completedTurnTimings
});




}
/// @nodoc
class _$StoredProfilesCopyWithImpl<$Res>
    implements $StoredProfilesCopyWith<$Res> {
  _$StoredProfilesCopyWithImpl(this._self, this._then);

  final StoredProfiles _self;
  final $Res Function(StoredProfiles) _then;

/// Create a copy of StoredProfiles
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? profiles = null,Object? selectedProfileId = freezed,Object? composerDrafts = null,Object? threadModelPreferences = null,Object? completedTurnTimings = null,}) {
  return _then(_self.copyWith(
profiles: null == profiles ? _self.profiles : profiles // ignore: cast_nullable_to_non_nullable
as List<ServerProfile>,selectedProfileId: freezed == selectedProfileId ? _self.selectedProfileId : selectedProfileId // ignore: cast_nullable_to_non_nullable
as String?,composerDrafts: null == composerDrafts ? _self.composerDrafts : composerDrafts // ignore: cast_nullable_to_non_nullable
as Map<String, String>,threadModelPreferences: null == threadModelPreferences ? _self.threadModelPreferences : threadModelPreferences // ignore: cast_nullable_to_non_nullable
as Map<String, ThreadModelPreference>,completedTurnTimings: null == completedTurnTimings ? _self.completedTurnTimings : completedTurnTimings // ignore: cast_nullable_to_non_nullable
as Map<String, TurnTiming>,
  ));
}

}


/// Adds pattern-matching-related methods to [StoredProfiles].
extension StoredProfilesPatterns on StoredProfiles {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _StoredProfiles value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _StoredProfiles() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _StoredProfiles value)  $default,){
final _that = this;
switch (_that) {
case _StoredProfiles():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _StoredProfiles value)?  $default,){
final _that = this;
switch (_that) {
case _StoredProfiles() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( List<ServerProfile> profiles,  String? selectedProfileId,  Map<String, String> composerDrafts,  Map<String, ThreadModelPreference> threadModelPreferences,  Map<String, TurnTiming> completedTurnTimings)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _StoredProfiles() when $default != null:
return $default(_that.profiles,_that.selectedProfileId,_that.composerDrafts,_that.threadModelPreferences,_that.completedTurnTimings);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( List<ServerProfile> profiles,  String? selectedProfileId,  Map<String, String> composerDrafts,  Map<String, ThreadModelPreference> threadModelPreferences,  Map<String, TurnTiming> completedTurnTimings)  $default,) {final _that = this;
switch (_that) {
case _StoredProfiles():
return $default(_that.profiles,_that.selectedProfileId,_that.composerDrafts,_that.threadModelPreferences,_that.completedTurnTimings);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( List<ServerProfile> profiles,  String? selectedProfileId,  Map<String, String> composerDrafts,  Map<String, ThreadModelPreference> threadModelPreferences,  Map<String, TurnTiming> completedTurnTimings)?  $default,) {final _that = this;
switch (_that) {
case _StoredProfiles() when $default != null:
return $default(_that.profiles,_that.selectedProfileId,_that.composerDrafts,_that.threadModelPreferences,_that.completedTurnTimings);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _StoredProfiles implements StoredProfiles {
  const _StoredProfiles({final  List<ServerProfile> profiles = const <ServerProfile>[], this.selectedProfileId, final  Map<String, String> composerDrafts = const <String, String>{}, final  Map<String, ThreadModelPreference> threadModelPreferences = const <String, ThreadModelPreference>{}, final  Map<String, TurnTiming> completedTurnTimings = const <String, TurnTiming>{}}): _profiles = profiles,_composerDrafts = composerDrafts,_threadModelPreferences = threadModelPreferences,_completedTurnTimings = completedTurnTimings;
  factory _StoredProfiles.fromJson(Map<String, dynamic> json) => _$StoredProfilesFromJson(json);

 final  List<ServerProfile> _profiles;
@override@JsonKey() List<ServerProfile> get profiles {
  if (_profiles is EqualUnmodifiableListView) return _profiles;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_profiles);
}

@override final  String? selectedProfileId;
 final  Map<String, String> _composerDrafts;
@override@JsonKey() Map<String, String> get composerDrafts {
  if (_composerDrafts is EqualUnmodifiableMapView) return _composerDrafts;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_composerDrafts);
}

 final  Map<String, ThreadModelPreference> _threadModelPreferences;
@override@JsonKey() Map<String, ThreadModelPreference> get threadModelPreferences {
  if (_threadModelPreferences is EqualUnmodifiableMapView) return _threadModelPreferences;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_threadModelPreferences);
}

 final  Map<String, TurnTiming> _completedTurnTimings;
@override@JsonKey() Map<String, TurnTiming> get completedTurnTimings {
  if (_completedTurnTimings is EqualUnmodifiableMapView) return _completedTurnTimings;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_completedTurnTimings);
}


/// Create a copy of StoredProfiles
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$StoredProfilesCopyWith<_StoredProfiles> get copyWith => __$StoredProfilesCopyWithImpl<_StoredProfiles>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$StoredProfilesToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _StoredProfiles&&const DeepCollectionEquality().equals(other._profiles, _profiles)&&(identical(other.selectedProfileId, selectedProfileId) || other.selectedProfileId == selectedProfileId)&&const DeepCollectionEquality().equals(other._composerDrafts, _composerDrafts)&&const DeepCollectionEquality().equals(other._threadModelPreferences, _threadModelPreferences)&&const DeepCollectionEquality().equals(other._completedTurnTimings, _completedTurnTimings));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(_profiles),selectedProfileId,const DeepCollectionEquality().hash(_composerDrafts),const DeepCollectionEquality().hash(_threadModelPreferences),const DeepCollectionEquality().hash(_completedTurnTimings));

@override
String toString() {
  return 'StoredProfiles(profiles: $profiles, selectedProfileId: $selectedProfileId, composerDrafts: $composerDrafts, threadModelPreferences: $threadModelPreferences, completedTurnTimings: $completedTurnTimings)';
}


}

/// @nodoc
abstract mixin class _$StoredProfilesCopyWith<$Res> implements $StoredProfilesCopyWith<$Res> {
  factory _$StoredProfilesCopyWith(_StoredProfiles value, $Res Function(_StoredProfiles) _then) = __$StoredProfilesCopyWithImpl;
@override @useResult
$Res call({
 List<ServerProfile> profiles, String? selectedProfileId, Map<String, String> composerDrafts, Map<String, ThreadModelPreference> threadModelPreferences, Map<String, TurnTiming> completedTurnTimings
});




}
/// @nodoc
class __$StoredProfilesCopyWithImpl<$Res>
    implements _$StoredProfilesCopyWith<$Res> {
  __$StoredProfilesCopyWithImpl(this._self, this._then);

  final _StoredProfiles _self;
  final $Res Function(_StoredProfiles) _then;

/// Create a copy of StoredProfiles
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? profiles = null,Object? selectedProfileId = freezed,Object? composerDrafts = null,Object? threadModelPreferences = null,Object? completedTurnTimings = null,}) {
  return _then(_StoredProfiles(
profiles: null == profiles ? _self._profiles : profiles // ignore: cast_nullable_to_non_nullable
as List<ServerProfile>,selectedProfileId: freezed == selectedProfileId ? _self.selectedProfileId : selectedProfileId // ignore: cast_nullable_to_non_nullable
as String?,composerDrafts: null == composerDrafts ? _self._composerDrafts : composerDrafts // ignore: cast_nullable_to_non_nullable
as Map<String, String>,threadModelPreferences: null == threadModelPreferences ? _self._threadModelPreferences : threadModelPreferences // ignore: cast_nullable_to_non_nullable
as Map<String, ThreadModelPreference>,completedTurnTimings: null == completedTurnTimings ? _self._completedTurnTimings : completedTurnTimings // ignore: cast_nullable_to_non_nullable
as Map<String, TurnTiming>,
  ));
}


}

/// @nodoc
mixin _$ConnectionState {

 ConnectionPhase get phase; String get message; String? get cliVersion;
/// Create a copy of ConnectionState
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ConnectionStateCopyWith<ConnectionState> get copyWith => _$ConnectionStateCopyWithImpl<ConnectionState>(this as ConnectionState, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ConnectionState&&(identical(other.phase, phase) || other.phase == phase)&&(identical(other.message, message) || other.message == message)&&(identical(other.cliVersion, cliVersion) || other.cliVersion == cliVersion));
}


@override
int get hashCode => Object.hash(runtimeType,phase,message,cliVersion);

@override
String toString() {
  return 'ConnectionState(phase: $phase, message: $message, cliVersion: $cliVersion)';
}


}

/// @nodoc
abstract mixin class $ConnectionStateCopyWith<$Res>  {
  factory $ConnectionStateCopyWith(ConnectionState value, $Res Function(ConnectionState) _then) = _$ConnectionStateCopyWithImpl;
@useResult
$Res call({
 ConnectionPhase phase, String message, String? cliVersion
});




}
/// @nodoc
class _$ConnectionStateCopyWithImpl<$Res>
    implements $ConnectionStateCopyWith<$Res> {
  _$ConnectionStateCopyWithImpl(this._self, this._then);

  final ConnectionState _self;
  final $Res Function(ConnectionState) _then;

/// Create a copy of ConnectionState
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? phase = null,Object? message = null,Object? cliVersion = freezed,}) {
  return _then(_self.copyWith(
phase: null == phase ? _self.phase : phase // ignore: cast_nullable_to_non_nullable
as ConnectionPhase,message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,cliVersion: freezed == cliVersion ? _self.cliVersion : cliVersion // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// Adds pattern-matching-related methods to [ConnectionState].
extension ConnectionStatePatterns on ConnectionState {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ConnectionState value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ConnectionState() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ConnectionState value)  $default,){
final _that = this;
switch (_that) {
case _ConnectionState():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ConnectionState value)?  $default,){
final _that = this;
switch (_that) {
case _ConnectionState() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( ConnectionPhase phase,  String message,  String? cliVersion)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ConnectionState() when $default != null:
return $default(_that.phase,_that.message,_that.cliVersion);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( ConnectionPhase phase,  String message,  String? cliVersion)  $default,) {final _that = this;
switch (_that) {
case _ConnectionState():
return $default(_that.phase,_that.message,_that.cliVersion);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( ConnectionPhase phase,  String message,  String? cliVersion)?  $default,) {final _that = this;
switch (_that) {
case _ConnectionState() when $default != null:
return $default(_that.phase,_that.message,_that.cliVersion);case _:
  return null;

}
}

}

/// @nodoc


class _ConnectionState implements ConnectionState {
  const _ConnectionState({this.phase = ConnectionPhase.disconnected, this.message = '未连接', this.cliVersion});
  

@override@JsonKey() final  ConnectionPhase phase;
@override@JsonKey() final  String message;
@override final  String? cliVersion;

/// Create a copy of ConnectionState
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ConnectionStateCopyWith<_ConnectionState> get copyWith => __$ConnectionStateCopyWithImpl<_ConnectionState>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ConnectionState&&(identical(other.phase, phase) || other.phase == phase)&&(identical(other.message, message) || other.message == message)&&(identical(other.cliVersion, cliVersion) || other.cliVersion == cliVersion));
}


@override
int get hashCode => Object.hash(runtimeType,phase,message,cliVersion);

@override
String toString() {
  return 'ConnectionState(phase: $phase, message: $message, cliVersion: $cliVersion)';
}


}

/// @nodoc
abstract mixin class _$ConnectionStateCopyWith<$Res> implements $ConnectionStateCopyWith<$Res> {
  factory _$ConnectionStateCopyWith(_ConnectionState value, $Res Function(_ConnectionState) _then) = __$ConnectionStateCopyWithImpl;
@override @useResult
$Res call({
 ConnectionPhase phase, String message, String? cliVersion
});




}
/// @nodoc
class __$ConnectionStateCopyWithImpl<$Res>
    implements _$ConnectionStateCopyWith<$Res> {
  __$ConnectionStateCopyWithImpl(this._self, this._then);

  final _ConnectionState _self;
  final $Res Function(_ConnectionState) _then;

/// Create a copy of ConnectionState
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? phase = null,Object? message = null,Object? cliVersion = freezed,}) {
  return _then(_ConnectionState(
phase: null == phase ? _self.phase : phase // ignore: cast_nullable_to_non_nullable
as ConnectionPhase,message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,cliVersion: freezed == cliVersion ? _self.cliVersion : cliVersion // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

/// @nodoc
mixin _$AgentConnectionKey {

 String get profileId; AgentKind get agent;
/// Create a copy of AgentConnectionKey
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AgentConnectionKeyCopyWith<AgentConnectionKey> get copyWith => _$AgentConnectionKeyCopyWithImpl<AgentConnectionKey>(this as AgentConnectionKey, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AgentConnectionKey&&(identical(other.profileId, profileId) || other.profileId == profileId)&&(identical(other.agent, agent) || other.agent == agent));
}


@override
int get hashCode => Object.hash(runtimeType,profileId,agent);

@override
String toString() {
  return 'AgentConnectionKey(profileId: $profileId, agent: $agent)';
}


}

/// @nodoc
abstract mixin class $AgentConnectionKeyCopyWith<$Res>  {
  factory $AgentConnectionKeyCopyWith(AgentConnectionKey value, $Res Function(AgentConnectionKey) _then) = _$AgentConnectionKeyCopyWithImpl;
@useResult
$Res call({
 String profileId, AgentKind agent
});




}
/// @nodoc
class _$AgentConnectionKeyCopyWithImpl<$Res>
    implements $AgentConnectionKeyCopyWith<$Res> {
  _$AgentConnectionKeyCopyWithImpl(this._self, this._then);

  final AgentConnectionKey _self;
  final $Res Function(AgentConnectionKey) _then;

/// Create a copy of AgentConnectionKey
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? profileId = null,Object? agent = null,}) {
  return _then(_self.copyWith(
profileId: null == profileId ? _self.profileId : profileId // ignore: cast_nullable_to_non_nullable
as String,agent: null == agent ? _self.agent : agent // ignore: cast_nullable_to_non_nullable
as AgentKind,
  ));
}

}


/// Adds pattern-matching-related methods to [AgentConnectionKey].
extension AgentConnectionKeyPatterns on AgentConnectionKey {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _AgentConnectionKey value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _AgentConnectionKey() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _AgentConnectionKey value)  $default,){
final _that = this;
switch (_that) {
case _AgentConnectionKey():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _AgentConnectionKey value)?  $default,){
final _that = this;
switch (_that) {
case _AgentConnectionKey() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String profileId,  AgentKind agent)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _AgentConnectionKey() when $default != null:
return $default(_that.profileId,_that.agent);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String profileId,  AgentKind agent)  $default,) {final _that = this;
switch (_that) {
case _AgentConnectionKey():
return $default(_that.profileId,_that.agent);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String profileId,  AgentKind agent)?  $default,) {final _that = this;
switch (_that) {
case _AgentConnectionKey() when $default != null:
return $default(_that.profileId,_that.agent);case _:
  return null;

}
}

}

/// @nodoc


class _AgentConnectionKey implements AgentConnectionKey {
  const _AgentConnectionKey({required this.profileId, required this.agent});
  

@override final  String profileId;
@override final  AgentKind agent;

/// Create a copy of AgentConnectionKey
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$AgentConnectionKeyCopyWith<_AgentConnectionKey> get copyWith => __$AgentConnectionKeyCopyWithImpl<_AgentConnectionKey>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _AgentConnectionKey&&(identical(other.profileId, profileId) || other.profileId == profileId)&&(identical(other.agent, agent) || other.agent == agent));
}


@override
int get hashCode => Object.hash(runtimeType,profileId,agent);

@override
String toString() {
  return 'AgentConnectionKey(profileId: $profileId, agent: $agent)';
}


}

/// @nodoc
abstract mixin class _$AgentConnectionKeyCopyWith<$Res> implements $AgentConnectionKeyCopyWith<$Res> {
  factory _$AgentConnectionKeyCopyWith(_AgentConnectionKey value, $Res Function(_AgentConnectionKey) _then) = __$AgentConnectionKeyCopyWithImpl;
@override @useResult
$Res call({
 String profileId, AgentKind agent
});




}
/// @nodoc
class __$AgentConnectionKeyCopyWithImpl<$Res>
    implements _$AgentConnectionKeyCopyWith<$Res> {
  __$AgentConnectionKeyCopyWithImpl(this._self, this._then);

  final _AgentConnectionKey _self;
  final $Res Function(_AgentConnectionKey) _then;

/// Create a copy of AgentConnectionKey
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? profileId = null,Object? agent = null,}) {
  return _then(_AgentConnectionKey(
profileId: null == profileId ? _self.profileId : profileId // ignore: cast_nullable_to_non_nullable
as String,agent: null == agent ? _self.agent : agent // ignore: cast_nullable_to_non_nullable
as AgentKind,
  ));
}


}

/// @nodoc
mixin _$AgentCapabilities {

 bool get models; List<ModelApiProtocol> get modelApiProtocols; bool get reasoningEffort; bool get approvals; bool get archiveThread; bool get renameThread; bool get interruptTurn; bool get steerTurn; bool get rollbackThread; bool get reviewChanges; bool get compactThread; bool get threadGoals; bool get subAgents; bool get globalSettings;
/// Create a copy of AgentCapabilities
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AgentCapabilitiesCopyWith<AgentCapabilities> get copyWith => _$AgentCapabilitiesCopyWithImpl<AgentCapabilities>(this as AgentCapabilities, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AgentCapabilities&&(identical(other.models, models) || other.models == models)&&const DeepCollectionEquality().equals(other.modelApiProtocols, modelApiProtocols)&&(identical(other.reasoningEffort, reasoningEffort) || other.reasoningEffort == reasoningEffort)&&(identical(other.approvals, approvals) || other.approvals == approvals)&&(identical(other.archiveThread, archiveThread) || other.archiveThread == archiveThread)&&(identical(other.renameThread, renameThread) || other.renameThread == renameThread)&&(identical(other.interruptTurn, interruptTurn) || other.interruptTurn == interruptTurn)&&(identical(other.steerTurn, steerTurn) || other.steerTurn == steerTurn)&&(identical(other.rollbackThread, rollbackThread) || other.rollbackThread == rollbackThread)&&(identical(other.reviewChanges, reviewChanges) || other.reviewChanges == reviewChanges)&&(identical(other.compactThread, compactThread) || other.compactThread == compactThread)&&(identical(other.threadGoals, threadGoals) || other.threadGoals == threadGoals)&&(identical(other.subAgents, subAgents) || other.subAgents == subAgents)&&(identical(other.globalSettings, globalSettings) || other.globalSettings == globalSettings));
}


@override
int get hashCode => Object.hash(runtimeType,models,const DeepCollectionEquality().hash(modelApiProtocols),reasoningEffort,approvals,archiveThread,renameThread,interruptTurn,steerTurn,rollbackThread,reviewChanges,compactThread,threadGoals,subAgents,globalSettings);

@override
String toString() {
  return 'AgentCapabilities(models: $models, modelApiProtocols: $modelApiProtocols, reasoningEffort: $reasoningEffort, approvals: $approvals, archiveThread: $archiveThread, renameThread: $renameThread, interruptTurn: $interruptTurn, steerTurn: $steerTurn, rollbackThread: $rollbackThread, reviewChanges: $reviewChanges, compactThread: $compactThread, threadGoals: $threadGoals, subAgents: $subAgents, globalSettings: $globalSettings)';
}


}

/// @nodoc
abstract mixin class $AgentCapabilitiesCopyWith<$Res>  {
  factory $AgentCapabilitiesCopyWith(AgentCapabilities value, $Res Function(AgentCapabilities) _then) = _$AgentCapabilitiesCopyWithImpl;
@useResult
$Res call({
 bool models, List<ModelApiProtocol> modelApiProtocols, bool reasoningEffort, bool approvals, bool archiveThread, bool renameThread, bool interruptTurn, bool steerTurn, bool rollbackThread, bool reviewChanges, bool compactThread, bool threadGoals, bool subAgents, bool globalSettings
});




}
/// @nodoc
class _$AgentCapabilitiesCopyWithImpl<$Res>
    implements $AgentCapabilitiesCopyWith<$Res> {
  _$AgentCapabilitiesCopyWithImpl(this._self, this._then);

  final AgentCapabilities _self;
  final $Res Function(AgentCapabilities) _then;

/// Create a copy of AgentCapabilities
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? models = null,Object? modelApiProtocols = null,Object? reasoningEffort = null,Object? approvals = null,Object? archiveThread = null,Object? renameThread = null,Object? interruptTurn = null,Object? steerTurn = null,Object? rollbackThread = null,Object? reviewChanges = null,Object? compactThread = null,Object? threadGoals = null,Object? subAgents = null,Object? globalSettings = null,}) {
  return _then(_self.copyWith(
models: null == models ? _self.models : models // ignore: cast_nullable_to_non_nullable
as bool,modelApiProtocols: null == modelApiProtocols ? _self.modelApiProtocols : modelApiProtocols // ignore: cast_nullable_to_non_nullable
as List<ModelApiProtocol>,reasoningEffort: null == reasoningEffort ? _self.reasoningEffort : reasoningEffort // ignore: cast_nullable_to_non_nullable
as bool,approvals: null == approvals ? _self.approvals : approvals // ignore: cast_nullable_to_non_nullable
as bool,archiveThread: null == archiveThread ? _self.archiveThread : archiveThread // ignore: cast_nullable_to_non_nullable
as bool,renameThread: null == renameThread ? _self.renameThread : renameThread // ignore: cast_nullable_to_non_nullable
as bool,interruptTurn: null == interruptTurn ? _self.interruptTurn : interruptTurn // ignore: cast_nullable_to_non_nullable
as bool,steerTurn: null == steerTurn ? _self.steerTurn : steerTurn // ignore: cast_nullable_to_non_nullable
as bool,rollbackThread: null == rollbackThread ? _self.rollbackThread : rollbackThread // ignore: cast_nullable_to_non_nullable
as bool,reviewChanges: null == reviewChanges ? _self.reviewChanges : reviewChanges // ignore: cast_nullable_to_non_nullable
as bool,compactThread: null == compactThread ? _self.compactThread : compactThread // ignore: cast_nullable_to_non_nullable
as bool,threadGoals: null == threadGoals ? _self.threadGoals : threadGoals // ignore: cast_nullable_to_non_nullable
as bool,subAgents: null == subAgents ? _self.subAgents : subAgents // ignore: cast_nullable_to_non_nullable
as bool,globalSettings: null == globalSettings ? _self.globalSettings : globalSettings // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}

}


/// Adds pattern-matching-related methods to [AgentCapabilities].
extension AgentCapabilitiesPatterns on AgentCapabilities {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _AgentCapabilities value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _AgentCapabilities() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _AgentCapabilities value)  $default,){
final _that = this;
switch (_that) {
case _AgentCapabilities():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _AgentCapabilities value)?  $default,){
final _that = this;
switch (_that) {
case _AgentCapabilities() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( bool models,  List<ModelApiProtocol> modelApiProtocols,  bool reasoningEffort,  bool approvals,  bool archiveThread,  bool renameThread,  bool interruptTurn,  bool steerTurn,  bool rollbackThread,  bool reviewChanges,  bool compactThread,  bool threadGoals,  bool subAgents,  bool globalSettings)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _AgentCapabilities() when $default != null:
return $default(_that.models,_that.modelApiProtocols,_that.reasoningEffort,_that.approvals,_that.archiveThread,_that.renameThread,_that.interruptTurn,_that.steerTurn,_that.rollbackThread,_that.reviewChanges,_that.compactThread,_that.threadGoals,_that.subAgents,_that.globalSettings);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( bool models,  List<ModelApiProtocol> modelApiProtocols,  bool reasoningEffort,  bool approvals,  bool archiveThread,  bool renameThread,  bool interruptTurn,  bool steerTurn,  bool rollbackThread,  bool reviewChanges,  bool compactThread,  bool threadGoals,  bool subAgents,  bool globalSettings)  $default,) {final _that = this;
switch (_that) {
case _AgentCapabilities():
return $default(_that.models,_that.modelApiProtocols,_that.reasoningEffort,_that.approvals,_that.archiveThread,_that.renameThread,_that.interruptTurn,_that.steerTurn,_that.rollbackThread,_that.reviewChanges,_that.compactThread,_that.threadGoals,_that.subAgents,_that.globalSettings);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( bool models,  List<ModelApiProtocol> modelApiProtocols,  bool reasoningEffort,  bool approvals,  bool archiveThread,  bool renameThread,  bool interruptTurn,  bool steerTurn,  bool rollbackThread,  bool reviewChanges,  bool compactThread,  bool threadGoals,  bool subAgents,  bool globalSettings)?  $default,) {final _that = this;
switch (_that) {
case _AgentCapabilities() when $default != null:
return $default(_that.models,_that.modelApiProtocols,_that.reasoningEffort,_that.approvals,_that.archiveThread,_that.renameThread,_that.interruptTurn,_that.steerTurn,_that.rollbackThread,_that.reviewChanges,_that.compactThread,_that.threadGoals,_that.subAgents,_that.globalSettings);case _:
  return null;

}
}

}

/// @nodoc


class _AgentCapabilities implements AgentCapabilities {
  const _AgentCapabilities({this.models = true, final  List<ModelApiProtocol> modelApiProtocols = const <ModelApiProtocol>[], this.reasoningEffort = false, this.approvals = false, this.archiveThread = true, this.renameThread = true, this.interruptTurn = true, this.steerTurn = false, this.rollbackThread = false, this.reviewChanges = false, this.compactThread = false, this.threadGoals = false, this.subAgents = false, this.globalSettings = false}): _modelApiProtocols = modelApiProtocols;
  

@override@JsonKey() final  bool models;
 final  List<ModelApiProtocol> _modelApiProtocols;
@override@JsonKey() List<ModelApiProtocol> get modelApiProtocols {
  if (_modelApiProtocols is EqualUnmodifiableListView) return _modelApiProtocols;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_modelApiProtocols);
}

@override@JsonKey() final  bool reasoningEffort;
@override@JsonKey() final  bool approvals;
@override@JsonKey() final  bool archiveThread;
@override@JsonKey() final  bool renameThread;
@override@JsonKey() final  bool interruptTurn;
@override@JsonKey() final  bool steerTurn;
@override@JsonKey() final  bool rollbackThread;
@override@JsonKey() final  bool reviewChanges;
@override@JsonKey() final  bool compactThread;
@override@JsonKey() final  bool threadGoals;
@override@JsonKey() final  bool subAgents;
@override@JsonKey() final  bool globalSettings;

/// Create a copy of AgentCapabilities
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$AgentCapabilitiesCopyWith<_AgentCapabilities> get copyWith => __$AgentCapabilitiesCopyWithImpl<_AgentCapabilities>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _AgentCapabilities&&(identical(other.models, models) || other.models == models)&&const DeepCollectionEquality().equals(other._modelApiProtocols, _modelApiProtocols)&&(identical(other.reasoningEffort, reasoningEffort) || other.reasoningEffort == reasoningEffort)&&(identical(other.approvals, approvals) || other.approvals == approvals)&&(identical(other.archiveThread, archiveThread) || other.archiveThread == archiveThread)&&(identical(other.renameThread, renameThread) || other.renameThread == renameThread)&&(identical(other.interruptTurn, interruptTurn) || other.interruptTurn == interruptTurn)&&(identical(other.steerTurn, steerTurn) || other.steerTurn == steerTurn)&&(identical(other.rollbackThread, rollbackThread) || other.rollbackThread == rollbackThread)&&(identical(other.reviewChanges, reviewChanges) || other.reviewChanges == reviewChanges)&&(identical(other.compactThread, compactThread) || other.compactThread == compactThread)&&(identical(other.threadGoals, threadGoals) || other.threadGoals == threadGoals)&&(identical(other.subAgents, subAgents) || other.subAgents == subAgents)&&(identical(other.globalSettings, globalSettings) || other.globalSettings == globalSettings));
}


@override
int get hashCode => Object.hash(runtimeType,models,const DeepCollectionEquality().hash(_modelApiProtocols),reasoningEffort,approvals,archiveThread,renameThread,interruptTurn,steerTurn,rollbackThread,reviewChanges,compactThread,threadGoals,subAgents,globalSettings);

@override
String toString() {
  return 'AgentCapabilities(models: $models, modelApiProtocols: $modelApiProtocols, reasoningEffort: $reasoningEffort, approvals: $approvals, archiveThread: $archiveThread, renameThread: $renameThread, interruptTurn: $interruptTurn, steerTurn: $steerTurn, rollbackThread: $rollbackThread, reviewChanges: $reviewChanges, compactThread: $compactThread, threadGoals: $threadGoals, subAgents: $subAgents, globalSettings: $globalSettings)';
}


}

/// @nodoc
abstract mixin class _$AgentCapabilitiesCopyWith<$Res> implements $AgentCapabilitiesCopyWith<$Res> {
  factory _$AgentCapabilitiesCopyWith(_AgentCapabilities value, $Res Function(_AgentCapabilities) _then) = __$AgentCapabilitiesCopyWithImpl;
@override @useResult
$Res call({
 bool models, List<ModelApiProtocol> modelApiProtocols, bool reasoningEffort, bool approvals, bool archiveThread, bool renameThread, bool interruptTurn, bool steerTurn, bool rollbackThread, bool reviewChanges, bool compactThread, bool threadGoals, bool subAgents, bool globalSettings
});




}
/// @nodoc
class __$AgentCapabilitiesCopyWithImpl<$Res>
    implements _$AgentCapabilitiesCopyWith<$Res> {
  __$AgentCapabilitiesCopyWithImpl(this._self, this._then);

  final _AgentCapabilities _self;
  final $Res Function(_AgentCapabilities) _then;

/// Create a copy of AgentCapabilities
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? models = null,Object? modelApiProtocols = null,Object? reasoningEffort = null,Object? approvals = null,Object? archiveThread = null,Object? renameThread = null,Object? interruptTurn = null,Object? steerTurn = null,Object? rollbackThread = null,Object? reviewChanges = null,Object? compactThread = null,Object? threadGoals = null,Object? subAgents = null,Object? globalSettings = null,}) {
  return _then(_AgentCapabilities(
models: null == models ? _self.models : models // ignore: cast_nullable_to_non_nullable
as bool,modelApiProtocols: null == modelApiProtocols ? _self._modelApiProtocols : modelApiProtocols // ignore: cast_nullable_to_non_nullable
as List<ModelApiProtocol>,reasoningEffort: null == reasoningEffort ? _self.reasoningEffort : reasoningEffort // ignore: cast_nullable_to_non_nullable
as bool,approvals: null == approvals ? _self.approvals : approvals // ignore: cast_nullable_to_non_nullable
as bool,archiveThread: null == archiveThread ? _self.archiveThread : archiveThread // ignore: cast_nullable_to_non_nullable
as bool,renameThread: null == renameThread ? _self.renameThread : renameThread // ignore: cast_nullable_to_non_nullable
as bool,interruptTurn: null == interruptTurn ? _self.interruptTurn : interruptTurn // ignore: cast_nullable_to_non_nullable
as bool,steerTurn: null == steerTurn ? _self.steerTurn : steerTurn // ignore: cast_nullable_to_non_nullable
as bool,rollbackThread: null == rollbackThread ? _self.rollbackThread : rollbackThread // ignore: cast_nullable_to_non_nullable
as bool,reviewChanges: null == reviewChanges ? _self.reviewChanges : reviewChanges // ignore: cast_nullable_to_non_nullable
as bool,compactThread: null == compactThread ? _self.compactThread : compactThread // ignore: cast_nullable_to_non_nullable
as bool,threadGoals: null == threadGoals ? _self.threadGoals : threadGoals // ignore: cast_nullable_to_non_nullable
as bool,subAgents: null == subAgents ? _self.subAgents : subAgents // ignore: cast_nullable_to_non_nullable
as bool,globalSettings: null == globalSettings ? _self.globalSettings : globalSettings // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

/// @nodoc
mixin _$ServerMetrics {

 int? get cpuPercent; int? get cpuCoreCount; int? get memoryPercent; int? get memoryTotalKiB; int? get memoryUsedKiB; int? get diskPercent; int? get diskTotalKiB; int? get diskUsedKiB; int? get networkDownloadBytesPerSecond; int? get networkUploadBytesPerSecond; int get sampledAtEpochMillis; String? get error;
/// Create a copy of ServerMetrics
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ServerMetricsCopyWith<ServerMetrics> get copyWith => _$ServerMetricsCopyWithImpl<ServerMetrics>(this as ServerMetrics, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ServerMetrics&&(identical(other.cpuPercent, cpuPercent) || other.cpuPercent == cpuPercent)&&(identical(other.cpuCoreCount, cpuCoreCount) || other.cpuCoreCount == cpuCoreCount)&&(identical(other.memoryPercent, memoryPercent) || other.memoryPercent == memoryPercent)&&(identical(other.memoryTotalKiB, memoryTotalKiB) || other.memoryTotalKiB == memoryTotalKiB)&&(identical(other.memoryUsedKiB, memoryUsedKiB) || other.memoryUsedKiB == memoryUsedKiB)&&(identical(other.diskPercent, diskPercent) || other.diskPercent == diskPercent)&&(identical(other.diskTotalKiB, diskTotalKiB) || other.diskTotalKiB == diskTotalKiB)&&(identical(other.diskUsedKiB, diskUsedKiB) || other.diskUsedKiB == diskUsedKiB)&&(identical(other.networkDownloadBytesPerSecond, networkDownloadBytesPerSecond) || other.networkDownloadBytesPerSecond == networkDownloadBytesPerSecond)&&(identical(other.networkUploadBytesPerSecond, networkUploadBytesPerSecond) || other.networkUploadBytesPerSecond == networkUploadBytesPerSecond)&&(identical(other.sampledAtEpochMillis, sampledAtEpochMillis) || other.sampledAtEpochMillis == sampledAtEpochMillis)&&(identical(other.error, error) || other.error == error));
}


@override
int get hashCode => Object.hash(runtimeType,cpuPercent,cpuCoreCount,memoryPercent,memoryTotalKiB,memoryUsedKiB,diskPercent,diskTotalKiB,diskUsedKiB,networkDownloadBytesPerSecond,networkUploadBytesPerSecond,sampledAtEpochMillis,error);

@override
String toString() {
  return 'ServerMetrics(cpuPercent: $cpuPercent, cpuCoreCount: $cpuCoreCount, memoryPercent: $memoryPercent, memoryTotalKiB: $memoryTotalKiB, memoryUsedKiB: $memoryUsedKiB, diskPercent: $diskPercent, diskTotalKiB: $diskTotalKiB, diskUsedKiB: $diskUsedKiB, networkDownloadBytesPerSecond: $networkDownloadBytesPerSecond, networkUploadBytesPerSecond: $networkUploadBytesPerSecond, sampledAtEpochMillis: $sampledAtEpochMillis, error: $error)';
}


}

/// @nodoc
abstract mixin class $ServerMetricsCopyWith<$Res>  {
  factory $ServerMetricsCopyWith(ServerMetrics value, $Res Function(ServerMetrics) _then) = _$ServerMetricsCopyWithImpl;
@useResult
$Res call({
 int? cpuPercent, int? cpuCoreCount, int? memoryPercent, int? memoryTotalKiB, int? memoryUsedKiB, int? diskPercent, int? diskTotalKiB, int? diskUsedKiB, int? networkDownloadBytesPerSecond, int? networkUploadBytesPerSecond, int sampledAtEpochMillis, String? error
});




}
/// @nodoc
class _$ServerMetricsCopyWithImpl<$Res>
    implements $ServerMetricsCopyWith<$Res> {
  _$ServerMetricsCopyWithImpl(this._self, this._then);

  final ServerMetrics _self;
  final $Res Function(ServerMetrics) _then;

/// Create a copy of ServerMetrics
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? cpuPercent = freezed,Object? cpuCoreCount = freezed,Object? memoryPercent = freezed,Object? memoryTotalKiB = freezed,Object? memoryUsedKiB = freezed,Object? diskPercent = freezed,Object? diskTotalKiB = freezed,Object? diskUsedKiB = freezed,Object? networkDownloadBytesPerSecond = freezed,Object? networkUploadBytesPerSecond = freezed,Object? sampledAtEpochMillis = null,Object? error = freezed,}) {
  return _then(_self.copyWith(
cpuPercent: freezed == cpuPercent ? _self.cpuPercent : cpuPercent // ignore: cast_nullable_to_non_nullable
as int?,cpuCoreCount: freezed == cpuCoreCount ? _self.cpuCoreCount : cpuCoreCount // ignore: cast_nullable_to_non_nullable
as int?,memoryPercent: freezed == memoryPercent ? _self.memoryPercent : memoryPercent // ignore: cast_nullable_to_non_nullable
as int?,memoryTotalKiB: freezed == memoryTotalKiB ? _self.memoryTotalKiB : memoryTotalKiB // ignore: cast_nullable_to_non_nullable
as int?,memoryUsedKiB: freezed == memoryUsedKiB ? _self.memoryUsedKiB : memoryUsedKiB // ignore: cast_nullable_to_non_nullable
as int?,diskPercent: freezed == diskPercent ? _self.diskPercent : diskPercent // ignore: cast_nullable_to_non_nullable
as int?,diskTotalKiB: freezed == diskTotalKiB ? _self.diskTotalKiB : diskTotalKiB // ignore: cast_nullable_to_non_nullable
as int?,diskUsedKiB: freezed == diskUsedKiB ? _self.diskUsedKiB : diskUsedKiB // ignore: cast_nullable_to_non_nullable
as int?,networkDownloadBytesPerSecond: freezed == networkDownloadBytesPerSecond ? _self.networkDownloadBytesPerSecond : networkDownloadBytesPerSecond // ignore: cast_nullable_to_non_nullable
as int?,networkUploadBytesPerSecond: freezed == networkUploadBytesPerSecond ? _self.networkUploadBytesPerSecond : networkUploadBytesPerSecond // ignore: cast_nullable_to_non_nullable
as int?,sampledAtEpochMillis: null == sampledAtEpochMillis ? _self.sampledAtEpochMillis : sampledAtEpochMillis // ignore: cast_nullable_to_non_nullable
as int,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// Adds pattern-matching-related methods to [ServerMetrics].
extension ServerMetricsPatterns on ServerMetrics {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ServerMetrics value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ServerMetrics() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ServerMetrics value)  $default,){
final _that = this;
switch (_that) {
case _ServerMetrics():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ServerMetrics value)?  $default,){
final _that = this;
switch (_that) {
case _ServerMetrics() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( int? cpuPercent,  int? cpuCoreCount,  int? memoryPercent,  int? memoryTotalKiB,  int? memoryUsedKiB,  int? diskPercent,  int? diskTotalKiB,  int? diskUsedKiB,  int? networkDownloadBytesPerSecond,  int? networkUploadBytesPerSecond,  int sampledAtEpochMillis,  String? error)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ServerMetrics() when $default != null:
return $default(_that.cpuPercent,_that.cpuCoreCount,_that.memoryPercent,_that.memoryTotalKiB,_that.memoryUsedKiB,_that.diskPercent,_that.diskTotalKiB,_that.diskUsedKiB,_that.networkDownloadBytesPerSecond,_that.networkUploadBytesPerSecond,_that.sampledAtEpochMillis,_that.error);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( int? cpuPercent,  int? cpuCoreCount,  int? memoryPercent,  int? memoryTotalKiB,  int? memoryUsedKiB,  int? diskPercent,  int? diskTotalKiB,  int? diskUsedKiB,  int? networkDownloadBytesPerSecond,  int? networkUploadBytesPerSecond,  int sampledAtEpochMillis,  String? error)  $default,) {final _that = this;
switch (_that) {
case _ServerMetrics():
return $default(_that.cpuPercent,_that.cpuCoreCount,_that.memoryPercent,_that.memoryTotalKiB,_that.memoryUsedKiB,_that.diskPercent,_that.diskTotalKiB,_that.diskUsedKiB,_that.networkDownloadBytesPerSecond,_that.networkUploadBytesPerSecond,_that.sampledAtEpochMillis,_that.error);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( int? cpuPercent,  int? cpuCoreCount,  int? memoryPercent,  int? memoryTotalKiB,  int? memoryUsedKiB,  int? diskPercent,  int? diskTotalKiB,  int? diskUsedKiB,  int? networkDownloadBytesPerSecond,  int? networkUploadBytesPerSecond,  int sampledAtEpochMillis,  String? error)?  $default,) {final _that = this;
switch (_that) {
case _ServerMetrics() when $default != null:
return $default(_that.cpuPercent,_that.cpuCoreCount,_that.memoryPercent,_that.memoryTotalKiB,_that.memoryUsedKiB,_that.diskPercent,_that.diskTotalKiB,_that.diskUsedKiB,_that.networkDownloadBytesPerSecond,_that.networkUploadBytesPerSecond,_that.sampledAtEpochMillis,_that.error);case _:
  return null;

}
}

}

/// @nodoc


class _ServerMetrics implements ServerMetrics {
  const _ServerMetrics({this.cpuPercent, this.cpuCoreCount, this.memoryPercent, this.memoryTotalKiB, this.memoryUsedKiB, this.diskPercent, this.diskTotalKiB, this.diskUsedKiB, this.networkDownloadBytesPerSecond, this.networkUploadBytesPerSecond, this.sampledAtEpochMillis = 0, this.error});
  

@override final  int? cpuPercent;
@override final  int? cpuCoreCount;
@override final  int? memoryPercent;
@override final  int? memoryTotalKiB;
@override final  int? memoryUsedKiB;
@override final  int? diskPercent;
@override final  int? diskTotalKiB;
@override final  int? diskUsedKiB;
@override final  int? networkDownloadBytesPerSecond;
@override final  int? networkUploadBytesPerSecond;
@override@JsonKey() final  int sampledAtEpochMillis;
@override final  String? error;

/// Create a copy of ServerMetrics
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ServerMetricsCopyWith<_ServerMetrics> get copyWith => __$ServerMetricsCopyWithImpl<_ServerMetrics>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ServerMetrics&&(identical(other.cpuPercent, cpuPercent) || other.cpuPercent == cpuPercent)&&(identical(other.cpuCoreCount, cpuCoreCount) || other.cpuCoreCount == cpuCoreCount)&&(identical(other.memoryPercent, memoryPercent) || other.memoryPercent == memoryPercent)&&(identical(other.memoryTotalKiB, memoryTotalKiB) || other.memoryTotalKiB == memoryTotalKiB)&&(identical(other.memoryUsedKiB, memoryUsedKiB) || other.memoryUsedKiB == memoryUsedKiB)&&(identical(other.diskPercent, diskPercent) || other.diskPercent == diskPercent)&&(identical(other.diskTotalKiB, diskTotalKiB) || other.diskTotalKiB == diskTotalKiB)&&(identical(other.diskUsedKiB, diskUsedKiB) || other.diskUsedKiB == diskUsedKiB)&&(identical(other.networkDownloadBytesPerSecond, networkDownloadBytesPerSecond) || other.networkDownloadBytesPerSecond == networkDownloadBytesPerSecond)&&(identical(other.networkUploadBytesPerSecond, networkUploadBytesPerSecond) || other.networkUploadBytesPerSecond == networkUploadBytesPerSecond)&&(identical(other.sampledAtEpochMillis, sampledAtEpochMillis) || other.sampledAtEpochMillis == sampledAtEpochMillis)&&(identical(other.error, error) || other.error == error));
}


@override
int get hashCode => Object.hash(runtimeType,cpuPercent,cpuCoreCount,memoryPercent,memoryTotalKiB,memoryUsedKiB,diskPercent,diskTotalKiB,diskUsedKiB,networkDownloadBytesPerSecond,networkUploadBytesPerSecond,sampledAtEpochMillis,error);

@override
String toString() {
  return 'ServerMetrics(cpuPercent: $cpuPercent, cpuCoreCount: $cpuCoreCount, memoryPercent: $memoryPercent, memoryTotalKiB: $memoryTotalKiB, memoryUsedKiB: $memoryUsedKiB, diskPercent: $diskPercent, diskTotalKiB: $diskTotalKiB, diskUsedKiB: $diskUsedKiB, networkDownloadBytesPerSecond: $networkDownloadBytesPerSecond, networkUploadBytesPerSecond: $networkUploadBytesPerSecond, sampledAtEpochMillis: $sampledAtEpochMillis, error: $error)';
}


}

/// @nodoc
abstract mixin class _$ServerMetricsCopyWith<$Res> implements $ServerMetricsCopyWith<$Res> {
  factory _$ServerMetricsCopyWith(_ServerMetrics value, $Res Function(_ServerMetrics) _then) = __$ServerMetricsCopyWithImpl;
@override @useResult
$Res call({
 int? cpuPercent, int? cpuCoreCount, int? memoryPercent, int? memoryTotalKiB, int? memoryUsedKiB, int? diskPercent, int? diskTotalKiB, int? diskUsedKiB, int? networkDownloadBytesPerSecond, int? networkUploadBytesPerSecond, int sampledAtEpochMillis, String? error
});




}
/// @nodoc
class __$ServerMetricsCopyWithImpl<$Res>
    implements _$ServerMetricsCopyWith<$Res> {
  __$ServerMetricsCopyWithImpl(this._self, this._then);

  final _ServerMetrics _self;
  final $Res Function(_ServerMetrics) _then;

/// Create a copy of ServerMetrics
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? cpuPercent = freezed,Object? cpuCoreCount = freezed,Object? memoryPercent = freezed,Object? memoryTotalKiB = freezed,Object? memoryUsedKiB = freezed,Object? diskPercent = freezed,Object? diskTotalKiB = freezed,Object? diskUsedKiB = freezed,Object? networkDownloadBytesPerSecond = freezed,Object? networkUploadBytesPerSecond = freezed,Object? sampledAtEpochMillis = null,Object? error = freezed,}) {
  return _then(_ServerMetrics(
cpuPercent: freezed == cpuPercent ? _self.cpuPercent : cpuPercent // ignore: cast_nullable_to_non_nullable
as int?,cpuCoreCount: freezed == cpuCoreCount ? _self.cpuCoreCount : cpuCoreCount // ignore: cast_nullable_to_non_nullable
as int?,memoryPercent: freezed == memoryPercent ? _self.memoryPercent : memoryPercent // ignore: cast_nullable_to_non_nullable
as int?,memoryTotalKiB: freezed == memoryTotalKiB ? _self.memoryTotalKiB : memoryTotalKiB // ignore: cast_nullable_to_non_nullable
as int?,memoryUsedKiB: freezed == memoryUsedKiB ? _self.memoryUsedKiB : memoryUsedKiB // ignore: cast_nullable_to_non_nullable
as int?,diskPercent: freezed == diskPercent ? _self.diskPercent : diskPercent // ignore: cast_nullable_to_non_nullable
as int?,diskTotalKiB: freezed == diskTotalKiB ? _self.diskTotalKiB : diskTotalKiB // ignore: cast_nullable_to_non_nullable
as int?,diskUsedKiB: freezed == diskUsedKiB ? _self.diskUsedKiB : diskUsedKiB // ignore: cast_nullable_to_non_nullable
as int?,networkDownloadBytesPerSecond: freezed == networkDownloadBytesPerSecond ? _self.networkDownloadBytesPerSecond : networkDownloadBytesPerSecond // ignore: cast_nullable_to_non_nullable
as int?,networkUploadBytesPerSecond: freezed == networkUploadBytesPerSecond ? _self.networkUploadBytesPerSecond : networkUploadBytesPerSecond // ignore: cast_nullable_to_non_nullable
as int?,sampledAtEpochMillis: null == sampledAtEpochMillis ? _self.sampledAtEpochMillis : sampledAtEpochMillis // ignore: cast_nullable_to_non_nullable
as int,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

/// @nodoc
mixin _$ApiModelOption {

 String get modelId; String get displayName; int get contextWindowTokens; int get maxOutputTokens;
/// Create a copy of ApiModelOption
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ApiModelOptionCopyWith<ApiModelOption> get copyWith => _$ApiModelOptionCopyWithImpl<ApiModelOption>(this as ApiModelOption, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ApiModelOption&&(identical(other.modelId, modelId) || other.modelId == modelId)&&(identical(other.displayName, displayName) || other.displayName == displayName)&&(identical(other.contextWindowTokens, contextWindowTokens) || other.contextWindowTokens == contextWindowTokens)&&(identical(other.maxOutputTokens, maxOutputTokens) || other.maxOutputTokens == maxOutputTokens));
}


@override
int get hashCode => Object.hash(runtimeType,modelId,displayName,contextWindowTokens,maxOutputTokens);

@override
String toString() {
  return 'ApiModelOption(modelId: $modelId, displayName: $displayName, contextWindowTokens: $contextWindowTokens, maxOutputTokens: $maxOutputTokens)';
}


}

/// @nodoc
abstract mixin class $ApiModelOptionCopyWith<$Res>  {
  factory $ApiModelOptionCopyWith(ApiModelOption value, $Res Function(ApiModelOption) _then) = _$ApiModelOptionCopyWithImpl;
@useResult
$Res call({
 String modelId, String displayName, int contextWindowTokens, int maxOutputTokens
});




}
/// @nodoc
class _$ApiModelOptionCopyWithImpl<$Res>
    implements $ApiModelOptionCopyWith<$Res> {
  _$ApiModelOptionCopyWithImpl(this._self, this._then);

  final ApiModelOption _self;
  final $Res Function(ApiModelOption) _then;

/// Create a copy of ApiModelOption
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? modelId = null,Object? displayName = null,Object? contextWindowTokens = null,Object? maxOutputTokens = null,}) {
  return _then(_self.copyWith(
modelId: null == modelId ? _self.modelId : modelId // ignore: cast_nullable_to_non_nullable
as String,displayName: null == displayName ? _self.displayName : displayName // ignore: cast_nullable_to_non_nullable
as String,contextWindowTokens: null == contextWindowTokens ? _self.contextWindowTokens : contextWindowTokens // ignore: cast_nullable_to_non_nullable
as int,maxOutputTokens: null == maxOutputTokens ? _self.maxOutputTokens : maxOutputTokens // ignore: cast_nullable_to_non_nullable
as int,
  ));
}

}


/// Adds pattern-matching-related methods to [ApiModelOption].
extension ApiModelOptionPatterns on ApiModelOption {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ApiModelOption value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ApiModelOption() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ApiModelOption value)  $default,){
final _that = this;
switch (_that) {
case _ApiModelOption():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ApiModelOption value)?  $default,){
final _that = this;
switch (_that) {
case _ApiModelOption() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String modelId,  String displayName,  int contextWindowTokens,  int maxOutputTokens)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ApiModelOption() when $default != null:
return $default(_that.modelId,_that.displayName,_that.contextWindowTokens,_that.maxOutputTokens);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String modelId,  String displayName,  int contextWindowTokens,  int maxOutputTokens)  $default,) {final _that = this;
switch (_that) {
case _ApiModelOption():
return $default(_that.modelId,_that.displayName,_that.contextWindowTokens,_that.maxOutputTokens);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String modelId,  String displayName,  int contextWindowTokens,  int maxOutputTokens)?  $default,) {final _that = this;
switch (_that) {
case _ApiModelOption() when $default != null:
return $default(_that.modelId,_that.displayName,_that.contextWindowTokens,_that.maxOutputTokens);case _:
  return null;

}
}

}

/// @nodoc


class _ApiModelOption implements ApiModelOption {
  const _ApiModelOption({required this.modelId, this.displayName = '', this.contextWindowTokens = 0, this.maxOutputTokens = 0});
  

@override final  String modelId;
@override@JsonKey() final  String displayName;
@override@JsonKey() final  int contextWindowTokens;
@override@JsonKey() final  int maxOutputTokens;

/// Create a copy of ApiModelOption
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ApiModelOptionCopyWith<_ApiModelOption> get copyWith => __$ApiModelOptionCopyWithImpl<_ApiModelOption>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ApiModelOption&&(identical(other.modelId, modelId) || other.modelId == modelId)&&(identical(other.displayName, displayName) || other.displayName == displayName)&&(identical(other.contextWindowTokens, contextWindowTokens) || other.contextWindowTokens == contextWindowTokens)&&(identical(other.maxOutputTokens, maxOutputTokens) || other.maxOutputTokens == maxOutputTokens));
}


@override
int get hashCode => Object.hash(runtimeType,modelId,displayName,contextWindowTokens,maxOutputTokens);

@override
String toString() {
  return 'ApiModelOption(modelId: $modelId, displayName: $displayName, contextWindowTokens: $contextWindowTokens, maxOutputTokens: $maxOutputTokens)';
}


}

/// @nodoc
abstract mixin class _$ApiModelOptionCopyWith<$Res> implements $ApiModelOptionCopyWith<$Res> {
  factory _$ApiModelOptionCopyWith(_ApiModelOption value, $Res Function(_ApiModelOption) _then) = __$ApiModelOptionCopyWithImpl;
@override @useResult
$Res call({
 String modelId, String displayName, int contextWindowTokens, int maxOutputTokens
});




}
/// @nodoc
class __$ApiModelOptionCopyWithImpl<$Res>
    implements _$ApiModelOptionCopyWith<$Res> {
  __$ApiModelOptionCopyWithImpl(this._self, this._then);

  final _ApiModelOption _self;
  final $Res Function(_ApiModelOption) _then;

/// Create a copy of ApiModelOption
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? modelId = null,Object? displayName = null,Object? contextWindowTokens = null,Object? maxOutputTokens = null,}) {
  return _then(_ApiModelOption(
modelId: null == modelId ? _self.modelId : modelId // ignore: cast_nullable_to_non_nullable
as String,displayName: null == displayName ? _self.displayName : displayName // ignore: cast_nullable_to_non_nullable
as String,contextWindowTokens: null == contextWindowTokens ? _self.contextWindowTokens : contextWindowTokens // ignore: cast_nullable_to_non_nullable
as int,maxOutputTokens: null == maxOutputTokens ? _self.maxOutputTokens : maxOutputTokens // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc
mixin _$AgentThread {

 String get id; String get title; String get preview; String get cwd; String get source; String get status; int get createdAt; int get updatedAt; String get cliVersion; String? get activeTurnId;
/// Create a copy of AgentThread
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AgentThreadCopyWith<AgentThread> get copyWith => _$AgentThreadCopyWithImpl<AgentThread>(this as AgentThread, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AgentThread&&(identical(other.id, id) || other.id == id)&&(identical(other.title, title) || other.title == title)&&(identical(other.preview, preview) || other.preview == preview)&&(identical(other.cwd, cwd) || other.cwd == cwd)&&(identical(other.source, source) || other.source == source)&&(identical(other.status, status) || other.status == status)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt)&&(identical(other.updatedAt, updatedAt) || other.updatedAt == updatedAt)&&(identical(other.cliVersion, cliVersion) || other.cliVersion == cliVersion)&&(identical(other.activeTurnId, activeTurnId) || other.activeTurnId == activeTurnId));
}


@override
int get hashCode => Object.hash(runtimeType,id,title,preview,cwd,source,status,createdAt,updatedAt,cliVersion,activeTurnId);

@override
String toString() {
  return 'AgentThread(id: $id, title: $title, preview: $preview, cwd: $cwd, source: $source, status: $status, createdAt: $createdAt, updatedAt: $updatedAt, cliVersion: $cliVersion, activeTurnId: $activeTurnId)';
}


}

/// @nodoc
abstract mixin class $AgentThreadCopyWith<$Res>  {
  factory $AgentThreadCopyWith(AgentThread value, $Res Function(AgentThread) _then) = _$AgentThreadCopyWithImpl;
@useResult
$Res call({
 String id, String title, String preview, String cwd, String source, String status, int createdAt, int updatedAt, String cliVersion, String? activeTurnId
});




}
/// @nodoc
class _$AgentThreadCopyWithImpl<$Res>
    implements $AgentThreadCopyWith<$Res> {
  _$AgentThreadCopyWithImpl(this._self, this._then);

  final AgentThread _self;
  final $Res Function(AgentThread) _then;

/// Create a copy of AgentThread
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? title = null,Object? preview = null,Object? cwd = null,Object? source = null,Object? status = null,Object? createdAt = null,Object? updatedAt = null,Object? cliVersion = null,Object? activeTurnId = freezed,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,title: null == title ? _self.title : title // ignore: cast_nullable_to_non_nullable
as String,preview: null == preview ? _self.preview : preview // ignore: cast_nullable_to_non_nullable
as String,cwd: null == cwd ? _self.cwd : cwd // ignore: cast_nullable_to_non_nullable
as String,source: null == source ? _self.source : source // ignore: cast_nullable_to_non_nullable
as String,status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as String,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as int,updatedAt: null == updatedAt ? _self.updatedAt : updatedAt // ignore: cast_nullable_to_non_nullable
as int,cliVersion: null == cliVersion ? _self.cliVersion : cliVersion // ignore: cast_nullable_to_non_nullable
as String,activeTurnId: freezed == activeTurnId ? _self.activeTurnId : activeTurnId // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// Adds pattern-matching-related methods to [AgentThread].
extension AgentThreadPatterns on AgentThread {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _AgentThread value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _AgentThread() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _AgentThread value)  $default,){
final _that = this;
switch (_that) {
case _AgentThread():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _AgentThread value)?  $default,){
final _that = this;
switch (_that) {
case _AgentThread() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String title,  String preview,  String cwd,  String source,  String status,  int createdAt,  int updatedAt,  String cliVersion,  String? activeTurnId)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _AgentThread() when $default != null:
return $default(_that.id,_that.title,_that.preview,_that.cwd,_that.source,_that.status,_that.createdAt,_that.updatedAt,_that.cliVersion,_that.activeTurnId);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String title,  String preview,  String cwd,  String source,  String status,  int createdAt,  int updatedAt,  String cliVersion,  String? activeTurnId)  $default,) {final _that = this;
switch (_that) {
case _AgentThread():
return $default(_that.id,_that.title,_that.preview,_that.cwd,_that.source,_that.status,_that.createdAt,_that.updatedAt,_that.cliVersion,_that.activeTurnId);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String title,  String preview,  String cwd,  String source,  String status,  int createdAt,  int updatedAt,  String cliVersion,  String? activeTurnId)?  $default,) {final _that = this;
switch (_that) {
case _AgentThread() when $default != null:
return $default(_that.id,_that.title,_that.preview,_that.cwd,_that.source,_that.status,_that.createdAt,_that.updatedAt,_that.cliVersion,_that.activeTurnId);case _:
  return null;

}
}

}

/// @nodoc


class _AgentThread implements AgentThread {
  const _AgentThread({required this.id, this.title = '', this.preview = '', this.cwd = '', this.source = '', this.status = '', this.createdAt = 0, this.updatedAt = 0, this.cliVersion = '', this.activeTurnId});
  

@override final  String id;
@override@JsonKey() final  String title;
@override@JsonKey() final  String preview;
@override@JsonKey() final  String cwd;
@override@JsonKey() final  String source;
@override@JsonKey() final  String status;
@override@JsonKey() final  int createdAt;
@override@JsonKey() final  int updatedAt;
@override@JsonKey() final  String cliVersion;
@override final  String? activeTurnId;

/// Create a copy of AgentThread
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$AgentThreadCopyWith<_AgentThread> get copyWith => __$AgentThreadCopyWithImpl<_AgentThread>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _AgentThread&&(identical(other.id, id) || other.id == id)&&(identical(other.title, title) || other.title == title)&&(identical(other.preview, preview) || other.preview == preview)&&(identical(other.cwd, cwd) || other.cwd == cwd)&&(identical(other.source, source) || other.source == source)&&(identical(other.status, status) || other.status == status)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt)&&(identical(other.updatedAt, updatedAt) || other.updatedAt == updatedAt)&&(identical(other.cliVersion, cliVersion) || other.cliVersion == cliVersion)&&(identical(other.activeTurnId, activeTurnId) || other.activeTurnId == activeTurnId));
}


@override
int get hashCode => Object.hash(runtimeType,id,title,preview,cwd,source,status,createdAt,updatedAt,cliVersion,activeTurnId);

@override
String toString() {
  return 'AgentThread(id: $id, title: $title, preview: $preview, cwd: $cwd, source: $source, status: $status, createdAt: $createdAt, updatedAt: $updatedAt, cliVersion: $cliVersion, activeTurnId: $activeTurnId)';
}


}

/// @nodoc
abstract mixin class _$AgentThreadCopyWith<$Res> implements $AgentThreadCopyWith<$Res> {
  factory _$AgentThreadCopyWith(_AgentThread value, $Res Function(_AgentThread) _then) = __$AgentThreadCopyWithImpl;
@override @useResult
$Res call({
 String id, String title, String preview, String cwd, String source, String status, int createdAt, int updatedAt, String cliVersion, String? activeTurnId
});




}
/// @nodoc
class __$AgentThreadCopyWithImpl<$Res>
    implements _$AgentThreadCopyWith<$Res> {
  __$AgentThreadCopyWithImpl(this._self, this._then);

  final _AgentThread _self;
  final $Res Function(_AgentThread) _then;

/// Create a copy of AgentThread
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? title = null,Object? preview = null,Object? cwd = null,Object? source = null,Object? status = null,Object? createdAt = null,Object? updatedAt = null,Object? cliVersion = null,Object? activeTurnId = freezed,}) {
  return _then(_AgentThread(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,title: null == title ? _self.title : title // ignore: cast_nullable_to_non_nullable
as String,preview: null == preview ? _self.preview : preview // ignore: cast_nullable_to_non_nullable
as String,cwd: null == cwd ? _self.cwd : cwd // ignore: cast_nullable_to_non_nullable
as String,source: null == source ? _self.source : source // ignore: cast_nullable_to_non_nullable
as String,status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as String,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as int,updatedAt: null == updatedAt ? _self.updatedAt : updatedAt // ignore: cast_nullable_to_non_nullable
as int,cliVersion: null == cliVersion ? _self.cliVersion : cliVersion // ignore: cast_nullable_to_non_nullable
as String,activeTurnId: freezed == activeTurnId ? _self.activeTurnId : activeTurnId // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

/// @nodoc
mixin _$AgentModel {

 String get id; String get model; String get displayName; String get description; bool get isDefault; String get defaultEffort; List<String> get efforts; int get contextWindowTokens; int get maxOutputTokens; bool get isCustom; ModelApiProtocol? get apiProtocol;
/// Create a copy of AgentModel
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AgentModelCopyWith<AgentModel> get copyWith => _$AgentModelCopyWithImpl<AgentModel>(this as AgentModel, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AgentModel&&(identical(other.id, id) || other.id == id)&&(identical(other.model, model) || other.model == model)&&(identical(other.displayName, displayName) || other.displayName == displayName)&&(identical(other.description, description) || other.description == description)&&(identical(other.isDefault, isDefault) || other.isDefault == isDefault)&&(identical(other.defaultEffort, defaultEffort) || other.defaultEffort == defaultEffort)&&const DeepCollectionEquality().equals(other.efforts, efforts)&&(identical(other.contextWindowTokens, contextWindowTokens) || other.contextWindowTokens == contextWindowTokens)&&(identical(other.maxOutputTokens, maxOutputTokens) || other.maxOutputTokens == maxOutputTokens)&&(identical(other.isCustom, isCustom) || other.isCustom == isCustom)&&(identical(other.apiProtocol, apiProtocol) || other.apiProtocol == apiProtocol));
}


@override
int get hashCode => Object.hash(runtimeType,id,model,displayName,description,isDefault,defaultEffort,const DeepCollectionEquality().hash(efforts),contextWindowTokens,maxOutputTokens,isCustom,apiProtocol);

@override
String toString() {
  return 'AgentModel(id: $id, model: $model, displayName: $displayName, description: $description, isDefault: $isDefault, defaultEffort: $defaultEffort, efforts: $efforts, contextWindowTokens: $contextWindowTokens, maxOutputTokens: $maxOutputTokens, isCustom: $isCustom, apiProtocol: $apiProtocol)';
}


}

/// @nodoc
abstract mixin class $AgentModelCopyWith<$Res>  {
  factory $AgentModelCopyWith(AgentModel value, $Res Function(AgentModel) _then) = _$AgentModelCopyWithImpl;
@useResult
$Res call({
 String id, String model, String displayName, String description, bool isDefault, String defaultEffort, List<String> efforts, int contextWindowTokens, int maxOutputTokens, bool isCustom, ModelApiProtocol? apiProtocol
});




}
/// @nodoc
class _$AgentModelCopyWithImpl<$Res>
    implements $AgentModelCopyWith<$Res> {
  _$AgentModelCopyWithImpl(this._self, this._then);

  final AgentModel _self;
  final $Res Function(AgentModel) _then;

/// Create a copy of AgentModel
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? model = null,Object? displayName = null,Object? description = null,Object? isDefault = null,Object? defaultEffort = null,Object? efforts = null,Object? contextWindowTokens = null,Object? maxOutputTokens = null,Object? isCustom = null,Object? apiProtocol = freezed,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,model: null == model ? _self.model : model // ignore: cast_nullable_to_non_nullable
as String,displayName: null == displayName ? _self.displayName : displayName // ignore: cast_nullable_to_non_nullable
as String,description: null == description ? _self.description : description // ignore: cast_nullable_to_non_nullable
as String,isDefault: null == isDefault ? _self.isDefault : isDefault // ignore: cast_nullable_to_non_nullable
as bool,defaultEffort: null == defaultEffort ? _self.defaultEffort : defaultEffort // ignore: cast_nullable_to_non_nullable
as String,efforts: null == efforts ? _self.efforts : efforts // ignore: cast_nullable_to_non_nullable
as List<String>,contextWindowTokens: null == contextWindowTokens ? _self.contextWindowTokens : contextWindowTokens // ignore: cast_nullable_to_non_nullable
as int,maxOutputTokens: null == maxOutputTokens ? _self.maxOutputTokens : maxOutputTokens // ignore: cast_nullable_to_non_nullable
as int,isCustom: null == isCustom ? _self.isCustom : isCustom // ignore: cast_nullable_to_non_nullable
as bool,apiProtocol: freezed == apiProtocol ? _self.apiProtocol : apiProtocol // ignore: cast_nullable_to_non_nullable
as ModelApiProtocol?,
  ));
}

}


/// Adds pattern-matching-related methods to [AgentModel].
extension AgentModelPatterns on AgentModel {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _AgentModel value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _AgentModel() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _AgentModel value)  $default,){
final _that = this;
switch (_that) {
case _AgentModel():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _AgentModel value)?  $default,){
final _that = this;
switch (_that) {
case _AgentModel() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String model,  String displayName,  String description,  bool isDefault,  String defaultEffort,  List<String> efforts,  int contextWindowTokens,  int maxOutputTokens,  bool isCustom,  ModelApiProtocol? apiProtocol)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _AgentModel() when $default != null:
return $default(_that.id,_that.model,_that.displayName,_that.description,_that.isDefault,_that.defaultEffort,_that.efforts,_that.contextWindowTokens,_that.maxOutputTokens,_that.isCustom,_that.apiProtocol);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String model,  String displayName,  String description,  bool isDefault,  String defaultEffort,  List<String> efforts,  int contextWindowTokens,  int maxOutputTokens,  bool isCustom,  ModelApiProtocol? apiProtocol)  $default,) {final _that = this;
switch (_that) {
case _AgentModel():
return $default(_that.id,_that.model,_that.displayName,_that.description,_that.isDefault,_that.defaultEffort,_that.efforts,_that.contextWindowTokens,_that.maxOutputTokens,_that.isCustom,_that.apiProtocol);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String model,  String displayName,  String description,  bool isDefault,  String defaultEffort,  List<String> efforts,  int contextWindowTokens,  int maxOutputTokens,  bool isCustom,  ModelApiProtocol? apiProtocol)?  $default,) {final _that = this;
switch (_that) {
case _AgentModel() when $default != null:
return $default(_that.id,_that.model,_that.displayName,_that.description,_that.isDefault,_that.defaultEffort,_that.efforts,_that.contextWindowTokens,_that.maxOutputTokens,_that.isCustom,_that.apiProtocol);case _:
  return null;

}
}

}

/// @nodoc


class _AgentModel implements AgentModel {
  const _AgentModel({required this.id, this.model = '', this.displayName = '', this.description = '', this.isDefault = false, this.defaultEffort = '', final  List<String> efforts = const <String>[], this.contextWindowTokens = 0, this.maxOutputTokens = 0, this.isCustom = false, this.apiProtocol}): _efforts = efforts;
  

@override final  String id;
@override@JsonKey() final  String model;
@override@JsonKey() final  String displayName;
@override@JsonKey() final  String description;
@override@JsonKey() final  bool isDefault;
@override@JsonKey() final  String defaultEffort;
 final  List<String> _efforts;
@override@JsonKey() List<String> get efforts {
  if (_efforts is EqualUnmodifiableListView) return _efforts;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_efforts);
}

@override@JsonKey() final  int contextWindowTokens;
@override@JsonKey() final  int maxOutputTokens;
@override@JsonKey() final  bool isCustom;
@override final  ModelApiProtocol? apiProtocol;

/// Create a copy of AgentModel
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$AgentModelCopyWith<_AgentModel> get copyWith => __$AgentModelCopyWithImpl<_AgentModel>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _AgentModel&&(identical(other.id, id) || other.id == id)&&(identical(other.model, model) || other.model == model)&&(identical(other.displayName, displayName) || other.displayName == displayName)&&(identical(other.description, description) || other.description == description)&&(identical(other.isDefault, isDefault) || other.isDefault == isDefault)&&(identical(other.defaultEffort, defaultEffort) || other.defaultEffort == defaultEffort)&&const DeepCollectionEquality().equals(other._efforts, _efforts)&&(identical(other.contextWindowTokens, contextWindowTokens) || other.contextWindowTokens == contextWindowTokens)&&(identical(other.maxOutputTokens, maxOutputTokens) || other.maxOutputTokens == maxOutputTokens)&&(identical(other.isCustom, isCustom) || other.isCustom == isCustom)&&(identical(other.apiProtocol, apiProtocol) || other.apiProtocol == apiProtocol));
}


@override
int get hashCode => Object.hash(runtimeType,id,model,displayName,description,isDefault,defaultEffort,const DeepCollectionEquality().hash(_efforts),contextWindowTokens,maxOutputTokens,isCustom,apiProtocol);

@override
String toString() {
  return 'AgentModel(id: $id, model: $model, displayName: $displayName, description: $description, isDefault: $isDefault, defaultEffort: $defaultEffort, efforts: $efforts, contextWindowTokens: $contextWindowTokens, maxOutputTokens: $maxOutputTokens, isCustom: $isCustom, apiProtocol: $apiProtocol)';
}


}

/// @nodoc
abstract mixin class _$AgentModelCopyWith<$Res> implements $AgentModelCopyWith<$Res> {
  factory _$AgentModelCopyWith(_AgentModel value, $Res Function(_AgentModel) _then) = __$AgentModelCopyWithImpl;
@override @useResult
$Res call({
 String id, String model, String displayName, String description, bool isDefault, String defaultEffort, List<String> efforts, int contextWindowTokens, int maxOutputTokens, bool isCustom, ModelApiProtocol? apiProtocol
});




}
/// @nodoc
class __$AgentModelCopyWithImpl<$Res>
    implements _$AgentModelCopyWith<$Res> {
  __$AgentModelCopyWithImpl(this._self, this._then);

  final _AgentModel _self;
  final $Res Function(_AgentModel) _then;

/// Create a copy of AgentModel
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? model = null,Object? displayName = null,Object? description = null,Object? isDefault = null,Object? defaultEffort = null,Object? efforts = null,Object? contextWindowTokens = null,Object? maxOutputTokens = null,Object? isCustom = null,Object? apiProtocol = freezed,}) {
  return _then(_AgentModel(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,model: null == model ? _self.model : model // ignore: cast_nullable_to_non_nullable
as String,displayName: null == displayName ? _self.displayName : displayName // ignore: cast_nullable_to_non_nullable
as String,description: null == description ? _self.description : description // ignore: cast_nullable_to_non_nullable
as String,isDefault: null == isDefault ? _self.isDefault : isDefault // ignore: cast_nullable_to_non_nullable
as bool,defaultEffort: null == defaultEffort ? _self.defaultEffort : defaultEffort // ignore: cast_nullable_to_non_nullable
as String,efforts: null == efforts ? _self._efforts : efforts // ignore: cast_nullable_to_non_nullable
as List<String>,contextWindowTokens: null == contextWindowTokens ? _self.contextWindowTokens : contextWindowTokens // ignore: cast_nullable_to_non_nullable
as int,maxOutputTokens: null == maxOutputTokens ? _self.maxOutputTokens : maxOutputTokens // ignore: cast_nullable_to_non_nullable
as int,isCustom: null == isCustom ? _self.isCustom : isCustom // ignore: cast_nullable_to_non_nullable
as bool,apiProtocol: freezed == apiProtocol ? _self.apiProtocol : apiProtocol // ignore: cast_nullable_to_non_nullable
as ModelApiProtocol?,
  ));
}


}

/// @nodoc
mixin _$ThreadGoal {

 String get threadId; String get objective; ThreadGoalStatus get status; int get createdAt; int get updatedAt; int get timeUsedSeconds; int get tokensUsed; int? get tokenBudget;
/// Create a copy of ThreadGoal
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ThreadGoalCopyWith<ThreadGoal> get copyWith => _$ThreadGoalCopyWithImpl<ThreadGoal>(this as ThreadGoal, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ThreadGoal&&(identical(other.threadId, threadId) || other.threadId == threadId)&&(identical(other.objective, objective) || other.objective == objective)&&(identical(other.status, status) || other.status == status)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt)&&(identical(other.updatedAt, updatedAt) || other.updatedAt == updatedAt)&&(identical(other.timeUsedSeconds, timeUsedSeconds) || other.timeUsedSeconds == timeUsedSeconds)&&(identical(other.tokensUsed, tokensUsed) || other.tokensUsed == tokensUsed)&&(identical(other.tokenBudget, tokenBudget) || other.tokenBudget == tokenBudget));
}


@override
int get hashCode => Object.hash(runtimeType,threadId,objective,status,createdAt,updatedAt,timeUsedSeconds,tokensUsed,tokenBudget);

@override
String toString() {
  return 'ThreadGoal(threadId: $threadId, objective: $objective, status: $status, createdAt: $createdAt, updatedAt: $updatedAt, timeUsedSeconds: $timeUsedSeconds, tokensUsed: $tokensUsed, tokenBudget: $tokenBudget)';
}


}

/// @nodoc
abstract mixin class $ThreadGoalCopyWith<$Res>  {
  factory $ThreadGoalCopyWith(ThreadGoal value, $Res Function(ThreadGoal) _then) = _$ThreadGoalCopyWithImpl;
@useResult
$Res call({
 String threadId, String objective, ThreadGoalStatus status, int createdAt, int updatedAt, int timeUsedSeconds, int tokensUsed, int? tokenBudget
});




}
/// @nodoc
class _$ThreadGoalCopyWithImpl<$Res>
    implements $ThreadGoalCopyWith<$Res> {
  _$ThreadGoalCopyWithImpl(this._self, this._then);

  final ThreadGoal _self;
  final $Res Function(ThreadGoal) _then;

/// Create a copy of ThreadGoal
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? threadId = null,Object? objective = null,Object? status = null,Object? createdAt = null,Object? updatedAt = null,Object? timeUsedSeconds = null,Object? tokensUsed = null,Object? tokenBudget = freezed,}) {
  return _then(_self.copyWith(
threadId: null == threadId ? _self.threadId : threadId // ignore: cast_nullable_to_non_nullable
as String,objective: null == objective ? _self.objective : objective // ignore: cast_nullable_to_non_nullable
as String,status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as ThreadGoalStatus,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as int,updatedAt: null == updatedAt ? _self.updatedAt : updatedAt // ignore: cast_nullable_to_non_nullable
as int,timeUsedSeconds: null == timeUsedSeconds ? _self.timeUsedSeconds : timeUsedSeconds // ignore: cast_nullable_to_non_nullable
as int,tokensUsed: null == tokensUsed ? _self.tokensUsed : tokensUsed // ignore: cast_nullable_to_non_nullable
as int,tokenBudget: freezed == tokenBudget ? _self.tokenBudget : tokenBudget // ignore: cast_nullable_to_non_nullable
as int?,
  ));
}

}


/// Adds pattern-matching-related methods to [ThreadGoal].
extension ThreadGoalPatterns on ThreadGoal {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ThreadGoal value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ThreadGoal() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ThreadGoal value)  $default,){
final _that = this;
switch (_that) {
case _ThreadGoal():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ThreadGoal value)?  $default,){
final _that = this;
switch (_that) {
case _ThreadGoal() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String threadId,  String objective,  ThreadGoalStatus status,  int createdAt,  int updatedAt,  int timeUsedSeconds,  int tokensUsed,  int? tokenBudget)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ThreadGoal() when $default != null:
return $default(_that.threadId,_that.objective,_that.status,_that.createdAt,_that.updatedAt,_that.timeUsedSeconds,_that.tokensUsed,_that.tokenBudget);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String threadId,  String objective,  ThreadGoalStatus status,  int createdAt,  int updatedAt,  int timeUsedSeconds,  int tokensUsed,  int? tokenBudget)  $default,) {final _that = this;
switch (_that) {
case _ThreadGoal():
return $default(_that.threadId,_that.objective,_that.status,_that.createdAt,_that.updatedAt,_that.timeUsedSeconds,_that.tokensUsed,_that.tokenBudget);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String threadId,  String objective,  ThreadGoalStatus status,  int createdAt,  int updatedAt,  int timeUsedSeconds,  int tokensUsed,  int? tokenBudget)?  $default,) {final _that = this;
switch (_that) {
case _ThreadGoal() when $default != null:
return $default(_that.threadId,_that.objective,_that.status,_that.createdAt,_that.updatedAt,_that.timeUsedSeconds,_that.tokensUsed,_that.tokenBudget);case _:
  return null;

}
}

}

/// @nodoc


class _ThreadGoal implements ThreadGoal {
  const _ThreadGoal({required this.threadId, required this.objective, required this.status, this.createdAt = 0, this.updatedAt = 0, this.timeUsedSeconds = 0, this.tokensUsed = 0, this.tokenBudget});
  

@override final  String threadId;
@override final  String objective;
@override final  ThreadGoalStatus status;
@override@JsonKey() final  int createdAt;
@override@JsonKey() final  int updatedAt;
@override@JsonKey() final  int timeUsedSeconds;
@override@JsonKey() final  int tokensUsed;
@override final  int? tokenBudget;

/// Create a copy of ThreadGoal
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ThreadGoalCopyWith<_ThreadGoal> get copyWith => __$ThreadGoalCopyWithImpl<_ThreadGoal>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ThreadGoal&&(identical(other.threadId, threadId) || other.threadId == threadId)&&(identical(other.objective, objective) || other.objective == objective)&&(identical(other.status, status) || other.status == status)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt)&&(identical(other.updatedAt, updatedAt) || other.updatedAt == updatedAt)&&(identical(other.timeUsedSeconds, timeUsedSeconds) || other.timeUsedSeconds == timeUsedSeconds)&&(identical(other.tokensUsed, tokensUsed) || other.tokensUsed == tokensUsed)&&(identical(other.tokenBudget, tokenBudget) || other.tokenBudget == tokenBudget));
}


@override
int get hashCode => Object.hash(runtimeType,threadId,objective,status,createdAt,updatedAt,timeUsedSeconds,tokensUsed,tokenBudget);

@override
String toString() {
  return 'ThreadGoal(threadId: $threadId, objective: $objective, status: $status, createdAt: $createdAt, updatedAt: $updatedAt, timeUsedSeconds: $timeUsedSeconds, tokensUsed: $tokensUsed, tokenBudget: $tokenBudget)';
}


}

/// @nodoc
abstract mixin class _$ThreadGoalCopyWith<$Res> implements $ThreadGoalCopyWith<$Res> {
  factory _$ThreadGoalCopyWith(_ThreadGoal value, $Res Function(_ThreadGoal) _then) = __$ThreadGoalCopyWithImpl;
@override @useResult
$Res call({
 String threadId, String objective, ThreadGoalStatus status, int createdAt, int updatedAt, int timeUsedSeconds, int tokensUsed, int? tokenBudget
});




}
/// @nodoc
class __$ThreadGoalCopyWithImpl<$Res>
    implements _$ThreadGoalCopyWith<$Res> {
  __$ThreadGoalCopyWithImpl(this._self, this._then);

  final _ThreadGoal _self;
  final $Res Function(_ThreadGoal) _then;

/// Create a copy of ThreadGoal
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? threadId = null,Object? objective = null,Object? status = null,Object? createdAt = null,Object? updatedAt = null,Object? timeUsedSeconds = null,Object? tokensUsed = null,Object? tokenBudget = freezed,}) {
  return _then(_ThreadGoal(
threadId: null == threadId ? _self.threadId : threadId // ignore: cast_nullable_to_non_nullable
as String,objective: null == objective ? _self.objective : objective // ignore: cast_nullable_to_non_nullable
as String,status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as ThreadGoalStatus,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as int,updatedAt: null == updatedAt ? _self.updatedAt : updatedAt // ignore: cast_nullable_to_non_nullable
as int,timeUsedSeconds: null == timeUsedSeconds ? _self.timeUsedSeconds : timeUsedSeconds // ignore: cast_nullable_to_non_nullable
as int,tokensUsed: null == tokensUsed ? _self.tokensUsed : tokensUsed // ignore: cast_nullable_to_non_nullable
as int,tokenBudget: freezed == tokenBudget ? _self.tokenBudget : tokenBudget // ignore: cast_nullable_to_non_nullable
as int?,
  ));
}


}

/// @nodoc
mixin _$TokenUsageBreakdown {

 int get cachedInputTokens; int get inputTokens; int get outputTokens; int get reasoningOutputTokens; int get totalTokens;
/// Create a copy of TokenUsageBreakdown
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$TokenUsageBreakdownCopyWith<TokenUsageBreakdown> get copyWith => _$TokenUsageBreakdownCopyWithImpl<TokenUsageBreakdown>(this as TokenUsageBreakdown, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is TokenUsageBreakdown&&(identical(other.cachedInputTokens, cachedInputTokens) || other.cachedInputTokens == cachedInputTokens)&&(identical(other.inputTokens, inputTokens) || other.inputTokens == inputTokens)&&(identical(other.outputTokens, outputTokens) || other.outputTokens == outputTokens)&&(identical(other.reasoningOutputTokens, reasoningOutputTokens) || other.reasoningOutputTokens == reasoningOutputTokens)&&(identical(other.totalTokens, totalTokens) || other.totalTokens == totalTokens));
}


@override
int get hashCode => Object.hash(runtimeType,cachedInputTokens,inputTokens,outputTokens,reasoningOutputTokens,totalTokens);

@override
String toString() {
  return 'TokenUsageBreakdown(cachedInputTokens: $cachedInputTokens, inputTokens: $inputTokens, outputTokens: $outputTokens, reasoningOutputTokens: $reasoningOutputTokens, totalTokens: $totalTokens)';
}


}

/// @nodoc
abstract mixin class $TokenUsageBreakdownCopyWith<$Res>  {
  factory $TokenUsageBreakdownCopyWith(TokenUsageBreakdown value, $Res Function(TokenUsageBreakdown) _then) = _$TokenUsageBreakdownCopyWithImpl;
@useResult
$Res call({
 int cachedInputTokens, int inputTokens, int outputTokens, int reasoningOutputTokens, int totalTokens
});




}
/// @nodoc
class _$TokenUsageBreakdownCopyWithImpl<$Res>
    implements $TokenUsageBreakdownCopyWith<$Res> {
  _$TokenUsageBreakdownCopyWithImpl(this._self, this._then);

  final TokenUsageBreakdown _self;
  final $Res Function(TokenUsageBreakdown) _then;

/// Create a copy of TokenUsageBreakdown
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? cachedInputTokens = null,Object? inputTokens = null,Object? outputTokens = null,Object? reasoningOutputTokens = null,Object? totalTokens = null,}) {
  return _then(_self.copyWith(
cachedInputTokens: null == cachedInputTokens ? _self.cachedInputTokens : cachedInputTokens // ignore: cast_nullable_to_non_nullable
as int,inputTokens: null == inputTokens ? _self.inputTokens : inputTokens // ignore: cast_nullable_to_non_nullable
as int,outputTokens: null == outputTokens ? _self.outputTokens : outputTokens // ignore: cast_nullable_to_non_nullable
as int,reasoningOutputTokens: null == reasoningOutputTokens ? _self.reasoningOutputTokens : reasoningOutputTokens // ignore: cast_nullable_to_non_nullable
as int,totalTokens: null == totalTokens ? _self.totalTokens : totalTokens // ignore: cast_nullable_to_non_nullable
as int,
  ));
}

}


/// Adds pattern-matching-related methods to [TokenUsageBreakdown].
extension TokenUsageBreakdownPatterns on TokenUsageBreakdown {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _TokenUsageBreakdown value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _TokenUsageBreakdown() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _TokenUsageBreakdown value)  $default,){
final _that = this;
switch (_that) {
case _TokenUsageBreakdown():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _TokenUsageBreakdown value)?  $default,){
final _that = this;
switch (_that) {
case _TokenUsageBreakdown() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( int cachedInputTokens,  int inputTokens,  int outputTokens,  int reasoningOutputTokens,  int totalTokens)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _TokenUsageBreakdown() when $default != null:
return $default(_that.cachedInputTokens,_that.inputTokens,_that.outputTokens,_that.reasoningOutputTokens,_that.totalTokens);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( int cachedInputTokens,  int inputTokens,  int outputTokens,  int reasoningOutputTokens,  int totalTokens)  $default,) {final _that = this;
switch (_that) {
case _TokenUsageBreakdown():
return $default(_that.cachedInputTokens,_that.inputTokens,_that.outputTokens,_that.reasoningOutputTokens,_that.totalTokens);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( int cachedInputTokens,  int inputTokens,  int outputTokens,  int reasoningOutputTokens,  int totalTokens)?  $default,) {final _that = this;
switch (_that) {
case _TokenUsageBreakdown() when $default != null:
return $default(_that.cachedInputTokens,_that.inputTokens,_that.outputTokens,_that.reasoningOutputTokens,_that.totalTokens);case _:
  return null;

}
}

}

/// @nodoc


class _TokenUsageBreakdown implements TokenUsageBreakdown {
  const _TokenUsageBreakdown({this.cachedInputTokens = 0, this.inputTokens = 0, this.outputTokens = 0, this.reasoningOutputTokens = 0, this.totalTokens = 0});
  

@override@JsonKey() final  int cachedInputTokens;
@override@JsonKey() final  int inputTokens;
@override@JsonKey() final  int outputTokens;
@override@JsonKey() final  int reasoningOutputTokens;
@override@JsonKey() final  int totalTokens;

/// Create a copy of TokenUsageBreakdown
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$TokenUsageBreakdownCopyWith<_TokenUsageBreakdown> get copyWith => __$TokenUsageBreakdownCopyWithImpl<_TokenUsageBreakdown>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _TokenUsageBreakdown&&(identical(other.cachedInputTokens, cachedInputTokens) || other.cachedInputTokens == cachedInputTokens)&&(identical(other.inputTokens, inputTokens) || other.inputTokens == inputTokens)&&(identical(other.outputTokens, outputTokens) || other.outputTokens == outputTokens)&&(identical(other.reasoningOutputTokens, reasoningOutputTokens) || other.reasoningOutputTokens == reasoningOutputTokens)&&(identical(other.totalTokens, totalTokens) || other.totalTokens == totalTokens));
}


@override
int get hashCode => Object.hash(runtimeType,cachedInputTokens,inputTokens,outputTokens,reasoningOutputTokens,totalTokens);

@override
String toString() {
  return 'TokenUsageBreakdown(cachedInputTokens: $cachedInputTokens, inputTokens: $inputTokens, outputTokens: $outputTokens, reasoningOutputTokens: $reasoningOutputTokens, totalTokens: $totalTokens)';
}


}

/// @nodoc
abstract mixin class _$TokenUsageBreakdownCopyWith<$Res> implements $TokenUsageBreakdownCopyWith<$Res> {
  factory _$TokenUsageBreakdownCopyWith(_TokenUsageBreakdown value, $Res Function(_TokenUsageBreakdown) _then) = __$TokenUsageBreakdownCopyWithImpl;
@override @useResult
$Res call({
 int cachedInputTokens, int inputTokens, int outputTokens, int reasoningOutputTokens, int totalTokens
});




}
/// @nodoc
class __$TokenUsageBreakdownCopyWithImpl<$Res>
    implements _$TokenUsageBreakdownCopyWith<$Res> {
  __$TokenUsageBreakdownCopyWithImpl(this._self, this._then);

  final _TokenUsageBreakdown _self;
  final $Res Function(_TokenUsageBreakdown) _then;

/// Create a copy of TokenUsageBreakdown
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? cachedInputTokens = null,Object? inputTokens = null,Object? outputTokens = null,Object? reasoningOutputTokens = null,Object? totalTokens = null,}) {
  return _then(_TokenUsageBreakdown(
cachedInputTokens: null == cachedInputTokens ? _self.cachedInputTokens : cachedInputTokens // ignore: cast_nullable_to_non_nullable
as int,inputTokens: null == inputTokens ? _self.inputTokens : inputTokens // ignore: cast_nullable_to_non_nullable
as int,outputTokens: null == outputTokens ? _self.outputTokens : outputTokens // ignore: cast_nullable_to_non_nullable
as int,reasoningOutputTokens: null == reasoningOutputTokens ? _self.reasoningOutputTokens : reasoningOutputTokens // ignore: cast_nullable_to_non_nullable
as int,totalTokens: null == totalTokens ? _self.totalTokens : totalTokens // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc
mixin _$TokenUsage {

 TokenUsageBreakdown get last; TokenUsageBreakdown get total; int get modelContextWindow;
/// Create a copy of TokenUsage
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$TokenUsageCopyWith<TokenUsage> get copyWith => _$TokenUsageCopyWithImpl<TokenUsage>(this as TokenUsage, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is TokenUsage&&(identical(other.last, last) || other.last == last)&&(identical(other.total, total) || other.total == total)&&(identical(other.modelContextWindow, modelContextWindow) || other.modelContextWindow == modelContextWindow));
}


@override
int get hashCode => Object.hash(runtimeType,last,total,modelContextWindow);

@override
String toString() {
  return 'TokenUsage(last: $last, total: $total, modelContextWindow: $modelContextWindow)';
}


}

/// @nodoc
abstract mixin class $TokenUsageCopyWith<$Res>  {
  factory $TokenUsageCopyWith(TokenUsage value, $Res Function(TokenUsage) _then) = _$TokenUsageCopyWithImpl;
@useResult
$Res call({
 TokenUsageBreakdown last, TokenUsageBreakdown total, int modelContextWindow
});


$TokenUsageBreakdownCopyWith<$Res> get last;$TokenUsageBreakdownCopyWith<$Res> get total;

}
/// @nodoc
class _$TokenUsageCopyWithImpl<$Res>
    implements $TokenUsageCopyWith<$Res> {
  _$TokenUsageCopyWithImpl(this._self, this._then);

  final TokenUsage _self;
  final $Res Function(TokenUsage) _then;

/// Create a copy of TokenUsage
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? last = null,Object? total = null,Object? modelContextWindow = null,}) {
  return _then(_self.copyWith(
last: null == last ? _self.last : last // ignore: cast_nullable_to_non_nullable
as TokenUsageBreakdown,total: null == total ? _self.total : total // ignore: cast_nullable_to_non_nullable
as TokenUsageBreakdown,modelContextWindow: null == modelContextWindow ? _self.modelContextWindow : modelContextWindow // ignore: cast_nullable_to_non_nullable
as int,
  ));
}
/// Create a copy of TokenUsage
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$TokenUsageBreakdownCopyWith<$Res> get last {
  
  return $TokenUsageBreakdownCopyWith<$Res>(_self.last, (value) {
    return _then(_self.copyWith(last: value));
  });
}/// Create a copy of TokenUsage
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$TokenUsageBreakdownCopyWith<$Res> get total {
  
  return $TokenUsageBreakdownCopyWith<$Res>(_self.total, (value) {
    return _then(_self.copyWith(total: value));
  });
}
}


/// Adds pattern-matching-related methods to [TokenUsage].
extension TokenUsagePatterns on TokenUsage {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _TokenUsage value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _TokenUsage() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _TokenUsage value)  $default,){
final _that = this;
switch (_that) {
case _TokenUsage():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _TokenUsage value)?  $default,){
final _that = this;
switch (_that) {
case _TokenUsage() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( TokenUsageBreakdown last,  TokenUsageBreakdown total,  int modelContextWindow)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _TokenUsage() when $default != null:
return $default(_that.last,_that.total,_that.modelContextWindow);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( TokenUsageBreakdown last,  TokenUsageBreakdown total,  int modelContextWindow)  $default,) {final _that = this;
switch (_that) {
case _TokenUsage():
return $default(_that.last,_that.total,_that.modelContextWindow);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( TokenUsageBreakdown last,  TokenUsageBreakdown total,  int modelContextWindow)?  $default,) {final _that = this;
switch (_that) {
case _TokenUsage() when $default != null:
return $default(_that.last,_that.total,_that.modelContextWindow);case _:
  return null;

}
}

}

/// @nodoc


class _TokenUsage extends TokenUsage {
  const _TokenUsage({this.last = const TokenUsageBreakdown(), this.total = const TokenUsageBreakdown(), this.modelContextWindow = 0}): super._();
  

@override@JsonKey() final  TokenUsageBreakdown last;
@override@JsonKey() final  TokenUsageBreakdown total;
@override@JsonKey() final  int modelContextWindow;

/// Create a copy of TokenUsage
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$TokenUsageCopyWith<_TokenUsage> get copyWith => __$TokenUsageCopyWithImpl<_TokenUsage>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _TokenUsage&&(identical(other.last, last) || other.last == last)&&(identical(other.total, total) || other.total == total)&&(identical(other.modelContextWindow, modelContextWindow) || other.modelContextWindow == modelContextWindow));
}


@override
int get hashCode => Object.hash(runtimeType,last,total,modelContextWindow);

@override
String toString() {
  return 'TokenUsage(last: $last, total: $total, modelContextWindow: $modelContextWindow)';
}


}

/// @nodoc
abstract mixin class _$TokenUsageCopyWith<$Res> implements $TokenUsageCopyWith<$Res> {
  factory _$TokenUsageCopyWith(_TokenUsage value, $Res Function(_TokenUsage) _then) = __$TokenUsageCopyWithImpl;
@override @useResult
$Res call({
 TokenUsageBreakdown last, TokenUsageBreakdown total, int modelContextWindow
});


@override $TokenUsageBreakdownCopyWith<$Res> get last;@override $TokenUsageBreakdownCopyWith<$Res> get total;

}
/// @nodoc
class __$TokenUsageCopyWithImpl<$Res>
    implements _$TokenUsageCopyWith<$Res> {
  __$TokenUsageCopyWithImpl(this._self, this._then);

  final _TokenUsage _self;
  final $Res Function(_TokenUsage) _then;

/// Create a copy of TokenUsage
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? last = null,Object? total = null,Object? modelContextWindow = null,}) {
  return _then(_TokenUsage(
last: null == last ? _self.last : last // ignore: cast_nullable_to_non_nullable
as TokenUsageBreakdown,total: null == total ? _self.total : total // ignore: cast_nullable_to_non_nullable
as TokenUsageBreakdown,modelContextWindow: null == modelContextWindow ? _self.modelContextWindow : modelContextWindow // ignore: cast_nullable_to_non_nullable
as int,
  ));
}

/// Create a copy of TokenUsage
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$TokenUsageBreakdownCopyWith<$Res> get last {
  
  return $TokenUsageBreakdownCopyWith<$Res>(_self.last, (value) {
    return _then(_self.copyWith(last: value));
  });
}/// Create a copy of TokenUsage
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$TokenUsageBreakdownCopyWith<$Res> get total {
  
  return $TokenUsageBreakdownCopyWith<$Res>(_self.total, (value) {
    return _then(_self.copyWith(total: value));
  });
}
}

/// @nodoc
mixin _$FileChange {

 String get path; String get kind; String get diff;
/// Create a copy of FileChange
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$FileChangeCopyWith<FileChange> get copyWith => _$FileChangeCopyWithImpl<FileChange>(this as FileChange, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is FileChange&&(identical(other.path, path) || other.path == path)&&(identical(other.kind, kind) || other.kind == kind)&&(identical(other.diff, diff) || other.diff == diff));
}


@override
int get hashCode => Object.hash(runtimeType,path,kind,diff);

@override
String toString() {
  return 'FileChange(path: $path, kind: $kind, diff: $diff)';
}


}

/// @nodoc
abstract mixin class $FileChangeCopyWith<$Res>  {
  factory $FileChangeCopyWith(FileChange value, $Res Function(FileChange) _then) = _$FileChangeCopyWithImpl;
@useResult
$Res call({
 String path, String kind, String diff
});




}
/// @nodoc
class _$FileChangeCopyWithImpl<$Res>
    implements $FileChangeCopyWith<$Res> {
  _$FileChangeCopyWithImpl(this._self, this._then);

  final FileChange _self;
  final $Res Function(FileChange) _then;

/// Create a copy of FileChange
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? path = null,Object? kind = null,Object? diff = null,}) {
  return _then(_self.copyWith(
path: null == path ? _self.path : path // ignore: cast_nullable_to_non_nullable
as String,kind: null == kind ? _self.kind : kind // ignore: cast_nullable_to_non_nullable
as String,diff: null == diff ? _self.diff : diff // ignore: cast_nullable_to_non_nullable
as String,
  ));
}

}


/// Adds pattern-matching-related methods to [FileChange].
extension FileChangePatterns on FileChange {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _FileChange value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _FileChange() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _FileChange value)  $default,){
final _that = this;
switch (_that) {
case _FileChange():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _FileChange value)?  $default,){
final _that = this;
switch (_that) {
case _FileChange() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String path,  String kind,  String diff)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _FileChange() when $default != null:
return $default(_that.path,_that.kind,_that.diff);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String path,  String kind,  String diff)  $default,) {final _that = this;
switch (_that) {
case _FileChange():
return $default(_that.path,_that.kind,_that.diff);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String path,  String kind,  String diff)?  $default,) {final _that = this;
switch (_that) {
case _FileChange() when $default != null:
return $default(_that.path,_that.kind,_that.diff);case _:
  return null;

}
}

}

/// @nodoc


class _FileChange extends FileChange {
  const _FileChange({required this.path, this.kind = '', this.diff = ''}): super._();
  

@override final  String path;
@override@JsonKey() final  String kind;
@override@JsonKey() final  String diff;

/// Create a copy of FileChange
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$FileChangeCopyWith<_FileChange> get copyWith => __$FileChangeCopyWithImpl<_FileChange>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _FileChange&&(identical(other.path, path) || other.path == path)&&(identical(other.kind, kind) || other.kind == kind)&&(identical(other.diff, diff) || other.diff == diff));
}


@override
int get hashCode => Object.hash(runtimeType,path,kind,diff);

@override
String toString() {
  return 'FileChange(path: $path, kind: $kind, diff: $diff)';
}


}

/// @nodoc
abstract mixin class _$FileChangeCopyWith<$Res> implements $FileChangeCopyWith<$Res> {
  factory _$FileChangeCopyWith(_FileChange value, $Res Function(_FileChange) _then) = __$FileChangeCopyWithImpl;
@override @useResult
$Res call({
 String path, String kind, String diff
});




}
/// @nodoc
class __$FileChangeCopyWithImpl<$Res>
    implements _$FileChangeCopyWith<$Res> {
  __$FileChangeCopyWithImpl(this._self, this._then);

  final _FileChange _self;
  final $Res Function(_FileChange) _then;

/// Create a copy of FileChange
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? path = null,Object? kind = null,Object? diff = null,}) {
  return _then(_FileChange(
path: null == path ? _self.path : path // ignore: cast_nullable_to_non_nullable
as String,kind: null == kind ? _self.kind : kind // ignore: cast_nullable_to_non_nullable
as String,diff: null == diff ? _self.diff : diff // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc
mixin _$MessageAttachment {

 String get name; String get remotePath; String get mimeType;
/// Create a copy of MessageAttachment
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$MessageAttachmentCopyWith<MessageAttachment> get copyWith => _$MessageAttachmentCopyWithImpl<MessageAttachment>(this as MessageAttachment, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MessageAttachment&&(identical(other.name, name) || other.name == name)&&(identical(other.remotePath, remotePath) || other.remotePath == remotePath)&&(identical(other.mimeType, mimeType) || other.mimeType == mimeType));
}


@override
int get hashCode => Object.hash(runtimeType,name,remotePath,mimeType);

@override
String toString() {
  return 'MessageAttachment(name: $name, remotePath: $remotePath, mimeType: $mimeType)';
}


}

/// @nodoc
abstract mixin class $MessageAttachmentCopyWith<$Res>  {
  factory $MessageAttachmentCopyWith(MessageAttachment value, $Res Function(MessageAttachment) _then) = _$MessageAttachmentCopyWithImpl;
@useResult
$Res call({
 String name, String remotePath, String mimeType
});




}
/// @nodoc
class _$MessageAttachmentCopyWithImpl<$Res>
    implements $MessageAttachmentCopyWith<$Res> {
  _$MessageAttachmentCopyWithImpl(this._self, this._then);

  final MessageAttachment _self;
  final $Res Function(MessageAttachment) _then;

/// Create a copy of MessageAttachment
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? name = null,Object? remotePath = null,Object? mimeType = null,}) {
  return _then(_self.copyWith(
name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,remotePath: null == remotePath ? _self.remotePath : remotePath // ignore: cast_nullable_to_non_nullable
as String,mimeType: null == mimeType ? _self.mimeType : mimeType // ignore: cast_nullable_to_non_nullable
as String,
  ));
}

}


/// Adds pattern-matching-related methods to [MessageAttachment].
extension MessageAttachmentPatterns on MessageAttachment {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _MessageAttachment value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _MessageAttachment() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _MessageAttachment value)  $default,){
final _that = this;
switch (_that) {
case _MessageAttachment():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _MessageAttachment value)?  $default,){
final _that = this;
switch (_that) {
case _MessageAttachment() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String name,  String remotePath,  String mimeType)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _MessageAttachment() when $default != null:
return $default(_that.name,_that.remotePath,_that.mimeType);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String name,  String remotePath,  String mimeType)  $default,) {final _that = this;
switch (_that) {
case _MessageAttachment():
return $default(_that.name,_that.remotePath,_that.mimeType);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String name,  String remotePath,  String mimeType)?  $default,) {final _that = this;
switch (_that) {
case _MessageAttachment() when $default != null:
return $default(_that.name,_that.remotePath,_that.mimeType);case _:
  return null;

}
}

}

/// @nodoc


class _MessageAttachment implements MessageAttachment {
  const _MessageAttachment({required this.name, this.remotePath = '', this.mimeType = 'application/octet-stream'});
  

@override final  String name;
@override@JsonKey() final  String remotePath;
@override@JsonKey() final  String mimeType;

/// Create a copy of MessageAttachment
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$MessageAttachmentCopyWith<_MessageAttachment> get copyWith => __$MessageAttachmentCopyWithImpl<_MessageAttachment>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _MessageAttachment&&(identical(other.name, name) || other.name == name)&&(identical(other.remotePath, remotePath) || other.remotePath == remotePath)&&(identical(other.mimeType, mimeType) || other.mimeType == mimeType));
}


@override
int get hashCode => Object.hash(runtimeType,name,remotePath,mimeType);

@override
String toString() {
  return 'MessageAttachment(name: $name, remotePath: $remotePath, mimeType: $mimeType)';
}


}

/// @nodoc
abstract mixin class _$MessageAttachmentCopyWith<$Res> implements $MessageAttachmentCopyWith<$Res> {
  factory _$MessageAttachmentCopyWith(_MessageAttachment value, $Res Function(_MessageAttachment) _then) = __$MessageAttachmentCopyWithImpl;
@override @useResult
$Res call({
 String name, String remotePath, String mimeType
});




}
/// @nodoc
class __$MessageAttachmentCopyWithImpl<$Res>
    implements _$MessageAttachmentCopyWith<$Res> {
  __$MessageAttachmentCopyWithImpl(this._self, this._then);

  final _MessageAttachment _self;
  final $Res Function(_MessageAttachment) _then;

/// Create a copy of MessageAttachment
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? name = null,Object? remotePath = null,Object? mimeType = null,}) {
  return _then(_MessageAttachment(
name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,remotePath: null == remotePath ? _self.remotePath : remotePath // ignore: cast_nullable_to_non_nullable
as String,mimeType: null == mimeType ? _self.mimeType : mimeType // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc
mixin _$TimelineEntry {

 String get id; TimelineKind get kind; String get title; String get text; String get status; String get command; String get cwd; String get output; List<FileChange> get changes; List<MessageAttachment> get attachments; String get turnId; String get subAgentPath; String get subAgentThreadId; String get subAgentActivity; List<String> get reasoningSummary; List<String> get reasoningContent;
/// Create a copy of TimelineEntry
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$TimelineEntryCopyWith<TimelineEntry> get copyWith => _$TimelineEntryCopyWithImpl<TimelineEntry>(this as TimelineEntry, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is TimelineEntry&&(identical(other.id, id) || other.id == id)&&(identical(other.kind, kind) || other.kind == kind)&&(identical(other.title, title) || other.title == title)&&(identical(other.text, text) || other.text == text)&&(identical(other.status, status) || other.status == status)&&(identical(other.command, command) || other.command == command)&&(identical(other.cwd, cwd) || other.cwd == cwd)&&(identical(other.output, output) || other.output == output)&&const DeepCollectionEquality().equals(other.changes, changes)&&const DeepCollectionEquality().equals(other.attachments, attachments)&&(identical(other.turnId, turnId) || other.turnId == turnId)&&(identical(other.subAgentPath, subAgentPath) || other.subAgentPath == subAgentPath)&&(identical(other.subAgentThreadId, subAgentThreadId) || other.subAgentThreadId == subAgentThreadId)&&(identical(other.subAgentActivity, subAgentActivity) || other.subAgentActivity == subAgentActivity)&&const DeepCollectionEquality().equals(other.reasoningSummary, reasoningSummary)&&const DeepCollectionEquality().equals(other.reasoningContent, reasoningContent));
}


@override
int get hashCode => Object.hash(runtimeType,id,kind,title,text,status,command,cwd,output,const DeepCollectionEquality().hash(changes),const DeepCollectionEquality().hash(attachments),turnId,subAgentPath,subAgentThreadId,subAgentActivity,const DeepCollectionEquality().hash(reasoningSummary),const DeepCollectionEquality().hash(reasoningContent));

@override
String toString() {
  return 'TimelineEntry(id: $id, kind: $kind, title: $title, text: $text, status: $status, command: $command, cwd: $cwd, output: $output, changes: $changes, attachments: $attachments, turnId: $turnId, subAgentPath: $subAgentPath, subAgentThreadId: $subAgentThreadId, subAgentActivity: $subAgentActivity, reasoningSummary: $reasoningSummary, reasoningContent: $reasoningContent)';
}


}

/// @nodoc
abstract mixin class $TimelineEntryCopyWith<$Res>  {
  factory $TimelineEntryCopyWith(TimelineEntry value, $Res Function(TimelineEntry) _then) = _$TimelineEntryCopyWithImpl;
@useResult
$Res call({
 String id, TimelineKind kind, String title, String text, String status, String command, String cwd, String output, List<FileChange> changes, List<MessageAttachment> attachments, String turnId, String subAgentPath, String subAgentThreadId, String subAgentActivity, List<String> reasoningSummary, List<String> reasoningContent
});




}
/// @nodoc
class _$TimelineEntryCopyWithImpl<$Res>
    implements $TimelineEntryCopyWith<$Res> {
  _$TimelineEntryCopyWithImpl(this._self, this._then);

  final TimelineEntry _self;
  final $Res Function(TimelineEntry) _then;

/// Create a copy of TimelineEntry
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? kind = null,Object? title = null,Object? text = null,Object? status = null,Object? command = null,Object? cwd = null,Object? output = null,Object? changes = null,Object? attachments = null,Object? turnId = null,Object? subAgentPath = null,Object? subAgentThreadId = null,Object? subAgentActivity = null,Object? reasoningSummary = null,Object? reasoningContent = null,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,kind: null == kind ? _self.kind : kind // ignore: cast_nullable_to_non_nullable
as TimelineKind,title: null == title ? _self.title : title // ignore: cast_nullable_to_non_nullable
as String,text: null == text ? _self.text : text // ignore: cast_nullable_to_non_nullable
as String,status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as String,command: null == command ? _self.command : command // ignore: cast_nullable_to_non_nullable
as String,cwd: null == cwd ? _self.cwd : cwd // ignore: cast_nullable_to_non_nullable
as String,output: null == output ? _self.output : output // ignore: cast_nullable_to_non_nullable
as String,changes: null == changes ? _self.changes : changes // ignore: cast_nullable_to_non_nullable
as List<FileChange>,attachments: null == attachments ? _self.attachments : attachments // ignore: cast_nullable_to_non_nullable
as List<MessageAttachment>,turnId: null == turnId ? _self.turnId : turnId // ignore: cast_nullable_to_non_nullable
as String,subAgentPath: null == subAgentPath ? _self.subAgentPath : subAgentPath // ignore: cast_nullable_to_non_nullable
as String,subAgentThreadId: null == subAgentThreadId ? _self.subAgentThreadId : subAgentThreadId // ignore: cast_nullable_to_non_nullable
as String,subAgentActivity: null == subAgentActivity ? _self.subAgentActivity : subAgentActivity // ignore: cast_nullable_to_non_nullable
as String,reasoningSummary: null == reasoningSummary ? _self.reasoningSummary : reasoningSummary // ignore: cast_nullable_to_non_nullable
as List<String>,reasoningContent: null == reasoningContent ? _self.reasoningContent : reasoningContent // ignore: cast_nullable_to_non_nullable
as List<String>,
  ));
}

}


/// Adds pattern-matching-related methods to [TimelineEntry].
extension TimelineEntryPatterns on TimelineEntry {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _TimelineEntry value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _TimelineEntry() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _TimelineEntry value)  $default,){
final _that = this;
switch (_that) {
case _TimelineEntry():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _TimelineEntry value)?  $default,){
final _that = this;
switch (_that) {
case _TimelineEntry() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  TimelineKind kind,  String title,  String text,  String status,  String command,  String cwd,  String output,  List<FileChange> changes,  List<MessageAttachment> attachments,  String turnId,  String subAgentPath,  String subAgentThreadId,  String subAgentActivity,  List<String> reasoningSummary,  List<String> reasoningContent)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _TimelineEntry() when $default != null:
return $default(_that.id,_that.kind,_that.title,_that.text,_that.status,_that.command,_that.cwd,_that.output,_that.changes,_that.attachments,_that.turnId,_that.subAgentPath,_that.subAgentThreadId,_that.subAgentActivity,_that.reasoningSummary,_that.reasoningContent);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  TimelineKind kind,  String title,  String text,  String status,  String command,  String cwd,  String output,  List<FileChange> changes,  List<MessageAttachment> attachments,  String turnId,  String subAgentPath,  String subAgentThreadId,  String subAgentActivity,  List<String> reasoningSummary,  List<String> reasoningContent)  $default,) {final _that = this;
switch (_that) {
case _TimelineEntry():
return $default(_that.id,_that.kind,_that.title,_that.text,_that.status,_that.command,_that.cwd,_that.output,_that.changes,_that.attachments,_that.turnId,_that.subAgentPath,_that.subAgentThreadId,_that.subAgentActivity,_that.reasoningSummary,_that.reasoningContent);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  TimelineKind kind,  String title,  String text,  String status,  String command,  String cwd,  String output,  List<FileChange> changes,  List<MessageAttachment> attachments,  String turnId,  String subAgentPath,  String subAgentThreadId,  String subAgentActivity,  List<String> reasoningSummary,  List<String> reasoningContent)?  $default,) {final _that = this;
switch (_that) {
case _TimelineEntry() when $default != null:
return $default(_that.id,_that.kind,_that.title,_that.text,_that.status,_that.command,_that.cwd,_that.output,_that.changes,_that.attachments,_that.turnId,_that.subAgentPath,_that.subAgentThreadId,_that.subAgentActivity,_that.reasoningSummary,_that.reasoningContent);case _:
  return null;

}
}

}

/// @nodoc


class _TimelineEntry implements TimelineEntry {
  const _TimelineEntry({required this.id, required this.kind, this.title = '', this.text = '', this.status = '', this.command = '', this.cwd = '', this.output = '', final  List<FileChange> changes = const <FileChange>[], final  List<MessageAttachment> attachments = const <MessageAttachment>[], this.turnId = '', this.subAgentPath = '', this.subAgentThreadId = '', this.subAgentActivity = '', final  List<String> reasoningSummary = const <String>[], final  List<String> reasoningContent = const <String>[]}): _changes = changes,_attachments = attachments,_reasoningSummary = reasoningSummary,_reasoningContent = reasoningContent;
  

@override final  String id;
@override final  TimelineKind kind;
@override@JsonKey() final  String title;
@override@JsonKey() final  String text;
@override@JsonKey() final  String status;
@override@JsonKey() final  String command;
@override@JsonKey() final  String cwd;
@override@JsonKey() final  String output;
 final  List<FileChange> _changes;
@override@JsonKey() List<FileChange> get changes {
  if (_changes is EqualUnmodifiableListView) return _changes;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_changes);
}

 final  List<MessageAttachment> _attachments;
@override@JsonKey() List<MessageAttachment> get attachments {
  if (_attachments is EqualUnmodifiableListView) return _attachments;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_attachments);
}

@override@JsonKey() final  String turnId;
@override@JsonKey() final  String subAgentPath;
@override@JsonKey() final  String subAgentThreadId;
@override@JsonKey() final  String subAgentActivity;
 final  List<String> _reasoningSummary;
@override@JsonKey() List<String> get reasoningSummary {
  if (_reasoningSummary is EqualUnmodifiableListView) return _reasoningSummary;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_reasoningSummary);
}

 final  List<String> _reasoningContent;
@override@JsonKey() List<String> get reasoningContent {
  if (_reasoningContent is EqualUnmodifiableListView) return _reasoningContent;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_reasoningContent);
}


/// Create a copy of TimelineEntry
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$TimelineEntryCopyWith<_TimelineEntry> get copyWith => __$TimelineEntryCopyWithImpl<_TimelineEntry>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _TimelineEntry&&(identical(other.id, id) || other.id == id)&&(identical(other.kind, kind) || other.kind == kind)&&(identical(other.title, title) || other.title == title)&&(identical(other.text, text) || other.text == text)&&(identical(other.status, status) || other.status == status)&&(identical(other.command, command) || other.command == command)&&(identical(other.cwd, cwd) || other.cwd == cwd)&&(identical(other.output, output) || other.output == output)&&const DeepCollectionEquality().equals(other._changes, _changes)&&const DeepCollectionEquality().equals(other._attachments, _attachments)&&(identical(other.turnId, turnId) || other.turnId == turnId)&&(identical(other.subAgentPath, subAgentPath) || other.subAgentPath == subAgentPath)&&(identical(other.subAgentThreadId, subAgentThreadId) || other.subAgentThreadId == subAgentThreadId)&&(identical(other.subAgentActivity, subAgentActivity) || other.subAgentActivity == subAgentActivity)&&const DeepCollectionEquality().equals(other._reasoningSummary, _reasoningSummary)&&const DeepCollectionEquality().equals(other._reasoningContent, _reasoningContent));
}


@override
int get hashCode => Object.hash(runtimeType,id,kind,title,text,status,command,cwd,output,const DeepCollectionEquality().hash(_changes),const DeepCollectionEquality().hash(_attachments),turnId,subAgentPath,subAgentThreadId,subAgentActivity,const DeepCollectionEquality().hash(_reasoningSummary),const DeepCollectionEquality().hash(_reasoningContent));

@override
String toString() {
  return 'TimelineEntry(id: $id, kind: $kind, title: $title, text: $text, status: $status, command: $command, cwd: $cwd, output: $output, changes: $changes, attachments: $attachments, turnId: $turnId, subAgentPath: $subAgentPath, subAgentThreadId: $subAgentThreadId, subAgentActivity: $subAgentActivity, reasoningSummary: $reasoningSummary, reasoningContent: $reasoningContent)';
}


}

/// @nodoc
abstract mixin class _$TimelineEntryCopyWith<$Res> implements $TimelineEntryCopyWith<$Res> {
  factory _$TimelineEntryCopyWith(_TimelineEntry value, $Res Function(_TimelineEntry) _then) = __$TimelineEntryCopyWithImpl;
@override @useResult
$Res call({
 String id, TimelineKind kind, String title, String text, String status, String command, String cwd, String output, List<FileChange> changes, List<MessageAttachment> attachments, String turnId, String subAgentPath, String subAgentThreadId, String subAgentActivity, List<String> reasoningSummary, List<String> reasoningContent
});




}
/// @nodoc
class __$TimelineEntryCopyWithImpl<$Res>
    implements _$TimelineEntryCopyWith<$Res> {
  __$TimelineEntryCopyWithImpl(this._self, this._then);

  final _TimelineEntry _self;
  final $Res Function(_TimelineEntry) _then;

/// Create a copy of TimelineEntry
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? kind = null,Object? title = null,Object? text = null,Object? status = null,Object? command = null,Object? cwd = null,Object? output = null,Object? changes = null,Object? attachments = null,Object? turnId = null,Object? subAgentPath = null,Object? subAgentThreadId = null,Object? subAgentActivity = null,Object? reasoningSummary = null,Object? reasoningContent = null,}) {
  return _then(_TimelineEntry(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,kind: null == kind ? _self.kind : kind // ignore: cast_nullable_to_non_nullable
as TimelineKind,title: null == title ? _self.title : title // ignore: cast_nullable_to_non_nullable
as String,text: null == text ? _self.text : text // ignore: cast_nullable_to_non_nullable
as String,status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as String,command: null == command ? _self.command : command // ignore: cast_nullable_to_non_nullable
as String,cwd: null == cwd ? _self.cwd : cwd // ignore: cast_nullable_to_non_nullable
as String,output: null == output ? _self.output : output // ignore: cast_nullable_to_non_nullable
as String,changes: null == changes ? _self._changes : changes // ignore: cast_nullable_to_non_nullable
as List<FileChange>,attachments: null == attachments ? _self._attachments : attachments // ignore: cast_nullable_to_non_nullable
as List<MessageAttachment>,turnId: null == turnId ? _self.turnId : turnId // ignore: cast_nullable_to_non_nullable
as String,subAgentPath: null == subAgentPath ? _self.subAgentPath : subAgentPath // ignore: cast_nullable_to_non_nullable
as String,subAgentThreadId: null == subAgentThreadId ? _self.subAgentThreadId : subAgentThreadId // ignore: cast_nullable_to_non_nullable
as String,subAgentActivity: null == subAgentActivity ? _self.subAgentActivity : subAgentActivity // ignore: cast_nullable_to_non_nullable
as String,reasoningSummary: null == reasoningSummary ? _self._reasoningSummary : reasoningSummary // ignore: cast_nullable_to_non_nullable
as List<String>,reasoningContent: null == reasoningContent ? _self._reasoningContent : reasoningContent // ignore: cast_nullable_to_non_nullable
as List<String>,
  ));
}


}

/// @nodoc
mixin _$InputOption {

 String get label; String get description;
/// Create a copy of InputOption
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$InputOptionCopyWith<InputOption> get copyWith => _$InputOptionCopyWithImpl<InputOption>(this as InputOption, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is InputOption&&(identical(other.label, label) || other.label == label)&&(identical(other.description, description) || other.description == description));
}


@override
int get hashCode => Object.hash(runtimeType,label,description);

@override
String toString() {
  return 'InputOption(label: $label, description: $description)';
}


}

/// @nodoc
abstract mixin class $InputOptionCopyWith<$Res>  {
  factory $InputOptionCopyWith(InputOption value, $Res Function(InputOption) _then) = _$InputOptionCopyWithImpl;
@useResult
$Res call({
 String label, String description
});




}
/// @nodoc
class _$InputOptionCopyWithImpl<$Res>
    implements $InputOptionCopyWith<$Res> {
  _$InputOptionCopyWithImpl(this._self, this._then);

  final InputOption _self;
  final $Res Function(InputOption) _then;

/// Create a copy of InputOption
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? label = null,Object? description = null,}) {
  return _then(_self.copyWith(
label: null == label ? _self.label : label // ignore: cast_nullable_to_non_nullable
as String,description: null == description ? _self.description : description // ignore: cast_nullable_to_non_nullable
as String,
  ));
}

}


/// Adds pattern-matching-related methods to [InputOption].
extension InputOptionPatterns on InputOption {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _InputOption value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _InputOption() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _InputOption value)  $default,){
final _that = this;
switch (_that) {
case _InputOption():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _InputOption value)?  $default,){
final _that = this;
switch (_that) {
case _InputOption() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String label,  String description)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _InputOption() when $default != null:
return $default(_that.label,_that.description);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String label,  String description)  $default,) {final _that = this;
switch (_that) {
case _InputOption():
return $default(_that.label,_that.description);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String label,  String description)?  $default,) {final _that = this;
switch (_that) {
case _InputOption() when $default != null:
return $default(_that.label,_that.description);case _:
  return null;

}
}

}

/// @nodoc


class _InputOption implements InputOption {
  const _InputOption({required this.label, this.description = ''});
  

@override final  String label;
@override@JsonKey() final  String description;

/// Create a copy of InputOption
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$InputOptionCopyWith<_InputOption> get copyWith => __$InputOptionCopyWithImpl<_InputOption>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _InputOption&&(identical(other.label, label) || other.label == label)&&(identical(other.description, description) || other.description == description));
}


@override
int get hashCode => Object.hash(runtimeType,label,description);

@override
String toString() {
  return 'InputOption(label: $label, description: $description)';
}


}

/// @nodoc
abstract mixin class _$InputOptionCopyWith<$Res> implements $InputOptionCopyWith<$Res> {
  factory _$InputOptionCopyWith(_InputOption value, $Res Function(_InputOption) _then) = __$InputOptionCopyWithImpl;
@override @useResult
$Res call({
 String label, String description
});




}
/// @nodoc
class __$InputOptionCopyWithImpl<$Res>
    implements _$InputOptionCopyWith<$Res> {
  __$InputOptionCopyWithImpl(this._self, this._then);

  final _InputOption _self;
  final $Res Function(_InputOption) _then;

/// Create a copy of InputOption
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? label = null,Object? description = null,}) {
  return _then(_InputOption(
label: null == label ? _self.label : label // ignore: cast_nullable_to_non_nullable
as String,description: null == description ? _self.description : description // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc
mixin _$InputQuestion {

 String get id; String get header; String get question; List<InputOption> get options; bool get isSecret;
/// Create a copy of InputQuestion
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$InputQuestionCopyWith<InputQuestion> get copyWith => _$InputQuestionCopyWithImpl<InputQuestion>(this as InputQuestion, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is InputQuestion&&(identical(other.id, id) || other.id == id)&&(identical(other.header, header) || other.header == header)&&(identical(other.question, question) || other.question == question)&&const DeepCollectionEquality().equals(other.options, options)&&(identical(other.isSecret, isSecret) || other.isSecret == isSecret));
}


@override
int get hashCode => Object.hash(runtimeType,id,header,question,const DeepCollectionEquality().hash(options),isSecret);

@override
String toString() {
  return 'InputQuestion(id: $id, header: $header, question: $question, options: $options, isSecret: $isSecret)';
}


}

/// @nodoc
abstract mixin class $InputQuestionCopyWith<$Res>  {
  factory $InputQuestionCopyWith(InputQuestion value, $Res Function(InputQuestion) _then) = _$InputQuestionCopyWithImpl;
@useResult
$Res call({
 String id, String header, String question, List<InputOption> options, bool isSecret
});




}
/// @nodoc
class _$InputQuestionCopyWithImpl<$Res>
    implements $InputQuestionCopyWith<$Res> {
  _$InputQuestionCopyWithImpl(this._self, this._then);

  final InputQuestion _self;
  final $Res Function(InputQuestion) _then;

/// Create a copy of InputQuestion
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? header = null,Object? question = null,Object? options = null,Object? isSecret = null,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,header: null == header ? _self.header : header // ignore: cast_nullable_to_non_nullable
as String,question: null == question ? _self.question : question // ignore: cast_nullable_to_non_nullable
as String,options: null == options ? _self.options : options // ignore: cast_nullable_to_non_nullable
as List<InputOption>,isSecret: null == isSecret ? _self.isSecret : isSecret // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}

}


/// Adds pattern-matching-related methods to [InputQuestion].
extension InputQuestionPatterns on InputQuestion {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _InputQuestion value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _InputQuestion() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _InputQuestion value)  $default,){
final _that = this;
switch (_that) {
case _InputQuestion():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _InputQuestion value)?  $default,){
final _that = this;
switch (_that) {
case _InputQuestion() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String header,  String question,  List<InputOption> options,  bool isSecret)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _InputQuestion() when $default != null:
return $default(_that.id,_that.header,_that.question,_that.options,_that.isSecret);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String header,  String question,  List<InputOption> options,  bool isSecret)  $default,) {final _that = this;
switch (_that) {
case _InputQuestion():
return $default(_that.id,_that.header,_that.question,_that.options,_that.isSecret);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String header,  String question,  List<InputOption> options,  bool isSecret)?  $default,) {final _that = this;
switch (_that) {
case _InputQuestion() when $default != null:
return $default(_that.id,_that.header,_that.question,_that.options,_that.isSecret);case _:
  return null;

}
}

}

/// @nodoc


class _InputQuestion implements InputQuestion {
  const _InputQuestion({required this.id, required this.header, required this.question, final  List<InputOption> options = const <InputOption>[], this.isSecret = false}): _options = options;
  

@override final  String id;
@override final  String header;
@override final  String question;
 final  List<InputOption> _options;
@override@JsonKey() List<InputOption> get options {
  if (_options is EqualUnmodifiableListView) return _options;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_options);
}

@override@JsonKey() final  bool isSecret;

/// Create a copy of InputQuestion
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$InputQuestionCopyWith<_InputQuestion> get copyWith => __$InputQuestionCopyWithImpl<_InputQuestion>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _InputQuestion&&(identical(other.id, id) || other.id == id)&&(identical(other.header, header) || other.header == header)&&(identical(other.question, question) || other.question == question)&&const DeepCollectionEquality().equals(other._options, _options)&&(identical(other.isSecret, isSecret) || other.isSecret == isSecret));
}


@override
int get hashCode => Object.hash(runtimeType,id,header,question,const DeepCollectionEquality().hash(_options),isSecret);

@override
String toString() {
  return 'InputQuestion(id: $id, header: $header, question: $question, options: $options, isSecret: $isSecret)';
}


}

/// @nodoc
abstract mixin class _$InputQuestionCopyWith<$Res> implements $InputQuestionCopyWith<$Res> {
  factory _$InputQuestionCopyWith(_InputQuestion value, $Res Function(_InputQuestion) _then) = __$InputQuestionCopyWithImpl;
@override @useResult
$Res call({
 String id, String header, String question, List<InputOption> options, bool isSecret
});




}
/// @nodoc
class __$InputQuestionCopyWithImpl<$Res>
    implements _$InputQuestionCopyWith<$Res> {
  __$InputQuestionCopyWithImpl(this._self, this._then);

  final _InputQuestion _self;
  final $Res Function(_InputQuestion) _then;

/// Create a copy of InputQuestion
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? header = null,Object? question = null,Object? options = null,Object? isSecret = null,}) {
  return _then(_InputQuestion(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,header: null == header ? _self.header : header // ignore: cast_nullable_to_non_nullable
as String,question: null == question ? _self.question : question // ignore: cast_nullable_to_non_nullable
as String,options: null == options ? _self._options : options // ignore: cast_nullable_to_non_nullable
as List<InputOption>,isSecret: null == isSecret ? _self.isSecret : isSecret // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

/// @nodoc
mixin _$ApprovalPrompt {

 String get requestId; bool get requestIdIsString; ApprovalKind get kind; String get threadId; String get turnId; String get itemId; String get title; String get detail; String get command; String get cwd; List<InputQuestion> get questions;
/// Create a copy of ApprovalPrompt
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ApprovalPromptCopyWith<ApprovalPrompt> get copyWith => _$ApprovalPromptCopyWithImpl<ApprovalPrompt>(this as ApprovalPrompt, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ApprovalPrompt&&(identical(other.requestId, requestId) || other.requestId == requestId)&&(identical(other.requestIdIsString, requestIdIsString) || other.requestIdIsString == requestIdIsString)&&(identical(other.kind, kind) || other.kind == kind)&&(identical(other.threadId, threadId) || other.threadId == threadId)&&(identical(other.turnId, turnId) || other.turnId == turnId)&&(identical(other.itemId, itemId) || other.itemId == itemId)&&(identical(other.title, title) || other.title == title)&&(identical(other.detail, detail) || other.detail == detail)&&(identical(other.command, command) || other.command == command)&&(identical(other.cwd, cwd) || other.cwd == cwd)&&const DeepCollectionEquality().equals(other.questions, questions));
}


@override
int get hashCode => Object.hash(runtimeType,requestId,requestIdIsString,kind,threadId,turnId,itemId,title,detail,command,cwd,const DeepCollectionEquality().hash(questions));

@override
String toString() {
  return 'ApprovalPrompt(requestId: $requestId, requestIdIsString: $requestIdIsString, kind: $kind, threadId: $threadId, turnId: $turnId, itemId: $itemId, title: $title, detail: $detail, command: $command, cwd: $cwd, questions: $questions)';
}


}

/// @nodoc
abstract mixin class $ApprovalPromptCopyWith<$Res>  {
  factory $ApprovalPromptCopyWith(ApprovalPrompt value, $Res Function(ApprovalPrompt) _then) = _$ApprovalPromptCopyWithImpl;
@useResult
$Res call({
 String requestId, bool requestIdIsString, ApprovalKind kind, String threadId, String turnId, String itemId, String title, String detail, String command, String cwd, List<InputQuestion> questions
});




}
/// @nodoc
class _$ApprovalPromptCopyWithImpl<$Res>
    implements $ApprovalPromptCopyWith<$Res> {
  _$ApprovalPromptCopyWithImpl(this._self, this._then);

  final ApprovalPrompt _self;
  final $Res Function(ApprovalPrompt) _then;

/// Create a copy of ApprovalPrompt
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? requestId = null,Object? requestIdIsString = null,Object? kind = null,Object? threadId = null,Object? turnId = null,Object? itemId = null,Object? title = null,Object? detail = null,Object? command = null,Object? cwd = null,Object? questions = null,}) {
  return _then(_self.copyWith(
requestId: null == requestId ? _self.requestId : requestId // ignore: cast_nullable_to_non_nullable
as String,requestIdIsString: null == requestIdIsString ? _self.requestIdIsString : requestIdIsString // ignore: cast_nullable_to_non_nullable
as bool,kind: null == kind ? _self.kind : kind // ignore: cast_nullable_to_non_nullable
as ApprovalKind,threadId: null == threadId ? _self.threadId : threadId // ignore: cast_nullable_to_non_nullable
as String,turnId: null == turnId ? _self.turnId : turnId // ignore: cast_nullable_to_non_nullable
as String,itemId: null == itemId ? _self.itemId : itemId // ignore: cast_nullable_to_non_nullable
as String,title: null == title ? _self.title : title // ignore: cast_nullable_to_non_nullable
as String,detail: null == detail ? _self.detail : detail // ignore: cast_nullable_to_non_nullable
as String,command: null == command ? _self.command : command // ignore: cast_nullable_to_non_nullable
as String,cwd: null == cwd ? _self.cwd : cwd // ignore: cast_nullable_to_non_nullable
as String,questions: null == questions ? _self.questions : questions // ignore: cast_nullable_to_non_nullable
as List<InputQuestion>,
  ));
}

}


/// Adds pattern-matching-related methods to [ApprovalPrompt].
extension ApprovalPromptPatterns on ApprovalPrompt {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ApprovalPrompt value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ApprovalPrompt() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ApprovalPrompt value)  $default,){
final _that = this;
switch (_that) {
case _ApprovalPrompt():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ApprovalPrompt value)?  $default,){
final _that = this;
switch (_that) {
case _ApprovalPrompt() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String requestId,  bool requestIdIsString,  ApprovalKind kind,  String threadId,  String turnId,  String itemId,  String title,  String detail,  String command,  String cwd,  List<InputQuestion> questions)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ApprovalPrompt() when $default != null:
return $default(_that.requestId,_that.requestIdIsString,_that.kind,_that.threadId,_that.turnId,_that.itemId,_that.title,_that.detail,_that.command,_that.cwd,_that.questions);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String requestId,  bool requestIdIsString,  ApprovalKind kind,  String threadId,  String turnId,  String itemId,  String title,  String detail,  String command,  String cwd,  List<InputQuestion> questions)  $default,) {final _that = this;
switch (_that) {
case _ApprovalPrompt():
return $default(_that.requestId,_that.requestIdIsString,_that.kind,_that.threadId,_that.turnId,_that.itemId,_that.title,_that.detail,_that.command,_that.cwd,_that.questions);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String requestId,  bool requestIdIsString,  ApprovalKind kind,  String threadId,  String turnId,  String itemId,  String title,  String detail,  String command,  String cwd,  List<InputQuestion> questions)?  $default,) {final _that = this;
switch (_that) {
case _ApprovalPrompt() when $default != null:
return $default(_that.requestId,_that.requestIdIsString,_that.kind,_that.threadId,_that.turnId,_that.itemId,_that.title,_that.detail,_that.command,_that.cwd,_that.questions);case _:
  return null;

}
}

}

/// @nodoc


class _ApprovalPrompt implements ApprovalPrompt {
  const _ApprovalPrompt({required this.requestId, required this.requestIdIsString, required this.kind, required this.threadId, required this.turnId, required this.itemId, required this.title, required this.detail, this.command = '', this.cwd = '', final  List<InputQuestion> questions = const <InputQuestion>[]}): _questions = questions;
  

@override final  String requestId;
@override final  bool requestIdIsString;
@override final  ApprovalKind kind;
@override final  String threadId;
@override final  String turnId;
@override final  String itemId;
@override final  String title;
@override final  String detail;
@override@JsonKey() final  String command;
@override@JsonKey() final  String cwd;
 final  List<InputQuestion> _questions;
@override@JsonKey() List<InputQuestion> get questions {
  if (_questions is EqualUnmodifiableListView) return _questions;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_questions);
}


/// Create a copy of ApprovalPrompt
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ApprovalPromptCopyWith<_ApprovalPrompt> get copyWith => __$ApprovalPromptCopyWithImpl<_ApprovalPrompt>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ApprovalPrompt&&(identical(other.requestId, requestId) || other.requestId == requestId)&&(identical(other.requestIdIsString, requestIdIsString) || other.requestIdIsString == requestIdIsString)&&(identical(other.kind, kind) || other.kind == kind)&&(identical(other.threadId, threadId) || other.threadId == threadId)&&(identical(other.turnId, turnId) || other.turnId == turnId)&&(identical(other.itemId, itemId) || other.itemId == itemId)&&(identical(other.title, title) || other.title == title)&&(identical(other.detail, detail) || other.detail == detail)&&(identical(other.command, command) || other.command == command)&&(identical(other.cwd, cwd) || other.cwd == cwd)&&const DeepCollectionEquality().equals(other._questions, _questions));
}


@override
int get hashCode => Object.hash(runtimeType,requestId,requestIdIsString,kind,threadId,turnId,itemId,title,detail,command,cwd,const DeepCollectionEquality().hash(_questions));

@override
String toString() {
  return 'ApprovalPrompt(requestId: $requestId, requestIdIsString: $requestIdIsString, kind: $kind, threadId: $threadId, turnId: $turnId, itemId: $itemId, title: $title, detail: $detail, command: $command, cwd: $cwd, questions: $questions)';
}


}

/// @nodoc
abstract mixin class _$ApprovalPromptCopyWith<$Res> implements $ApprovalPromptCopyWith<$Res> {
  factory _$ApprovalPromptCopyWith(_ApprovalPrompt value, $Res Function(_ApprovalPrompt) _then) = __$ApprovalPromptCopyWithImpl;
@override @useResult
$Res call({
 String requestId, bool requestIdIsString, ApprovalKind kind, String threadId, String turnId, String itemId, String title, String detail, String command, String cwd, List<InputQuestion> questions
});




}
/// @nodoc
class __$ApprovalPromptCopyWithImpl<$Res>
    implements _$ApprovalPromptCopyWith<$Res> {
  __$ApprovalPromptCopyWithImpl(this._self, this._then);

  final _ApprovalPrompt _self;
  final $Res Function(_ApprovalPrompt) _then;

/// Create a copy of ApprovalPrompt
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? requestId = null,Object? requestIdIsString = null,Object? kind = null,Object? threadId = null,Object? turnId = null,Object? itemId = null,Object? title = null,Object? detail = null,Object? command = null,Object? cwd = null,Object? questions = null,}) {
  return _then(_ApprovalPrompt(
requestId: null == requestId ? _self.requestId : requestId // ignore: cast_nullable_to_non_nullable
as String,requestIdIsString: null == requestIdIsString ? _self.requestIdIsString : requestIdIsString // ignore: cast_nullable_to_non_nullable
as bool,kind: null == kind ? _self.kind : kind // ignore: cast_nullable_to_non_nullable
as ApprovalKind,threadId: null == threadId ? _self.threadId : threadId // ignore: cast_nullable_to_non_nullable
as String,turnId: null == turnId ? _self.turnId : turnId // ignore: cast_nullable_to_non_nullable
as String,itemId: null == itemId ? _self.itemId : itemId // ignore: cast_nullable_to_non_nullable
as String,title: null == title ? _self.title : title // ignore: cast_nullable_to_non_nullable
as String,detail: null == detail ? _self.detail : detail // ignore: cast_nullable_to_non_nullable
as String,command: null == command ? _self.command : command // ignore: cast_nullable_to_non_nullable
as String,cwd: null == cwd ? _self.cwd : cwd // ignore: cast_nullable_to_non_nullable
as String,questions: null == questions ? _self._questions : questions // ignore: cast_nullable_to_non_nullable
as List<InputQuestion>,
  ));
}


}

/// @nodoc
mixin _$PendingAttachment {

 String get name; String get remotePath; String get mimeType; String? get textContent;
/// Create a copy of PendingAttachment
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PendingAttachmentCopyWith<PendingAttachment> get copyWith => _$PendingAttachmentCopyWithImpl<PendingAttachment>(this as PendingAttachment, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is PendingAttachment&&(identical(other.name, name) || other.name == name)&&(identical(other.remotePath, remotePath) || other.remotePath == remotePath)&&(identical(other.mimeType, mimeType) || other.mimeType == mimeType)&&(identical(other.textContent, textContent) || other.textContent == textContent));
}


@override
int get hashCode => Object.hash(runtimeType,name,remotePath,mimeType,textContent);

@override
String toString() {
  return 'PendingAttachment(name: $name, remotePath: $remotePath, mimeType: $mimeType, textContent: $textContent)';
}


}

/// @nodoc
abstract mixin class $PendingAttachmentCopyWith<$Res>  {
  factory $PendingAttachmentCopyWith(PendingAttachment value, $Res Function(PendingAttachment) _then) = _$PendingAttachmentCopyWithImpl;
@useResult
$Res call({
 String name, String remotePath, String mimeType, String? textContent
});




}
/// @nodoc
class _$PendingAttachmentCopyWithImpl<$Res>
    implements $PendingAttachmentCopyWith<$Res> {
  _$PendingAttachmentCopyWithImpl(this._self, this._then);

  final PendingAttachment _self;
  final $Res Function(PendingAttachment) _then;

/// Create a copy of PendingAttachment
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? name = null,Object? remotePath = null,Object? mimeType = null,Object? textContent = freezed,}) {
  return _then(_self.copyWith(
name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,remotePath: null == remotePath ? _self.remotePath : remotePath // ignore: cast_nullable_to_non_nullable
as String,mimeType: null == mimeType ? _self.mimeType : mimeType // ignore: cast_nullable_to_non_nullable
as String,textContent: freezed == textContent ? _self.textContent : textContent // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// Adds pattern-matching-related methods to [PendingAttachment].
extension PendingAttachmentPatterns on PendingAttachment {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _PendingAttachment value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _PendingAttachment() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _PendingAttachment value)  $default,){
final _that = this;
switch (_that) {
case _PendingAttachment():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _PendingAttachment value)?  $default,){
final _that = this;
switch (_that) {
case _PendingAttachment() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String name,  String remotePath,  String mimeType,  String? textContent)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _PendingAttachment() when $default != null:
return $default(_that.name,_that.remotePath,_that.mimeType,_that.textContent);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String name,  String remotePath,  String mimeType,  String? textContent)  $default,) {final _that = this;
switch (_that) {
case _PendingAttachment():
return $default(_that.name,_that.remotePath,_that.mimeType,_that.textContent);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String name,  String remotePath,  String mimeType,  String? textContent)?  $default,) {final _that = this;
switch (_that) {
case _PendingAttachment() when $default != null:
return $default(_that.name,_that.remotePath,_that.mimeType,_that.textContent);case _:
  return null;

}
}

}

/// @nodoc


class _PendingAttachment implements PendingAttachment {
  const _PendingAttachment({required this.name, required this.remotePath, required this.mimeType, this.textContent});
  

@override final  String name;
@override final  String remotePath;
@override final  String mimeType;
@override final  String? textContent;

/// Create a copy of PendingAttachment
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$PendingAttachmentCopyWith<_PendingAttachment> get copyWith => __$PendingAttachmentCopyWithImpl<_PendingAttachment>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _PendingAttachment&&(identical(other.name, name) || other.name == name)&&(identical(other.remotePath, remotePath) || other.remotePath == remotePath)&&(identical(other.mimeType, mimeType) || other.mimeType == mimeType)&&(identical(other.textContent, textContent) || other.textContent == textContent));
}


@override
int get hashCode => Object.hash(runtimeType,name,remotePath,mimeType,textContent);

@override
String toString() {
  return 'PendingAttachment(name: $name, remotePath: $remotePath, mimeType: $mimeType, textContent: $textContent)';
}


}

/// @nodoc
abstract mixin class _$PendingAttachmentCopyWith<$Res> implements $PendingAttachmentCopyWith<$Res> {
  factory _$PendingAttachmentCopyWith(_PendingAttachment value, $Res Function(_PendingAttachment) _then) = __$PendingAttachmentCopyWithImpl;
@override @useResult
$Res call({
 String name, String remotePath, String mimeType, String? textContent
});




}
/// @nodoc
class __$PendingAttachmentCopyWithImpl<$Res>
    implements _$PendingAttachmentCopyWith<$Res> {
  __$PendingAttachmentCopyWithImpl(this._self, this._then);

  final _PendingAttachment _self;
  final $Res Function(_PendingAttachment) _then;

/// Create a copy of PendingAttachment
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? name = null,Object? remotePath = null,Object? mimeType = null,Object? textContent = freezed,}) {
  return _then(_PendingAttachment(
name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,remotePath: null == remotePath ? _self.remotePath : remotePath // ignore: cast_nullable_to_non_nullable
as String,mimeType: null == mimeType ? _self.mimeType : mimeType // ignore: cast_nullable_to_non_nullable
as String,textContent: freezed == textContent ? _self.textContent : textContent // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

/// @nodoc
mixin _$RemoteDirectory {

 String get name; String get path;
/// Create a copy of RemoteDirectory
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RemoteDirectoryCopyWith<RemoteDirectory> get copyWith => _$RemoteDirectoryCopyWithImpl<RemoteDirectory>(this as RemoteDirectory, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RemoteDirectory&&(identical(other.name, name) || other.name == name)&&(identical(other.path, path) || other.path == path));
}


@override
int get hashCode => Object.hash(runtimeType,name,path);

@override
String toString() {
  return 'RemoteDirectory(name: $name, path: $path)';
}


}

/// @nodoc
abstract mixin class $RemoteDirectoryCopyWith<$Res>  {
  factory $RemoteDirectoryCopyWith(RemoteDirectory value, $Res Function(RemoteDirectory) _then) = _$RemoteDirectoryCopyWithImpl;
@useResult
$Res call({
 String name, String path
});




}
/// @nodoc
class _$RemoteDirectoryCopyWithImpl<$Res>
    implements $RemoteDirectoryCopyWith<$Res> {
  _$RemoteDirectoryCopyWithImpl(this._self, this._then);

  final RemoteDirectory _self;
  final $Res Function(RemoteDirectory) _then;

/// Create a copy of RemoteDirectory
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? name = null,Object? path = null,}) {
  return _then(_self.copyWith(
name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,path: null == path ? _self.path : path // ignore: cast_nullable_to_non_nullable
as String,
  ));
}

}


/// Adds pattern-matching-related methods to [RemoteDirectory].
extension RemoteDirectoryPatterns on RemoteDirectory {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _RemoteDirectory value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _RemoteDirectory() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _RemoteDirectory value)  $default,){
final _that = this;
switch (_that) {
case _RemoteDirectory():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _RemoteDirectory value)?  $default,){
final _that = this;
switch (_that) {
case _RemoteDirectory() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String name,  String path)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _RemoteDirectory() when $default != null:
return $default(_that.name,_that.path);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String name,  String path)  $default,) {final _that = this;
switch (_that) {
case _RemoteDirectory():
return $default(_that.name,_that.path);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String name,  String path)?  $default,) {final _that = this;
switch (_that) {
case _RemoteDirectory() when $default != null:
return $default(_that.name,_that.path);case _:
  return null;

}
}

}

/// @nodoc


class _RemoteDirectory implements RemoteDirectory {
  const _RemoteDirectory({required this.name, required this.path});
  

@override final  String name;
@override final  String path;

/// Create a copy of RemoteDirectory
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$RemoteDirectoryCopyWith<_RemoteDirectory> get copyWith => __$RemoteDirectoryCopyWithImpl<_RemoteDirectory>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _RemoteDirectory&&(identical(other.name, name) || other.name == name)&&(identical(other.path, path) || other.path == path));
}


@override
int get hashCode => Object.hash(runtimeType,name,path);

@override
String toString() {
  return 'RemoteDirectory(name: $name, path: $path)';
}


}

/// @nodoc
abstract mixin class _$RemoteDirectoryCopyWith<$Res> implements $RemoteDirectoryCopyWith<$Res> {
  factory _$RemoteDirectoryCopyWith(_RemoteDirectory value, $Res Function(_RemoteDirectory) _then) = __$RemoteDirectoryCopyWithImpl;
@override @useResult
$Res call({
 String name, String path
});




}
/// @nodoc
class __$RemoteDirectoryCopyWithImpl<$Res>
    implements _$RemoteDirectoryCopyWith<$Res> {
  __$RemoteDirectoryCopyWithImpl(this._self, this._then);

  final _RemoteDirectory _self;
  final $Res Function(_RemoteDirectory) _then;

/// Create a copy of RemoteDirectory
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? name = null,Object? path = null,}) {
  return _then(_RemoteDirectory(
name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,path: null == path ? _self.path : path // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc
mixin _$RemoteDirectoryListing {

 String get currentPath; String? get parentPath; List<RemoteDirectory> get directories;
/// Create a copy of RemoteDirectoryListing
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RemoteDirectoryListingCopyWith<RemoteDirectoryListing> get copyWith => _$RemoteDirectoryListingCopyWithImpl<RemoteDirectoryListing>(this as RemoteDirectoryListing, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RemoteDirectoryListing&&(identical(other.currentPath, currentPath) || other.currentPath == currentPath)&&(identical(other.parentPath, parentPath) || other.parentPath == parentPath)&&const DeepCollectionEquality().equals(other.directories, directories));
}


@override
int get hashCode => Object.hash(runtimeType,currentPath,parentPath,const DeepCollectionEquality().hash(directories));

@override
String toString() {
  return 'RemoteDirectoryListing(currentPath: $currentPath, parentPath: $parentPath, directories: $directories)';
}


}

/// @nodoc
abstract mixin class $RemoteDirectoryListingCopyWith<$Res>  {
  factory $RemoteDirectoryListingCopyWith(RemoteDirectoryListing value, $Res Function(RemoteDirectoryListing) _then) = _$RemoteDirectoryListingCopyWithImpl;
@useResult
$Res call({
 String currentPath, String? parentPath, List<RemoteDirectory> directories
});




}
/// @nodoc
class _$RemoteDirectoryListingCopyWithImpl<$Res>
    implements $RemoteDirectoryListingCopyWith<$Res> {
  _$RemoteDirectoryListingCopyWithImpl(this._self, this._then);

  final RemoteDirectoryListing _self;
  final $Res Function(RemoteDirectoryListing) _then;

/// Create a copy of RemoteDirectoryListing
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? currentPath = null,Object? parentPath = freezed,Object? directories = null,}) {
  return _then(_self.copyWith(
currentPath: null == currentPath ? _self.currentPath : currentPath // ignore: cast_nullable_to_non_nullable
as String,parentPath: freezed == parentPath ? _self.parentPath : parentPath // ignore: cast_nullable_to_non_nullable
as String?,directories: null == directories ? _self.directories : directories // ignore: cast_nullable_to_non_nullable
as List<RemoteDirectory>,
  ));
}

}


/// Adds pattern-matching-related methods to [RemoteDirectoryListing].
extension RemoteDirectoryListingPatterns on RemoteDirectoryListing {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _RemoteDirectoryListing value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _RemoteDirectoryListing() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _RemoteDirectoryListing value)  $default,){
final _that = this;
switch (_that) {
case _RemoteDirectoryListing():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _RemoteDirectoryListing value)?  $default,){
final _that = this;
switch (_that) {
case _RemoteDirectoryListing() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String currentPath,  String? parentPath,  List<RemoteDirectory> directories)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _RemoteDirectoryListing() when $default != null:
return $default(_that.currentPath,_that.parentPath,_that.directories);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String currentPath,  String? parentPath,  List<RemoteDirectory> directories)  $default,) {final _that = this;
switch (_that) {
case _RemoteDirectoryListing():
return $default(_that.currentPath,_that.parentPath,_that.directories);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String currentPath,  String? parentPath,  List<RemoteDirectory> directories)?  $default,) {final _that = this;
switch (_that) {
case _RemoteDirectoryListing() when $default != null:
return $default(_that.currentPath,_that.parentPath,_that.directories);case _:
  return null;

}
}

}

/// @nodoc


class _RemoteDirectoryListing implements RemoteDirectoryListing {
  const _RemoteDirectoryListing({required this.currentPath, this.parentPath, final  List<RemoteDirectory> directories = const <RemoteDirectory>[]}): _directories = directories;
  

@override final  String currentPath;
@override final  String? parentPath;
 final  List<RemoteDirectory> _directories;
@override@JsonKey() List<RemoteDirectory> get directories {
  if (_directories is EqualUnmodifiableListView) return _directories;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_directories);
}


/// Create a copy of RemoteDirectoryListing
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$RemoteDirectoryListingCopyWith<_RemoteDirectoryListing> get copyWith => __$RemoteDirectoryListingCopyWithImpl<_RemoteDirectoryListing>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _RemoteDirectoryListing&&(identical(other.currentPath, currentPath) || other.currentPath == currentPath)&&(identical(other.parentPath, parentPath) || other.parentPath == parentPath)&&const DeepCollectionEquality().equals(other._directories, _directories));
}


@override
int get hashCode => Object.hash(runtimeType,currentPath,parentPath,const DeepCollectionEquality().hash(_directories));

@override
String toString() {
  return 'RemoteDirectoryListing(currentPath: $currentPath, parentPath: $parentPath, directories: $directories)';
}


}

/// @nodoc
abstract mixin class _$RemoteDirectoryListingCopyWith<$Res> implements $RemoteDirectoryListingCopyWith<$Res> {
  factory _$RemoteDirectoryListingCopyWith(_RemoteDirectoryListing value, $Res Function(_RemoteDirectoryListing) _then) = __$RemoteDirectoryListingCopyWithImpl;
@override @useResult
$Res call({
 String currentPath, String? parentPath, List<RemoteDirectory> directories
});




}
/// @nodoc
class __$RemoteDirectoryListingCopyWithImpl<$Res>
    implements _$RemoteDirectoryListingCopyWith<$Res> {
  __$RemoteDirectoryListingCopyWithImpl(this._self, this._then);

  final _RemoteDirectoryListing _self;
  final $Res Function(_RemoteDirectoryListing) _then;

/// Create a copy of RemoteDirectoryListing
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? currentPath = null,Object? parentPath = freezed,Object? directories = null,}) {
  return _then(_RemoteDirectoryListing(
currentPath: null == currentPath ? _self.currentPath : currentPath // ignore: cast_nullable_to_non_nullable
as String,parentPath: freezed == parentPath ? _self.parentPath : parentPath // ignore: cast_nullable_to_non_nullable
as String?,directories: null == directories ? _self._directories : directories // ignore: cast_nullable_to_non_nullable
as List<RemoteDirectory>,
  ));
}


}

/// @nodoc
mixin _$RemoteFileEntry {

 String get name; String get path; RemoteFileKind get kind; int get sizeBytes; int? get modifiedAtEpochMillis; String get permissions;
/// Create a copy of RemoteFileEntry
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RemoteFileEntryCopyWith<RemoteFileEntry> get copyWith => _$RemoteFileEntryCopyWithImpl<RemoteFileEntry>(this as RemoteFileEntry, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RemoteFileEntry&&(identical(other.name, name) || other.name == name)&&(identical(other.path, path) || other.path == path)&&(identical(other.kind, kind) || other.kind == kind)&&(identical(other.sizeBytes, sizeBytes) || other.sizeBytes == sizeBytes)&&(identical(other.modifiedAtEpochMillis, modifiedAtEpochMillis) || other.modifiedAtEpochMillis == modifiedAtEpochMillis)&&(identical(other.permissions, permissions) || other.permissions == permissions));
}


@override
int get hashCode => Object.hash(runtimeType,name,path,kind,sizeBytes,modifiedAtEpochMillis,permissions);

@override
String toString() {
  return 'RemoteFileEntry(name: $name, path: $path, kind: $kind, sizeBytes: $sizeBytes, modifiedAtEpochMillis: $modifiedAtEpochMillis, permissions: $permissions)';
}


}

/// @nodoc
abstract mixin class $RemoteFileEntryCopyWith<$Res>  {
  factory $RemoteFileEntryCopyWith(RemoteFileEntry value, $Res Function(RemoteFileEntry) _then) = _$RemoteFileEntryCopyWithImpl;
@useResult
$Res call({
 String name, String path, RemoteFileKind kind, int sizeBytes, int? modifiedAtEpochMillis, String permissions
});




}
/// @nodoc
class _$RemoteFileEntryCopyWithImpl<$Res>
    implements $RemoteFileEntryCopyWith<$Res> {
  _$RemoteFileEntryCopyWithImpl(this._self, this._then);

  final RemoteFileEntry _self;
  final $Res Function(RemoteFileEntry) _then;

/// Create a copy of RemoteFileEntry
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? name = null,Object? path = null,Object? kind = null,Object? sizeBytes = null,Object? modifiedAtEpochMillis = freezed,Object? permissions = null,}) {
  return _then(_self.copyWith(
name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,path: null == path ? _self.path : path // ignore: cast_nullable_to_non_nullable
as String,kind: null == kind ? _self.kind : kind // ignore: cast_nullable_to_non_nullable
as RemoteFileKind,sizeBytes: null == sizeBytes ? _self.sizeBytes : sizeBytes // ignore: cast_nullable_to_non_nullable
as int,modifiedAtEpochMillis: freezed == modifiedAtEpochMillis ? _self.modifiedAtEpochMillis : modifiedAtEpochMillis // ignore: cast_nullable_to_non_nullable
as int?,permissions: null == permissions ? _self.permissions : permissions // ignore: cast_nullable_to_non_nullable
as String,
  ));
}

}


/// Adds pattern-matching-related methods to [RemoteFileEntry].
extension RemoteFileEntryPatterns on RemoteFileEntry {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _RemoteFileEntry value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _RemoteFileEntry() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _RemoteFileEntry value)  $default,){
final _that = this;
switch (_that) {
case _RemoteFileEntry():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _RemoteFileEntry value)?  $default,){
final _that = this;
switch (_that) {
case _RemoteFileEntry() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String name,  String path,  RemoteFileKind kind,  int sizeBytes,  int? modifiedAtEpochMillis,  String permissions)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _RemoteFileEntry() when $default != null:
return $default(_that.name,_that.path,_that.kind,_that.sizeBytes,_that.modifiedAtEpochMillis,_that.permissions);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String name,  String path,  RemoteFileKind kind,  int sizeBytes,  int? modifiedAtEpochMillis,  String permissions)  $default,) {final _that = this;
switch (_that) {
case _RemoteFileEntry():
return $default(_that.name,_that.path,_that.kind,_that.sizeBytes,_that.modifiedAtEpochMillis,_that.permissions);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String name,  String path,  RemoteFileKind kind,  int sizeBytes,  int? modifiedAtEpochMillis,  String permissions)?  $default,) {final _that = this;
switch (_that) {
case _RemoteFileEntry() when $default != null:
return $default(_that.name,_that.path,_that.kind,_that.sizeBytes,_that.modifiedAtEpochMillis,_that.permissions);case _:
  return null;

}
}

}

/// @nodoc


class _RemoteFileEntry implements RemoteFileEntry {
  const _RemoteFileEntry({required this.name, required this.path, required this.kind, this.sizeBytes = 0, this.modifiedAtEpochMillis, this.permissions = ''});
  

@override final  String name;
@override final  String path;
@override final  RemoteFileKind kind;
@override@JsonKey() final  int sizeBytes;
@override final  int? modifiedAtEpochMillis;
@override@JsonKey() final  String permissions;

/// Create a copy of RemoteFileEntry
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$RemoteFileEntryCopyWith<_RemoteFileEntry> get copyWith => __$RemoteFileEntryCopyWithImpl<_RemoteFileEntry>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _RemoteFileEntry&&(identical(other.name, name) || other.name == name)&&(identical(other.path, path) || other.path == path)&&(identical(other.kind, kind) || other.kind == kind)&&(identical(other.sizeBytes, sizeBytes) || other.sizeBytes == sizeBytes)&&(identical(other.modifiedAtEpochMillis, modifiedAtEpochMillis) || other.modifiedAtEpochMillis == modifiedAtEpochMillis)&&(identical(other.permissions, permissions) || other.permissions == permissions));
}


@override
int get hashCode => Object.hash(runtimeType,name,path,kind,sizeBytes,modifiedAtEpochMillis,permissions);

@override
String toString() {
  return 'RemoteFileEntry(name: $name, path: $path, kind: $kind, sizeBytes: $sizeBytes, modifiedAtEpochMillis: $modifiedAtEpochMillis, permissions: $permissions)';
}


}

/// @nodoc
abstract mixin class _$RemoteFileEntryCopyWith<$Res> implements $RemoteFileEntryCopyWith<$Res> {
  factory _$RemoteFileEntryCopyWith(_RemoteFileEntry value, $Res Function(_RemoteFileEntry) _then) = __$RemoteFileEntryCopyWithImpl;
@override @useResult
$Res call({
 String name, String path, RemoteFileKind kind, int sizeBytes, int? modifiedAtEpochMillis, String permissions
});




}
/// @nodoc
class __$RemoteFileEntryCopyWithImpl<$Res>
    implements _$RemoteFileEntryCopyWith<$Res> {
  __$RemoteFileEntryCopyWithImpl(this._self, this._then);

  final _RemoteFileEntry _self;
  final $Res Function(_RemoteFileEntry) _then;

/// Create a copy of RemoteFileEntry
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? name = null,Object? path = null,Object? kind = null,Object? sizeBytes = null,Object? modifiedAtEpochMillis = freezed,Object? permissions = null,}) {
  return _then(_RemoteFileEntry(
name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,path: null == path ? _self.path : path // ignore: cast_nullable_to_non_nullable
as String,kind: null == kind ? _self.kind : kind // ignore: cast_nullable_to_non_nullable
as RemoteFileKind,sizeBytes: null == sizeBytes ? _self.sizeBytes : sizeBytes // ignore: cast_nullable_to_non_nullable
as int,modifiedAtEpochMillis: freezed == modifiedAtEpochMillis ? _self.modifiedAtEpochMillis : modifiedAtEpochMillis // ignore: cast_nullable_to_non_nullable
as int?,permissions: null == permissions ? _self.permissions : permissions // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc
mixin _$RemoteFileListing {

 String get currentPath; String? get parentPath; List<RemoteFileEntry> get entries;
/// Create a copy of RemoteFileListing
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RemoteFileListingCopyWith<RemoteFileListing> get copyWith => _$RemoteFileListingCopyWithImpl<RemoteFileListing>(this as RemoteFileListing, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RemoteFileListing&&(identical(other.currentPath, currentPath) || other.currentPath == currentPath)&&(identical(other.parentPath, parentPath) || other.parentPath == parentPath)&&const DeepCollectionEquality().equals(other.entries, entries));
}


@override
int get hashCode => Object.hash(runtimeType,currentPath,parentPath,const DeepCollectionEquality().hash(entries));

@override
String toString() {
  return 'RemoteFileListing(currentPath: $currentPath, parentPath: $parentPath, entries: $entries)';
}


}

/// @nodoc
abstract mixin class $RemoteFileListingCopyWith<$Res>  {
  factory $RemoteFileListingCopyWith(RemoteFileListing value, $Res Function(RemoteFileListing) _then) = _$RemoteFileListingCopyWithImpl;
@useResult
$Res call({
 String currentPath, String? parentPath, List<RemoteFileEntry> entries
});




}
/// @nodoc
class _$RemoteFileListingCopyWithImpl<$Res>
    implements $RemoteFileListingCopyWith<$Res> {
  _$RemoteFileListingCopyWithImpl(this._self, this._then);

  final RemoteFileListing _self;
  final $Res Function(RemoteFileListing) _then;

/// Create a copy of RemoteFileListing
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? currentPath = null,Object? parentPath = freezed,Object? entries = null,}) {
  return _then(_self.copyWith(
currentPath: null == currentPath ? _self.currentPath : currentPath // ignore: cast_nullable_to_non_nullable
as String,parentPath: freezed == parentPath ? _self.parentPath : parentPath // ignore: cast_nullable_to_non_nullable
as String?,entries: null == entries ? _self.entries : entries // ignore: cast_nullable_to_non_nullable
as List<RemoteFileEntry>,
  ));
}

}


/// Adds pattern-matching-related methods to [RemoteFileListing].
extension RemoteFileListingPatterns on RemoteFileListing {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _RemoteFileListing value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _RemoteFileListing() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _RemoteFileListing value)  $default,){
final _that = this;
switch (_that) {
case _RemoteFileListing():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _RemoteFileListing value)?  $default,){
final _that = this;
switch (_that) {
case _RemoteFileListing() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String currentPath,  String? parentPath,  List<RemoteFileEntry> entries)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _RemoteFileListing() when $default != null:
return $default(_that.currentPath,_that.parentPath,_that.entries);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String currentPath,  String? parentPath,  List<RemoteFileEntry> entries)  $default,) {final _that = this;
switch (_that) {
case _RemoteFileListing():
return $default(_that.currentPath,_that.parentPath,_that.entries);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String currentPath,  String? parentPath,  List<RemoteFileEntry> entries)?  $default,) {final _that = this;
switch (_that) {
case _RemoteFileListing() when $default != null:
return $default(_that.currentPath,_that.parentPath,_that.entries);case _:
  return null;

}
}

}

/// @nodoc


class _RemoteFileListing implements RemoteFileListing {
  const _RemoteFileListing({required this.currentPath, this.parentPath, final  List<RemoteFileEntry> entries = const <RemoteFileEntry>[]}): _entries = entries;
  

@override final  String currentPath;
@override final  String? parentPath;
 final  List<RemoteFileEntry> _entries;
@override@JsonKey() List<RemoteFileEntry> get entries {
  if (_entries is EqualUnmodifiableListView) return _entries;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_entries);
}


/// Create a copy of RemoteFileListing
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$RemoteFileListingCopyWith<_RemoteFileListing> get copyWith => __$RemoteFileListingCopyWithImpl<_RemoteFileListing>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _RemoteFileListing&&(identical(other.currentPath, currentPath) || other.currentPath == currentPath)&&(identical(other.parentPath, parentPath) || other.parentPath == parentPath)&&const DeepCollectionEquality().equals(other._entries, _entries));
}


@override
int get hashCode => Object.hash(runtimeType,currentPath,parentPath,const DeepCollectionEquality().hash(_entries));

@override
String toString() {
  return 'RemoteFileListing(currentPath: $currentPath, parentPath: $parentPath, entries: $entries)';
}


}

/// @nodoc
abstract mixin class _$RemoteFileListingCopyWith<$Res> implements $RemoteFileListingCopyWith<$Res> {
  factory _$RemoteFileListingCopyWith(_RemoteFileListing value, $Res Function(_RemoteFileListing) _then) = __$RemoteFileListingCopyWithImpl;
@override @useResult
$Res call({
 String currentPath, String? parentPath, List<RemoteFileEntry> entries
});




}
/// @nodoc
class __$RemoteFileListingCopyWithImpl<$Res>
    implements _$RemoteFileListingCopyWith<$Res> {
  __$RemoteFileListingCopyWithImpl(this._self, this._then);

  final _RemoteFileListing _self;
  final $Res Function(_RemoteFileListing) _then;

/// Create a copy of RemoteFileListing
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? currentPath = null,Object? parentPath = freezed,Object? entries = null,}) {
  return _then(_RemoteFileListing(
currentPath: null == currentPath ? _self.currentPath : currentPath // ignore: cast_nullable_to_non_nullable
as String,parentPath: freezed == parentPath ? _self.parentPath : parentPath // ignore: cast_nullable_to_non_nullable
as String?,entries: null == entries ? _self._entries : entries // ignore: cast_nullable_to_non_nullable
as List<RemoteFileEntry>,
  ));
}


}

/// @nodoc
mixin _$RemoteFileClipboard {

 List<RemoteFileEntry> get entries; RemoteFileTransferMode get mode;
/// Create a copy of RemoteFileClipboard
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RemoteFileClipboardCopyWith<RemoteFileClipboard> get copyWith => _$RemoteFileClipboardCopyWithImpl<RemoteFileClipboard>(this as RemoteFileClipboard, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RemoteFileClipboard&&const DeepCollectionEquality().equals(other.entries, entries)&&(identical(other.mode, mode) || other.mode == mode));
}


@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(entries),mode);

@override
String toString() {
  return 'RemoteFileClipboard(entries: $entries, mode: $mode)';
}


}

/// @nodoc
abstract mixin class $RemoteFileClipboardCopyWith<$Res>  {
  factory $RemoteFileClipboardCopyWith(RemoteFileClipboard value, $Res Function(RemoteFileClipboard) _then) = _$RemoteFileClipboardCopyWithImpl;
@useResult
$Res call({
 List<RemoteFileEntry> entries, RemoteFileTransferMode mode
});




}
/// @nodoc
class _$RemoteFileClipboardCopyWithImpl<$Res>
    implements $RemoteFileClipboardCopyWith<$Res> {
  _$RemoteFileClipboardCopyWithImpl(this._self, this._then);

  final RemoteFileClipboard _self;
  final $Res Function(RemoteFileClipboard) _then;

/// Create a copy of RemoteFileClipboard
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? entries = null,Object? mode = null,}) {
  return _then(_self.copyWith(
entries: null == entries ? _self.entries : entries // ignore: cast_nullable_to_non_nullable
as List<RemoteFileEntry>,mode: null == mode ? _self.mode : mode // ignore: cast_nullable_to_non_nullable
as RemoteFileTransferMode,
  ));
}

}


/// Adds pattern-matching-related methods to [RemoteFileClipboard].
extension RemoteFileClipboardPatterns on RemoteFileClipboard {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _RemoteFileClipboard value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _RemoteFileClipboard() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _RemoteFileClipboard value)  $default,){
final _that = this;
switch (_that) {
case _RemoteFileClipboard():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _RemoteFileClipboard value)?  $default,){
final _that = this;
switch (_that) {
case _RemoteFileClipboard() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( List<RemoteFileEntry> entries,  RemoteFileTransferMode mode)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _RemoteFileClipboard() when $default != null:
return $default(_that.entries,_that.mode);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( List<RemoteFileEntry> entries,  RemoteFileTransferMode mode)  $default,) {final _that = this;
switch (_that) {
case _RemoteFileClipboard():
return $default(_that.entries,_that.mode);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( List<RemoteFileEntry> entries,  RemoteFileTransferMode mode)?  $default,) {final _that = this;
switch (_that) {
case _RemoteFileClipboard() when $default != null:
return $default(_that.entries,_that.mode);case _:
  return null;

}
}

}

/// @nodoc


class _RemoteFileClipboard implements RemoteFileClipboard {
  const _RemoteFileClipboard({required final  List<RemoteFileEntry> entries, required this.mode}): _entries = entries;
  

 final  List<RemoteFileEntry> _entries;
@override List<RemoteFileEntry> get entries {
  if (_entries is EqualUnmodifiableListView) return _entries;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_entries);
}

@override final  RemoteFileTransferMode mode;

/// Create a copy of RemoteFileClipboard
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$RemoteFileClipboardCopyWith<_RemoteFileClipboard> get copyWith => __$RemoteFileClipboardCopyWithImpl<_RemoteFileClipboard>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _RemoteFileClipboard&&const DeepCollectionEquality().equals(other._entries, _entries)&&(identical(other.mode, mode) || other.mode == mode));
}


@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(_entries),mode);

@override
String toString() {
  return 'RemoteFileClipboard(entries: $entries, mode: $mode)';
}


}

/// @nodoc
abstract mixin class _$RemoteFileClipboardCopyWith<$Res> implements $RemoteFileClipboardCopyWith<$Res> {
  factory _$RemoteFileClipboardCopyWith(_RemoteFileClipboard value, $Res Function(_RemoteFileClipboard) _then) = __$RemoteFileClipboardCopyWithImpl;
@override @useResult
$Res call({
 List<RemoteFileEntry> entries, RemoteFileTransferMode mode
});




}
/// @nodoc
class __$RemoteFileClipboardCopyWithImpl<$Res>
    implements _$RemoteFileClipboardCopyWith<$Res> {
  __$RemoteFileClipboardCopyWithImpl(this._self, this._then);

  final _RemoteFileClipboard _self;
  final $Res Function(_RemoteFileClipboard) _then;

/// Create a copy of RemoteFileClipboard
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? entries = null,Object? mode = null,}) {
  return _then(_RemoteFileClipboard(
entries: null == entries ? _self._entries : entries // ignore: cast_nullable_to_non_nullable
as List<RemoteFileEntry>,mode: null == mode ? _self.mode : mode // ignore: cast_nullable_to_non_nullable
as RemoteFileTransferMode,
  ));
}


}

/// @nodoc
mixin _$RemoteSetupPrompt {

 String get title; String get detail; String get os; String get architecture; String get home; String? get detectedVersion; AgentKind get agent;
/// Create a copy of RemoteSetupPrompt
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RemoteSetupPromptCopyWith<RemoteSetupPrompt> get copyWith => _$RemoteSetupPromptCopyWithImpl<RemoteSetupPrompt>(this as RemoteSetupPrompt, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RemoteSetupPrompt&&(identical(other.title, title) || other.title == title)&&(identical(other.detail, detail) || other.detail == detail)&&(identical(other.os, os) || other.os == os)&&(identical(other.architecture, architecture) || other.architecture == architecture)&&(identical(other.home, home) || other.home == home)&&(identical(other.detectedVersion, detectedVersion) || other.detectedVersion == detectedVersion)&&(identical(other.agent, agent) || other.agent == agent));
}


@override
int get hashCode => Object.hash(runtimeType,title,detail,os,architecture,home,detectedVersion,agent);

@override
String toString() {
  return 'RemoteSetupPrompt(title: $title, detail: $detail, os: $os, architecture: $architecture, home: $home, detectedVersion: $detectedVersion, agent: $agent)';
}


}

/// @nodoc
abstract mixin class $RemoteSetupPromptCopyWith<$Res>  {
  factory $RemoteSetupPromptCopyWith(RemoteSetupPrompt value, $Res Function(RemoteSetupPrompt) _then) = _$RemoteSetupPromptCopyWithImpl;
@useResult
$Res call({
 String title, String detail, String os, String architecture, String home, String? detectedVersion, AgentKind agent
});




}
/// @nodoc
class _$RemoteSetupPromptCopyWithImpl<$Res>
    implements $RemoteSetupPromptCopyWith<$Res> {
  _$RemoteSetupPromptCopyWithImpl(this._self, this._then);

  final RemoteSetupPrompt _self;
  final $Res Function(RemoteSetupPrompt) _then;

/// Create a copy of RemoteSetupPrompt
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? title = null,Object? detail = null,Object? os = null,Object? architecture = null,Object? home = null,Object? detectedVersion = freezed,Object? agent = null,}) {
  return _then(_self.copyWith(
title: null == title ? _self.title : title // ignore: cast_nullable_to_non_nullable
as String,detail: null == detail ? _self.detail : detail // ignore: cast_nullable_to_non_nullable
as String,os: null == os ? _self.os : os // ignore: cast_nullable_to_non_nullable
as String,architecture: null == architecture ? _self.architecture : architecture // ignore: cast_nullable_to_non_nullable
as String,home: null == home ? _self.home : home // ignore: cast_nullable_to_non_nullable
as String,detectedVersion: freezed == detectedVersion ? _self.detectedVersion : detectedVersion // ignore: cast_nullable_to_non_nullable
as String?,agent: null == agent ? _self.agent : agent // ignore: cast_nullable_to_non_nullable
as AgentKind,
  ));
}

}


/// Adds pattern-matching-related methods to [RemoteSetupPrompt].
extension RemoteSetupPromptPatterns on RemoteSetupPrompt {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _RemoteSetupPrompt value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _RemoteSetupPrompt() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _RemoteSetupPrompt value)  $default,){
final _that = this;
switch (_that) {
case _RemoteSetupPrompt():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _RemoteSetupPrompt value)?  $default,){
final _that = this;
switch (_that) {
case _RemoteSetupPrompt() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String title,  String detail,  String os,  String architecture,  String home,  String? detectedVersion,  AgentKind agent)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _RemoteSetupPrompt() when $default != null:
return $default(_that.title,_that.detail,_that.os,_that.architecture,_that.home,_that.detectedVersion,_that.agent);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String title,  String detail,  String os,  String architecture,  String home,  String? detectedVersion,  AgentKind agent)  $default,) {final _that = this;
switch (_that) {
case _RemoteSetupPrompt():
return $default(_that.title,_that.detail,_that.os,_that.architecture,_that.home,_that.detectedVersion,_that.agent);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String title,  String detail,  String os,  String architecture,  String home,  String? detectedVersion,  AgentKind agent)?  $default,) {final _that = this;
switch (_that) {
case _RemoteSetupPrompt() when $default != null:
return $default(_that.title,_that.detail,_that.os,_that.architecture,_that.home,_that.detectedVersion,_that.agent);case _:
  return null;

}
}

}

/// @nodoc


class _RemoteSetupPrompt implements RemoteSetupPrompt {
  const _RemoteSetupPrompt({required this.title, required this.detail, required this.os, required this.architecture, required this.home, this.detectedVersion, this.agent = AgentKind.codex});
  

@override final  String title;
@override final  String detail;
@override final  String os;
@override final  String architecture;
@override final  String home;
@override final  String? detectedVersion;
@override@JsonKey() final  AgentKind agent;

/// Create a copy of RemoteSetupPrompt
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$RemoteSetupPromptCopyWith<_RemoteSetupPrompt> get copyWith => __$RemoteSetupPromptCopyWithImpl<_RemoteSetupPrompt>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _RemoteSetupPrompt&&(identical(other.title, title) || other.title == title)&&(identical(other.detail, detail) || other.detail == detail)&&(identical(other.os, os) || other.os == os)&&(identical(other.architecture, architecture) || other.architecture == architecture)&&(identical(other.home, home) || other.home == home)&&(identical(other.detectedVersion, detectedVersion) || other.detectedVersion == detectedVersion)&&(identical(other.agent, agent) || other.agent == agent));
}


@override
int get hashCode => Object.hash(runtimeType,title,detail,os,architecture,home,detectedVersion,agent);

@override
String toString() {
  return 'RemoteSetupPrompt(title: $title, detail: $detail, os: $os, architecture: $architecture, home: $home, detectedVersion: $detectedVersion, agent: $agent)';
}


}

/// @nodoc
abstract mixin class _$RemoteSetupPromptCopyWith<$Res> implements $RemoteSetupPromptCopyWith<$Res> {
  factory _$RemoteSetupPromptCopyWith(_RemoteSetupPrompt value, $Res Function(_RemoteSetupPrompt) _then) = __$RemoteSetupPromptCopyWithImpl;
@override @useResult
$Res call({
 String title, String detail, String os, String architecture, String home, String? detectedVersion, AgentKind agent
});




}
/// @nodoc
class __$RemoteSetupPromptCopyWithImpl<$Res>
    implements _$RemoteSetupPromptCopyWith<$Res> {
  __$RemoteSetupPromptCopyWithImpl(this._self, this._then);

  final _RemoteSetupPrompt _self;
  final $Res Function(_RemoteSetupPrompt) _then;

/// Create a copy of RemoteSetupPrompt
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? title = null,Object? detail = null,Object? os = null,Object? architecture = null,Object? home = null,Object? detectedVersion = freezed,Object? agent = null,}) {
  return _then(_RemoteSetupPrompt(
title: null == title ? _self.title : title // ignore: cast_nullable_to_non_nullable
as String,detail: null == detail ? _self.detail : detail // ignore: cast_nullable_to_non_nullable
as String,os: null == os ? _self.os : os // ignore: cast_nullable_to_non_nullable
as String,architecture: null == architecture ? _self.architecture : architecture // ignore: cast_nullable_to_non_nullable
as String,home: null == home ? _self.home : home // ignore: cast_nullable_to_non_nullable
as String,detectedVersion: freezed == detectedVersion ? _self.detectedVersion : detectedVersion // ignore: cast_nullable_to_non_nullable
as String?,agent: null == agent ? _self.agent : agent // ignore: cast_nullable_to_non_nullable
as AgentKind,
  ));
}


}

/// @nodoc
mixin _$AgentSetupState {

 RemoteSetupPrompt? get prompt; bool get inProgress; String get progress; int get percent; String get detail; int? get downloadPercent; bool get minimized;
/// Create a copy of AgentSetupState
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AgentSetupStateCopyWith<AgentSetupState> get copyWith => _$AgentSetupStateCopyWithImpl<AgentSetupState>(this as AgentSetupState, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AgentSetupState&&(identical(other.prompt, prompt) || other.prompt == prompt)&&(identical(other.inProgress, inProgress) || other.inProgress == inProgress)&&(identical(other.progress, progress) || other.progress == progress)&&(identical(other.percent, percent) || other.percent == percent)&&(identical(other.detail, detail) || other.detail == detail)&&(identical(other.downloadPercent, downloadPercent) || other.downloadPercent == downloadPercent)&&(identical(other.minimized, minimized) || other.minimized == minimized));
}


@override
int get hashCode => Object.hash(runtimeType,prompt,inProgress,progress,percent,detail,downloadPercent,minimized);

@override
String toString() {
  return 'AgentSetupState(prompt: $prompt, inProgress: $inProgress, progress: $progress, percent: $percent, detail: $detail, downloadPercent: $downloadPercent, minimized: $minimized)';
}


}

/// @nodoc
abstract mixin class $AgentSetupStateCopyWith<$Res>  {
  factory $AgentSetupStateCopyWith(AgentSetupState value, $Res Function(AgentSetupState) _then) = _$AgentSetupStateCopyWithImpl;
@useResult
$Res call({
 RemoteSetupPrompt? prompt, bool inProgress, String progress, int percent, String detail, int? downloadPercent, bool minimized
});


$RemoteSetupPromptCopyWith<$Res>? get prompt;

}
/// @nodoc
class _$AgentSetupStateCopyWithImpl<$Res>
    implements $AgentSetupStateCopyWith<$Res> {
  _$AgentSetupStateCopyWithImpl(this._self, this._then);

  final AgentSetupState _self;
  final $Res Function(AgentSetupState) _then;

/// Create a copy of AgentSetupState
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? prompt = freezed,Object? inProgress = null,Object? progress = null,Object? percent = null,Object? detail = null,Object? downloadPercent = freezed,Object? minimized = null,}) {
  return _then(_self.copyWith(
prompt: freezed == prompt ? _self.prompt : prompt // ignore: cast_nullable_to_non_nullable
as RemoteSetupPrompt?,inProgress: null == inProgress ? _self.inProgress : inProgress // ignore: cast_nullable_to_non_nullable
as bool,progress: null == progress ? _self.progress : progress // ignore: cast_nullable_to_non_nullable
as String,percent: null == percent ? _self.percent : percent // ignore: cast_nullable_to_non_nullable
as int,detail: null == detail ? _self.detail : detail // ignore: cast_nullable_to_non_nullable
as String,downloadPercent: freezed == downloadPercent ? _self.downloadPercent : downloadPercent // ignore: cast_nullable_to_non_nullable
as int?,minimized: null == minimized ? _self.minimized : minimized // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}
/// Create a copy of AgentSetupState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$RemoteSetupPromptCopyWith<$Res>? get prompt {
    if (_self.prompt == null) {
    return null;
  }

  return $RemoteSetupPromptCopyWith<$Res>(_self.prompt!, (value) {
    return _then(_self.copyWith(prompt: value));
  });
}
}


/// Adds pattern-matching-related methods to [AgentSetupState].
extension AgentSetupStatePatterns on AgentSetupState {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _AgentSetupState value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _AgentSetupState() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _AgentSetupState value)  $default,){
final _that = this;
switch (_that) {
case _AgentSetupState():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _AgentSetupState value)?  $default,){
final _that = this;
switch (_that) {
case _AgentSetupState() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( RemoteSetupPrompt? prompt,  bool inProgress,  String progress,  int percent,  String detail,  int? downloadPercent,  bool minimized)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _AgentSetupState() when $default != null:
return $default(_that.prompt,_that.inProgress,_that.progress,_that.percent,_that.detail,_that.downloadPercent,_that.minimized);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( RemoteSetupPrompt? prompt,  bool inProgress,  String progress,  int percent,  String detail,  int? downloadPercent,  bool minimized)  $default,) {final _that = this;
switch (_that) {
case _AgentSetupState():
return $default(_that.prompt,_that.inProgress,_that.progress,_that.percent,_that.detail,_that.downloadPercent,_that.minimized);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( RemoteSetupPrompt? prompt,  bool inProgress,  String progress,  int percent,  String detail,  int? downloadPercent,  bool minimized)?  $default,) {final _that = this;
switch (_that) {
case _AgentSetupState() when $default != null:
return $default(_that.prompt,_that.inProgress,_that.progress,_that.percent,_that.detail,_that.downloadPercent,_that.minimized);case _:
  return null;

}
}

}

/// @nodoc


class _AgentSetupState implements AgentSetupState {
  const _AgentSetupState({this.prompt, this.inProgress = false, this.progress = '', this.percent = 0, this.detail = '', this.downloadPercent, this.minimized = false});
  

@override final  RemoteSetupPrompt? prompt;
@override@JsonKey() final  bool inProgress;
@override@JsonKey() final  String progress;
@override@JsonKey() final  int percent;
@override@JsonKey() final  String detail;
@override final  int? downloadPercent;
@override@JsonKey() final  bool minimized;

/// Create a copy of AgentSetupState
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$AgentSetupStateCopyWith<_AgentSetupState> get copyWith => __$AgentSetupStateCopyWithImpl<_AgentSetupState>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _AgentSetupState&&(identical(other.prompt, prompt) || other.prompt == prompt)&&(identical(other.inProgress, inProgress) || other.inProgress == inProgress)&&(identical(other.progress, progress) || other.progress == progress)&&(identical(other.percent, percent) || other.percent == percent)&&(identical(other.detail, detail) || other.detail == detail)&&(identical(other.downloadPercent, downloadPercent) || other.downloadPercent == downloadPercent)&&(identical(other.minimized, minimized) || other.minimized == minimized));
}


@override
int get hashCode => Object.hash(runtimeType,prompt,inProgress,progress,percent,detail,downloadPercent,minimized);

@override
String toString() {
  return 'AgentSetupState(prompt: $prompt, inProgress: $inProgress, progress: $progress, percent: $percent, detail: $detail, downloadPercent: $downloadPercent, minimized: $minimized)';
}


}

/// @nodoc
abstract mixin class _$AgentSetupStateCopyWith<$Res> implements $AgentSetupStateCopyWith<$Res> {
  factory _$AgentSetupStateCopyWith(_AgentSetupState value, $Res Function(_AgentSetupState) _then) = __$AgentSetupStateCopyWithImpl;
@override @useResult
$Res call({
 RemoteSetupPrompt? prompt, bool inProgress, String progress, int percent, String detail, int? downloadPercent, bool minimized
});


@override $RemoteSetupPromptCopyWith<$Res>? get prompt;

}
/// @nodoc
class __$AgentSetupStateCopyWithImpl<$Res>
    implements _$AgentSetupStateCopyWith<$Res> {
  __$AgentSetupStateCopyWithImpl(this._self, this._then);

  final _AgentSetupState _self;
  final $Res Function(_AgentSetupState) _then;

/// Create a copy of AgentSetupState
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? prompt = freezed,Object? inProgress = null,Object? progress = null,Object? percent = null,Object? detail = null,Object? downloadPercent = freezed,Object? minimized = null,}) {
  return _then(_AgentSetupState(
prompt: freezed == prompt ? _self.prompt : prompt // ignore: cast_nullable_to_non_nullable
as RemoteSetupPrompt?,inProgress: null == inProgress ? _self.inProgress : inProgress // ignore: cast_nullable_to_non_nullable
as bool,progress: null == progress ? _self.progress : progress // ignore: cast_nullable_to_non_nullable
as String,percent: null == percent ? _self.percent : percent // ignore: cast_nullable_to_non_nullable
as int,detail: null == detail ? _self.detail : detail // ignore: cast_nullable_to_non_nullable
as String,downloadPercent: freezed == downloadPercent ? _self.downloadPercent : downloadPercent // ignore: cast_nullable_to_non_nullable
as int?,minimized: null == minimized ? _self.minimized : minimized // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}

/// Create a copy of AgentSetupState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$RemoteSetupPromptCopyWith<$Res>? get prompt {
    if (_self.prompt == null) {
    return null;
  }

  return $RemoteSetupPromptCopyWith<$Res>(_self.prompt!, (value) {
    return _then(_self.copyWith(prompt: value));
  });
}
}

/// @nodoc
mixin _$AgentGlobalSettings {

 String get baseUrl; String get model; String get reasoningEffort; String get modelProvider; bool get hasStoredAuthentication; String get apiKey; String get proxyUrl;
/// Create a copy of AgentGlobalSettings
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AgentGlobalSettingsCopyWith<AgentGlobalSettings> get copyWith => _$AgentGlobalSettingsCopyWithImpl<AgentGlobalSettings>(this as AgentGlobalSettings, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AgentGlobalSettings&&(identical(other.baseUrl, baseUrl) || other.baseUrl == baseUrl)&&(identical(other.model, model) || other.model == model)&&(identical(other.reasoningEffort, reasoningEffort) || other.reasoningEffort == reasoningEffort)&&(identical(other.modelProvider, modelProvider) || other.modelProvider == modelProvider)&&(identical(other.hasStoredAuthentication, hasStoredAuthentication) || other.hasStoredAuthentication == hasStoredAuthentication)&&(identical(other.apiKey, apiKey) || other.apiKey == apiKey)&&(identical(other.proxyUrl, proxyUrl) || other.proxyUrl == proxyUrl));
}


@override
int get hashCode => Object.hash(runtimeType,baseUrl,model,reasoningEffort,modelProvider,hasStoredAuthentication,apiKey,proxyUrl);

@override
String toString() {
  return 'AgentGlobalSettings(baseUrl: $baseUrl, model: $model, reasoningEffort: $reasoningEffort, modelProvider: $modelProvider, hasStoredAuthentication: $hasStoredAuthentication, apiKey: $apiKey, proxyUrl: $proxyUrl)';
}


}

/// @nodoc
abstract mixin class $AgentGlobalSettingsCopyWith<$Res>  {
  factory $AgentGlobalSettingsCopyWith(AgentGlobalSettings value, $Res Function(AgentGlobalSettings) _then) = _$AgentGlobalSettingsCopyWithImpl;
@useResult
$Res call({
 String baseUrl, String model, String reasoningEffort, String modelProvider, bool hasStoredAuthentication, String apiKey, String proxyUrl
});




}
/// @nodoc
class _$AgentGlobalSettingsCopyWithImpl<$Res>
    implements $AgentGlobalSettingsCopyWith<$Res> {
  _$AgentGlobalSettingsCopyWithImpl(this._self, this._then);

  final AgentGlobalSettings _self;
  final $Res Function(AgentGlobalSettings) _then;

/// Create a copy of AgentGlobalSettings
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? baseUrl = null,Object? model = null,Object? reasoningEffort = null,Object? modelProvider = null,Object? hasStoredAuthentication = null,Object? apiKey = null,Object? proxyUrl = null,}) {
  return _then(_self.copyWith(
baseUrl: null == baseUrl ? _self.baseUrl : baseUrl // ignore: cast_nullable_to_non_nullable
as String,model: null == model ? _self.model : model // ignore: cast_nullable_to_non_nullable
as String,reasoningEffort: null == reasoningEffort ? _self.reasoningEffort : reasoningEffort // ignore: cast_nullable_to_non_nullable
as String,modelProvider: null == modelProvider ? _self.modelProvider : modelProvider // ignore: cast_nullable_to_non_nullable
as String,hasStoredAuthentication: null == hasStoredAuthentication ? _self.hasStoredAuthentication : hasStoredAuthentication // ignore: cast_nullable_to_non_nullable
as bool,apiKey: null == apiKey ? _self.apiKey : apiKey // ignore: cast_nullable_to_non_nullable
as String,proxyUrl: null == proxyUrl ? _self.proxyUrl : proxyUrl // ignore: cast_nullable_to_non_nullable
as String,
  ));
}

}


/// Adds pattern-matching-related methods to [AgentGlobalSettings].
extension AgentGlobalSettingsPatterns on AgentGlobalSettings {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _AgentGlobalSettings value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _AgentGlobalSettings() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _AgentGlobalSettings value)  $default,){
final _that = this;
switch (_that) {
case _AgentGlobalSettings():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _AgentGlobalSettings value)?  $default,){
final _that = this;
switch (_that) {
case _AgentGlobalSettings() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String baseUrl,  String model,  String reasoningEffort,  String modelProvider,  bool hasStoredAuthentication,  String apiKey,  String proxyUrl)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _AgentGlobalSettings() when $default != null:
return $default(_that.baseUrl,_that.model,_that.reasoningEffort,_that.modelProvider,_that.hasStoredAuthentication,_that.apiKey,_that.proxyUrl);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String baseUrl,  String model,  String reasoningEffort,  String modelProvider,  bool hasStoredAuthentication,  String apiKey,  String proxyUrl)  $default,) {final _that = this;
switch (_that) {
case _AgentGlobalSettings():
return $default(_that.baseUrl,_that.model,_that.reasoningEffort,_that.modelProvider,_that.hasStoredAuthentication,_that.apiKey,_that.proxyUrl);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String baseUrl,  String model,  String reasoningEffort,  String modelProvider,  bool hasStoredAuthentication,  String apiKey,  String proxyUrl)?  $default,) {final _that = this;
switch (_that) {
case _AgentGlobalSettings() when $default != null:
return $default(_that.baseUrl,_that.model,_that.reasoningEffort,_that.modelProvider,_that.hasStoredAuthentication,_that.apiKey,_that.proxyUrl);case _:
  return null;

}
}

}

/// @nodoc


class _AgentGlobalSettings implements AgentGlobalSettings {
  const _AgentGlobalSettings({this.baseUrl = '', this.model = '', this.reasoningEffort = '', this.modelProvider = 'openai', this.hasStoredAuthentication = false, this.apiKey = '', this.proxyUrl = ''});
  

@override@JsonKey() final  String baseUrl;
@override@JsonKey() final  String model;
@override@JsonKey() final  String reasoningEffort;
@override@JsonKey() final  String modelProvider;
@override@JsonKey() final  bool hasStoredAuthentication;
@override@JsonKey() final  String apiKey;
@override@JsonKey() final  String proxyUrl;

/// Create a copy of AgentGlobalSettings
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$AgentGlobalSettingsCopyWith<_AgentGlobalSettings> get copyWith => __$AgentGlobalSettingsCopyWithImpl<_AgentGlobalSettings>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _AgentGlobalSettings&&(identical(other.baseUrl, baseUrl) || other.baseUrl == baseUrl)&&(identical(other.model, model) || other.model == model)&&(identical(other.reasoningEffort, reasoningEffort) || other.reasoningEffort == reasoningEffort)&&(identical(other.modelProvider, modelProvider) || other.modelProvider == modelProvider)&&(identical(other.hasStoredAuthentication, hasStoredAuthentication) || other.hasStoredAuthentication == hasStoredAuthentication)&&(identical(other.apiKey, apiKey) || other.apiKey == apiKey)&&(identical(other.proxyUrl, proxyUrl) || other.proxyUrl == proxyUrl));
}


@override
int get hashCode => Object.hash(runtimeType,baseUrl,model,reasoningEffort,modelProvider,hasStoredAuthentication,apiKey,proxyUrl);

@override
String toString() {
  return 'AgentGlobalSettings(baseUrl: $baseUrl, model: $model, reasoningEffort: $reasoningEffort, modelProvider: $modelProvider, hasStoredAuthentication: $hasStoredAuthentication, apiKey: $apiKey, proxyUrl: $proxyUrl)';
}


}

/// @nodoc
abstract mixin class _$AgentGlobalSettingsCopyWith<$Res> implements $AgentGlobalSettingsCopyWith<$Res> {
  factory _$AgentGlobalSettingsCopyWith(_AgentGlobalSettings value, $Res Function(_AgentGlobalSettings) _then) = __$AgentGlobalSettingsCopyWithImpl;
@override @useResult
$Res call({
 String baseUrl, String model, String reasoningEffort, String modelProvider, bool hasStoredAuthentication, String apiKey, String proxyUrl
});




}
/// @nodoc
class __$AgentGlobalSettingsCopyWithImpl<$Res>
    implements _$AgentGlobalSettingsCopyWith<$Res> {
  __$AgentGlobalSettingsCopyWithImpl(this._self, this._then);

  final _AgentGlobalSettings _self;
  final $Res Function(_AgentGlobalSettings) _then;

/// Create a copy of AgentGlobalSettings
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? baseUrl = null,Object? model = null,Object? reasoningEffort = null,Object? modelProvider = null,Object? hasStoredAuthentication = null,Object? apiKey = null,Object? proxyUrl = null,}) {
  return _then(_AgentGlobalSettings(
baseUrl: null == baseUrl ? _self.baseUrl : baseUrl // ignore: cast_nullable_to_non_nullable
as String,model: null == model ? _self.model : model // ignore: cast_nullable_to_non_nullable
as String,reasoningEffort: null == reasoningEffort ? _self.reasoningEffort : reasoningEffort // ignore: cast_nullable_to_non_nullable
as String,modelProvider: null == modelProvider ? _self.modelProvider : modelProvider // ignore: cast_nullable_to_non_nullable
as String,hasStoredAuthentication: null == hasStoredAuthentication ? _self.hasStoredAuthentication : hasStoredAuthentication // ignore: cast_nullable_to_non_nullable
as bool,apiKey: null == apiKey ? _self.apiKey : apiKey // ignore: cast_nullable_to_non_nullable
as String,proxyUrl: null == proxyUrl ? _self.proxyUrl : proxyUrl // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc
mixin _$AgentConnectionTestResult {

 bool get successful; String get message;
/// Create a copy of AgentConnectionTestResult
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AgentConnectionTestResultCopyWith<AgentConnectionTestResult> get copyWith => _$AgentConnectionTestResultCopyWithImpl<AgentConnectionTestResult>(this as AgentConnectionTestResult, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AgentConnectionTestResult&&(identical(other.successful, successful) || other.successful == successful)&&(identical(other.message, message) || other.message == message));
}


@override
int get hashCode => Object.hash(runtimeType,successful,message);

@override
String toString() {
  return 'AgentConnectionTestResult(successful: $successful, message: $message)';
}


}

/// @nodoc
abstract mixin class $AgentConnectionTestResultCopyWith<$Res>  {
  factory $AgentConnectionTestResultCopyWith(AgentConnectionTestResult value, $Res Function(AgentConnectionTestResult) _then) = _$AgentConnectionTestResultCopyWithImpl;
@useResult
$Res call({
 bool successful, String message
});




}
/// @nodoc
class _$AgentConnectionTestResultCopyWithImpl<$Res>
    implements $AgentConnectionTestResultCopyWith<$Res> {
  _$AgentConnectionTestResultCopyWithImpl(this._self, this._then);

  final AgentConnectionTestResult _self;
  final $Res Function(AgentConnectionTestResult) _then;

/// Create a copy of AgentConnectionTestResult
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? successful = null,Object? message = null,}) {
  return _then(_self.copyWith(
successful: null == successful ? _self.successful : successful // ignore: cast_nullable_to_non_nullable
as bool,message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,
  ));
}

}


/// Adds pattern-matching-related methods to [AgentConnectionTestResult].
extension AgentConnectionTestResultPatterns on AgentConnectionTestResult {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _AgentConnectionTestResult value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _AgentConnectionTestResult() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _AgentConnectionTestResult value)  $default,){
final _that = this;
switch (_that) {
case _AgentConnectionTestResult():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _AgentConnectionTestResult value)?  $default,){
final _that = this;
switch (_that) {
case _AgentConnectionTestResult() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( bool successful,  String message)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _AgentConnectionTestResult() when $default != null:
return $default(_that.successful,_that.message);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( bool successful,  String message)  $default,) {final _that = this;
switch (_that) {
case _AgentConnectionTestResult():
return $default(_that.successful,_that.message);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( bool successful,  String message)?  $default,) {final _that = this;
switch (_that) {
case _AgentConnectionTestResult() when $default != null:
return $default(_that.successful,_that.message);case _:
  return null;

}
}

}

/// @nodoc


class _AgentConnectionTestResult implements AgentConnectionTestResult {
  const _AgentConnectionTestResult({required this.successful, required this.message});
  

@override final  bool successful;
@override final  String message;

/// Create a copy of AgentConnectionTestResult
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$AgentConnectionTestResultCopyWith<_AgentConnectionTestResult> get copyWith => __$AgentConnectionTestResultCopyWithImpl<_AgentConnectionTestResult>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _AgentConnectionTestResult&&(identical(other.successful, successful) || other.successful == successful)&&(identical(other.message, message) || other.message == message));
}


@override
int get hashCode => Object.hash(runtimeType,successful,message);

@override
String toString() {
  return 'AgentConnectionTestResult(successful: $successful, message: $message)';
}


}

/// @nodoc
abstract mixin class _$AgentConnectionTestResultCopyWith<$Res> implements $AgentConnectionTestResultCopyWith<$Res> {
  factory _$AgentConnectionTestResultCopyWith(_AgentConnectionTestResult value, $Res Function(_AgentConnectionTestResult) _then) = __$AgentConnectionTestResultCopyWithImpl;
@override @useResult
$Res call({
 bool successful, String message
});




}
/// @nodoc
class __$AgentConnectionTestResultCopyWithImpl<$Res>
    implements _$AgentConnectionTestResultCopyWith<$Res> {
  __$AgentConnectionTestResultCopyWithImpl(this._self, this._then);

  final _AgentConnectionTestResult _self;
  final $Res Function(_AgentConnectionTestResult) _then;

/// Create a copy of AgentConnectionTestResult
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? successful = null,Object? message = null,}) {
  return _then(_AgentConnectionTestResult(
successful: null == successful ? _self.successful : successful // ignore: cast_nullable_to_non_nullable
as bool,message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc
mixin _$AppUiState {

 AppScreen get screen; bool get subAgentBackNavigation; bool get debugModeEnabled; List<ServerProfile> get profiles; String? get selectedProfileId; ConnectionState get connection; Map<String, ConnectionState> get connectionStates; Map<AgentConnectionKey, ConnectionState> get agentConnectionStates; AgentKind get activeAgent; AgentCapabilities get activeAgentCapabilities; Map<String, ServerMetrics> get serverMetrics; String? get pendingFingerprint; RemoteSetupPrompt? get remoteSetup; bool get setupInProgress; String get setupProgress; int get setupProgressPercent; String get setupProgressDetail; int? get setupDownloadPercent; Map<AgentConnectionKey, AgentSetupState> get agentSetupStates; Map<AgentConnectionKey, List<AgentThread>> get agentThreadLists; Map<AgentConnectionKey, List<AgentModel>> get agentModelLists; Map<AgentConnectionKey, bool> get agentLoadingStates; List<AgentThread> get threads; String get threadSearch; AgentThread? get activeThread; String? get activeAgentName; ThreadGoal? get activeGoal; List<TimelineEntry> get timeline; String? get olderTurnsCursor; bool get olderTurnsLoading; String? get activeTurnId; bool get running; TurnTiming? get turnTiming; bool get submitting; bool get loading; List<AgentModel> get models; List<ApiModelOption> get apiModelOptions; String? get apiModelOptionsProfileId; bool get apiModelOptionsLoading; String? get apiModelOptionsError; String? get selectedModel; String? get selectedEffort; ApprovalMode get approvalMode; SandboxChoice get sandbox; bool get workspacePickerVisible; bool get workspaceLoading; String get workspaceCurrentPath; String? get workspaceParentPath; List<RemoteDirectory> get workspaceDirectories; String? get workspaceError; String? get fileManagerProfileId; bool get fileManagerLoading; String get fileManagerCurrentPath; String? get fileManagerParentPath; List<RemoteFileEntry> get fileManagerEntries; RemoteFileClipboard? get fileManagerClipboard; String? get fileManagerOperation; String? get fileManagerError; bool get agentSettingsVisible; bool get agentSettingsLoading; bool get agentSettingsSaving; bool get agentSettingsTesting; AgentGlobalSettings? get agentSettings; AgentConnectionTestResult? get agentSettingsTestResult; String? get agentSettingsError; ApprovalPrompt? get approval; List<ApprovalPrompt> get approvalQueue; List<PendingAttachment> get attachments; bool get attachmentUploading; int get composerClearNonce; String get composerDraft; String get aggregateDiff; TokenUsage? get tokenUsage; String? get error; String? get diagnostic;
/// Create a copy of AppUiState
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AppUiStateCopyWith<AppUiState> get copyWith => _$AppUiStateCopyWithImpl<AppUiState>(this as AppUiState, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AppUiState&&(identical(other.screen, screen) || other.screen == screen)&&(identical(other.subAgentBackNavigation, subAgentBackNavigation) || other.subAgentBackNavigation == subAgentBackNavigation)&&(identical(other.debugModeEnabled, debugModeEnabled) || other.debugModeEnabled == debugModeEnabled)&&const DeepCollectionEquality().equals(other.profiles, profiles)&&(identical(other.selectedProfileId, selectedProfileId) || other.selectedProfileId == selectedProfileId)&&(identical(other.connection, connection) || other.connection == connection)&&const DeepCollectionEquality().equals(other.connectionStates, connectionStates)&&const DeepCollectionEquality().equals(other.agentConnectionStates, agentConnectionStates)&&(identical(other.activeAgent, activeAgent) || other.activeAgent == activeAgent)&&(identical(other.activeAgentCapabilities, activeAgentCapabilities) || other.activeAgentCapabilities == activeAgentCapabilities)&&const DeepCollectionEquality().equals(other.serverMetrics, serverMetrics)&&(identical(other.pendingFingerprint, pendingFingerprint) || other.pendingFingerprint == pendingFingerprint)&&(identical(other.remoteSetup, remoteSetup) || other.remoteSetup == remoteSetup)&&(identical(other.setupInProgress, setupInProgress) || other.setupInProgress == setupInProgress)&&(identical(other.setupProgress, setupProgress) || other.setupProgress == setupProgress)&&(identical(other.setupProgressPercent, setupProgressPercent) || other.setupProgressPercent == setupProgressPercent)&&(identical(other.setupProgressDetail, setupProgressDetail) || other.setupProgressDetail == setupProgressDetail)&&(identical(other.setupDownloadPercent, setupDownloadPercent) || other.setupDownloadPercent == setupDownloadPercent)&&const DeepCollectionEquality().equals(other.agentSetupStates, agentSetupStates)&&const DeepCollectionEquality().equals(other.agentThreadLists, agentThreadLists)&&const DeepCollectionEquality().equals(other.agentModelLists, agentModelLists)&&const DeepCollectionEquality().equals(other.agentLoadingStates, agentLoadingStates)&&const DeepCollectionEquality().equals(other.threads, threads)&&(identical(other.threadSearch, threadSearch) || other.threadSearch == threadSearch)&&(identical(other.activeThread, activeThread) || other.activeThread == activeThread)&&(identical(other.activeAgentName, activeAgentName) || other.activeAgentName == activeAgentName)&&(identical(other.activeGoal, activeGoal) || other.activeGoal == activeGoal)&&const DeepCollectionEquality().equals(other.timeline, timeline)&&(identical(other.olderTurnsCursor, olderTurnsCursor) || other.olderTurnsCursor == olderTurnsCursor)&&(identical(other.olderTurnsLoading, olderTurnsLoading) || other.olderTurnsLoading == olderTurnsLoading)&&(identical(other.activeTurnId, activeTurnId) || other.activeTurnId == activeTurnId)&&(identical(other.running, running) || other.running == running)&&(identical(other.turnTiming, turnTiming) || other.turnTiming == turnTiming)&&(identical(other.submitting, submitting) || other.submitting == submitting)&&(identical(other.loading, loading) || other.loading == loading)&&const DeepCollectionEquality().equals(other.models, models)&&const DeepCollectionEquality().equals(other.apiModelOptions, apiModelOptions)&&(identical(other.apiModelOptionsProfileId, apiModelOptionsProfileId) || other.apiModelOptionsProfileId == apiModelOptionsProfileId)&&(identical(other.apiModelOptionsLoading, apiModelOptionsLoading) || other.apiModelOptionsLoading == apiModelOptionsLoading)&&(identical(other.apiModelOptionsError, apiModelOptionsError) || other.apiModelOptionsError == apiModelOptionsError)&&(identical(other.selectedModel, selectedModel) || other.selectedModel == selectedModel)&&(identical(other.selectedEffort, selectedEffort) || other.selectedEffort == selectedEffort)&&(identical(other.approvalMode, approvalMode) || other.approvalMode == approvalMode)&&(identical(other.sandbox, sandbox) || other.sandbox == sandbox)&&(identical(other.workspacePickerVisible, workspacePickerVisible) || other.workspacePickerVisible == workspacePickerVisible)&&(identical(other.workspaceLoading, workspaceLoading) || other.workspaceLoading == workspaceLoading)&&(identical(other.workspaceCurrentPath, workspaceCurrentPath) || other.workspaceCurrentPath == workspaceCurrentPath)&&(identical(other.workspaceParentPath, workspaceParentPath) || other.workspaceParentPath == workspaceParentPath)&&const DeepCollectionEquality().equals(other.workspaceDirectories, workspaceDirectories)&&(identical(other.workspaceError, workspaceError) || other.workspaceError == workspaceError)&&(identical(other.fileManagerProfileId, fileManagerProfileId) || other.fileManagerProfileId == fileManagerProfileId)&&(identical(other.fileManagerLoading, fileManagerLoading) || other.fileManagerLoading == fileManagerLoading)&&(identical(other.fileManagerCurrentPath, fileManagerCurrentPath) || other.fileManagerCurrentPath == fileManagerCurrentPath)&&(identical(other.fileManagerParentPath, fileManagerParentPath) || other.fileManagerParentPath == fileManagerParentPath)&&const DeepCollectionEquality().equals(other.fileManagerEntries, fileManagerEntries)&&(identical(other.fileManagerClipboard, fileManagerClipboard) || other.fileManagerClipboard == fileManagerClipboard)&&(identical(other.fileManagerOperation, fileManagerOperation) || other.fileManagerOperation == fileManagerOperation)&&(identical(other.fileManagerError, fileManagerError) || other.fileManagerError == fileManagerError)&&(identical(other.agentSettingsVisible, agentSettingsVisible) || other.agentSettingsVisible == agentSettingsVisible)&&(identical(other.agentSettingsLoading, agentSettingsLoading) || other.agentSettingsLoading == agentSettingsLoading)&&(identical(other.agentSettingsSaving, agentSettingsSaving) || other.agentSettingsSaving == agentSettingsSaving)&&(identical(other.agentSettingsTesting, agentSettingsTesting) || other.agentSettingsTesting == agentSettingsTesting)&&(identical(other.agentSettings, agentSettings) || other.agentSettings == agentSettings)&&(identical(other.agentSettingsTestResult, agentSettingsTestResult) || other.agentSettingsTestResult == agentSettingsTestResult)&&(identical(other.agentSettingsError, agentSettingsError) || other.agentSettingsError == agentSettingsError)&&(identical(other.approval, approval) || other.approval == approval)&&const DeepCollectionEquality().equals(other.approvalQueue, approvalQueue)&&const DeepCollectionEquality().equals(other.attachments, attachments)&&(identical(other.attachmentUploading, attachmentUploading) || other.attachmentUploading == attachmentUploading)&&(identical(other.composerClearNonce, composerClearNonce) || other.composerClearNonce == composerClearNonce)&&(identical(other.composerDraft, composerDraft) || other.composerDraft == composerDraft)&&(identical(other.aggregateDiff, aggregateDiff) || other.aggregateDiff == aggregateDiff)&&(identical(other.tokenUsage, tokenUsage) || other.tokenUsage == tokenUsage)&&(identical(other.error, error) || other.error == error)&&(identical(other.diagnostic, diagnostic) || other.diagnostic == diagnostic));
}


@override
int get hashCode => Object.hashAll([runtimeType,screen,subAgentBackNavigation,debugModeEnabled,const DeepCollectionEquality().hash(profiles),selectedProfileId,connection,const DeepCollectionEquality().hash(connectionStates),const DeepCollectionEquality().hash(agentConnectionStates),activeAgent,activeAgentCapabilities,const DeepCollectionEquality().hash(serverMetrics),pendingFingerprint,remoteSetup,setupInProgress,setupProgress,setupProgressPercent,setupProgressDetail,setupDownloadPercent,const DeepCollectionEquality().hash(agentSetupStates),const DeepCollectionEquality().hash(agentThreadLists),const DeepCollectionEquality().hash(agentModelLists),const DeepCollectionEquality().hash(agentLoadingStates),const DeepCollectionEquality().hash(threads),threadSearch,activeThread,activeAgentName,activeGoal,const DeepCollectionEquality().hash(timeline),olderTurnsCursor,olderTurnsLoading,activeTurnId,running,turnTiming,submitting,loading,const DeepCollectionEquality().hash(models),const DeepCollectionEquality().hash(apiModelOptions),apiModelOptionsProfileId,apiModelOptionsLoading,apiModelOptionsError,selectedModel,selectedEffort,approvalMode,sandbox,workspacePickerVisible,workspaceLoading,workspaceCurrentPath,workspaceParentPath,const DeepCollectionEquality().hash(workspaceDirectories),workspaceError,fileManagerProfileId,fileManagerLoading,fileManagerCurrentPath,fileManagerParentPath,const DeepCollectionEquality().hash(fileManagerEntries),fileManagerClipboard,fileManagerOperation,fileManagerError,agentSettingsVisible,agentSettingsLoading,agentSettingsSaving,agentSettingsTesting,agentSettings,agentSettingsTestResult,agentSettingsError,approval,const DeepCollectionEquality().hash(approvalQueue),const DeepCollectionEquality().hash(attachments),attachmentUploading,composerClearNonce,composerDraft,aggregateDiff,tokenUsage,error,diagnostic]);

@override
String toString() {
  return 'AppUiState(screen: $screen, subAgentBackNavigation: $subAgentBackNavigation, debugModeEnabled: $debugModeEnabled, profiles: $profiles, selectedProfileId: $selectedProfileId, connection: $connection, connectionStates: $connectionStates, agentConnectionStates: $agentConnectionStates, activeAgent: $activeAgent, activeAgentCapabilities: $activeAgentCapabilities, serverMetrics: $serverMetrics, pendingFingerprint: $pendingFingerprint, remoteSetup: $remoteSetup, setupInProgress: $setupInProgress, setupProgress: $setupProgress, setupProgressPercent: $setupProgressPercent, setupProgressDetail: $setupProgressDetail, setupDownloadPercent: $setupDownloadPercent, agentSetupStates: $agentSetupStates, agentThreadLists: $agentThreadLists, agentModelLists: $agentModelLists, agentLoadingStates: $agentLoadingStates, threads: $threads, threadSearch: $threadSearch, activeThread: $activeThread, activeAgentName: $activeAgentName, activeGoal: $activeGoal, timeline: $timeline, olderTurnsCursor: $olderTurnsCursor, olderTurnsLoading: $olderTurnsLoading, activeTurnId: $activeTurnId, running: $running, turnTiming: $turnTiming, submitting: $submitting, loading: $loading, models: $models, apiModelOptions: $apiModelOptions, apiModelOptionsProfileId: $apiModelOptionsProfileId, apiModelOptionsLoading: $apiModelOptionsLoading, apiModelOptionsError: $apiModelOptionsError, selectedModel: $selectedModel, selectedEffort: $selectedEffort, approvalMode: $approvalMode, sandbox: $sandbox, workspacePickerVisible: $workspacePickerVisible, workspaceLoading: $workspaceLoading, workspaceCurrentPath: $workspaceCurrentPath, workspaceParentPath: $workspaceParentPath, workspaceDirectories: $workspaceDirectories, workspaceError: $workspaceError, fileManagerProfileId: $fileManagerProfileId, fileManagerLoading: $fileManagerLoading, fileManagerCurrentPath: $fileManagerCurrentPath, fileManagerParentPath: $fileManagerParentPath, fileManagerEntries: $fileManagerEntries, fileManagerClipboard: $fileManagerClipboard, fileManagerOperation: $fileManagerOperation, fileManagerError: $fileManagerError, agentSettingsVisible: $agentSettingsVisible, agentSettingsLoading: $agentSettingsLoading, agentSettingsSaving: $agentSettingsSaving, agentSettingsTesting: $agentSettingsTesting, agentSettings: $agentSettings, agentSettingsTestResult: $agentSettingsTestResult, agentSettingsError: $agentSettingsError, approval: $approval, approvalQueue: $approvalQueue, attachments: $attachments, attachmentUploading: $attachmentUploading, composerClearNonce: $composerClearNonce, composerDraft: $composerDraft, aggregateDiff: $aggregateDiff, tokenUsage: $tokenUsage, error: $error, diagnostic: $diagnostic)';
}


}

/// @nodoc
abstract mixin class $AppUiStateCopyWith<$Res>  {
  factory $AppUiStateCopyWith(AppUiState value, $Res Function(AppUiState) _then) = _$AppUiStateCopyWithImpl;
@useResult
$Res call({
 AppScreen screen, bool subAgentBackNavigation, bool debugModeEnabled, List<ServerProfile> profiles, String? selectedProfileId, ConnectionState connection, Map<String, ConnectionState> connectionStates, Map<AgentConnectionKey, ConnectionState> agentConnectionStates, AgentKind activeAgent, AgentCapabilities activeAgentCapabilities, Map<String, ServerMetrics> serverMetrics, String? pendingFingerprint, RemoteSetupPrompt? remoteSetup, bool setupInProgress, String setupProgress, int setupProgressPercent, String setupProgressDetail, int? setupDownloadPercent, Map<AgentConnectionKey, AgentSetupState> agentSetupStates, Map<AgentConnectionKey, List<AgentThread>> agentThreadLists, Map<AgentConnectionKey, List<AgentModel>> agentModelLists, Map<AgentConnectionKey, bool> agentLoadingStates, List<AgentThread> threads, String threadSearch, AgentThread? activeThread, String? activeAgentName, ThreadGoal? activeGoal, List<TimelineEntry> timeline, String? olderTurnsCursor, bool olderTurnsLoading, String? activeTurnId, bool running, TurnTiming? turnTiming, bool submitting, bool loading, List<AgentModel> models, List<ApiModelOption> apiModelOptions, String? apiModelOptionsProfileId, bool apiModelOptionsLoading, String? apiModelOptionsError, String? selectedModel, String? selectedEffort, ApprovalMode approvalMode, SandboxChoice sandbox, bool workspacePickerVisible, bool workspaceLoading, String workspaceCurrentPath, String? workspaceParentPath, List<RemoteDirectory> workspaceDirectories, String? workspaceError, String? fileManagerProfileId, bool fileManagerLoading, String fileManagerCurrentPath, String? fileManagerParentPath, List<RemoteFileEntry> fileManagerEntries, RemoteFileClipboard? fileManagerClipboard, String? fileManagerOperation, String? fileManagerError, bool agentSettingsVisible, bool agentSettingsLoading, bool agentSettingsSaving, bool agentSettingsTesting, AgentGlobalSettings? agentSettings, AgentConnectionTestResult? agentSettingsTestResult, String? agentSettingsError, ApprovalPrompt? approval, List<ApprovalPrompt> approvalQueue, List<PendingAttachment> attachments, bool attachmentUploading, int composerClearNonce, String composerDraft, String aggregateDiff, TokenUsage? tokenUsage, String? error, String? diagnostic
});


$ConnectionStateCopyWith<$Res> get connection;$AgentCapabilitiesCopyWith<$Res> get activeAgentCapabilities;$RemoteSetupPromptCopyWith<$Res>? get remoteSetup;$AgentThreadCopyWith<$Res>? get activeThread;$ThreadGoalCopyWith<$Res>? get activeGoal;$TurnTimingCopyWith<$Res>? get turnTiming;$RemoteFileClipboardCopyWith<$Res>? get fileManagerClipboard;$AgentGlobalSettingsCopyWith<$Res>? get agentSettings;$AgentConnectionTestResultCopyWith<$Res>? get agentSettingsTestResult;$ApprovalPromptCopyWith<$Res>? get approval;$TokenUsageCopyWith<$Res>? get tokenUsage;

}
/// @nodoc
class _$AppUiStateCopyWithImpl<$Res>
    implements $AppUiStateCopyWith<$Res> {
  _$AppUiStateCopyWithImpl(this._self, this._then);

  final AppUiState _self;
  final $Res Function(AppUiState) _then;

/// Create a copy of AppUiState
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? screen = null,Object? subAgentBackNavigation = null,Object? debugModeEnabled = null,Object? profiles = null,Object? selectedProfileId = freezed,Object? connection = null,Object? connectionStates = null,Object? agentConnectionStates = null,Object? activeAgent = null,Object? activeAgentCapabilities = null,Object? serverMetrics = null,Object? pendingFingerprint = freezed,Object? remoteSetup = freezed,Object? setupInProgress = null,Object? setupProgress = null,Object? setupProgressPercent = null,Object? setupProgressDetail = null,Object? setupDownloadPercent = freezed,Object? agentSetupStates = null,Object? agentThreadLists = null,Object? agentModelLists = null,Object? agentLoadingStates = null,Object? threads = null,Object? threadSearch = null,Object? activeThread = freezed,Object? activeAgentName = freezed,Object? activeGoal = freezed,Object? timeline = null,Object? olderTurnsCursor = freezed,Object? olderTurnsLoading = null,Object? activeTurnId = freezed,Object? running = null,Object? turnTiming = freezed,Object? submitting = null,Object? loading = null,Object? models = null,Object? apiModelOptions = null,Object? apiModelOptionsProfileId = freezed,Object? apiModelOptionsLoading = null,Object? apiModelOptionsError = freezed,Object? selectedModel = freezed,Object? selectedEffort = freezed,Object? approvalMode = null,Object? sandbox = null,Object? workspacePickerVisible = null,Object? workspaceLoading = null,Object? workspaceCurrentPath = null,Object? workspaceParentPath = freezed,Object? workspaceDirectories = null,Object? workspaceError = freezed,Object? fileManagerProfileId = freezed,Object? fileManagerLoading = null,Object? fileManagerCurrentPath = null,Object? fileManagerParentPath = freezed,Object? fileManagerEntries = null,Object? fileManagerClipboard = freezed,Object? fileManagerOperation = freezed,Object? fileManagerError = freezed,Object? agentSettingsVisible = null,Object? agentSettingsLoading = null,Object? agentSettingsSaving = null,Object? agentSettingsTesting = null,Object? agentSettings = freezed,Object? agentSettingsTestResult = freezed,Object? agentSettingsError = freezed,Object? approval = freezed,Object? approvalQueue = null,Object? attachments = null,Object? attachmentUploading = null,Object? composerClearNonce = null,Object? composerDraft = null,Object? aggregateDiff = null,Object? tokenUsage = freezed,Object? error = freezed,Object? diagnostic = freezed,}) {
  return _then(_self.copyWith(
screen: null == screen ? _self.screen : screen // ignore: cast_nullable_to_non_nullable
as AppScreen,subAgentBackNavigation: null == subAgentBackNavigation ? _self.subAgentBackNavigation : subAgentBackNavigation // ignore: cast_nullable_to_non_nullable
as bool,debugModeEnabled: null == debugModeEnabled ? _self.debugModeEnabled : debugModeEnabled // ignore: cast_nullable_to_non_nullable
as bool,profiles: null == profiles ? _self.profiles : profiles // ignore: cast_nullable_to_non_nullable
as List<ServerProfile>,selectedProfileId: freezed == selectedProfileId ? _self.selectedProfileId : selectedProfileId // ignore: cast_nullable_to_non_nullable
as String?,connection: null == connection ? _self.connection : connection // ignore: cast_nullable_to_non_nullable
as ConnectionState,connectionStates: null == connectionStates ? _self.connectionStates : connectionStates // ignore: cast_nullable_to_non_nullable
as Map<String, ConnectionState>,agentConnectionStates: null == agentConnectionStates ? _self.agentConnectionStates : agentConnectionStates // ignore: cast_nullable_to_non_nullable
as Map<AgentConnectionKey, ConnectionState>,activeAgent: null == activeAgent ? _self.activeAgent : activeAgent // ignore: cast_nullable_to_non_nullable
as AgentKind,activeAgentCapabilities: null == activeAgentCapabilities ? _self.activeAgentCapabilities : activeAgentCapabilities // ignore: cast_nullable_to_non_nullable
as AgentCapabilities,serverMetrics: null == serverMetrics ? _self.serverMetrics : serverMetrics // ignore: cast_nullable_to_non_nullable
as Map<String, ServerMetrics>,pendingFingerprint: freezed == pendingFingerprint ? _self.pendingFingerprint : pendingFingerprint // ignore: cast_nullable_to_non_nullable
as String?,remoteSetup: freezed == remoteSetup ? _self.remoteSetup : remoteSetup // ignore: cast_nullable_to_non_nullable
as RemoteSetupPrompt?,setupInProgress: null == setupInProgress ? _self.setupInProgress : setupInProgress // ignore: cast_nullable_to_non_nullable
as bool,setupProgress: null == setupProgress ? _self.setupProgress : setupProgress // ignore: cast_nullable_to_non_nullable
as String,setupProgressPercent: null == setupProgressPercent ? _self.setupProgressPercent : setupProgressPercent // ignore: cast_nullable_to_non_nullable
as int,setupProgressDetail: null == setupProgressDetail ? _self.setupProgressDetail : setupProgressDetail // ignore: cast_nullable_to_non_nullable
as String,setupDownloadPercent: freezed == setupDownloadPercent ? _self.setupDownloadPercent : setupDownloadPercent // ignore: cast_nullable_to_non_nullable
as int?,agentSetupStates: null == agentSetupStates ? _self.agentSetupStates : agentSetupStates // ignore: cast_nullable_to_non_nullable
as Map<AgentConnectionKey, AgentSetupState>,agentThreadLists: null == agentThreadLists ? _self.agentThreadLists : agentThreadLists // ignore: cast_nullable_to_non_nullable
as Map<AgentConnectionKey, List<AgentThread>>,agentModelLists: null == agentModelLists ? _self.agentModelLists : agentModelLists // ignore: cast_nullable_to_non_nullable
as Map<AgentConnectionKey, List<AgentModel>>,agentLoadingStates: null == agentLoadingStates ? _self.agentLoadingStates : agentLoadingStates // ignore: cast_nullable_to_non_nullable
as Map<AgentConnectionKey, bool>,threads: null == threads ? _self.threads : threads // ignore: cast_nullable_to_non_nullable
as List<AgentThread>,threadSearch: null == threadSearch ? _self.threadSearch : threadSearch // ignore: cast_nullable_to_non_nullable
as String,activeThread: freezed == activeThread ? _self.activeThread : activeThread // ignore: cast_nullable_to_non_nullable
as AgentThread?,activeAgentName: freezed == activeAgentName ? _self.activeAgentName : activeAgentName // ignore: cast_nullable_to_non_nullable
as String?,activeGoal: freezed == activeGoal ? _self.activeGoal : activeGoal // ignore: cast_nullable_to_non_nullable
as ThreadGoal?,timeline: null == timeline ? _self.timeline : timeline // ignore: cast_nullable_to_non_nullable
as List<TimelineEntry>,olderTurnsCursor: freezed == olderTurnsCursor ? _self.olderTurnsCursor : olderTurnsCursor // ignore: cast_nullable_to_non_nullable
as String?,olderTurnsLoading: null == olderTurnsLoading ? _self.olderTurnsLoading : olderTurnsLoading // ignore: cast_nullable_to_non_nullable
as bool,activeTurnId: freezed == activeTurnId ? _self.activeTurnId : activeTurnId // ignore: cast_nullable_to_non_nullable
as String?,running: null == running ? _self.running : running // ignore: cast_nullable_to_non_nullable
as bool,turnTiming: freezed == turnTiming ? _self.turnTiming : turnTiming // ignore: cast_nullable_to_non_nullable
as TurnTiming?,submitting: null == submitting ? _self.submitting : submitting // ignore: cast_nullable_to_non_nullable
as bool,loading: null == loading ? _self.loading : loading // ignore: cast_nullable_to_non_nullable
as bool,models: null == models ? _self.models : models // ignore: cast_nullable_to_non_nullable
as List<AgentModel>,apiModelOptions: null == apiModelOptions ? _self.apiModelOptions : apiModelOptions // ignore: cast_nullable_to_non_nullable
as List<ApiModelOption>,apiModelOptionsProfileId: freezed == apiModelOptionsProfileId ? _self.apiModelOptionsProfileId : apiModelOptionsProfileId // ignore: cast_nullable_to_non_nullable
as String?,apiModelOptionsLoading: null == apiModelOptionsLoading ? _self.apiModelOptionsLoading : apiModelOptionsLoading // ignore: cast_nullable_to_non_nullable
as bool,apiModelOptionsError: freezed == apiModelOptionsError ? _self.apiModelOptionsError : apiModelOptionsError // ignore: cast_nullable_to_non_nullable
as String?,selectedModel: freezed == selectedModel ? _self.selectedModel : selectedModel // ignore: cast_nullable_to_non_nullable
as String?,selectedEffort: freezed == selectedEffort ? _self.selectedEffort : selectedEffort // ignore: cast_nullable_to_non_nullable
as String?,approvalMode: null == approvalMode ? _self.approvalMode : approvalMode // ignore: cast_nullable_to_non_nullable
as ApprovalMode,sandbox: null == sandbox ? _self.sandbox : sandbox // ignore: cast_nullable_to_non_nullable
as SandboxChoice,workspacePickerVisible: null == workspacePickerVisible ? _self.workspacePickerVisible : workspacePickerVisible // ignore: cast_nullable_to_non_nullable
as bool,workspaceLoading: null == workspaceLoading ? _self.workspaceLoading : workspaceLoading // ignore: cast_nullable_to_non_nullable
as bool,workspaceCurrentPath: null == workspaceCurrentPath ? _self.workspaceCurrentPath : workspaceCurrentPath // ignore: cast_nullable_to_non_nullable
as String,workspaceParentPath: freezed == workspaceParentPath ? _self.workspaceParentPath : workspaceParentPath // ignore: cast_nullable_to_non_nullable
as String?,workspaceDirectories: null == workspaceDirectories ? _self.workspaceDirectories : workspaceDirectories // ignore: cast_nullable_to_non_nullable
as List<RemoteDirectory>,workspaceError: freezed == workspaceError ? _self.workspaceError : workspaceError // ignore: cast_nullable_to_non_nullable
as String?,fileManagerProfileId: freezed == fileManagerProfileId ? _self.fileManagerProfileId : fileManagerProfileId // ignore: cast_nullable_to_non_nullable
as String?,fileManagerLoading: null == fileManagerLoading ? _self.fileManagerLoading : fileManagerLoading // ignore: cast_nullable_to_non_nullable
as bool,fileManagerCurrentPath: null == fileManagerCurrentPath ? _self.fileManagerCurrentPath : fileManagerCurrentPath // ignore: cast_nullable_to_non_nullable
as String,fileManagerParentPath: freezed == fileManagerParentPath ? _self.fileManagerParentPath : fileManagerParentPath // ignore: cast_nullable_to_non_nullable
as String?,fileManagerEntries: null == fileManagerEntries ? _self.fileManagerEntries : fileManagerEntries // ignore: cast_nullable_to_non_nullable
as List<RemoteFileEntry>,fileManagerClipboard: freezed == fileManagerClipboard ? _self.fileManagerClipboard : fileManagerClipboard // ignore: cast_nullable_to_non_nullable
as RemoteFileClipboard?,fileManagerOperation: freezed == fileManagerOperation ? _self.fileManagerOperation : fileManagerOperation // ignore: cast_nullable_to_non_nullable
as String?,fileManagerError: freezed == fileManagerError ? _self.fileManagerError : fileManagerError // ignore: cast_nullable_to_non_nullable
as String?,agentSettingsVisible: null == agentSettingsVisible ? _self.agentSettingsVisible : agentSettingsVisible // ignore: cast_nullable_to_non_nullable
as bool,agentSettingsLoading: null == agentSettingsLoading ? _self.agentSettingsLoading : agentSettingsLoading // ignore: cast_nullable_to_non_nullable
as bool,agentSettingsSaving: null == agentSettingsSaving ? _self.agentSettingsSaving : agentSettingsSaving // ignore: cast_nullable_to_non_nullable
as bool,agentSettingsTesting: null == agentSettingsTesting ? _self.agentSettingsTesting : agentSettingsTesting // ignore: cast_nullable_to_non_nullable
as bool,agentSettings: freezed == agentSettings ? _self.agentSettings : agentSettings // ignore: cast_nullable_to_non_nullable
as AgentGlobalSettings?,agentSettingsTestResult: freezed == agentSettingsTestResult ? _self.agentSettingsTestResult : agentSettingsTestResult // ignore: cast_nullable_to_non_nullable
as AgentConnectionTestResult?,agentSettingsError: freezed == agentSettingsError ? _self.agentSettingsError : agentSettingsError // ignore: cast_nullable_to_non_nullable
as String?,approval: freezed == approval ? _self.approval : approval // ignore: cast_nullable_to_non_nullable
as ApprovalPrompt?,approvalQueue: null == approvalQueue ? _self.approvalQueue : approvalQueue // ignore: cast_nullable_to_non_nullable
as List<ApprovalPrompt>,attachments: null == attachments ? _self.attachments : attachments // ignore: cast_nullable_to_non_nullable
as List<PendingAttachment>,attachmentUploading: null == attachmentUploading ? _self.attachmentUploading : attachmentUploading // ignore: cast_nullable_to_non_nullable
as bool,composerClearNonce: null == composerClearNonce ? _self.composerClearNonce : composerClearNonce // ignore: cast_nullable_to_non_nullable
as int,composerDraft: null == composerDraft ? _self.composerDraft : composerDraft // ignore: cast_nullable_to_non_nullable
as String,aggregateDiff: null == aggregateDiff ? _self.aggregateDiff : aggregateDiff // ignore: cast_nullable_to_non_nullable
as String,tokenUsage: freezed == tokenUsage ? _self.tokenUsage : tokenUsage // ignore: cast_nullable_to_non_nullable
as TokenUsage?,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as String?,diagnostic: freezed == diagnostic ? _self.diagnostic : diagnostic // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}
/// Create a copy of AppUiState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ConnectionStateCopyWith<$Res> get connection {
  
  return $ConnectionStateCopyWith<$Res>(_self.connection, (value) {
    return _then(_self.copyWith(connection: value));
  });
}/// Create a copy of AppUiState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$AgentCapabilitiesCopyWith<$Res> get activeAgentCapabilities {
  
  return $AgentCapabilitiesCopyWith<$Res>(_self.activeAgentCapabilities, (value) {
    return _then(_self.copyWith(activeAgentCapabilities: value));
  });
}/// Create a copy of AppUiState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$RemoteSetupPromptCopyWith<$Res>? get remoteSetup {
    if (_self.remoteSetup == null) {
    return null;
  }

  return $RemoteSetupPromptCopyWith<$Res>(_self.remoteSetup!, (value) {
    return _then(_self.copyWith(remoteSetup: value));
  });
}/// Create a copy of AppUiState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$AgentThreadCopyWith<$Res>? get activeThread {
    if (_self.activeThread == null) {
    return null;
  }

  return $AgentThreadCopyWith<$Res>(_self.activeThread!, (value) {
    return _then(_self.copyWith(activeThread: value));
  });
}/// Create a copy of AppUiState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ThreadGoalCopyWith<$Res>? get activeGoal {
    if (_self.activeGoal == null) {
    return null;
  }

  return $ThreadGoalCopyWith<$Res>(_self.activeGoal!, (value) {
    return _then(_self.copyWith(activeGoal: value));
  });
}/// Create a copy of AppUiState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$TurnTimingCopyWith<$Res>? get turnTiming {
    if (_self.turnTiming == null) {
    return null;
  }

  return $TurnTimingCopyWith<$Res>(_self.turnTiming!, (value) {
    return _then(_self.copyWith(turnTiming: value));
  });
}/// Create a copy of AppUiState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$RemoteFileClipboardCopyWith<$Res>? get fileManagerClipboard {
    if (_self.fileManagerClipboard == null) {
    return null;
  }

  return $RemoteFileClipboardCopyWith<$Res>(_self.fileManagerClipboard!, (value) {
    return _then(_self.copyWith(fileManagerClipboard: value));
  });
}/// Create a copy of AppUiState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$AgentGlobalSettingsCopyWith<$Res>? get agentSettings {
    if (_self.agentSettings == null) {
    return null;
  }

  return $AgentGlobalSettingsCopyWith<$Res>(_self.agentSettings!, (value) {
    return _then(_self.copyWith(agentSettings: value));
  });
}/// Create a copy of AppUiState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$AgentConnectionTestResultCopyWith<$Res>? get agentSettingsTestResult {
    if (_self.agentSettingsTestResult == null) {
    return null;
  }

  return $AgentConnectionTestResultCopyWith<$Res>(_self.agentSettingsTestResult!, (value) {
    return _then(_self.copyWith(agentSettingsTestResult: value));
  });
}/// Create a copy of AppUiState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ApprovalPromptCopyWith<$Res>? get approval {
    if (_self.approval == null) {
    return null;
  }

  return $ApprovalPromptCopyWith<$Res>(_self.approval!, (value) {
    return _then(_self.copyWith(approval: value));
  });
}/// Create a copy of AppUiState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$TokenUsageCopyWith<$Res>? get tokenUsage {
    if (_self.tokenUsage == null) {
    return null;
  }

  return $TokenUsageCopyWith<$Res>(_self.tokenUsage!, (value) {
    return _then(_self.copyWith(tokenUsage: value));
  });
}
}


/// Adds pattern-matching-related methods to [AppUiState].
extension AppUiStatePatterns on AppUiState {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _AppUiState value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _AppUiState() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _AppUiState value)  $default,){
final _that = this;
switch (_that) {
case _AppUiState():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _AppUiState value)?  $default,){
final _that = this;
switch (_that) {
case _AppUiState() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( AppScreen screen,  bool subAgentBackNavigation,  bool debugModeEnabled,  List<ServerProfile> profiles,  String? selectedProfileId,  ConnectionState connection,  Map<String, ConnectionState> connectionStates,  Map<AgentConnectionKey, ConnectionState> agentConnectionStates,  AgentKind activeAgent,  AgentCapabilities activeAgentCapabilities,  Map<String, ServerMetrics> serverMetrics,  String? pendingFingerprint,  RemoteSetupPrompt? remoteSetup,  bool setupInProgress,  String setupProgress,  int setupProgressPercent,  String setupProgressDetail,  int? setupDownloadPercent,  Map<AgentConnectionKey, AgentSetupState> agentSetupStates,  Map<AgentConnectionKey, List<AgentThread>> agentThreadLists,  Map<AgentConnectionKey, List<AgentModel>> agentModelLists,  Map<AgentConnectionKey, bool> agentLoadingStates,  List<AgentThread> threads,  String threadSearch,  AgentThread? activeThread,  String? activeAgentName,  ThreadGoal? activeGoal,  List<TimelineEntry> timeline,  String? olderTurnsCursor,  bool olderTurnsLoading,  String? activeTurnId,  bool running,  TurnTiming? turnTiming,  bool submitting,  bool loading,  List<AgentModel> models,  List<ApiModelOption> apiModelOptions,  String? apiModelOptionsProfileId,  bool apiModelOptionsLoading,  String? apiModelOptionsError,  String? selectedModel,  String? selectedEffort,  ApprovalMode approvalMode,  SandboxChoice sandbox,  bool workspacePickerVisible,  bool workspaceLoading,  String workspaceCurrentPath,  String? workspaceParentPath,  List<RemoteDirectory> workspaceDirectories,  String? workspaceError,  String? fileManagerProfileId,  bool fileManagerLoading,  String fileManagerCurrentPath,  String? fileManagerParentPath,  List<RemoteFileEntry> fileManagerEntries,  RemoteFileClipboard? fileManagerClipboard,  String? fileManagerOperation,  String? fileManagerError,  bool agentSettingsVisible,  bool agentSettingsLoading,  bool agentSettingsSaving,  bool agentSettingsTesting,  AgentGlobalSettings? agentSettings,  AgentConnectionTestResult? agentSettingsTestResult,  String? agentSettingsError,  ApprovalPrompt? approval,  List<ApprovalPrompt> approvalQueue,  List<PendingAttachment> attachments,  bool attachmentUploading,  int composerClearNonce,  String composerDraft,  String aggregateDiff,  TokenUsage? tokenUsage,  String? error,  String? diagnostic)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _AppUiState() when $default != null:
return $default(_that.screen,_that.subAgentBackNavigation,_that.debugModeEnabled,_that.profiles,_that.selectedProfileId,_that.connection,_that.connectionStates,_that.agentConnectionStates,_that.activeAgent,_that.activeAgentCapabilities,_that.serverMetrics,_that.pendingFingerprint,_that.remoteSetup,_that.setupInProgress,_that.setupProgress,_that.setupProgressPercent,_that.setupProgressDetail,_that.setupDownloadPercent,_that.agentSetupStates,_that.agentThreadLists,_that.agentModelLists,_that.agentLoadingStates,_that.threads,_that.threadSearch,_that.activeThread,_that.activeAgentName,_that.activeGoal,_that.timeline,_that.olderTurnsCursor,_that.olderTurnsLoading,_that.activeTurnId,_that.running,_that.turnTiming,_that.submitting,_that.loading,_that.models,_that.apiModelOptions,_that.apiModelOptionsProfileId,_that.apiModelOptionsLoading,_that.apiModelOptionsError,_that.selectedModel,_that.selectedEffort,_that.approvalMode,_that.sandbox,_that.workspacePickerVisible,_that.workspaceLoading,_that.workspaceCurrentPath,_that.workspaceParentPath,_that.workspaceDirectories,_that.workspaceError,_that.fileManagerProfileId,_that.fileManagerLoading,_that.fileManagerCurrentPath,_that.fileManagerParentPath,_that.fileManagerEntries,_that.fileManagerClipboard,_that.fileManagerOperation,_that.fileManagerError,_that.agentSettingsVisible,_that.agentSettingsLoading,_that.agentSettingsSaving,_that.agentSettingsTesting,_that.agentSettings,_that.agentSettingsTestResult,_that.agentSettingsError,_that.approval,_that.approvalQueue,_that.attachments,_that.attachmentUploading,_that.composerClearNonce,_that.composerDraft,_that.aggregateDiff,_that.tokenUsage,_that.error,_that.diagnostic);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( AppScreen screen,  bool subAgentBackNavigation,  bool debugModeEnabled,  List<ServerProfile> profiles,  String? selectedProfileId,  ConnectionState connection,  Map<String, ConnectionState> connectionStates,  Map<AgentConnectionKey, ConnectionState> agentConnectionStates,  AgentKind activeAgent,  AgentCapabilities activeAgentCapabilities,  Map<String, ServerMetrics> serverMetrics,  String? pendingFingerprint,  RemoteSetupPrompt? remoteSetup,  bool setupInProgress,  String setupProgress,  int setupProgressPercent,  String setupProgressDetail,  int? setupDownloadPercent,  Map<AgentConnectionKey, AgentSetupState> agentSetupStates,  Map<AgentConnectionKey, List<AgentThread>> agentThreadLists,  Map<AgentConnectionKey, List<AgentModel>> agentModelLists,  Map<AgentConnectionKey, bool> agentLoadingStates,  List<AgentThread> threads,  String threadSearch,  AgentThread? activeThread,  String? activeAgentName,  ThreadGoal? activeGoal,  List<TimelineEntry> timeline,  String? olderTurnsCursor,  bool olderTurnsLoading,  String? activeTurnId,  bool running,  TurnTiming? turnTiming,  bool submitting,  bool loading,  List<AgentModel> models,  List<ApiModelOption> apiModelOptions,  String? apiModelOptionsProfileId,  bool apiModelOptionsLoading,  String? apiModelOptionsError,  String? selectedModel,  String? selectedEffort,  ApprovalMode approvalMode,  SandboxChoice sandbox,  bool workspacePickerVisible,  bool workspaceLoading,  String workspaceCurrentPath,  String? workspaceParentPath,  List<RemoteDirectory> workspaceDirectories,  String? workspaceError,  String? fileManagerProfileId,  bool fileManagerLoading,  String fileManagerCurrentPath,  String? fileManagerParentPath,  List<RemoteFileEntry> fileManagerEntries,  RemoteFileClipboard? fileManagerClipboard,  String? fileManagerOperation,  String? fileManagerError,  bool agentSettingsVisible,  bool agentSettingsLoading,  bool agentSettingsSaving,  bool agentSettingsTesting,  AgentGlobalSettings? agentSettings,  AgentConnectionTestResult? agentSettingsTestResult,  String? agentSettingsError,  ApprovalPrompt? approval,  List<ApprovalPrompt> approvalQueue,  List<PendingAttachment> attachments,  bool attachmentUploading,  int composerClearNonce,  String composerDraft,  String aggregateDiff,  TokenUsage? tokenUsage,  String? error,  String? diagnostic)  $default,) {final _that = this;
switch (_that) {
case _AppUiState():
return $default(_that.screen,_that.subAgentBackNavigation,_that.debugModeEnabled,_that.profiles,_that.selectedProfileId,_that.connection,_that.connectionStates,_that.agentConnectionStates,_that.activeAgent,_that.activeAgentCapabilities,_that.serverMetrics,_that.pendingFingerprint,_that.remoteSetup,_that.setupInProgress,_that.setupProgress,_that.setupProgressPercent,_that.setupProgressDetail,_that.setupDownloadPercent,_that.agentSetupStates,_that.agentThreadLists,_that.agentModelLists,_that.agentLoadingStates,_that.threads,_that.threadSearch,_that.activeThread,_that.activeAgentName,_that.activeGoal,_that.timeline,_that.olderTurnsCursor,_that.olderTurnsLoading,_that.activeTurnId,_that.running,_that.turnTiming,_that.submitting,_that.loading,_that.models,_that.apiModelOptions,_that.apiModelOptionsProfileId,_that.apiModelOptionsLoading,_that.apiModelOptionsError,_that.selectedModel,_that.selectedEffort,_that.approvalMode,_that.sandbox,_that.workspacePickerVisible,_that.workspaceLoading,_that.workspaceCurrentPath,_that.workspaceParentPath,_that.workspaceDirectories,_that.workspaceError,_that.fileManagerProfileId,_that.fileManagerLoading,_that.fileManagerCurrentPath,_that.fileManagerParentPath,_that.fileManagerEntries,_that.fileManagerClipboard,_that.fileManagerOperation,_that.fileManagerError,_that.agentSettingsVisible,_that.agentSettingsLoading,_that.agentSettingsSaving,_that.agentSettingsTesting,_that.agentSettings,_that.agentSettingsTestResult,_that.agentSettingsError,_that.approval,_that.approvalQueue,_that.attachments,_that.attachmentUploading,_that.composerClearNonce,_that.composerDraft,_that.aggregateDiff,_that.tokenUsage,_that.error,_that.diagnostic);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( AppScreen screen,  bool subAgentBackNavigation,  bool debugModeEnabled,  List<ServerProfile> profiles,  String? selectedProfileId,  ConnectionState connection,  Map<String, ConnectionState> connectionStates,  Map<AgentConnectionKey, ConnectionState> agentConnectionStates,  AgentKind activeAgent,  AgentCapabilities activeAgentCapabilities,  Map<String, ServerMetrics> serverMetrics,  String? pendingFingerprint,  RemoteSetupPrompt? remoteSetup,  bool setupInProgress,  String setupProgress,  int setupProgressPercent,  String setupProgressDetail,  int? setupDownloadPercent,  Map<AgentConnectionKey, AgentSetupState> agentSetupStates,  Map<AgentConnectionKey, List<AgentThread>> agentThreadLists,  Map<AgentConnectionKey, List<AgentModel>> agentModelLists,  Map<AgentConnectionKey, bool> agentLoadingStates,  List<AgentThread> threads,  String threadSearch,  AgentThread? activeThread,  String? activeAgentName,  ThreadGoal? activeGoal,  List<TimelineEntry> timeline,  String? olderTurnsCursor,  bool olderTurnsLoading,  String? activeTurnId,  bool running,  TurnTiming? turnTiming,  bool submitting,  bool loading,  List<AgentModel> models,  List<ApiModelOption> apiModelOptions,  String? apiModelOptionsProfileId,  bool apiModelOptionsLoading,  String? apiModelOptionsError,  String? selectedModel,  String? selectedEffort,  ApprovalMode approvalMode,  SandboxChoice sandbox,  bool workspacePickerVisible,  bool workspaceLoading,  String workspaceCurrentPath,  String? workspaceParentPath,  List<RemoteDirectory> workspaceDirectories,  String? workspaceError,  String? fileManagerProfileId,  bool fileManagerLoading,  String fileManagerCurrentPath,  String? fileManagerParentPath,  List<RemoteFileEntry> fileManagerEntries,  RemoteFileClipboard? fileManagerClipboard,  String? fileManagerOperation,  String? fileManagerError,  bool agentSettingsVisible,  bool agentSettingsLoading,  bool agentSettingsSaving,  bool agentSettingsTesting,  AgentGlobalSettings? agentSettings,  AgentConnectionTestResult? agentSettingsTestResult,  String? agentSettingsError,  ApprovalPrompt? approval,  List<ApprovalPrompt> approvalQueue,  List<PendingAttachment> attachments,  bool attachmentUploading,  int composerClearNonce,  String composerDraft,  String aggregateDiff,  TokenUsage? tokenUsage,  String? error,  String? diagnostic)?  $default,) {final _that = this;
switch (_that) {
case _AppUiState() when $default != null:
return $default(_that.screen,_that.subAgentBackNavigation,_that.debugModeEnabled,_that.profiles,_that.selectedProfileId,_that.connection,_that.connectionStates,_that.agentConnectionStates,_that.activeAgent,_that.activeAgentCapabilities,_that.serverMetrics,_that.pendingFingerprint,_that.remoteSetup,_that.setupInProgress,_that.setupProgress,_that.setupProgressPercent,_that.setupProgressDetail,_that.setupDownloadPercent,_that.agentSetupStates,_that.agentThreadLists,_that.agentModelLists,_that.agentLoadingStates,_that.threads,_that.threadSearch,_that.activeThread,_that.activeAgentName,_that.activeGoal,_that.timeline,_that.olderTurnsCursor,_that.olderTurnsLoading,_that.activeTurnId,_that.running,_that.turnTiming,_that.submitting,_that.loading,_that.models,_that.apiModelOptions,_that.apiModelOptionsProfileId,_that.apiModelOptionsLoading,_that.apiModelOptionsError,_that.selectedModel,_that.selectedEffort,_that.approvalMode,_that.sandbox,_that.workspacePickerVisible,_that.workspaceLoading,_that.workspaceCurrentPath,_that.workspaceParentPath,_that.workspaceDirectories,_that.workspaceError,_that.fileManagerProfileId,_that.fileManagerLoading,_that.fileManagerCurrentPath,_that.fileManagerParentPath,_that.fileManagerEntries,_that.fileManagerClipboard,_that.fileManagerOperation,_that.fileManagerError,_that.agentSettingsVisible,_that.agentSettingsLoading,_that.agentSettingsSaving,_that.agentSettingsTesting,_that.agentSettings,_that.agentSettingsTestResult,_that.agentSettingsError,_that.approval,_that.approvalQueue,_that.attachments,_that.attachmentUploading,_that.composerClearNonce,_that.composerDraft,_that.aggregateDiff,_that.tokenUsage,_that.error,_that.diagnostic);case _:
  return null;

}
}

}

/// @nodoc


class _AppUiState implements AppUiState {
  const _AppUiState({this.screen = AppScreen.servers, this.subAgentBackNavigation = false, this.debugModeEnabled = false, final  List<ServerProfile> profiles = const <ServerProfile>[], this.selectedProfileId, this.connection = const ConnectionState(), final  Map<String, ConnectionState> connectionStates = const <String, ConnectionState>{}, final  Map<AgentConnectionKey, ConnectionState> agentConnectionStates = const <AgentConnectionKey, ConnectionState>{}, this.activeAgent = AgentKind.codex, this.activeAgentCapabilities = AgentCapabilities.none, final  Map<String, ServerMetrics> serverMetrics = const <String, ServerMetrics>{}, this.pendingFingerprint, this.remoteSetup, this.setupInProgress = false, this.setupProgress = '', this.setupProgressPercent = 0, this.setupProgressDetail = '', this.setupDownloadPercent, final  Map<AgentConnectionKey, AgentSetupState> agentSetupStates = const <AgentConnectionKey, AgentSetupState>{}, final  Map<AgentConnectionKey, List<AgentThread>> agentThreadLists = const <AgentConnectionKey, List<AgentThread>>{}, final  Map<AgentConnectionKey, List<AgentModel>> agentModelLists = const <AgentConnectionKey, List<AgentModel>>{}, final  Map<AgentConnectionKey, bool> agentLoadingStates = const <AgentConnectionKey, bool>{}, final  List<AgentThread> threads = const <AgentThread>[], this.threadSearch = '', this.activeThread, this.activeAgentName, this.activeGoal, final  List<TimelineEntry> timeline = const <TimelineEntry>[], this.olderTurnsCursor, this.olderTurnsLoading = false, this.activeTurnId, this.running = false, this.turnTiming, this.submitting = false, this.loading = false, final  List<AgentModel> models = const <AgentModel>[], final  List<ApiModelOption> apiModelOptions = const <ApiModelOption>[], this.apiModelOptionsProfileId, this.apiModelOptionsLoading = false, this.apiModelOptionsError, this.selectedModel, this.selectedEffort, this.approvalMode = ApprovalMode.requestApproval, this.sandbox = SandboxChoice.workspaceWrite, this.workspacePickerVisible = false, this.workspaceLoading = false, this.workspaceCurrentPath = '', this.workspaceParentPath, final  List<RemoteDirectory> workspaceDirectories = const <RemoteDirectory>[], this.workspaceError, this.fileManagerProfileId, this.fileManagerLoading = false, this.fileManagerCurrentPath = '', this.fileManagerParentPath, final  List<RemoteFileEntry> fileManagerEntries = const <RemoteFileEntry>[], this.fileManagerClipboard, this.fileManagerOperation, this.fileManagerError, this.agentSettingsVisible = false, this.agentSettingsLoading = false, this.agentSettingsSaving = false, this.agentSettingsTesting = false, this.agentSettings, this.agentSettingsTestResult, this.agentSettingsError, this.approval, final  List<ApprovalPrompt> approvalQueue = const <ApprovalPrompt>[], final  List<PendingAttachment> attachments = const <PendingAttachment>[], this.attachmentUploading = false, this.composerClearNonce = 0, this.composerDraft = '', this.aggregateDiff = '', this.tokenUsage, this.error, this.diagnostic}): _profiles = profiles,_connectionStates = connectionStates,_agentConnectionStates = agentConnectionStates,_serverMetrics = serverMetrics,_agentSetupStates = agentSetupStates,_agentThreadLists = agentThreadLists,_agentModelLists = agentModelLists,_agentLoadingStates = agentLoadingStates,_threads = threads,_timeline = timeline,_models = models,_apiModelOptions = apiModelOptions,_workspaceDirectories = workspaceDirectories,_fileManagerEntries = fileManagerEntries,_approvalQueue = approvalQueue,_attachments = attachments;
  

@override@JsonKey() final  AppScreen screen;
@override@JsonKey() final  bool subAgentBackNavigation;
@override@JsonKey() final  bool debugModeEnabled;
 final  List<ServerProfile> _profiles;
@override@JsonKey() List<ServerProfile> get profiles {
  if (_profiles is EqualUnmodifiableListView) return _profiles;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_profiles);
}

@override final  String? selectedProfileId;
@override@JsonKey() final  ConnectionState connection;
 final  Map<String, ConnectionState> _connectionStates;
@override@JsonKey() Map<String, ConnectionState> get connectionStates {
  if (_connectionStates is EqualUnmodifiableMapView) return _connectionStates;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_connectionStates);
}

 final  Map<AgentConnectionKey, ConnectionState> _agentConnectionStates;
@override@JsonKey() Map<AgentConnectionKey, ConnectionState> get agentConnectionStates {
  if (_agentConnectionStates is EqualUnmodifiableMapView) return _agentConnectionStates;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_agentConnectionStates);
}

@override@JsonKey() final  AgentKind activeAgent;
@override@JsonKey() final  AgentCapabilities activeAgentCapabilities;
 final  Map<String, ServerMetrics> _serverMetrics;
@override@JsonKey() Map<String, ServerMetrics> get serverMetrics {
  if (_serverMetrics is EqualUnmodifiableMapView) return _serverMetrics;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_serverMetrics);
}

@override final  String? pendingFingerprint;
@override final  RemoteSetupPrompt? remoteSetup;
@override@JsonKey() final  bool setupInProgress;
@override@JsonKey() final  String setupProgress;
@override@JsonKey() final  int setupProgressPercent;
@override@JsonKey() final  String setupProgressDetail;
@override final  int? setupDownloadPercent;
 final  Map<AgentConnectionKey, AgentSetupState> _agentSetupStates;
@override@JsonKey() Map<AgentConnectionKey, AgentSetupState> get agentSetupStates {
  if (_agentSetupStates is EqualUnmodifiableMapView) return _agentSetupStates;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_agentSetupStates);
}

 final  Map<AgentConnectionKey, List<AgentThread>> _agentThreadLists;
@override@JsonKey() Map<AgentConnectionKey, List<AgentThread>> get agentThreadLists {
  if (_agentThreadLists is EqualUnmodifiableMapView) return _agentThreadLists;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_agentThreadLists);
}

 final  Map<AgentConnectionKey, List<AgentModel>> _agentModelLists;
@override@JsonKey() Map<AgentConnectionKey, List<AgentModel>> get agentModelLists {
  if (_agentModelLists is EqualUnmodifiableMapView) return _agentModelLists;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_agentModelLists);
}

 final  Map<AgentConnectionKey, bool> _agentLoadingStates;
@override@JsonKey() Map<AgentConnectionKey, bool> get agentLoadingStates {
  if (_agentLoadingStates is EqualUnmodifiableMapView) return _agentLoadingStates;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_agentLoadingStates);
}

 final  List<AgentThread> _threads;
@override@JsonKey() List<AgentThread> get threads {
  if (_threads is EqualUnmodifiableListView) return _threads;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_threads);
}

@override@JsonKey() final  String threadSearch;
@override final  AgentThread? activeThread;
@override final  String? activeAgentName;
@override final  ThreadGoal? activeGoal;
 final  List<TimelineEntry> _timeline;
@override@JsonKey() List<TimelineEntry> get timeline {
  if (_timeline is EqualUnmodifiableListView) return _timeline;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_timeline);
}

@override final  String? olderTurnsCursor;
@override@JsonKey() final  bool olderTurnsLoading;
@override final  String? activeTurnId;
@override@JsonKey() final  bool running;
@override final  TurnTiming? turnTiming;
@override@JsonKey() final  bool submitting;
@override@JsonKey() final  bool loading;
 final  List<AgentModel> _models;
@override@JsonKey() List<AgentModel> get models {
  if (_models is EqualUnmodifiableListView) return _models;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_models);
}

 final  List<ApiModelOption> _apiModelOptions;
@override@JsonKey() List<ApiModelOption> get apiModelOptions {
  if (_apiModelOptions is EqualUnmodifiableListView) return _apiModelOptions;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_apiModelOptions);
}

@override final  String? apiModelOptionsProfileId;
@override@JsonKey() final  bool apiModelOptionsLoading;
@override final  String? apiModelOptionsError;
@override final  String? selectedModel;
@override final  String? selectedEffort;
@override@JsonKey() final  ApprovalMode approvalMode;
@override@JsonKey() final  SandboxChoice sandbox;
@override@JsonKey() final  bool workspacePickerVisible;
@override@JsonKey() final  bool workspaceLoading;
@override@JsonKey() final  String workspaceCurrentPath;
@override final  String? workspaceParentPath;
 final  List<RemoteDirectory> _workspaceDirectories;
@override@JsonKey() List<RemoteDirectory> get workspaceDirectories {
  if (_workspaceDirectories is EqualUnmodifiableListView) return _workspaceDirectories;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_workspaceDirectories);
}

@override final  String? workspaceError;
@override final  String? fileManagerProfileId;
@override@JsonKey() final  bool fileManagerLoading;
@override@JsonKey() final  String fileManagerCurrentPath;
@override final  String? fileManagerParentPath;
 final  List<RemoteFileEntry> _fileManagerEntries;
@override@JsonKey() List<RemoteFileEntry> get fileManagerEntries {
  if (_fileManagerEntries is EqualUnmodifiableListView) return _fileManagerEntries;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_fileManagerEntries);
}

@override final  RemoteFileClipboard? fileManagerClipboard;
@override final  String? fileManagerOperation;
@override final  String? fileManagerError;
@override@JsonKey() final  bool agentSettingsVisible;
@override@JsonKey() final  bool agentSettingsLoading;
@override@JsonKey() final  bool agentSettingsSaving;
@override@JsonKey() final  bool agentSettingsTesting;
@override final  AgentGlobalSettings? agentSettings;
@override final  AgentConnectionTestResult? agentSettingsTestResult;
@override final  String? agentSettingsError;
@override final  ApprovalPrompt? approval;
 final  List<ApprovalPrompt> _approvalQueue;
@override@JsonKey() List<ApprovalPrompt> get approvalQueue {
  if (_approvalQueue is EqualUnmodifiableListView) return _approvalQueue;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_approvalQueue);
}

 final  List<PendingAttachment> _attachments;
@override@JsonKey() List<PendingAttachment> get attachments {
  if (_attachments is EqualUnmodifiableListView) return _attachments;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_attachments);
}

@override@JsonKey() final  bool attachmentUploading;
@override@JsonKey() final  int composerClearNonce;
@override@JsonKey() final  String composerDraft;
@override@JsonKey() final  String aggregateDiff;
@override final  TokenUsage? tokenUsage;
@override final  String? error;
@override final  String? diagnostic;

/// Create a copy of AppUiState
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$AppUiStateCopyWith<_AppUiState> get copyWith => __$AppUiStateCopyWithImpl<_AppUiState>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _AppUiState&&(identical(other.screen, screen) || other.screen == screen)&&(identical(other.subAgentBackNavigation, subAgentBackNavigation) || other.subAgentBackNavigation == subAgentBackNavigation)&&(identical(other.debugModeEnabled, debugModeEnabled) || other.debugModeEnabled == debugModeEnabled)&&const DeepCollectionEquality().equals(other._profiles, _profiles)&&(identical(other.selectedProfileId, selectedProfileId) || other.selectedProfileId == selectedProfileId)&&(identical(other.connection, connection) || other.connection == connection)&&const DeepCollectionEquality().equals(other._connectionStates, _connectionStates)&&const DeepCollectionEquality().equals(other._agentConnectionStates, _agentConnectionStates)&&(identical(other.activeAgent, activeAgent) || other.activeAgent == activeAgent)&&(identical(other.activeAgentCapabilities, activeAgentCapabilities) || other.activeAgentCapabilities == activeAgentCapabilities)&&const DeepCollectionEquality().equals(other._serverMetrics, _serverMetrics)&&(identical(other.pendingFingerprint, pendingFingerprint) || other.pendingFingerprint == pendingFingerprint)&&(identical(other.remoteSetup, remoteSetup) || other.remoteSetup == remoteSetup)&&(identical(other.setupInProgress, setupInProgress) || other.setupInProgress == setupInProgress)&&(identical(other.setupProgress, setupProgress) || other.setupProgress == setupProgress)&&(identical(other.setupProgressPercent, setupProgressPercent) || other.setupProgressPercent == setupProgressPercent)&&(identical(other.setupProgressDetail, setupProgressDetail) || other.setupProgressDetail == setupProgressDetail)&&(identical(other.setupDownloadPercent, setupDownloadPercent) || other.setupDownloadPercent == setupDownloadPercent)&&const DeepCollectionEquality().equals(other._agentSetupStates, _agentSetupStates)&&const DeepCollectionEquality().equals(other._agentThreadLists, _agentThreadLists)&&const DeepCollectionEquality().equals(other._agentModelLists, _agentModelLists)&&const DeepCollectionEquality().equals(other._agentLoadingStates, _agentLoadingStates)&&const DeepCollectionEquality().equals(other._threads, _threads)&&(identical(other.threadSearch, threadSearch) || other.threadSearch == threadSearch)&&(identical(other.activeThread, activeThread) || other.activeThread == activeThread)&&(identical(other.activeAgentName, activeAgentName) || other.activeAgentName == activeAgentName)&&(identical(other.activeGoal, activeGoal) || other.activeGoal == activeGoal)&&const DeepCollectionEquality().equals(other._timeline, _timeline)&&(identical(other.olderTurnsCursor, olderTurnsCursor) || other.olderTurnsCursor == olderTurnsCursor)&&(identical(other.olderTurnsLoading, olderTurnsLoading) || other.olderTurnsLoading == olderTurnsLoading)&&(identical(other.activeTurnId, activeTurnId) || other.activeTurnId == activeTurnId)&&(identical(other.running, running) || other.running == running)&&(identical(other.turnTiming, turnTiming) || other.turnTiming == turnTiming)&&(identical(other.submitting, submitting) || other.submitting == submitting)&&(identical(other.loading, loading) || other.loading == loading)&&const DeepCollectionEquality().equals(other._models, _models)&&const DeepCollectionEquality().equals(other._apiModelOptions, _apiModelOptions)&&(identical(other.apiModelOptionsProfileId, apiModelOptionsProfileId) || other.apiModelOptionsProfileId == apiModelOptionsProfileId)&&(identical(other.apiModelOptionsLoading, apiModelOptionsLoading) || other.apiModelOptionsLoading == apiModelOptionsLoading)&&(identical(other.apiModelOptionsError, apiModelOptionsError) || other.apiModelOptionsError == apiModelOptionsError)&&(identical(other.selectedModel, selectedModel) || other.selectedModel == selectedModel)&&(identical(other.selectedEffort, selectedEffort) || other.selectedEffort == selectedEffort)&&(identical(other.approvalMode, approvalMode) || other.approvalMode == approvalMode)&&(identical(other.sandbox, sandbox) || other.sandbox == sandbox)&&(identical(other.workspacePickerVisible, workspacePickerVisible) || other.workspacePickerVisible == workspacePickerVisible)&&(identical(other.workspaceLoading, workspaceLoading) || other.workspaceLoading == workspaceLoading)&&(identical(other.workspaceCurrentPath, workspaceCurrentPath) || other.workspaceCurrentPath == workspaceCurrentPath)&&(identical(other.workspaceParentPath, workspaceParentPath) || other.workspaceParentPath == workspaceParentPath)&&const DeepCollectionEquality().equals(other._workspaceDirectories, _workspaceDirectories)&&(identical(other.workspaceError, workspaceError) || other.workspaceError == workspaceError)&&(identical(other.fileManagerProfileId, fileManagerProfileId) || other.fileManagerProfileId == fileManagerProfileId)&&(identical(other.fileManagerLoading, fileManagerLoading) || other.fileManagerLoading == fileManagerLoading)&&(identical(other.fileManagerCurrentPath, fileManagerCurrentPath) || other.fileManagerCurrentPath == fileManagerCurrentPath)&&(identical(other.fileManagerParentPath, fileManagerParentPath) || other.fileManagerParentPath == fileManagerParentPath)&&const DeepCollectionEquality().equals(other._fileManagerEntries, _fileManagerEntries)&&(identical(other.fileManagerClipboard, fileManagerClipboard) || other.fileManagerClipboard == fileManagerClipboard)&&(identical(other.fileManagerOperation, fileManagerOperation) || other.fileManagerOperation == fileManagerOperation)&&(identical(other.fileManagerError, fileManagerError) || other.fileManagerError == fileManagerError)&&(identical(other.agentSettingsVisible, agentSettingsVisible) || other.agentSettingsVisible == agentSettingsVisible)&&(identical(other.agentSettingsLoading, agentSettingsLoading) || other.agentSettingsLoading == agentSettingsLoading)&&(identical(other.agentSettingsSaving, agentSettingsSaving) || other.agentSettingsSaving == agentSettingsSaving)&&(identical(other.agentSettingsTesting, agentSettingsTesting) || other.agentSettingsTesting == agentSettingsTesting)&&(identical(other.agentSettings, agentSettings) || other.agentSettings == agentSettings)&&(identical(other.agentSettingsTestResult, agentSettingsTestResult) || other.agentSettingsTestResult == agentSettingsTestResult)&&(identical(other.agentSettingsError, agentSettingsError) || other.agentSettingsError == agentSettingsError)&&(identical(other.approval, approval) || other.approval == approval)&&const DeepCollectionEquality().equals(other._approvalQueue, _approvalQueue)&&const DeepCollectionEquality().equals(other._attachments, _attachments)&&(identical(other.attachmentUploading, attachmentUploading) || other.attachmentUploading == attachmentUploading)&&(identical(other.composerClearNonce, composerClearNonce) || other.composerClearNonce == composerClearNonce)&&(identical(other.composerDraft, composerDraft) || other.composerDraft == composerDraft)&&(identical(other.aggregateDiff, aggregateDiff) || other.aggregateDiff == aggregateDiff)&&(identical(other.tokenUsage, tokenUsage) || other.tokenUsage == tokenUsage)&&(identical(other.error, error) || other.error == error)&&(identical(other.diagnostic, diagnostic) || other.diagnostic == diagnostic));
}


@override
int get hashCode => Object.hashAll([runtimeType,screen,subAgentBackNavigation,debugModeEnabled,const DeepCollectionEquality().hash(_profiles),selectedProfileId,connection,const DeepCollectionEquality().hash(_connectionStates),const DeepCollectionEquality().hash(_agentConnectionStates),activeAgent,activeAgentCapabilities,const DeepCollectionEquality().hash(_serverMetrics),pendingFingerprint,remoteSetup,setupInProgress,setupProgress,setupProgressPercent,setupProgressDetail,setupDownloadPercent,const DeepCollectionEquality().hash(_agentSetupStates),const DeepCollectionEquality().hash(_agentThreadLists),const DeepCollectionEquality().hash(_agentModelLists),const DeepCollectionEquality().hash(_agentLoadingStates),const DeepCollectionEquality().hash(_threads),threadSearch,activeThread,activeAgentName,activeGoal,const DeepCollectionEquality().hash(_timeline),olderTurnsCursor,olderTurnsLoading,activeTurnId,running,turnTiming,submitting,loading,const DeepCollectionEquality().hash(_models),const DeepCollectionEquality().hash(_apiModelOptions),apiModelOptionsProfileId,apiModelOptionsLoading,apiModelOptionsError,selectedModel,selectedEffort,approvalMode,sandbox,workspacePickerVisible,workspaceLoading,workspaceCurrentPath,workspaceParentPath,const DeepCollectionEquality().hash(_workspaceDirectories),workspaceError,fileManagerProfileId,fileManagerLoading,fileManagerCurrentPath,fileManagerParentPath,const DeepCollectionEquality().hash(_fileManagerEntries),fileManagerClipboard,fileManagerOperation,fileManagerError,agentSettingsVisible,agentSettingsLoading,agentSettingsSaving,agentSettingsTesting,agentSettings,agentSettingsTestResult,agentSettingsError,approval,const DeepCollectionEquality().hash(_approvalQueue),const DeepCollectionEquality().hash(_attachments),attachmentUploading,composerClearNonce,composerDraft,aggregateDiff,tokenUsage,error,diagnostic]);

@override
String toString() {
  return 'AppUiState(screen: $screen, subAgentBackNavigation: $subAgentBackNavigation, debugModeEnabled: $debugModeEnabled, profiles: $profiles, selectedProfileId: $selectedProfileId, connection: $connection, connectionStates: $connectionStates, agentConnectionStates: $agentConnectionStates, activeAgent: $activeAgent, activeAgentCapabilities: $activeAgentCapabilities, serverMetrics: $serverMetrics, pendingFingerprint: $pendingFingerprint, remoteSetup: $remoteSetup, setupInProgress: $setupInProgress, setupProgress: $setupProgress, setupProgressPercent: $setupProgressPercent, setupProgressDetail: $setupProgressDetail, setupDownloadPercent: $setupDownloadPercent, agentSetupStates: $agentSetupStates, agentThreadLists: $agentThreadLists, agentModelLists: $agentModelLists, agentLoadingStates: $agentLoadingStates, threads: $threads, threadSearch: $threadSearch, activeThread: $activeThread, activeAgentName: $activeAgentName, activeGoal: $activeGoal, timeline: $timeline, olderTurnsCursor: $olderTurnsCursor, olderTurnsLoading: $olderTurnsLoading, activeTurnId: $activeTurnId, running: $running, turnTiming: $turnTiming, submitting: $submitting, loading: $loading, models: $models, apiModelOptions: $apiModelOptions, apiModelOptionsProfileId: $apiModelOptionsProfileId, apiModelOptionsLoading: $apiModelOptionsLoading, apiModelOptionsError: $apiModelOptionsError, selectedModel: $selectedModel, selectedEffort: $selectedEffort, approvalMode: $approvalMode, sandbox: $sandbox, workspacePickerVisible: $workspacePickerVisible, workspaceLoading: $workspaceLoading, workspaceCurrentPath: $workspaceCurrentPath, workspaceParentPath: $workspaceParentPath, workspaceDirectories: $workspaceDirectories, workspaceError: $workspaceError, fileManagerProfileId: $fileManagerProfileId, fileManagerLoading: $fileManagerLoading, fileManagerCurrentPath: $fileManagerCurrentPath, fileManagerParentPath: $fileManagerParentPath, fileManagerEntries: $fileManagerEntries, fileManagerClipboard: $fileManagerClipboard, fileManagerOperation: $fileManagerOperation, fileManagerError: $fileManagerError, agentSettingsVisible: $agentSettingsVisible, agentSettingsLoading: $agentSettingsLoading, agentSettingsSaving: $agentSettingsSaving, agentSettingsTesting: $agentSettingsTesting, agentSettings: $agentSettings, agentSettingsTestResult: $agentSettingsTestResult, agentSettingsError: $agentSettingsError, approval: $approval, approvalQueue: $approvalQueue, attachments: $attachments, attachmentUploading: $attachmentUploading, composerClearNonce: $composerClearNonce, composerDraft: $composerDraft, aggregateDiff: $aggregateDiff, tokenUsage: $tokenUsage, error: $error, diagnostic: $diagnostic)';
}


}

/// @nodoc
abstract mixin class _$AppUiStateCopyWith<$Res> implements $AppUiStateCopyWith<$Res> {
  factory _$AppUiStateCopyWith(_AppUiState value, $Res Function(_AppUiState) _then) = __$AppUiStateCopyWithImpl;
@override @useResult
$Res call({
 AppScreen screen, bool subAgentBackNavigation, bool debugModeEnabled, List<ServerProfile> profiles, String? selectedProfileId, ConnectionState connection, Map<String, ConnectionState> connectionStates, Map<AgentConnectionKey, ConnectionState> agentConnectionStates, AgentKind activeAgent, AgentCapabilities activeAgentCapabilities, Map<String, ServerMetrics> serverMetrics, String? pendingFingerprint, RemoteSetupPrompt? remoteSetup, bool setupInProgress, String setupProgress, int setupProgressPercent, String setupProgressDetail, int? setupDownloadPercent, Map<AgentConnectionKey, AgentSetupState> agentSetupStates, Map<AgentConnectionKey, List<AgentThread>> agentThreadLists, Map<AgentConnectionKey, List<AgentModel>> agentModelLists, Map<AgentConnectionKey, bool> agentLoadingStates, List<AgentThread> threads, String threadSearch, AgentThread? activeThread, String? activeAgentName, ThreadGoal? activeGoal, List<TimelineEntry> timeline, String? olderTurnsCursor, bool olderTurnsLoading, String? activeTurnId, bool running, TurnTiming? turnTiming, bool submitting, bool loading, List<AgentModel> models, List<ApiModelOption> apiModelOptions, String? apiModelOptionsProfileId, bool apiModelOptionsLoading, String? apiModelOptionsError, String? selectedModel, String? selectedEffort, ApprovalMode approvalMode, SandboxChoice sandbox, bool workspacePickerVisible, bool workspaceLoading, String workspaceCurrentPath, String? workspaceParentPath, List<RemoteDirectory> workspaceDirectories, String? workspaceError, String? fileManagerProfileId, bool fileManagerLoading, String fileManagerCurrentPath, String? fileManagerParentPath, List<RemoteFileEntry> fileManagerEntries, RemoteFileClipboard? fileManagerClipboard, String? fileManagerOperation, String? fileManagerError, bool agentSettingsVisible, bool agentSettingsLoading, bool agentSettingsSaving, bool agentSettingsTesting, AgentGlobalSettings? agentSettings, AgentConnectionTestResult? agentSettingsTestResult, String? agentSettingsError, ApprovalPrompt? approval, List<ApprovalPrompt> approvalQueue, List<PendingAttachment> attachments, bool attachmentUploading, int composerClearNonce, String composerDraft, String aggregateDiff, TokenUsage? tokenUsage, String? error, String? diagnostic
});


@override $ConnectionStateCopyWith<$Res> get connection;@override $AgentCapabilitiesCopyWith<$Res> get activeAgentCapabilities;@override $RemoteSetupPromptCopyWith<$Res>? get remoteSetup;@override $AgentThreadCopyWith<$Res>? get activeThread;@override $ThreadGoalCopyWith<$Res>? get activeGoal;@override $TurnTimingCopyWith<$Res>? get turnTiming;@override $RemoteFileClipboardCopyWith<$Res>? get fileManagerClipboard;@override $AgentGlobalSettingsCopyWith<$Res>? get agentSettings;@override $AgentConnectionTestResultCopyWith<$Res>? get agentSettingsTestResult;@override $ApprovalPromptCopyWith<$Res>? get approval;@override $TokenUsageCopyWith<$Res>? get tokenUsage;

}
/// @nodoc
class __$AppUiStateCopyWithImpl<$Res>
    implements _$AppUiStateCopyWith<$Res> {
  __$AppUiStateCopyWithImpl(this._self, this._then);

  final _AppUiState _self;
  final $Res Function(_AppUiState) _then;

/// Create a copy of AppUiState
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? screen = null,Object? subAgentBackNavigation = null,Object? debugModeEnabled = null,Object? profiles = null,Object? selectedProfileId = freezed,Object? connection = null,Object? connectionStates = null,Object? agentConnectionStates = null,Object? activeAgent = null,Object? activeAgentCapabilities = null,Object? serverMetrics = null,Object? pendingFingerprint = freezed,Object? remoteSetup = freezed,Object? setupInProgress = null,Object? setupProgress = null,Object? setupProgressPercent = null,Object? setupProgressDetail = null,Object? setupDownloadPercent = freezed,Object? agentSetupStates = null,Object? agentThreadLists = null,Object? agentModelLists = null,Object? agentLoadingStates = null,Object? threads = null,Object? threadSearch = null,Object? activeThread = freezed,Object? activeAgentName = freezed,Object? activeGoal = freezed,Object? timeline = null,Object? olderTurnsCursor = freezed,Object? olderTurnsLoading = null,Object? activeTurnId = freezed,Object? running = null,Object? turnTiming = freezed,Object? submitting = null,Object? loading = null,Object? models = null,Object? apiModelOptions = null,Object? apiModelOptionsProfileId = freezed,Object? apiModelOptionsLoading = null,Object? apiModelOptionsError = freezed,Object? selectedModel = freezed,Object? selectedEffort = freezed,Object? approvalMode = null,Object? sandbox = null,Object? workspacePickerVisible = null,Object? workspaceLoading = null,Object? workspaceCurrentPath = null,Object? workspaceParentPath = freezed,Object? workspaceDirectories = null,Object? workspaceError = freezed,Object? fileManagerProfileId = freezed,Object? fileManagerLoading = null,Object? fileManagerCurrentPath = null,Object? fileManagerParentPath = freezed,Object? fileManagerEntries = null,Object? fileManagerClipboard = freezed,Object? fileManagerOperation = freezed,Object? fileManagerError = freezed,Object? agentSettingsVisible = null,Object? agentSettingsLoading = null,Object? agentSettingsSaving = null,Object? agentSettingsTesting = null,Object? agentSettings = freezed,Object? agentSettingsTestResult = freezed,Object? agentSettingsError = freezed,Object? approval = freezed,Object? approvalQueue = null,Object? attachments = null,Object? attachmentUploading = null,Object? composerClearNonce = null,Object? composerDraft = null,Object? aggregateDiff = null,Object? tokenUsage = freezed,Object? error = freezed,Object? diagnostic = freezed,}) {
  return _then(_AppUiState(
screen: null == screen ? _self.screen : screen // ignore: cast_nullable_to_non_nullable
as AppScreen,subAgentBackNavigation: null == subAgentBackNavigation ? _self.subAgentBackNavigation : subAgentBackNavigation // ignore: cast_nullable_to_non_nullable
as bool,debugModeEnabled: null == debugModeEnabled ? _self.debugModeEnabled : debugModeEnabled // ignore: cast_nullable_to_non_nullable
as bool,profiles: null == profiles ? _self._profiles : profiles // ignore: cast_nullable_to_non_nullable
as List<ServerProfile>,selectedProfileId: freezed == selectedProfileId ? _self.selectedProfileId : selectedProfileId // ignore: cast_nullable_to_non_nullable
as String?,connection: null == connection ? _self.connection : connection // ignore: cast_nullable_to_non_nullable
as ConnectionState,connectionStates: null == connectionStates ? _self._connectionStates : connectionStates // ignore: cast_nullable_to_non_nullable
as Map<String, ConnectionState>,agentConnectionStates: null == agentConnectionStates ? _self._agentConnectionStates : agentConnectionStates // ignore: cast_nullable_to_non_nullable
as Map<AgentConnectionKey, ConnectionState>,activeAgent: null == activeAgent ? _self.activeAgent : activeAgent // ignore: cast_nullable_to_non_nullable
as AgentKind,activeAgentCapabilities: null == activeAgentCapabilities ? _self.activeAgentCapabilities : activeAgentCapabilities // ignore: cast_nullable_to_non_nullable
as AgentCapabilities,serverMetrics: null == serverMetrics ? _self._serverMetrics : serverMetrics // ignore: cast_nullable_to_non_nullable
as Map<String, ServerMetrics>,pendingFingerprint: freezed == pendingFingerprint ? _self.pendingFingerprint : pendingFingerprint // ignore: cast_nullable_to_non_nullable
as String?,remoteSetup: freezed == remoteSetup ? _self.remoteSetup : remoteSetup // ignore: cast_nullable_to_non_nullable
as RemoteSetupPrompt?,setupInProgress: null == setupInProgress ? _self.setupInProgress : setupInProgress // ignore: cast_nullable_to_non_nullable
as bool,setupProgress: null == setupProgress ? _self.setupProgress : setupProgress // ignore: cast_nullable_to_non_nullable
as String,setupProgressPercent: null == setupProgressPercent ? _self.setupProgressPercent : setupProgressPercent // ignore: cast_nullable_to_non_nullable
as int,setupProgressDetail: null == setupProgressDetail ? _self.setupProgressDetail : setupProgressDetail // ignore: cast_nullable_to_non_nullable
as String,setupDownloadPercent: freezed == setupDownloadPercent ? _self.setupDownloadPercent : setupDownloadPercent // ignore: cast_nullable_to_non_nullable
as int?,agentSetupStates: null == agentSetupStates ? _self._agentSetupStates : agentSetupStates // ignore: cast_nullable_to_non_nullable
as Map<AgentConnectionKey, AgentSetupState>,agentThreadLists: null == agentThreadLists ? _self._agentThreadLists : agentThreadLists // ignore: cast_nullable_to_non_nullable
as Map<AgentConnectionKey, List<AgentThread>>,agentModelLists: null == agentModelLists ? _self._agentModelLists : agentModelLists // ignore: cast_nullable_to_non_nullable
as Map<AgentConnectionKey, List<AgentModel>>,agentLoadingStates: null == agentLoadingStates ? _self._agentLoadingStates : agentLoadingStates // ignore: cast_nullable_to_non_nullable
as Map<AgentConnectionKey, bool>,threads: null == threads ? _self._threads : threads // ignore: cast_nullable_to_non_nullable
as List<AgentThread>,threadSearch: null == threadSearch ? _self.threadSearch : threadSearch // ignore: cast_nullable_to_non_nullable
as String,activeThread: freezed == activeThread ? _self.activeThread : activeThread // ignore: cast_nullable_to_non_nullable
as AgentThread?,activeAgentName: freezed == activeAgentName ? _self.activeAgentName : activeAgentName // ignore: cast_nullable_to_non_nullable
as String?,activeGoal: freezed == activeGoal ? _self.activeGoal : activeGoal // ignore: cast_nullable_to_non_nullable
as ThreadGoal?,timeline: null == timeline ? _self._timeline : timeline // ignore: cast_nullable_to_non_nullable
as List<TimelineEntry>,olderTurnsCursor: freezed == olderTurnsCursor ? _self.olderTurnsCursor : olderTurnsCursor // ignore: cast_nullable_to_non_nullable
as String?,olderTurnsLoading: null == olderTurnsLoading ? _self.olderTurnsLoading : olderTurnsLoading // ignore: cast_nullable_to_non_nullable
as bool,activeTurnId: freezed == activeTurnId ? _self.activeTurnId : activeTurnId // ignore: cast_nullable_to_non_nullable
as String?,running: null == running ? _self.running : running // ignore: cast_nullable_to_non_nullable
as bool,turnTiming: freezed == turnTiming ? _self.turnTiming : turnTiming // ignore: cast_nullable_to_non_nullable
as TurnTiming?,submitting: null == submitting ? _self.submitting : submitting // ignore: cast_nullable_to_non_nullable
as bool,loading: null == loading ? _self.loading : loading // ignore: cast_nullable_to_non_nullable
as bool,models: null == models ? _self._models : models // ignore: cast_nullable_to_non_nullable
as List<AgentModel>,apiModelOptions: null == apiModelOptions ? _self._apiModelOptions : apiModelOptions // ignore: cast_nullable_to_non_nullable
as List<ApiModelOption>,apiModelOptionsProfileId: freezed == apiModelOptionsProfileId ? _self.apiModelOptionsProfileId : apiModelOptionsProfileId // ignore: cast_nullable_to_non_nullable
as String?,apiModelOptionsLoading: null == apiModelOptionsLoading ? _self.apiModelOptionsLoading : apiModelOptionsLoading // ignore: cast_nullable_to_non_nullable
as bool,apiModelOptionsError: freezed == apiModelOptionsError ? _self.apiModelOptionsError : apiModelOptionsError // ignore: cast_nullable_to_non_nullable
as String?,selectedModel: freezed == selectedModel ? _self.selectedModel : selectedModel // ignore: cast_nullable_to_non_nullable
as String?,selectedEffort: freezed == selectedEffort ? _self.selectedEffort : selectedEffort // ignore: cast_nullable_to_non_nullable
as String?,approvalMode: null == approvalMode ? _self.approvalMode : approvalMode // ignore: cast_nullable_to_non_nullable
as ApprovalMode,sandbox: null == sandbox ? _self.sandbox : sandbox // ignore: cast_nullable_to_non_nullable
as SandboxChoice,workspacePickerVisible: null == workspacePickerVisible ? _self.workspacePickerVisible : workspacePickerVisible // ignore: cast_nullable_to_non_nullable
as bool,workspaceLoading: null == workspaceLoading ? _self.workspaceLoading : workspaceLoading // ignore: cast_nullable_to_non_nullable
as bool,workspaceCurrentPath: null == workspaceCurrentPath ? _self.workspaceCurrentPath : workspaceCurrentPath // ignore: cast_nullable_to_non_nullable
as String,workspaceParentPath: freezed == workspaceParentPath ? _self.workspaceParentPath : workspaceParentPath // ignore: cast_nullable_to_non_nullable
as String?,workspaceDirectories: null == workspaceDirectories ? _self._workspaceDirectories : workspaceDirectories // ignore: cast_nullable_to_non_nullable
as List<RemoteDirectory>,workspaceError: freezed == workspaceError ? _self.workspaceError : workspaceError // ignore: cast_nullable_to_non_nullable
as String?,fileManagerProfileId: freezed == fileManagerProfileId ? _self.fileManagerProfileId : fileManagerProfileId // ignore: cast_nullable_to_non_nullable
as String?,fileManagerLoading: null == fileManagerLoading ? _self.fileManagerLoading : fileManagerLoading // ignore: cast_nullable_to_non_nullable
as bool,fileManagerCurrentPath: null == fileManagerCurrentPath ? _self.fileManagerCurrentPath : fileManagerCurrentPath // ignore: cast_nullable_to_non_nullable
as String,fileManagerParentPath: freezed == fileManagerParentPath ? _self.fileManagerParentPath : fileManagerParentPath // ignore: cast_nullable_to_non_nullable
as String?,fileManagerEntries: null == fileManagerEntries ? _self._fileManagerEntries : fileManagerEntries // ignore: cast_nullable_to_non_nullable
as List<RemoteFileEntry>,fileManagerClipboard: freezed == fileManagerClipboard ? _self.fileManagerClipboard : fileManagerClipboard // ignore: cast_nullable_to_non_nullable
as RemoteFileClipboard?,fileManagerOperation: freezed == fileManagerOperation ? _self.fileManagerOperation : fileManagerOperation // ignore: cast_nullable_to_non_nullable
as String?,fileManagerError: freezed == fileManagerError ? _self.fileManagerError : fileManagerError // ignore: cast_nullable_to_non_nullable
as String?,agentSettingsVisible: null == agentSettingsVisible ? _self.agentSettingsVisible : agentSettingsVisible // ignore: cast_nullable_to_non_nullable
as bool,agentSettingsLoading: null == agentSettingsLoading ? _self.agentSettingsLoading : agentSettingsLoading // ignore: cast_nullable_to_non_nullable
as bool,agentSettingsSaving: null == agentSettingsSaving ? _self.agentSettingsSaving : agentSettingsSaving // ignore: cast_nullable_to_non_nullable
as bool,agentSettingsTesting: null == agentSettingsTesting ? _self.agentSettingsTesting : agentSettingsTesting // ignore: cast_nullable_to_non_nullable
as bool,agentSettings: freezed == agentSettings ? _self.agentSettings : agentSettings // ignore: cast_nullable_to_non_nullable
as AgentGlobalSettings?,agentSettingsTestResult: freezed == agentSettingsTestResult ? _self.agentSettingsTestResult : agentSettingsTestResult // ignore: cast_nullable_to_non_nullable
as AgentConnectionTestResult?,agentSettingsError: freezed == agentSettingsError ? _self.agentSettingsError : agentSettingsError // ignore: cast_nullable_to_non_nullable
as String?,approval: freezed == approval ? _self.approval : approval // ignore: cast_nullable_to_non_nullable
as ApprovalPrompt?,approvalQueue: null == approvalQueue ? _self._approvalQueue : approvalQueue // ignore: cast_nullable_to_non_nullable
as List<ApprovalPrompt>,attachments: null == attachments ? _self._attachments : attachments // ignore: cast_nullable_to_non_nullable
as List<PendingAttachment>,attachmentUploading: null == attachmentUploading ? _self.attachmentUploading : attachmentUploading // ignore: cast_nullable_to_non_nullable
as bool,composerClearNonce: null == composerClearNonce ? _self.composerClearNonce : composerClearNonce // ignore: cast_nullable_to_non_nullable
as int,composerDraft: null == composerDraft ? _self.composerDraft : composerDraft // ignore: cast_nullable_to_non_nullable
as String,aggregateDiff: null == aggregateDiff ? _self.aggregateDiff : aggregateDiff // ignore: cast_nullable_to_non_nullable
as String,tokenUsage: freezed == tokenUsage ? _self.tokenUsage : tokenUsage // ignore: cast_nullable_to_non_nullable
as TokenUsage?,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as String?,diagnostic: freezed == diagnostic ? _self.diagnostic : diagnostic // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

/// Create a copy of AppUiState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ConnectionStateCopyWith<$Res> get connection {
  
  return $ConnectionStateCopyWith<$Res>(_self.connection, (value) {
    return _then(_self.copyWith(connection: value));
  });
}/// Create a copy of AppUiState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$AgentCapabilitiesCopyWith<$Res> get activeAgentCapabilities {
  
  return $AgentCapabilitiesCopyWith<$Res>(_self.activeAgentCapabilities, (value) {
    return _then(_self.copyWith(activeAgentCapabilities: value));
  });
}/// Create a copy of AppUiState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$RemoteSetupPromptCopyWith<$Res>? get remoteSetup {
    if (_self.remoteSetup == null) {
    return null;
  }

  return $RemoteSetupPromptCopyWith<$Res>(_self.remoteSetup!, (value) {
    return _then(_self.copyWith(remoteSetup: value));
  });
}/// Create a copy of AppUiState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$AgentThreadCopyWith<$Res>? get activeThread {
    if (_self.activeThread == null) {
    return null;
  }

  return $AgentThreadCopyWith<$Res>(_self.activeThread!, (value) {
    return _then(_self.copyWith(activeThread: value));
  });
}/// Create a copy of AppUiState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ThreadGoalCopyWith<$Res>? get activeGoal {
    if (_self.activeGoal == null) {
    return null;
  }

  return $ThreadGoalCopyWith<$Res>(_self.activeGoal!, (value) {
    return _then(_self.copyWith(activeGoal: value));
  });
}/// Create a copy of AppUiState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$TurnTimingCopyWith<$Res>? get turnTiming {
    if (_self.turnTiming == null) {
    return null;
  }

  return $TurnTimingCopyWith<$Res>(_self.turnTiming!, (value) {
    return _then(_self.copyWith(turnTiming: value));
  });
}/// Create a copy of AppUiState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$RemoteFileClipboardCopyWith<$Res>? get fileManagerClipboard {
    if (_self.fileManagerClipboard == null) {
    return null;
  }

  return $RemoteFileClipboardCopyWith<$Res>(_self.fileManagerClipboard!, (value) {
    return _then(_self.copyWith(fileManagerClipboard: value));
  });
}/// Create a copy of AppUiState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$AgentGlobalSettingsCopyWith<$Res>? get agentSettings {
    if (_self.agentSettings == null) {
    return null;
  }

  return $AgentGlobalSettingsCopyWith<$Res>(_self.agentSettings!, (value) {
    return _then(_self.copyWith(agentSettings: value));
  });
}/// Create a copy of AppUiState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$AgentConnectionTestResultCopyWith<$Res>? get agentSettingsTestResult {
    if (_self.agentSettingsTestResult == null) {
    return null;
  }

  return $AgentConnectionTestResultCopyWith<$Res>(_self.agentSettingsTestResult!, (value) {
    return _then(_self.copyWith(agentSettingsTestResult: value));
  });
}/// Create a copy of AppUiState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ApprovalPromptCopyWith<$Res>? get approval {
    if (_self.approval == null) {
    return null;
  }

  return $ApprovalPromptCopyWith<$Res>(_self.approval!, (value) {
    return _then(_self.copyWith(approval: value));
  });
}/// Create a copy of AppUiState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$TokenUsageCopyWith<$Res>? get tokenUsage {
    if (_self.tokenUsage == null) {
    return null;
  }

  return $TokenUsageCopyWith<$Res>(_self.tokenUsage!, (value) {
    return _then(_self.copyWith(tokenUsage: value));
  });
}
}

// dart format on
