import 'package:flutter/services.dart';

class CodexMetricsAsset {
  const CodexMetricsAsset._();

  static Future<String> load() =>
      rootBundle.loadString('assets/codex-request-metrics.cjs');
}
