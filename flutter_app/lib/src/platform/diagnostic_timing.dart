import 'dart:async';

enum TimingStatus { success, failed, timeout, stale, skipped }

/// Low-frequency operation timing, not model request/first-token timing.
/// Only fixed stage labels, opaque identifiers and numeric metadata are logged.
/// The sink retains its existing Debug switch, redaction and rotation policy.
class DiagnosticTiming {
  DiagnosticTiming.start({
    required String stage,
    required this.log,
    String? profileId,
    String? agent,
    String? threadId,
    int? generation,
  }) : _identity =
           'timing operation=${++_sequence} stage=${_field(stage)}'
           '${profileId == null ? '' : ' profile=${_field(profileId)}'}'
           '${agent == null ? '' : ' agent=${_field(agent)}'}'
           '${threadId == null ? '' : ' thread=${_field(threadId)}'}'
           '${generation == null ? '' : ' generation=$generation'}' {
    _emit('status=started elapsedMs=0');
  }

  static int _sequence = 0;
  static final _safeField = RegExp(r'^[a-zA-Z0-9_.:/-]+$');
  final void Function(String) log;
  final String _identity;
  final Stopwatch _watch = Stopwatch()..start();
  bool _finished = false;

  static String _field(String value) {
    if (value.isEmpty ||
        value.length > 128 ||
        !_safeField.hasMatch(value) ||
        value.contains('://') ||
        value.startsWith('/')) {
      return 'redacted';
    }
    return value;
  }

  Future<T> run<T>(Future<T> Function() operation) async {
    try {
      final result = await operation();
      finish();
      return result;
    } catch (error) {
      fail(error);
      rethrow;
    }
  }

  void fail(Object error) => finish(
    status: error is TimeoutException
        ? TimingStatus.timeout
        : TimingStatus.failed,
  );

  void finish({
    TimingStatus status = TimingStatus.success,
    int? count,
    bool? hasMore,
    bool? cacheHit,
  }) {
    if (_finished) return;
    _finished = true;
    _watch.stop();
    _emit(
      'status=${status.name} elapsedMs=${_watch.elapsedMilliseconds}'
      '${count == null ? '' : ' count=${count < 0 ? 0 : count}'}'
      '${hasMore == null ? '' : ' hasMore=$hasMore'}'
      '${cacheHit == null ? '' : ' cacheHit=$cacheHit'}',
    );
  }

  void _emit(String fields) {
    try {
      log('$_identity $fields');
    } catch (_) {
      // Diagnostics must not change operation success, errors or cleanup.
    }
  }
}
