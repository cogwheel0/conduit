/// Derives bounded redaction candidates from one configured credential-bearing
/// header value.
///
/// Besides the complete value, this includes cookie pairs and their right-hand
/// sides (`session=token; csrf=token`) plus authorization payloads
/// (`Bearer token`, Digest parameters). Providers and transports sometimes
/// reflect only one of these components rather than the original header.
/// Returns `null` when the input or derived candidate count exceeds its budget
/// so callers can fail closed.
List<String>? boundedSensitiveValueVariants(
  String raw, {
  required int maxCharacters,
  required int maxVariants,
}) {
  if (maxCharacters <= 0) {
    throw RangeError.value(maxCharacters, 'maxCharacters');
  }
  if (maxVariants <= 0) {
    throw RangeError.value(maxVariants, 'maxVariants');
  }
  if (raw.length > maxCharacters) return null;

  final values = <String>{};
  var invalid = false;

  void add(String candidate) {
    if (invalid || candidate.isEmpty || values.contains(candidate)) return;
    if (candidate.length > maxCharacters || values.length >= maxVariants) {
      invalid = true;
      values.clear();
      return;
    }
    values.add(candidate);
  }

  void addWithOptionalQuotes(String candidate) {
    final trimmed = candidate.trim();
    add(trimmed);
    if (trimmed.length < 2) return;
    final first = trimmed.codeUnitAt(0);
    final last = trimmed.codeUnitAt(trimmed.length - 1);
    final isQuoted =
        (first == 0x22 && last == 0x22) || (first == 0x27 && last == 0x27);
    if (isQuoted) add(trimmed.substring(1, trimmed.length - 1));
  }

  // Preserve the exact value for full reflection, while also treating an
  // entirely quoted credential as sensitive without its transport quotes.
  add(raw);
  final trimmed = raw.trim();
  addWithOptionalQuotes(trimmed);
  if (invalid) return null;

  // Cookie and Digest headers use semicolon/comma-delimited key-value pairs.
  // Splitting is safe here because [raw] was bounded before any allocation.
  for (final component in trimmed.split(RegExp(r'[;,]'))) {
    final part = component.trim();
    add(part);
    final equals = part.indexOf('=');
    if (equals >= 0 && equals + 1 < part.length) {
      addWithOptionalQuotes(part.substring(equals + 1));
    }
    if (invalid) return null;
  }

  // Authorization-style values place a scheme before the credential. Retain
  // both the complete payload and its first token for custom schemes.
  final authorization = RegExp(
    r'^[A-Za-z][A-Za-z0-9_-]*\s+(.+)$',
  ).firstMatch(trimmed);
  final payload = authorization?.group(1)?.trim();
  if (payload != null && payload.isNotEmpty) {
    addWithOptionalQuotes(payload);
    final token = payload.split(RegExp(r'\s+')).first;
    addWithOptionalQuotes(token);
  }

  return invalid ? null : List<String>.unmodifiable(values);
}
