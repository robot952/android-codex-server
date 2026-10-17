import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/models.dart';

/// Stable versions published for an npm-managed Agent CLI.
///
/// Lists stable release history and always retains the app default. The UI
/// separately adds a saved version if it falls outside this bounded catalog.
class NpmVersionCatalog {
  const NpmVersionCatalog({
    required this.packageName,
    required this.pinnedVersion,
    required this.label,
    this.versionPredicate = isStableNpmVersion,
    this.client,
  });

  final String packageName;
  final String pinnedVersion;
  final String label;
  final bool Function(String value) versionPredicate;
  final http.Client? client;

  Future<List<String>> fetch() async {
    final requestClient = client ?? http.Client();
    final ownsClient = client == null;
    try {
      final encoded = Uri.encodeComponent(packageName);
      final response = await requestClient
          .get(
            Uri.parse('https://registry.npmjs.org/$encoded'),
            headers: const {'Accept': 'application/vnd.npm.install-v1+json'},
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw StateError('$label 版本列表请求失败（HTTP ${response.statusCode}）');
      }
      final payload = jsonDecode(response.body);
      if (payload is! Map) throw const FormatException('版本列表格式无效');
      final versionsValue = payload['versions'];
      if (versionsValue is! Map) throw const FormatException('版本列表格式无效');
      final versions = <String>{};
      for (final key in versionsValue.keys) {
        final version = key.toString().trim();
        if (versionPredicate(version)) versions.add(version);
      }
      final latest = (payload['dist-tags'] is Map)
          ? (payload['dist-tags'] as Map)['latest']?.toString().trim()
          : null;
      if (latest != null && versionPredicate(latest)) versions.add(latest);
      if (!versionPredicate(pinnedVersion)) {
        throw ArgumentError('$label 默认版本格式无效');
      }
      if (versions.isEmpty) throw StateError('$label 没有返回可用的稳定版本');
      versions.add(pinnedVersion);
      final result = versions.toList()..sort(compareVersionsDescending);
      // Bound large release histories while preserving the app default.
      final limited = result.take(100).toList(growable: true);
      if (!limited.contains(pinnedVersion)) {
        limited.removeLast();
        limited.add(pinnedVersion);
        limited.sort(compareVersionsDescending);
      }
      return List<String>.unmodifiable(limited);
    } finally {
      if (ownsClient) requestClient.close();
    }
  }
}

class OpenCodeVersionCatalog extends NpmVersionCatalog {
  const OpenCodeVersionCatalog({super.client})
    : super(
        packageName: 'opencode-ai',
        pinnedVersion: defaultOpenCodeVersion,
        label: 'OpenCode',
      );
}

class ClaudeCodeVersionCatalog extends NpmVersionCatalog {
  const ClaudeCodeVersionCatalog({super.client})
    : super(
        packageName: '@anthropic-ai/claude-code',
        pinnedVersion: defaultClaudeCodeVersion,
        label: 'Claude Code',
        versionPredicate: _isSupportedClaudeVersion,
      );
}

bool isStableNpmVersion(String value) => _isStableVersion(value);

int compareVersionsDescending(String left, String right) {
  final a = left.split('.').map(int.parse).toList(growable: false);
  final b = right.split('.').map(int.parse).toList(growable: false);
  for (var index = 0; index < 3; index++) {
    final comparison = b[index].compareTo(a[index]);
    if (comparison != 0) return comparison;
  }
  return 0;
}

bool _isStableVersion(String value) =>
    RegExp(r'^\d+\.\d+\.\d+$').hasMatch(value);

bool _isSupportedClaudeVersion(String value) =>
    RegExp(r'^2\.(?:[1-9]\d*)\.(?:0|[1-9]\d*)$').hasMatch(value);
