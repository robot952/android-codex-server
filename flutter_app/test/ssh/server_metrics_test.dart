import 'package:codex_remote/src/ssh/server_metrics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const sampledAt = 1_725_000_000_123;

  group('parseServerMetrics', () {
    test('uses the last marker and trims the marker and field whitespace', () {
      final metrics = parseServerMetrics(
        'shell preface\n'
        'CODEX_METRICS|1|2|3|4|4|1|5|5|6|7\n'
        'unrelated output\n'
        '  CODEX_METRICS| 61 | 72 | 83 | 1024 | 768 | 8 | 4096 | 2048 | 300 | 200  \n'
        'trailing output\n',
        sampledAtEpochMillis: sampledAt,
      );

      expect(metrics.cpuPercent, 61);
      expect(metrics.memoryPercent, 72);
      expect(metrics.diskPercent, 83);
      expect(metrics.memoryTotalKiB, 1024);
      expect(metrics.memoryUsedKiB, 768);
      expect(metrics.cpuCoreCount, 8);
      expect(metrics.diskTotalKiB, 4096);
      expect(metrics.diskUsedKiB, 2048);
      expect(metrics.networkDownloadBytesPerSecond, 300);
      expect(metrics.networkUploadBytesPerSecond, 200);
      expect(metrics.sampledAtEpochMillis, sampledAt);
      expect(metrics.error, isNull);
    });

    test('accepts the four required fields without optional details', () {
      final metrics = parseServerMetrics(
        'CODEX_METRICS|10|20|30',
        sampledAtEpochMillis: sampledAt,
      );

      expect(metrics.cpuPercent, 10);
      expect(metrics.memoryPercent, 20);
      expect(metrics.diskPercent, 30);
      expect(metrics.memoryTotalKiB, isNull);
      expect(metrics.memoryUsedKiB, isNull);
      expect(metrics.cpuCoreCount, isNull);
      expect(metrics.diskTotalKiB, isNull);
      expect(metrics.diskUsedKiB, isNull);
      expect(metrics.networkDownloadBytesPerSecond, isNull);
      expect(metrics.networkUploadBytesPerSecond, isNull);
      expect(metrics.error, isNull);
    });

    test('returns an error when no marker has at least four fields', () {
      for (final output in [
        '',
        'ordinary command output',
        'CODEX_METRICS',
        'CODEX_METRICS|10',
        'CODEX_METRICS|10|20',
      ]) {
        final metrics = parseServerMetrics(
          output,
          sampledAtEpochMillis: sampledAt,
        );

        expect(metrics.error, '远端未返回资源数据', reason: output);
        expect(metrics.sampledAtEpochMillis, sampledAt, reason: output);
        expect(metrics.cpuPercent, isNull, reason: output);
      }
    });

    test('clamps percentages above 100 and rejects negative percentages', () {
      final metrics = parseServerMetrics(
        'CODEX_METRICS|101|999|-1',
        sampledAtEpochMillis: sampledAt,
      );

      expect(metrics.cpuPercent, 100);
      expect(metrics.memoryPercent, 100);
      expect(metrics.diskPercent, isNull);
    });

    test('rejects malformed and negative numeric details', () {
      final metrics = parseServerMetrics(
        'CODEX_METRICS|cpu|memory|disk|-1|used|cores|-2|-3|down|up',
        sampledAtEpochMillis: sampledAt,
      );

      expect(metrics.cpuPercent, isNull);
      expect(metrics.memoryPercent, isNull);
      expect(metrics.diskPercent, isNull);
      expect(metrics.memoryTotalKiB, isNull);
      expect(metrics.memoryUsedKiB, isNull);
      expect(metrics.cpuCoreCount, isNull);
      expect(metrics.diskTotalKiB, isNull);
      expect(metrics.diskUsedKiB, isNull);
      expect(metrics.networkDownloadBytesPerSecond, isNull);
      expect(metrics.networkUploadBytesPerSecond, isNull);
    });

    test('rejects zero CPU core count', () {
      final metrics = parseServerMetrics(
        'CODEX_METRICS|1|2|3|4|3|0',
        sampledAtEpochMillis: sampledAt,
      );

      expect(metrics.cpuCoreCount, isNull);
    });

    test('rejects used sizes greater than their totals', () {
      final metrics = parseServerMetrics(
        'CODEX_METRICS|1|2|3|100|101|4|200|201',
        sampledAtEpochMillis: sampledAt,
      );

      expect(metrics.memoryTotalKiB, 100);
      expect(metrics.memoryUsedKiB, isNull);
      expect(metrics.diskTotalKiB, 200);
      expect(metrics.diskUsedKiB, isNull);
    });

    test('maps shell sentinel values to unavailable fields', () {
      final metrics = parseServerMetrics(
        'CODEX_METRICS|-1|--|--|--|--|--|--|--|-1|-1',
        sampledAtEpochMillis: sampledAt,
      );

      expect(metrics.cpuPercent, isNull);
      expect(metrics.memoryPercent, isNull);
      expect(metrics.diskPercent, isNull);
      expect(metrics.memoryTotalKiB, isNull);
      expect(metrics.memoryUsedKiB, isNull);
      expect(metrics.cpuCoreCount, isNull);
      expect(metrics.diskTotalKiB, isNull);
      expect(metrics.diskUsedKiB, isNull);
      expect(metrics.networkDownloadBytesPerSecond, isNull);
      expect(metrics.networkUploadBytesPerSecond, isNull);
      expect(metrics.error, isNull);
    });
  });
}
