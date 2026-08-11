import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/ui/server_metrics_strip.dart';
import 'package:codex_remote/src/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('keeps resource metrics compact and left aligned in portrait', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildCodexTheme(),
        home: const Scaffold(
          body: Padding(
            padding: EdgeInsets.symmetric(horizontal: 18),
            child: ServerMetricsStrip(
              metrics: ServerMetrics(
                cpuPercent: 63,
                memoryPercent: 33,
                diskPercent: 58,
                networkDownloadBytesPerSecond: 2048,
                networkUploadBytesPerSecond: 5120,
              ),
              showResourceDetails: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final cpu = tester.getRect(find.byIcon(Icons.speed));
    final memory = tester.getRect(find.byIcon(Icons.memory));
    final disk = tester.getRect(find.byIcon(Icons.storage));
    final network = tester.getRect(find.byIcon(Icons.network_check));

    expect(cpu.left, 18);
    expect(memory.left - cpu.left, lessThan(68));
    expect(disk.left - memory.left, lessThan(68));
    expect(network.left - disk.left, lessThan(68));
    expect(network.right, lessThan(260));
    expect(tester.takeException(), isNull);
  });
}
