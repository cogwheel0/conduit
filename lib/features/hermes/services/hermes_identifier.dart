const int kMaxHermesOpaqueIdentifierCharacters = 512;

final RegExp _hermesOpaqueIdentifierPattern = RegExp(
  r'^[A-Za-z0-9][A-Za-z0-9._~:+/=\-]*$',
);

/// Validates an opaque provider identifier without coercing provider values.
///
/// Hermes identifiers are persisted, reused as headers, and interpolated into
/// encoded path segments. Keeping one strict boundary prevents structured JSON,
/// control characters, unbounded values, and reflected credentials from
/// crossing into those sinks.
String? validateHermesOpaqueIdentifier(
  Object? value, {
  Iterable<String> sensitiveValues = const <String>[],
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
    if (value.contains(configured)) return null;
    final trimmed = configured.trim();
    if (trimmed.isNotEmpty && value.contains(trimmed)) return null;
  }
  return value;
}
