import 'package:checks/checks.dart';
import 'package:conduit/core/utils/json_parsing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseDateTime', () {
    test('null returns approximately DateTime.now()', () {
      final before = DateTime.now();
      final result = parseDateTime(null);
      final after = DateTime.now();

      check(result.isAfter(before) || result.isAtSameMomentAs(before))
          .isTrue();
      check(result.isBefore(after) || result.isAtSameMomentAs(after))
          .isTrue();
    });

    test('DateTime value is returned as-is', () {
      final dt = DateTime(2024, 6, 15, 12, 30);
      check(parseDateTime(dt)).equals(dt);
    });

    test('ISO 8601 string is parsed', () {
      final result = parseDateTime('2024-06-15T12:30:00.000Z');
      check(result).equals(DateTime.utc(2024, 6, 15, 12, 30));
    });

    test('int is treated as Unix seconds', () {
      final result = parseDateTime(1718451000);
      final expected =
          DateTime.fromMillisecondsSinceEpoch(1718451000 * 1000);
      check(result).equals(expected);
    });

    test('malformed string returns approximately DateTime.now()', () {
      final before = DateTime.now();
      final result = parseDateTime('not-a-date');
      final after = DateTime.now();

      check(result.isAfter(before) || result.isAtSameMomentAs(before))
          .isTrue();
      check(result.isBefore(after) || result.isAtSameMomentAs(after))
          .isTrue();
    });

    test('unrecognized type returns approximately DateTime.now()', () {
      final before = DateTime.now();
      final result = parseDateTime([1, 2, 3]);
      final after = DateTime.now();

      check(result.isAfter(before) || result.isAtSameMomentAs(before))
          .isTrue();
      check(result.isBefore(after) || result.isAtSameMomentAs(after))
          .isTrue();
    });

    test('Unix timestamp 0 returns epoch', () {
      final result = parseDateTime(0);
      check(result)
          .equals(DateTime.fromMillisecondsSinceEpoch(0));
    });
  });

  group('parseDateTimeOrNull', () {
    test('null returns null', () {
      check(parseDateTimeOrNull(null)).isNull();
    });

    test('DateTime value delegates to parseDateTime', () {
      final dt = DateTime(2024, 1, 1);
      check(parseDateTimeOrNull(dt)).equals(dt);
    });

    test('ISO 8601 string delegates to parseDateTime', () {
      final result = parseDateTimeOrNull('2024-06-15T12:30:00.000Z');
      check(result).isNotNull().equals(DateTime.utc(2024, 6, 15, 12, 30));
    });

    test('int delegates to parseDateTime', () {
      final result = parseDateTimeOrNull(1718451000);
      final expected =
          DateTime.fromMillisecondsSinceEpoch(1718451000 * 1000);
      check(result).isNotNull().equals(expected);
    });
  });

  group('parseInt', () {
    test('null returns null', () {
      check(parseInt(null)).isNull();
    });

    test('int value is returned as-is', () {
      check(parseInt(42)).equals(42);
    });

    test('negative int is returned as-is', () {
      check(parseInt(-7)).equals(-7);
    });

    test('double (num) is converted to int', () {
      check(parseInt(3.14)).equals(3);
    });

    test('double with no fractional part converts cleanly', () {
      check(parseInt(5.0)).equals(5);
    });

    test('String with valid int is parsed', () {
      check(parseInt('123')).equals(123);
    });

    test('String with negative int is parsed', () {
      check(parseInt('-42')).equals(-42);
    });

    test('String with invalid value returns null', () {
      check(parseInt('abc')).isNull();
    });

    test('empty String returns null', () {
      check(parseInt('')).isNull();
    });

    test('String with decimal returns null (tryParse)', () {
      check(parseInt('3.14')).isNull();
    });

    test('unrecognized type returns null', () {
      check(parseInt([1, 2])).isNull();
    });

    test('bool returns null', () {
      check(parseInt(true)).isNull();
    });
  });
}
