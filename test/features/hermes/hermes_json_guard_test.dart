import 'package:checks/checks.dart';
import 'package:conduit/features/hermes/services/hermes_json_guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('validateHermesJsonSource', () {
    test('ignores structural characters inside escaped strings', () {
      check(
        () => validateHermesJsonSource(r'{"value":"[\\\"]{}"}', maxDepth: 1),
      ).returnsNormally();
    });

    test('rejects depth before decoding', () {
      check(() => validateHermesJsonSource('[[0]]', maxDepth: 1))
          .throws<HermesJsonGuardException>()
          .has((error) => error.limit, 'limit')
          .equals(HermesJsonLimit.depth);
    });

    test('rejects more than 100k compact allocation-bearing nodes', () {
      final source = '[${List<String>.filled(100000, '0').join(',')}]';

      check(() => validateHermesJsonSource(source))
          .throws<HermesJsonGuardException>()
          .has((error) => error.limit, 'limit')
          .equals(HermesJsonLimit.nodes);
    });

    test('bounds punctuation tokens independently of value nodes', () {
      check(() => validateHermesJsonSource('[0,0]', maxNodes: 10, maxTokens: 4))
          .throws<HermesJsonGuardException>()
          .has((error) => error.limit, 'limit')
          .equals(HermesJsonLimit.tokens);
    });
  });
}
