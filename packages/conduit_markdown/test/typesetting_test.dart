import 'package:conduit_markdown/conduit_markdown.dart';
import 'package:test/test.dart';

void main() {
  group('joinNumberRanges', () {
    test('joins an en dash between digits on both sides', () {
      expect(
        joinNumberRanges('Doubles within 4–6 hours'),
        'Doubles within 4$wordJoiner–${wordJoiner}6 hours',
      );
      expect(
        joinNumberRanges('2020–2024 and 10\u201212'),
        '2020$wordJoiner–${wordJoiner}2024 and '
        '10$wordJoiner\u2012${wordJoiner}12',
      );
    });

    test('leaves dashes that do not join two numbers alone', () {
      for (final text in [
        'Mon–Fri',
        'a pause – then more',
        '4 – 6 hours',
        'Day 7–',
        'plain text',
        '4-6 hours',
      ]) {
        expect(joinNumberRanges(text), text, reason: text);
      }
    });

    test('text that already has a joiner stays as written', () {
      const text = 'keep 1$wordJoiner–2 and 3–4';
      expect(joinNumberRanges(text), text);
    });

    test('removing the joiners restores the original text', () {
      const text = 'Feed 2–3 times, 25–30 °C, days 4–6.';
      expect(removeWordJoiners(joinNumberRanges(text)), text);
      expect(removeWordJoiners(text), text);
    });
  });

  test('joinedTextIndex maps an original index past added joiners', () {
    const original = 'within 4–6 h';
    final joined = joinNumberRanges(original);
    for (var i = 0; i <= original.length; i++) {
      final mapped = joinedTextIndex(joined, i);
      expect(
        removeWordJoiners(joined.substring(0, mapped)),
        original.substring(0, i),
        reason: 'index $i',
      );
    }
  });
}
