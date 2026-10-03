import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/check_package_boundaries.dart';

void main() {
  group('stripSwiftComments', () {
    test('drops a trailing line comment', () {
      check(stripSwiftComments('let a = 1 // AppDelegate'))
          .not((it) => it.contains('AppDelegate'));
    });

    test('keeps code after a // inside a string literal', () {
      const line = 'let u = "https://x.test"; _ = AppDelegate.self // note';
      final stripped = stripSwiftComments(line);
      check(stripped).contains('AppDelegate');
      check(stripped).not((it) => it.contains('note'));
    });

    test('handles escaped quotes inside strings', () {
      const line = r'let s = "a\"//b"; x() // c';
      check(stripSwiftComments(line)).startsWith(r'let s = "a\"//b"; x() ');
    });

    test('keeps code after a block comment containing //', () {
      const line = '/* https://example.test */ let _ = AppDelegate.self';
      check(stripSwiftComments(line)).contains('AppDelegate');
    });

    test('blanks nested multi-line block comments and keeps line numbers', () {
      const source = 'a\n/* AppDelegate\n/* nested */ AppDelegate\n*/ b\nc';
      final stripped = stripSwiftComments(source);
      check(stripped).not((it) => it.contains('AppDelegate'));
      check(stripped.split('\n')).length.equals(5);
      check(stripped.split('\n')[3]).contains('b');
    });

    test('treats comment markers in a multi-line string as code', () {
      const source = 'let s = """\n// AppDelegate\n"""\nlet t = 1';
      check(stripSwiftComments(source)).contains('AppDelegate');
    });
  });
}
