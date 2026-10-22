import 'package:conduit_core/utils/unicode_prefix.dart';
import 'package:conduit_core/utils/sensitive_value_utils.dart';

const kMaxHermesApprovalTextCharacters = 32768;
const kHermesApprovalTextTruncated = '\n[…command truncated]';

/// Bounded approval text retains newlines and indentation for command review.
/// Configured credentials and common credential assignments remain redacted.
String? sanitizeHermesApprovalText(
  String? value, {
  Iterable<String> sensitiveValues = const [],
}) {
  if (value == null || value.trim().isEmpty) return null;
  final unique = <String>{};
  var characters = 0;
  for (final secret in sensitiveValues) {
    if (secret.isEmpty || !unique.add(secret)) continue;
    characters += secret.length;
    if (secret.length > kMaxProviderErrorSecretCharacters ||
        unique.length > kMaxProviderErrorSecrets ||
        characters > kMaxProviderErrorSecretTotalCharacters) {
      return null;
    }
  }
  final secrets = unique.toList()..sort((a, b) => b.length.compareTo(a.length));
  var safe = redactSensitiveValuesInUnicodePrefix(
    value,
    sensitiveValues: secrets,
    maxVisibleScalars: kMaxHermesApprovalTextCharacters,
  );
  safe = safe
      .replaceAllMapped(
        RegExp(
          r'\b(authorization|proxy-authorization|cookie)\b\s*[:=]\s*[^\r\n]*',
          caseSensitive: false,
        ),
        (match) => '${match.group(1)}: [REDACTED]',
      )
      .replaceAll(
        RegExp(r'\bBearer\s+[^\s,;]+', caseSensitive: false),
        'Bearer [REDACTED]',
      )
      .replaceAllMapped(
        RegExp(
          r'\b(api[-_ ]?key|access[-_ ]?token|password|secret|session[-_ ]?key)\b\s*[:=]\s*[^\s,;]+',
          caseSensitive: false,
        ),
        (match) => '${match.group(1)}: [REDACTED]',
      )
      .replaceAll(
        RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F]'),
        ' ',
      )
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n');
  final truncated =
      value.runes.take(kMaxHermesApprovalTextCharacters + 1).length >
          kMaxHermesApprovalTextCharacters ||
      safe.runes.take(kMaxHermesApprovalTextCharacters + 1).length >
          kMaxHermesApprovalTextCharacters;
  safe = takeUnicodeScalarPrefix(safe, kMaxHermesApprovalTextCharacters);
  if (truncated) {
    safe += kHermesApprovalTextTruncated;
  }
  return safe.trim().isEmpty ? null : safe;
}
