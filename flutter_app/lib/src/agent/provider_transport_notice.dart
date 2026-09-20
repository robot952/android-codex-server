/// This is Codex's model-provider transport, not the App's SSH transport.
bool isProviderWebSocketFallback(String message) => message
    .trimLeft()
    .toLowerCase()
    .startsWith('falling back from websockets to https transport');
