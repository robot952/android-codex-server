# Codex Remote server

The Android application starts a Codex app-server channel over SSH. It never parses terminal ANSI
output and does not expose app-server on a public TCP port.

## Personal test setup

Run these commands as the Unix user whose Codex threads and credentials should be visible:

```bash
./install-codex-pinned.sh
~/.local/bin/codex-remote login status
CODEX_REMOTE_BIN="$HOME/.local/bin/codex-remote" node ./smoke-test.mjs
```

The app's remote command for direct mode is:

```text
~/.local/bin/codex-remote app-server --listen stdio://
```

The command remains the reproducible profile value and smoke-test entrypoint. On an unrestricted
shell account, App `1.8.19` and later transparently replace its stdio listener with a private Unix
socket and detach the app-server before opening the SSH forwarding channel. A mobile SSH socket can
then be recreated without terminating the remote app-server or its active turn. If Unix forwarding
or the listener is unavailable, the App cleans up and falls back to the direct stdio behavior below.

## Connection modes

### Durable private Unix listener (default App path)

The App derives a stable per-profile key, starts the configured Codex app-server with
`--listen unix:///...sock` under `nohup`/`setsid`, and connects through OpenSSH
`direct-streamlocal@openssh.com`. WebSocket messages never leave the SSH tunnel and no TCP listener
is created. Unexpected transport loss keeps the process and active turn alive; explicit App
disconnect stops the process. The server must allow a normal shell and Unix-socket forwarding.

### Direct stdio (the pinned npm install)

`install-codex-pinned.sh` installs the exact version from `protocol/codex-version.txt` into a
versioned npm prefix. Use this mode for the reproducible setup in this repository:

```text
~/.local/bin/codex-remote app-server --listen stdio://
```

The app-server exits when SSH disconnects, while persisted threads remain available on the next
connection. This remains the fallback for restricted/forced-command SSH accounts and servers that
disable `direct-streamlocal@openssh.com`.

### Durable daemon (optional, standalone installer only)

The current Codex daemon command only accepts the official standalone installation managed under
`$CODEX_HOME/packages/standalone/current/codex`. It does not accept the npm installation produced by
`install-codex-pinned.sh`; that installation is intentionally supported in direct stdio mode only.
`bootstrap-daemon.sh` requires an explicit auto-update opt-in, then checks the standalone path and
the pinned version before invoking the daemon command.

If you separately install the official standalone CLI, verify that its exact version matches
`protocol/codex-version.txt`, then run:

```bash
CODEX_REMOTE_ALLOW_DAEMON_BOOTSTRAP=1 \
  CODEX_REMOTE_STANDALONE_BIN="$HOME/.codex/packages/standalone/current/codex" \
  ./bootstrap-daemon.sh
```

Only after that succeeds should `CODEX_REMOTE_MODE=daemon` be used with a wrapper that explicitly
selects daemon mode; the sample forced-command wrapper intentionally ignores that override and stays
in direct mode.
The daemon/proxy path is optional and is not part of the npm pin workflow. Important: the
`daemon bootstrap` command launches Codex's detached updater, which periodically fetches the latest standalone
installer and may replace the managed binary. The bootstrap-time version check does not make this a
strict fixed-version mode. Use direct stdio mode for a strict pin; use daemon mode only when its
automatic update behavior is acceptable and monitor the reported version.

## Restricted SSH account

For an internet-reachable host, create a dedicated non-root account and install the pinned CLI while
logged in as that account. Copy `codex-app-server-ssh` to `/usr/local/libexec`, add the snippet from
`codex-remote.sshd_config.example` to sshd configuration, and validate configuration with:

```bash
sshd -t
```

The hardened forced entrypoint derives `CODEX_HOME`, the CLI path, and its launch directory from the
SSH account's passwd home and ignores `CODEX_REMOTE_*` overrides. It therefore launches in that
account's home by default. This is not a path sandbox: an authenticated app-server client can still
request a `cwd` in `thread/start` or `turn/start` anywhere the Unix account can access. Use a
dedicated account, filesystem permissions, or a container/chroot as the actual workspace boundary.
The sample also fixes the mode to direct; daemon/proxy mode requires a separately reviewed
root-owned wrapper and is not enabled by the sample forced-command configuration.

Each phone must have its own key in `authorized_keys`. Pin the SSH host fingerprint in the Android
profile. Do not enable password login, PTY, port forwarding, agent forwarding, root login, or a
general shell for this account. The forced entrypoint has an explicit SFTP path for attachments and
does not grant a shell, but SFTP availability still depends on the host's `Subsystem sftp` setting;
test it with the same key before relying on uploads. The entrypoint recognizes `sftp` and the common
external helper paths. OpenSSH's built-in `internal-sftp` cannot be dispatched by this wrapper;
configure an external `sftp-server` or use a separate upload-only account. The `-d` option is an
initial directory, not a chroot. Add and
test a dedicated upload directory or a properly configured `ChrootDirectory` (including the
external helper's required files) when filesystem confinement is required.

For this hardened forced-command example, the wrapper uses the account's real home as `CODEX_HOME`
and launch directory and ignores `CODEX_REMOTE_*` environment overrides. The Android profile's
Workspace field is still sent through the app-server protocol; restrict the account itself when
that path must be confined.

The wrapper launches an external SFTP helper, detected at `/usr/lib/openssh/sftp-server` or
`/usr/libexec/openssh/sftp-server`. In an actual forced SSH session, environment overrides are
ignored; install the helper at one of those paths or edit the root-owned wrapper for another path.
`CODEX_REMOTE_SFTP_SERVER` is only a local-test override.
When probing the wrapper from a shell that was itself opened over SSH, clear the inherited marker,
for example `env -u SSH_CONNECTION ...`; do not use that bypass for a real client connection.
If the host does not expose a compatible subsystem, use direct mode without attachments or a
separate, dedicated upload-only SSH account rather than weakening the forced command.

The `request_user_input` dialog is an experimental app-server API. In Codex 0.146.0 the
`default_mode_request_user_input` feature is disabled by default; enable it explicitly in the
server's own configuration/command only after reviewing the risk, for example:

```text
codex --enable default_mode_request_user_input app-server --listen stdio://
```

The Android client opts into experimental API notifications but rejects unsupported server
requests (such as MCP elicitation) with a JSON-RPC error instead of leaving a turn waiting.

Codex authentication stays in the server user's `CODEX_HOME`. Never copy `auth.json` into the APK.
For policy enforcement, deploy `requirements.toml.example` as `/etc/codex/requirements.toml` only
after checking whether other Codex users on the host should inherit the same restrictions.

## Version upgrades

1. Change `protocol/codex-version.txt`; Gradle reads this single source for
   `BuildConfig.PINNED_CODEX_VERSION`.
2. Run `install-codex-pinned.sh` with the new exact version.
3. Diff the generated schemas against the previous release.
4. Run unit tests, the smoke test, lint, and both APK builds.
5. Test thread history, an active turn, command approval, file approval, diff rendering, reconnect,
   and cancellation before switching the stable symlink.

The app-server transport is still experimental. Pinning and schema validation are mandatory. The
version pin applies directly to the npm install and direct stdio mode; standalone daemon mode has
its own auto-updating installer and must be version-checked before use.
