import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:synchronized/synchronized.dart';

import '../domain/request_usage.dart';

class UsageHistorySnapshot {
  const UsageHistorySnapshot({
    this.records = const [],
    this.dismissedIds = const [],
  });

  final List<RequestUsageRecord> records;
  // Bounded hashes only: clearing records must not turn replay into new usage.
  final List<String> dismissedIds;
}

abstract interface class RequestUsageStore {
  Future<UsageHistorySnapshot> read();
  Future<void> write(UsageHistorySnapshot snapshot);
}

class FileRequestUsageStore implements RequestUsageStore {
  FileRequestUsageStore({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  static const maxRecords = 10000;
  static const maxDismissedIds = 20000;
  static const maxFileBytes = 12 * 1024 * 1024;
  final Future<Directory> Function() _directoryProvider;
  final _lock = Lock();

  Future<File> _file() async =>
      File(p.join((await _directoryProvider()).path, 'request_usage_v1.json'));

  @override
  Future<UsageHistorySnapshot> read() => _lock.synchronized(() async {
    final file = await _file();
    if (!await file.exists()) return const UsageHistorySnapshot();
    if (await file.length() > maxFileBytes) {
      throw const FormatException('Usage history exceeds size limit');
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > maxFileBytes) {
      throw const FormatException('Usage history exceeds size limit');
    }
    return _decode(bytes);
  });

  // Separate static scopes keep the lock and directory callback out of the
  // isolate closure's captured context (they cannot cross isolate boundaries).
  static Future<UsageHistorySnapshot> _decode(List<int> bytes) =>
      Isolate.run(() {
        final json = jsonDecode(utf8.decode(bytes));
        if (json is! Map<String, dynamic> ||
            json['version'] != 1 ||
            json['records'] is! List ||
            json['dismissedIds'] is! List) {
          throw const FormatException('Invalid usage history');
        }
        final rows = json['records'] as List;
        final dismissed = json['dismissedIds'] as List;
        if (rows.length > maxRecords || dismissed.length > maxDismissedIds) {
          throw const FormatException('Usage history exceeds record limit');
        }
        return UsageHistorySnapshot(
          records: rows
              .whereType<Map<String, dynamic>>()
              .map(RequestUsageRecord.fromJson)
              .nonNulls
              .toList(),
          dismissedIds: dismissed
              .whereType<String>()
              .where((id) => RegExp(r'^[a-f0-9]{64}$').hasMatch(id))
              .toList(),
        );
      });

  static Future<List<int>> _encode(UsageHistorySnapshot snapshot) =>
      Isolate.run(
        () => utf8.encode(
          jsonEncode({
            'version': 1,
            'records': snapshot.records
                .map((record) => record.toJson())
                .toList(),
            'dismissedIds': snapshot.dismissedIds,
          }),
        ),
      );

  @override
  Future<void> write(UsageHistorySnapshot snapshot) =>
      _lock.synchronized(() async {
        if (snapshot.records.length > maxRecords ||
            snapshot.dismissedIds.length > maxDismissedIds) {
          throw const FormatException('Usage history exceeds record limit');
        }
        final bytes = await _encode(snapshot);
        if (bytes.length > maxFileBytes) {
          throw const FormatException('Usage history exceeds size limit');
        }
        final file = await _file();
        await file.parent.create(recursive: true);
        final temporary = File('${file.path}.tmp');
        try {
          await temporary.writeAsBytes(bytes, flush: true);
          await temporary.rename(file.path);
        } finally {
          if (await temporary.exists()) await temporary.delete();
        }
      });
}
