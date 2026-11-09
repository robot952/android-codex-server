import 'dart:async';
import 'dart:typed_data';

typedef ImageReadProgress = void Function(int receivedBytes, int totalBytes);
typedef RemoteImageCacheKey = ({
  String profileId,
  Object connection,
  String path,
  int maxBytes,
});

/// Encoded image bytes shared across Work pages for the lifetime of a host
/// connection. Recency is based on viewing, not download order.
class RemoteImageCache {
  RemoteImageCache({this.maxEntries = 20, this.maxBytes = 64 * 1024 * 1024})
    : assert(maxEntries > 0),
      assert(maxBytes > 0);

  final int maxEntries;
  final int maxBytes;
  final _images = <RemoteImageCacheKey, Uint8List>{};
  final _pending = <RemoteImageCacheKey, _ImageRead>{};
  int _byteCount = 0;

  Future<Uint8List> read(
    RemoteImageCacheKey key, {
    required Future<Uint8List> Function(ImageReadProgress progress) load,
    ImageReadProgress? onProgress,
    bool forceReload = false,
  }) {
    final cached = _images.remove(key);
    if (cached != null) {
      if (!forceReload) {
        _images[key] = cached;
        onProgress?.call(cached.length, cached.length);
        return Future.value(cached);
      }
      _byteCount -= cached.length;
    }
    final pending = _pending[key];
    if (!forceReload && pending != null) {
      pending.listen(onProgress);
      return pending.result;
    }

    final request = _ImageRead()..listen(onProgress);
    _pending[key] = request;
    request.result = Future.sync(() => load(request.report))
        .then((bytes) {
          if (bytes.isEmpty || bytes.length > key.maxBytes) {
            throw StateError('图片大小无效或超过预览限制');
          }
          // Retain one stable, immutable buffer so Flutter can also reuse its
          // decoded MemoryImage when the same preview is opened again.
          final image = Uint8List.fromList(bytes).asUnmodifiableView();
          if (identical(_pending[key], request) && image.length <= maxBytes) {
            _images[key] = image;
            _byteCount += image.length;
            while (_images.length > maxEntries || _byteCount > maxBytes) {
              _byteCount -= _images.remove(_images.keys.first)!.length;
            }
          }
          return image;
        })
        .whenComplete(() {
          if (identical(_pending[key], request)) _pending.remove(key);
          request.listeners.clear();
        });
    return request.result;
  }

  void clearProfile(String profileId) {
    _images.removeWhere((key, bytes) {
      if (key.profileId != profileId) return false;
      _byteCount -= bytes.length;
      return true;
    });
    _pending.removeWhere((key, request) {
      if (key.profileId != profileId) return false;
      request.listeners.clear();
      return true;
    });
  }

  void clear() {
    _images.clear();
    _byteCount = 0;
    for (final request in _pending.values) {
      request.listeners.clear();
    }
    _pending.clear();
  }
}

class _ImageRead {
  late final Future<Uint8List> result;
  final listeners = <ImageReadProgress>[];
  (int, int)? progress;

  void listen(ImageReadProgress? listener) {
    if (listener == null) return;
    listeners.add(listener);
    final latest = progress;
    if (latest != null) listener(latest.$1, latest.$2);
  }

  void report(int receivedBytes, int totalBytes) {
    progress = (receivedBytes, totalBytes);
    for (final listener in List<ImageReadProgress>.of(listeners)) {
      listener(receivedBytes, totalBytes);
    }
  }
}
