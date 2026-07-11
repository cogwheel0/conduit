/// Parses the timestamp shapes returned by Hermes APIs.
///
/// Hermes versions may return epoch seconds, epoch milliseconds, numeric
/// strings, or ISO-8601 strings.
DateTime? parseHermesTimestamp(dynamic value) {
  if (value == null) return null;
  if (value is num) {
    final ms = value < 100000000000 ? (value * 1000).round() : value.round();
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }
  final str = value.toString();
  final asNum = num.tryParse(str);
  if (asNum != null) return parseHermesTimestamp(asNum);
  return DateTime.tryParse(str);
}
