/// User-facing error phrasing moved out of `lib/core/error` and into
/// `lib/shared`, because composing prose needs a locale and the core will not
/// have one once `conduitd` hosts it. These cases came with it unchanged, so
/// the wording users see is provably the same.
library;

import 'package:checks/checks.dart';
import 'package:conduit_core/error/api_error.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:conduit/shared/utils/api_error_messages.dart';
import 'package:conduit_core/conduit_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final l10n = AppLocalizationsEn();

  group('getUserMessage', () {
    test('returns non-empty string for network error', () {
      const error = ApiError.network(message: 'Connection failed');
      final msg = userFacingApiError(error, l10n);
      check(msg).isNotEmpty();
      check(msg).contains('check your connection');
    });

    test('returns non-empty string for timeout error', () {
      const error = ApiError.timeout(message: 'Timed out');
      final msg = userFacingApiError(error, l10n);
      check(msg).isNotEmpty();
      check(msg).contains('request timed out');
    });

    test('returns non-empty string for authentication error', () {
      const error = ApiError.authentication(message: 'Unauthorized');
      final msg = userFacingApiError(error, l10n);
      check(msg).isNotEmpty();
      check(msg).contains('sign in');
    });

    test('returns non-empty string for authorization error', () {
      const error = ApiError.authorization(message: 'Forbidden');
      final msg = userFacingApiError(error, l10n);
      check(msg).isNotEmpty();
      check(msg).contains('permission');
    });

    test('returns non-empty string for validation error', () {
      const error = ApiError.validation(message: 'Invalid data');
      final msg = userFacingApiError(error, l10n);
      check(msg).isNotEmpty();
      check(msg).contains('input');
    });

    test('returns non-empty string for rateLimit error', () {
      const error = ApiError.rateLimit(message: 'Too many requests');
      final msg = userFacingApiError(error, l10n);
      check(msg).isNotEmpty();
      check(msg).contains('wait');
    });

    test('includes time info for rateLimit with retryAfter', () {
      const error = ApiError.rateLimit(
        message: 'Too many requests',
        retryAfter: Duration(seconds: 90),
      );
      final msg = userFacingApiError(error, l10n);
      check(msg).contains('1m');
      check(msg).contains('30s');
    });

    test('returns non-empty string for server error', () {
      const error = ApiError.server(
        message: 'Internal server error',
        statusCode: 500,
      );
      final msg = userFacingApiError(error, l10n);
      check(msg).isNotEmpty();
      check(msg).contains('Server is having problems');
    });

    test('returns base message for unknown error type', () {
      const error = ApiError.unknown(message: 'Something happened');
      final msg = userFacingApiError(error, l10n);
      check(msg).equals('Something happened');
    });
  });
  group('localizeCoreError', () {
    test('every code renders a non-empty string in English', () {
      // The resolver switch is exhaustive, so this cannot miss a code; what
      // it catches is an ARB key that exists but resolves to empty.
      for (final code in CoreErrorCode.values) {
        final rendered = localizeCoreError(ErrorMessage(code), l10n);
        check(because: '$code', rendered).isNotEmpty();
      }
    });

    test('interpolates rate-limit delay into the message', () {
      final rendered = localizeCoreError(
        const ErrorMessage(
          CoreErrorCode.rateLimitRetryAfter,
          args: {'delay': '2m 30s'},
        ),
        l10n,
      );
      check(rendered).contains('2m 30s');
    });
  });

  group('describeApiError', () {
    test('prefers server prose over the classification', () {
      // The server knows more than we do about why it said no.
      const error = ApiError.server(message: 'Model queue is full');
      check(describeApiError(error, l10n)).equals('Model queue is full');
    });

    test('falls back to the code when the server said nothing', () {
      const error = ApiError.server();
      check(describeApiError(error, l10n)).equals(l10n.serverErrorGeneric);
    });

    test('treats blank server prose as absent', () {
      const error = ApiError.network(message: '   ');
      check(describeApiError(error, l10n)).equals(l10n.networkGenericError);
    });
  });

  group('formatRetryDelay', () {
    test('renders minutes and seconds', () {
      check(formatRetryDelay(const Duration(minutes: 2, seconds: 30)))
          .equals('2m 30s');
      check(formatRetryDelay(const Duration(minutes: 3))).equals('3m');
      check(formatRetryDelay(const Duration(seconds: 45))).equals('45s');
    });
  });
}
