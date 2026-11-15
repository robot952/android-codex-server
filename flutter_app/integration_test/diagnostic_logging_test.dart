import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codex_remote/src/app/app_controller.dart';
import 'package:codex_remote/src/app/codex_remote_app.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/persistence/profile_store.dart';
import 'package:codex_remote/src/platform/app_update_manager.dart';
import 'package:codex_remote/src/platform/diagnostic_logger.dart';
import 'package:codex_remote/src/ssh/server_connection_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Store implements ProfileStore {
  @override
  Future<StoredProfiles> load() async => const StoredProfiles();
  @override
  Future<void> save(StoredProfiles value) async {}
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Android saves gzip on lifecycle, log actions and shutdown', (
    tester,
  ) async {
    final root = await Directory.systemTemp.createTemp('diagnostic-check-');
    final logs = Directory('${root.path}/logs');
    final exports = Directory('${root.path}/exports');
    const native = MethodChannel('top.asdb.agent/diagnostics');
    final preferences = await SharedPreferences.getInstance();
    final previousEnabled =
        preferences.getBool(
          SharedPreferencesDiagnosticSettingsStore.enabledKey,
        ) ??
        false;
    File? shared;
    final logger = DiagnosticLogger(
      directoryProvider: () async => logs,
      exportDirectoryProvider: () async => exports,
      settingsProvider: () async => MemoryDiagnosticSettingsStore(),
      shareHandler: (file) async => shared = file,
    );
    final manager = ServerConnectionManager();
    final controller = AppController(_Store(), manager, null, logger);
    addTearDown(() async {
      await native.invokeMethod<void>('setEnabled', {
        'enabled': previousEnabled,
      });
      await manager.close();
      await root.delete(recursive: true);
    });
    await logger.setEnabled(true);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appControllerProvider.overrideWith((ref) => controller),
          appUpdateProvider.overrideWith(
            (ref) => AppUpdateController(autoCheck: false),
          ),
        ],
        child: const CodexRemoteApp(),
      ),
    );
    await tester.pumpAndSettle();
    final active = (await logger.listLogs()).first;
    final file = File('${logs.path}/${active.fileName}');
    String diskText() => utf8.decode(gzip.decode(file.readAsBytesSync()));
    final before = file.readAsBytesSync();
    logger.info('Fixture', 'memory-only-marker');
    expect(file.readAsBytesSync(), before);

    // Exercise the production AppRoot observer, without calling logger.flush.
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    for (var attempt = 0; attempt < 50; attempt++) {
      if (diskText().contains('memory-only-marker')) break;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(diskText(), contains('memory-only-marker'));
    expect(diskText(), contains('to=paused'));
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    logger.info('Fixture', 'share-marker');
    await logger.share(ids: [active.id]);
    expect(shared!.path, endsWith('.log.gz'));
    expect(shared!.readAsBytesSync(), file.readAsBytesSync());
    expect(diskText(), contains('share-marker'));
    logger.info('Fixture', 'attachment-marker');
    final attachment = await logger.attachmentBytes(active.id);
    expect(attachment, file.readAsBytesSync());
    expect(diskText(), contains('attachment-marker'));

    logger.info('Fixture', 'shutdown-marker');
    final shutdown = Completer<void>();
    tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'top.asdb.agent/background',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('shutdown'),
      ),
      (reply) {
        expect(const StandardMethodCodec().decodeEnvelope(reply!), isTrue);
        shutdown.complete();
      },
    );
    await shutdown.future.timeout(const Duration(seconds: 5));
    expect(diskText(), contains('shutdown-marker'));

    final support = await getApplicationSupportDirectory();
    final nativeFiles = Directory('${support.path}/diagnostics')
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.log.gz'))
        .toList();
    expect(nativeFiles, isNotEmpty);
    expect(nativeFiles.length, lessThanOrEqualTo(5));
    expect(
      nativeFiles.any(
        (file) => utf8
            .decode(gzip.decode(file.readAsBytesSync()))
            .contains('native_diagnostic_logging_enabled'),
      ),
      isTrue,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
