import 'package:conduit_core/models/folder_icons.dart';
import 'package:test/test.dart';

void main() {
  test('every saved icon Open WebUI can show has an emoji', () {
    // One of the app's own choices.
    expect(folderIconEmoji('rocket'), '🚀');
    // Any other shortcode, as the web's picker saves it.
    expect(folderIconEmoji('fire'), '\u{1F525}\u{FE0F}');
    expect(folderIconEmoji(' fire '), '\u{1F525}\u{FE0F}');
    // A glyph saved as is, in any emoji sequence.
    for (final glyph in ['🦊', '👍🏽', '👩‍🚀', '🇳🇴', '1️⃣', '❤️']) {
      expect(folderIconEmoji(glyph), glyph);
    }
    // Nothing to draw: the platform folder symbol.
    expect(folderIconEmoji(null), isNull);
    expect(folderIconEmoji(''), isNull);
    for (final name in [
      'not_an_emoji',
      'not.an.emoji',
      'my folder',
      '🦊 fox',
    ]) {
      expect(folderIconEmoji(name), isNull, reason: name);
    }
  });

  test('only an icon outside the curated choices is offered as custom', () {
    expect(customFolderIconAlias('fire'), 'fire');
    expect(customFolderIconAlias('🦊'), '🦊');
    expect(customFolderIconAlias('rocket'), isNull);
    expect(customFolderIconAlias('not_an_emoji'), isNull);
    expect(customFolderIconAlias('not.an.emoji'), isNull);
    expect(customFolderIconAlias(null), isNull);
  });

  test('a custom icon is labelled with its emoji and shortcode', () {
    expect(customFolderIconLabel('fire'), '\u{1F525}\u{FE0F} fire');
    expect(customFolderIconLabel('🦊'), '🦊');
  });
}
