import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'remote_bootstrap.dart';

const pinnedOpenCodeVersion = '1.18.11';
const openCodeSharedRuntimePercent = 68;
const managedOpenCodeBridgeCommand =
    '~/.local/bin/codex-remote-opencode-bridge';

const _openCodeProbePrefix = '__CODEX_REMOTE_OPENCODE_';
final _openCodeVersionPattern = RegExp(
  r'^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$',
);
final _installTokenPattern = RegExp(
  r'__(?:OPENCODE_VERSION|PROXY_SHELL|BRIDGE_BASE64_SHELL|BRIDGE_SHA256)__',
);

class OpenCodeRuntimeProbe {
  const OpenCodeRuntimeProbe({
    this.version,
    this.executablePath,
    this.bridgePath,
    this.bridgeSha256,
  });

  final String? version;
  final String? executablePath;
  final String? bridgePath;
  final String? bridgeSha256;

  bool isCompatible({
    required String expectedVersion,
    required String expectedBridgeSha256,
  }) {
    final detectedVersion = version?.trim() ?? '';
    final detectedPath = bridgePath?.trim() ?? '';
    final detectedHash = bridgeSha256?.trim().toLowerCase() ?? '';
    return detectedVersion.contains(expectedVersion) &&
        detectedPath.isNotEmpty &&
        detectedHash == expectedBridgeSha256.toLowerCase();
  }
}

/// Builds the app-owned OpenCode runtime scripts used over an SSH stdin
/// channel. The bridge source must come from `OpenCodeBridgeAsset` at the
/// application boundary; it is encoded before being embedded in the script.
class OpenCodeBootstrap {
  const OpenCodeBootstrap._();

  static const probeScript = r'''
set -u
value() { printf '__CODEX_REMOTE_OPENCODE_%s=%s\n' "$1" "$2"; }
ROOT="$HOME/.local/share/codex-remote"
WRAPPER="$HOME/.local/bin/codex-remote-opencode-bridge"
if [ -x "$WRAPPER" ]; then
  value BRIDGE "$WRAPPER"
fi
BRIDGE_HASH="$ROOT/opencode/bridge.sha256"
if [ -r "$BRIDGE_HASH" ]; then
  value BRIDGE_SHA256 "$(cat "$BRIDGE_HASH" 2>/dev/null || true)"
fi
OPENCODE_BIN="$(find -L "$ROOT/opencode/releases" -path '*/node_modules/.bin/opencode' -type f -perm -u+x 2>/dev/null | sort | tail -n 1)"
if [ -n "$OPENCODE_BIN" ] && [ -x "$OPENCODE_BIN" ]; then
  value PATH "$OPENCODE_BIN"
  value VERSION "$("$OPENCODE_BIN" --version 2>/dev/null || true)"
fi
''';

  /// Host prerequisites and OpenCode metadata are intentionally collected in
  /// one SSH invocation so the result belongs to one connection generation.
  static const combinedProbeScript =
      '${RemoteBootstrap.probeScript}\n$probeScript';

  static OpenCodeRuntimeProbe parseProbe(String output) {
    final values = <String, String>{};
    for (final line in output.split(RegExp(r'\r?\n'))) {
      if (!line.startsWith(_openCodeProbePrefix)) continue;
      final value = line.substring(_openCodeProbePrefix.length);
      final separator = value.indexOf('=');
      if (separator < 0) continue;
      values[value.substring(0, separator)] = value.substring(separator + 1);
    }

    String? optional(String key) {
      final value = values[key]?.trim();
      return value == null || value.isEmpty ? null : value;
    }

    return OpenCodeRuntimeProbe(
      version: optional('VERSION'),
      executablePath: optional('PATH'),
      bridgePath: optional('BRIDGE'),
      bridgeSha256: optional('BRIDGE_SHA256'),
    );
  }

  /// Projects the combined probe onto the Agent-neutral inspection contract.
  /// An installed OpenCode is reusable only when both its pinned CLI version
  /// and the bundled bridge hash match.
  static AgentRuntimeInspection inspect(
    String output, {
    required String bridgeSource,
    String openCodeVersion = pinnedOpenCodeVersion,
  }) {
    _validateBridgeSource(bridgeSource);
    final expectedVersion = _validateVersion(openCodeVersion);
    final host = RemoteBootstrap.parseProbe(output);
    final openCode = parseProbe(output);
    final compatible =
        host.installationProblem == null &&
        openCode.isCompatible(
          expectedVersion: expectedVersion,
          expectedBridgeSha256: bridgeSha256(bridgeSource),
        );

    return AgentRuntimeInspection(
      os: host.os,
      architecture: host.architecture,
      home: host.home,
      libc: host.libc,
      managedVersion: openCode.version,
      managedPath: openCode.bridgePath,
      hasShell: host.hasShell,
      hasTar: host.hasTar,
      hasSha256: host.hasSha256,
      hasFlock: host.hasFlock,
      hasSetsidWait: host.hasSetsidWait,
      downloader: host.downloader,
      fallbackCommand: compatible ? shellQuote(openCode.bridgePath!) : null,
    );
  }

  /// Prepares only the shared pinned Node.js runtime. OpenCode clients should
  /// execute this before [installScript] and map its progress into 0-68%.
  static String installNodeRuntimeScript({
    String nodeVersion = pinnedNodeVersion,
    String proxyUrl = '',
  }) => RemoteBootstrap.installNodeRuntimeScript(
    nodeVersion: nodeVersion,
    proxyUrl: proxyUrl,
  );

  /// Installs the pinned OpenCode package and atomically publishes the launcher
  /// after the package, version, bridge, and hash are ready.
  static String installScript({
    String openCodeVersion = pinnedOpenCodeVersion,
    String proxyUrl = '',
    required String bridgeSource,
  }) {
    _validateBridgeSource(bridgeSource);
    final version = _validateVersion(openCodeVersion);
    final proxy = RemoteBootstrap.validateProxyUrl(proxyUrl);
    final replacements = <String, String>{
      '__OPENCODE_VERSION__': version,
      '__PROXY_SHELL__': shellQuote(proxy),
      '__BRIDGE_BASE64_SHELL__': shellQuote(
        base64Encode(utf8.encode(bridgeSource)),
      ),
      '__BRIDGE_SHA256__': bridgeSha256(bridgeSource),
    };
    return _openCodeInstallTemplate.replaceAllMapped(
      _installTokenPattern,
      (match) => replacements[match.group(0)]!,
    );
  }

  static String bridgeSha256(String bridgeSource) =>
      sha256.convert(utf8.encode(bridgeSource)).toString();

  static const uninstallScript = r'''
set -eu
rm -f -- "$HOME/.local/bin/codex-remote-opencode-bridge"
rm -rf -- "$HOME/.local/share/codex-remote/opencode"
''';

  static String _validateVersion(String value) {
    final version = value.trim();
    if (!_openCodeVersionPattern.hasMatch(version)) {
      throw ArgumentError.value(value, 'openCodeVersion', 'OpenCode 版本格式无效');
    }
    return version;
  }

  static void _validateBridgeSource(String value) {
    if (value.trim().isEmpty) {
      throw ArgumentError.value(value, 'bridgeSource', 'OpenCode bridge 资源为空');
    }
  }
}

const _openCodeInstallTemplate = r'''
set -eu
progress() {
  printf '::progress::%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$1" "$2" "$3" "$4" "${5:-}" "${6:-}" "${7:-}" "${8:-}";
}
format_bytes() {
  BYTES="$1"
  if [ "$BYTES" -ge 1048576 ]; then
    awk -v bytes="$BYTES" 'BEGIN { printf "%.1f MB", bytes / 1048576 }'
  elif [ "$BYTES" -ge 1024 ]; then
    awk -v bytes="$BYTES" 'BEGIN { printf "%.1f KB", bytes / 1024 }'
  else
    printf '%s B' "$BYTES"
  fi
}
ROOT="$HOME/.local/share/codex-remote"
BIN_DIR="$HOME/.local/bin"
OPENCODE_ROOT="$ROOT/opencode"
RELEASE="$OPENCODE_ROOT/releases/__OPENCODE_VERSION__"
WORK="$OPENCODE_ROOT/.install-$$"
PROXY=__PROXY_SHELL__
cleanup() { rm -rf -- "$WORK"; }
trap cleanup EXIT HUP INT TERM
progress 70 '' '准备 OpenCode 运行时' '检查共享 Node.js 环境'
NODE="$(find "$ROOT/runtime" -path '*/bin/node' -type f -perm -u+x 2>/dev/null | sort | tail -n 1)"
if [ -z "$NODE" ] || [ ! -x "$NODE" ]; then
  printf '未找到 Codex Remote 管理的 Node.js 运行时\n' >&2
  exit 65
fi
NODE_BIN="$(dirname "$NODE")"
NPM="$NODE_BIN/npm"
if [ ! -x "$NPM" ]; then
  printf '共享 Node.js 运行时缺少 npm\n' >&2
  exit 65
fi
if [ -n "$PROXY" ]; then
  HTTP_PROXY="$PROXY"
  HTTPS_PROXY="$PROXY"
  ALL_PROXY="$PROXY"
  npm_config_proxy="$PROXY"
  npm_config_https_proxy="$PROXY"
  export HTTP_PROXY HTTPS_PROXY ALL_PROXY npm_config_proxy npm_config_https_proxy
fi
npm_config_registry=https://registry.npmmirror.com
export npm_config_registry
mkdir -p "$OPENCODE_ROOT/releases" "$BIN_DIR" "$WORK"
ARCH_RAW="$(uname -m 2>/dev/null || printf unknown)"
case "$ARCH_RAW" in
  aarch64|arm64) PLATFORM_PACKAGE=opencode-linux-arm64 ;;
  x86_64|amd64)
    if grep -Eq '(^|[[:space:]])avx2([[:space:]]|$)' /proc/cpuinfo 2>/dev/null; then
      PLATFORM_PACKAGE=opencode-linux-x64
    else
      PLATFORM_PACKAGE=opencode-linux-x64-baseline
    fi
    ;;
  *) printf 'OpenCode 不支持当前架构: %s\n' "$ARCH_RAW" >&2; exit 65 ;;
esac
printf '%s\n' \
  '{"private":true,"dependencies":{"jsonc-parser":"3.3.1","opencode-ai":"__OPENCODE_VERSION__","'"$PLATFORM_PACKAGE"'":"__OPENCODE_VERSION__"}}' \
  > "$WORK/package.json"
progress 74 '' '分析 OpenCode 下载清单' "通过国内源锁定 $PLATFORM_PACKAGE"
(
  cd "$WORK"
  PATH="$NODE_BIN:$PATH" "$NPM" install --package-lock-only \
    --ignore-scripts --omit=dev --no-audit --no-fund --loglevel=error
)
PACKAGE_TOTAL="$("$NODE" -e 'const lock = require(process.argv[1]); const packages = lock.packages || {}; console.log(Object.keys(packages).filter((path) => path.startsWith("node_modules/")).length)' "$WORK/package-lock.json")"
case "$PACKAGE_TOTAL" in
  ''|*[!0-9]*) PACKAGE_TOTAL=1 ;;
esac
progress 78 0 '下载并安装 OpenCode __OPENCODE_VERSION__' "通过国内源下载 $PLATFORM_PACKAGE · 共 $PACKAGE_TOTAL 个组件"
NPM_LOG="$WORK/npm-install.log"
NPM_STARTED="$(date +%s)"
(
  cd "$WORK"
  PATH="$NODE_BIN:$PATH" "$NPM" ci \
    --ignore-scripts --omit=dev --omit=optional --no-audit --no-fund --loglevel=error
) > "$NPM_LOG" 2>&1 &
NPM_PID="$!"
NPM_LAST=
while kill -0 "$NPM_PID" 2>/dev/null; do
  NPM_COMPLETE="$(find "$WORK/node_modules" -type f -name package.json 2>/dev/null | wc -l | tr -d '[:space:]')"
  case "$NPM_COMPLETE" in
    ''|*[!0-9]*) NPM_COMPLETE=0 ;;
  esac
  if [ "$NPM_COMPLETE" -gt "$PACKAGE_TOTAL" ]; then PACKAGE_TOTAL="$NPM_COMPLETE"; fi
  NPM_PERCENT="$((NPM_COMPLETE * 100 / PACKAGE_TOTAL))"
  if [ "$NPM_PERCENT" -gt 99 ]; then NPM_PERCENT=99; fi
  NPM_OVERALL="$((78 + NPM_PERCENT * 16 / 100))"
  NPM_SIZE_KB="$(du -sk "$WORK/node_modules" 2>/dev/null | awk 'NR == 1 { print $1 }')"
  case "$NPM_SIZE_KB" in
    ''|*[!0-9]*) NPM_SIZE_KB=0 ;;
  esac
  NPM_NOW="$(date +%s)"
  NPM_ELAPSED="$((NPM_NOW - NPM_STARTED))"
  if [ "$NPM_ELAPSED" -lt 1 ]; then NPM_ELAPSED=1; fi
  NPM_BYTES="$((NPM_SIZE_KB * 1024))"
  NPM_SPEED="$((NPM_BYTES / NPM_ELAPSED))"
  NPM_DETAIL="已处理 $NPM_COMPLETE / $PACKAGE_TOTAL 个组件 · $(format_bytes "$NPM_BYTES") · 速度 $(format_bytes "$NPM_SPEED")/s · 已用时 ${NPM_ELAPSED}s"
  if [ "$NPM_DETAIL" != "$NPM_LAST" ]; then
    progress "$NPM_OVERALL" "$NPM_PERCENT" '下载并安装 OpenCode __OPENCODE_VERSION__' "$NPM_DETAIL" \
      "$NPM_BYTES" '' "$NPM_SPEED" "$NPM_ELAPSED"
    NPM_LAST="$NPM_DETAIL"
  fi
  sleep 1
done
if wait "$NPM_PID"; then
  NPM_FINISHED_AT="$(date +%s)"
  NPM_ELAPSED="$((NPM_FINISHED_AT - NPM_STARTED))"
  NPM_SIZE_KB="$(du -sk "$WORK/node_modules" 2>/dev/null | awk 'NR == 1 { print $1 }')"
  case "$NPM_SIZE_KB" in
    ''|*[!0-9]*) NPM_SIZE_KB=0 ;;
  esac
  NPM_BYTES="$((NPM_SIZE_KB * 1024))"
  progress 94 100 '下载并安装 OpenCode __OPENCODE_VERSION__' \
    "已完成 $PACKAGE_TOTAL 个组件 · $(format_bytes "$NPM_BYTES") · 已用时 ${NPM_ELAPSED}s" \
    "$NPM_BYTES" '' '' "$NPM_ELAPSED"
else
  NPM_STATUS="$?"
  cat "$NPM_LOG" >&2 || true
  exit "$NPM_STATUS"
fi
PLATFORM_BIN="$WORK/node_modules/$PLATFORM_PACKAGE/bin/opencode"
if [ ! -x "$PLATFORM_BIN" ]; then
  printf 'OpenCode 平台运行文件缺失: %s\n' "$PLATFORM_PACKAGE" >&2
  exit 65
fi
rm -f -- "$WORK/node_modules/.bin/opencode"
ln -s "../$PLATFORM_PACKAGE/bin/opencode" "$WORK/node_modules/.bin/opencode"
OPENCODE_BIN="$WORK/node_modules/.bin/opencode"
if [ ! -x "$OPENCODE_BIN" ]; then
  printf 'OpenCode 安装后缺少可执行文件\n' >&2
  exit 65
fi
ACTUAL="$("$OPENCODE_BIN" --version 2>/dev/null || true)"
case "$ACTUAL" in
  *__OPENCODE_VERSION__*) ;;
  *) printf 'OpenCode 版本校验失败: %s\n' "$ACTUAL" >&2; exit 65 ;;
esac
progress 95 100 '校验 OpenCode 运行时 __OPENCODE_VERSION__' "$ACTUAL"
rm -rf -- "$RELEASE"
mv "$WORK" "$RELEASE"
mkdir -p "$OPENCODE_ROOT"
BRIDGE="$OPENCODE_ROOT/bridge.cjs"
"$NODE" -e 'require("node:fs").writeFileSync(process.argv[1], Buffer.from(process.argv[2], "base64"), { mode: 384 })' \
  "$BRIDGE" __BRIDGE_BASE64_SHELL__
printf '%s\n' '__BRIDGE_SHA256__' > "$OPENCODE_ROOT/bridge.sha256"
WRAPPER="$BIN_DIR/.codex-remote-opencode-bridge.$$"
cat > "$WRAPPER" <<'EOF'
#!/bin/sh
ROOT="$HOME/.local/share/codex-remote"
NODE="$(find "$ROOT/runtime" -path '*/bin/node' -type f -perm -u+x 2>/dev/null | sort | tail -n 1)"
export PATH="$(dirname "$NODE"):$PATH"
export OPENCODE_BIN="$ROOT/opencode/releases/__OPENCODE_VERSION__/node_modules/.bin/opencode"
exec "$NODE" "$ROOT/opencode/bridge.cjs" "$@"
EOF
chmod 700 "$WRAPPER"
mv -f "$WRAPPER" "$BIN_DIR/codex-remote-opencode-bridge"
trap - EXIT HUP INT TERM
progress 100 '' '安装完成' 'OpenCode 服务与移动端桥接已就绪'
''';
