import 'dart:convert';

import 'package:codex_remote/src/agent/npm_version_catalog.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'OpenCode lists stable releases in numeric order and retains default',
    () async {
      final catalog = OpenCodeVersionCatalog(
        client: MockClient((request) async {
          expect(request.url.path, '/opencode-ai');
          return http.Response(
            jsonEncode({
              'versions': {
                '1.18.9': {},
                '1.18.10': {},
                '1.19.0-beta.1': {},
                'not-a-version': {},
              },
              'dist-tags': {'latest': '1.19.0'},
            }),
            200,
          );
        }),
      );

      expect(await catalog.fetch(), [
        '1.19.0',
        defaultOpenCodeVersion,
        '1.18.10',
        '1.18.9',
      ]);
    },
  );

  test(
    'Claude catalog limits choices to stable supported 2.1+ releases',
    () async {
      final catalog = ClaudeCodeVersionCatalog(
        client: MockClient((request) async {
          expect(
            Uri.decodeComponent(request.url.path),
            '/@anthropic-ai/claude-code',
          );
          return http.Response(
            jsonEncode({
              'versions': {
                '1.0.100': {},
                '2.0.99': {},
                '2.1.280': {},
                '2.1.294': {},
                '2.2.0-beta.1': {},
                '3.0.0': {},
              },
              'dist-tags': {'latest': '3.0.0'},
            }),
            200,
          );
        }),
      );

      expect(await catalog.fetch(), [
        '2.1.294',
        defaultClaudeCodeVersion,
        '2.1.280',
      ]);
    },
  );

  test('large catalogs stay bounded without dropping the default', () async {
    final catalog = OpenCodeVersionCatalog(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'versions': {
              for (var patch = 0; patch < 150; patch++) '2.0.$patch': {},
            },
          }),
          200,
        ),
      ),
    );

    final versions = await catalog.fetch();
    expect(versions, hasLength(100));
    expect(versions.first, '2.0.149');
    expect(versions.last, defaultOpenCodeVersion);
    expect(() => versions.add('1.0.0'), throwsUnsupportedError);
  });

  test('HTTP errors and empty or malformed metadata remain failures', () async {
    for (final response in <http.Response>[
      http.Response('{}', 503),
      http.Response('{"versions":{}}', 200),
      http.Response('{"versions":{"2.0.0-beta":{}}}', 200),
      http.Response('{"versions":[]}', 200),
      http.Response('not-json', 200),
    ]) {
      final catalog = OpenCodeVersionCatalog(
        client: MockClient((_) async => response),
      );
      await expectLater(
        catalog.fetch(),
        throwsA(anyOf(isA<StateError>(), isA<FormatException>())),
      );
    }
  });
}
