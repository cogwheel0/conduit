/// Returns at most [maxScalars] Unicode scalar values from the start of
/// [value].
///
/// Unlike `String.substring`, this never splits a UTF-16 surrogate pair. This
/// is useful when a bounded working prefix is later inspected for complete
/// security-sensitive values.
String takeUnicodeScalarPrefix(String value, int maxScalars) {
  if (maxScalars < 0) {
    throw RangeError.value(maxScalars, 'maxScalars');
  }
  if (value.length <= maxScalars) return value;
  return String.fromCharCodes(value.runes.take(maxScalars));
}

/// Redacts every configured sensitive-value occurrence in a bounded Unicode
/// prefix of [value].
///
/// Matches are collected as intervals before replacement, so self-overlapping,
/// mutually overlapping, and truncation-crossing values are redacted as one
/// union. The working prefix extends beyond [maxVisibleScalars] just far enough
/// to recognize a secret that begins inside the eventual visible result. At
/// most [maxVisibleScalars] non-sensitive source scalars are emitted; complete
/// [replacement] markers are preserved and do not consume that budget.
String redactSensitiveValuesInUnicodePrefix(
  String value, {
  required Iterable<String> sensitiveValues,
  required int maxVisibleScalars,
  String replacement = '[REDACTED]',
}) {
  if (maxVisibleScalars < 0) {
    throw RangeError.value(maxVisibleScalars, 'maxVisibleScalars');
  }

  final secrets = sensitiveValues.where((secret) => secret.isNotEmpty).toSet();
  final longestSecretScalars = secrets.fold<int>(
    0,
    (longest, secret) =>
        secret.runes.length > longest ? secret.runes.length : longest,
  );
  final workLimit =
      maxVisibleScalars +
      (longestSecretScalars > 0 ? longestSecretScalars - 1 : 0);
  final prefix = takeUnicodeScalarPrefix(value, workLimit);
  if (prefix.isEmpty) return prefix;
  if (secrets.isEmpty) {
    return takeUnicodeScalarPrefix(prefix, maxVisibleScalars);
  }

  final intervals = <({int start, int end})>[];
  for (final secret in secrets) {
    var searchStart = 0;
    while (searchStart <= prefix.length - secret.length) {
      final matchStart = prefix.indexOf(secret, searchStart);
      if (matchStart < 0) break;
      intervals.add((start: matchStart, end: matchStart + secret.length));
      // Advance one code unit so overlapping occurrences are retained.
      searchStart = matchStart + 1;
    }

    if (prefix.length < value.length) {
      var crossingStart = value.lastIndexOf(secret, prefix.length - 1);
      while (crossingStart >= 0 &&
          crossingStart + secret.length > prefix.length) {
        intervals.add((start: crossingStart, end: prefix.length));
        if (crossingStart == 0) break;
        crossingStart = value.lastIndexOf(secret, crossingStart - 1);
      }
    }
  }

  if (intervals.isEmpty) {
    return takeUnicodeScalarPrefix(prefix, maxVisibleScalars);
  }
  intervals.sort((a, b) {
    final byStart = a.start.compareTo(b.start);
    return byStart != 0 ? byStart : b.end.compareTo(a.end);
  });
  final merged = <({int start, int end})>[];
  for (final interval in intervals) {
    if (merged.isEmpty || interval.start > merged.last.end) {
      merged.add(interval);
      continue;
    }
    final previous = merged.last;
    if (interval.end > previous.end) {
      merged[merged.length - 1] = (start: previous.start, end: interval.end);
    }
  }

  final safe = StringBuffer();
  var cursor = 0;
  var remainingPlainScalars = maxVisibleScalars;
  void writePlainText(String text) {
    if (text.isEmpty || remainingPlainScalars == 0) return;
    final bounded = takeUnicodeScalarPrefix(text, remainingPlainScalars);
    safe.write(bounded);
    remainingPlainScalars -= bounded.runes.length;
  }

  for (final interval in merged) {
    writePlainText(prefix.substring(cursor, interval.start));
    safe.write(replacement);
    cursor = interval.end;
  }
  writePlainText(prefix.substring(cursor));
  return safe.toString();
}
