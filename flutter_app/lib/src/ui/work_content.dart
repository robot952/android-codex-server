import '../domain/models.dart';

const Set<String> _imageExtensions = <String>{
  '.png',
  '.jpg',
  '.jpeg',
  '.webp',
  '.gif',
  '.bmp',
};

bool isPreviewableImagePath(String path) {
  final lower = path.trim().toLowerCase();
  return lower.startsWith('/') && _imageExtensions.any(lower.endsWith);
}

const Set<String> _textAttachmentExtensions = <String>{
  'cfg',
  'conf',
  'csv',
  'css',
  'env',
  'gradle',
  'html',
  'ini',
  'java',
  'js',
  'json',
  'jsonl',
  'kt',
  'kts',
  'log',
  'markdown',
  'md',
  'properties',
  'py',
  'sh',
  'sql',
  'toml',
  'ts',
  'tsx',
  'txt',
  'xml',
  'yaml',
  'yml',
};

String attachmentMimeType(String name, {bool forceImage = false}) {
  final extension = name.split('.').last.toLowerCase();
  return switch (extension) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'webp' => 'image/webp',
    'gif' => 'image/gif',
    'bmp' => 'image/bmp',
    'heic' => 'image/heic',
    'heif' => 'image/heif',
    _ when forceImage => 'image/*',
    _ when _textAttachmentExtensions.contains(extension) => 'text/plain',
    _ => 'application/octet-stream',
  };
}

bool isTextAttachment(String name, String mimeType) {
  if (mimeType.split(';').first.trim().toLowerCase().startsWith('text/')) {
    return true;
  }
  final extension = name.split('.').last.toLowerCase();
  return _textAttachmentExtensions.contains(extension);
}

/// Returns the remote path exposed by Codex image-view tools. This mirrors the
/// Kotlin screen's conservative allow-list so arbitrary tool output is never
/// offered to the image decoder.
String? imagePreviewPath(TimelineEntry entry) {
  if (entry.kind != TimelineKind.tool) return null;
  final toolName = entry.title.trim().toLowerCase();
  if (!const <String>{
    'imageview',
    'view_image',
    'image viewer',
    '查看图片',
    '查看了图片',
  }.contains(toolName)) {
    return null;
  }
  for (final content in <String>[entry.text, entry.output]) {
    for (final line in content.split(RegExp(r'\r?\n'))) {
      final path = line.trim().replaceFirst(RegExp(r'^file://'), '');
      final unquoted =
          path.length >= 2 && path.startsWith('"') && path.endsWith('"')
          ? path.substring(1, path.length - 1)
          : path;
      if (isPreviewableImagePath(unquoted)) {
        return unquoted;
      }
    }
  }
  return null;
}

String imageMimeType(String path) {
  final extension = path.split('.').last.toLowerCase();
  return switch (extension) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'webp' => 'image/webp',
    'gif' => 'image/gif',
    'bmp' => 'image/bmp',
    _ => 'image/png',
  };
}

String imageFileName(String path) {
  final candidate = path.split('/').last.trim();
  if (candidate.isEmpty) {
    return 'codex-${DateTime.now().millisecondsSinceEpoch}.png';
  }
  final safe = candidate.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');
  return safe.length <= 120 ? safe : safe.substring(safe.length - 120);
}
