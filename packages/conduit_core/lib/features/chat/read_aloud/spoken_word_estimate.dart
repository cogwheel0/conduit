/// The word of [sentence] being spoken [fraction] of the way through the
/// sentence's audio, as character offsets in [sentence].
///
/// For speech played as audio, which reports no word timings, each word is
/// taken to last as long as its characters and the space after it. Null when
/// [sentence] has no words.
({int start, int end})? estimateSpokenWord(String sentence, double fraction) {
  final words = _word.allMatches(sentence).toList(growable: false);
  if (words.isEmpty) return null;
  var total = 0;
  for (final word in words) {
    total += word.end - word.start + 1;
  }
  final target = fraction.clamp(0.0, 1.0) * total;
  var reached = 0;
  for (final word in words) {
    reached += word.end - word.start + 1;
    if (target < reached) return (start: word.start, end: word.end);
  }
  final last = words.last;
  return (start: last.start, end: last.end);
}

final RegExp _word = RegExp(r'\S+');
