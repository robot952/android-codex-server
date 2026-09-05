import 'dart:async';
import 'dart:convert';

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
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'moveToBackground';
        });
    const bridge = BackgroundConnectionBridge(channel: channel);
    const intent = BackgroundConnectionIntent(
      hostProfileIds: <String>['server-a'],
      agentConnectionKeys: <String>['server-a\u0000codex'],
    );

    await bridge.setEnabled(true, intent: intent);
    expect(await bridge.moveTaskToBackground(), isTrue);
    await bridge.setEnabled(false);

    expect(calls.map((call) => call.method), [
      'start',
      'moveToBackground',
      'stop',
    ]);
    expect(calls.first.arguments, <String, Object>{
      'hostProfileIds': <String>['server-a'],
      'agentConnectionKeys': <String>['server-a\u0000codex'],
    });
    expect(calls.last.arguments, isNull);
  });

  test('forwards native task-removal shutdown to Dart cleanup', () async {
    const bridge = BackgroundConnectionBridge(channel: channel);
    var heartbeatCalls = 0;
    var shutdownCalls = 0;
    bridge.registerHeartbeat(
      (_) async => heartbeatCalls++,
      onShutdown: () async => shutdownCalls++,
    );

    final response = Completer<ByteData?>();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(MethodCall('shutdown')),
          response.complete,
        );
    await response.future;

    expect(heartbeatCalls, 0);
    expect(shutdownCalls, 1);
  });

  test('decodes bounded connection intents from a sticky service restart', () {
    String encoded(String value) =>
        base64Url.encode(utf8.encode(value)).replaceAll('=', '');

    final intent = BackgroundConnectionIntent.fromEntrypointArguments(<String>[
      '--unrelated=value',
      '--agent-background-host=${encoded('server-a')}',
      '--agent-background-host=${encoded('server-a')}',
      '--agent-background-agent=${encoded('server-a\u0000codex')}',
      '--agent-background-agent=${encoded('invalid')}',
      '--agent-background-host=not-base64!',
    ]);

    expect(intent.hostProfileIds, <String>['server-a']);
    expect(intent.agentConnectionKeys, <String>['server-a\u0000codex']);
    expect(
      decodeBackgroundAgentConnectionKey(intent.agentConnectionKeys.single),
      (profileId: 'server-a', agent: 'codex'),
    );
  });

  test('uses a collision-safe stable signature for connection intents', () {
    const first = BackgroundConnectionIntent(
      hostProfileIds: <String>['a,b'],
      agentConnectionKeys: <String>['lane|codex'],
    );
    const second = BackgroundConnectionIntent(
      hostProfileIds: <String>['a', 'b'],
      agentConnectionKeys: <String>['lane', 'codex'],
    );

    expect(first.signature, isNot(second.signature));
    expect(first.signature, '{"hosts":["a,b"],"agents":["lane|codex"]}');
  });

  test('decodes native heartbeat correlation fields with bounded delay', () {
    final heartbeat = BackgroundHeartbeat.fromChannelArguments(<String, Object>{
      'sequence': 42,
      'sentAtEpochMs': 1_000,
      'skippedBefore': 3,
    });

    expect(heartbeat.sequence, 42);
    expect(heartbeat.skippedBefore, 3);
    expect(
      heartbeat.deliveryDelayMillis(DateTime.fromMillisecondsSinceEpoch(1_250)),
      250,
    );

    final malformed = BackgroundHeartbeat.fromChannelArguments(<String, Object>{
      'sequence': -1,
      'sentAtEpochMs': 'invalid',
    });
    expect(malformed.sequence, 0);
    expect(malformed.deliveryDelayMillis(DateTime.now()), 0);
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
