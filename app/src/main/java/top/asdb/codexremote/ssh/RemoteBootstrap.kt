package top.asdb.codexremote.ssh

import java.util.Locale

data class RemoteEnvironment(
    val os: String,
    val architecture: String,
    val home: String,
    val libc: String,
    val managedVersion: String?,
    val managedPath: String?,
    val systemVersion: String?,
    val systemPath: String?,
    val hasShell: Boolean,
    val hasTar: Boolean,
    val hasSha256: Boolean,
    val hasFlock: Boolean,
    val hasSetsidWait: Boolean,
    val downloader: String?,
) {
    fun compatibleCommand(expectedVersion: String): String? = when {
        managedVersion == "codex-cli $expectedVersion" && !managedPath.isNullOrBlank() ->
            "${shellQuote(managedPath)} app-server --listen stdio://"
        systemVersion == "codex-cli $expectedVersion" && !systemPath.isNullOrBlank() ->
            "${shellQuote(systemPath)} app-server --listen stdio://"
        else -> null
    }

    fun detectedVersion(): String? = managedVersion ?: systemVersion

    fun installationProblem(): String? = when {
        os != "Linux" -> "暂不支持在 $os 上自动安装"
        architecture !in SUPPORTED_ARCHITECTURES -> "暂不支持 $architecture 架构"
        libc == "musl" -> "暂不支持 musl libc；自动安装需要 glibc Linux"
        !hasShell -> "服务器缺少 /bin/sh"
        !hasTar -> "服务器缺少 tar"
        !hasSha256 -> "服务器缺少 sha256sum"
        !hasFlock -> "服务器缺少 flock"
        !hasSetsidWait -> "服务器缺少支持 --wait 的 setsid"
        downloader == null -> "服务器缺少 curl 或 wget"
        else -> null
    }

    companion object {
        private val SUPPORTED_ARCHITECTURES = setOf("x86_64", "amd64", "aarch64", "arm64")
    }
}

object RemoteBootstrap {
    const val MANAGED_REMOTE_COMMAND = "~/.local/bin/codex-remote app-server --listen stdio://"
    private const val PREFIX = "__CODEX_REMOTE_"
    private const val NODE_X64_SHA256 = "0fa01328a0f3d10800623f7107fbcd654a60ec178fab1ef5b9779e94e0419e1a"
    private const val NODE_ARM64_SHA256 = "3e99df8b01b27dc8b334a2a30d1cd500442b3b0877d217b308fd61a9ccfc33d4"

    val probeScript: String = """
        set -u
        value() { printf '${PREFIX}%s=%s\n' "${'$'}1" "${'$'}2"; }
        value OS "${'$'}(uname -s 2>/dev/null || printf unknown)"
        value ARCH "${'$'}(uname -m 2>/dev/null || printf unknown)"
        value HOME "${'$'}HOME"
        if ldd --version 2>&1 | grep -qi musl; then
          value LIBC musl
        elif ldd --version 2>&1 | grep -Eqi 'glibc|gnu libc'; then
          value LIBC glibc
        else
          value LIBC unknown
        fi
        if [ -x "${'$'}HOME/.local/bin/codex-remote" ]; then
          value MANAGED_PATH "${'$'}HOME/.local/bin/codex-remote"
          value MANAGED_VERSION "${'$'}("${'$'}HOME/.local/bin/codex-remote" --version 2>/dev/null || true)"
        fi
        if command -v codex >/dev/null 2>&1; then
          value SYSTEM_PATH "${'$'}(command -v codex)"
          value SYSTEM_VERSION "${'$'}(codex --version 2>/dev/null || true)"
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
    """.trimIndent()

    fun parseProbe(lines: List<String>): RemoteEnvironment {
        val values = lines.mapNotNull { line ->
            if (!line.startsWith(PREFIX)) return@mapNotNull null
            val pair = line.removePrefix(PREFIX).split('=', limit = 2)
            if (pair.size == 2) pair[0] to pair[1] else null
        }.toMap()
        return RemoteEnvironment(
            os = values["OS"].orEmpty(),
            architecture = values["ARCH"].orEmpty(),
            home = values["HOME"].orEmpty(),
            libc = values["LIBC"].orEmpty(),
            managedVersion = values["MANAGED_VERSION"]?.takeIf { it.isNotBlank() },
            managedPath = values["MANAGED_PATH"]?.takeIf { it.isNotBlank() },
            systemVersion = values["SYSTEM_VERSION"]?.takeIf { it.isNotBlank() },
            systemPath = values["SYSTEM_PATH"]?.takeIf { it.isNotBlank() },
            hasShell = values["HAS_SHELL"] == "1",
            hasTar = values["HAS_TAR"] == "1",
            hasSha256 = values["HAS_SHA256"] == "1",
            hasFlock = values["HAS_FLOCK"] == "1",
            hasSetsidWait = values["HAS_SETSID_WAIT"] == "1",
            downloader = values["DOWNLOADER"]?.takeUnless { it == "none" || it.isBlank() },
        )
    }

    fun installScript(
        codexVersion: String,
        nodeVersion: String,
        proxyUrl: String = "",
    ): String {
        val normalizedProxy = validateProxyUrl(proxyUrl)
        return """
        set -eu
        progress() { printf '::progress::%s|%s\n' "${'$'}1" "${'$'}2"; }
        ROOT="${'$'}HOME/.local/share/codex-remote"
        BIN_DIR="${'$'}HOME/.local/bin"
        LOCK_FILE="${'$'}ROOT/.install.lock"
        ARCH_RAW="${'$'}(uname -m)"
        case "${'$'}ARCH_RAW" in
          x86_64|amd64) NODE_ARCH=x64; NODE_SHA=$NODE_X64_SHA256 ;;
          aarch64|arm64) NODE_ARCH=arm64; NODE_SHA=$NODE_ARM64_SHA256 ;;
          *) printf '不支持的服务器架构: %s\n' "${'$'}ARCH_RAW" >&2; exit 64 ;;
        esac
        NODE_NAME="node-v$nodeVersion-linux-${'$'}NODE_ARCH"
        NODE_SLOT="${'$'}NODE_NAME"
        NODE_DIR="${'$'}ROOT/runtime/${'$'}NODE_NAME"
        NODE_URL="https://nodejs.org/dist/v$nodeVersion/${'$'}NODE_NAME.tar.gz"
        WORK="${'$'}ROOT/.install-${'$'}${'$'}"
        NEW_NODE_DIR=
        TEMP_RELEASE=
        WRAPPER=
        SSH_PARENT="${'$'}{CODEX_REMOTE_SSH_PID:-${'$'}PPID}"
        WATCHDOG_PID=
        INSTALL_COMMITTED=0
        DOWNLOAD_PROXY=${shellQuote(normalizedProxy)}
        if [ -n "${'$'}DOWNLOAD_PROXY" ]; then
          HTTP_PROXY="${'$'}DOWNLOAD_PROXY"
          HTTPS_PROXY="${'$'}DOWNLOAD_PROXY"
          ALL_PROXY="${'$'}DOWNLOAD_PROXY"
          http_proxy="${'$'}DOWNLOAD_PROXY"
          https_proxy="${'$'}DOWNLOAD_PROXY"
          all_proxy="${'$'}DOWNLOAD_PROXY"
          npm_config_proxy="${'$'}DOWNLOAD_PROXY"
          npm_config_https_proxy="${'$'}DOWNLOAD_PROXY"
          export HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy
          export npm_config_proxy npm_config_https_proxy
        fi
        progress 5 '准备远程安装环境'
        mkdir -p "${'$'}ROOT" "${'$'}BIN_DIR" "${'$'}ROOT/runtime" "${'$'}ROOT/releases"
        ssh_parent_alive() {
          kill -0 "${'$'}SSH_PARENT" 2>/dev/null || return 1
          [ -r "/proc/${'$'}SSH_PARENT/stat" ] || return 0
          PARENT_STATE=
          read -r _ _ PARENT_STATE _ < "/proc/${'$'}SSH_PARENT/stat" || return 0
          [ "${'$'}PARENT_STATE" != Z ]
        }
        watch_ssh_parent() {
          trap 'exit 0' USR1
          trap '' HUP INT TERM
          while ssh_parent_alive; do sleep 1; done
          kill -TERM 0 2>/dev/null || true
          sleep 1
          rm -rf "${'$'}WORK"
        }
        cleanup() {
          if [ -n "${'$'}WATCHDOG_PID" ]; then
            kill -USR1 "${'$'}WATCHDOG_PID" 2>/dev/null || true
            wait "${'$'}WATCHDOG_PID" 2>/dev/null || true
          fi
          rm -rf "${'$'}WORK"
          if [ "${'$'}INSTALL_COMMITTED" != 1 ]; then
            [ -z "${'$'}TEMP_RELEASE" ] || rm -rf "${'$'}TEMP_RELEASE"
            [ -z "${'$'}NEW_NODE_DIR" ] || rm -rf "${'$'}NEW_NODE_DIR"
          fi
          [ -z "${'$'}WRAPPER" ] || rm -f "${'$'}WRAPPER"
        }
        on_signal() { exit 130; }
        trap cleanup EXIT
        trap on_signal HUP INT TERM
        watch_ssh_parent &
        WATCHDOG_PID="${'$'}!"
        exec 9>"${'$'}LOCK_FILE"
        if ! flock -n 9; then
          printf '另一个 Codex 安装任务正在运行\n' >&2
          exit 75
        fi
        printf '%s\n' "${'$'}${'$'}" >&9
        mkdir -p "${'$'}WORK"
        AVAILABLE_KB="${'$'}(df -Pk "${'$'}HOME" | awk 'NR==2 {print ${'$'}4}')"
        if [ "${'$'}{AVAILABLE_KB:-0}" -lt 307200 ]; then
          printf '用户目录可用空间不足 300 MB\n' >&2
          exit 74
        fi
        NODE_OK=0
        if [ -x "${'$'}NODE_DIR/bin/node" ] && [ -x "${'$'}NODE_DIR/bin/npm" ] && \
          [ "${'$'}("${'$'}NODE_DIR/bin/node" --version 2>/dev/null || true)" = "v$nodeVersion" ] && \
          PATH="${'$'}NODE_DIR/bin:${'$'}PATH" "${'$'}NODE_DIR/bin/npm" --version >/dev/null 2>&1; then
          NODE_OK=1
        fi
        if [ "${'$'}NODE_OK" != 1 ]; then
          progress 15 '下载独立 Node.js 运行时'
          ARCHIVE="${'$'}WORK/${'$'}NODE_NAME.tar.gz"
          if command -v curl >/dev/null 2>&1; then
            curl --fail --location --retry 3 --connect-timeout 15 --output "${'$'}ARCHIVE" "${'$'}NODE_URL"
          elif command -v wget >/dev/null 2>&1; then
            wget --tries=3 --timeout=30 --output-document="${'$'}ARCHIVE" "${'$'}NODE_URL"
          else
            printf '服务器缺少 curl 或 wget\n' >&2
            exit 69
          fi
          progress 40 '校验 Node.js 下载文件'
          printf '%s  %s\n' "${'$'}NODE_SHA" "${'$'}ARCHIVE" | sha256sum -c -
          mkdir -p "${'$'}WORK/node"
          tar -xzf "${'$'}ARCHIVE" -C "${'$'}WORK/node" --strip-components=1
          if [ "${'$'}("${'$'}WORK/node/bin/node" --version 2>/dev/null || true)" != "v$nodeVersion" ] || \
            ! PATH="${'$'}WORK/node/bin:${'$'}PATH" "${'$'}WORK/node/bin/npm" --version >/dev/null 2>&1; then
            printf '下载的 Node.js 运行时无法在此服务器执行\n' >&2
            exit 65
          fi
          NODE_SLOT="${'$'}NODE_NAME-${'$'}NODE_SHA-${'$'}${'$'}"
          while [ -e "${'$'}ROOT/runtime/${'$'}NODE_SLOT" ]; do
            NODE_SLOT="${'$'}NODE_SLOT-next"
          done
          NODE_DIR="${'$'}ROOT/runtime/${'$'}NODE_SLOT"
          mv "${'$'}WORK/node" "${'$'}NODE_DIR"
          NEW_NODE_DIR="${'$'}NODE_DIR"
        fi
        progress 55 '准备 Codex CLI 安装目录'
        RELEASE_SLOT="$codexVersion-${'$'}${'$'}"
        while [ -e "${'$'}ROOT/releases/${'$'}RELEASE_SLOT" ]; do
          RELEASE_SLOT="${'$'}RELEASE_SLOT-next"
        done
        TEMP_RELEASE="${'$'}ROOT/releases/${'$'}RELEASE_SLOT"
        mkdir "${'$'}TEMP_RELEASE"
        progress 65 '下载并安装 Codex CLI $codexVersion'
        PATH="${'$'}NODE_DIR/bin:${'$'}PATH" "${'$'}NODE_DIR/bin/npm" install --global --prefix "${'$'}TEMP_RELEASE" \
          "@openai/codex@$codexVersion" --omit=dev --no-audit --no-fund --loglevel=error
        CLI_JS="${'$'}TEMP_RELEASE/lib/node_modules/@openai/codex/bin/codex.js"
        ACTUAL="${'$'}("${'$'}NODE_DIR/bin/node" "${'$'}CLI_JS" --version)"
        if [ "${'$'}ACTUAL" != "codex-cli $codexVersion" ]; then
          printf 'Codex 版本校验失败: %s\n' "${'$'}ACTUAL" >&2
          exit 65
        fi
        "${'$'}NODE_DIR/bin/node" "${'$'}CLI_JS" app-server --help >/dev/null
        WRAPPER="${'$'}BIN_DIR/.codex-remote.${'$'}${'$'}"
        cat > "${'$'}WRAPPER" <<EOF
        #!/bin/sh
        # codex-remote-global-env
        if [ -r "\${'$'}{HOME}/.codex/codex-remote.env" ]; then
          . "\${'$'}{HOME}/.codex/codex-remote.env"
        fi
        exec "\${'$'}{HOME}/.local/share/codex-remote/runtime/${'$'}NODE_SLOT/bin/node" "\${'$'}{HOME}/.local/share/codex-remote/releases/${'$'}RELEASE_SLOT/lib/node_modules/@openai/codex/bin/codex.js" "\${'$'}@"
        EOF
        chmod 700 "${'$'}WRAPPER"
        "${'$'}WRAPPER" --version >/dev/null
        INSTALL_COMMITTED=1
        mv -f "${'$'}WRAPPER" "${'$'}BIN_DIR/codex-remote"
        progress 90 '验证 Codex app-server'
        "${'$'}BIN_DIR/codex-remote" --version
        progress 100 '安装完成'
        """.trimIndent()
    }

    /**
     * Removes only the runtime and launcher installed by [installScript]. System Codex installs,
     * VS Code server data, account state in ~/.codex, and user workspaces are intentionally outside
     * these paths and are never touched. The app-owned ~/.codex-mobile attachment staging directory
     * is removed with the runtime.
     */
    val uninstallScript: String = """
        set -eu
        ROOT="${'$'}HOME/.local/share/codex-remote"
        WRAPPER="${'$'}HOME/.local/bin/codex-remote"
        UPLOAD_ROOT="${'$'}HOME/.codex-mobile"

        if [ -d "${'$'}ROOT" ] && [ ! -L "${'$'}ROOT" ] && command -v flock >/dev/null 2>&1; then
          exec 9>>"${'$'}ROOT/.install.lock"
          if ! flock -n 9; then
            printf 'Codex Remote 正在安装，请稍后再卸载\n' >&2
            exit 75
          fi
        fi

        is_managed_app_server() {
          CHECK_PID="${'$'}1"
          [ "${'$'}CHECK_PID" != "${'$'}${'$'}" ] || return 1
          [ -r "/proc/${'$'}CHECK_PID/cmdline" ] || return 1
          CHECK_COMMAND_LINE="${'$'}(tr '\000' ' ' < "/proc/${'$'}CHECK_PID/cmdline" 2>/dev/null || true)"
          case "${'$'}CHECK_COMMAND_LINE" in
            "${'$'}ROOT"/runtime/*/bin/node\ "${'$'}ROOT"/releases/*/lib/node_modules/@openai/codex/bin/codex.js\ app-server*)
              return 0 ;;
          esac
          return 1
        }

        MANAGED_PIDS=
        for PROC in /proc/[0-9]*; do
          PID="${'$'}{PROC##*/}"
          if is_managed_app_server "${'$'}PID"; then
            kill -TERM "${'$'}PID" 2>/dev/null || true
            MANAGED_PIDS="${'$'}MANAGED_PIDS ${'$'}PID"
          fi
        done

        ATTEMPT=0
        while [ -n "${'$'}MANAGED_PIDS" ] && [ "${'$'}ATTEMPT" -lt 5 ]; do
          LIVE_PIDS=
          for PID in ${'$'}MANAGED_PIDS; do
            if is_managed_app_server "${'$'}PID"; then
              LIVE_PIDS="${'$'}LIVE_PIDS ${'$'}PID"
            fi
          done
          [ -n "${'$'}LIVE_PIDS" ] || break
          MANAGED_PIDS="${'$'}LIVE_PIDS"
          ATTEMPT="${'$'}((ATTEMPT + 1))"
          sleep 1
        done
        for PID in ${'$'}MANAGED_PIDS; do
          if is_managed_app_server "${'$'}PID"; then
            kill -KILL "${'$'}PID" 2>/dev/null || true
          fi
        done

        rm -f -- "${'$'}WRAPPER"
        rm -rf -- "${'$'}ROOT"
        rm -rf -- "${'$'}UPLOAD_ROOT"
        printf 'Codex Remote app service 已卸载\n'
    """.trimIndent()

    /** Reject whitespace/control characters before embedding the value in a remote shell script. */
    internal fun validateProxyUrl(value: String): String {
        val proxy = value.trim()
        if (proxy.isEmpty()) return ""
        require(proxy.all { !it.isWhitespace() && it.code in 0x20..0x7e }) {
            "代理地址不能包含空格、换行或控制字符"
        }
        val scheme = proxy.substringBefore("://", missingDelimiterValue = "").lowercase(Locale.ROOT)
        require(scheme in SUPPORTED_PROXY_SCHEMES && proxy.length > scheme.length + 3) {
            "代理地址必须以 http://、https://、socks5:// 或 socks5h:// 开头"
        }
        require(proxy.substringAfter("://").substringBefore('/').isNotBlank()) {
            "代理地址缺少主机"
        }
        return proxy
    }

    private val SUPPORTED_PROXY_SCHEMES = setOf("http", "https", "socks5", "socks5h")
}

private fun shellQuote(value: String): String = "'${value.replace("'", "'\\''")}'"
