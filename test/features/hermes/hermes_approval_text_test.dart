import 'package:conduit_core/features/hermes/services/hermes_approval_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'retains multiline command and indentation beyond the old summary cap',
    () {
      final command = List.generate(
        80,
        (i) => '  echo verify step $i',
      ).join('\n');
      expect(command.length, greaterThan(512));
      expect(sanitizeHermesApprovalText(command), command);
    },
  );
  test(
    'redacts configured and reflected credentials while retaining line breaks',
    () {
      final text = sanitizeHermesApprovalText(
        'echo private-key\nAuthorization: Digest username="u", response="secret-digest"\nCookie: session=hidden-cookie; csrf=hidden-csrf\napi_key=unknown-key\necho done',
        sensitiveValues: ['private-key'],
      )!;
      for (final secret in [
        'private-key',
        'secret-digest',
        'hidden-cookie',
        'hidden-csrf',
        'unknown-key',
      ]) {
        expect(text, isNot(contains(secret)));
      }
      expect(text, contains('\necho done'));
    },
  );
  test('oversize command is bounded and explicitly marked as incomplete', () {
    final text = sanitizeHermesApprovalText('😀' * 40000)!;
    expect(text, endsWith(kHermesApprovalTextTruncated));
    expect(
      text.runes.length,
      lessThanOrEqualTo(
        kMaxHermesApprovalTextCharacters + kHermesApprovalTextTruncated.length,
      ),
    );
  });
  test('oversize configured redaction set fails closed', () {
    expect(
      sanitizeHermesApprovalText('show secret', sensitiveValues: ['x' * 9000]),
      isNull,
    );
  });
}
