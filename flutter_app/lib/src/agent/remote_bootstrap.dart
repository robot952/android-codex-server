const pinnedCodexVersion = '0.146.0';
const pinnedNodeVersion = '22.17.0';
const managedCodexRemoteCommand =
    '~/.local/bin/codex-remote app-server --listen stdio://';
const remoteInstallCommand = 'CODEX_REMOTE_SSH_PID=\$PPID setsid --wait sh -s';

const _probePrefix = '__CODEX_REMOTE_';
const _progressPrefix = '::progress::';
const _supportedArchitectures = <String>{'x86_64', 'amd64', 'aarch64', 'arm64'};

class AgentRuntimeInspection {
  const AgentRuntimeInspection({
    required this.os,
    required this.architecture,
    required this.home,
    required this.libc,
    required this.hasShell,
    required this.hasTar,
    required this.hasSha256,
    required this.hasFlock,
    required this.hasSetsidWait,
    this.managedVersion,
    this.managedPath,
    this.systemVersion,
    this.systemPath,
    this.downloader,
    this.fallbackCommand,
  });

  const AgentRuntimeInspection.bypass(String command)
    : this(
        os: '',
        architecture: '',
        home: '',
        libc: '',
        hasShell: true,
        hasTar: true,
        hasSha256: true,
        hasFlock: true,
        hasSetsidWait: true,
        fallbackCommand: command,
      );

  final String os;
  final String architecture;
  final String home;
  final String libc;
  final String? managedVersion;
  final String? managedPath;
  final String? systemVersion;
  final String? systemPath;
  final bool hasShell;
  final bool hasTar;
  final bool hasSha256;
  final bool hasFlock;
  final bool hasSetsidWait;
  final String? downloader;
  final String? fallbackCommand;

  String? get compatibleCommand {
    final expected = 'codex-cli $pinnedCodexVersion';
    if (managedVersion == expected && _notEmpty(managedPath)) {
      return '${shellQuote(managedPath!)} app-server --listen stdio://';
    }
    if (systemVersion == expected && _notEmpty(systemPath)) {
      return '${shellQuote(systemPath!)} app-server --listen stdio://';
    }
    return _notEmpty(fallbackCommand) ? fallbackCommand!.trim() : null;
  }

  String? get detectedVersion => _notEmpty(managedVersion)
      ? managedVersion
      : _notEmpty(systemVersion)
      ? systemVersion
      : null;

  String? get installationProblem {
    if (fallbackCommand != null) return null;
    if (os == 'Windows') {
      if (!_supportedArchitectures.contains(architecture.toLowerCase())) {
        return '暂不支持 ${architecture.isEmpty ? '未知' : architecture} 架构';
      }
      return null;
    }
    if (os != 'Linux') return '暂不支持在 ${os.isEmpty ? '未知系统' : os} 上自动安装';
    if (!_supportedArchitectures.contains(architecture)) {
      return '暂不支持 ${architecture.isEmpty ? '未知' : architecture} 架构';
    }
    if (libc == 'musl') return '暂不支持 musl libc；自动安装需要 glibc Linux';
    if (!hasShell) return '服务器缺少 /bin/sh';
    if (!hasTar) return '服务器缺少 tar';
    if (!hasSha256) return '服务器缺少 sha256sum';
    if (!hasFlock) return '服务器缺少 flock';
    if (!hasSetsidWait) return '服务器缺少支持 --wait 的 setsid';
    if (!_notEmpty(downloader)) return '服务器缺少 curl 或 wget';
    return null;
  }
}

class RemoteInstallProgress {
  const RemoteInstallProgress({
    required this.percent,
    required this.message,
    this.detail = '',
    this.downloadPercent,
  });

  final int percent;
  final String message;
  final String detail;
  final int? downloadPercent;
}

class RemoteBootstrap {
  const RemoteBootstrap._();

  static const probeScript = r'''
set -u
value() { printf '__CODEX_REMOTE_%s=%s\n' "$1" "$2"; }
value OS "$(uname -s 2>/dev/null || printf unknown)"
value ARCH "$(uname -m 2>/dev/null || printf unknown)"
value HOME "$HOME"
if ldd --version 2>&1 | grep -qi musl; then
  value LIBC musl
elif ldd --version 2>&1 | grep -Eqi 'glibc|gnu libc'; then
  value LIBC glibc
else
  value LIBC unknown
fi
if [ -x "$HOME/.local/bin/codex-remote" ]; then
  value MANAGED_PATH "$HOME/.local/bin/codex-remote"
  value MANAGED_VERSION "$("$HOME/.local/bin/codex-remote" --version 2>/dev/null || true)"
fi
if command -v codex >/dev/null 2>&1; then
  value SYSTEM_PATH "$(command -v codex)"
  value SYSTEM_VERSION "$(codex --version 2>/dev/null || true)"
fi
command -v sh >/dev/null 2>&1 && value HAS_SHELL 1 || value HAS_SHELL 0
command -v tar >/dev/null 2>&1 && value HAS_TAR 1 || value HAS_TAR 0
command -v sha256sum >/dev/null 2>&1 && value HAS_SHA256 1 || value HAS_SHA256 0
command -v flock >/dev/null 2>&1 && value HAS_FLOCK 1 || value HAS_FLOCK 0
if command -v setsid >/dev/null 2>&1 && setsid --wait true >/dev/null 2>&1; then
  value HAS_SETSID_WAIT 1
else
  value HAS_SETSID_WAIT 0
fi
if command -v curl >/dev/null 2>&1; then
  value DOWNLOADER curl
elif command -v wget >/dev/null 2>&1; then
  value DOWNLOADER wget
else
  value DOWNLOADER none
fi
''';

  static AgentRuntimeInspection parseProbe(String output) {
    final values = <String, String>{};
    for (final line in output.split(RegExp(r'\r?\n'))) {
      if (!line.startsWith(_probePrefix)) continue;
      final value = line.substring(_probePrefix.length);
      final separator = value.indexOf('=');
      if (separator < 0) continue;
      values[value.substring(0, separator)] = value.substring(separator + 1);
    }
    String? optional(String key) {
      final value = values[key]?.trim();
      return value == null || value.isEmpty ? null : value;
    }

    return AgentRuntimeInspection(
      os: values['OS']?.trim() ?? '',
      architecture: values['ARCH']?.trim() ?? '',
      home: values['HOME']?.trim() ?? '',
      libc: values['LIBC']?.trim() ?? '',
      managedVersion: optional('MANAGED_VERSION'),
      managedPath: optional('MANAGED_PATH'),
      systemVersion: optional('SYSTEM_VERSION'),
      systemPath: optional('SYSTEM_PATH'),
      hasShell: values['HAS_SHELL'] == '1',
      hasTar: values['HAS_TAR'] == '1',
      hasSha256: values['HAS_SHA256'] == '1',
      hasFlock: values['HAS_FLOCK'] == '1',
      hasSetsidWait: values['HAS_SETSID_WAIT'] == '1',
      downloader: switch (optional('DOWNLOADER')) {
        null || 'none' => null,
        final value => value,
      },
    );
  }

  static String installScript({
    String codexVersion = pinnedCodexVersion,
    String nodeVersion = pinnedNodeVersion,
    String proxyUrl = '',
  }) {
    final proxy = validateProxyUrl(proxyUrl);
    return _installTemplate
        .replaceAll('__CODEX_VERSION__', codexVersion)
        .replaceAll('__NODE_VERSION__', nodeVersion)
        .replaceAll('__PROXY_SHELL__', shellQuote(proxy));
  }

  static String installNodeRuntimeScript({
    String nodeVersion = pinnedNodeVersion,
    String proxyUrl = '',
  }) {
    final full = installScript(
      codexVersion: 'node-runtime-only',
      nodeVersion: nodeVersion,
      proxyUrl: proxyUrl,
    );
    const marker = "\nprogress 55 '' '准备 Codex CLI 安装目录'";
    final markerIndex = full.indexOf(marker);
    if (markerIndex < 0) throw StateError('Codex 安装脚本结构已变化');
    return '${full.substring(0, markerIndex)}\n'
        "INSTALL_COMMITTED=1\n"
        "progress 100 '' '共享 Node.js 运行时已就绪' '仅准备 Agent 公共运行环境，未安装 Codex CLI'";
  }

  static String validateProxyUrl(String value) {
    final proxy = value.trim();
    if (proxy.isEmpty) return '';
    if (proxy.runes.any((rune) => rune < 0x21 || rune > 0x7e)) {
      throw ArgumentError('代理地址不能包含空格、换行、控制字符或非 ASCII 字符');
    }
    final uri = Uri.tryParse(proxy);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw ArgumentError('代理地址必须是有效的 http:// 或 https:// 地址');
    }
    try {
      uri.port;
    } on FormatException {
      throw ArgumentError('代理地址端口无效');
    }
    return proxy;
  }

  static const uninstallScript = r'''
set -eu
ROOT="$HOME/.local/share/codex-remote"
WRAPPER="$HOME/.local/bin/codex-remote"
UPLOAD_ROOT="$HOME/.codex-mobile"

if [ -d "$ROOT" ] && [ ! -L "$ROOT" ] && command -v flock >/dev/null 2>&1; then
  exec 9>>"$ROOT/.install.lock"
  if ! flock -n 9; then
    printf 'Codex Remote 正在安装，请稍后再卸载\n' >&2
    exit 75
  fi
fi

is_managed_app_server() {
  CHECK_PID="$1"
  [ "$CHECK_PID" != "$$" ] || return 1
  [ -r "/proc/$CHECK_PID/cmdline" ] || return 1
  CHECK_COMMAND_LINE="$(tr '\000' ' ' < "/proc/$CHECK_PID/cmdline" 2>/dev/null || true)"
  case "$CHECK_COMMAND_LINE" in
    "$ROOT"/runtime/*/bin/node\ "$ROOT"/releases/*/node_modules/@openai/codex/bin/codex.js\ app-server*)
      return 0 ;;
  esac
  return 1
}

MANAGED_PIDS=
for PROC in /proc/[0-9]*; do
  PID="${PROC##*/}"
  if is_managed_app_server "$PID"; then
    kill -TERM "$PID" 2>/dev/null || true
    MANAGED_PIDS="$MANAGED_PIDS $PID"
  fi
done

ATTEMPT=0
while [ -n "$MANAGED_PIDS" ] && [ "$ATTEMPT" -lt 5 ]; do
  LIVE_PIDS=
  for PID in $MANAGED_PIDS; do
    if is_managed_app_server "$PID"; then
      LIVE_PIDS="$LIVE_PIDS $PID"
    fi
  done
  [ -n "$LIVE_PIDS" ] || break
  MANAGED_PIDS="$LIVE_PIDS"
  ATTEMPT="$((ATTEMPT + 1))"
  sleep 1
done
for PID in $MANAGED_PIDS; do
  if is_managed_app_server "$PID"; then
    kill -KILL "$PID" 2>/dev/null || true
  fi
done

rm -f -- "$WRAPPER"
rm -rf -- "$ROOT"
rm -rf -- "$UPLOAD_ROOT"
printf 'Codex Remote app service 已卸载\n'
''';
}

RemoteInstallProgress? parseRemoteInstallProgressLine(String line) {
  if (!line.startsWith(_progressPrefix)) return null;
  final value = line.substring(_progressPrefix.length);
  final parts = value.split('|');
  final percent = _boundedPercent(parts.firstOrNull) ?? 0;
  if (parts.length >= 4) {
    final message = parts[2].trim().isEmpty ? value.trim() : parts[2].trim();
    return RemoteInstallProgress(
      percent: percent,
      downloadPercent: _boundedPercent(parts[1]),
      message: message,
      detail: parts.sublist(3).join('|').trim(),
    );
  }
  final separator = value.indexOf('|');
  final message = separator < 0
      ? value.trim()
      : value.substring(separator + 1).trim();
  return RemoteInstallProgress(
    percent: percent,
    message: message.isEmpty ? value.trim() : message,
  );
}

String shellQuote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";

int? _boundedPercent(String? value) {
  final parsed = int.tryParse(value?.trim() ?? '');
  return parsed?.clamp(0, 100).toInt();
}

bool _notEmpty(String? value) => value?.trim().isNotEmpty == true;

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

const _installTemplate = r'''
set -eu
progress() { printf '::progress::%s|%s|%s|%s\n' "$1" "$2" "$3" "$4"; }
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
file_size() {
  if [ -f "$1" ]; then
    wc -c < "$1" | tr -d '[:space:]'
  else
    printf 0
  fi
}
download_size() {
  DOWNLOAD_URL="$1"
  if command -v curl >/dev/null 2>&1; then
    curl --fail --location --silent --show-error --head --connect-timeout 15 "$DOWNLOAD_URL" 2>/dev/null |
      awk 'tolower($1) == "content-length:" { size=$2 } END { gsub(/[^0-9]/, "", size); if (size != "") print size }'
  elif command -v wget >/dev/null 2>&1; then
    wget --spider --server-response --timeout=30 "$DOWNLOAD_URL" 2>&1 |
      awk 'tolower($1) == "content-length:" { size=$2 } END { gsub(/[^0-9]/, "", size); if (size != "") print size }'
  fi
}
download_file() {
  DOWNLOAD_URL="$1"
  DOWNLOAD_DEST="$2"
  DOWNLOAD_FROM="$3"
  DOWNLOAD_TO="$4"
  DOWNLOAD_LABEL="$5"
  DOWNLOAD_TOTAL="$(download_size "$DOWNLOAD_URL")"
  case "$DOWNLOAD_TOTAL" in
    ''|*[!0-9]*) DOWNLOAD_TOTAL=0 ;;
  esac
  progress "$DOWNLOAD_FROM" 0 "$DOWNLOAD_LABEL" '正在连接下载服务器'
  if command -v curl >/dev/null 2>&1; then
    curl --fail --location --retry 3 --connect-timeout 15 --silent --show-error \
      --output "$DOWNLOAD_DEST" "$DOWNLOAD_URL" &
  else
    wget --tries=3 --timeout=30 --no-verbose --output-document="$DOWNLOAD_DEST" "$DOWNLOAD_URL" &
  fi
  DOWNLOAD_PID="$!"
  DOWNLOAD_LAST=-1
  while kill -0 "$DOWNLOAD_PID" 2>/dev/null; do
    DOWNLOAD_BYTES="$(file_size "$DOWNLOAD_DEST")"
    if [ "$DOWNLOAD_TOTAL" -gt 0 ]; then
      DOWNLOAD_PERCENT="$((DOWNLOAD_BYTES * 100 / DOWNLOAD_TOTAL))"
      if [ "$DOWNLOAD_PERCENT" -gt 99 ]; then DOWNLOAD_PERCENT=99; fi
      DOWNLOAD_OVERALL="$((DOWNLOAD_FROM + (DOWNLOAD_TO - DOWNLOAD_FROM) * DOWNLOAD_PERCENT / 100))"
      if [ "$DOWNLOAD_BYTES" != "$DOWNLOAD_LAST" ]; then
        progress "$DOWNLOAD_OVERALL" "$DOWNLOAD_PERCENT" "$DOWNLOAD_LABEL" \
          "$(format_bytes "$DOWNLOAD_BYTES") / $(format_bytes "$DOWNLOAD_TOTAL")"
        DOWNLOAD_LAST="$DOWNLOAD_BYTES"
      fi
    elif [ "$DOWNLOAD_BYTES" != "$DOWNLOAD_LAST" ]; then
      progress "$DOWNLOAD_FROM" '' "$DOWNLOAD_LABEL" \
        "已下载 $(format_bytes "$DOWNLOAD_BYTES")（服务器未提供总大小）"
      DOWNLOAD_LAST="$DOWNLOAD_BYTES"
    fi
    sleep 1
  done
  if wait "$DOWNLOAD_PID"; then
    progress "$DOWNLOAD_TO" 100 "$DOWNLOAD_LABEL" \
      "$(format_bytes "$(file_size "$DOWNLOAD_DEST")") 下载完成"
  else
    DOWNLOAD_STATUS="$?"
    exit "$DOWNLOAD_STATUS"
  fi
}
ROOT="$HOME/.local/share/codex-remote"
BIN_DIR="$HOME/.local/bin"
LOCK_FILE="$ROOT/.install.lock"
ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64|amd64) NODE_ARCH=x64; NODE_SHA=0fa01328a0f3d10800623f7107fbcd654a60ec178fab1ef5b9779e94e0419e1a ;;
  aarch64|arm64) NODE_ARCH=arm64; NODE_SHA=3e99df8b01b27dc8b334a2a30d1cd500442b3b0877d217b308fd61a9ccfc33d4 ;;
  *) printf '不支持的服务器架构: %s\n' "$ARCH_RAW" >&2; exit 64 ;;
esac
NODE_NAME="node-v__NODE_VERSION__-linux-$NODE_ARCH"
NODE_SLOT="$NODE_NAME"
NODE_DIR="$ROOT/runtime/$NODE_NAME"
NODE_URL="https://nodejs.org/dist/v__NODE_VERSION__/$NODE_NAME.tar.gz"
WORK="$ROOT/.install-$$"
NEW_NODE_DIR=
TEMP_RELEASE=
WRAPPER=
SSH_PARENT="${CODEX_REMOTE_SSH_PID:-$PPID}"
WATCHDOG_PID=
INSTALL_COMMITTED=0
DOWNLOAD_PROXY=__PROXY_SHELL__
if [ -n "$DOWNLOAD_PROXY" ]; then
  HTTP_PROXY="$DOWNLOAD_PROXY"
  HTTPS_PROXY="$DOWNLOAD_PROXY"
  ALL_PROXY="$DOWNLOAD_PROXY"
  http_proxy="$DOWNLOAD_PROXY"
  https_proxy="$DOWNLOAD_PROXY"
  all_proxy="$DOWNLOAD_PROXY"
  npm_config_proxy="$DOWNLOAD_PROXY"
  npm_config_https_proxy="$DOWNLOAD_PROXY"
  export HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy
  export npm_config_proxy npm_config_https_proxy
fi
progress 5 '' '准备远程安装环境' '检查空间、下载器和安装锁'
mkdir -p "$ROOT" "$BIN_DIR" "$ROOT/runtime" "$ROOT/releases"
ssh_parent_alive() {
  kill -0 "$SSH_PARENT" 2>/dev/null || return 1
  [ -r "/proc/$SSH_PARENT/stat" ] || return 0
  PARENT_STATE=
  read -r _ _ PARENT_STATE _ < "/proc/$SSH_PARENT/stat" || return 0
  [ "$PARENT_STATE" != Z ]
}
watch_ssh_parent() {
  trap 'exit 0' USR1
  trap '' HUP INT TERM
  while ssh_parent_alive; do sleep 1; done
  kill -TERM 0 2>/dev/null || true
  sleep 1
  rm -rf "$WORK"
}
cleanup() {
  if [ -n "$WATCHDOG_PID" ]; then
    kill -USR1 "$WATCHDOG_PID" 2>/dev/null || true
    wait "$WATCHDOG_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
  if [ "$INSTALL_COMMITTED" != 1 ]; then
    [ -z "$TEMP_RELEASE" ] || rm -rf "$TEMP_RELEASE"
    [ -z "$NEW_NODE_DIR" ] || rm -rf "$NEW_NODE_DIR"
  fi
  [ -z "$WRAPPER" ] || rm -f "$WRAPPER"
}
on_signal() { exit 130; }
trap cleanup EXIT
trap on_signal HUP INT TERM
watch_ssh_parent &
WATCHDOG_PID="$!"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  printf '另一个 Agent 安装任务正在运行\n' >&2
  exit 75
fi
printf '%s\n' "$$" >&9
mkdir -p "$WORK"
AVAILABLE_KB="$(df -Pk "$HOME" | awk 'NR==2 {print $4}')"
if [ "${AVAILABLE_KB:-0}" -lt 307200 ]; then
  printf '用户目录可用空间不足 300 MB\n' >&2
  exit 74
fi
node_runtime_works() {
  [ -x "$1/bin/node" ] && [ -x "$1/bin/npm" ] && \
    [ "$("$1/bin/node" --version 2>/dev/null || true)" = "v__NODE_VERSION__" ] && \
    PATH="$1/bin:$PATH" "$1/bin/npm" --version >/dev/null 2>&1
}
NODE_OK=0
if node_runtime_works "$NODE_DIR"; then
  NODE_OK=1
else
  for CANDIDATE in "$ROOT"/runtime/"$NODE_NAME"-*; do
    if node_runtime_works "$CANDIDATE"; then
      NODE_DIR="$CANDIDATE"
      NODE_OK=1
      break
    fi
  done
fi
if [ "$NODE_OK" != 1 ]; then
  ARCHIVE="$WORK/$NODE_NAME.tar.gz"
  download_file "$NODE_URL" "$ARCHIVE" 15 38 '下载独立 Node.js 运行时'
  progress 40 '' '校验 Node.js 下载文件' '校验 SHA-256'
  printf '%s  %s\n' "$NODE_SHA" "$ARCHIVE" | sha256sum -c -
  progress 46 '' '解压 Node.js 运行时' '正在准备独立运行环境'
  mkdir -p "$WORK/node"
  tar -xzf "$ARCHIVE" -C "$WORK/node" --strip-components=1
  if [ "$("$WORK/node/bin/node" --version 2>/dev/null || true)" != "v__NODE_VERSION__" ] || \
    ! PATH="$WORK/node/bin:$PATH" "$WORK/node/bin/npm" --version >/dev/null 2>&1; then
    printf '下载的 Node.js 运行时无法在此服务器执行\n' >&2
    exit 65
  fi
  NODE_SLOT="$NODE_NAME-$NODE_SHA-$$"
  while [ -e "$ROOT/runtime/$NODE_SLOT" ]; do
    NODE_SLOT="$NODE_SLOT-next"
  done
  NODE_DIR="$ROOT/runtime/$NODE_SLOT"
  mv "$WORK/node" "$NODE_DIR"
  NEW_NODE_DIR="$NODE_DIR"
  progress 52 '' 'Node.js 运行时已就绪' '独立运行环境准备完成'
else
  progress 52 '' '复用现有 Node.js 运行时' '已检测到匹配的独立运行时'
fi
progress 55 '' '准备 Codex CLI 安装目录' '创建隔离发布目录'
RELEASE_SLOT="__CODEX_VERSION__-$$"
while [ -e "$ROOT/releases/$RELEASE_SLOT" ]; do
  RELEASE_SLOT="$RELEASE_SLOT-next"
done
TEMP_RELEASE="$ROOT/releases/$RELEASE_SLOT"
mkdir "$TEMP_RELEASE"
cat > "$TEMP_RELEASE/package.json" <<EOF
{"private":true,"dependencies":{"@openai/codex":"__CODEX_VERSION__"}}
EOF
progress 60 '' '分析 Codex CLI 下载清单' '正在锁定版本和依赖关系'
(
  cd "$TEMP_RELEASE"
  PATH="$NODE_DIR/bin:$PATH" "$NODE_DIR/bin/npm" install --package-lock-only \
    --ignore-scripts --omit=dev --no-audit --no-fund --loglevel=error
)
PACKAGE_TOTAL="$(
  "$NODE_DIR/bin/node" -e 'const lock = require(process.argv[1]); const packages = lock.packages || {}; console.log(Object.keys(packages).filter((path) => path.startsWith("node_modules/")).length)' \
    "$TEMP_RELEASE/package-lock.json"
)"
case "$PACKAGE_TOTAL" in
  ''|*[!0-9]*) PACKAGE_TOTAL=1 ;;
esac
progress 65 0 '下载并安装 Codex CLI __CODEX_VERSION__' "共 $PACKAGE_TOTAL 个组件"
NPM_LOG="$WORK/npm-install.log"
(
  cd "$TEMP_RELEASE"
  PATH="$NODE_DIR/bin:$PATH" "$NODE_DIR/bin/npm" ci \
    --omit=dev --no-audit --no-fund --loglevel=error
) > "$NPM_LOG" 2>&1 &
NPM_PID="$!"
NPM_LAST=
while kill -0 "$NPM_PID" 2>/dev/null; do
  NPM_COMPLETE="$(find "$TEMP_RELEASE/node_modules" -type f -name package.json 2>/dev/null | wc -l | tr -d '[:space:]')"
  case "$NPM_COMPLETE" in
    ''|*[!0-9]*) NPM_COMPLETE=0 ;;
  esac
  if [ "$NPM_COMPLETE" -gt "$PACKAGE_TOTAL" ]; then PACKAGE_TOTAL="$NPM_COMPLETE"; fi
  NPM_PERCENT="$((NPM_COMPLETE * 100 / PACKAGE_TOTAL))"
  if [ "$NPM_PERCENT" -gt 99 ]; then NPM_PERCENT=99; fi
  NPM_OVERALL="$((65 + NPM_PERCENT * 23 / 100))"
  NPM_SIZE_KB="$(du -sk "$TEMP_RELEASE/node_modules" 2>/dev/null | awk 'NR == 1 { print $1 }')"
  case "$NPM_SIZE_KB" in
    ''|*[!0-9]*) NPM_SIZE_KB=0 ;;
  esac
  NPM_DETAIL="已处理 $NPM_COMPLETE / $PACKAGE_TOTAL 个组件 · $(format_bytes "$((NPM_SIZE_KB * 1024))")"
  if [ "$NPM_DETAIL" != "$NPM_LAST" ]; then
    progress "$NPM_OVERALL" "$NPM_PERCENT" "下载并安装 Codex CLI __CODEX_VERSION__" "$NPM_DETAIL"
    NPM_LAST="$NPM_DETAIL"
  fi
  sleep 1
done
if wait "$NPM_PID"; then
  progress 88 100 '下载并安装 Codex CLI __CODEX_VERSION__' "已完成 $PACKAGE_TOTAL 个组件"
else
  NPM_STATUS="$?"
  cat "$NPM_LOG" >&2 || true
  exit "$NPM_STATUS"
fi
progress 90 '' '验证 Codex app-server' '检查命令行版本和 app-server'
CLI_JS="$TEMP_RELEASE/node_modules/@openai/codex/bin/codex.js"
ACTUAL="$("$NODE_DIR/bin/node" "$CLI_JS" --version)"
if [ "$ACTUAL" != "codex-cli __CODEX_VERSION__" ]; then
  printf 'Codex 版本校验失败: %s\n' "$ACTUAL" >&2
  exit 65
fi
"$NODE_DIR/bin/node" "$CLI_JS" app-server --help >/dev/null
WRAPPER="$BIN_DIR/.codex-remote.$$"
cat > "$WRAPPER" <<EOF
#!/bin/sh
# codex-remote-global-env
if [ -r "\${HOME}/.codex/codex-remote.env" ]; then
  . "\${HOME}/.codex/codex-remote.env"
fi
MODEL_CACHE="\${HOME}/.codex/models_cache.json"
if [ "\${1:-}" = "app-server" ] && \
  [ -r "\${MODEL_CACHE}" ] && \
  ! grep -Fq '"supports_reasoning_summaries"' "\${MODEL_CACHE}"; then
  mv "\${MODEL_CACHE}" "\${MODEL_CACHE}.incompatible.\$(date +%s)" 2>/dev/null || true
fi
exec "\${HOME}/.local/share/codex-remote/runtime/$NODE_SLOT/bin/node" "\${HOME}/.local/share/codex-remote/releases/$RELEASE_SLOT/node_modules/@openai/codex/bin/codex.js" "\$@"
EOF
chmod 700 "$WRAPPER"
"$WRAPPER" --version >/dev/null
INSTALL_COMMITTED=1
mv -f "$WRAPPER" "$BIN_DIR/codex-remote"
"$BIN_DIR/codex-remote" --version
progress 100 '' '安装完成' 'Codex app-server 已就绪'
''';
