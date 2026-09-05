import 'package:codex_remote/src/agent/codex_version_catalog.dart';
import 'package:codex_remote/src/agent/remote_bootstrap.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

class _FakeClient extends http.BaseClient {
  _FakeClient(this.response);

  final http.Response response;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream<List<int>>.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
      request: request,
    );
  }
}

void main() {
  test(
    'loads stable rust releases, sorts them, and keeps the current pin',
    () async {
      final catalog = CodexVersionCatalog(
        client: _FakeClient(
          http.Response(
            '[{"tag_name":"rust-v0.153.3","draft":false,"prerelease":false},'
            '{"tag_name":"rust-v0.154.0","draft":false,"prerelease":false},'
            '{"tag_name":"rust-v0.160.0-beta","draft":false,"prerelease":true},'
            '{"tag_name":"rust-v0.152.9","draft":true,"prerelease":false},'
            '{"tag_name":"v0.200.0","draft":false,"prerelease":false}]',
            200,
          ),
        ),
      );

      expect(await catalog.fetch(), <String>['0.154.0', pinnedCodexVersion]);
    },
  );

  test('reports an unavailable release response', () async {
    final catalog = CodexVersionCatalog(
      client: _FakeClient(http.Response('[]', 200)),
    );

    expect(catalog.fetch(), throwsA(isA<StateError>()));
  });
}
