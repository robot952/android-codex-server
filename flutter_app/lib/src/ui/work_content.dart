import '../domain/models.dart';

/// Codex may emit this English guidance as a separate assistant item after
/// context compaction. The timeline already shows the localized compaction
/// status, so the duplicate backend guidance should stay out of the UI.
bool isContextCompactionSummary(String text) {
  final normalized = text.trim().toLowerCase();
  return normalized.contains('model to be less accurate') &&
      normalized.contains('start a new thread');
}

final RegExp _thinkingTagPattern = RegExp(
  r'<\s*(/?)\s*think(?:ing)?\s*>',
  caseSensitive: false,
);

/// Normalizes provider-specific thinking markup before timeline rows are built.
///
/// Some OpenAI-compatible providers include literal `<think>` or `<thinking>`
/// blocks in assistant text even when the protocol already emits reasoning
/// items. Assistant blocks are internal drafts and stay hidden; reasoning rows
/// retain their content but do not expose the raw tags.
List<TimelineEntry> normalizeTimelineEntriesForDisplay(
  Iterable<TimelineEntry> entries,
) {
  final result = <TimelineEntry>[];
  for (final entry in entries) {
    if (isContextCompactionSummary(entry.text)) continue;
    final normalized = switch (entry.kind) {
      TimelineKind.agentMessage => _normalizeAgentMessage(entry),
      TimelineKind.reasoning => _normalizeReasoning(entry),
      _ => entry,
    };
    if (normalized != null) result.add(normalized);
  }
  return List<TimelineEntry>.unmodifiable(result);
}

TimelineEntry? _normalizeAgentMessage(TimelineEntry entry) {
  final text = _removeThinkingDrafts(entry.text);
  if (text.isEmpty && entry.attachments.isEmpty) return null;
  return text == entry.text ? entry : entry.copyWith(text: text);
}

TimelineEntry? _normalizeReasoning(TimelineEntry entry) {
  final summary = entry.reasoningSummary
      .map(_removeThinkingMarkers)
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
  final content = entry.reasoningContent
      .map(_removeThinkingMarkers)
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
  var text = _removeThinkingMarkers(entry.text);
  if (text.isEmpty) {
    text = <String>[...summary, ...content].join('\n').trim();
  }
  if (text.isEmpty) return null;
  return entry.copyWith(
    text: text,
    reasoningSummary: List<String>.unmodifiable(summary),
    reasoningContent: List<String>.unmodifiable(content),
  );
}

String _removeThinkingMarkers(String text) =>
    text.replaceAll(_thinkingTagPattern, '').trim();

String _removeThinkingDrafts(String text) {
  final matches = _thinkingTagPattern.allMatches(text).toList(growable: false);
  if (matches.isEmpty) return text;

  final visible = StringBuffer();
  var cursor = 0;
  var depth = 0;
  for (final match in matches) {
    if (depth == 0) visible.write(text.substring(cursor, match.start));
    final closing = (match.group(1) ?? '').isNotEmpty;
    if (closing) {
      if (depth > 0) depth -= 1;
    } else {
      depth += 1;
    }
    cursor = match.end;
  }
  if (depth == 0) visible.write(text.substring(cursor));
  return visible.toString().trim();
}

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
