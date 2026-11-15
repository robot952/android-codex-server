# Pinned Codex app-server contract

The Android client targets `codex-cli 0.169.0` by default and the pinned app-server API. Each server profile
can select another official stable Codex CLI release. Its optional remote
bootstrap also pins the private Node.js runtime in `node-version.txt`.
The client performs the following JSON-RPC flow over newline-delimited JSON:

1. `initialize`, followed by the `initialized` notification.
2. `model/list` and `thread/list` for the task screen.
3. `thread/read`, `thread/resume`, `thread/start`, and `thread/archive` for thread lifecycle.
4. `turn/start`, `turn/steer`, and `turn/interrupt` for work.
5. `review/start` for uncommitted-change review.
6. Server notifications for turn, item, command, file change, plan, and diff updates.
7. Server requests for command/file-change/permission approvals and user-input questions.

`item/tool/requestUserInput` (legacy alias `tool/requestUserInput`) is displayed as a modal,
thread-scoped question form. Preserve question ids, option labels/descriptions, `isOther`, and
`isSecret`. Submit `{ "answers": { "question-id": { "answers": ["user answer"] } } }`
with the original numeric/string request id. Skipping sends `{ "answers": {} }`, never empty
strings or suggested answers on the user's behalf. `autoResolutionMs` does not cause this client
to select or submit an answer automatically.

`serverRequest/resolved` removes only the matching thread and type-sensitive request id from
both the adapter pending map and UI queue, including background threads. Dialog ownership
prevents a resolved request from dismissing unrelated routes. Replies are bound to the initiating
transport generation. See https://learn.chatgpt.com/docs/app-server#toolrequestuserinput.

Generate the authoritative schema whenever the pinned CLI changes:

```bash
codex app-server generate-json-schema --experimental --out server/generated-schema
```

The client opts into `experimentalApi` because the VS Code-style approval/input surface uses the
experimental `request_user_input` request. Codex 0.153.3 keeps the corresponding
`default_mode_request_user_input` feature disabled by default. Since App 1.8.109, the Codex adapter
passes `config: { "features.default_mode_request_user_input": true }` on `thread/start` and
`thread/resume`. This is a thread-local override, not a global config write or collaboration-mode
change, and is never sent to OpenCode. Existing loaded threads can ignore resume overrides;
finish active work and reconnect after upgrading the App. Real Codex 0.153.3 and 0.154.0 were
tested with isolated local model responses for disabled, enabled and resumed-thread cases.
Unknown notifications are ignored, while unsupported
server-initiated requests receive a JSON-RPC `-32601` response so a turn cannot wait forever. A
different CLI version is reported in the connection status and must be validated before release.
Turn timestamps such as `startedAt` are Unix seconds and must be normalized to milliseconds before
Android uses them for elapsed-time calculations.

## Codex 0.169.0 compatibility

The default is shared by Flutter profiles, runtime setup and `protocol/codex-version.txt`.
New profiles and stored profiles with no version field receive it; explicitly stored versions and
custom commands remain unchanged. Changing an existing server's selected version uses the normal
managed installation flow, without replacing system Codex or rewriting its sessions/configuration.

`model/list` uses the native process's effective default provider, `includeHidden: true`, and opaque
continuation cursors. Global-file provider settings must not override workspace/launch configuration.
Pages are deduplicated by model ID while preserving wire model IDs and efforts.
The entire catalogue shares one timeout budget and at most 20 pages. Invalid/repeated cursors,
provider rejection or a changed connection generation fail the fetch rather than publishing a
partial catalogue or silently switching providers. The client does not inject `modelProvider`.

An old `turn/completed` (including `interrupted` or `failed`) cannot clear a newer known active
turn in either the foreground or background thread list. Native interrupt requests retain both
thread and turn IDs. The existing item-based history relay remains bounded to 20 records per
page, with read-only child inspection and writer ownership checks intact.

Native 0.169 can emit an empty `item/started` before text arrives. The metrics relay excludes empty
message, reasoning and plan placeholders from TTFT; the first actual delta (or model-issued tool)
still uses server timestamps. Both SSE and WebSocket loopback probes assert the original first-text
threshold with a paused phone reader, rather than relaxing the threshold for the new lifecycle.

The native loopback fixture `scripts/test-codex-history-relay-live.cjs` validates this version's
provider catalogue, fork pagination, active-turn resume, interruption followed by a new turn,
and delayed interruption of the previous turn, alongside malformed child-message compatibility
and HTTP 400 recovery. It uses isolated synthetic sessions without credentials or paid model calls.
