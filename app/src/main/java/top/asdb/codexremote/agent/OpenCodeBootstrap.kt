package top.asdb.codexremote.agent

import java.security.MessageDigest
import java.util.Base64

internal fun quoteShellArgument(value: String): String = "'${value.replace("'", "'\\''")}'"

internal object OpenCodeBootstrap {
    private const val PREFIX = "__CODEX_REMOTE_OPENCODE_"
    private const val SHELL_DOLLAR = "__SHELL_DOLLAR__"

    val probeScript: String = """
        set -u
        value() { printf '${PREFIX}%s=%s\n' "__SHELL_DOLLAR__1" "__SHELL_DOLLAR__2"; }
        ROOT="__SHELL_DOLLAR__HOME/.local/share/codex-remote"
        WRAPPER="__SHELL_DOLLAR__HOME/.local/bin/codex-remote-opencode-bridge"
        if [ -x "__SHELL_DOLLAR__WRAPPER" ]; then
          value BRIDGE "__SHELL_DOLLAR__WRAPPER"
        fi
        BRIDGE_HASH="__SHELL_DOLLAR__ROOT/opencode/bridge.sha256"
        if [ -r "__SHELL_DOLLAR__BRIDGE_HASH" ]; then
          value BRIDGE_SHA256 "__SHELL_DOLLAR__(cat "__SHELL_DOLLAR__BRIDGE_HASH" 2>/dev/null || true)"
        fi
        OPENCODE_BIN="__SHELL_DOLLAR__(find -L "__SHELL_DOLLAR__ROOT/opencode/releases" -path '*/node_modules/.bin/opencode' -type f -perm -u+x 2>/dev/null | sort | tail -n 1)"
        if [ -n "__SHELL_DOLLAR__OPENCODE_BIN" ] && [ -x "__SHELL_DOLLAR__OPENCODE_BIN" ]; then
          value PATH "__SHELL_DOLLAR__OPENCODE_BIN"
          value VERSION "__SHELL_DOLLAR__("__SHELL_DOLLAR__OPENCODE_BIN" --version 2>/dev/null || true)"
        fi
    """.trimIndent().replace(SHELL_DOLLAR, "\$")

    fun parseProbe(lines: List<String>): Map<String, String> = lines.mapNotNull { line ->
        if (!line.startsWith(PREFIX)) return@mapNotNull null
        val pair = line.removePrefix(PREFIX).split('=', limit = 2)
        if (pair.size == 2) pair[0] to pair[1] else null
    }.toMap()

    fun installScript(
        openCodeVersion: String,
        proxyUrl: String,
        bridgeSource: String,
    ): String {
        require(bridgeSource.isNotBlank()) { "OpenCode bridge resource is empty" }
        val encodedBridge = Base64.getEncoder().encodeToString(bridgeSource.toByteArray(Charsets.UTF_8))
        val bridgeSha256 = bridgeSha256(bridgeSource)
        return """
            set -eu
            progress() { printf '::progress::%s|%s|%s|%s\n' "__SHELL_DOLLAR__1" "__SHELL_DOLLAR__2" "__SHELL_DOLLAR__3" "__SHELL_DOLLAR__4"; }
            ROOT="__SHELL_DOLLAR__HOME/.local/share/codex-remote"
            BIN_DIR="__SHELL_DOLLAR__HOME/.local/bin"
            OPENCODE_ROOT="__SHELL_DOLLAR__ROOT/opencode"
            RELEASE="__SHELL_DOLLAR__OPENCODE_ROOT/releases/$openCodeVersion"
            WORK="__SHELL_DOLLAR__OPENCODE_ROOT/.install-__SHELL_DOLLAR____SHELL_DOLLAR__"
            PROXY=${quoteShellArgument(proxyUrl)}
            cleanup() { rm -rf "__SHELL_DOLLAR__WORK"; }
            trap cleanup EXIT HUP INT TERM
            progress 70 '' '准备 OpenCode 运行时' '检查共享 Node.js 环境'
            NODE="__SHELL_DOLLAR__(find "__SHELL_DOLLAR__ROOT/runtime" -path '*/bin/node' -type f -perm -u+x 2>/dev/null | sort | tail -n 1)"
            if [ -z "__SHELL_DOLLAR__NODE" ] || [ ! -x "__SHELL_DOLLAR__NODE" ]; then
              printf '未找到 Codex Remote 管理的 Node.js 运行时\n' >&2
              exit 65
            fi
            NODE_BIN="__SHELL_DOLLAR__(dirname "__SHELL_DOLLAR__NODE")"
            NPM="__SHELL_DOLLAR__NODE_BIN/npm"
            if [ ! -x "__SHELL_DOLLAR__NPM" ]; then
              printf '共享 Node.js 运行时缺少 npm\n' >&2
              exit 65
            fi
            if [ -n "__SHELL_DOLLAR__PROXY" ]; then
              HTTP_PROXY="__SHELL_DOLLAR__PROXY"
              HTTPS_PROXY="__SHELL_DOLLAR__PROXY"
              ALL_PROXY="__SHELL_DOLLAR__PROXY"
              npm_config_proxy="__SHELL_DOLLAR__PROXY"
              npm_config_https_proxy="__SHELL_DOLLAR__PROXY"
              export HTTP_PROXY HTTPS_PROXY ALL_PROXY npm_config_proxy npm_config_https_proxy
            fi
            npm_config_registry=https://registry.npmmirror.com
            export npm_config_registry
            mkdir -p "__SHELL_DOLLAR__OPENCODE_ROOT/releases" "__SHELL_DOLLAR__BIN_DIR" "__SHELL_DOLLAR__WORK"
            cat > "__SHELL_DOLLAR__WORK/package.json" <<'EOF'
            {"private":true,"dependencies":{"jsonc-parser":"3.3.1","opencode-ai":"$openCodeVersion"}}
            EOF
            progress 74 '' '分析 OpenCode 下载清单' '锁定 OpenCode $openCodeVersion'
            (
              cd "__SHELL_DOLLAR__WORK"
              PATH="__SHELL_DOLLAR__NODE_BIN:__SHELL_DOLLAR__PATH" "__SHELL_DOLLAR__NPM" install --package-lock-only \
                --omit=dev --no-audit --no-fund --loglevel=error
            )
            progress 78 0 '下载并安装 OpenCode $openCodeVersion' '正在下载平台运行文件'
            (
              cd "__SHELL_DOLLAR__WORK"
              PATH="__SHELL_DOLLAR__NODE_BIN:__SHELL_DOLLAR__PATH" "__SHELL_DOLLAR__NPM" ci \
                --omit=dev --omit=optional --no-audit --no-fund --loglevel=error
            )
            OPENCODE_BIN="__SHELL_DOLLAR__WORK/node_modules/.bin/opencode"
            if [ ! -x "__SHELL_DOLLAR__OPENCODE_BIN" ]; then
              printf 'OpenCode 安装后缺少可执行文件\n' >&2
              exit 65
            fi
            ACTUAL="__SHELL_DOLLAR__("__SHELL_DOLLAR__OPENCODE_BIN" --version 2>/dev/null || true)"
            case "__SHELL_DOLLAR__ACTUAL" in
              *"$openCodeVersion"*) ;;
              *) printf 'OpenCode 版本校验失败: %s\n' "__SHELL_DOLLAR__ACTUAL" >&2; exit 65 ;;
            esac
            progress 94 100 '下载并安装 OpenCode $openCodeVersion' "__SHELL_DOLLAR__ACTUAL"
            rm -rf "__SHELL_DOLLAR__RELEASE"
            mv "__SHELL_DOLLAR__WORK" "__SHELL_DOLLAR__RELEASE"
            mkdir -p "__SHELL_DOLLAR__OPENCODE_ROOT"
            BRIDGE="__SHELL_DOLLAR__OPENCODE_ROOT/bridge.cjs"
            "__SHELL_DOLLAR__NODE" -e 'require("node:fs").writeFileSync(process.argv[1], Buffer.from(process.argv[2], "base64"), { mode: 384 })' \
              "__SHELL_DOLLAR__BRIDGE" ${quoteShellArgument(encodedBridge)}
            printf '%s\n' '$bridgeSha256' > "__SHELL_DOLLAR__OPENCODE_ROOT/bridge.sha256"
            WRAPPER="__SHELL_DOLLAR__BIN_DIR/.codex-remote-opencode-bridge.__SHELL_DOLLAR____SHELL_DOLLAR__"
            cat > "__SHELL_DOLLAR__WRAPPER" <<'EOF'
            #!/bin/sh
            ROOT="__SHELL_DOLLAR__HOME/.local/share/codex-remote"
            NODE="__SHELL_DOLLAR__(find "__SHELL_DOLLAR__ROOT/runtime" -path '*/bin/node' -type f -perm -u+x 2>/dev/null | sort | tail -n 1)"
            export PATH="__SHELL_DOLLAR__(dirname "__SHELL_DOLLAR__NODE"):__SHELL_DOLLAR__PATH"
            export OPENCODE_BIN="__SHELL_DOLLAR__ROOT/opencode/releases/$openCodeVersion/node_modules/.bin/opencode"
            exec "__SHELL_DOLLAR__NODE" "__SHELL_DOLLAR__ROOT/opencode/bridge.cjs" "__SHELL_DOLLAR__@"
            EOF
            chmod 700 "__SHELL_DOLLAR__WRAPPER"
            mv -f "__SHELL_DOLLAR__WRAPPER" "__SHELL_DOLLAR__BIN_DIR/codex-remote-opencode-bridge"
            trap - EXIT HUP INT TERM
            progress 100 '' '安装完成' 'OpenCode 服务与移动端桥接已就绪'
        """.trimIndent().replace(SHELL_DOLLAR, "\$")
    }

    fun bridgeSha256(bridgeSource: String): String = MessageDigest.getInstance("SHA-256")
        .digest(bridgeSource.toByteArray(Charsets.UTF_8))
        .joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }

    val uninstallScript: String = """
        set -eu
        rm -f "__SHELL_DOLLAR__HOME/.local/bin/codex-remote-opencode-bridge"
        rm -rf "__SHELL_DOLLAR__HOME/.local/share/codex-remote/opencode"
    """.trimIndent().replace(SHELL_DOLLAR, "\$")
}
