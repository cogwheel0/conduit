import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('chatHeaderShowsTitle', () {
    test('at the top the header names only the model', () {
      expect(
        chatHeaderShowsTitle(
          scrolledFromTop: 0,
          hasOlderMessages: false,
          currentlyShowing: false,
        ),
        isFalse,
      );
    });

    test('the title comes in once the first message is under the bar', () {
      expect(
        chatHeaderShowsTitle(
          scrolledFromTop: 24,
          hasOlderMessages: false,
          currentlyShowing: false,
        ),
        isTrue,
      );
    });

    test('a resting scroll near the threshold does not flicker', () {
      // Just past where it goes away, it is not brought back...
      expect(
        chatHeaderShowsTitle(
          scrolledFromTop: 12,
          hasOlderMessages: false,
          currentlyShowing: false,
        ),
        isFalse,
      );
      // ...and once shown, the same position keeps it.
      expect(
        chatHeaderShowsTitle(
          scrolledFromTop: 12,
          hasOlderMessages: false,
          currentlyShowing: true,
        ),
        isTrue,
      );
    });

    test('older messages still above always count as scrolled', () {
      expect(
        chatHeaderShowsTitle(
          scrolledFromTop: 0,
          hasOlderMessages: true,
          currentlyShowing: false,
        ),
        isTrue,
      );
    });
  });

  test('chatHeaderTitle skips the placeholder a new chat carries', () {
    expect(chatHeaderTitle(null), isNull);
    expect(chatHeaderTitle('  '), isNull);
    expect(chatHeaderTitle('New Chat'), isNull);
    expect(chatHeaderTitle('  Sourdough plan '), 'Sourdough plan');
    // User titles keep their own casing.
    expect(chatHeaderTitle('sourdough plan'), 'sourdough plan');
  });

  test('the Temporary Chat toggle fills its dashed circle while on', () {
    expect(temporaryChatToolbarSymbol(isTemporary: false), 'circle.dashed');
    expect(
      temporaryChatToolbarSymbol(isTemporary: true),
      'circle.dashed.inset.filled',
    );
  });
}
