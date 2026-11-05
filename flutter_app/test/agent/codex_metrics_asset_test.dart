import 'dart:convert';
import 'dart:io';

import 'package:codex_remote/src/agent/codex_metrics_asset.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loads history compatibility assets before the metrics relay', () async {
    final paths = [
      'assets/codex-history-compat.cjs',
      'assets/codex-history-proxy.cjs',
      'assets/codex-history-relay.cjs',
      'assets/codex-request-metrics.cjs',
    ];
    final sources = await Future.wait(paths.map(rootBundle.loadString));
    final bundled = await CodexMetricsAsset.load();
    expect(bundled, sources.join('\n'));
    final result = await Process.run('node', [
      '-e',
      '$bundled\n'
          'if (typeof normalizeResponsesHistory !== "function" || '
          'typeof createHistoryProxy !== "function" || '
          'typeof createHistoryRpcBridge !== "function" || '
          'typeof runRelay !== "function") process.exit(2);',
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  });

  test('routes both streams and closes history resources once', () async {
    final result = await _runRelayProbe(proxyFails: false);
    expect(result.output['value'], 'bridged:hello\n');
    final bypass = (result.output['bypass'] as String).split(',');
    expect(bypass, containsAll(['upstream.example', '127.0.0.1', 'localhost']));
    expect(result.stderr, contains('input-routed\n'));
    expect(result.stderr, contains('output-routed\n'));
    expect(result.stderr, contains('input-ended\n'));
    expect('bridge-closed'.allMatches(result.stderr), hasLength(1));
    expect('proxy-closed'.allMatches(result.stderr), hasLength(1));
  });

  test(
    'proxy startup failure falls back without logging exception data',
    () async {
      final result = await _runRelayProbe(proxyFails: true);
      expect(result.output['value'], 'bridged:hello\n');
      expect(result.output['bypass'], 'upstream.example');
      expect(
        result.stderr,
        contains(
          'Codex history compatibility proxy unavailable; continuing normally.',
        ),
      );
      expect(result.stderr, isNot(contains('sensitive-fixture-value')));
      expect(result.stderr, isNot(contains('proxy-closed')));
      expect('bridge-closed'.allMatches(result.stderr), hasLength(1));
    },
  );
}

Future<({Map<String, dynamic> output, String stderr})> _runRelayProbe({
  required bool proxyFails,
}) async {
  final relayPath = File('assets/codex-request-metrics.cjs').absolute.path;
  final childScript = '''
process.on("SIGTERM", () => process.exit(0));
process.stdin.on("data", chunk => process.stdout.write(JSON.stringify({
  value: chunk.toString(), bypass: process.env.NO_PROXY
}) + "\\n"));
''';
  final script =
      '''
const assert = require("node:assert/strict");
const upstreamBypass = process.env.NO_PROXY;
const proxy = { close: async () => process.stderr.write("proxy-closed\\n") };
global.createHistoryProxy = async ({env}) => {
  assert.equal(env.NO_PROXY, "upstream.example");
  assert.equal(process.env.NO_PROXY, upstreamBypass);
  ${proxyFails ? 'throw new Error("sensitive-fixture-value");' : 'return proxy;'}
};
global.createHistoryRpcBridge = ({send, output, proxy: actualProxy}) => {
  assert.equal(actualProxy, ${proxyFails ? 'null' : 'proxy'});
  let inputFinished = false;
  return {
    writeInput: chunk => {
      assert.equal(process.env.NO_PROXY, "upstream.example");
      process.stderr.write("input-routed\\n");
      send(Buffer.from("bridged:" + chunk));
    },
    writeOutput: chunk => {
      process.stderr.write("output-routed\\n");
      output(chunk);
    },
    endInput: async () => {
      await new Promise(resolve => setTimeout(resolve, 5));
      inputFinished = true;
      process.stderr.write("input-ended\\n");
    },
    close: () => {
      assert.equal(inputFinished, true);
      process.stderr.write("bridge-closed\\n");
    },
  };
};
const quote = value => "'" + value.replaceAll("'", "'\\"'\\"'") + "'";
require(${jsonEncode(relayPath)}).runRelay(
  quote(process.execPath) + " -e " + quote(${jsonEncode(childScript)})
).catch(() => process.exit(2));
''';
  final process = await Process.start(
    'node',
    ['-e', script],
    environment: {
      'NO_PROXY': 'upstream.example',
      'no_proxy': '',
      'OTEL_EXPORTER_OTLP_ENDPOINT': 'http://telemetry.invalid',
    },
  );
  addTearDown(() => process.kill(ProcessSignal.sigkill));
  final errors = process.stderr.transform(utf8.decoder).join();
  final firstLine = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .first;
  process.stdin.write('hello\n');
  await process.stdin.flush();
  final output =
      jsonDecode(await firstLine.timeout(const Duration(seconds: 10)))
          as Map<String, dynamic>;
  await process.stdin.close();
  expect(await process.exitCode.timeout(const Duration(seconds: 10)), 0);
  return (output: output, stderr: await errors);
}
