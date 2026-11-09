import 'dart:async';
import 'dart:typed_data';

import 'package:codex_remote/src/ssh/remote_image_cache.dart';
import 'package:flutter_test/flutter_test.dart';

RemoteImageCacheKey key(
  String path, {
  String profile = 'a',
  int generation = 1,
}) => (profileId: profile, connection: generation, path: path, maxBytes: 100);

void main() {
  test(
    'retains the 20 most recently viewed images with stable immutable bytes',
    () async {
      final cache = RemoteImageCache();
      final reads = <String>[];
      Future<Uint8List> read(String path) => cache.read(
        key(path),
        load: (_) async {
          reads.add(path);
          return Uint8List.fromList([1, 2, 3]);
        },
      );
      final first = await read('0');
      for (var i = 1; i < 20; i++) {
        await read('$i');
      }
      expect(await read('0'), same(first));
      expect(() => first[0] = 9, throwsUnsupportedError);
      await read('20');
      expect(await read('0'), same(first));
      expect(reads.length, 21);
      await read('1');
      expect(reads.length, 22);
      expect(reads.last, '1');
    },
  );

  test('evicts by byte budget and does not retain oversized images', () async {
    final cache = RemoteImageCache(maxBytes: 5);
    var reads = 0;
    Future<Uint8List> read(String path, int length) => cache.read(
      key(path),
      load: (_) async {
        reads++;
        return Uint8List(length);
      },
    );
    await read('a', 3);
    await read('b', 3);
    await read('b', 3);
    expect(reads, 2);
    await read('a', 3);
    expect(reads, 3);
    await read('large', 6);
    await read('large', 6);
    expect(reads, 5);
    await read('a', 3);
    expect(reads, 5);
  });

  test('isolates server, connection generation and byte limits', () async {
    final cache = RemoteImageCache();
    var reads = 0;
    Future<Uint8List> read(RemoteImageCacheKey key) => cache.read(
      key,
      load: (_) async {
        reads++;
        return Uint8List(2);
      },
    );
    await read(key('/same.png'));
    await read(key('/same.png', profile: 'b'));
    await read(key('/same.png', generation: 2));
    await read((profileId: 'a', connection: 1, path: '/same.png', maxBytes: 3));
    expect(reads, 4);
    await read(key('/same.png'));
    expect(reads, 4);
  });

  test(
    'shares pending downloads and reports progress to every viewer',
    () async {
      final cache = RemoteImageCache();
      final pending = Completer<Uint8List>();
      late ImageReadProgress report;
      final firstProgress = <(int, int)>[];
      final secondProgress = <(int, int)>[];
      final first = cache.read(
        key('a'),
        load: (progress) {
          report = progress;
          return pending.future;
        },
        onProgress: (a, b) => firstProgress.add((a, b)),
      );
      report(1, 2);
      final second = cache.read(
        key('a'),
        load: (_) => throw StateError('duplicate read'),
        onProgress: (a, b) => secondProgress.add((a, b)),
      );
      report(2, 2);
      pending.complete(Uint8List(2));
      expect(await second, same(await first));
      expect(firstProgress, [(1, 2), (2, 2)]);
      expect(secondProgress, firstProgress);
      final hits = <(int, int)>[];
      await cache.read(
        key('a'),
        load: (_) => throw StateError('cache miss'),
        onProgress: (a, b) => hits.add((a, b)),
      );
      expect(hits, [(2, 2)]);
    },
  );

  test(
    'refresh replaces cached content and ignores older pending results',
    () async {
      final cache = RemoteImageCache();
      final pending = Completer<Uint8List>();
      final old = cache.read(key('a'), load: (_) => pending.future);
      final refreshed = await cache.read(
        key('a'),
        forceReload: true,
        load: (_) async => Uint8List.fromList([2]),
      );
      pending.complete(Uint8List.fromList([1]));
      await old;
      expect(
        await cache.read(key('a'), load: (_) => throw StateError('cache miss')),
        same(refreshed),
      );
      final newer = await cache.read(
        key('a'),
        forceReload: true,
        load: (_) async => Uint8List.fromList([3]),
      );
      expect(newer, [3]);
      expect(
        await cache.read(key('a'), load: (_) => throw StateError('cache miss')),
        same(newer),
      );
    },
  );

  test(
    'failures and invalid responses are retried, including failed refresh',
    () async {
      final cache = RemoteImageCache();
      await cache.read(key('a'), load: (_) async => Uint8List(2));
      await expectLater(
        cache.read(
          key('a'),
          forceReload: true,
          load: (_) => throw StateError('download failed'),
        ),
        throwsStateError,
      );
      await expectLater(
        cache.read(key('a'), load: (_) async => Uint8List(0)),
        throwsStateError,
      );
      await expectLater(
        cache.read(key('a'), load: (_) async => Uint8List(101)),
        throwsStateError,
      );
      expect(
        await cache.read(key('a'), load: (_) async => Uint8List.fromList([7])),
        [7],
      );
    },
  );

  test(
    'profile removal and shutdown cannot be undone by a late download',
    () async {
      for (final clearAll in [false, true]) {
        final cache = RemoteImageCache();
        final pending = Completer<Uint8List>();
        final old = cache.read(key('a'), load: (_) => pending.future);
        final other = await cache.read(
          key('a', profile: 'b'),
          load: (_) async => Uint8List(1),
        );
        if (clearAll) {
          cache.clear();
        } else {
          cache.clearProfile('a');
        }
        pending.complete(Uint8List.fromList([1]));
        await old;
        expect(
          await cache.read(
            key('a'),
            load: (_) async => Uint8List.fromList([2]),
          ),
          [2],
        );
        if (!clearAll) {
          expect(
            await cache.read(
              key('a', profile: 'b'),
              load: (_) => throw StateError('other cleared'),
            ),
            same(other),
          );
        }
      }
    },
  );
}
