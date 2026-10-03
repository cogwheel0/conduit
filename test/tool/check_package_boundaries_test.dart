import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/check_package_boundaries.dart';

void main() {
  group('stripSwiftLineComment', () {
    test('drops a trailing comment', () {
      check(stripSwiftLineComment('let a = 1 // AppDelegate'))
          .equals('let a = 1 ');
    });

    test('keeps code after a // inside a string literal', () {
      const line = 'let u = "https://x.test"; _ = AppDelegate.self // note';
      check(stripSwiftLineComment(line)).contains('AppDelegate');
      check(stripSwiftLineComment(line)).not((it) => it.contains('note'));
    });

    test('handles escaped quotes inside strings', () {
      const line = r'let s = "a\"//b"; x() // c';
      check(stripSwiftLineComment(line)).equals(r'let s = "a\"//b"; x() ');
    });
  });
}
