import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/ui/remote_setup_dialog.dart';
import 'package:codex_remote/src/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows runtime information and forwards proxy and actions', (
    tester,
  ) async {
    final proxies = <String>[];
    var installs = 0;
    var cancels = 0;

    await tester.pumpWidget(
      _DialogHarness(
        state: const AppUiState(
          remoteSetup: RemoteSetupPrompt(
            title: '安装远程 Codex',
            detail: '服务器上没有兼容的 Codex 运行时。',
            os: 'Linux',
            architecture: 'x86_64',
            home: '/home/tester',
            detectedVersion: '0.130.0',
            targetVersion: '0.162.1',
          ),
        ),
        proxyUrl: 'http://127.0.0.1:7890',
        onProxyChanged: proxies.add,
        onInstall: () => installs += 1,
        onCancel: () => cancels += 1,
      ),
    );

    expect(find.text('安装远程 Codex'), findsOneWidget);
    expect(find.text('将在此服务器安装 Codex 0.162.1，完成后自动连接。'), findsOneWidget);
    expect(find.text('Linux · x86_64'), findsOneWidget);
    expect(find.text('Codex 0.162.1 · Node 22.17.0'), findsOneWidget);
    expect(find.text('0.130.0'), findsOneWidget);
    expect(find.text('目标版本'), findsOneWidget);
    expect(find.text('当前版本'), findsOneWidget);
    expect(
      find.text('Codex $defaultCodexVersion · Node 22.17.0'),
      findsNothing,
    );
    expect(find.text('/home/tester/.local/share/codex-remote'), findsOneWidget);
    expect(_fieldText(tester, 'remote-setup-proxy'), 'http://127.0.0.1:7890');

    await tester.enterText(
      find.byKey(const ValueKey('remote-setup-proxy')),
      'https://proxy.example.com:8443',
    );
    expect(proxies.last, 'https://proxy.example.com:8443');

    await tester.tap(find.byKey(const ValueKey('remote-setup-install')));
    await tester.tap(find.byKey(const ValueKey('remote-setup-cancel')));
    expect(installs, 1);
    expect(cancels, 1);
  });

  testWidgets('shows overall and download progress and only allows minimize', (
    tester,
  ) async {
    var installs = 0;
    var minimizes = 0;

    await tester.pumpWidget(
      _DialogHarness(
        state: const AppUiState(
          remoteSetup: RemoteSetupPrompt(
            title: '安装远程 OpenCode',
            detail: '需要安装固定版本。',
            os: 'Ubuntu 24.04',
            architecture: 'aarch64',
            home: '/root',
            agent: AgentKind.openCode,
          ),
          setupInProgress: true,
          setupProgress: '正在下载 OpenCode',
          setupProgressPercent: 46,
          setupProgressDetail: '正在下载远程安装包',
          setupDownloadPercent: 73,
          setupDownloadedBytes: 3 * 1024 * 1024,
          setupTotalBytes: 4 * 1024 * 1024,
          setupBytesPerSecond: 512 * 1024,
          setupElapsedSeconds: 6,
        ),
        onInstall: () => installs += 1,
        onMinimize: () => minimizes += 1,
      ),
    );

    expect(find.text('OpenCode 1.18.11 · 共享 Node 22.17.0'), findsOneWidget);
    expect(
      find.text('/root/.local/share/codex-remote/opencode/releases/1.18.11'),
      findsOneWidget,
    );
    expect(
      find.text('/root/.local/bin/codex-remote-opencode-bridge'),
      findsOneWidget,
    );
    expect(find.text('46%'), findsOneWidget);
    expect(find.text('75%'), findsOneWidget);
    expect(find.text('73%'), findsNothing);
    expect(find.text('安装步骤进度'), findsOneWidget);
    expect(find.text('当前文件下载'), findsOneWidget);
    expect(find.textContaining('3.0 MB / 4.0 MB'), findsOneWidget);
    expect(find.textContaining('512.0 KB/s'), findsOneWidget);
    expect(find.textContaining('用时 6s'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const ValueKey('remote-setup-overall-progress')),
          )
          .value,
      0.46,
    );
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const ValueKey('remote-setup-download-progress')),
          )
          .value,
      0.75,
    );
    expect(find.byKey(const ValueKey('remote-setup-proxy')), findsNothing);
    expect(find.text('安装在服务器上继续，可最小化查看其他页面。'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('remote-setup-install')),
          )
          .onPressed,
      isNull,
    );

    await tester.tap(find.byKey(const ValueKey('remote-setup-minimize')));
    expect(minimizes, 1);
    expect(installs, 0);
  });

  testWidgets('keeps npm component processing separate from download bytes', (
    tester,
  ) async {
    await tester.pumpWidget(
      const _DialogHarness(
        state: AppUiState(
          remoteSetup: RemoteSetupPrompt(
            title: '安装远程 Codex',
            detail: '需要安装固定版本。',
            os: 'Windows',
            architecture: 'x64',
            home: r'C:\Users\tester',
          ),
          setupInProgress: true,
          setupProgress: '正在通过 npm 安装 Codex',
          setupProgressPercent: 24,
          setupProgressDetail: '已处理 1 / 7 个组件',
          setupElapsedSeconds: 8,
          setupProgressIndeterminate: true,
        ),
      ),
    );

    expect(find.text('已处理 1 / 7 个组件'), findsOneWidget);
    expect(find.text('用时 8s'), findsOneWidget);
    expect(find.text('当前文件下载'), findsNothing);
    expect(find.textContaining('总大小未知'), findsNothing);
    expect(
      find.byKey(const ValueKey('remote-setup-download-progress')),
      findsNothing,
    );
  });

  testWidgets('unknown download total never presents a supplied percentage', (
    tester,
  ) async {
    await tester.pumpWidget(
      const _DialogHarness(
        state: AppUiState(
          remoteSetup: RemoteSetupPrompt(
            title: '安装远程 Codex',
            detail: '需要安装固定版本。',
            os: 'Linux',
            architecture: 'x86_64',
            home: '/root',
            targetVersion: '0.162.1',
            detectedVersion: 'codex-cli 0.154.0',
          ),
          setupInProgress: true,
          setupProgress: '正在下载 Node.js 22.17.0',
          setupProgressPercent: 12,
          setupDownloadPercent: 14,
          setupDownloadedBytes: 2 * 1024 * 1024,
          setupBytesPerSecond: 256 * 1024,
          setupElapsedSeconds: 8,
          setupProgressIndeterminate: true,
        ),
      ),
    );

    expect(find.text('Codex 0.162.1 · Node 22.17.0'), findsOneWidget);
    expect(find.text('codex-cli 0.154.0'), findsOneWidget);
    expect(find.text('14%'), findsNothing);
    expect(
      find.byKey(const ValueKey('remote-setup-download-percent')),
      findsNothing,
    );
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const ValueKey('remote-setup-download-progress')),
          )
          .value,
      isNull,
    );
    expect(find.textContaining('已下载 2.0 MB / 总大小未知'), findsOneWidget);
  });

  testWidgets('preparation does not infer a percentage from the stage name', (
    tester,
  ) async {
    await tester.pumpWidget(
      const _DialogHarness(
        state: AppUiState(
          remoteSetup: RemoteSetupPrompt(
            title: '安装远程 Codex',
            detail: '需要安装固定版本。',
            os: 'Linux',
            architecture: 'x86_64',
            home: '/root',
          ),
          setupInProgress: true,
          setupProgress: '正在下载并安装 Codex',
        ),
      ),
    );

    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const ValueKey('remote-setup-overall-progress')),
          )
          .value,
      isNull,
    );
    expect(
      find.byKey(const ValueKey('remote-setup-overall-percent')),
      findsNothing,
    );
    expect(find.text('18%'), findsNothing);
  });

  testWidgets('renders an installation failure as a retry state', (
    tester,
  ) async {
    var retries = 0;

    await tester.pumpWidget(
      _DialogHarness(
        state: const AppUiState(
          remoteSetup: RemoteSetupPrompt(
            title: '安装远程 Codex',
            detail: '需要安装固定版本。',
            os: 'Linux',
            architecture: 'x86_64',
            home: '/root',
          ),
          setupProgress: '安装失败',
          setupProgressDetail: '下载连接已中断',
          error: '无法下载 Node.js，请检查代理后重试',
        ),
        onInstall: () => retries += 1,
      ),
    );

    expect(find.text('安装未完成'), findsOneWidget);
    expect(find.text('无法下载 Node.js，请检查代理后重试'), findsOneWidget);
    expect(find.text('重试安装'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('remote-setup-proxy')))
          .enabled,
      isTrue,
    );

    await tester.tap(find.byKey(const ValueKey('remote-setup-install')));
    expect(retries, 1);
  });

  testWidgets('moves the compact dialog above the keyboard inset', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 800);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const _DialogHarness(
        state: AppUiState(
          remoteSetup: RemoteSetupPrompt(
            title: '安装远程 Codex',
            detail: '服务器上没有兼容的运行时。',
            os: 'Linux',
            architecture: 'x86_64',
            home: '/root',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Focus the field before applying the simulated keyboard inset. This
    // mirrors the order of events on Android and avoids tapping a clipped
    // field that is already laid out beneath the inset.
    final proxy = find.byKey(const ValueKey('remote-setup-proxy'));
    await tester.ensureVisible(proxy);
    expect(proxy.hitTestable(), findsOneWidget);
    await tester.tap(proxy);
    await tester.pumpAndSettle();
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
    );
    expect(
      find.byKey(const ValueKey('remote-setup-runtime-information')),
      findsNothing,
    );

    await tester.pumpWidget(
      const _DialogHarness(
        bottomInset: 260,
        state: AppUiState(
          remoteSetup: RemoteSetupPrompt(
            title: '安装远程 Codex',
            detail: '服务器上没有兼容的运行时。',
            os: 'Linux',
            architecture: 'x86_64',
            home: '/root',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final padding = tester.widget<AnimatedPadding>(
      find.byKey(const ValueKey('remote-setup-keyboard-padding')),
    );
    expect((padding.padding as EdgeInsets).bottom, 276);
    expect(proxy.hitTestable(), findsOneWidget);
    expect(tester.getRect(proxy).bottom, lessThanOrEqualTo(540));
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'starting installation dismisses proxy focus and restores target information',
    (tester) async {
      const prompt = RemoteSetupPrompt(
        title: '安装远程 Codex',
        detail: '需要安装固定版本。',
        os: 'Linux',
        architecture: 'x86_64',
        home: '/root',
        targetVersion: '0.162.1',
      );
      await tester.pumpWidget(
        const _DialogHarness(state: AppUiState(remoteSetup: prompt)),
      );
      final proxy = find.byKey(const ValueKey('remote-setup-proxy'));
      await tester.ensureVisible(proxy);
      await tester.tap(proxy);
      await tester.pumpAndSettle();
      final focusNode = tester
          .widget<EditableText>(find.byType(EditableText))
          .focusNode;
      expect(focusNode.hasFocus, isTrue);

      await tester.pumpWidget(
        const _DialogHarness(
          state: AppUiState(
            remoteSetup: prompt,
            setupInProgress: true,
            setupProgress: '正在准备安装',
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(proxy, findsNothing);
      expect(focusNode.hasFocus, isFalse);
      expect(find.text('Codex 0.162.1 · Node 22.17.0'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'target version and actions remain usable on a narrow large-text screen',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 700);
      addTearDown(tester.view.reset);
      var minimizes = 0;
      var retries = 0;
      const prompt = RemoteSetupPrompt(
        title: '安装远程 Codex',
        detail: '需要安装固定版本。',
        os: 'Linux',
        architecture: 'x86_64',
        home: '/root',
        targetVersion: '0.162.1',
        detectedVersion: 'codex-cli 0.154.0',
      );

      await tester.pumpWidget(
        _DialogHarness(
          textScale: 2,
          state: const AppUiState(
            remoteSetup: prompt,
            setupInProgress: true,
            setupProgress: '下载并安装 Codex CLI 0.162.1',
            setupProgressPercent: 68,
            setupProgressDetail: '已处理 1 / 7 个组件',
            setupElapsedSeconds: 23,
            setupProgressIndeterminate: true,
          ),
          onMinimize: () => minimizes += 1,
        ),
      );
      await tester.pump();
      expect(find.text('Codex 0.162.1 · Node 22.17.0'), findsOneWidget);
      final label = tester.widget<Text>(
        find.byKey(const ValueKey('remote-setup-progress-label')),
      );
      expect(label.maxLines, isNull);
      expect(label.overflow, isNot(TextOverflow.ellipsis));
      await tester.ensureVisible(
        find.byKey(const ValueKey('remote-setup-progress-label')),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('remote-setup-minimize')));
      expect(minimizes, 1);

      await tester.pumpWidget(
        _DialogHarness(
          textScale: 2,
          state: const AppUiState(remoteSetup: prompt, error: '无法下载，请检查代理后重试'),
          onInstall: () => retries += 1,
        ),
      );
      await tester.pump();
      await tester.ensureVisible(
        find.byKey(const ValueKey('remote-setup-proxy')),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('remote-setup-install')));
      expect(retries, 1);
    },
  );
}

class _DialogHarness extends StatelessWidget {
  const _DialogHarness({
    required this.state,
    this.proxyUrl = '',
    this.bottomInset = 0,
    this.textScale = 1,
    this.onProxyChanged = _noopProxy,
    this.onInstall = _noop,
    this.onCancel = _noop,
    this.onMinimize = _noop,
  });

  final AppUiState state;
  final String proxyUrl;
  final double bottomInset;
  final double textScale;
  final ValueChanged<String> onProxyChanged;
  final VoidCallback onInstall;
  final VoidCallback onCancel;
  final VoidCallback onMinimize;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: buildCodexTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          viewInsets: EdgeInsets.only(bottom: bottomInset),
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      home: Scaffold(
        resizeToAvoidBottomInset: false,
        body: Stack(
          fit: StackFit.expand,
          children: [
            const SizedBox.expand(),
            RemoteSetupDialog(
              state: state,
              proxyUrl: proxyUrl,
              onProxyChanged: onProxyChanged,
              onInstall: onInstall,
              onCancel: onCancel,
              onMinimize: onMinimize,
            ),
          ],
        ),
      ),
    );
  }
}

String _fieldText(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;

void _noop() {}

void _noopProxy(String _) {}
