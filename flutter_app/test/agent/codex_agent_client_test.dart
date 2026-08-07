import 'package:codex_remote/src/agent/codex_agent_client.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('builds the app-server command with env and a quoted workspace', () {
    const profile = ServerProfile(
      id: 'server',
      workspace: "/srv/team's app",
      remoteCommand: '~/.local/bin/codex-remote app-server --listen stdio://',
    );

    final command = buildCodexAppServerCommand(profile);

    expect(command, contains(r'. "$HOME/.codex/codex-remote.env"'));
    expect(command, contains("cd -- '/srv/team'\"'\"'s app' &&"));
    expect(
      command,
      endsWith('exec ~/.local/bin/codex-remote app-server --listen stdio://'),
    );
  });

  test('rejects an empty remote command', () {
    expect(
      () => buildCodexAppServerCommand(
        const ServerProfile(id: 'server', remoteCommand: '  '),
      ),
      throwsStateError,
    );
  });
}
