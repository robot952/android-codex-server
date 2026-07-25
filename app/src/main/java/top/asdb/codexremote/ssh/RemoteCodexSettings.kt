package top.asdb.codexremote.ssh

import java.net.URI
import java.util.Locale
import top.asdb.codexremote.data.CodexGlobalSettings

/** Builds narrowly-scoped scripts for the user's global Codex configuration. */
internal object RemoteCodexSettings {
    private const val PREFIX = "__CODEX_GLOBAL_"

    val readScript: String = """
        set -eu
        CONFIG_DIR="${'$'}HOME/.codex"
        CONFIG_FILE="${'$'}CONFIG_DIR/config.toml"
        ENV_FILE="${'$'}CONFIG_DIR/codex-remote.env"
        AUTH_FILE="${'$'}CONFIG_DIR/auth.json"
        BASE_URL=
        if [ -r "${'$'}CONFIG_FILE" ]; then
          BASE_URL="${'$'}(awk '
            /^[[:space:]]*\[/ { in_table = 1 }
            !in_table && /^[[:space:]]*openai_base_url[[:space:]]*=/ {
              value = ${'$'}0
              sub(/^[[:space:]]*openai_base_url[[:space:]]*=[[:space:]]*/, "", value)
              sub(/[[:space:]]*#.*/, "", value)
              sub(/^[[:space:]]*"/, "", value)
              sub(/"[[:space:]]*$/, "", value)
              print value
              exit
            }
          ' "${'$'}CONFIG_FILE")"
        fi
        PROXY_URL=
        if [ -r "${'$'}ENV_FILE" ]; then
          PROXY_URL="${'$'}(awk '
            /^# codex-remote-proxy: / {
              sub(/^# codex-remote-proxy: /, "")
              print
              exit
            }
          ' "${'$'}ENV_FILE")"
        fi
        if [ -s "${'$'}AUTH_FILE" ]; then AUTH_PRESENT=1; else AUTH_PRESENT=0; fi
        printf '${PREFIX}BASE_URL=%s\n' "${'$'}BASE_URL"
        printf '${PREFIX}PROXY_URL=%s\n' "${'$'}PROXY_URL"
        printf '${PREFIX}AUTH_PRESENT=%s\n' "${'$'}AUTH_PRESENT"
    """.trimIndent()

    fun parse(lines: List<String>): CodexGlobalSettings {
        val values = lines.mapNotNull { line ->
            if (!line.startsWith(PREFIX)) return@mapNotNull null
            line.removePrefix(PREFIX).split('=', limit = 2).takeIf { it.size == 2 }
                ?.let { it[0] to it[1] }
        }.toMap()
        return CodexGlobalSettings(
            baseUrl = values["BASE_URL"].orEmpty(),
            hasStoredAuthentication = values["AUTH_PRESENT"] == "1",
            proxyUrl = values["PROXY_URL"].orEmpty(),
        )
    }

    fun writeScript(
        baseUrl: String,
        apiKey: String,
        proxyUrl: String,
    ): String {
        val normalizedBaseUrl = validateBaseUrl(baseUrl)
        val normalizedApiKey = validateApiKey(apiKey)
        val normalizedProxy = RemoteBootstrap.validateProxyUrl(proxyUrl)
        val baseLine = normalizedBaseUrl.takeIf { it.isNotBlank() }
            ?.let { "openai_base_url = \"$it\"" }
            .orEmpty()
        val proxyComment = shellQuote("# codex-remote-proxy: $normalizedProxy")
        val httpProxy = shellQuote("export HTTP_PROXY=$normalizedProxy")
        val httpsProxy = shellQuote("export HTTPS_PROXY=$normalizedProxy")
        val allProxy = shellQuote("export ALL_PROXY=$normalizedProxy")
        val lowercaseHttpProxy = shellQuote("export http_proxy=$normalizedProxy")
        val lowercaseHttpsProxy = shellQuote("export https_proxy=$normalizedProxy")
        val lowercaseAllProxy = shellQuote("export all_proxy=$normalizedProxy")
        return """
            set -eu
            CONFIG_DIR="${'$'}HOME/.codex"
            CONFIG_FILE="${'$'}CONFIG_DIR/config.toml"
            ENV_FILE="${'$'}CONFIG_DIR/codex-remote.env"
            WRAPPER="${'$'}HOME/.local/bin/codex-remote"
            BASE_URL=${shellQuote(normalizedBaseUrl)}
            API_KEY=${shellQuote(normalizedApiKey)}
            PROXY_URL=${shellQuote(normalizedProxy)}
            BASE_LINE=${shellQuote(baseLine)}
            PROVIDER_LINE='model_provider = "openai"'
            umask 077
            mkdir -p "${'$'}CONFIG_DIR"
            chmod 700 "${'$'}CONFIG_DIR"

            CONFIG_TMP="${'$'}CONFIG_FILE.tmp.${'$'}${'$'}"
            ENV_TMP="${'$'}ENV_FILE.tmp.${'$'}${'$'}"
            WRAPPER_TMP="${'$'}WRAPPER.tmp.${'$'}${'$'}"
            cleanup() { rm -f "${'$'}CONFIG_TMP" "${'$'}ENV_TMP" "${'$'}WRAPPER_TMP"; }
            trap cleanup EXIT HUP INT TERM

            if [ -f "${'$'}CONFIG_FILE" ]; then CONFIG_SOURCE="${'$'}CONFIG_FILE"; else CONFIG_SOURCE=/dev/null; fi
            awk -v provider_line="${'$'}PROVIDER_LINE" -v base_line="${'$'}BASE_LINE" '
              function inject_root_keys() {
                if (!injected) {
                  print provider_line
                  if (base_line != "") print base_line
                  injected = 1
                }
              }
              /^[[:space:]]*\[/ { inject_root_keys(); in_table = 1 }
              !in_table && /^[[:space:]]*(model_provider|openai_base_url)[[:space:]]*=/ { next }
              { print }
              END { inject_root_keys() }
            ' "${'$'}CONFIG_SOURCE" > "${'$'}CONFIG_TMP"
            chmod 600 "${'$'}CONFIG_TMP"
            mv -f "${'$'}CONFIG_TMP" "${'$'}CONFIG_FILE"

            if [ -n "${'$'}PROXY_URL" ]; then
              {
                printf '%s\n' '# Managed by Codex Remote Android. Source before starting Codex.'
                printf '%s\n' $proxyComment
                printf '%s\n' $httpProxy
                printf '%s\n' $httpsProxy
                printf '%s\n' $allProxy
                printf '%s\n' $lowercaseHttpProxy
                printf '%s\n' $lowercaseHttpsProxy
                printf '%s\n' $lowercaseAllProxy
              } > "${'$'}ENV_TMP"
              chmod 600 "${'$'}ENV_TMP"
              mv -f "${'$'}ENV_TMP" "${'$'}ENV_FILE"
            else
              rm -f "${'$'}ENV_FILE"
            fi

            if [ -x "${'$'}WRAPPER" ] && ! grep -Fq '# codex-remote-global-env' "${'$'}WRAPPER"; then
              awk '
                NR == 1 {
                  print
                  print "# codex-remote-global-env"
                  print "if [ -r \"${'$'}{HOME}/.codex/codex-remote.env\" ]; then"
                  print "  . \"${'$'}{HOME}/.codex/codex-remote.env\""
                  print "fi"
                  next
                }
                { print }
              ' "${'$'}WRAPPER" > "${'$'}WRAPPER_TMP"
              chmod 700 "${'$'}WRAPPER_TMP"
              mv -f "${'$'}WRAPPER_TMP" "${'$'}WRAPPER"
            fi

            if [ -n "${'$'}API_KEY" ]; then
              if [ -x "${'$'}WRAPPER" ]; then
                CODEX_BIN="${'$'}WRAPPER"
              elif command -v codex >/dev/null 2>&1; then
                CODEX_BIN="${'$'}(command -v codex)"
              else
                printf '找不到 Codex CLI，无法写入 API 密钥\n' >&2
                exit 69
              fi
              printf '%s' "${'$'}API_KEY" | "${'$'}CODEX_BIN" login --with-api-key >/dev/null
            fi
            printf '${PREFIX}UPDATED=1\n'
        """.trimIndent()
    }

    internal fun validateBaseUrl(value: String): String {
        val baseUrl = value.trim().trimEnd('/')
        if (baseUrl.isEmpty()) return ""
        require(baseUrl.none { it.isWhitespace() || it.code !in 0x20..0x7e }) {
            "模型 URL 不能包含空格、换行或控制字符"
        }
        val uri = runCatching { URI(baseUrl) }.getOrElse { throw IllegalArgumentException("模型 URL 格式错误") }
        require(uri.scheme?.lowercase(Locale.ROOT) in setOf("http", "https") && !uri.host.isNullOrBlank()) {
            "模型 URL 必须是 http:// 或 https:// 地址"
        }
        return baseUrl
    }

    private fun validateApiKey(value: String): String {
        val apiKey = value.trim()
        require(apiKey.none { it.isWhitespace() || it.code !in 0x20..0x7e }) {
            "API 密钥不能包含空格、换行或控制字符"
        }
        return apiKey
    }

    private fun shellQuote(value: String): String = "'${value.replace("'", "'\\''")}'"
}
