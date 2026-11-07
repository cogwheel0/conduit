import 'package:checks/checks.dart';
import 'package:conduit_core/utils/sensitive_value_utils.dart';
import 'package:test/test.dart';

void main() {
  test('a quoted key and a quoted value are redacted whole', () {
    final safe = redactCredentialLabels(
      '{"password": "two word secret", "user": "ada"}\n'
      "api_key='alpha beta'",
      keepLines: true,
    );

    check(safe).not((it) => it.contains('two word'));
    check(safe).not((it) => it.contains('secret",'));
    check(safe).not((it) => it.contains('alpha'));
    check(safe).not((it) => it.contains('beta'));
    check(safe).contains('"user": "ada"');
    // A diff keeps its lines.
    check(safe.split('\n')).length.equals(2);
  });

  test('an Authorization value goes with its scheme', () {
    check(
      redactCredentialLabels('Authorization: Bearer service-token'),
    ).not((it) => it.contains('service-token'));
  });
}
