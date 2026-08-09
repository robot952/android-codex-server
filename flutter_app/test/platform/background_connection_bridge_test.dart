import 'package:codex_remote/src/platform/background_connection_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/background');

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('starts, stops, and backgrounds through the Android channel', () async {
    final methods = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          methods.add(call.method);
          return call.method == 'moveToBackground';
        });
    const bridge = BackgroundConnectionBridge(channel: channel);

    await bridge.setEnabled(true);
    expect(await bridge.moveTaskToBackground(), isTrue);
    await bridge.setEnabled(false);

    expect(methods, ['start', 'moveToBackground', 'stop']);
  });

  test('platform failures never close or crash an active connection', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          throw PlatformException(code: 'unavailable');
        });
    const bridge = BackgroundConnectionBridge(channel: channel);

    await bridge.setEnabled(true);
    expect(await bridge.moveTaskToBackground(), isFalse);
  });
}
