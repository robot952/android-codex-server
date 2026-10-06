import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'remote_bootstrap.dart';

const managedClaudeCodeBridgeCommand =
    '~/.local/bin/codex-remote-claude-bridge';
const _probePrefix = '__CODEX_REMOTE_CLAUDE_';

class ClaudeCodeRuntimeProbe {
  const ClaudeCodeRuntimeProbe({
    this.version,
    this.executablePath,
    this.nodePath,
    this.bridgePath,
    this.bridgeSha256,
    this.launcherSha256,
  });

  final String? version;
  final String? executablePath;
  final String? nodePath;
  final String? bridgePath;
  final String? bridgeSha256;
  final String? launcherSha256;

  bool get hasSupportedVersion =>
      RegExp(r'^2\.(?:[1-9]\d*)\.\d+(?:\s|$)').hasMatch(version ?? '');

  bool isCompatible(String expectedBridgeSha256) =>
      hasSupportedVersion &&
      (executablePath?.isNotEmpty ?? false) &&
      (nodePath?.isNotEmpty ?? false) &&
      (bridgePath?.isNotEmpty ?? false) &&
      bridgeSha256?.toLowerCase() == expectedBridgeSha256.toLowerCase() &&
      launcherSha256?.toLowerCase() ==
          ClaudeCodeBootstrap.bridgeSha256(ClaudeCodeBootstrap.launcherSource);
}

/// Installs only the mobile connection component. The SSH user's Claude CLI,
/// login, settings and CLI version remain under that user's control.
class ClaudeCodeBootstrap {
  const ClaudeCodeBootstrap._();

  static const _discoverRuntime = r'''
CLAUDE_BIN=""
for CANDIDATE in "$HOME/.local/bin/claude" "$(command -v claude 2>/dev/null || true)"; do
  if [ -n "$CANDIDATE" ] && [ -x "$CANDIDATE" ]; then CLAUDE_BIN="$CANDIDATE"; break; fi
done
NODE_BIN=""
for CANDIDATE in "$(command -v node 2>/dev/null || true)" "$HOME"/.local/share/codex-remote/runtime/*/bin/node; do
  if [ -n "$CANDIDATE" ] && [ -x "$CANDIDATE" ] && "$CANDIDATE" -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 18 ? 0 : 1)' >/dev/null 2>&1; then
    NODE_BIN="$CANDIDATE"
    break
  fi
done
if [ -n "$NODE_BIN" ]; then PATH="$(dirname "$NODE_BIN"):$PATH"; export PATH; fi
''';

  static const launcherSource =
      '#!/bin/sh\nset -eu\n$_discoverRuntime'
      r'''
if [ -z "$CLAUDE_BIN" ]; then printf '%s\n' '未找到 Claude Code CLI，请先在服务器安装并登录 Claude Code' >&2; exit 65; fi
if [ -z "$NODE_BIN" ]; then printf '%s\n' 'Claude Code 连接组件需要 Node.js 18 或更新版本' >&2; exit 65; fi
export CLAUDE_BIN
exec "$NODE_BIN" "$HOME/.local/share/codex-remote/claude/bridge.cjs" "$@"
''';

  static const probeScript =
      'set -u\n$_discoverRuntime'
      r'''
value() { printf '__CODEX_REMOTE_CLAUDE_%s=%s\n' "$1" "$2"; }
WRAPPER="$HOME/.local/bin/codex-remote-claude-bridge"
BRIDGE="$HOME/.local/share/codex-remote/claude/bridge.cjs"
if [ -x "$WRAPPER" ] && [ -f "$BRIDGE" ]; then
  value BRIDGE "$WRAPPER"
  value BRIDGE_SHA256 "$(sha256sum "$BRIDGE" 2>/dev/null | cut -d ' ' -f 1)"
  value LAUNCHER_SHA256 "$(sha256sum "$WRAPPER" 2>/dev/null | cut -d ' ' -f 1)"
fi
if [ -n "$NODE_BIN" ]; then value NODE "$NODE_BIN"; fi
if [ -n "$CLAUDE_BIN" ]; then
  value PATH "$CLAUDE_BIN"
  value VERSION "$("$CLAUDE_BIN" --version 2>/dev/null || true)"
fi
''';

  // Do not execute Codex probes or load its proxy/auth environment for this lane.
  static const combinedProbeScript =
      r'''
set -u
value() { printf '__CODEX_REMOTE_%s=%s\n' "$1" "$2"; }
value OS "$(uname -s 2>/dev/null || printf unknown)"
value ARCH "$(uname -m 2>/dev/null || printf unknown)"
value HOME "$HOME"
value LIBC unknown
command -v sh >/dev/null 2>&1 && value HAS_SHELL 1 || value HAS_SHELL 0
command -v tar >/dev/null 2>&1 && value HAS_TAR 1 || value HAS_TAR 0
command -v sha256sum >/dev/null 2>&1 && value HAS_SHA256 1 || value HAS_SHA256 0
command -v flock >/dev/null 2>&1 && value HAS_FLOCK 1 || value HAS_FLOCK 0
command -v setsid >/dev/null 2>&1 && setsid --wait true >/dev/null 2>&1 && value HAS_SETSID_WAIT 1 || value HAS_SETSID_WAIT 0
command -v curl >/dev/null 2>&1 && value DOWNLOADER curl || value DOWNLOADER none
'''
      '\n$probeScript';

  static ClaudeCodeRuntimeProbe parseProbe(String output) {
    final values = <String, String>{};
    for (final line in output.split(RegExp(r'\r?\n'))) {
      if (!line.startsWith(_probePrefix)) continue;
      final value = line.substring(_probePrefix.length);
      final separator = value.indexOf('=');
      if (separator >= 0) {
        values[value.substring(0, separator)] = value.substring(separator + 1);
      }
    }
    String? optional(String key) {
      final value = values[key]?.trim();
      return value == null || value.isEmpty ? null : value;
    }

    return ClaudeCodeRuntimeProbe(
      version: optional('VERSION'),
      executablePath: optional('PATH'),
      nodePath: optional('NODE'),
      bridgePath: optional('BRIDGE'),
      bridgeSha256: optional('BRIDGE_SHA256'),
      launcherSha256: optional('LAUNCHER_SHA256'),
    );
  }

  static AgentRuntimeInspection inspect(
    String output, {
    required String bridgeSource,
  }) {
    final host = RemoteBootstrap.parseProbe(output);
    final claude = parseProbe(output);
    final compatible =
        host.os == 'Linux' && claude.isCompatible(bridgeSha256(bridgeSource));
    return _ClaudeRuntimeInspection(
      host: host,
      claude: claude,
      command: compatible ? shellQuote(claude.bridgePath!) : null,
    );
  }

  static String installScript({required String bridgeSource}) {
    if (bridgeSource.trim().isEmpty) {
      throw ArgumentError.value(bridgeSource, 'bridgeSource');
    }
    final install = _installTemplate
        .replaceAll(
          '__BRIDGE_BASE64__',
          shellQuote(base64Encode(utf8.encode(bridgeSource))),
        )
        .replaceAll(
          '__LAUNCHER_BASE64__',
          shellQuote(base64Encode(utf8.encode(launcherSource))),
        )
        .replaceAll('__BRIDGE_HASH__', bridgeSha256(bridgeSource));
    return 'set -eu\numask 077\n$_discoverRuntime$install';
  }

  static const _installTemplate = r'''
if [ -z "$CLAUDE_BIN" ]; then printf '%s\n' '未找到 Claude Code CLI，请先在服务器安装并登录 Claude Code 2.1 或更新的 2.x 版本' >&2; exit 65; fi
if [ -z "$NODE_BIN" ]; then printf '%s\n' 'Claude Code 连接组件需要 Node.js 18 或更新版本，也可复用 Codex/OpenCode 已安装的 Node.js' >&2; exit 65; fi
VERSION="$("$CLAUDE_BIN" --version)"
printf '%s' "$VERSION" | "$NODE_BIN" -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>process.exit(/^2\.[1-9]\d*\.\d+(?:\s|$)/.test(s)?0:1))' || {
  printf '%s\n' '需要 Claude Code 2.1 或更新的 2.x 版本，请先升级服务器上的 Claude Code CLI' >&2; exit 65;
}

ROOT="$HOME/.local/share/codex-remote/claude"
BIN_DIR="$HOME/.local/bin"
if [ -L "$ROOT" ]; then printf '%s\n' 'Claude Code 连接组件目录不能是符号链接' >&2; exit 65; fi
mkdir -p "$ROOT" "$BIN_DIR"
if [ -L "$ROOT/.install.lock" ]; then exit 65; fi
exec 9>"$ROOT/.install.lock"
flock -n 9 || { printf '%s\n' 'Claude Code 连接组件正在安装，请稍后重试' >&2; exit 75; }
WORK="$(mktemp -d "$ROOT/.install.XXXXXX")"
LAUNCHER="$(mktemp "$BIN_DIR/.codex-remote-claude.XXXXXX")"
cleanup() { rm -f -- "$WORK/bridge.cjs" "$LAUNCHER"; rmdir -- "$WORK" 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM
printf '::progress::25||校验 Claude Code 连接组件|服务器 CLI 已就绪\n'
"$NODE_BIN" -e 'require("node:fs").writeFileSync(process.argv[1],Buffer.from(process.argv[2],"base64"),{mode:384})' "$WORK/bridge.cjs" __BRIDGE_BASE64__
ACTUAL_HASH="$(sha256sum "$WORK/bridge.cjs" | cut -d ' ' -f 1)"
[ "$ACTUAL_HASH" = '__BRIDGE_HASH__' ] || { printf '%s\n' 'Claude Code 连接组件校验失败' >&2; exit 65; }
"$NODE_BIN" --check "$WORK/bridge.cjs" >/dev/null
"$NODE_BIN" -e 'require("node:fs").writeFileSync(process.argv[1],Buffer.from(process.argv[2],"base64"),{mode:448})' "$LAUNCHER" __LAUNCHER_BASE64__
chmod 700 "$LAUNCHER"
sh -n "$LAUNCHER"
mv -f -- "$WORK/bridge.cjs" "$ROOT/bridge.cjs"
mv -f -- "$LAUNCHER" "$BIN_DIR/codex-remote-claude-bridge"
printf '::progress::100||Claude Code 连接组件已安装|保留服务器原有登录和配置\n'
''';

  static const uninstallScript = r'''
set -eu
ROOT="$HOME/.local/share/codex-remote/claude"
if [ -L "$ROOT" ]; then exit 65; fi
if [ -d "$ROOT" ]; then
  if [ -L "$ROOT/.install.lock" ]; then exit 65; fi
  exec 9>"$ROOT/.install.lock"
  flock -n 9 || { printf '%s\n' 'Claude Code 连接组件正在安装，请稍后重试' >&2; exit 75; }
  rm -f -- "$ROOT/bridge.cjs"
fi
rm -f -- "$HOME/.local/bin/codex-remote-claude-bridge" "$HOME/.local/bin/codex-remote-claude-bridge.sha256"
''';

  static String bridgeSha256(String source) =>
      sha256.convert(utf8.encode(source)).toString();
}

class _ClaudeRuntimeInspection extends AgentRuntimeInspection {
  _ClaudeRuntimeInspection({
    required AgentRuntimeInspection host,
    required ClaudeCodeRuntimeProbe claude,
    required String? command,
  }) : _claude = claude,
       super(
         os: host.os,
         architecture: host.architecture,
         home: host.home,
         libc: host.libc,
         managedVersion: claude.version,
         managedPath: claude.bridgePath,
         systemVersion: claude.version,
         systemPath: claude.executablePath,
         hasShell: host.hasShell,
         hasTar: host.hasTar,
         hasSha256: host.hasSha256,
         hasFlock: host.hasFlock,
         hasSetsidWait: host.hasSetsidWait,
         downloader: host.downloader,
         fallbackCommand: command,
       );

  final ClaudeCodeRuntimeProbe _claude;

  @override
  String? get installationProblem {
    if (fallbackCommand != null) return null;
    if (os != 'Linux') return 'Claude Code 目前支持通过 SSH 连接 Linux 服务器';
    if (!hasShell) return '服务器缺少 /bin/sh';
    if (_claude.executablePath == null) {
      return '请先在服务器安装并登录 Claude Code 2.1 或更新的 2.x 版本';
    }
    if (!_claude.hasSupportedVersion) {
      return '请将服务器上的 Claude Code 升级到 2.1 或更新的 2.x 版本';
    }
    if (_claude.nodePath == null) {
      return 'Claude Code 连接组件需要 Node.js 18 或更新版本';
    }
    if (!hasSha256) return '服务器缺少 sha256sum';
    if (!hasFlock) return '服务器缺少 flock';
    if (!hasSetsidWait) return '服务器缺少支持 --wait 的 setsid';
    return null;
  }
}
