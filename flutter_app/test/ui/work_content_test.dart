import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/ui/work_content.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('hides the backend context-compaction guidance only', () {
    expect(
      isContextCompactionSummary(
        'Head off long conversations before they cause the model to be less accurate. '
        'Start a new thread when possible to keep threads small and targeted.',
      ),
      isTrue,
    );
    expect(isContextCompactionSummary('上下文已压缩'), isFalse);
    expect(isContextCompactionSummary('正常的英文回复'), isFalse);
  });

  test('recognizes image-view tool paths from text and output', () {
    expect(
      imagePreviewPath(
        const TimelineEntry(
          id: 'image-1',
          kind: TimelineKind.tool,
          title: 'imageView',
          text: '/tmp/codex-preview.png',
        ),
      ),
      '/tmp/codex-preview.png',
    );
    expect(
      imagePreviewPath(
        const TimelineEntry(
          id: 'image-2',
          kind: TimelineKind.tool,
          title: 'view_image',
          output: 'file:///tmp/screenshot.webp',
        ),
      ),
      '/tmp/screenshot.webp',
    );
    expect(
      imagePreviewPath(
        const TimelineEntry(
          id: 'image-3',
          kind: TimelineKind.tool,
          title: '查看了图片',
          text: '"/tmp/screenshot.jpg"',
        ),
      ),
      '/tmp/screenshot.jpg',
    );
  });

  test('rejects non-image tool output and maps image mime types', () {
    expect(
      imagePreviewPath(
        const TimelineEntry(
          id: 'command',
          kind: TimelineKind.tool,
          title: 'exec_command',
          text: '/tmp/result.txt',
        ),
      ),
      isNull,
    );
    expect(imageMimeType('/tmp/screenshot.JPG'), 'image/jpeg');
    expect(imageMimeType('/tmp/screenshot.webp'), 'image/webp');
    expect(imageMimeType('/tmp/screenshot.png'), 'image/png');
    expect(isPreviewableImagePath('/tmp/SCREENSHOT.PNG'), isTrue);
    expect(isPreviewableImagePath('/tmp/archive.zip'), isFalse);
    expect(isPreviewableImagePath('relative.png'), isFalse);
  });

  test('sanitizes remote names before opening the platform save dialog', () {
    expect(imageFileName('/tmp/a:b?.png'), 'a_b_.png');
  });

  test('classifies picked images and inline text attachments', () {
    expect(attachmentMimeType('SCREENSHOT.JPG'), 'image/jpeg');
    expect(attachmentMimeType('notes.md'), 'text/plain');
    expect(attachmentMimeType('archive.zip'), 'application/octet-stream');
    expect(attachmentMimeType('camera-output', forceImage: true), 'image/*');
    expect(
      isTextAttachment('build.gradle', 'application/octet-stream'),
      isTrue,
    );
    expect(isTextAttachment('archive.zip', 'application/zip'), isFalse);
  });
}
