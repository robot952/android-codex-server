import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/app/codex_remote_app.dart';
import 'src/platform/diagnostic_logger.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final diagnostics = DiagnosticLogger.instance;
  try {
    await diagnostics.initialize();
  } catch (_) {
    // Diagnostics are best effort and must not prevent the app from opening.
  }

  final previousFlutterError = FlutterError.onError;
  FlutterError.onError = (details) {
    diagnostics.recordFlutterError(
      details.exception,
      details.stack,
      context: details.context?.toString(),
    );
    if (previousFlutterError != null) {
      previousFlutterError(details);
    } else {
      FlutterError.presentError(details);
    }
  };

  final previousPlatformError = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stack) {
    diagnostics.recordError(error, stack, tag: 'Async');
    return previousPlatformError?.call(error, stack) ?? false;
  };

  runZonedGuarded<void>(
    () => runApp(const ProviderScope(child: CodexRemoteApp())),
    (error, stack) => diagnostics.recordError(error, stack, tag: 'Zone'),
  );
}
