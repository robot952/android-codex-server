import 'package:flutter/services.dart';

const claudeCodeBridgeAssetPath = 'assets/claude-code-bridge.cjs';

class ClaudeCodeBridgeAsset {
  const ClaudeCodeBridgeAsset._();

  static Future<String> load({AssetBundle? bundle}) async {
    final source = await (bundle ?? rootBundle).loadString(
      claudeCodeBridgeAssetPath,
    );
    if (source.trim().isEmpty) {
      throw StateError('Claude Code bridge 资源为空');
    }
    return source;
  }
}
