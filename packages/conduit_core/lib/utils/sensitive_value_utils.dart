import 'unicode_prefix.dart';

/// Budgets for the configured secrets one provider error is checked against.
/// Exceeding any of them fails closed: a provider may reflect any substring
/// of a credential, and no bounded pattern can redact every substring of an
/// oversized one.
const int kMaxProviderErrorSecretCharacters = 8 * 1024;
const int kMaxProviderErrorSecrets = 128;
const int kMaxProviderErrorSecretTotalCharacters = 64 * 1024;

const String _redacted = '[REDACTED]';

/// Makes an error reported by a model provider safe to show and persist in a
/// chat: configured secrets and common credential values are redacted,
/// control characters are removed, and the result is capped at
/// [maxCharacters] Unicode scalars. Returns [fallback] when nothing safe is
/// left or when [sensitiveValues] exceed their budgets.
String sanitizeProviderErrorMessage(
  String raw, {
  required String fallback,
  Iterable<String> sensitiveValues = const <String>[],
  int maxCharacters = 512,
}) {
  if (maxCharacters <= 0) {
    throw RangeError.value(maxCharacters, 'maxCharacters');
  }

  final secrets = <String>{};
  var secretCharacters = 0;
  for (final value in sensitiveValues) {
    if (value.isEmpty) continue;
    if (value.length > kMaxProviderErrorSecretCharacters) return fallback;
    if (!secrets.add(value)) continue;
    secretCharacters += value.length;
    if (secrets.length > kMaxProviderErrorSecrets ||
        secretCharacters > kMaxProviderErrorSecretTotalCharacters) {
      // A pathological profile must not turn an untrusted provider error into
      // either an amplification attack or a partially redacted log.
      return fallback;
    }
  }
  final orderedSecrets = secrets.toList(growable: false)
    ..sort((a, b) => b.length.compareTo(a.length));
  // Bound by Unicode scalar rather than UTF-16 code unit. Otherwise preceding
  // supplementary characters can make this prefix end inside a configured
  // secret, leaving a fragment that the exact-secret pass cannot recognize.
  var safe = redactSensitiveValuesInUnicodePrefix(
    raw,
    sensitiveValues: orderedSecrets,
    maxVisibleScalars: maxCharacters,
  );

  // Authorization values can contain a scheme followed by whitespace-rich
  // credentials (for example Digest parameters). Redact the complete header
  // value before applying the narrower single-token rules below.
  safe = safe.replaceAllMapped(
    RegExp(
      r'\b(authorization|proxy-authorization)\b\s*[:=]\s*[^\r\n]*',
      caseSensitive: false,
    ),
    (match) => '${match.group(1)}: $_redacted',
  );

  // Redact common credential labels even when a provider reflects a value
  // that was not part of the configured credentials.
  safe = safe.replaceAllMapped(
    RegExp(
      r'\b(api[-_ ]?key|access[-_ ]?token|password|secret|session[-_ ]?key)\b\s*[:=]\s*(?:bearer\s+)?[^\s,;]+',
      caseSensitive: false,
    ),
    (match) => '${match.group(1)}: $_redacted',
  );
  safe = safe.replaceAllMapped(
    RegExp(r'\bbearer\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
    (_) => 'Bearer $_redacted',
  );

  safe = safe
      .replaceAll(RegExp(r'[\u0000-\u001F\u007F-\u009F]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (safe.isEmpty) return fallback;

  final iterator = safe.runes.iterator;
  final prefix = <int>[];
  while (prefix.length < maxCharacters && iterator.moveNext()) {
    prefix.add(iterator.current);
  }
  if (!iterator.moveNext()) return String.fromCharCodes(prefix);
  if (maxCharacters == 1) return '…';
  return '${String.fromCharCodes(prefix.take(maxCharacters - 1))}…';
}

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
  final authorization = RegExp(r'^[A-Za-z][A-Za-z0-9_-]*\s+(.+)$')
      .firstMatch(trimmed);
  final payload = authorization?.group(1)?.trim();
  if (payload != null && payload.isNotEmpty) {
    addWithOptionalQuotes(payload);
    final token = payload.split(RegExp(r'\s+')).first;
    addWithOptionalQuotes(token);
  }

  return invalid ? null : List<String>.unmodifiable(values);
}
