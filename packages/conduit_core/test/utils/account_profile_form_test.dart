import 'package:checks/checks.dart';
import 'package:conduit_core/utils/account_profile_form.dart';
import 'package:test/test.dart';

void main() {
  group('profile gender', () {
    test('empty, male and female map to their choice', () {
      check(splitProfileGender(null)).equals((choice: '', custom: ''));
      check(splitProfileGender('  ')).equals((choice: '', custom: ''));
      check(splitProfileGender(' male ')).equals((choice: 'male', custom: ''));
      check(splitProfileGender('female'))
          .equals((choice: 'female', custom: ''));
    });

    test('anything else is a custom gender', () {
      check(splitProfileGender(' Nonbinary '))
          .equals((choice: kProfileGenderCustom, custom: 'Nonbinary'));
    });

    test('the saved value follows the choice', () {
      check(resolveProfileGender('male', 'ignored')).equals('male');
      check(resolveProfileGender('custom', '  Agender ')).equals('Agender');
      check(resolveProfileGender('', 'ignored')).equals('');
      check(resolveProfileGender('unknown', 'ignored')).equals('');
    });
  });

  group('profile birth date', () {
    test('parses and formats the stored day', () {
      check(parseProfileBirthDate(' ')).isNull();
      check(parseProfileBirthDate('not a date')).isNull();
      check(parseProfileBirthDate('1990-02-03')).equals(DateTime(1990, 2, 3));
      check(formatProfileBirthDate(DateTime(1990, 2, 3, 22, 15)))
          .equals('1990-02-03');
    });

    test('clamps to 1900 and today', () {
      final now = DateTime(2026, 9, 29);
      check(clampProfileBirthDate(DateTime(1850), now: now))
          .equals(DateTime(1900));
      check(clampProfileBirthDate(DateTime(2030), now: now)).equals(now);
      check(clampProfileBirthDate(DateTime(1990, 5, 6), now: now))
          .equals(DateTime(1990, 5, 6));
    });
  });
}
