/// Plain-text notification previews, cleaned the way Conduit's push senders
/// clean them (docs/push/PROTOCOL.md §2, and `clean_text` / `clip` in
/// server-plugins/common/conduit_webpush/payload.py), so a reply previews the
/// same whether a push or the app itself posts it.
library;

/// The longest preview, in code points (the protocol's `b` limit).
const int notificationPreviewLimit = 200;

/// The longest title, in code points (the protocol's `t` limit).
const int notificationTitleLimit = 100;

const String _ellipsis = '…';

final List<RegExp> _blocks = [
  RegExp(
    r'<details\b[^>]*>.*?</details\s*>',
    caseSensitive: false,
    dotAll: true,
  ),
  RegExp(r'<think\b[^>]*>.*?</think\s*>', caseSensitive: false, dotAll: true),
  RegExp(
    r'<thinking\b[^>]*>.*?</thinking\s*>',
    caseSensitive: false,
    dotAll: true,
  ),
  // A fence left open by a truncated or still-streaming reply runs to the end.
  RegExp(
    r'(^|\n)[ \t]*(```|~~~).*?(\n[ \t]*\2[ \t]*(?=\n|$)|$)',
    dotAll: true,
  ),
];
final RegExp _image = RegExp(r'!\[([^\]]*)\]\([^)]*\)');
final RegExp _link = RegExp(r'\[([^\]]+)\]\([^)]*\)');
final RegExp _tag = RegExp(r'</?[A-Za-z][A-Za-z0-9-]*(\s[^<>]*)?/?>');
final RegExp _lineMarker = RegExp(
  r'^[ \t]*(#{1,6}[ \t]+|>[ \t]?|[-*+][ \t]+|\d+[.)][ \t]+)',
  multiLine: true,
);
final RegExp _emphasis = RegExp(r'(\*\*|__|~~|`)');
final RegExp _space = RegExp(r'\s+');

/// Turns a Markdown reply into one line of plain text: reasoning blocks
/// (`<details>`, `<think>`), fenced code, image and link markup, HTML tags and
/// Markdown markers go, and whitespace collapses.
String cleanNotificationText(String? text) {
  if (text == null || text.isEmpty) return '';
  var result = text;
  for (final pattern in _blocks) {
    result = result.replaceAll(pattern, '\n');
  }
  result = result.replaceAllMapped(_image, (m) => m.group(1) ?? '');
  result = result.replaceAllMapped(_link, (m) => m.group(1) ?? '');
  result = result.replaceAll(_tag, '');
  result = result.replaceAll(_lineMarker, '');
  result = result.replaceAll(_emphasis, '');
  return result.replaceAll(_space, ' ').trim();
}

/// Cuts [text] to at most [limit] code points, ending in `…` when it was cut.
/// Never splits a surrogate pair.
String clipNotificationText(String? text, int limit) {
  final collapsed = (text ?? '').replaceAll(_space, ' ').trim();
  final runes = collapsed.runes;
  if (runes.length <= limit) return collapsed;
  final kept = String.fromCharCodes(runes.take(limit - 1)).trimRight();
  return '$kept$_ellipsis';
}

/// The preview of [text]: cleaned to plain text and clipped to
/// [notificationPreviewLimit] code points.
String notificationPreviewText(String? text) =>
    clipNotificationText(cleanNotificationText(text), notificationPreviewLimit);
