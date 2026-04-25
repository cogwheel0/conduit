import 'dart:math' as math;

final RegExp _comparisonBoundaryNoise = RegExp(
  r"(^[^\p{L}\p{N}']+|[^\p{L}\p{N}']+$)",
  unicode: true,
);
final RegExp _whitespace = RegExp(r'\s');

/// Accumulates local STT segments across recognizer resets.
///
/// The platform recognizer can restart mid-turn and resume with only the tail of
/// the transcript. This helper keeps the committed portion of the transcript
/// and merges the next partial segment back onto it without duplicating overlap.
class VoiceTranscriptAccumulator {
  String _committedTranscript = '';
  String _currentSegment = '';

  /// The best transcript assembled so far.
  String get text => _mergeTranscript(_committedTranscript, _currentSegment);

  /// Clears all buffered transcript state.
  void reset() {
    _committedTranscript = '';
    _currentSegment = '';
  }

  /// Applies a recognition update and returns the merged transcript.
  String applyResult({
    required String recognizedWords,
    required bool isFinalResult,
  }) {
    final normalized = _normalizeTranscript(recognizedWords);

    if (normalized.isNotEmpty) {
      if (_currentSegment.isEmpty) {
        _currentSegment = normalized;
      } else if (_belongsToCurrentSegment(_currentSegment, normalized)) {
        _currentSegment = normalized;
      } else {
        _commitCurrentSegment();
        _currentSegment = normalized;
      }
    }

    if (isFinalResult) {
      _commitCurrentSegment();
    }

    return text;
  }

  /// Commits any pending partial segment and returns the final transcript.
  String finalizePending() {
    _commitCurrentSegment();
    return _committedTranscript;
  }

  void _commitCurrentSegment() {
    if (_currentSegment.isEmpty) {
      return;
    }
    _committedTranscript = _mergeTranscript(
      _committedTranscript,
      _currentSegment,
    );
    _currentSegment = '';
  }
}

String _normalizeTranscript(String value) {
  return value.trim().replaceAll(RegExp(r'\s+'), ' ');
}

bool _belongsToCurrentSegment(String current, String incoming) {
  final normalizedCurrent = _normalizeForComparison(current);
  final normalizedIncoming = _normalizeForComparison(incoming);
  if (normalizedCurrent.isEmpty || normalizedIncoming.isEmpty) {
    return false;
  }

  if (normalizedCurrent == normalizedIncoming ||
      normalizedIncoming.startsWith(normalizedCurrent) ||
      normalizedCurrent.startsWith(normalizedIncoming)) {
    return true;
  }

  final currentWords = current.split(' ');
  final incomingWords = incoming.split(' ');
  final sharedPrefix = _sharedPrefixWordCount(currentWords, incomingWords);
  final smallerLength = math.min(currentWords.length, incomingWords.length);

  if (sharedPrefix == 0 || smallerLength == 0) {
    return _phrasesLookLikeRevision(normalizedCurrent, normalizedIncoming);
  }

  if (sharedPrefix == smallerLength) {
    return true;
  }

  if (smallerLength <= 3 && sharedPrefix + 1 >= smallerLength) {
    return true;
  }

  if (sharedPrefix >= 2 && sharedPrefix * 2 >= smallerLength) {
    return true;
  }

  return _phrasesLookLikeRevision(normalizedCurrent, normalizedIncoming);
}

int _sharedPrefixWordCount(List<String> left, List<String> right) {
  final maxWords = math.min(left.length, right.length);
  var count = 0;
  for (var index = 0; index < maxWords; index++) {
    if (!_tokensEquivalent(left[index], right[index])) {
      break;
    }
    count++;
  }
  return count;
}

String _mergeTranscript(String base, String incoming) {
  if (base.isEmpty) {
    return incoming;
  }
  if (incoming.isEmpty) {
    return base;
  }

  final baseWords = base.split(' ');
  final incomingWords = incoming.split(' ');
  final maxOverlap = math.min(baseWords.length, incomingWords.length);

  for (var overlap = maxOverlap; overlap > 0; overlap--) {
    final baseSlice = baseWords.sublist(baseWords.length - overlap);
    final incomingSlice = incomingWords.sublist(0, overlap);
    final matches = List.generate(
      overlap,
      (index) => _tokensEquivalent(baseSlice[index], incomingSlice[index]),
    ).every((value) => value);
    if (matches) {
      final merged = <String>[...baseWords, ...incomingWords.sublist(overlap)];
      return merged.join(' ');
    }
  }

  final mergedWithoutWordBoundaries = _mergeWithoutWordBoundaries(
    base,
    incoming,
  );
  if (mergedWithoutWordBoundaries != null) {
    return mergedWithoutWordBoundaries;
  }

  return '$base $incoming';
}

String? _mergeWithoutWordBoundaries(String base, String incoming) {
  if (_whitespace.hasMatch(base) ||
      _whitespace.hasMatch(incoming) ||
      (!_containsNonAscii(base) && !_containsNonAscii(incoming))) {
    return null;
  }

  final maxOverlap = math.min(base.length, incoming.length);
  for (var overlap = maxOverlap; overlap >= 2; overlap--) {
    final baseSlice = base.substring(base.length - overlap);
    final incomingSlice = incoming.substring(0, overlap);
    if (baseSlice == incomingSlice) {
      return '$base${incoming.substring(overlap)}';
    }
  }

  return null;
}

String _normalizeForComparison(String value) {
  return value
      .split(' ')
      .map(_canonicalizeToken)
      .where((token) => token.isNotEmpty)
      .join(' ');
}

String _canonicalizeToken(String token) {
  return token.toLowerCase().replaceAll(_comparisonBoundaryNoise, '');
}

bool _tokensEquivalent(String left, String right) {
  final normalizedLeft = _canonicalizeToken(left);
  final normalizedRight = _canonicalizeToken(right);
  if (normalizedLeft.isEmpty || normalizedRight.isEmpty) {
    return false;
  }
  if (normalizedLeft == normalizedRight) {
    return true;
  }

  final shorter = normalizedLeft.length <= normalizedRight.length
      ? normalizedLeft
      : normalizedRight;
  final longer = normalizedLeft.length <= normalizedRight.length
      ? normalizedRight
      : normalizedLeft;
  final lengthDelta = longer.length - shorter.length;
  final sharedPrefix = _sharedCharacterPrefixLength(shorter, longer);

  if (shorter.length >= 4 && lengthDelta <= 2 && longer.startsWith(shorter)) {
    return true;
  }

  return shorter.length >= 5 &&
      lengthDelta <= 1 &&
      sharedPrefix * 5 >= shorter.length * 4;
}

int _sharedCharacterPrefixLength(String left, String right) {
  final maxLength = math.min(left.length, right.length);
  var count = 0;
  for (var index = 0; index < maxLength; index++) {
    if (left[index] != right[index]) {
      break;
    }
    count++;
  }
  return count;
}

bool _phrasesLookLikeRevision(String left, String right) {
  final maxLength = math.max(left.length, right.length);
  if (maxLength == 0 || maxLength > 80) {
    return false;
  }

  final leftWords = left.isEmpty ? const <String>[] : left.split(' ');
  final rightWords = right.isEmpty ? const <String>[] : right.split(' ');
  if ((leftWords.length - rightWords.length).abs() > 2) {
    return false;
  }

  final distance = _levenshteinDistance(left, right);
  return distance * 4 <= maxLength;
}

int _levenshteinDistance(String left, String right) {
  if (left == right) {
    return 0;
  }
  if (left.isEmpty) {
    return right.length;
  }
  if (right.isEmpty) {
    return left.length;
  }

  var previous = List<int>.generate(right.length + 1, (index) => index);
  var current = List<int>.filled(right.length + 1, 0);

  for (var i = 0; i < left.length; i++) {
    current[0] = i + 1;
    for (var j = 0; j < right.length; j++) {
      final substitutionCost = left[i] == right[j] ? 0 : 1;
      current[j + 1] = math.min(
        math.min(current[j] + 1, previous[j + 1] + 1),
        previous[j] + substitutionCost,
      );
    }
    final nextPrevious = previous;
    previous = current;
    current = nextPrevious;
  }

  return previous[right.length];
}

bool _containsNonAscii(String value) {
  for (final rune in value.runes) {
    if (rune > 0x7F) {
      return true;
    }
  }
  return false;
}
