/// Small typesetting fixes applied to rendered text only, never to the text a
/// user copies or a voice reads.
library;

/// U+2060 WORD JOINER: invisible and zero-width, it forbids a line break on
/// either side of it.
const String wordJoiner = '⁠';

/// An en dash (or figure dash) set tight between two digits: a numeric range
/// such as "4–6" or "2020–2024".
final RegExp _numberRangeDash = RegExp(r'(?<=\d)[‒–](?=\d)');

/// Keeps numeric ranges such as "4–6 hours" on one line.
///
/// Line breaking may split after an en dash, which strands "4–" at the end
/// of one line and "6 hours" at the start of the next. Word joiners around
/// the dash keep the range whole; they render as nothing.
///
/// Text that already contains a word joiner is returned unchanged, so every
/// joiner in the result was added here and [removeWordJoiners] restores the
/// original exactly.
String joinNumberRanges(String text) {
  if (text.contains(wordJoiner) ||
      !(text.contains('–') || text.contains('‒'))) {
    return text;
  }
  return text.replaceAllMapped(
    _numberRangeDash,
    (match) => '$wordJoiner${match[0]}$wordJoiner',
  );
}

/// Removes the word joiners [joinNumberRanges] adds, e.g. before copying
/// selected text.
String removeWordJoiners(String text) =>
    text.contains(wordJoiner) ? text.replaceAll(wordJoiner, '') : text;

/// The index in [joined] (a [joinNumberRanges] result) that corresponds to
/// [index] in the original text.
int joinedTextIndex(String joined, int index) {
  if (index <= 0) return index;
  var original = 0;
  for (var i = 0; i < joined.length; i++) {
    if (joined.codeUnitAt(i) == 0x2060) continue;
    if (original == index) return i;
    original++;
  }
  return joined.length;
}
