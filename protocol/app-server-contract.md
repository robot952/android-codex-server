# Pinned Codex app-server contract

The Android client targets `codex-cli 0.144.6` and the pinned app-server API. Its optional remote
bootstrap also pins the private Node.js runtime in `node-version.txt`.
The client performs the following JSON-RPC flow over newline-delimited JSON:

1. `initialize`, followed by the `initialized` notification.
2. `model/list` and `thread/list` for the task screen.
3. `thread/read`, `thread/resume`, `thread/start`, and `thread/archive` for thread lifecycle.
4. `turn/start`, `turn/steer`, and `turn/interrupt` for work.
5. `review/start` for uncommitted-change review.
6. Server notifications for turn, item, command, file change, plan, and diff updates.
7. Server requests for command and file-change approvals.

Generate the authoritative schema whenever the pinned CLI changes:

```bash
codex app-server generate-json-schema --out server/generated-schema
```

The client opts into `experimentalApi` because the VS Code-style approval/input surface uses the
experimental `request_user_input` request. Codex 0.144.6 keeps the corresponding
`default_mode_request_user_input` feature disabled by default; enable it explicitly on the server
only when that workflow is wanted. Unknown notifications are ignored, while unsupported
server-initiated requests receive a JSON-RPC `-32601` response so a turn cannot wait forever. A
different CLI version is reported in the connection status and must be validated before release.
