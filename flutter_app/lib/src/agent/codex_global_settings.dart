import 'dart:convert';
import 'dart:typed_data';

import '../domain/models.dart';

const _settingsPrefix = '__CODEX_GLOBAL_';
const _testPrefix = '__CODEX_CONNECTION_TEST_';
const _modelListPrefix = '__CODEX_API_MODEL_LIST_';
const _defaultOpenAiBaseUrl = 'https://api.openai.com/v1';
const _maxModelListResponseBytes = 256 * 1024;
const _modelListChunkWidth = 4096;

const codexWebSocketPolicyAuto = 'auto';
const codexWebSocketPolicyEnabled = 'enabled';
const codexWebSocketPolicyDisabled = 'disabled';

/// Reads the same per-user files shared by Codex CLI and the IDE extension.
const readCodexGlobalSettingsScript = r'''
set -eu
CONFIG_DIR="$HOME/.codex"
CONFIG_FILE="$CONFIG_DIR/config.toml"
ENV_FILE="$CONFIG_DIR/codex-remote.env"
AUTH_FILE="$CONFIG_DIR/auth.json"
toml_root_value() {
  awk -v key="$1" '
    /^[[:space:]]*\[/ { in_table = 1 }
    !in_table {
      value = $0
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
  ' "$CONFIG_FILE"
}
toml_provider_base_url() {
  awk -v provider="$1" '
    /^[[:space:]]*\[/ {
      section = $0
      sub(/^[[:space:]]*\[/, "", section)
      sub(/\][[:space:]]*(#.*)?$/, "", section)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", section)
      in_provider = (section == "model_providers." provider)
      next
    }
    in_provider {
      value = $0
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
  ' "$CONFIG_FILE"
}
toml_provider_websocket_policy() {
  awk -v provider="$1" '
    /^[[:space:]]*\[/ {
      section = $0
      sub(/^[[:space:]]*\[/, "", section)
      sub(/\][[:space:]]*(#.*)?$/, "", section)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", section)
      in_provider = (section == "model_providers." provider)
      next
    }
    in_provider {
      value = $0
      sub(/^[[:space:]]*/, "", value)
      if (value ~ /^supports_websockets[[:space:]]*=/) {
        sub(/^supports_websockets[[:space:]]*=[[:space:]]*/, "", value)
        sub(/[[:space:]]*#.*/, "", value)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        if (value == "true") print "enabled"
        if (value == "false") print "disabled"
        exit
      }
    }
  ' "$CONFIG_FILE"
}
BASE_URL=
MODEL=
MODEL_REASONING_EFFORT=
MODEL_PROVIDER=openai
WEBSOCKET_POLICY=
if [ -r "$CONFIG_FILE" ]; then
  MODEL="$(toml_root_value model)"
  MODEL_REASONING_EFFORT="$(toml_root_value model_reasoning_effort)"
  MODEL_PROVIDER="$(toml_root_value model_provider)"
  if [ -z "$MODEL_PROVIDER" ]; then MODEL_PROVIDER=openai; fi
  BASE_URL="$(toml_root_value openai_base_url)"
  if [ "$MODEL_PROVIDER" != openai ]; then
    CUSTOM_BASE_URL="$(toml_provider_base_url "$MODEL_PROVIDER")"
    if [ -n "$CUSTOM_BASE_URL" ]; then BASE_URL="$CUSTOM_BASE_URL"; fi
    WEBSOCKET_POLICY="$(toml_provider_websocket_policy "$MODEL_PROVIDER")"
  fi
fi
PROXY_URL=
if [ -r "$ENV_FILE" ]; then
  PROXY_URL="$(awk '
    /^# codex-remote-proxy: / {
      sub(/^# codex-remote-proxy: /, "")
      print
      exit
    }
  ' "$ENV_FILE")"
fi
AUTH_API_KEY=
if [ -r "$AUTH_FILE" ]; then
  AUTH_API_KEY="$(awk '
    index($0, "OPENAI_API_KEY") {
      value = $0
      sub(/^.*"OPENAI_API_KEY"[[:space:]]*:[[:space:]]*"/, "", value)
      sub(/".*$/, "", value)
      print value
      exit
    }
  ' "$AUTH_FILE")"
fi
if [ -s "$AUTH_FILE" ]; then AUTH_PRESENT=1; else AUTH_PRESENT=0; fi
printf '__CODEX_GLOBAL_BASE_URL=%s\n' "$BASE_URL"
printf '__CODEX_GLOBAL_MODEL=%s\n' "$MODEL"
printf '__CODEX_GLOBAL_MODEL_REASONING_EFFORT=%s\n' "$MODEL_REASONING_EFFORT"
printf '__CODEX_GLOBAL_MODEL_PROVIDER=%s\n' "$MODEL_PROVIDER"
printf '__CODEX_GLOBAL_WEBSOCKET_POLICY=%s\n' "$WEBSOCKET_POLICY"
printf '__CODEX_GLOBAL_PROXY_URL=%s\n' "$PROXY_URL"
printf '__CODEX_GLOBAL_AUTH_PRESENT=%s\n' "$AUTH_PRESENT"
printf '__CODEX_GLOBAL_API_KEY=%s\n' "$AUTH_API_KEY"
''';

AgentGlobalSettings parseCodexGlobalSettings(String output) {
  final values = _prefixedValues(output, _settingsPrefix);
  return AgentGlobalSettings(
    baseUrl: values['BASE_URL'] ?? '',
    model: values['MODEL'] ?? '',
    reasoningEffort: values['MODEL_REASONING_EFFORT'] ?? '',
    modelProvider: _nonEmpty(values['MODEL_PROVIDER']) ?? 'openai',
    websocketPolicy: _nonEmpty(values['WEBSOCKET_POLICY']),
    hasStoredAuthentication: values['AUTH_PRESENT'] == '1',
    apiKey: values['API_KEY'] ?? '',
    proxyUrl: values['PROXY_URL'] ?? '',
  );
}

String updateCodexProviderBaseUrl(String configText, String baseUrl) {
  final normalizedBaseUrl = normalizeCodexBaseUrl(baseUrl);
  final configuredProvider = _codexTomlStringValue(
    configText,
    table: null,
    key: 'model_provider',
  );
  final provider = configuredProvider?.trim().isNotEmpty == true
      ? configuredProvider!.trim()
      : 'openai';
  return _replaceCodexTomlStringValue(
    configText,
    table: provider == 'openai' ? null : 'model_providers.$provider',
    key: provider == 'openai' ? 'openai_base_url' : 'base_url',
    value: normalizedBaseUrl.isEmpty ? null : normalizedBaseUrl,
  );
}

String updateCodexProviderWebSocketPolicy(
  String configText,
  String? websocketPolicy,
) {
  final configuredProvider = _codexTomlStringValue(
    configText,
    table: null,
    key: 'model_provider',
  );
  final provider = configuredProvider?.trim().isNotEmpty == true
      ? configuredProvider!.trim()
      : 'openai';
  if (provider == 'openai') return configText;
  final normalizedPolicy = normalizeCodexWebSocketPolicy(websocketPolicy);
  return _replaceCodexTomlBooleanValue(
    configText,
    table: 'model_providers.$provider',
    key: 'supports_websockets',
    value: normalizedPolicy,
  );
}

/// Fetches an OpenAI-compatible `/models` response from the remote server.
/// The API key is kept in a mode-0600 header file and is never printed.
String buildFetchCodexApiModelsScript({
  required String baseUrl,
  required String apiKey,
  required String proxyUrl,
}) {
  final configuredBaseUrl = normalizeCodexBaseUrl(baseUrl);
  final normalizedBaseUrl = configuredBaseUrl.isEmpty
      ? _defaultOpenAiBaseUrl
      : configuredBaseUrl;
  final normalizedApiKey = normalizeCodexApiKey(apiKey);
  final normalizedProxy = normalizeCodexProxyUrl(proxyUrl);
  final endpoint =
      '${normalizedBaseUrl.replaceFirst(RegExp(r'/+$'), '')}/models';

  return _renderShellTemplate(
    r'''
set -u
API_KEY=@@API_KEY@@
PROXY_URL=@@PROXY_URL@@
MODELS_ENDPOINT=@@MODELS_ENDPOINT@@
MAX_BODY_BYTES=@@MAX_BODY_BYTES@@
CHUNK_WIDTH=@@CHUNK_WIDTH@@
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY

if [ -z "$API_KEY" ]; then
  printf '__CODEX_API_MODEL_LIST_STATUS=MISSING_API_KEY\n'
  exit 0
fi
if ! command -v curl >/dev/null 2>&1; then
  printf '__CODEX_API_MODEL_LIST_STATUS=CURL_UNAVAILABLE\n'
  exit 0
fi
if ! command -v base64 >/dev/null 2>&1 || ! command -v fold >/dev/null 2>&1; then
  printf '__CODEX_API_MODEL_LIST_STATUS=ENCODER_UNAVAILABLE\n'
  exit 0
fi

HEADER_FILE="$(mktemp "${TMPDIR:-/tmp}/codex-api-header.XXXXXX" 2>/dev/null)" || {
  printf '__CODEX_API_MODEL_LIST_STATUS=TEMPORARY_FILE_ERROR\n'
  exit 0
}
BODY_FILE="$(mktemp "${TMPDIR:-/tmp}/codex-api-models-body.XXXXXX" 2>/dev/null)" || {
  rm -f "$HEADER_FILE"
  printf '__CODEX_API_MODEL_LIST_STATUS=TEMPORARY_FILE_ERROR\n'
  exit 0
}
cleanup() { rm -f "$HEADER_FILE" "$BODY_FILE"; }
trap cleanup EXIT HUP INT TERM
if ! chmod 600 "$HEADER_FILE" "$BODY_FILE" 2>/dev/null ||
   ! printf 'Authorization: Bearer %s\n' "$API_KEY" > "$HEADER_FILE"; then
  printf '__CODEX_API_MODEL_LIST_STATUS=TEMPORARY_FILE_ERROR\n'
  exit 0
fi

fetch_models() {
  if [ -n "$PROXY_URL" ]; then
    curl --disable --silent --output "$BODY_FILE" --write-out '%{http_code}' \
      --connect-timeout 10 --max-time 15 --proxy "$PROXY_URL" --request GET \
      --header "@$HEADER_FILE" "$MODELS_ENDPOINT" 2>/dev/null
  else
    curl --disable --silent --output "$BODY_FILE" --write-out '%{http_code}' \
      --connect-timeout 10 --max-time 15 --request GET \
      --header "@$HEADER_FILE" "$MODELS_ENDPOINT" 2>/dev/null
  fi
}

HTTP_STATUS=
CURL_EXIT=1
ATTEMPT=1
while [ "$ATTEMPT" -le 2 ]; do
  HTTP_STATUS="$(fetch_models)"
  CURL_EXIT=$?
  if [ "$CURL_EXIT" -eq 0 ]; then break; fi
  if [ "$ATTEMPT" -lt 2 ]; then sleep 1; fi
  ATTEMPT=$((ATTEMPT + 1))
done
if [ "$CURL_EXIT" -ne 0 ]; then
  printf '__CODEX_API_MODEL_LIST_STATUS=NETWORK_ERROR\n'
  printf '__CODEX_API_MODEL_LIST_CURL_EXIT=%s\n' "$CURL_EXIT"
  exit 0
fi
case "$HTTP_STATUS" in
  2??) ;;
  401|403)
    printf '__CODEX_API_MODEL_LIST_STATUS=UNAUTHORIZED\n'
    printf '__CODEX_API_MODEL_LIST_HTTP_STATUS=%s\n' "$HTTP_STATUS"
    exit 0
    ;;
  *)
    printf '__CODEX_API_MODEL_LIST_STATUS=HTTP_ERROR\n'
    printf '__CODEX_API_MODEL_LIST_HTTP_STATUS=%s\n' "$HTTP_STATUS"
    exit 0
    ;;
esac
BODY_SIZE="$(wc -c < "$BODY_FILE" | tr -d '[:space:]')"
if [ "$BODY_SIZE" -gt "$MAX_BODY_BYTES" ]; then
  printf '__CODEX_API_MODEL_LIST_STATUS=BODY_TOO_LARGE\n'
  exit 0
fi

printf '__CODEX_API_MODEL_LIST_STATUS=SUCCESS\n'
printf '__CODEX_API_MODEL_LIST_HTTP_STATUS=%s\n' "$HTTP_STATUS"
base64 "$BODY_FILE" | tr -d '\n' | fold -w "$CHUNK_WIDTH" | while IFS= read -r CHUNK || [ -n "$CHUNK" ]; do
  printf '__CODEX_API_MODEL_LIST_DATA=%s\n' "$CHUNK"
done
''',
    {
      'API_KEY': _shellQuote(normalizedApiKey),
      'PROXY_URL': _shellQuote(normalizedProxy),
      'MODELS_ENDPOINT': _shellQuote(endpoint),
      'MAX_BODY_BYTES': '$_maxModelListResponseBytes',
      'CHUNK_WIDTH': '$_modelListChunkWidth',
    },
  );
}

List<ApiModelOption> parseCodexApiModels(String output) {
  final values = <MapEntry<String, String>>[];
  for (final line in output.split(RegExp(r'\r?\n'))) {
    if (!line.startsWith(_modelListPrefix)) continue;
    final value = line.substring(_modelListPrefix.length);
    final separator = value.indexOf('=');
    if (separator <= 0) continue;
    values.add(
      MapEntry(value.substring(0, separator), value.substring(separator + 1)),
    );
  }
  String? first(String key) {
    for (final entry in values) {
      if (entry.key == key) return entry.value;
    }
    return null;
  }

  final status = first('STATUS');
  final httpStatus = first('HTTP_STATUS')?.trim();
  final curlExit = first('CURL_EXIT')?.trim();
  switch (status) {
    case 'SUCCESS':
      break;
    case 'MISSING_API_KEY':
      throw StateError('请先在模型配置中保存 API 密钥');
    case 'CURL_UNAVAILABLE':
      throw StateError('服务器未安装 curl，无法获取模型列表');
    case 'ENCODER_UNAVAILABLE':
      throw StateError('服务器缺少 base64 或 fold，无法读取模型列表');
    case 'TEMPORARY_FILE_ERROR':
      throw StateError('无法安全准备模型列表请求');
    case 'NETWORK_ERROR':
      throw StateError(
        '无法连接模型 API，请检查模型 URL、代理或服务器网络'
        '${curlExit?.isNotEmpty == true ? '（curl exit $curlExit）' : ''}',
      );
    case 'UNAUTHORIZED':
      throw StateError(
        'API 密钥无效或没有权限'
        '${httpStatus?.isNotEmpty == true ? '（HTTP $httpStatus）' : ''}',
      );
    case 'HTTP_ERROR':
      throw StateError(
        '模型 API 返回异常'
        '${httpStatus?.isNotEmpty == true ? '（HTTP $httpStatus）' : ''}',
      );
    case 'BODY_TOO_LARGE':
      throw StateError('模型列表响应过大，无法安全加载');
    default:
      throw StateError('模型列表请求未返回可识别的结果');
  }

  final encoded = values
      .where((entry) => entry.key == 'DATA')
      .map((entry) => entry.value)
      .join();
  if (encoded.isEmpty) throw StateError('模型 API 没有返回模型列表');

  Uint8List decoded;
  try {
    decoded = base64.decode(encoded);
  } on FormatException {
    throw StateError('模型列表数据无法解析');
  }
  return parseCodexApiModelsJson(decoded);
}

/// Parses the OpenAI-compatible model response shared by SSH curl and native
/// desktop HTTP clients.
List<ApiModelOption> parseCodexApiModelsJson(List<int> bytes) {
  Object? root;
  try {
    root = jsonDecode(utf8.decode(bytes));
  } on FormatException {
    throw StateError('模型列表数据无法解析');
  }
  final entries = switch (root) {
    {'data': final List<Object?> data} => data,
    final List<Object?> data => data,
    _ => throw StateError('模型 API 响应中没有 data 列表'),
  };
  final options = <ApiModelOption>[];
  final seen = <String>{};
  for (final item in entries) {
    if (item is! Map) continue;
    final value = item.cast<Object?, Object?>();
    final modelId = _firstJsonString(value, const ['id', 'model', 'name']);
    if (modelId.isEmpty || !seen.add(modelId)) continue;
    final provider = value['top_provider'];
    final providerMap = provider is Map
        ? provider.cast<Object?, Object?>()
        : const <Object?, Object?>{};
    final directOutput = _firstJsonInt(value, const [
      'max_output_tokens',
      'maxOutputTokens',
      'max_completion_tokens',
      'maxCompletionTokens',
      'max_tokens',
    ]);
    options.add(
      ApiModelOption(
        modelId: modelId,
        displayName: _firstJsonString(value, const [
          'display_name',
          'displayName',
          'name',
        ]),
        contextWindowTokens: _firstJsonInt(value, const [
          'context_length',
          'contextLength',
          'context_window',
          'contextWindow',
        ]),
        maxOutputTokens: directOutput > 0
            ? directOutput
            : _firstJsonInt(providerMap, const [
                'max_completion_tokens',
                'maxCompletionTokens',
              ]),
      ),
    );
  }
  options.sort(
    (left, right) =>
        left.modelId.toLowerCase().compareTo(right.modelId.toLowerCase()),
  );
  return List<ApiModelOption>.unmodifiable(options);
}

String buildWriteCodexGlobalSettingsScript({
  required String baseUrl,
  required String apiKey,
  required String proxyUrl,
  required String defaultModel,
  required String defaultReasoningEffort,
  String? websocketPolicy,
}) {
  final normalizedBaseUrl = normalizeCodexBaseUrl(baseUrl);
  final normalizedApiKey = normalizeCodexApiKey(apiKey);
  final normalizedProxy = normalizeCodexProxyUrl(proxyUrl);
  final normalizedModel = normalizeCodexModel(defaultModel, '默认模型');
  final normalizedEffort = normalizeCodexReasoningEffort(
    defaultReasoningEffort,
  );
  final normalizedWebSocketPolicy = normalizeCodexWebSocketPolicy(
    websocketPolicy,
  );
  final modelLine = normalizedModel.isEmpty ? '' : 'model = "$normalizedModel"';
  final effortLine = normalizedEffort.isEmpty
      ? ''
      : 'model_reasoning_effort = "$normalizedEffort"';

  return _renderShellTemplate(
    r'''
set -eu
CONFIG_DIR="$HOME/.codex"
CONFIG_FILE="$CONFIG_DIR/config.toml"
ENV_FILE="$CONFIG_DIR/codex-remote.env"
WRAPPER="$HOME/.local/bin/codex-remote"
API_KEY=@@API_KEY@@
PROXY_URL=@@PROXY_URL@@
BASE_URL=@@BASE_URL@@
DEFAULT_MODEL_LINE=@@MODEL_LINE@@
DEFAULT_REASONING_EFFORT_LINE=@@EFFORT_LINE@@
WEBSOCKET_POLICY=@@WEBSOCKET_POLICY@@
umask 077
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

CONFIG_TMP="$CONFIG_FILE.tmp.$$"
ENV_TMP="$ENV_FILE.tmp.$$"
WRAPPER_TMP="$WRAPPER.tmp.$$"
cleanup() { rm -f "$CONFIG_TMP" "$ENV_TMP" "$WRAPPER_TMP"; }
trap cleanup EXIT HUP INT TERM

if [ -f "$CONFIG_FILE" ]; then CONFIG_SOURCE="$CONFIG_FILE"; else CONFIG_SOURCE=/dev/null; fi
CURRENT_PROVIDER="$(awk '
  /^[[:space:]]*\[/ { exit }
  {
    value = $0
    sub(/^[[:space:]]*/, "", value)
    if (value ~ /^model_provider[[:space:]]*=/) {
      sub(/^model_provider[[:space:]]*=[[:space:]]*/, "", value)
      sub(/[[:space:]]*#.*/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      sub(/^"/, "", value)
      sub(/"$/, "", value)
      print value
      exit
    }
  }
' "$CONFIG_SOURCE")"
if [ -z "$CURRENT_PROVIDER" ]; then CURRENT_PROVIDER=openai; fi

awk -v base_url="$BASE_URL" -v current_provider="$CURRENT_PROVIDER" \
    -v websocket_policy="$WEBSOCKET_POLICY" \
    -v default_model_line="$DEFAULT_MODEL_LINE" \
    -v default_reasoning_effort_line="$DEFAULT_REASONING_EFFORT_LINE" \
    '
  function inject_root_keys() {
    if (!root_injected) {
      if (current_provider == "openai" && base_url != "") {
        print "openai_base_url = \"" base_url "\""
      }
      if (default_model_line != "") print default_model_line
      if (default_reasoning_effort_line != "") print default_reasoning_effort_line
      root_injected = 1
    }
  }
  function inject_provider_base_url() {
    if (in_target_provider && !provider_base_injected) {
      if (base_url != "") print "base_url = \"" base_url "\""
      provider_base_injected = 1
    }
  }
  function inject_provider_websocket_policy() {
    if (in_target_provider && !provider_websocket_injected && websocket_policy != "") {
      print "supports_websockets = " websocket_policy
      provider_websocket_injected = 1
    }
  }
  /^[[:space:]]*\[/ {
    inject_root_keys()
    inject_provider_base_url()
    inject_provider_websocket_policy()
    section = $0
    sub(/^[[:space:]]*\[/, "", section)
    sub(/\][[:space:]]*(#.*)?$/, "", section)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", section)
    in_table = 1
    in_target_provider = \
      (current_provider != "openai" && section == "model_providers." current_provider)
    if (in_target_provider) {
      target_provider_seen = 1
      provider_base_injected = 0
      provider_websocket_injected = 0
    }
    print
    next
  }
  !in_table && current_provider == "openai" && \
    /^[[:space:]]*openai_base_url[[:space:]]*=/ { next }
  !in_table && /^[[:space:]]*model[[:space:]]*=/ { next }
  !in_table && /^[[:space:]]*model_reasoning_effort[[:space:]]*=/ { next }
  in_target_provider && /^[[:space:]]*base_url[[:space:]]*=/ {
    if (base_url != "") print "base_url = \"" base_url "\""
    provider_base_injected = 1
    next
  }
  in_target_provider && /^[[:space:]]*supports_websockets[[:space:]]*=/ {
    if (websocket_policy != "") print "supports_websockets = " websocket_policy
    provider_websocket_injected = 1
    next
  }
  { print }
  END {
    inject_root_keys()
    inject_provider_base_url()
    inject_provider_websocket_policy()
    if (current_provider != "openai" && !target_provider_seen && \
        (base_url != "" || websocket_policy != "")) {
      if (NR > 0) print ""
      print "[model_providers." current_provider "]"
      if (base_url != "") print "base_url = \"" base_url "\""
      if (websocket_policy != "") print "supports_websockets = " websocket_policy
    }
  }
' "$CONFIG_SOURCE" > "$CONFIG_TMP"
chmod 600 "$CONFIG_TMP"
mv -f "$CONFIG_TMP" "$CONFIG_FILE"

if [ -n "$PROXY_URL" ]; then
  {
    printf '%s\n' '# Managed by Codex Remote Android. Source before starting Codex.'
    printf '# codex-remote-proxy: %s\n' "$PROXY_URL"
    printf 'export HTTP_PROXY=%s\n' "$PROXY_URL"
    printf 'export HTTPS_PROXY=%s\n' "$PROXY_URL"
    printf 'export ALL_PROXY=%s\n' "$PROXY_URL"
    printf 'export http_proxy=%s\n' "$PROXY_URL"
    printf 'export https_proxy=%s\n' "$PROXY_URL"
    printf 'export all_proxy=%s\n' "$PROXY_URL"
  } > "$ENV_TMP"
  chmod 600 "$ENV_TMP"
  mv -f "$ENV_TMP" "$ENV_FILE"
else
  rm -f "$ENV_FILE"
fi

if [ -x "$WRAPPER" ] && ! grep -Fq '# codex-remote-global-env' "$WRAPPER"; then
  awk '
    NR == 1 {
      print
      print "# codex-remote-global-env"
      print "if [ -r \"${HOME}/.codex/codex-remote.env\" ]; then"
      print "  . \"${HOME}/.codex/codex-remote.env\""
      print "fi"
      next
    }
    { print }
  ' "$WRAPPER" > "$WRAPPER_TMP"
  chmod 700 "$WRAPPER_TMP"
  mv -f "$WRAPPER_TMP" "$WRAPPER"
fi

if [ -n "$API_KEY" ]; then
  if [ -x "$WRAPPER" ]; then
    CODEX_BIN="$WRAPPER"
  elif command -v codex >/dev/null 2>&1; then
    CODEX_BIN="$(command -v codex)"
  else
    printf '找不到 Codex CLI，无法写入 API 密钥\n' >&2
    exit 69
  fi
  printf '%s' "$API_KEY" | "$CODEX_BIN" login --with-api-key >/dev/null 2>&1
fi
printf '__CODEX_GLOBAL_UPDATED=1\n'
''',
    {
      'API_KEY': _shellQuote(normalizedApiKey),
      'PROXY_URL': _shellQuote(normalizedProxy),
      'BASE_URL': _shellQuote(normalizedBaseUrl),
      'MODEL_LINE': _shellQuote(modelLine),
      'EFFORT_LINE': _shellQuote(effortLine),
      'WEBSOCKET_POLICY': _shellQuote(normalizedWebSocketPolicy ?? ''),
    },
  );
}

String buildTestCodexGlobalSettingsScript({
  required String baseUrl,
  required String apiKey,
  required String proxyUrl,
  required String testModel,
  ModelApiProtocol? apiProtocol,
}) {
  final configuredBaseUrl = normalizeCodexBaseUrl(baseUrl);
  final normalizedBaseUrl = configuredBaseUrl.isEmpty
      ? _defaultOpenAiBaseUrl
      : configuredBaseUrl;
  final normalizedApiKey = normalizeCodexApiKey(apiKey);
  final normalizedProxy = normalizeCodexProxyUrl(proxyUrl);
  final normalizedModel = normalizeCodexModel(testModel, '测试模型');
  final baseEndpoint = normalizedBaseUrl.replaceFirst(RegExp(r'/+$'), '');
  final responsesBody = '{"model":"$normalizedModel","input":"ping"}';
  final chatBody =
      '{"model":"$normalizedModel","messages":[{"role":"user","content":"ping"}]}';
  final apiMode = switch (apiProtocol) {
    ModelApiProtocol.responses => 'responses',
    ModelApiProtocol.chatCompletions => 'chat/completions',
    null => 'auto',
  };

  return _renderShellTemplate(
    r'''
set -u
API_KEY=@@API_KEY@@
PROXY_URL=@@PROXY_URL@@
TEST_MODEL=@@TEST_MODEL@@
TEST_API_MODE=@@TEST_API_MODE@@
RESPONSES_ENDPOINT=@@RESPONSES_ENDPOINT@@
CHAT_ENDPOINT=@@CHAT_ENDPOINT@@
RESPONSES_BODY=@@RESPONSES_BODY@@
CHAT_BODY=@@CHAT_BODY@@
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY

if [ -z "$API_KEY" ]; then
  printf '__CODEX_CONNECTION_TEST_STATUS=MISSING_API_KEY\n'
  exit 0
fi
if [ -z "$TEST_MODEL" ]; then
  printf '__CODEX_CONNECTION_TEST_STATUS=MISSING_TEST_MODEL\n'
  exit 0
fi
if ! command -v curl >/dev/null 2>&1; then
  printf '__CODEX_CONNECTION_TEST_STATUS=CURL_UNAVAILABLE\n'
  exit 0
fi

HEADER_FILE="$(mktemp "${TMPDIR:-/tmp}/codex-api-header.XXXXXX" 2>/dev/null)" || {
  printf '__CODEX_CONNECTION_TEST_STATUS=TEMPORARY_FILE_ERROR\n'
  exit 0
}
RESPONSES_FILE="$(mktemp "${TMPDIR:-/tmp}/codex-api-responses.XXXXXX" 2>/dev/null)" || {
  rm -f "$HEADER_FILE"
  printf '__CODEX_CONNECTION_TEST_STATUS=TEMPORARY_FILE_ERROR\n'
  exit 0
}
CHAT_FILE="$(mktemp "${TMPDIR:-/tmp}/codex-api-chat.XXXXXX" 2>/dev/null)" || {
  rm -f "$HEADER_FILE" "$RESPONSES_FILE"
  printf '__CODEX_CONNECTION_TEST_STATUS=TEMPORARY_FILE_ERROR\n'
  exit 0
}
cleanup() { rm -f "$HEADER_FILE" "$RESPONSES_FILE" "$CHAT_FILE"; }
trap cleanup EXIT HUP INT TERM
if ! chmod 600 "$HEADER_FILE" "$RESPONSES_FILE" "$CHAT_FILE" 2>/dev/null ||
   ! printf 'Authorization: Bearer %s\n' "$API_KEY" > "$HEADER_FILE" ||
   ! printf '%s' "$RESPONSES_BODY" > "$RESPONSES_FILE" ||
   ! printf '%s' "$CHAT_BODY" > "$CHAT_FILE"; then
  printf '__CODEX_CONNECTION_TEST_STATUS=TEMPORARY_FILE_ERROR\n'
  exit 0
fi

run_request() {
  endpoint="$1"
  body_file="$2"
  if [ -n "$PROXY_URL" ]; then
    curl --disable --silent --output /dev/null --write-out '%{http_code}' \
      --connect-timeout 10 --max-time 25 --proxy "$PROXY_URL" --request POST \
      --header "@$HEADER_FILE" --header 'Content-Type: application/json' \
      --data-binary "@$body_file" "$endpoint" 2>/dev/null
  else
    curl --disable --silent --output /dev/null --write-out '%{http_code}' \
      --connect-timeout 10 --max-time 25 --request POST --header "@$HEADER_FILE" \
      --header 'Content-Type: application/json' --data-binary "@$body_file" \
      "$endpoint" 2>/dev/null
  fi
}

if [ "$TEST_API_MODE" = 'chat/completions' ]; then
  TEST_API=chat/completions
  HTTP_STATUS="$(run_request "$CHAT_ENDPOINT" "$CHAT_FILE")"
else
  TEST_API=responses
  HTTP_STATUS="$(run_request "$RESPONSES_ENDPOINT" "$RESPONSES_FILE")"
fi
CURL_EXIT=$?
CURL_EXIT_CODE=$CURL_EXIT
if [ "$CURL_EXIT" -ne 0 ]; then
  TEST_STATUS=NETWORK_ERROR
else
  case "$HTTP_STATUS" in
    2??) TEST_STATUS=SUCCESS ;;
    401|403) TEST_STATUS=UNAUTHORIZED ;;
    *) if [ "$TEST_API_MODE" = 'auto' ]; then
      HTTP_STATUS="$(run_request "$CHAT_ENDPOINT" "$CHAT_FILE")"
      CURL_EXIT=$?
      CURL_EXIT_CODE=$CURL_EXIT
      TEST_API=chat/completions
      if [ "$CURL_EXIT" -ne 0 ]; then
        TEST_STATUS=NETWORK_ERROR
      else
        case "$HTTP_STATUS" in
          2??) TEST_STATUS=SUCCESS ;;
          401|403) TEST_STATUS=UNAUTHORIZED ;;
          *) TEST_STATUS=HTTP_ERROR ;;
        esac
      fi
      else
        TEST_STATUS=HTTP_ERROR
      fi
      ;;
  esac
fi
printf '__CODEX_CONNECTION_TEST_STATUS=%s\n' "$TEST_STATUS"
printf '__CODEX_CONNECTION_TEST_MODEL=%s\n' "$TEST_MODEL"
printf '__CODEX_CONNECTION_TEST_API=%s\n' "$TEST_API"
printf '__CODEX_CONNECTION_TEST_HTTP_STATUS=%s\n' "$HTTP_STATUS"
printf '__CODEX_CONNECTION_TEST_CURL_EXIT=%s\n' "$CURL_EXIT_CODE"
''',
    {
      'API_KEY': _shellQuote(normalizedApiKey),
      'PROXY_URL': _shellQuote(normalizedProxy),
      'TEST_MODEL': _shellQuote(normalizedModel),
      'TEST_API_MODE': _shellQuote(apiMode),
      'RESPONSES_ENDPOINT': _shellQuote('$baseEndpoint/responses'),
      'CHAT_ENDPOINT': _shellQuote('$baseEndpoint/chat/completions'),
      'RESPONSES_BODY': _shellQuote(responsesBody),
      'CHAT_BODY': _shellQuote(chatBody),
    },
  );
}

AgentConnectionTestResult parseCodexConnectionTest(String output) {
  final values = _prefixedValues(output, _testPrefix);
  final statusCode = values['HTTP_STATUS'];
  final httpStatus =
      statusCode != null && RegExp(r'^\d{3}$').hasMatch(statusCode)
      ? statusCode
      : null;
  final model = _nonEmpty(values['MODEL']) ?? '请求';
  final api = switch (values['API']) {
    'responses' => 'Responses',
    'chat/completions' => 'Chat Completions',
    _ => '',
  };
  final networkError = switch (values['CURL_EXIT']) {
    '6' => '无法解析 API 域名，请检查本机 Linux 的 DNS',
    '7' => '无法连接 API 服务端口，请检查地址、代理或网络',
    '28' => '连接 API 服务超时，请检查网络或代理',
    '35' || '60' => 'API 服务 TLS 证书或握手失败',
    _ => '无法连接 API 服务，请检查模型 URL、代理或服务器网络',
  };
  return switch (values['STATUS']) {
    'SUCCESS' => AgentConnectionTestResult(
      successful: true,
      message:
          '模型 $model 可用${api.isEmpty ? '' : '（$api）'}${httpStatus == null ? '' : '（HTTP $httpStatus）'}',
    ),
    'MISSING_API_KEY' => const AgentConnectionTestResult(
      successful: false,
      message: '请输入 API 密钥后再测试',
    ),
    'MISSING_TEST_MODEL' => const AgentConnectionTestResult(
      successful: false,
      message: '请输入测试模型后再测试',
    ),
    'CURL_UNAVAILABLE' => const AgentConnectionTestResult(
      successful: false,
      message: '服务器未安装 curl，无法测试 API 连接',
    ),
    'TEMPORARY_FILE_ERROR' => const AgentConnectionTestResult(
      successful: false,
      message: '无法安全准备 API 测试请求',
    ),
    'NETWORK_ERROR' => AgentConnectionTestResult(
      successful: false,
      message: networkError,
    ),
    'UNAUTHORIZED' => AgentConnectionTestResult(
      successful: false,
      message: 'API 密钥无效或没有权限${httpStatus == null ? '' : '（HTTP $httpStatus）'}',
    ),
    'HTTP_ERROR' => AgentConnectionTestResult(
      successful: false,
      message: 'API 服务返回异常${httpStatus == null ? '' : '（HTTP $httpStatus）'}',
    ),
    _ => throw StateError('API 测试未返回可识别的结果'),
  };
}

String normalizeCodexBaseUrl(String value) {
  final result = value.trim().replaceFirst(RegExp(r'/+$'), '');
  if (result.isEmpty) return '';
  _requireVisibleWithoutWhitespace(result, '模型 URL');
  final uri = Uri.tryParse(result);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    throw ArgumentError('模型 URL 必须是 http:// 或 https:// 地址');
  }
  return result;
}

String normalizeCodexProxyUrl(String value) {
  final result = value.trim().replaceFirst(RegExp(r'/+$'), '');
  if (result.isEmpty) return '';
  _requireVisibleWithoutWhitespace(result, '代理地址');
  final uri = Uri.tryParse(result);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    throw ArgumentError('代理地址必须是 http:// 或 https:// 地址');
  }
  return result;
}

String? normalizeCodexWebSocketPolicy(String? value) {
  final normalized = value?.trim().toLowerCase() ?? '';
  if (normalized.isEmpty || normalized == codexWebSocketPolicyAuto) return null;
  if (normalized == codexWebSocketPolicyEnabled) return 'true';
  if (normalized == codexWebSocketPolicyDisabled) return 'false';
  if (normalized == 'true' || normalized == 'false') return normalized;
  throw ArgumentError('WebSocket 传输设置无效');
}

String normalizeCodexApiKey(String value) {
  final result = value.trim();
  if (result.isNotEmpty) _requireVisibleWithoutWhitespace(result, 'API 密钥');
  return result;
}

String normalizeCodexModel(String value, String fieldName) {
  final result = value.trim();
  if (result.isEmpty) return '';
  if (result.length > 200 ||
      !RegExp(r'^[A-Za-z0-9._:/@+\-]+$').hasMatch(result)) {
    throw ArgumentError('$fieldName只能包含字母、数字及 . _ - / : @ +');
  }
  return result;
}

String normalizeCodexReasoningEffort(String value) {
  final result = value.trim().toLowerCase();
  if (result.isEmpty) return '';
  const supported = {'minimal', 'low', 'medium', 'high', 'xhigh'};
  if (!supported.contains(result)) {
    throw ArgumentError('默认思考强度只能为极低、低、中、高或极高');
  }
  return result;
}

String? _codexTomlStringValue(
  String text, {
  required String? table,
  required String key,
}) {
  String? currentTable;
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    final header = RegExp(r'^\[([^]]+)\]').firstMatch(line);
    if (header != null) {
      currentTable = header.group(1)!.trim();
      continue;
    }
    if (currentTable != table) continue;
    final match = RegExp(
      '^${RegExp.escape(key)}\\s*=\\s*"((?:\\\\.|[^"])*)"',
    ).firstMatch(line);
    if (match != null) return _unescapeCodexTomlString(match.group(1)!);
  }
  return null;
}

String _replaceCodexTomlStringValue(
  String text, {
  required String? table,
  required String key,
  required String? value,
}) {
  final output = <String>[];
  final lines = const LineSplitter().convert(text);
  String? currentTable;
  var targetSeen = table == null;
  var inserted = false;

  void insertValue() {
    if (inserted) return;
    if (value != null) {
      output.add('$key = "${_escapeCodexTomlString(value)}"');
    }
    inserted = true;
  }

  for (final raw in lines) {
    final header = RegExp(r'^\s*\[([^]]+)\]').firstMatch(raw);
    if (header != null) {
      if (currentTable == table) insertValue();
      currentTable = header.group(1)!.trim();
      if (currentTable == table) targetSeen = true;
      output.add(raw);
      continue;
    }
    final existingKey = currentTable == table
        ? RegExp(r'^\s*([A-Za-z0-9_]+)\s*=').firstMatch(raw)?.group(1)
        : null;
    if (existingKey == key) continue;
    output.add(raw);
  }

  if (currentTable == table || table == null) insertValue();
  if (table != null && !targetSeen && value != null) {
    if (output.isNotEmpty && output.last.trim().isNotEmpty) output.add('');
    output
      ..add('[$table]')
      ..add('$key = "${_escapeCodexTomlString(value)}"');
  }
  return '${output.join('\n').replaceFirst(RegExp(r'\n+$'), '')}\n';
}

String _replaceCodexTomlBooleanValue(
  String text, {
  required String table,
  required String key,
  required String? value,
}) {
  final output = <String>[];
  final lines = const LineSplitter().convert(text);
  final targetTable = table.trim();

  String? currentTable;
  var targetSeen = false;
  var valueWritten = false;

  for (final raw in lines) {
    final header = RegExp(r'^\[([^\]]+)\]').firstMatch(raw.trim());
    if (header != null) {
      if (currentTable == targetTable && value != null && !valueWritten) {
        output.add('$key = $value');
        valueWritten = true;
      }
      currentTable = header.group(1)!.trim();
      if (currentTable == targetTable) targetSeen = true;
      output.add(raw);
      continue;
    }
    if (currentTable == targetTable) {
      final existingKey = RegExp(
        r'^\s*([A-Za-z0-9_]+)\s*=',
      ).firstMatch(raw)?.group(1);
      if (existingKey == key) {
        if (value != null && !valueWritten) {
          output.add('$key = $value');
          valueWritten = true;
        }
        continue;
      }
    }
    output.add(raw);
  }
  if (currentTable == targetTable && value != null && !valueWritten) {
    output.add('$key = $value');
  }
  if (!targetSeen && value != null) {
    if (output.isNotEmpty && output.last.trim().isNotEmpty) output.add('');
    output
      ..add('[$targetTable]')
      ..add('$key = $value');
  }
  return '${output.join('\n').replaceFirst(RegExp(r'\n+$'), '')}\n';
}

String _escapeCodexTomlString(String value) =>
    value.replaceAll('\\', '\\\\').replaceAll('"', '\\"');

String _unescapeCodexTomlString(String value) =>
    value.replaceAll('\\"', '"').replaceAll('\\\\', '\\');

Map<String, String> _prefixedValues(String output, String prefix) {
  final values = <String, String>{};
  for (final line in output.split(RegExp(r'\r?\n'))) {
    if (!line.startsWith(prefix)) continue;
    final value = line.substring(prefix.length);
    final separator = value.indexOf('=');
    if (separator <= 0) continue;
    values[value.substring(0, separator)] = value.substring(separator + 1);
  }
  return values;
}

void _requireVisibleWithoutWhitespace(String value, String fieldName) {
  if (value.codeUnits.any((unit) => unit <= 0x20 || unit > 0x7e)) {
    throw ArgumentError('$fieldName不能包含空格、换行或控制字符');
  }
}

String _shellQuote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";

final _shellTemplateToken = RegExp(r'@@([A-Z][A-Z0-9_]*)@@');

String _renderShellTemplate(String template, Map<String, String> replacements) {
  final usedKeys = <String>{};
  final rendered = template.replaceAllMapped(_shellTemplateToken, (match) {
    final key = match.group(1)!;
    final replacement = replacements[key];
    if (replacement == null) {
      throw StateError('Missing shell template replacement: $key');
    }
    usedKeys.add(key);
    return replacement;
  });
  final unusedKeys = replacements.keys
      .where((key) => !usedKeys.contains(key))
      .toList(growable: false);
  if (unusedKeys.isNotEmpty) {
    throw StateError(
      'Unused shell template replacements: ${unusedKeys.join(', ')}',
    );
  }
  return rendered;
}

String? _nonEmpty(String? value) {
  final result = value?.trim();
  return result == null || result.isEmpty ? null : result;
}

String _firstJsonString(Map<Object?, Object?> value, List<String> keys) {
  for (final key in keys) {
    final candidate = value[key];
    if (candidate is String && candidate.trim().isNotEmpty) {
      return candidate.trim();
    }
  }
  return '';
}

int _firstJsonInt(Map<Object?, Object?> value, List<String> keys) {
  for (final key in keys) {
    final candidate = value[key];
    final parsed = switch (candidate) {
      final int number => number,
      final num number => number.toInt(),
      final String text => int.tryParse(text.trim()),
      _ => null,
    };
    if (parsed != null && parsed >= 0) return parsed;
  }
  return 0;
}
