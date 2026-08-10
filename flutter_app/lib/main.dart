import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/app/app_controller.dart';
import 'src/app/codex_remote_app.dart';
import 'src/platform/background_connection_bridge.dart';
import 'src/platform/diagnostic_logger.dart';

Future<void> main(List<String> arguments) async {
  final diagnostics = DiagnosticLogger.instance;
  await (runZonedGuarded<Future<void>>(
        () async {
          WidgetsFlutterBinding.ensureInitialized();
          try {
            await diagnostics.initialize();
          } catch (_) {
            // Diagnostics are best effort and must not block app startup.
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

          final backgroundRestoreIntent =
              BackgroundConnectionIntent.fromEntrypointArguments(arguments);
          runApp(
            ProviderScope(
              overrides: <Override>[
                backgroundRestoreIntentProvider.overrideWithValue(
                  backgroundRestoreIntent,
                ),
              ],
              child: const CodexRemoteApp(),
            ),
          );
        },
        (error, stack) => diagnostics.recordError(error, stack, tag: 'Zone'),
      ) ??
      Future<void>.value());
}
