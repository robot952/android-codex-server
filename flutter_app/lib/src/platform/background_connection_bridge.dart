import 'dart:convert';

import 'package:flutter/services.dart';

const String _backgroundHostArgumentPrefix = '--agent-background-host=';
const String _backgroundAgentArgumentPrefix = '--agent-background-agent=';
const int _maxBackgroundConnectionIntents = 64;
const int _maxBackgroundConnectionIntentChars = 512;
// Base64 expands the 512-character raw value by roughly four thirds.
const int _maxEncodedEntrypointValueChars = 768;

class BackgroundConnectionIntent {
  const BackgroundConnectionIntent({
    this.hostProfileIds = const <String>[],
    this.agentConnectionKeys = const <String>[],
  });

  factory BackgroundConnectionIntent.fromEntrypointArguments(
    List<String> arguments,
  ) {
    final hosts = <String>{};
    final agents = <String>{};
    for (final argument in arguments) {
      if (hosts.length + agents.length >= _maxBackgroundConnectionIntents) {
        break;
      }
      if (argument.startsWith(_backgroundHostArgumentPrefix)) {
        final value = _decodeEntrypointValue(
          argument.substring(_backgroundHostArgumentPrefix.length),
        );
        if (value != null && !value.contains('\u0000')) hosts.add(value);
      } else if (argument.startsWith(_backgroundAgentArgumentPrefix)) {
        final value = _decodeEntrypointValue(
          argument.substring(_backgroundAgentArgumentPrefix.length),
        );
        if (decodeBackgroundAgentConnectionKey(value ?? '') != null) {
          agents.add(value!);
        }
      }
    }
    return BackgroundConnectionIntent(
      hostProfileIds: List<String>.unmodifiable(hosts),
      agentConnectionKeys: List<String>.unmodifiable(agents),
    );
  }

  final List<String> hostProfileIds;
  final List<String> agentConnectionKeys;

  bool get isEmpty => hostProfileIds.isEmpty && agentConnectionKeys.isEmpty;

  String get signature {
    final hosts = hostProfileIds.toList()..sort();
    final agents = agentConnectionKeys.toList()..sort();
    return jsonEncode(<String, List<String>>{'hosts': hosts, 'agents': agents});
  }

  Map<String, Object> toChannelArguments() => <String, Object>{
    'hostProfileIds': hostProfileIds,
    'agentConnectionKeys': agentConnectionKeys,
  };
}

String backgroundAgentConnectionKey(String profileId, String agent) =>
    '$profileId\u0000$agent';

({String profileId, String agent})? decodeBackgroundAgentConnectionKey(
  String value,
) {
  if (value.isEmpty || value.length > _maxBackgroundConnectionIntentChars) {
    return null;
  }
  final separator = value.indexOf('\u0000');
  if (separator <= 0 || separator == value.length - 1) return null;
  final profileId = value.substring(0, separator).trim();
  final agent = value.substring(separator + 1).trim();
  if (profileId.isEmpty || agent.isEmpty || agent.contains('\u0000')) {
    return null;
  }
  return (profileId: profileId, agent: agent);
}

String? _decodeEntrypointValue(String encoded) {
  if (encoded.isEmpty || encoded.length > _maxEncodedEntrypointValueChars) {
    return null;
  }
  try {
    final value = utf8.decode(base64Url.decode(base64Url.normalize(encoded)));
    if (value.isEmpty || value.length > _maxBackgroundConnectionIntentChars) {
      return null;
    }
    return value;
  } on FormatException {
    return null;
  }
}

/// Small bridge to the Android foreground service that keeps the Flutter
/// process and its SSH/Codex sockets eligible to run while the activity is in
/// the background. The native service persists only the connection intent and
/// starts a headless Flutter engine after a sticky process restart; protocol
/// state and reconnect policy remain owned by Dart. It also holds a partial
/// wake lock and a silent foreground notification.
class BackgroundConnectionBridge {
  const BackgroundConnectionBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'top.asdb.agent/background';
  final MethodChannel _channel;

  /// Registers the native foreground-service heartbeat callback. The service
  /// invokes this continuously while a retained connection exists, so SSH
  /// keepalive traffic does not depend on a Dart timer or the UI lifecycle.
  void registerHeartbeat(Future<void> Function() callback) {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'heartbeat') return null;
      await callback();
      return true;
    });
  }

  void unregisterHeartbeat() {
    _channel.setMethodCallHandler(null);
  }

  Future<void> setEnabled(
    bool enabled, {
    BackgroundConnectionIntent intent = const BackgroundConnectionIntent(),
  }) async {
    try {
      await _channel.invokeMethod<void>(
        enabled ? 'start' : 'stop',
        enabled ? intent.toChannelArguments() : null,
      );
    } on MissingPluginException {
      // Desktop/test hosts have no Android service.
    } on PlatformException {
      // A service failure must not tear down an active SSH lane.
    }
  }

  Future<bool> moveTaskToBackground() async {
    try {
      return await _channel.invokeMethod<bool>('moveToBackground') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}

const backgroundConnectionBridge = BackgroundConnectionBridge();
