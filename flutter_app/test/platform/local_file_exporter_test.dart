import 'package:codex_remote/src/platform/local_file_exporter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/file_export');

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('streams chunks and completes the selected export session', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'beginExport') {
            return <String, Object?>{'token': 'one'};
          }
          return null;
        });
    const exporter = AndroidLocalFileExporter(channel: channel);

    final session = await exporter.begin(
      fileName: 'result.apk',
      mimeType: 'application/vnd.android.package-archive',
    );
    await session!.write(Uint8List.fromList(<int>[1, 2, 3]));
    await session.complete();

    expect(calls.map((call) => call.method), <String>[
      'beginExport',
      'writeExportChunk',
      'finishExport',
    ]);
    expect(
      (calls.last.arguments as Map<Object?, Object?>)['successful'],
      isTrue,
    );
  });

  test('returns null when the system picker is cancelled', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    const exporter = AndroidLocalFileExporter(channel: channel);

    expect(await exporter.begin(fileName: 'cancelled.txt'), isNull);
  });

  test('aborts once and rejects writes after closing', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'beginExport'
              ? <String, Object?>{'token': 'two'}
              : null;
        });
    const exporter = AndroidLocalFileExporter(channel: channel);
    final session = await exporter.begin(fileName: 'partial.bin');

    await session!.abort();
    await session.abort();

    expect(calls.where((call) => call.method == 'finishExport'), hasLength(1));
    expect(session.write(Uint8List.fromList(<int>[1])), throwsStateError);
  });
}
