import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:codex_remote/src/agent/thread_session_cache.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/persistence/thread_snapshot_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late int now;
  final key = Uint8List.fromList(List.generate(32, (i) => i + 1));

  EncryptedThreadSnapshotStore store({
    Uint8List? encryptionKey,
    Future<Uint8List> Function()? keyProvider,
    int maxPlainBytes = 4 * 1024 * 1024,
    int maxFileBytes = 1024 * 1024,
    int maxTotalBytes = 8 * 1024 * 1024,
    int maxEntries = 16,
    Duration debounce = Duration.zero,
  }) => EncryptedThreadSnapshotStore(
    directoryProvider: () async => directory,
    keyProvider: keyProvider ?? () async => encryptionKey ?? key,
    nowEpochMillis: () => now,
    writeDebounce: debounce,
    maxPlainBytes: maxPlainBytes,
    maxFileBytes: maxFileBytes,
    maxTotalBytes: maxTotalBytes,
    maxEntries: maxEntries,
  );

  ThreadSessionSnapshot snapshot({
    String id = 'thread',
    String text = 'Private conversation 机密内容',
    int? savedAt,
  }) => ThreadSessionSnapshot(
    thread: AgentThread(id: id, title: 'Cached task'),
    timeline: [
      TimelineEntry(id: 'message', kind: TimelineKind.agentMessage, text: text),
    ],
    savedAtEpochMillis: savedAt ?? now,
  );

  File file(String scope, String threadId) {
    String hash(String value) => sha256.convert(utf8.encode(value)).toString();
    return File('${directory.path}/${hash(scope)}_${hash(threadId)}.snapshot');
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('thread-cache-test-');
    now = DateTime.now().millisecondsSinceEpoch;
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test(
    'round trips all display fields across store instances without ownership',
    () async {
      final original = ThreadSessionSnapshot(
        thread: const AgentThread(
          id: 'child-thread',
          title: 'child',
          preview: 'preview',
          cwd: '/work',
          source: 'subAgent',
          modelProvider: 'custom',
          status: 'active',
          createdAt: 12,
          updatedAt: 19,
          cliVersion: '1',
          activeTurnId: 'turn',
          isExternallyOwned: true,
        ),
        timeline: TimelineKind.values
            .map(
              (kind) => TimelineEntry(
                id: kind.name,
                kind: kind,
                title: 'title',
                text: 'text 中文',
                status: 'completed',
                command: 'pwd',
                cwd: '/work',
                output: 'result',
                turnId: 'turn',
                subAgentPath: '/root/child',
                subAgentThreadId: 'nested',
                subAgentActivity: 'spawn',
                reasoningSummary: ['summary'],
                reasoningContent: ['reasoning'],
                changes: [
                  const FileChange(
                    path: 'file',
                    kind: 'update',
                    diff: '+one\n-two',
                  ),
                ],
                attachments: [
                  const MessageAttachment(
                    name: 'image',
                    remotePath: '/image',
                    mimeType: 'image/png',
                  ),
                ],
                questions: [
                  const InputQuestion(
                    id: 'question',
                    header: 'header',
                    question: 'Choice?',
                    isOther: true,
                    isSecret: true,
                    options: [InputOption(label: 'one', description: 'first')],
                  ),
                ],
              ),
            )
            .toList(),
        savedAtEpochMillis: now,
        nextTurnsCursor: 'older-cursor',
        tokenUsage: const TokenUsage(
          last: TokenUsageBreakdown(
            cachedInputTokens: 1,
            inputTokens: 2,
            outputTokens: 3,
            reasoningOutputTokens: 4,
            totalTokens: 5,
          ),
          total: TokenUsageBreakdown(
            cachedInputTokens: 6,
            inputTokens: 7,
            outputTokens: 8,
            reasoningOutputTokens: 9,
            totalTokens: 10,
          ),
          modelContextWindow: 100,
        ),
      );
      await store().write('scope', original);
      final restored = await store().read('scope', original.thread.id);
      expect(restored, isNotNull);
      expect(
        restored!.thread,
        original.thread.copyWith(isExternallyOwned: false),
      );
      expect(restored.timeline, original.timeline);
      expect(restored.nextTurnsCursor, original.nextTurnsCursor);
      expect(restored.savedAtEpochMillis, now);
      expect(restored.tokenUsage, original.tokenUsage);
    },
  );

  test(
    'compresses repetitive histories before randomized authenticated encryption',
    () async {
      final value = snapshot(
        text: List.filled(10000, 'sensitive repeated text').join(),
      );
      final cache = store();
      await cache.write('private-scope', value);
      final first = await file('private-scope', 'thread').readAsBytes();
      expect(first.length, lessThan(value.timeline.single.text.length ~/ 20));
      expect(latin1.decode(first), isNot(contains('sensitive')));
      expect(latin1.decode(first), isNot(contains('private-scope')));
      await cache.write('private-scope', value);
      final second = await file('private-scope', 'thread').readAsBytes();
      expect(second, isNot(first));
      expect(
        (await cache.read('private-scope', 'thread'))!.timeline,
        value.timeline,
      );
    },
  );

  test(
    'rejects a wrong key, modified ciphertext and cross-scope or thread replay',
    () async {
      final cache = store();
      await cache.write('scope', snapshot());
      final bytes = await file('scope', 'thread').readAsBytes();
      expect(
        await store(encryptionKey: Uint8List(32)).read('scope', 'thread'),
        isNull,
      );
      await file('other', 'thread').writeAsBytes(bytes);
      await file('scope', 'other-thread').writeAsBytes(bytes);
      expect(await cache.read('other', 'thread'), isNull);
      expect(await cache.read('scope', 'other-thread'), isNull);
      bytes[bytes.length - 1] ^= 1;
      await file('scope', 'thread').writeAsBytes(bytes);
      expect(await cache.read('scope', 'thread'), isNull);
    },
  );

  test(
    'treats missing, truncated and unsupported files or inaccessible keys as misses',
    () async {
      final cache = store();
      expect(await cache.read('scope', 'missing'), isNull);
      await file('scope', 'thread').writeAsBytes([1, 2, 3]);
      expect(await cache.read('scope', 'thread'), isNull);
      await cache.write('scope', snapshot());
      final bytes = await file('scope', 'thread').readAsBytes();
      bytes[0] = 99;
      await file('scope', 'thread').writeAsBytes(bytes);
      expect(await cache.read('scope', 'thread'), isNull);
      await cache.write('scope', snapshot());
      final unavailable = store(
        keyProvider: () async => throw StateError('locked'),
      );
      expect(await unavailable.read('scope', 'thread'), isNull);
      await unavailable.write('scope', snapshot(id: 'other'));
      expect(await file('scope', 'other').exists(), isFalse);
    },
  );

  test(
    'expires authenticated saved time even if file timestamp is refreshed',
    () async {
      final cache = store();
      await cache.write('scope', snapshot());
      now += const Duration(days: 8).inMilliseconds;
      await file(
        'scope',
        'thread',
      ).setLastModified(DateTime.fromMillisecondsSinceEpoch(now));
      expect(await cache.read('scope', 'thread'), isNull);
      now = DateTime.now().millisecondsSinceEpoch;
      await cache.write(
        'scope',
        snapshot(savedAt: now + const Duration(hours: 1).inMilliseconds),
      );
      expect(await file('scope', 'thread').exists(), isTrue);
      expect(await cache.read('scope', 'thread'), isNull);
    },
  );

  test(
    'plain overflow replaces the previous cached transcript with a miss',
    () async {
      final cache = store(maxPlainBytes: 2048);
      await cache.write('scope', snapshot());
      expect(await cache.read('scope', 'thread'), isNotNull);
      await cache.write('scope', snapshot(text: List.filled(4096, 'a').join()));
      expect(await cache.read('scope', 'thread'), isNull);
      expect(await file('scope', 'thread').exists(), isFalse);
      // UTF-8 exceeds the limit even when the cheap character preflight fits.
      await cache.write('scope', snapshot());
      await cache.write('scope', snapshot(text: List.filled(900, '汉').join()));
      expect(await file('scope', 'thread').exists(), isFalse);
    },
  );

  test('ciphertext overflow removes the older smaller file', () async {
    final cache = store(maxFileBytes: 600);
    await cache.write('scope', snapshot());
    expect(await cache.read('scope', 'thread'), isNotNull);
    final random = Random(1);
    final noise = base64Encode(List.generate(4096, (_) => random.nextInt(256)));
    await cache.write('scope', snapshot(text: noise));
    expect(await file('scope', 'thread').exists(), isFalse);
  });

  test('bounds encrypted file reads and expanded gzip size', () async {
    await store().write(
      'scope',
      snapshot(text: List.filled(100000, 'x').join()),
    );
    expect(await store(maxFileBytes: 32).read('scope', 'thread'), isNull);
    expect(await store(maxPlainBytes: 2048).read('scope', 'thread'), isNull);
  });

  test(
    'coalesces queued writes and avoids reading the previous file mid-write',
    () async {
      final cache = store(debounce: const Duration(milliseconds: 20));
      await cache.write('scope', snapshot(text: 'old'));
      final first = cache.write('scope', snapshot(text: 'intermediate'));
      final last = cache.write('scope', snapshot(text: 'newest'));
      expect(identical(first, last), isTrue);
      expect(await cache.read('scope', 'thread'), isNull);
      await last;
      expect(
        (await cache.read('scope', 'thread'))!.timeline.single.text,
        'newest',
      );
    },
  );

  test(
    'caps queued count and retained files with oldest-first eviction',
    () async {
      final cache = store(
        maxEntries: 2,
        debounce: const Duration(milliseconds: 20),
      );
      await Future.wait([
        cache.write('scope', snapshot(id: 'first')),
        cache.write('scope', snapshot(id: 'second')),
        cache.write('scope', snapshot(id: 'third')),
      ]);
      expect(await cache.read('scope', 'first'), isNull);
      expect(await cache.read('scope', 'second'), isNotNull);
      expect(await cache.read('scope', 'third'), isNotNull);
      await file(
        'scope',
        'second',
      ).setLastModified(DateTime.fromMillisecondsSinceEpoch(now - 10000));
      await cache.write('scope', snapshot(id: 'fourth'));
      expect(await cache.read('scope', 'second'), isNull);
      expect(await cache.read('scope', 'third'), isNotNull);
      expect(await cache.read('scope', 'fourth'), isNotNull);
    },
  );

  test(
    'bounds pending transcript weight as well as encrypted total bytes',
    () async {
      final cache = store(
        maxPlainBytes: 4096,
        debounce: const Duration(milliseconds: 20),
      );
      await Future.wait(
        List.generate(
          4,
          (i) => cache.write(
            'scope',
            snapshot(id: '$i', text: List.filled(2500, 'x').join()),
          ),
        ),
      );
      expect(await cache.read('scope', '0'), isNull);
      expect(await cache.read('scope', '1'), isNull);
      expect(await cache.read('scope', '3'), isNotNull);
      final limited = store(maxTotalBytes: 500);
      await limited.write('scope', snapshot(id: 'small'));
      final files = await directory
          .list()
          .where((f) => f.path.endsWith('.snapshot'))
          .toList();
      var bytes = 0;
      for (final entry in files) {
        bytes += (await entry.stat()).size;
      }
      expect(bytes, lessThanOrEqualTo(500));
    },
  );

  test(
    'remove invalidates an active write and allows a later replacement',
    () async {
      final entered = Completer<void>();
      final release = Completer<Uint8List>();
      var calls = 0;
      final cache = store(
        keyProvider: () {
          if (calls++ == 0) {
            entered.complete();
            return release.future;
          }
          return Future.value(key);
        },
      );
      final first = cache.write('scope', snapshot(text: 'removed'));
      await entered.future;
      final remove = cache.remove('scope', 'thread');
      final replacement = cache.write('scope', snapshot(text: 'after removal'));
      release.complete(key);
      await Future.wait([first, remove, replacement]);
      expect(
        (await cache.read('scope', 'thread'))!.timeline.single.text,
        'after removal',
      );
    },
  );

  test(
    'scope removal cancels active and pending saves without deleting another scope',
    () async {
      await store().write('other-scope', snapshot());
      final entered = Completer<void>();
      final release = Completer<Uint8List>();
      var calls = 0;
      final cache = store(
        keyProvider: () {
          if (calls++ == 0) {
            entered.complete();
            return release.future;
          }
          return Future.value(key);
        },
      );
      final active = cache.write('scope', snapshot());
      await entered.future;
      final queued = cache.write('scope', snapshot(id: 'queued'));
      final cleared = cache.removeScope('scope');
      release.complete(key);
      await Future.wait([active, queued, cleared]);
      expect(await cache.read('scope', 'thread'), isNull);
      expect(await cache.read('scope', 'queued'), isNull);
      expect(await cache.read('other-scope', 'thread'), isNotNull);
    },
  );

  test(
    'scope removal rejects an in-flight read and cannot resurrect deleted data',
    () async {
      await store().write('scope', snapshot());
      final entered = Completer<void>();
      final release = Completer<Uint8List>();
      final cache = store(
        keyProvider: () {
          entered.complete();
          return release.future;
        },
      );
      final reading = cache.read('scope', 'thread');
      await entered.future;
      final clearing = cache.removeScope('scope');
      release.complete(key);
      expect(await reading, isNull);
      await clearing;
      expect(await file('scope', 'thread').exists(), isFalse);
    },
  );
}
