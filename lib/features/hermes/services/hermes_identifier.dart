const int kMaxHermesOpaqueIdentifierCharacters = 512;
const int _minSensitiveIdentifierSubstringCharacters = 8;
const int _maxSensitiveIdentifierPatternCharacters = 8 * 1024;

final RegExp _hermesOpaqueIdentifierPattern = RegExp(
  r'^[A-Za-z0-9][A-Za-z0-9._~:+/=\-]*$',
);

/// Accepts only a scalar provider string and bounds it by Unicode scalar
/// count. The cheap UTF-16 preflight prevents trimming or rune iteration over
/// hostile multi-megabyte display fields.
String? validateHermesBoundedString(
  Object? value, {
  required int maxCharacters,
  bool trim = true,
  bool allowEmpty = false,
}) {
  if (value is! String || maxCharacters <= 0) return null;
  if (value.length > maxCharacters * 2) return null;
  final normalized = trim ? value.trim() : value;
  if ((!allowEmpty && normalized.isEmpty) ||
      normalized.length > maxCharacters * 2 ||
      normalized.runes.length > maxCharacters ||
      normalized.contains('\u0000')) {
    return null;
  }
  return normalized;
}

/// Validates an opaque provider identifier without coercing provider values.
///
/// Hermes identifiers are persisted, reused as headers, and interpolated into
/// encoded path segments. Keeping one strict boundary prevents structured JSON,
/// control characters, unbounded values, and reflected credentials from
/// crossing into those sinks.
String? validateHermesOpaqueIdentifier(
  Object? value, {
  Iterable<String> sensitiveValues = const <String>[],
  bool rejectShortSensitiveSubstrings = true,
}) {
  if (value is! String || value.isEmpty) return null;

  // One Unicode scalar can occupy at most two UTF-16 code units. This cheap
  // preflight rejects hostile giant strings before the rune-counting pass.
  if (value.length > kMaxHermesOpaqueIdentifierCharacters * 2 ||
      value.runes.length > kMaxHermesOpaqueIdentifierCharacters ||
      value.trim() != value ||
      !_hermesOpaqueIdentifierPattern.hasMatch(value)) {
    return null;
  }

  for (final configured in sensitiveValues) {
    if (configured.isEmpty) continue;
    if (configured.length > _maxSensitiveIdentifierPatternCharacters) {
      return null;
    }
    for (final candidate in <String>{configured, configured.trim()}) {
      if (candidate.isEmpty) continue;
      // Fresh create/stream responses fail closed even when a short credential
      // is embedded in an identifier. Collection endpoints can opt out of
      // short substring matching because an API key such as `a` would
      // otherwise hide most ordinary server-owned IDs; exact matches remain
      // rejected in both modes.
      if (value == candidate ||
          ((rejectShortSensitiveSubstrings ||
                  candidate.length >=
                      _minSensitiveIdentifierSubstringCharacters) &&
              value.contains(candidate))) {
        return null;
      }
    }
  }
  return value;
}
