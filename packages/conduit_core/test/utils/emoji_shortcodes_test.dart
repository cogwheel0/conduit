import 'package:checks/checks.dart';
import 'package:conduit_core/utils/emoji_shortcode_table.dart';
import 'package:conduit_core/utils/emoji_shortcodes.dart';
import 'package:test/test.dart';

void main() {
  test('a shortcode chosen on the web resolves to its emoji', () {
    check(emojiForShortcode('fire')).equals('\u{1F525}\u{FE0F}');
    check(emojiForShortcode('rocket')).equals('\u{1F680}\u{FE0F}');
    check(emojiForShortcode('+1')).equals('\u{1F44D}\u{FE0F}');
  });

  test('a lone symbol asks for its emoji form', () {
    // U+2764 alone draws as a plain text heart.
    check(emojiForShortcode('heart')).equals('❤\u{FE0F}');
    check(emojiForShortcode('sunny')).equals('☀\u{FE0F}');
  });

  test('a sequence keeps its code points as Open WebUI lists them', () {
    check(emojiForShortcode('hash')).equals('#\u{FE0F}⃣');
    check(emojiForShortcode('flag-us')).equals('\u{1F1FA}\u{1F1F8}');
    // Another shortcode for the same emoji.
    check(emojiForShortcode('us')).equals('\u{1F1FA}\u{1F1F8}');
  });

  test('colons and whitespace around a shortcode are ignored', () {
    check(emojiForShortcode(':fire:')).equals(emojiForShortcode('fire'));
    check(emojiForShortcode(' fire ')).equals(emojiForShortcode('fire'));
  });

  test('a name Open WebUI does not know has no emoji', () {
    check(emojiForShortcode('not_an_emoji')).isNull();
    check(emojiForShortcode('')).isNull();
    check(emojiForShortcode('::')).isNull();
    // Shortcodes are lower case, as Open WebUI saves them.
    check(emojiForShortcode('FIRE')).isNull();
  });

  test('every shortcode in the table resolves', () {
    final names = [
      for (final entry in openWebUiEmojiShortcodeTable.split(';'))
        ...entry.substring(entry.indexOf(':') + 1).split(','),
    ];
    // Open WebUI's list: 1,903 emoji under 1,964 shortcodes.
    check(names).length.equals(1964);
    check(names.toSet()).length.equals(names.length);
    for (final name in names) {
      check(because: name, emojiForShortcode(name)).isNotNull().isNotEmpty();
    }
  });
}
