# UI reference and behavior contract

The supplied VS Code Codex reference is stored as `vscode-codex-task-reference.png`.

## Task view

- Compact top bar with the literal `CODEX` product name and active server below it
- Refresh, new-task, and disconnect icon actions
- Search field followed by an unframed, divider-separated task list
- Each row renders runtime status, title, preview, source, working directory, and relative update time
- Active work uses a fixed-size progress indicator so row layout does not shift

Protocol mapping: `thread/list`, `thread/start`, `thread/resume`, `thread/read`,
`thread/name/set`, and `thread/archive`.

## Work view

- Compact back/title/working-directory bar
- Full-width timeline, not chat cards nested inside section cards
- User messages use a restrained surface; agent output is native Markdown
- Reasoning and plan sections are collapsible
- Command items show command, status, and expandable output
- File changes show aggregate additions/deletions and a row per changed file
- Selecting a file opens a full-screen unified diff view
- Review is a direct action associated with file changes
- Composer remains fixed at the bottom with attachment, permission, model, stop, and send actions
- The context ring opens a compact popover with server-reported current-context usage: used/remaining
  percentage and used/window token counts. It is informational; manual compaction remains an explicit
  command in the composer action menu. Reopening a cached thread retains its last known usage until
  the server sends a newer value.
- Model and reasoning effort use a bottom sheet; sandbox choice uses a dedicated mode sheet
- Approvals are blocking dialogs tied to the exact JSON-RPC request id
- Transient remote diagnostics use a compact, dark, width-bounded Snackbar. Raw stderr, nested JSON,
  request ids, and stack-like text never occupy the work surface; a nonfatal MCP/rmcp 403 explains
  that the main session remains usable while the related tool may be unavailable.

Protocol mapping: `turn/start`, `turn/steer`, `turn/interrupt`, `review/start`, `item/*`,
`turn/diff/updated`, and server request/response approval methods.

## Visual constraints

- Default dark palette follows the quiet VS Code work surface rather than a marketing layout
- Cards are limited to actual command, tool, message, and file-change items, with 6 dp radius
- No gradients, decorative orbs, nested cards, oversized typography, or WebView UI
- Text uses zero letter spacing and stable control dimensions
- Diffs use green/red only for semantic additions/deletions; blue and amber cover other states
