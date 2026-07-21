# Codex Remote for Android

An Android client for a remote Codex CLI host. The app opens an SSH exec channel, starts the pinned
Codex app-server without a PTY, and renders its structured JSON-RPC events as a native Jetpack
Compose interface modeled after the VS Code Codex task and work views.

The project is isolated in `/home/yan/ygy/codex-remote-android`. It does not modify the existing
`ssh-client`, `lobe-android`, or `mihomo-web` workspaces.

## Features

- Multiple encrypted server profiles with password or imported private-key authentication
- SHA-256 SSH host-key fingerprint probing, explicit trust, and strict pinning
- Fixed Codex app-server command over a non-PTY JSON-RPC channel
- Independent SSH terminal with a local xterm renderer, hide/resume history, and explicit disconnect
- Codex `initialize` handshake and model catalog
- Task list, search, refresh, new task, resume, rename, and archive
- Streaming user/agent messages, reasoning, plans, command output, tool calls, and notices
- File-change summary, per-file unified diff viewer, and uncommitted-change review
- Command, file-write, permission, and `request_user_input` dialogs
- Turn start, same-turn steering, interruption, model, reasoning effort, and sandbox selection
- VS Code-style approval modes backed by Codex approval policies
- SSH directory picker after login with per-server workspace persistence
- IME-aware composer positioning and a jump-to-latest control while reading earlier output
- Optional SFTP attachment upload when the host's SSH subsystem and helper are configured; image
  paths are sent as `localImage` input
- Encrypted profile storage with Android Keystore-backed `EncryptedSharedPreferences`
- Pinned Codex CLI installer, restricted SSH entrypoint examples, schema generation, and smoke test
- SSH preflight with an explicit, user-approved installation of private Node.js and pinned Codex

## Build

The repository pins Gradle 8.2, AGP 8.2.2, Kotlin 1.9.22, and Android SDK 34.

For local iteration, use the tiered build entry point. It keeps Gradle's daemon, configuration
cache, task cache, and incremental Kotlin outputs between runs; normal development should not call
`clean`. By default the shared dependency cache is stored beside the checkout at
`../.gradle-cache`; set `GRADLE_USER_HOME` to override it.

```bash
./scripts/build-android.sh fast     # Kotlin compile only
./scripts/build-android.sh debug    # unit tests + installable debug APK
./scripts/build-android.sh release  # release unit tests + Lint + signed release APK
./scripts/build-android.sh all      # tests, Lint, and APKs for both variants
```

The script is offline by default once dependencies are cached. When a download is required, it
detects and uses the local `127.0.0.1:7890` proxy:

```bash
CODEX_BUILD_ONLINE=1 ./scripts/build-android.sh debug
```

```bash
docker run --rm \
  --network host \
  -v "$PWD:/project" \
  -v /home/yan/ygy/.gradle-cache:/gradle-cache \
  -v android-sdk:/opt/android-sdk \
  -e GRADLE_USER_HOME=/gradle-cache \
  -e CODEX_BUILD_ONLINE=1 \
  -w /project \
  thyrlian/android-sdk:latest \
  sh -lc './scripts/build-android.sh all'
```

APK:

```text
app/build/outputs/apk/debug/app-debug.apk
```

Both debug and release APKs use the project's persistent signing key at
`keystore/codex-remote-stable.keystore`, so builds from fresh containers remain upgrade-compatible.
Do not delete or regenerate that file. Its signing certificate SHA-256 is:

```text
D2:52:C3:93:69:98:B5:20:EB:48:2E:32:20:A9:91:88:A5:85:99:CF:F9:D0:00:90:0A:80:32:04:FE:A4:E3:F0
```

The debug APK can be installed directly:

```bash
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

`assembleRelease` produces a signed `app/build/outputs/apk/release/app-release.apk` with the same
certificate. Keep an encrypted backup of the signing key; losing it makes future in-place updates
impossible.

## Server quickstart

Run as the Unix user whose Codex login, threads, workspace, and config should be available:

```bash
cd server
./install-codex-pinned.sh
~/.local/bin/codex-remote login
CODEX_REMOTE_BIN="$HOME/.local/bin/codex-remote" node ./smoke-test.mjs
```

Create an Android server profile with:

```text
Host: your SSH host
User: the same Unix user
Command: ~/.local/bin/codex-remote app-server --listen stdio://
Workspace: an absolute project directory on the server
```

Tap the fingerprint action, verify the SHA-256 value against a trusted server console, then trust and
connect. The app loads the same persisted Codex threads visible to other Codex clients using that
Unix user's `CODEX_HOME`.

When the default managed command is selected, the app checks the remote host before starting Codex.
An existing compatible `codex-cli 0.144.6` is reused. If Codex is missing or has a different version,
the app asks before installing Node.js 22.17.0 and Codex into:

```text
~/.local/share/codex-remote/
~/.local/bin/codex-remote
```

The bootstrap does not use `sudo`, modify a system Node.js installation, or overwrite the CLI bundled
with the VS Code extension. Node.js archives are pinned by SHA-256 and the installed CLI version and
`app-server` command are verified before the connection continues. The server needs Linux x86_64 or
arm64, `sh`, `tar`, `sha256sum`, `curl` or `wget`, at least 300 MB free in the user's home directory,
and outbound HTTPS access to nodejs.org and the npm registry. The host also needs `flock` and
`setsid --wait` (normally provided by `util-linux`) so concurrent installs are serialized and an
install is terminated if its SSH connection disappears.

Installation does not create an OpenAI login. The CLI and IDE extension reuse the same login cache
under the Unix user's `CODEX_HOME` (normally `~/.codex`). On a new headless account, run
`~/.local/bin/codex-remote login --device-auth` after installation.

For a hardened forced-command account and daemon/proxy mode, see [server/README.md](server/README.md).
The sample forced entrypoint intentionally fixes direct mode, CLI paths, and its launch directory
rather than trusting SSH environment overrides. It is not a filesystem boundary; use a dedicated
account/container when the app-server `cwd` must be confined.

## Architecture

```text
Jetpack Compose UI
        |
AppViewModel + event reducer
        |
Codex JSON-RPC client
        |
SSH exec channel (JSONL stdin/stdout, no PTY)
        |
codex app-server --listen stdio://
        |
Pinned Codex CLI + server CODEX_HOME + workspace
```

`thread`, `turn`, and `item` are kept as separate protocol concepts. The event reducer updates an
idempotent timeline from item start/completion and delta notifications. Server-initiated requests
retain their JSON-RPC request id until the user approves, declines, or answers.

## Security defaults

- The app never accepts an unknown host silently during an authenticated connection.
- Cleartext Android network traffic and backups are disabled.
- Passwords and imported private keys are encrypted at rest.
- Codex credentials remain on the SSH host.
- New turns default to `workspace-write` and `on-request`.
- Full access requires a separate confirmation in the UI.
- Public app-server WebSocket listeners are not used.

`request_user_input` is experimental and disabled by default in Codex 0.144.6. The UI is ready for
servers that explicitly enable `default_mode_request_user_input`; otherwise normal command/file
approvals remain available.

For production, use a non-root account, public-key authentication, one key per phone, a forced SSH
command, no PTY/forwarding on the forced account, and server-side `requirements.toml` policy. The
forced entrypoint has an explicit, host-dependent external `sftp-server` attachment path but does
not provide a shell; built-in `internal-sftp` needs a separate upload account. Verify the host's
subsystem with the same key, and pair it with a tested chroot or dedicated upload directory when
filesystem confinement is needed.

## Protocol version

The direct transport pins `codex-cli 0.144.6`. The optional standalone daemon bootstrap starts an
updater and can move to a newer CLI, so use direct mode when a strict version pin is required. The
app-server interface remains experimental. Upgrade only by changing `protocol/codex-version.txt`
(the Android build reads this as its single version source), regenerating the schema, reviewing its
diff, and running the full validation checklist in `server/README.md`.

Official references:

- <https://learn.chatgpt.com/docs/app-server>
- <https://learn.chatgpt.com/docs/remote-connections>
- <https://github.com/openai/codex/tree/main/codex-rs/app-server>
