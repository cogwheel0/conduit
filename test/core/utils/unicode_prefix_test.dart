import 'package:checks/checks.dart';
import 'package:conduit/core/utils/unicode_prefix.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('redaction unions a self-overlapping boundary match', () {
    final safe = redactSensitiveValuesInUnicodePrefix(
      'aaaaa',
      sensitiveValues: const ['aaaa'],
      maxVisibleScalars: 1,
    );

    check(safe).equals('[REDACTED]');
  });

  test('redaction unions distinct overlapping secrets', () {
    final safe = redactSensitiveValuesInUnicodePrefix(
      'abcde',
      sensitiveValues: const ['abcd', 'bcde'],
      maxVisibleScalars: 32,
    );

    check(safe).equals('[REDACTED]');
  });

  test('early redaction does not expose the long detection tail', () {
    final safe = redactSensitiveValuesInUnicodePrefix(
      'absecret0123456789abcdefghijklmnopqrstuvwxyz',
      sensitiveValues: const [
        'secret',
        'a-much-longer-secret-that-does-not-match',
      ],
      maxVisibleScalars: 8,
    );

    check(safe).equals('ab[REDACTED]012345');
  });

  test('no-match output still respects the visible scalar limit', () {
    check(
      redactSensitiveValuesInUnicodePrefix(
        'abcdef',
        sensitiveValues: const ['uvwxyz'],
        maxVisibleScalars: 3,
      ),
    ).equals('abc');
    check(
      redactSensitiveValuesInUnicodePrefix(
        'abcdef',
        sensitiveValues: const ['uvwxyz'],
        maxVisibleScalars: 0,
      ),
    ).isEmpty();
  });
}
