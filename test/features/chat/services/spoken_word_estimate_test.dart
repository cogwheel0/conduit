import 'package:conduit/features/chat/services/spoken_word_estimate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const sentence = 'Water the  fern, then rest.';

  String word(double fraction) {
    final range = estimateSpokenWord(sentence, fraction)!;
    return sentence.substring(range.start, range.end);
  }

  test('follows the audio through the words by their characters', () {
    // Water(6) the(4) fern,(6) then(5) rest.(6): 27 parts in all.
    expect(word(0), 'Water');
    expect(word(0.2), 'Water');
    expect(word(0.25), 'the');
    expect(word(0.5), 'fern,');
    expect(word(0.7), 'then');
    expect(word(0.99), 'rest.');
    expect(word(1), 'rest.');
    // Positions past either end clamp to the first or last word.
    expect(word(-0.5), 'Water');
    expect(word(1.5), 'rest.');
  });

  test('a sentence without words has no spoken word', () {
    expect(estimateSpokenWord('   ', 0.5), isNull);
    expect(estimateSpokenWord('', 0), isNull);
  });
}
