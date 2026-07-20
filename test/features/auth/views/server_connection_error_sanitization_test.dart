import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/core/network/conduit_user_agent.dart';
import 'package:conduit/features/auth/views/server_connection_page.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'captured proxy cookies replace stale names and normalize header casing',
    () {
      final merged = mergeCapturedProxyCookiesIntoHeaders(
        headers: const {
          'cookie': 'session=stale; theme=dark; token=old=payload',
          'COOKIE': 'csrf=stale',
          'X-Proxy': 'preserved',
        },
        capturedCookies: const {'session': 'fresh', 'csrf': 'fresh-csrf'},
      );

      check(merged['X-Proxy']).equals('preserved');
      check(
        merged.keys.where((key) => key.toLowerCase() == 'cookie').toList(),
      ).deepEquals(['Cookie']);
      check(
        merged['Cookie'],
      ).equals('session=fresh; theme=dark; token=old=payload; csrf=fresh-csrf');
    },
  );

  test('scheme-less plaintext probe sends only the public user agent', () {
    final options = buildSchemeLessPlaintextHealthProbeOptions(
      'http://openwebui.example',
    );

    check(options.headers).deepEquals(<String, dynamic>{
      ConduitUserAgent.headerName: ConduitUserAgent.value,
    });
    check(options.followRedirects).isFalse();
  });

  test(
    'custom-header redaction survives a supplementary-character boundary',
    () {
      const secret = 'ZXQVB_UNICODE_BOUNDARY_SECRET';
      final reflected = '${List<String>.filled(6, '😀').join()}$secret';

      final safe = sanitizeServerConnectionProviderText(
        reflected,
        sensitiveValues: const [secret],
        maxCharacters: 8,
      );

      check(safe).isNotNull();
      // The unfixed UTF-16 prefix leaked the first `Z` before its ellipsis.
      check(safe!).not((value) => value.contains('Z'));
      check(safe.runes.length).equals(8);
    },
  );

  test('custom-header redaction drops a fragment before normalization', () {
    const secret = 'ZXQVB_UNICODE_BOUNDARY_SECRET';
    final reflected = '${List<String>.filled(20, ' ').join()}$secret';

    final safe = sanitizeServerConnectionProviderText(
      reflected,
      sensitiveValues: const [secret],
      maxCharacters: 8,
    );

    check(safe).equals('[REDACT…');
    check(safe!.runes.length).equals(8);
  });

  test(
    'custom-header redaction covers cookie and authorization components',
    () {
      const cookieToken = 'COOKIE_COMPONENT_SECRET';
      const csrfToken = 'CSRF_COMPONENT_SECRET';
      const authorizationToken = 'AUTH_COMPONENT_SECRET';
      const quotedToken = 'QUOTED_COMPONENT_SECRET';

      final safe = sanitizeServerConnectionProviderText(
        'provider reflected $cookieToken, $csrfToken, $authorizationToken, '
        'and $quotedToken',
        sensitiveValues: const [
          'session=$cookieToken; csrf=$csrfToken',
          'Bearer $authorizationToken',
          '"$quotedToken"',
        ],
      );

      check(safe).isNotNull();
      check(safe!).contains('[REDACTED]');
      check(safe).not((value) => value.contains(cookieToken));
      check(safe).not((value) => value.contains(csrfToken));
      check(safe).not((value) => value.contains(authorizationToken));
      check(safe).not((value) => value.contains(quotedToken));
    },
  );

  test('Dio formatter redacts status, redirect, and response details', () {
    const secret = 'custom-header-provider-secret';
    const querySecret = 'query-secret-sentinel';
    final request = RequestOptions(
      path:
          'https://user:password@openwebui.example/health?token=$querySecret#fragment',
    );
    final response = Response<dynamic>(
      requestOptions: request,
      statusCode: 502,
      statusMessage: 'upstream reflected $secret',
      headers: Headers.fromMap({
        'location': ['/proxy/sign-in?reason=$secret'],
      }),
      data: {'detail': 'provider body reflected $secret'},
    );
    final error = DioException(requestOptions: request, response: response);

    final safe = formatServerConnectionDioExceptionForDisplay(
      error,
      sensitiveValues: const [secret],
    );

    check(safe).contains('HTTP 502');
    check(safe).contains('redirected by server');
    check(safe).contains('[REDACTED]');
    check(safe).not((value) => value.contains(secret));
    check(safe).not((value) => value.contains(querySecret));
    check(safe).not((value) => value.contains('user:password'));
    check(safe.runes.length).isLessOrEqual(640);
  });

  test('Dio formatter never replays a wrapped transport URI', () {
    const wrappedSecret = 'wrapped-uri-secret';
    final request = RequestOptions(path: 'https://openwebui.example/health');
    final error = DioException(
      requestOptions: request,
      type: DioExceptionType.connectionError,
      error: HttpException(
        'connection failed',
        uri: Uri.parse(
          'https://user:$wrappedSecret@other.example/path?token=$wrappedSecret',
        ),
      ),
    );

    final safe = formatServerConnectionDioExceptionForDisplay(
      error,
      sensitiveValues: const <String>[],
    );

    check(safe).contains('connectionError');
    check(safe).not((value) => value.contains(wrappedSecret));
    check(safe).not((value) => value.contains('other.example'));
  });

  test('Dio formatter never reflects a response request host or path', () {
    const secret = 'redirected-header-secret';
    final request = RequestOptions(
      path: 'https://$secret.example/path/$secret',
    );
    final response = Response<dynamic>(
      requestOptions: request,
      statusCode: 502,
    );

    final safe = formatServerConnectionDioExceptionForDisplay(
      DioException(requestOptions: request, response: response),
      sensitiveValues: const [secret],
    );

    check(safe).contains('HTTP 502');
    check(safe).contains('from the server');
    check(safe).not((value) => value.contains(secret));
    check(safe).not((value) => value.contains('.example/path'));
  });

  test('Dio formatter never reflects a failed request host or path', () {
    const secret = 'transport-header-secret';
    final request = RequestOptions(
      path: 'https://$secret.example/path/$secret',
    );

    final safe = formatServerConnectionDioExceptionForDisplay(
      DioException(
        requestOptions: request,
        type: DioExceptionType.connectionError,
      ),
      sensitiveValues: const [secret],
    );

    check(safe).contains('connectionError while contacting the server');
    check(safe).not((value) => value.contains(secret));
    check(safe).not((value) => value.contains('.example/path'));
  });

  test('Dio formatter does not recursively expand redaction markers', () {
    const secret = 'D';
    final request = RequestOptions(path: 'https://openwebui.example/health');
    final response = Response<dynamic>(
      requestOptions: request,
      statusCode: 502,
      data: {'detail': 'reflected $secret'},
    );

    final safe = formatServerConnectionDioExceptionForDisplay(
      DioException(requestOptions: request, response: response),
      sensitiveValues: const [secret],
    );

    check(safe).contains('[REDACTED]');
    check(safe).not((value) => value.contains('[RE[REDACTED]'));
  });
}
