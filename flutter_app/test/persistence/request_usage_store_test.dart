import 'dart:convert';
import 'dart:io';

import 'package:codex_remote/src/persistence/request_usage_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/request_usage_fixture.dart';

void main() {
  late Directory directory;
  late FileRequestUsageStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('request-usage-fixture-');
    store = FileRequestUsageStore(directoryProvider: () async => directory);
  });
  tearDown(() => directory.delete(recursive: true));

  test('empty history and atomic round trip across store instances', () async {
    expect((await store.read()).records, isEmpty);
    final record = usageFixture();
    await store.write(UsageHistorySnapshot(records: [record]));
    final another = FileRequestUsageStore(
      directoryProvider: () async => directory,
    );
    expect((await another.read()).records.single.toJson(), record.toJson());
    await store.write(UsageHistorySnapshot(dismissedIds: [record.id]));
    expect((await another.read()).records, isEmpty);
    expect((await another.read()).dismissedIds, [record.id]);
    expect(
      await File('${directory.path}/request_usage_v1.json.tmp').exists(),
      isFalse,
    );
  });

  test(
    'rejects corrupt/versioned/oversized files rather than losing data silently',
    () async {
      final file = File('${directory.path}/request_usage_v1.json');
      for (final contents in [
        'not-json',
        '{"version":2}',
        '{"version":1,"records":{}}',
      ]) {
        await file.writeAsString(contents);
        await expectLater(store.read(), throwsFormatException);
      }
      final handle = await file.open(mode: FileMode.write);
      await handle.truncate(FileRequestUsageStore.maxFileBytes + 1);
      await handle.close();
      await expectLater(store.read(), throwsFormatException);
    },
  );

  test('invalid rows/counters are bounded and valid rows survive', () async {
    final record = usageFixture();
    await File('${directory.path}/request_usage_v1.json').writeAsString(
      jsonEncode({
        'version': 1,
        'records': [
          record.toJson(),
          {'id': 'invalid'},
          {...record.toJson(), 'recordedAtMillis': -1},
        ],
        'dismissedIds': [record.id, 'not-a-hash', 123],
      }),
    );
    final value = await store.read();
    expect(value.records, hasLength(1));
    expect(value.dismissedIds, [record.id]);
  });

  test(
    'concurrent writes serialize and excessive counts preserve previous file',
    () async {
      final first = usageFixture();
      final last = usageFixture(id: 'b');
      await Future.wait([
        store.write(UsageHistorySnapshot(records: [first])),
        store.write(UsageHistorySnapshot(records: [last])),
      ]);
      await expectLater(
        store.write(
          UsageHistorySnapshot(
            records: List.filled(FileRequestUsageStore.maxRecords + 1, first),
          ),
        ),
        throwsFormatException,
      );
      expect((await store.read()).records.single.id, last.id);
    },
  );
}
