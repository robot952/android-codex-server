import 'package:codex_remote/src/ui/markdown_links.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;

void main() {
  test('shows only HTTP destinations as links on the next line', () {
    expect(
      markdownWithVisibleLinkDestinations('[文档](https://example.com/docs)'),
      '文档\n'
      '[https://example.com/docs](https://example.com/docs)',
    );
    expect(
      markdownWithVisibleLinkDestinations(
        '[https://example.com](https://example.com)',
      ),
      '[https://example.com](https://example.com)',
    );
  });

  test('keeps localized text after the visible link destination', () {
    const url = 'http://192.168.8.107/agent.apk';
    final markdown = markdownWithVisibleLinkDestinations(
      '[内网下载]($url)：仅同一局域网可用',
    );
    expect(markdown, '内网下载\n[$url]($url)：仅同一局域网可用');
    final nodes = md.Document(
      inlineSyntaxes: workMarkdownInlineSyntaxes,
      extensionSet: md.ExtensionSet.gitHubFlavored,
      encodeHtml: false,
    ).parseInline(markdown);

    expect(nodes, hasLength(3));
    expect(nodes.first.textContent.trim(), '内网下载');
    expect(nodes.first, isNot(isA<md.Element>()));
    final visibleUrl = nodes.whereType<md.Element>().single;
    expect(visibleUrl.textContent, url);
    expect(visibleUrl.attributes['href'], url);
    expect(nodes.last.textContent, '：仅同一局域网可用');
  });

  test('autolinks HTTP destinations adjacent to localized punctuation', () {
    const url = 'http://192.168.8.107/codex.apk';
    final nodes = md.Document(
      inlineSyntaxes: workMarkdownInlineSyntaxes,
      extensionSet: md.ExtensionSet.gitHubFlavored,
      encodeHtml: false,
    ).parseInline('内网：$url');
    final link = nodes.whereType<md.Element>().singleWhere(
      (element) => element.tag == 'a',
    );

    expect(link.textContent, url);
    expect(link.attributes['href'], url);
  });

  test('keeps URL-labelled Markdown links as one clean link', () {
    const url = 'http://frp.asdb.top:18080/agent.apk';
    final markdown = markdownWithVisibleLinkDestinations('[$url]($url)');
    final nodes = md.Document(
      inlineSyntaxes: workMarkdownInlineSyntaxes,
      extensionSet: md.ExtensionSet.gitHubFlavored,
      encodeHtml: false,
    ).parseInline(markdown);

    expect(nodes, hasLength(1));
    final link = nodes.single as md.Element;
    expect(link.tag, 'a');
    expect(link.textContent, url);
    expect(link.attributes['href'], url);
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
