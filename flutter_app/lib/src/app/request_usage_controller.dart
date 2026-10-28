import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/models.dart';
import '../domain/request_usage.dart';
import '../persistence/request_usage_store.dart';

final requestUsageStoreProvider = Provider<RequestUsageStore>(
  (ref) => FileRequestUsageStore(),
);

final requestUsageProvider =
    StateNotifierProvider<RequestUsageController, UsageHistoryState>(
      (ref) => RequestUsageController(ref.watch(requestUsageStoreProvider)),
    );

class UsageHistoryState {
  const UsageHistoryState({
    this.records = const [],
    this.loading = true,
    this.error,
  });

  final List<RequestUsageRecord> records;
  final bool loading;
  final String? error;

  RequestUsageRecord? latestFor({
    required String profileId,
    required AgentKind agent,
    required String provider,
    required String threadId,
  }) => records
      .where(
        (record) =>
            record.profileId == profileId &&
            record.agent == agent &&
            record.provider == provider &&
            record.threadId == threadId,
      )
      .firstOrNull;
}

/// Observes usage notifications once, independently of navigation or transcript
/// replay. A stable upstream request ID wins; Codex v2 supplies cumulative
/// counters instead, which identify completed requests within a turn.
class RequestUsageController extends StateNotifier<UsageHistoryState> {
  RequestUsageController(
    this._store, {
    int Function()? nowMillis,
    this.writeDebounce = const Duration(milliseconds: 400),
  }) : _nowMillis = nowMillis ?? (() => DateTime.now().millisecondsSinceEpoch),
       super(const UsageHistoryState()) {
    ready = _load();
  }

  final RequestUsageStore _store;
  final int Function() _nowMillis;
  final Duration writeDebounce;
  late final Future<void> ready;
  final _records = <String, RequestUsageRecord>{};
  final _dismissed = <String>{};
  Future<void> _writeTail = Future.value();
  Timer? _timer;
  bool _loaded = false;
  bool _dirty = false;
  bool _readFailed = false;
  Future<bool>? _retry;
  String? _error;

  Future<void> _load() async {
    try {
      final saved = await _store.read();
      _dismissed.addAll(saved.dismissedIds);
      final live = Map<String, RequestUsageRecord>.of(_records);
      _records.clear();
      for (final record in saved.records) {
        if (!_dismissed.contains(record.id)) _records[record.id] = record;
      }
      for (final record in live.values) {
        if (!_dismissed.contains(record.id)) {
          _records[record.id] = _records[record.id]?.merge(record) ?? record;
        }
      }
      _readFailed = false;
      _error = null;
    } catch (_) {
      // Never replace unread history with a partial in-memory snapshot.
      _readFailed = true;
      _error = '本机统计读取失败；新收到的用量仍会显示。';
    }
    _loaded = true;
    _prune();
    _publish();
    if (_dirty) _scheduleWrite();
  }

  void observe({
    required String profileId,
    required AgentKind agent,
    required String provider,
    required String threadId,
    required Map<String, dynamic> params,
    String? fallbackModel,
  }) {
    if (!mounted ||
        usageIdentifier(profileId) == null ||
        usageIdentifier(threadId) == null) {
      return;
    }
    final usage = _map(params['tokenUsage'] ?? params['token_usage']);
    final last = _map(usage?['last']);
    if (last == null) return;
    final metrics = _map(params['requestMetrics']);
    if (metrics?['historical'] == true) return;
    final normalizedProvider = usageIdentifier(provider) ?? '';
    final requestId = usageIdentifier(
      metrics?['requestId'] ?? params['requestId'],
    );
    final turnId = usageIdentifier(params['turnId'] ?? params['turn_id']);
    final counters = _map(metrics?['usage']) ?? last;
    final input = _counter(counters, 'inputTokens', 'input_tokens');
    final output = _counter(counters, 'outputTokens', 'output_tokens');
    final cached = _counter(
      counters,
      'cachedInputTokens',
      'cached_input_tokens',
    );
    final total =
        _counter(counters, 'totalTokens', 'total_tokens') ??
        (input != null && output != null ? usageInteger(input + output) : null);
    if (requestId == null &&
        ![input, output, cached, total].any((value) => (value ?? 0) > 0)) {
      return;
    }
    final cumulative = _map(usage?['total']);
    final cumulativeCounts = cumulative == null
        ? <int?>[]
        : [
            _counter(cumulative, 'inputTokens', 'input_tokens'),
            _counter(cumulative, 'outputTokens', 'output_tokens'),
            _counter(cumulative, 'cachedInputTokens', 'cached_input_tokens'),
            _counter(
              cumulative,
              'reasoningOutputTokens',
              'reasoning_output_tokens',
            ),
            _counter(cumulative, 'totalTokens', 'total_tokens'),
          ];
    if (requestId == null && turnId == null) return;
    final identity = requestId != null
        ? ['request', requestId]
        : cumulativeCounts.any((value) => value != null)
        ? ['cumulative', turnId, ...cumulativeCounts]
        : ['last', turnId, input, output, cached, total];
    final id = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              profileId,
              agent.name,
              normalizedProvider,
              threadId,
              ...identity,
            ]),
          ),
        )
        .toString();
    if (_dismissed.contains(id)) return;
    final now = _nowMillis();
    final started = usageInteger(metrics?['startedAtMillis']);
    final record = RequestUsageRecord(
      id: id,
      profileId: profileId,
      agent: agent,
      provider: normalizedProvider,
      threadId: threadId,
      recordedAtMillis:
          started != null &&
              started > 0 &&
              started <= now + const Duration(minutes: 5).inMilliseconds
          ? started
          : now,
      model:
          usageIdentifier(metrics?['model'] ?? params['model']) ??
          _records[id]?.model ??
          usageIdentifier(fallbackModel),
      inputTokens: input,
      outputTokens: output,
      cachedInputTokens: cached,
      totalTokens: total,
      // These fields describe an upstream model request, NEVER turn timings.
      firstTokenMillis: usageInteger(metrics?['firstTokenMillis']),
      durationMillis: usageInteger(metrics?['durationMillis']),
    );
    final merged = _records[id]?.merge(record) ?? record;
    if (jsonEncode(_records[id]?.toJson()) == jsonEncode(merged.toJson())) {
      return;
    }
    _records[id] = merged;
    _prune();
    _dirty = true;
    _publish();
    _scheduleWrite();
  }

  void _prune() {
    final cutoff = _nowMillis() - const Duration(days: 90).inMilliseconds;
    final ordered = _orderedRecords();
    for (var index = 0; index < ordered.length; index++) {
      final record = ordered[index];
      if (index >= FileRequestUsageStore.maxRecords ||
          record.recordedAtMillis < cutoff) {
        _records.remove(record.id);
        _dismissed.add(record.id);
        _dirty = true;
      }
    }
    while (_dismissed.length > FileRequestUsageStore.maxDismissedIds) {
      _dismissed.remove(_dismissed.first);
    }
  }

  void _publish() {
    if (!mounted) return;
    final records = _orderedRecords();
    state = UsageHistoryState(
      records: List.unmodifiable(records),
      loading: !_loaded,
      error: _error,
    );
  }

  List<RequestUsageRecord> _orderedRecords() {
    final order = {for (final (index, id) in _records.keys.indexed) id: index};
    return _records.values.toList()..sort((a, b) {
      final byTime = b.recordedAtMillis.compareTo(a.recordedAtMillis);
      return byTime != 0 ? byTime : order[b.id]!.compareTo(order[a.id]!);
    });
  }

  void _scheduleWrite() {
    if (!_loaded || _readFailed || !mounted) return;
    _timer?.cancel();
    _timer = Timer(writeDebounce, () => unawaited(flush()));
  }

  Future<bool> clear() async {
    await ready;
    _dismissed.addAll(_records.keys);
    _records.clear();
    // Explicitly confirmed clearing is allowed even if the old file is corrupt.
    _readFailed = false;
    _error = null;
    _prune();
    _dirty = true;
    _publish();
    return flush();
  }

  Future<bool> flush() async {
    _timer?.cancel();
    await ready;
    if (_readFailed) return false;
    if (!_dirty) {
      await _writeTail;
      return _error == null;
    }
    _dirty = false;
    final snapshot = UsageHistorySnapshot(
      records: List.of(_records.values),
      dismissedIds: List.of(_dismissed),
    );
    var success = true;
    _writeTail = _writeTail.then((_) async {
      try {
        await _store.write(snapshot);
        _error = null;
      } catch (_) {
        success = false;
        _error = '本机统计保存失败，重启后可能无法保留；请稍后重试。';
        _dirty = true;
      }
      _publish();
    });
    await _writeTail;
    return success;
  }

  Future<bool> retry() => _retry ??= _retryReadAndSave().whenComplete(() {
    _retry = null;
  });

  Future<bool> _retryReadAndSave() async {
    await ready;
    if (_readFailed) {
      _loaded = false;
      _publish();
      await _load();
    }
    return flush();
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(flush());
    super.dispose();
  }

  static Map<String, dynamic>? _map(Object? value) => value is Map
      ? Map<String, dynamic>.fromEntries(
          value.entries
              .where((entry) => entry.key is String)
              .map((entry) => MapEntry(entry.key as String, entry.value)),
        )
      : null;

  static int? _counter(
    Map<String, dynamic> value,
    String camel,
    String snake,
  ) => usageInteger(value[camel] ?? value[snake]);
}
