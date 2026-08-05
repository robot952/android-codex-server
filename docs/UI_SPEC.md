# UI reference and behavior contract

The supplied VS Code Codex reference is stored as `vscode-codex-task-reference.png`.

## Task view

- Compact top bar with the neutral `Agent` title and active server below it
- Refresh, new-task, and disconnect icon actions
- Search field followed by an unframed, divider-separated task list
- Each row renders runtime status, title, preview, source, working directory, and relative update time
- Active work uses a fixed-size progress indicator so row layout does not shift
- The active server header shows compact speedometer, memory, and storage icons with percentages; accessibility descriptions retain the metric names, while visible task rows stay unchanged
- Tapping the `Agent` title returns to the server list without disconnecting the selected server
- The Agent switcher is a two-segment control for Codex and OpenCode. Its selected segment uses a
  moving filled indicator, border, and stronger type weight; connection/install status remains visible
  in each segment. Switching segments animates only the lower task-list viewport horizontally, so the
  server metrics, search field, and actions do not reload or jump.
- Selecting an Agent that needs dependencies opens its install prompt. While downloading, the prompt
  can be minimized; the task continues and its overall percentage plus a compact progress bar appear
  inside that Agent's segment. Tapping the segment restores the prompt for that lane. Codex and
  OpenCode installers have independent jobs and never install the other Agent's package. Requests for
  the same server are queued while retaining separate per-Agent progress; different servers may install
  concurrently.
- After the Agent handshake succeeds, the task list and model/workspace selections restore from the
  profile-and-Agent cache immediately. Model, task-list, and workspace refreshes continue in parallel;
  workspace latency must never keep the Agent page in a loading state.

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
- Adjacent collaborator events from one turn retain the compact, horizontally wrapping Agent chip
  layout instead of repeating bulky transcript cards. Each chip grows only enough to place its own
  status after the name: active states use a fixed-size rotating indicator, while terminal states
  show their own visible label (`已完成`、`失败` etc.). No group-level status may stand in for multiple
  collaborators. An
  individual collaborator keeps a stable avatar color across all statuses; status color is not an
  identity signal.
- When collaborators exist, the composer has a collapsible `N 个后台智能体` panel. Every row
  shows its icon, name, and independent current status using the same active/terminal treatment;
  tapping a row opens that collaborator's own work page.
- Backing out of a collaborator page resumes the parent thread remotely as well as restoring its
  cached UI, so later input always targets the parent thread rather than the last collaborator.
  A loading child still accepts one back action; repeat presses do not skip a parent or issue a
  second resume. A failed resume returns to the child for retry, while a disconnected profile
  returns its cached parent view with a reconnect notice. A child resume must return the requested
  thread id; a mismatched response is retried once and then rejected, never rendered under the
  child Agent name. Unscoped streaming items are also rejected while viewing a child.
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
