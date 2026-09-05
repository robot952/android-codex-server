import 'dart:convert';

import 'package:http/http.dart' as http;

import 'remote_bootstrap.dart';

/// Official Codex CLI releases that can be installed into a server user's
/// managed runtime directory.
class CodexVersionCatalog {
  const CodexVersionCatalog({this.client});

  final http.Client? client;

  Future<List<String>> fetch() async {
    final requestClient = client ?? http.Client();
    final ownsClient = client == null;
    try {
      final response = await requestClient
          .get(
            Uri.parse(
              'https://api.github.com/repos/openai/codex/releases?per_page=50',
            ),
            headers: const {'Accept': 'application/vnd.github+json'},
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw StateError('官方 Codex 版本列表请求失败（HTTP ${response.statusCode}）');
      }
      final payload = jsonDecode(response.body);
      if (payload is! List) throw const FormatException('版本列表格式无效');
      final versions = <String>{};
      for (final item in payload) {
        if (item is! Map ||
            item['draft'] == true ||
            item['prerelease'] == true) {
          continue;
        }
        final tag = item['tag_name']?.toString().trim() ?? '';
        if (!tag.startsWith('rust-v')) continue;
        final version = tag.substring('rust-v'.length);
        if (_isVersion(version)) versions.add(version);
      }
      if (versions.isEmpty) throw StateError('官方没有返回可用的 Codex 稳定版本');
      final result = versions.toList()..sort(_compareVersions);
      if (!result.contains(pinnedCodexVersion)) result.add(pinnedCodexVersion);
      result.sort(_compareVersions);
      return List<String>.unmodifiable(result);
    } finally {
      if (ownsClient) requestClient.close();
    }
  }
}

bool _isVersion(String value) => RegExp(r'^\d+\.\d+\.\d+$').hasMatch(value);

int _compareVersions(String left, String right) {
  final a = left.split('.').map(int.parse).toList();
  final b = right.split('.').map(int.parse).toList();
  for (var index = 0; index < 3; index++) {
    final comparison = b[index].compareTo(a[index]);
    if (comparison != 0) return comparison;
  }
  return 0;
}
