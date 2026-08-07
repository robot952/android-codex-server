import 'package:codex_remote/src/ui/markdown_links.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('exposes HTTP destinations without duplicating identical labels', () {
    expect(
      markdownWithVisibleLinkDestinations('[文档](https://example.com/docs)'),
      '[文档](https://example.com/docs)\nhttps://example.com/docs',
    );
    expect(
      markdownWithVisibleLinkDestinations(
        '[https://example.com](https://example.com)',
      ),
      '[https://example.com](https://example.com)',
    );
  });

  test('round trips safe absolute remote file links', () {
    const path = '/home/root/build/app-release.apk';
    final link = remoteFileLinkForPath(path);

    expect(link, startsWith('https://codex-remote.local/remote-file/'));
    expect(remoteFilePathFromLink(link!), path);
    expect(markdownWithVisibleLinkDestinations('[安装包]($path)'), '[安装包]($link)');
  });

  test('rejects malformed tokens and unsafe remote paths', () {
    expect(remoteFileLinkForPath('relative/file.txt'), isNull);
    expect(remoteFileLinkForPath('/tmp/bad\nname.txt'), isNull);
    expect(remoteFilePathFromLink('https://example.com/file'), isNull);
    expect(
      remoteFilePathFromLink(
        'https://codex-remote.local/remote-file/not+base64',
      ),
      isNull,
    );
  });

  test('sanitizes the suggested local download name', () {
    expect(remoteDownloadFileName('/tmp/release:a?.apk'), 'release_a_.apk');
    expect(remoteDownloadFileName('/'), 'download');
  });
}
