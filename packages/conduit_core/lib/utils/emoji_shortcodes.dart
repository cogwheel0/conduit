import 'emoji_shortcode_table.dart';

/// The emoji Open WebUI shows for [shortcode] (`fire`, `+1`, `flag-us`), or
/// null when Open WebUI does not know it. Surrounding whitespace and colons
/// (`:fire:`) are ignored.
///
/// Open WebUI saves a folder's icon as one of these shortcodes and draws its
/// own image of the emoji; Conduit shows the system's glyph for it.
String? emojiForShortcode(String shortcode) {
  var name = shortcode.trim();
  if (name.length > 2 && name.startsWith(':') && name.endsWith(':')) {
    name = name.substring(1, name.length - 1);
  }
  final codePoints = _codePointsByShortcode[name];
  return codePoints == null ? null : _emojiFor(codePoints);
}

/// Every shortcode, read from [openWebUiEmojiShortcodeTable] when first
/// needed, mapped to its emoji's code points.
final Map<String, String> _codePointsByShortcode = () {
  final map = <String, String>{};
  for (final entry in openWebUiEmojiShortcodeTable.split(';')) {
    final colon = entry.indexOf(':');
    final codePoints = entry.substring(0, colon);
    for (final name in entry.substring(colon + 1).split(',')) {
      map[name] = codePoints;
    }
  }
  return map;
}();

String _emojiFor(String codePoints) {
  final runes = [
    for (final hex in codePoints.split('-')) int.parse(hex, radix: 16),
  ];
  // A lone symbol such as ❤ (2764) or ☀ (2600) is drawn as plain text
  // unless variation selector 16 asks for its emoji form. One that is
  // always an emoji ignores the selector.
  if (runes.length == 1) runes.add(0xFE0F);
  return String.fromCharCodes(runes);
}
