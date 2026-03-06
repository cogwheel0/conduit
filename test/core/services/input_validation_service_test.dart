import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/core/services/input_validation_service.dart';

void main() {
  group('InputValidationService', () {
    group('validateEmail', () {
      test('returns null for valid email', () {
        check(InputValidationService.validateEmail('user@example.com'))
            .isNull();
      });

      test('returns null for valid email with subdomain', () {
        check(InputValidationService.validateEmail('user@mail.example.com'))
            .isNull();
      });

      test('returns error for invalid email without domain', () {
        check(InputValidationService.validateEmail('user@'))
            .isA<String>();
      });

      test('returns error for invalid email without @', () {
        check(InputValidationService.validateEmail('userexample.com'))
            .isA<String>();
      });

      test('returns error for empty string', () {
        check(InputValidationService.validateEmail(''))
            .isA<String>();
      });

      test('returns error for null', () {
        check(InputValidationService.validateEmail(null))
            .isA<String>();
      });
    });

    group('validateUrl', () {
      test('returns null for valid URL with https', () {
        check(InputValidationService.validateUrl('https://example.com'))
            .isNull();
      });

      test('returns null for valid URL with http', () {
        check(InputValidationService.validateUrl('http://example.com'))
            .isNull();
      });

      test('returns null for URL without scheme (auto-prepends http)',
          () {
        check(InputValidationService.validateUrl('example.com'))
            .isNull();
      });

      test('returns null for IP with port', () {
        check(InputValidationService.validateUrl('http://192.168.1.10:3000'))
            .isNull();
      });

      test('returns error for invalid IP address', () {
        check(InputValidationService.validateUrl('http://999.999.999.999'))
            .isA<String>();
      });

      test('returns error for empty when required', () {
        check(InputValidationService.validateUrl('', required: true))
            .isA<String>();
      });

      test('returns null for empty when not required', () {
        check(InputValidationService.validateUrl('', required: false))
            .isNull();
      });
    });

    group('validatePassword', () {
      test('returns error for empty password', () {
        check(InputValidationService.validatePassword(''))
            .isA<String>();
      });

      test('returns error for short password', () {
        check(InputValidationService.validatePassword('Ab1!'))
            .isA<String>();
      });

      test('returns error for weak password when checkStrength=true',
          () {
        // 8 chars but no special char
        check(InputValidationService.validatePassword('Abcdefg1'))
            .isA<String>();
      });

      test('returns null for strong password', () {
        check(InputValidationService.validatePassword('Abcdef1!'))
            .isNull();
      });

      test(
          'returns null for long password without strength '
          'when checkStrength=false', () {
        check(InputValidationService.validatePassword(
          'abcdefgh',
          checkStrength: false,
        )).isNull();
      });
    });

    group('validateRequired', () {
      test('returns error for empty string', () {
        check(InputValidationService.validateRequired(''))
            .isA<String>();
      });

      test('returns error for whitespace-only string', () {
        check(InputValidationService.validateRequired('   '))
            .isA<String>();
      });

      test('returns error for null', () {
        check(InputValidationService.validateRequired(null))
            .isA<String>();
      });

      test('returns null for non-empty string', () {
        check(InputValidationService.validateRequired('hello'))
            .isNull();
      });

      test('includes field name in error message', () {
        check(InputValidationService.validateRequired(
          '',
          fieldName: 'Name',
        )).isA<String>().contains('Name');
      });
    });

    group('validateMinLength', () {
      test('returns null when length meets minimum', () {
        check(InputValidationService.validateMinLength('abcde', 5))
            .isNull();
      });

      test('returns error when too short', () {
        check(InputValidationService.validateMinLength('ab', 5))
            .isA<String>();
      });

      test('returns error for empty string', () {
        check(InputValidationService.validateMinLength('', 3))
            .isA<String>();
      });

      test('returns error for null', () {
        check(InputValidationService.validateMinLength(null, 3))
            .isA<String>();
      });
    });

    group('validateMaxLength', () {
      test('returns null when within max length', () {
        check(InputValidationService.validateMaxLength('abc', 5))
            .isNull();
      });

      test('returns error when exceeding max length', () {
        check(InputValidationService.validateMaxLength('abcdef', 5))
            .isA<String>();
      });

      test('returns null for null value', () {
        check(InputValidationService.validateMaxLength(null, 5))
            .isNull();
      });

      test('returns null for empty string', () {
        check(InputValidationService.validateMaxLength('', 5))
            .isNull();
      });
    });

    group('validateNumber', () {
      test('returns null for valid number in range', () {
        check(InputValidationService.validateNumber('5', min: 1, max: 10))
            .isNull();
      });

      test('returns error for number below min', () {
        check(InputValidationService.validateNumber('0', min: 1))
            .isA<String>();
      });

      test('returns error for number above max', () {
        check(InputValidationService.validateNumber('11', max: 10))
            .isA<String>();
      });

      test('returns error for non-numeric string', () {
        check(InputValidationService.validateNumber('abc'))
            .isA<String>();
      });

      test('returns error for empty when required', () {
        check(InputValidationService.validateNumber('', required: true))
            .isA<String>();
      });

      test('returns null for empty when not required', () {
        check(InputValidationService.validateNumber(
          '',
          required: false,
        )).isNull();
      });

      test('returns null for decimal when allowDecimal is true', () {
        check(InputValidationService.validateNumber('3.14'))
            .isNull();
      });

      test('returns error for decimal when allowDecimal is false', () {
        check(InputValidationService.validateNumber(
          '3.14',
          allowDecimal: false,
        )).isA<String>();
      });
    });

    group('validateUsername', () {
      test('returns null for valid username', () {
        check(InputValidationService.validateUsername('user_123'))
            .isNull();
      });

      test('returns null for 3-char username', () {
        check(InputValidationService.validateUsername('abc'))
            .isNull();
      });

      test('returns null for 20-char username', () {
        check(InputValidationService.validateUsername('a' * 20))
            .isNull();
      });

      test('returns error for too short username', () {
        check(InputValidationService.validateUsername('ab'))
            .isA<String>();
      });

      test('returns error for too long username', () {
        check(InputValidationService.validateUsername('a' * 21))
            .isA<String>();
      });

      test('returns error for username with invalid characters', () {
        check(InputValidationService.validateUsername('user@name'))
            .isA<String>();
      });

      test('returns error for username with spaces', () {
        check(InputValidationService.validateUsername('user name'))
            .isA<String>();
      });

      test('returns error for empty username', () {
        check(InputValidationService.validateUsername(''))
            .isA<String>();
      });

      test('returns error for null username', () {
        check(InputValidationService.validateUsername(null))
            .isA<String>();
      });
    });

    group('sanitizeInput', () {
      test('escapes HTML angle brackets', () {
        final result = InputValidationService.sanitizeInput('<b>bold</b>');
        check(result).not((it) => it.contains('<'));
        check(result).not((it) => it.contains('>'));
        check(result).contains('&lt;');
        check(result).contains('&gt;');
      });

      test('escapes script tags', () {
        final result = InputValidationService.sanitizeInput(
          '<script>alert("xss")</script>',
        );
        check(result).not((it) => it.contains('<script>'));
      });

      test('escapes double quotes', () {
        final result = InputValidationService.sanitizeInput('say "hello"');
        check(result).not((it) => it.contains('"'));
        check(result).contains('&quot;');
      });

      test('escapes single quotes', () {
        final result = InputValidationService.sanitizeInput("it's");
        check(result).not((it) => it.contains("'"));
        check(result).contains('&#x27;');
      });

      test('escapes forward slashes', () {
        final result = InputValidationService.sanitizeInput('a/b');
        check(result).not((it) => it.contains('/'));
        check(result).contains('&#x2F;');
      });

      test('returns plain text unchanged', () {
        check(InputValidationService.sanitizeInput('hello world'))
            .equals('hello world');
      });
    });
  });
}
