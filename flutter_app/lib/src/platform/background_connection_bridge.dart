import 'package:flutter/services.dart';

/// Small bridge to the Android foreground service that keeps the Flutter
/// process and its SSH/Codex sockets eligible to run while the activity is in
/// the background.  The service does not own protocol state; it only holds a
/// partial wake lock and a silent foreground notification.
class BackgroundConnectionBridge {
  const BackgroundConnectionBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'top.asdb.agent/background';
  final MethodChannel _channel;

  Future<void> setEnabled(bool enabled) async {
    try {
      await _channel.invokeMethod<void>(enabled ? 'start' : 'stop');
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
