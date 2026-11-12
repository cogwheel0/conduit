import 'package:conduit/features/navigation/widgets/folder_icon.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every saved icon Open WebUI can show has an emoji', () {
    // One of the app's own choices.
    expect(folderIconEmoji('rocket'), '🚀');
    // Any other shortcode, as the web's picker saves it.
    expect(folderIconEmoji('fire'), '\u{1F525}\u{FE0F}');
    expect(folderIconEmoji(' fire '), '\u{1F525}\u{FE0F}');
    // A glyph saved as is.
    expect(folderIconEmoji('🦊'), '🦊');
    // Nothing to draw: the platform folder symbol.
    expect(folderIconEmoji(null), isNull);
    expect(folderIconEmoji(''), isNull);
    expect(folderIconEmoji('not_an_emoji'), isNull);
  });

  test('only an icon outside the curated choices is offered as custom', () {
    expect(customFolderIconAlias('fire'), 'fire');
    expect(customFolderIconAlias('🦊'), '🦊');
    expect(customFolderIconAlias('rocket'), isNull);
    expect(customFolderIconAlias('not_an_emoji'), isNull);
    expect(customFolderIconAlias(null), isNull);
  });

  test('a custom icon is labelled with its emoji and shortcode', () {
    expect(customFolderIconLabel('fire'), '\u{1F525}\u{FE0F} fire');
    expect(customFolderIconLabel('🦊'), '🦊');
  });
}
