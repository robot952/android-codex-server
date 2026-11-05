import 'package:flutter/services.dart';

class CodexMetricsAsset {
  const CodexMetricsAsset._();

  static Future<String> load() async {
    final sources = await Future.wait([
      rootBundle.loadString('assets/codex-history-compat.cjs'),
      rootBundle.loadString('assets/codex-history-proxy.cjs'),
      rootBundle.loadString('assets/codex-history-relay.cjs'),
      rootBundle.loadString('assets/codex-request-metrics.cjs'),
    ]);
    return sources.join('\n');
  }
}
