import 'package:flutter/services.dart';

abstract interface class LocalFileExporter {
  Future<LocalFileExportSession?> begin({
    required String fileName,
    String mimeType = 'application/octet-stream',
  });
}

abstract interface class LocalFileExportSession {
  Future<void> write(Uint8List bytes);
  Future<void> complete();
  Future<void> abort();
}

class AndroidLocalFileExporter implements LocalFileExporter {
  const AndroidLocalFileExporter({
    this.channel = const MethodChannel(_channelName),
  });

  static const String _channelName = 'top.asdb.agent/file_export';
  final MethodChannel channel;

  @override
  Future<LocalFileExportSession?> begin({
    required String fileName,
    String mimeType = 'application/octet-stream',
  }) async {
    final response = await channel.invokeMapMethod<String, Object?>(
      'beginExport',
      <String, Object?>{'fileName': fileName, 'mimeType': mimeType},
    );
    final token = response?['token'];
    if (token is! String || token.isEmpty) return null;
    return _AndroidLocalFileExportSession(channel, token);
  }
}

class _AndroidLocalFileExportSession implements LocalFileExportSession {
  _AndroidLocalFileExportSession(this._channel, this._token);

  static const int _maxChannelChunkBytes = 256 * 1024;
  final MethodChannel _channel;
  final String _token;
  bool _closed = false;

  @override
  Future<void> write(Uint8List bytes) async {
    if (_closed) throw StateError('本地文件已经关闭');
    if (bytes.isEmpty) return;
    if (bytes.length > _maxChannelChunkBytes) {
      throw StateError('本地文件写入分块过大');
    }
    await _channel.invokeMethod<void>('writeExportChunk', <String, Object?>{
      'token': _token,
      'bytes': bytes,
    });
  }

  @override
  Future<void> complete() => _finish(successful: true);

  @override
  Future<void> abort() => _finish(successful: false);

  Future<void> _finish({required bool successful}) async {
    if (_closed) return;
    _closed = true;
    await _channel.invokeMethod<void>('finishExport', <String, Object?>{
      'token': _token,
      'successful': successful,
    });
  }
}
