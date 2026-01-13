/// Utilities for parsing JSON values with graceful fallbacks.
///
/// These helpers handle various API response formats and provide defensive
/// parsing to avoid crashes from malformed data.
library;

/// Parses a DateTime from various formats.
///
/// Handles:
/// - `DateTime` objects (returned as-is)
/// - ISO 8601 strings (parsed)
/// - Unix timestamps as integers (assumed to be in seconds)
/// - `null` or invalid values (returns [DateTime.now])
DateTime parseDateTime(Object? value) {
  if (value == null) {
    return DateTime.now();
  }
  if (value is DateTime) {
    return value;
  }
  if (value is String) {
    // Use tryParse to avoid FormatException on malformed strings
    return DateTime.tryParse(value) ?? DateTime.now();
  }
  if (value is int) {
    // Assume Unix timestamp in seconds
    return DateTime.fromMillisecondsSinceEpoch(value * 1000);
  }
  return DateTime.now();
}

/// Parses a nullable DateTime from various formats.
///
/// Returns `null` if the input is `null`, otherwise delegates to [parseDateTime].
DateTime? parseDateTimeOrNull(Object? value) {
  if (value == null) return null;
  return parseDateTime(value);
}

/// Parses an int from various formats.
///
/// Handles:
/// - `int` values (returned as-is)
/// - `num` values (converted to int)
/// - String values (parsed with [int.tryParse])
/// - `null` or invalid values (returns `null`)
int? parseInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}
