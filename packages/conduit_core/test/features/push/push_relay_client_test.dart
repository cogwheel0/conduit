import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/push/services/push_relay_client.dart';
import 'package:conduit_core/network/conduit_user_agent.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  late _Relay relay;
  late PushRelayClient client;

  setUp(() {
    relay = _Relay();
    client = PushRelayClient(
      baseUrl: 'https://relay.test/',
      dio: Dio()..httpClientAdapter = relay,
    );
  });

  test('reads the relay info', () async {
    final info = await client.info();

    check(info.proto).equals(1);
    check(info.activeKid).equals(3);
    check(info.maxBody).equals(2134);
    check(info.providers).deepEquals(['apns', 'fcm']);
    check(relay.requests.single.uri.toString())
        .equals('https://relay.test/v1/info');
  });

  test('registers a token and returns the sealed endpoint', () async {
    final registration = await client.register(
      provider: 'apns',
      token: 'ab' * 32,
      app: 'app.cogwheel.conduit',
      env: 'dev',
      sid: 'AAAAAAAAAAAAAAAAAAAAAA',
    );

    check(registration.kid).equals(3);
    check(registration.endpoint).startsWith('https://relay.test/v1/push/');
    check(PushRelayClient.kidOfEndpoint(registration.endpoint)).equals(3);
    check(jsonDecode(relay.requests.single.data as String) as Map).deepEquals({
      'provider': 'apns',
      'token': 'ab' * 32,
      'app': 'app.cogwheel.conduit',
      'env': 'dev',
      'sid': 'AAAAAAAAAAAAAAAAAAAAAA',
    });
  });

  test('sends nothing that identifies an account', () async {
    await client.info();
    await client.register(
      provider: 'fcm',
      token: 'token-token-token-token',
      app: 'app',
      env: 'prod',
      sid: 'AAAAAAAAAAAAAAAAAAAAAA',
    );

    for (final request in relay.requests) {
      final names = request.headers.keys.map((k) => k.toLowerCase()).toSet()
        ..remove('content-type')
        ..remove('content-length');
      check(names).deepEquals({'user-agent'});
      check(request.headers[ConduitUserAgent.headerName])
          .equals(ConduitUserAgent.value);
    }
  });

  group('maps relay errors', () {
    Future<PushRelayException> registerError() async {
      try {
        await client.register(
          provider: 'apns',
          token: 'ab' * 32,
          app: 'app',
          env: 'dev',
          sid: 'AAAAAAAAAAAAAAAAAAAAAA',
        );
      } on PushRelayException catch (error) {
        return error;
      }
      throw StateError('no error');
    }

    test('400 invalid_request', () async {
      relay.registerStatus = 400;
      relay.registerError = 'invalid_request';
      check((await registerError()).kind)
          .equals(PushRelayErrorKind.invalidRequest);
    });

    test('403 app_not_allowed', () async {
      relay.registerStatus = 403;
      relay.registerError = 'app_not_allowed';
      check((await registerError()).kind)
          .equals(PushRelayErrorKind.appNotAllowed);
    });

    test('429 with Retry-After', () async {
      relay.registerStatus = 429;
      relay.registerError = 'rate_limited';
      relay.retryAfter = '42';
      final error = await registerError();
      check(error.kind).equals(PushRelayErrorKind.rateLimited);
      check(error.retryAfter).equals(const Duration(seconds: 42));
    });

    test('503 provider_unconfigured', () async {
      relay.registerStatus = 503;
      relay.registerError = 'provider_unconfigured';
      check((await registerError()).kind)
          .equals(PushRelayErrorKind.providerUnconfigured);
    });

    test('a 200 that is not the relay API', () async {
      relay.registerBody = {'hello': 'world'};
      check((await registerError()).kind)
          .equals(PushRelayErrorKind.invalidResponse);
    });

    test('an unreachable relay', () async {
      relay.fail = true;
      check((await registerError()).kind).equals(PushRelayErrorKind.network);
      await check(client.info()).throws<PushRelayException>();
    });
  });

  group('kidOfEndpoint', () {
    String endpoint(List<int> sealed) =>
        'https://relay.test/v1/push/${base64Url.encode(sealed).replaceAll('=', '')}';

    test('reads the second byte of the sealed segment', () {
      check(
        PushRelayClient.kidOfEndpoint(endpoint([1, 7, ...List.filled(40, 9)])),
      ).equals(7);
    });

    test('ignores other formats and other endpoints', () {
      check(
        PushRelayClient.kidOfEndpoint(endpoint([2, 7, ...List.filled(40, 9)])),
      ).isNull();
      check(PushRelayClient.kidOfEndpoint('https://ntfy.example/upAbc?up=1'))
          .isNull();
      check(PushRelayClient.kidOfEndpoint('not a url')).isNull();
    });
  });
}

final class _Relay implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  int registerStatus = 200;
  String? registerError;
  String? retryAfter;
  Map<String, Object?>? registerBody;
  bool fail = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (fail) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'offline',
      );
    }
    if (options.uri.path == '/v1/info') {
      return _json({
        'proto': 1,
        'active_kid': 3,
        'max_body': 2134,
        'providers': ['apns', 'fcm'],
      });
    }
    if (registerStatus != 200) {
      return _json(
        {'error': registerError},
        registerStatus,
        {
          if (retryAfter != null) 'retry-after': [retryAfter!],
        },
      );
    }
    final sealed = base64Url
        .encode([1, 3, ...List.filled(40, 5)])
        .replaceAll('=', '');
    return _json(
      registerBody ??
          {'endpoint': 'https://relay.test/v1/push/$sealed', 'kid': 3},
    );
  }

  ResponseBody _json(
    Object body, [
    int status = 200,
    Map<String, List<String>> headers = const {},
  ]) => ResponseBody.fromString(
    jsonEncode(body),
    status,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
      ...headers,
    },
  );

  @override
  void close({bool force = false}) {}
}
