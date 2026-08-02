package top.asdb.codexremote.ssh

import java.net.URI
import java.util.Locale
import top.asdb.codexremote.data.CodexConnectionTestResult
import top.asdb.codexremote.data.CodexGlobalSettings

/** Builds narrowly-scoped scripts for the user's global Codex configuration. */
internal object RemoteCodexSettings {
    private const val PREFIX = "__CODEX_GLOBAL_"
    private const val TEST_PREFIX = "__CODEX_CONNECTION_TEST_"
    private const val DEFAULT_OPENAI_BASE_URL = "https://api.openai.com/v1"

    val readScript: String = """
        set -eu
        CONFIG_DIR="${'$'}HOME/.codex"
        CONFIG_FILE="${'$'}CONFIG_DIR/config.toml"
        ENV_FILE="${'$'}CONFIG_DIR/codex-remote.env"
        AUTH_FILE="${'$'}CONFIG_DIR/auth.json"
        toml_root_value() {
          awk -v key="${'$'}1" '
            /^[[:space:]]*\[/ { in_table = 1 }
            !in_table {
              value = ${'$'}0
              sub(/^[[:space:]]*/, "", value)
              if (value ~ ("^" key "[[:space:]]*=")) {
                sub("^" key "[[:space:]]*=[[:space:]]*", "", value)
                sub(/[[:space:]]*#.*/, "", value)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                sub(/^"/, "", value)
                sub(/"$/, "", value)
                print value
                exit
              }
            }
          ' "${'$'}CONFIG_FILE"
        }
        toml_provider_base_url() {
          awk -v provider="${'$'}1" '
            /^[[:space:]]*\[/ {
              section = ${'$'}0
              sub(/^[[:space:]]*\[/, "", section)
              sub(/\][[:space:]]*(#.*)?$/, "", section)
              gsub(/^[[:space:]]+|[[:space:]]+$/, "", section)
              in_provider = (section == "model_providers." provider)
              next
            }
            in_provider {
              value = ${'$'}0
              sub(/^[[:space:]]*/, "", value)
              if (value ~ /^base_url[[:space:]]*=/) {
                sub(/^base_url[[:space:]]*=[[:space:]]*/, "", value)
                sub(/[[:space:]]*#.*/, "", value)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                sub(/^"/, "", value)
                sub(/"$/, "", value)
                print value
                exit
              }
            }
          ' "${'$'}CONFIG_FILE"
        }
        BASE_URL=
        MODEL=
        MODEL_PROVIDER=openai
        if [ -r "${'$'}CONFIG_FILE" ]; then
          MODEL="${'$'}(toml_root_value model)"
          MODEL_PROVIDER="${'$'}(toml_root_value model_provider)"
          if [ -z "${'$'}MODEL_PROVIDER" ]; then MODEL_PROVIDER=openai; fi
          BASE_URL="${'$'}(toml_root_value openai_base_url)"
          if [ "${'$'}MODEL_PROVIDER" != openai ]; then
            CUSTOM_BASE_URL="${'$'}(toml_provider_base_url "${'$'}MODEL_PROVIDER")"
            if [ -n "${'$'}CUSTOM_BASE_URL" ]; then BASE_URL="${'$'}CUSTOM_BASE_URL"; fi
          fi
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
        AUTH_API_KEY=
        if [ -r "${'$'}AUTH_FILE" ]; then
          AUTH_API_KEY="${'$'}(awk '
            index(${'$'}0, "OPENAI_API_KEY") {
              value = ${'$'}0
              sub(/^.*"OPENAI_API_KEY"[[:space:]]*:[[:space:]]*"/, "", value)
              sub(/".*${'$'}/, "", value)
              print value
              exit
            }
          ' "${'$'}AUTH_FILE")"
        fi
        if [ -s "${'$'}AUTH_FILE" ]; then AUTH_PRESENT=1; else AUTH_PRESENT=0; fi
        printf '${PREFIX}BASE_URL=%s\n' "${'$'}BASE_URL"
        printf '${PREFIX}MODEL=%s\n' "${'$'}MODEL"
        printf '${PREFIX}MODEL_PROVIDER=%s\n' "${'$'}MODEL_PROVIDER"
        printf '${PREFIX}PROXY_URL=%s\n' "${'$'}PROXY_URL"
        printf '${PREFIX}AUTH_PRESENT=%s\n' "${'$'}AUTH_PRESENT"
        printf '${PREFIX}API_KEY=%s\n' "${'$'}AUTH_API_KEY"
    """.trimIndent()

    fun parse(lines: List<String>): CodexGlobalSettings {
        val values = lines.mapNotNull { line ->
            if (!line.startsWith(PREFIX)) return@mapNotNull null
            line.removePrefix(PREFIX).split('=', limit = 2).takeIf { it.size == 2 }
                ?.let { it[0] to it[1] }
        }.toMap()
        return CodexGlobalSettings(
            baseUrl = values["BASE_URL"].orEmpty(),
            model = values["MODEL"].orEmpty(),
            modelProvider = values["MODEL_PROVIDER"].orEmpty().ifBlank { "openai" },
            hasStoredAuthentication = values["AUTH_PRESENT"] == "1",
            apiKey = values["API_KEY"].orEmpty(),
            proxyUrl = values["PROXY_URL"].orEmpty(),
        )
    }

    /**
     * Sends a minimal OpenAI Responses request to the selected model from the remote server. The
     * key is placed in a mode-0600 temporary header file so it is not exposed through process
     * arguments or script output.
     */
    fun testConnectionScript(
        baseUrl: String,
        apiKey: String,
        proxyUrl: String,
        testModel: String,
    ): String {
        val normalizedBaseUrl = validateBaseUrl(baseUrl).ifBlank { DEFAULT_OPENAI_BASE_URL }
        val normalizedApiKey = validateApiKey(apiKey)
        val normalizedProxy = RemoteBootstrap.validateProxyUrl(proxyUrl)
        val normalizedTestModel = normalizeTestModel(testModel)
        val endpoint = "${normalizedBaseUrl.trimEnd('/')}/responses"
        val requestBody = "{\"model\":\"$normalizedTestModel\",\"input\":\"ping\",\"max_output_tokens\":1}"
        return """
            set -u
            API_KEY=${shellQuote(normalizedApiKey)}
            PROXY_URL=${shellQuote(normalizedProxy)}
            TEST_MODEL=${shellQuote(normalizedTestModel)}
            ENDPOINT=${shellQuote(endpoint)}
            REQUEST_BODY=${shellQuote(requestBody)}
            unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY

            if [ -z "${'$'}API_KEY" ]; then
              printf '${TEST_PREFIX}STATUS=MISSING_API_KEY\n'
              exit 0
            fi
            if [ -z "${'$'}TEST_MODEL" ]; then
              printf '${TEST_PREFIX}STATUS=MISSING_TEST_MODEL\n'
              exit 0
            fi
            if ! command -v curl >/dev/null 2>&1; then
              printf '${TEST_PREFIX}STATUS=CURL_UNAVAILABLE\n'
              exit 0
            fi

            HEADER_FILE="${'$'}(mktemp "${'$'}{TMPDIR:-/tmp}/codex-api-header.XXXXXX" 2>/dev/null)" || {
              printf '${TEST_PREFIX}STATUS=TEMPORARY_FILE_ERROR\n'
              exit 0
            }
            BODY_FILE="${'$'}(mktemp "${'$'}{TMPDIR:-/tmp}/codex-api-body.XXXXXX" 2>/dev/null)" || {
              rm -f "${'$'}HEADER_FILE"
              printf '${TEST_PREFIX}STATUS=TEMPORARY_FILE_ERROR\n'
              exit 0
            }
            cleanup() { rm -f "${'$'}HEADER_FILE" "${'$'}BODY_FILE"; }
            trap cleanup EXIT HUP INT TERM
            if ! chmod 600 "${'$'}HEADER_FILE" "${'$'}BODY_FILE" 2>/dev/null ||
                ! printf 'Authorization: Bearer %s\n' "${'$'}API_KEY" > "${'$'}HEADER_FILE" ||
                ! printf '%s' "${'$'}REQUEST_BODY" > "${'$'}BODY_FILE"; then
              printf '${TEST_PREFIX}STATUS=TEMPORARY_FILE_ERROR\n'
              exit 0
            fi

            if [ -n "${'$'}PROXY_URL" ]; then
              HTTP_STATUS="${'$'}(curl --disable --silent --output /dev/null --write-out '%{http_code}' \
                --connect-timeout 10 --max-time 25 --proxy "${'$'}PROXY_URL" \
                --request POST --header "@${'$'}HEADER_FILE" --header 'Content-Type: application/json' \
                --data-binary "@${'$'}BODY_FILE" "${'$'}ENDPOINT" 2>/dev/null)"
            else
              HTTP_STATUS="${'$'}(curl --disable --silent --output /dev/null --write-out '%{http_code}' \
                --connect-timeout 10 --max-time 25 --request POST --header "@${'$'}HEADER_FILE" \
                --header 'Content-Type: application/json' --data-binary "@${'$'}BODY_FILE" \
                "${'$'}ENDPOINT" 2>/dev/null)"
            fi
            CURL_EXIT=${'$'}?
            if [ "${'$'}CURL_EXIT" -ne 0 ]; then
              printf '${TEST_PREFIX}STATUS=NETWORK_ERROR\n'
              exit 0
            fi

            case "${'$'}HTTP_STATUS" in
              2??) TEST_STATUS=SUCCESS ;;
              401|403) TEST_STATUS=UNAUTHORIZED ;;
              *) TEST_STATUS=HTTP_ERROR ;;
            esac
            printf '${TEST_PREFIX}STATUS=%s\n' "${'$'}TEST_STATUS"
            printf '${TEST_PREFIX}MODEL=%s\n' "${'$'}TEST_MODEL"
            printf '${TEST_PREFIX}HTTP_STATUS=%s\n' "${'$'}HTTP_STATUS"
        """.trimIndent()
    }

    fun parseConnectionTest(lines: List<String>): CodexConnectionTestResult {
        val values = lines.mapNotNull { line ->
            if (!line.startsWith(TEST_PREFIX)) return@mapNotNull null
            line.removePrefix(TEST_PREFIX).split('=', limit = 2).takeIf { it.size == 2 }
                ?.let { it[0] to it[1] }
        }.toMap()
        val httpStatus = values["HTTP_STATUS"]?.trim()?.takeIf { it.matches(Regex("\\d{3}")) }
        val model = values["MODEL"].orEmpty()
        return when (values["STATUS"]) {
            "SUCCESS" -> CodexConnectionTestResult(
                successful = true,
                message = "模型 ${model.ifBlank { "请求" }} 可用${httpStatus?.let { "（HTTP $it）" }.orEmpty()}",
            )

            "MISSING_API_KEY" -> CodexConnectionTestResult(false, "请输入 API 密钥后再测试")
            "MISSING_TEST_MODEL" -> CodexConnectionTestResult(false, "请输入测试模型后再测试")
            "CURL_UNAVAILABLE" -> CodexConnectionTestResult(false, "服务器未安装 curl，无法测试 API 连接")
            "TEMPORARY_FILE_ERROR" -> CodexConnectionTestResult(false, "无法安全准备 API 测试请求")
            "NETWORK_ERROR" -> CodexConnectionTestResult(false, "无法连接 API 服务，请检查模型 URL、代理或服务器网络")
            "UNAUTHORIZED" -> CodexConnectionTestResult(
                false,
                "API 密钥无效或没有权限${httpStatus?.let { "（HTTP $it）" }.orEmpty()}",
            )

            "HTTP_ERROR" -> CodexConnectionTestResult(
                false,
                "API 服务返回异常${httpStatus?.let { "（HTTP $it）" }.orEmpty()}",
            )

            else -> throw IllegalStateException("API 测试未返回可识别的结果")
        }
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

    internal fun normalizeTestModel(value: String): String {
        val model = value.trim()
        if (model.isEmpty()) return ""
        require(model.length <= 200 && model.matches(Regex("[A-Za-z0-9._:/@+-]+"))) {
            "测试模型只能包含字母、数字及 . _ - / : @ +"
        }
        return model
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
