import 'dart:async';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/oidc/oidc.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

Future<OidcException> _errorOf(Future<Object?> future) async {
  try {
    await future;
  } on OidcException catch (error) {
    return error;
  }
  fail('expected an OidcException');
}

OidcHttp _answering(
  FutureOr<http.Response> Function(http.Request request) answer, {
  Duration timeout = const Duration(seconds: 15),
  int maxResponseBytes = 256 * 1024,
}) => OidcHttp(
  client: MockClient((request) async => answer(request)),
  timeout: timeout,
  maxResponseBytes: maxResponseBytes,
);

final _url = Uri.parse(
  'https://id.example.com/.well-known/openid-configuration',
);

void main() {
  group('a request to the provider', () {
    test('reads a JSON object', () async {
      final oidc = _answering(
        (request) => http.Response('{"issuer":"https://id.example.com"}', 200),
      );
      check(await oidc.getJson(_url))
          .deepEquals({'issuer': 'https://id.example.com'});
    });

    test('never follows a redirect', () async {
      http.BaseRequest? sent;
      final oidc = _answering((request) {
        sent = request;
        return http.Response(
          '',
          302,
          headers: {'location': 'https://evil.example.com/'},
        );
      });
      final error = await _errorOf(oidc.getJson(_url));
      check(error.kind).equals(OidcFailureKind.redirected);
      check(error.statusCode).equals(302);
      check(sent!.followRedirects).isFalse();

      final post = await _errorOf(oidc.postForm(_url, const {'a': 'b'}));
      check(post.kind).equals(OidcFailureKind.redirected);
    });

    test('is never sent to an http endpoint', () async {
      var sent = false;
      final oidc = _answering((request) {
        sent = true;
        return http.Response('{}', 200);
      });
      final error = await _errorOf(
        oidc.getJson(Uri.parse('http://id.example.com/x')),
      );
      check(error.kind).equals(OidcFailureKind.insecureEndpoint);
      check(sent).isFalse();
    });

    test('reads no more than the cap', () async {
      final declared = _answering(
        (request) => http.Response('{"a":"${'x' * 64}"}', 200),
        maxResponseBytes: 32,
      );
      check((await _errorOf(declared.getJson(_url))).kind)
          .equals(OidcFailureKind.responseTooLarge);

      final streamed = OidcHttp(
        client: MockClient.streaming(
          (request, body) async => http.StreamedResponse(
            Stream.fromIterable([List.filled(20, 0x20), List.filled(20, 0x20)]),
            200,
          ),
        ),
        maxResponseBytes: 32,
      );
      check((await _errorOf(streamed.getJson(_url))).kind)
          .equals(OidcFailureKind.responseTooLarge);
    });

    test('tells statuses apart', () async {
      for (final (status, kind) in [
        (404, OidcFailureKind.unexpectedStatus),
        (429, OidcFailureKind.rateLimited),
        (500, OidcFailureKind.serverError),
      ]) {
        final oidc = _answering((request) => http.Response('{}', status));
        final error = await _errorOf(oidc.getJson(_url));
        check(error.kind).equals(kind);
        check(error.statusCode).equals(status);
      }
      final page = _answering(
        (request) => http.Response('<html>sign in</html>', 200),
      );
      check((await _errorOf(page.getJson(_url))).kind)
          .equals(OidcFailureKind.invalidResponse);
    });

    test('gives a form answer whatever its status', () async {
      final oidc = _answering(
        (request) => http.Response('{"error":"invalid_grant"}', 400),
      );
      final response = await oidc.postForm(_url, const {'a': 'b'});
      check(response.statusCode).equals(400);
      check(response.isSuccess).isFalse();
      check(response.json).isNotNull().deepEquals({'error': 'invalid_grant'});
    });

    test('tells transport failures apart', () async {
      for (final (failure, kind) in <(Object, OidcFailureKind)>[
        (http.ClientException('refused'), OidcFailureKind.network),
        (const SocketException('refused'), OidcFailureKind.network),
        (const HandshakeException('untrusted'), OidcFailureKind.tls),
      ]) {
        final oidc = _answering((request) => throw failure);
        final error = await _errorOf(oidc.getJson(_url));
        check(error.kind).equals(kind);
        check(error.isTransient).isTrue();
      }
      final hanging = OidcHttp(
        client: MockClient((_) => Completer<http.Response>().future),
        timeout: const Duration(milliseconds: 10),
      );
      check((await _errorOf(hanging.getJson(_url))).kind)
          .equals(OidcFailureKind.timeout);
    });

    test('carries nothing of Open WebUI', () async {
      http.BaseRequest? sent;
      final oidc = OidcHttp(
        route: const ServerConfig(
          id: 'account-1',
          name: 'Chat',
          url: 'https://chat.example.com',
          apiKey: 'sk-secret',
          customHeaders: {'X-Proxy': 'secret'},
        ),
        client: MockClient((request) async {
          sent = request;
          return http.Response('{}', 200);
        }),
      );
      await oidc.getJson(Uri.parse('https://chat.example.com/oidc/x'));
      check(sent!.headers.keys.map((key) => key.toLowerCase()))
        ..not((it) => it.contains('x-proxy'))
        ..not((it) => it.contains(HttpHeaders.cookieHeader))
        ..not((it) => it.contains(HttpHeaders.authorizationHeader));
    });
  });

  group("the Open WebUI address's TLS", () {
    const route = ServerConfig(
      id: 'account-1',
      name: 'Chat',
      url: 'https://chat.example.com',
      allowSelfSignedCertificates: true,
    );

    ({OidcHttp oidc, List<Uri> system, List<Uri> server}) setUp({
      ServerConfig config = route,
    }) {
      final system = <Uri>[];
      final server = <Uri>[];
      final oidc = OidcHttp(
        route: config,
        client: MockClient((request) async {
          system.add(request.url);
          return http.Response('{}', 200);
        }),
        routeClient: (routeConfig) {
          check(routeConfig).equals(config);
          return MockClient((request) async {
            server.add(request.url);
            return http.Response('{}', 200);
          });
        },
      );
      return (oidc: oidc, system: system, server: server);
    }

    test('is used on exactly its origin', () async {
      final (:oidc, :system, :server) = setUp();
      await oidc.getJson(
        Uri.parse('https://CHAT.example.com:443/realms/acme/x'),
      );
      check(server).length.equals(1);
      check(system).isEmpty();
    });

    test('is not used on another port, host or scheme', () async {
      final (:oidc, :system, :server) = setUp();
      for (final url in [
        'https://chat.example.com:8443/x',
        'https://id.chat.example.com/x',
        'https://example.com/x',
      ]) {
        await oidc.getJson(Uri.parse(url));
      }
      check(server).isEmpty();
      check(system).length.equals(3);
    });

    test('is not used when the address trusts only the system', () async {
      final (:oidc, :system, :server) = setUp(
        config: const ServerConfig(
          id: 'account-1',
          name: 'Chat',
          url: 'https://chat.example.com',
        ),
      );
      await oidc.getJson(Uri.parse('https://chat.example.com/x'));
      check(server).isEmpty();
      check(system).length.equals(1);
    });
  });
}
