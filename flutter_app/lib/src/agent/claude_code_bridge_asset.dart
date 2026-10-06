import 'package:flutter/services.dart';

const claudeCodeBridgeAssetPath = 'assets/claude-code-bridge.cjs';
const claudeCodeSettingsAssetPath = 'assets/claude-code-settings.cjs';

class ClaudeCodeBridgeAsset {
  const ClaudeCodeBridgeAsset._();

  static Future<String> load({AssetBundle? bundle}) async {
    final assets = bundle ?? rootBundle;
    final source = await assets.loadString(claudeCodeBridgeAssetPath);
    final settings = await assets.loadString(claudeCodeSettingsAssetPath);
    if (source.trim().isEmpty || settings.trim().isEmpty) {
      throw StateError('Claude Code bridge 资源为空');
    }
    // One hash and one atomic installation cover both the protocol bridge and
    // the settings implementation. Node fixtures require the same helper file.
    final program = source.replaceFirst(RegExp(r'^#![^\n]*\n'), '');
    return '#!/usr/bin/env node\n$settings\n$program';
  }
}
