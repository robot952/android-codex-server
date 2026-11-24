import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/ui/remote_setup_dialog.dart';
import 'package:codex_remote/src/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('edit the download proxy with the Android keyboard open', (
    tester,
  ) async {
    var draft = '';
    String? submitted;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildCodexTheme(),
        home: Stack(
          fit: StackFit.expand,
          children: [
            const Scaffold(),
            RemoteSetupDialog(
              state: const AppUiState(
                remoteSetup: RemoteSetupPrompt(
                  title: '安装远程 Codex',
                  detail: '',
                  os: 'Linux',
                  architecture: 'x86_64',
                  home: '/home/example',
                ),
                setupProgress: '安装失败',
                setupProgressDetail: '请稍后重试',
              ),
              proxyUrl: draft,
              onProxyChanged: (text) => draft = text,
              onInstall: () => submitted = draft,
              onCancel: () {},
              onMinimize: () {},
            ),
          ],
        ),
      ),
    );
    final proxy = find.byKey(const ValueKey('remote-setup-proxy'));
    // The first frame can arrive before Android gives the Activity input focus.
    await tester.pumpAndSettle();
    for (
      var i = 0;
      tester.binding.lifecycleState != AppLifecycleState.resumed && i < 50;
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    }
    await tester.ensureVisible(proxy);
    await tester.tap(proxy);
    // Wait for Android's IME metrics as well as Flutter's dialog animation.
    for (
      var attempt = 0;
      tester.view.viewInsets.bottom == 0 && attempt < 30;
      attempt++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (attempt == 10 || attempt == 20) {
        await tester.tap(find.byType(EditableText));
      }
      await tester.pump();
    }
    await tester.pumpAndSettle();
    final view = tester.view;
    expect(view.viewInsets.bottom, greaterThan(0));
    final ratio = view.devicePixelRatio;
    final keyboardTop =
        (view.physicalSize.height - view.viewInsets.bottom) / ratio;
    final field = tester.getRect(proxy);
    expect(field.top, greaterThanOrEqualTo(view.viewPadding.top / ratio));
    expect(field.bottom, lessThanOrEqualTo(keyboardTop));
    expect(proxy.hitTestable(), findsOneWidget);
    await tester.enterText(proxy, 'http://proxy.example:8080');
    final retry = find.byKey(const ValueKey('remote-setup-install'));
    expect(retry.hitTestable(), findsOneWidget);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(submitted, 'http://proxy.example:8080');
    expect(tester.takeException(), isNull);
  });
}
