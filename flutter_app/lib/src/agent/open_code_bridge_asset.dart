import 'package:flutter/services.dart';

const openCodeBridgeAssetPath = 'assets/opencode-bridge.cjs';

class OpenCodeBridgeAsset {
  const OpenCodeBridgeAsset._();

  static Future<String> load({AssetBundle? bundle}) async {
    final source = await (bundle ?? rootBundle).loadString(
      openCodeBridgeAssetPath,
    );
    if (source.trim().isEmpty) {
      throw StateError('OpenCode bridge 资源为空');
    }
    return source;
  }
}
