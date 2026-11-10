import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('chatHeaderShowsTitle', () {
    test('at the top the header names only the model', () {
      expect(
        chatHeaderShowsTitle(
          scrolledFromTop: 0,
          currentlyShowing: false,
        ),
        isFalse,
      );
    });

    test('the title comes in once the first message is under the bar', () {
      expect(
        chatHeaderShowsTitle(
          scrolledFromTop: 24,
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
          currentlyShowing: false,
        ),
        isFalse,
      );
      // ...and once shown, the same position keeps it.
      expect(
        chatHeaderShowsTitle(
          scrolledFromTop: 12,
          currentlyShowing: true,
        ),
        isTrue,
      );
    });

    test('a chat that fits on one screen never brings the title in', () {
      // A first turn settling into place reports a scroll offset from its
      // pinned end space; the title must not flash in.
      expect(
        chatHeaderShowsTitle(
          scrolledFromTop: 120,
          currentlyShowing: false,
          contentOverflowsViewport: false,
        ),
        isFalse,
      );
    });

    test('once shown, only a scroll back to the top takes it away', () {
      // A sent turn settling under the bar as the keyboard leaves can read
      // as fitting for a while; the title stays rather than blink.
      expect(
        chatHeaderShowsTitle(
          scrolledFromTop: 754,
          currentlyShowing: true,
          contentOverflowsViewport: false,
        ),
        isTrue,
      );
      expect(
        chatHeaderShowsTitle(
          scrolledFromTop: 4,
          currentlyShowing: true,
          contentOverflowsViewport: false,
        ),
        isFalse,
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
