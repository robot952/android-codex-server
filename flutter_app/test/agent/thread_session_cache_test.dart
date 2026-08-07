import 'package:codex_remote/src/agent/thread_session_cache.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  var now = 1_000;

  AgentThread thread(String id, {String title = ''}) =>
      AgentThread(id: id, title: title);

  TimelineEntry entry(String id, String text) =>
      TimelineEntry(id: id, kind: TimelineKind.agentMessage, text: text);

  test('returns fresh entries and keeps expired entries as stale fallback', () {
    final cache = ThreadSessionCache(
      ttl: const Duration(milliseconds: 100),
      nowEpochMillis: () => now,
    );
    cache.put(thread('one'), [entry('message', 'hello')]);

    expect(cache.get('one')?.timeline.single.text, 'hello');
    now += 101;
    expect(cache.get('one'), isNull);
    expect(cache.getStale('one')?.timeline.single.text, 'hello');
  });

  test('evicts the least recently used transcript', () {
    final cache = ThreadSessionCache(maxEntries: 2, nowEpochMillis: () => now);
    cache.put(thread('one'), const []);
    cache.put(thread('two'), const []);
    expect(cache.get('one'), isNotNull);

    cache.put(thread('three'), const []);

    expect(cache.getStale('one'), isNotNull);
    expect(cache.getStale('two'), isNull);
    expect(cache.getStale('three'), isNotNull);
  });

  test('bounds transcript weight and preserves valid context usage', () {
    final cache = ThreadSessionCache(
      maxWeightChars: 80,
      nowEpochMillis: () => now,
    );
    const usage = TokenUsage(modelContextWindow: 200000);

    cache.put(thread('large'), [
      entry('message', List.filled(100, 'x').join()),
    ], tokenUsage: usage);

    expect(cache.getStale('large'), isNull);
    expect(cache.contextUsage('large'), usage);
  });

  test('keeps caches isolated per server lane', () {
    final first = ThreadSessionCache(nowEpochMillis: () => now);
    final second = ThreadSessionCache(nowEpochMillis: () => now);
    first.put(thread('shared', title: 'first'), const []);
    second.put(thread('shared', title: 'second'), const []);

    expect(first.get('shared')?.thread.title, 'first');
    expect(second.get('shared')?.thread.title, 'second');
    first.clear();
    expect(second.get('shared')?.thread.title, 'second');
  });

  test('remove clears both transcript and context usage', () {
    final cache = ThreadSessionCache(nowEpochMillis: () => now);
    cache.put(
      thread('one'),
      const [],
      tokenUsage: const TokenUsage(modelContextWindow: 1000),
    );

    cache.remove('one');

    expect(cache.getStale('one'), isNull);
    expect(cache.contextUsage('one'), isNull);
  });
}
