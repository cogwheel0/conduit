import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/openwebui_two_step.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// Answers every request with [status] and [body], and records the requests.
class _Adapter implements HttpClientAdapter {
  _Adapter(this.body, {this.status = 200});

  final Map<String, dynamic> body;
  final int status;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromBytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

ApiService _api(_Adapter adapter) {
  final service = ApiService(
    serverConfig: const ServerConfig(
      id: 'test',
      name: 'Test Server',
      url: 'http://localhost:9999',
    ),
    workerManager: WorkerManager(),
  );
  service.dio.httpClientAdapter = adapter;
  service.dio.interceptors.clear();
  return service;
}

/// Open WebUI 0.12's `/api/v1/auths/mfa` routes, as the sign-in uses them.
void main() {
  const token = 'user-1.challenge-token-value';

  test('a code is verified with the challenge it answers', () async {
    final adapter = _Adapter({
      'token': 'issued-session',
      'token_type': 'Bearer',
      'id': 'user-1',
    });

    final session = await _api(
      adapter,
    ).verifyTwoStepCode(token, 'a1b2c3', recovery: true);

    check(session.token).equals('issued-session');
    check(session.recoveryCodes).isEmpty();
    final request = adapter.requests.single;
    check(request.method).equals('POST');
    check(request.path).equals('/api/v1/auths/mfa/verify');
    check(request.data as Map<String, dynamic>).deepEquals({
      'challenge_token': token,
      'code': 'a1b2c3',
      'recovery': true,
    });
  });

  test('reaches the server before any session exists', () async {
    // With the client's own interceptors, as sign-in sends it: no session
    // token, and none asked for.
    final adapter = _Adapter({'token': 'issued-session'});
    final service = ApiService(
      serverConfig: const ServerConfig(
        id: 'test',
        name: 'Test Server',
        url: 'http://localhost:9999',
      ),
      workerManager: WorkerManager(),
    );
    service.dio.httpClientAdapter = adapter;

    final session = await service.verifyTwoStepCode(token, '123456');

    check(session.token).equals('issued-session');
    check(adapter.requests.single.headers.containsKey('Authorization'))
        .isFalse();
  });

  test('a new authenticator is set up and confirmed', () async {
    final setupAdapter = _Adapter({
      'manual_key': 'JBSWY3DPEHPK3PXP',
      'qr_code': 'data:image/svg+xml;base64,PHN2Zy8+',
    });
    final setup = await _api(setupAdapter).startTwoStepEnrollment(token);
    check(setup.manualKey).equals('JBSWY3DPEHPK3PXP');
    check(setup.qrSvg).equals('<svg/>');
    check(setupAdapter.requests.single.path)
        .equals('/api/v1/auths/mfa/enroll/start');
    check(setupAdapter.requests.single.data as Map<String, dynamic>)
        .deepEquals({'challenge_token': token});

    final confirmAdapter = _Adapter({
      'token': 'issued-session',
      'recovery_codes': ['code-one', 'code-two'],
    });
    final session = await _api(
      confirmAdapter,
    ).confirmTwoStepEnrollment(token, '123456');
    check(session.recoveryCodes).deepEquals(['code-one', 'code-two']);
    check(confirmAdapter.requests.single.path)
        .equals('/api/v1/auths/mfa/enroll/confirm');
    check(confirmAdapter.requests.single.data as Map<String, dynamic>)
        .deepEquals({'challenge_token': token, 'code': '123456'});
  });

  test('a recovery token leads on to setting up an authenticator', () async {
    final adapter = _Adapter({
      'next_step': 'enroll',
      'challenge_token': 'user-1.next-challenge-token',
      'expires_in': 300,
    });

    final next = await _api(
      adapter,
    ).redeemTwoStepResetToken(token, 'operator-reset-token-value');

    check(next.kind).equals(OpenWebUiTwoStepKind.enroll);
    check(next.challengeToken).equals('user-1.next-challenge-token');
    check(adapter.requests.single.path).equals('/api/v1/auths/mfa/recover');
    check(adapter.requests.single.data as Map<String, dynamic>).deepEquals({
      'challenge_token': token,
      'reset_token': 'operator-reset-token-value',
    });
  });

  test('a refusal says why', () async {
    for (final (status, detail, failure) in [
      (
        401,
        'Invalid or already used code.',
        OpenWebUiTwoStepFailure.invalidCode,
      ),
      (
        401,
        'This authentication step expired. Please start again.',
        OpenWebUiTwoStepFailure.expired,
      ),
      (
        429,
        'Too many codes. Please sign in again.',
        OpenWebUiTwoStepFailure.tooManyAttempts,
      ),
    ]) {
      final adapter = _Adapter({'detail': detail}, status: status);
      await check(_api(adapter).verifyTwoStepCode(token, '000000'))
          .throws<OpenWebUiTwoStepException>(
            (it) => it.has((e) => e.failure, 'failure').equals(failure),
          );
    }
  });
}
