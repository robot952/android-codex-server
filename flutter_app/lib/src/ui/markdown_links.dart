import 'dart:convert';

import 'package:markdown/markdown.dart' as md;

final RegExp _markdownRemoteFileLink = RegExp(r'\[([^\]\r\n]+)]\((/[^\s)]+)\)');
final RegExp _remoteFileToken = RegExp(r'^[A-Za-z0-9_-]+$');

const String _remoteFileLinkPrefix = 'https://codex-remote.local/remote-file/';
const int _maxRemoteFilePathLength = 4096;
const int _maxRemoteFileTokenLength = 6000;

final List<md.InlineSyntax> workMarkdownInlineSyntaxes = <md.InlineSyntax>[
  AdjacentHttpAutolinkSyntax(),
];

/// Extends GFM autolinks to URLs immediately following localized punctuation.
/// The upstream syntax intentionally accepts only a small ASCII prefix set,
/// which leaves text such as `内网：https://example.com` unlinked.
class AdjacentHttpAutolinkSyntax extends md.AutolinkExtensionSyntax {
  @override
  bool tryMatch(md.InlineParser parser, [int? startMatchPos]) {
    startMatchPos ??= parser.pos;
    final match = pattern.matchAsPrefix(parser.source, startMatchPos);
    if (match == null || match[1] == null) return false;
    if (parser.pos > 0) {
      final precededBy = String.fromCharCode(parser.charAt(parser.pos - 1));
      const validPrecedingChars = <String>{
        '\n',
        ' ',
        '*',
        '_',
        '~',
        '(',
        '>',
        '：',
        '，',
        '。',
        '；',
        '！',
        '？',
        '、',
        '（',
        '【',
        '《',
        '「',
        '『',
      };
      if (!validPrecedingChars.contains(precededBy)) return false;
    }
    parser.writeText();
    return onMatch(parser, match);
  }
}

/// Rewrites absolute server paths to internal links that are decoded locally
/// and are never sent to a browser. Ordinary Markdown links stay untouched so
/// their destination is not duplicated in the visible transcript.
String markdownWithVisibleLinkDestinations(String markdown) {
  return markdown.replaceAllMapped(_markdownRemoteFileLink, (match) {
    final link = remoteFileLinkForPath(match.group(2) ?? '');
    if (link == null) return match.group(0) ?? '';
    return '[${match.group(1)}]($link)';
  });
}

String? remoteFileLinkForPath(String path) {
  if (!_isDownloadableRemoteFilePath(path)) return null;
  final token = base64Url.encode(utf8.encode(path)).replaceAll('=', '');
  return '$_remoteFileLinkPrefix$token';
}

String? remoteFilePathFromLink(String link) {
  if (!link.startsWith(_remoteFileLinkPrefix)) return null;
  final token = link.substring(_remoteFileLinkPrefix.length);
  if (token.isEmpty ||
      token.length > _maxRemoteFileTokenLength ||
      !_remoteFileToken.hasMatch(token)) {
    return null;
  }
  try {
    final bytes = base64Url.decode(base64Url.normalize(token));
    final path = utf8.decode(bytes);
    final encoded = utf8.encode(path);
    if (bytes.length != encoded.length) return null;
    for (var index = 0; index < bytes.length; index++) {
      if (bytes[index] != encoded[index]) return null;
    }
    return _isDownloadableRemoteFilePath(path) ? path : null;
  } catch (_) {
    return null;
  }
}

String remoteDownloadFileName(String path) {
  final candidate = path.split('/').last.trim();
  if (candidate.isEmpty) return 'download';
  final safe = candidate.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');
  if (safe.isEmpty) return 'download';
  return safe.length <= 160 ? safe : safe.substring(safe.length - 160);
}

bool _isDownloadableRemoteFilePath(String path) =>
    path.length >= 2 &&
    path.length <= _maxRemoteFilePathLength &&
    path.startsWith('/') &&
    path.runes.every((value) => value >= 0x20 && value != 0x7f);
