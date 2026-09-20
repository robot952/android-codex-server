/// This is Codex's model-provider transport, not the App's SSH transport.
bool isProviderWebSocketFallback(String message) => message
    .trimLeft()
    .toLowerCase()
    .startsWith('falling back from websockets to https transport');

String providerWebSocketFallbackLabel(String message) =>
    message.toLowerCase().contains('no available account')
    ? '模型接口暂无可用账号，正在切换到 HTTPS 重试。'
    : '模型连接中断，正在切换到 HTTPS 重试。';
