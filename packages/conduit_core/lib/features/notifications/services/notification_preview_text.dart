/// Plain-text notification previews, cleaned the way Conduit's push senders
/// clean them (docs/push/PROTOCOL.md §2, and `clean_text` / `clip` in
/// server-plugins/common/conduit_webpush/payload.py), so a reply previews the
/// same whether a push or the app itself posts it.
library;

import 'package:meta/meta.dart';

/// The longest preview, in code points (the protocol's `b` limit).
const int notificationPreviewLimit = 200;

/// The longest title, in code points (the protocol's `t` limit).
const int notificationTitleLimit = 100;

/// The most code points a preview is cleaned from (`CLEAN_INPUT_LIMIT` on
/// the server). Some patterns below backtrack on long runs of unclosed
/// markup, and a channel message or a reply can be any length, so they never
/// see more than this.
const int notificationCleanInputLimit = 4000;

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
// The start of a block that [notificationCleanInputLimit] cut off before its
// end.
final RegExp _openBlock = RegExp(
  r'<(?:details|think|thinking)\b',
  caseSensitive: false,
);
// Link text can't contain brackets and a target can't contain parentheses,
// except one nested pair as in Wikipedia URLs. That keeps each attempt short,
// so a run of unclosed "[" or "(" takes linear time, not quadratic.
@visibleForTesting
final RegExp notificationImagePattern = RegExp(
  r'!\[([^\[\]]*)\]\([^()]*(?:\([^()]*\)[^()]*)*\)',
);
@visibleForTesting
final RegExp notificationLinkPattern = RegExp(
  r'\[([^\[\]]+)\]\([^()]*(?:\([^()]*\)[^()]*)*\)',
);
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
///
/// Only the first [notificationCleanInputLimit] code points are read. When
/// that cuts the text short, a reasoning block it leaves open is dropped to
/// the end, like an open code fence, and the result ends in `…`.
String cleanNotificationText(String? text) {
  if (text == null || text.isEmpty) return '';
  final kept = _cutToInputLimit(text);
  final cut = kept != null;
  var result = kept ?? text;
  for (final pattern in _blocks) {
    result = result.replaceAll(pattern, '\n');
  }
  if (cut) {
    final opened = _openBlock.firstMatch(result);
    if (opened != null) result = result.substring(0, opened.start);
  }
  result = result.replaceAllMapped(notificationImagePattern, (m) => m.group(1) ?? '');
  result = result.replaceAllMapped(notificationLinkPattern, (m) => m.group(1) ?? '');
  result = result.replaceAll(_tag, '');
  result = result.replaceAll(_lineMarker, '');
  result = result.replaceAll(_emphasis, '');
  result = result.replaceAll(_space, ' ').trim();
  return cut && result.isNotEmpty ? '$result$_ellipsis' : result;
}

/// The first [notificationCleanInputLimit] code points of [text], or null
/// when it has no more than that. Counted in code points, as the server
/// counts, so both cut in the same place.
String? _cutToInputLimit(String text) {
  // At most one code point per UTF-16 unit.
  if (text.length <= notificationCleanInputLimit) return null;
  final runes = RuneIterator(text);
  var count = 0;
  while (runes.moveNext()) {
    if (count == notificationCleanInputLimit) {
      return text.substring(0, runes.rawIndex);
    }
    count++;
  }
  return null;
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
