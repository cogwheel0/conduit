import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit/core/services/secure_credential_storage.dart';
import 'package:conduit/features/direct_connections/models/direct_mcp_server.dart';
import 'package:conduit/features/direct_connections/services/direct_mcp_oauth.dart';
import 'package:conduit/features/direct_connections/services/direct_mcp_server_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('discovers OAuth, owns S256/state, and persists bound tokens', () async {
    final fixture = await _OAuthFixture.start();
    addTearDown(fixture.close);
    final store = _store();
    final server = await _saveOAuthServer(store, fixture.endpoint);
    late Uri authorizationUri;
    final coordinator = DirectMcpOAuthCoordinator(
      store: store,
      launchBrowser: (uri) async {
        authorizationUri = uri;
        unawaited(_deliverCallback(uri, issuer: fixture.issuer.toString()));
        return true;
      },
    );
    addTearDown(coordinator.close);

    final connected = await coordinator.connect(server);

    final query = authorizationUri.queryParameters;
    expect(
      fixture.discoveryPaths.first,
      '/.well-known/oauth-authorization-server/issuer',
    );
    expect(query['response_type'], 'code');
    expect(query['code_challenge_method'], 'S256');
    expect(query['code_challenge'], hasLength(43));
    expect(query['state'], hasLength(43));
    expect(query['resource'], fixture.endpoint.toString());
    expect(fixture.registrationBodies.single['application_type'], 'native');
    expect(
      fixture.registrationBodies.single['token_endpoint_auth_method'],
      'none',
    );
    final tokenForm = fixture.tokenForms.single;
    final verifier = tokenForm['code_verifier']!;
    expect(verifier, hasLength(43));
    expect(_challenge(verifier), query['code_challenge']);
    expect(tokenForm['resource'], fixture.endpoint.toString());
    expect(tokenForm['redirect_uri'], query['redirect_uri']);
    expect(connected.oauthTokens?.accessToken, 'access-one');
    expect(connected.oauthTokens?.refreshToken, 'refresh-one');
    expect(
      connected.oauthTokens?.authorizationServerIssuer,
      fixture.issuer.toString(),
    );
    expect((await store.load()).single.oauthTokens?.accessToken, 'access-one');
  });

  test('rejects a state mismatch before token exchange', () async {
    final fixture = await _OAuthFixture.start();
    addTearDown(fixture.close);
    final store = _store();
    final server = await _saveOAuthServer(store, fixture.endpoint);
    final coordinator = DirectMcpOAuthCoordinator(
      store: store,
      launchBrowser: (uri) async {
        unawaited(
          _deliverCallback(
            uri,
            state: 'wrong-state',
            issuer: fixture.issuer.toString(),
          ).catchError((_) {}),
        );
        return true;
      },
    );
    addTearDown(coordinator.close);

    await expectLater(
      coordinator.connect(server),
      throwsA(
        isA<DirectMcpOAuthException>().having(
          (error) => error.message,
          'message',
          contains('did not match'),
        ),
      ),
    );

    expect(fixture.tokenForms, isEmpty);
    expect((await store.load()).single.oauthTokens, isNull);
  });

  test(
    'requires RFC 9207 iss when advertised and rejects a mismatch',
    () async {
      final fixture = await _OAuthFixture.start();
      addTearDown(fixture.close);
      final store = _store();
      final server = await _saveOAuthServer(store, fixture.endpoint);
      final coordinator = DirectMcpOAuthCoordinator(
        store: store,
        launchBrowser: (uri) async {
          unawaited(
            _deliverCallback(
              uri,
              issuer: 'https://wrong.example',
            ).catchError((_) {}),
          );
          return true;
        },
      );
      addTearDown(coordinator.close);

      await expectLater(
        coordinator.connect(server),
        throwsA(
          isA<DirectMcpOAuthException>().having(
            (error) => error.message,
            'message',
            contains('issuer'),
          ),
        ),
      );
      expect(fixture.tokenForms, isEmpty);
    },
  );

  test('rejects insecure authorization-server discovery', () async {
    final fixture = await _OAuthFixture.start(
      authorizationServer: Uri.parse('http://auth.example/issuer'),
    );
    addTearDown(fixture.close);
    final store = _store();
    final server = await _saveOAuthServer(store, fixture.endpoint);
    var browserOpened = false;
    final coordinator = DirectMcpOAuthCoordinator(
      store: store,
      launchBrowser: (_) async {
        browserOpened = true;
        return true;
      },
    );
    addTearDown(coordinator.close);

    await expectLater(
      coordinator.connect(server),
      throwsA(isA<DirectMcpOAuthException>()),
    );
    expect(browserOpened, isFalse);
    expect(fixture.registrationBodies, isEmpty);
  });

  test('rejects oversized protected-resource metadata', () async {
    final fixture = await _OAuthFixture.start(oversizedProtectedMetadata: true);
    addTearDown(fixture.close);
    final store = _store();
    final server = await _saveOAuthServer(store, fixture.endpoint);
    final coordinator = DirectMcpOAuthCoordinator(
      store: store,
      launchBrowser: (_) async => true,
    );
    addTearDown(coordinator.close);

    await expectLater(
      coordinator.connect(server),
      throwsA(
        isA<DirectMcpOAuthException>().having(
          (error) => error.message,
          'message',
          contains('too large'),
        ),
      ),
    );
    expect(fixture.registrationBodies, isEmpty);
  });

  test('expires a pending browser flow without persisting tokens', () async {
    final fixture = await _OAuthFixture.start();
    addTearDown(fixture.close);
    final store = _store();
    final server = await _saveOAuthServer(store, fixture.endpoint);
    final coordinator = DirectMcpOAuthCoordinator(
      store: store,
      launchBrowser: (_) async => true,
      flowTimeout: const Duration(milliseconds: 50),
    );
    addTearDown(coordinator.close);

    await expectLater(
      coordinator.connect(server),
      throwsA(
        isA<DirectMcpOAuthException>().having(
          (error) => error.message,
          'message',
          contains('timed out'),
        ),
      ),
    );

    expect(coordinator.isPending(server.id), isFalse);
    expect((await store.load()).single.oauthTokens, isNull);
  });

  test('rejects authorization metadata with a different issuer', () async {
    final fixture = await _OAuthFixture.start(mismatchedMetadataIssuer: true);
    addTearDown(fixture.close);
    final store = _store();
    final server = await _saveOAuthServer(store, fixture.endpoint);
    var browserOpened = false;
    final coordinator = DirectMcpOAuthCoordinator(
      store: store,
      launchBrowser: (_) async {
        browserOpened = true;
        return true;
      },
    );
    addTearDown(coordinator.close);

    await expectLater(
      coordinator.connect(server),
      throwsA(
        isA<DirectMcpOAuthException>().having(
          (error) => error.message,
          'message',
          contains('issuer'),
        ),
      ),
    );

    expect(browserOpened, isFalse);
    expect(fixture.registrationBodies, isEmpty);
  });

  test('rejects confidential client registration', () async {
    final fixture = await _OAuthFixture.start(
      registeredAuthMethod: 'client_secret_basic',
    );
    addTearDown(fixture.close);
    final store = _store();
    final server = await _saveOAuthServer(store, fixture.endpoint);
    var browserOpened = false;
    final coordinator = DirectMcpOAuthCoordinator(
      store: store,
      launchBrowser: (_) async {
        browserOpened = true;
        return true;
      },
    );
    addTearDown(coordinator.close);

    await expectLater(
      coordinator.connect(server),
      throwsA(
        isA<DirectMcpOAuthException>().having(
          (error) => error.message,
          'message',
          contains('confidential'),
        ),
      ),
    );

    expect(browserOpened, isFalse);
    expect(fixture.registrationBodies, hasLength(1));
    expect((await store.load()).single.oauthTokens, isNull);
  });

  test('replaced flow cannot persist and the callback is single use', () async {
    final fixture = await _OAuthFixture.start();
    addTearDown(fixture.close);
    final store = _store();
    final server = await _saveOAuthServer(store, fixture.endpoint);
    var launches = 0;
    final firstLaunch = Completer<void>();
    final repeatedCallback = Completer<bool>();
    final coordinator = DirectMcpOAuthCoordinator(
      store: store,
      launchBrowser: (uri) async {
        launches++;
        if (launches == 1) {
          firstLaunch.complete();
        } else if (launches == 2) {
          unawaited(() async {
            try {
              await _deliverCallback(uri, issuer: fixture.issuer.toString());
              try {
                await _deliverCallback(uri, issuer: fixture.issuer.toString());
                repeatedCallback.complete(false);
              } catch (_) {
                repeatedCallback.complete(true);
              }
            } catch (error, stackTrace) {
              repeatedCallback.completeError(error, stackTrace);
            }
          }());
        }
        return true;
      },
    );
    addTearDown(coordinator.close);

    final first = coordinator.connect(server);
    await firstLaunch.future.timeout(const Duration(seconds: 2));
    final second = coordinator.connect(server);

    await expectLater(first, throwsA(isA<DirectMcpOAuthException>()));
    final connected = await second;
    final secondCallbackRejected = await repeatedCallback.future.timeout(
      const Duration(seconds: 2),
    );
    expect(connected.oauthTokens?.accessToken, 'access-one');
    expect(fixture.tokenForms, hasLength(1));
    expect(secondCallbackRejected, isTrue);
  });

  test('late callback cannot overwrite a concurrently edited server', () async {
    final fixture = await _OAuthFixture.start();
    addTearDown(fixture.close);
    final store = _store();
    final server = await _saveOAuthServer(store, fixture.endpoint);
    final launchGate = Completer<Uri>();
    final coordinator = DirectMcpOAuthCoordinator(
      store: store,
      launchBrowser: (uri) async {
        launchGate.complete(uri);
        return true;
      },
    );
    addTearDown(coordinator.close);

    final connection = coordinator.connect(server);
    final authorizationUri = await launchGate.future;
    await store.upsert(
      server.copyWith(name: 'Edited while pending'),
      expectedPrevious: server,
    );
    await _deliverCallback(authorizationUri, issuer: fixture.issuer.toString());

    await expectLater(connection, throwsA(isA<DirectMcpOAuthException>()));
    final stored = (await store.load()).single;
    expect(stored.name, 'Edited while pending');
    expect(stored.oauthTokens, isNull);
  });

  test(
    'pre-expiry refresh is single-flight and preserves rotated tokens',
    () async {
      final fixture = await _OAuthFixture.start(holdRefresh: true);
      addTearDown(fixture.close);
      final store = _store();
      final server = await _saveTokenServer(store, fixture, expired: true);
      final coordinator = DirectMcpOAuthCoordinator(store: store);
      addTearDown(coordinator.close);

      final first = coordinator.accessTokenFor(server);
      final second = coordinator.accessTokenFor(server);
      await fixture.refreshReceived.future;
      fixture.refreshRelease.complete();

      expect(await Future.wait([first, second]), ['access-two', 'access-two']);
      expect(
        fixture.tokenForms.where(
          (form) => form['grant_type'] == 'refresh_token',
        ),
        hasLength(1),
      );
      final stored = (await store.load()).single.oauthTokens!;
      expect(stored.accessToken, 'access-two');
      expect(stored.refreshToken, 'refresh-one');
    },
  );

  test('refresh uses the latest securely persisted token rotation', () async {
    final fixture = await _OAuthFixture.start(rotateRefreshToken: true);
    addTearDown(fixture.close);
    final store = _store();
    final staleServer = await _saveTokenServer(store, fixture, expired: true);
    final coordinator = DirectMcpOAuthCoordinator(store: store);
    addTearDown(coordinator.close);

    expect(
      await coordinator.accessTokenFor(staleServer, forceRefresh: true),
      'access-two',
    );
    expect(
      await coordinator.accessTokenFor(staleServer, forceRefresh: true),
      'access-two',
    );

    final refreshForms = fixture.tokenForms
        .where((form) => form['grant_type'] == 'refresh_token')
        .toList();
    expect(refreshForms, hasLength(2));
    expect(refreshForms.first['refresh_token'], 'refresh-one');
    expect(refreshForms.last['refresh_token'], 'refresh-two');
  });

  test('invalid_grant clears tokens and requires reconnect', () async {
    final fixture = await _OAuthFixture.start(invalidGrant: true);
    addTearDown(fixture.close);
    final store = _store();
    final server = await _saveTokenServer(store, fixture, expired: true);
    final coordinator = DirectMcpOAuthCoordinator(store: store);
    addTearDown(coordinator.close);

    await expectLater(
      coordinator.accessTokenFor(server),
      throwsA(
        isA<DirectMcpOAuthException>().having(
          (error) => error.message,
          'message',
          contains('Reconnect'),
        ),
      ),
    );

    expect((await store.load()).single.oauthTokens, isNull);
  });

  test('cancellation prevents a late refresh write', () async {
    final fixture = await _OAuthFixture.start(holdRefresh: true);
    addTearDown(fixture.close);
    final store = _store();
    final server = await _saveTokenServer(store, fixture, expired: true);
    final coordinator = DirectMcpOAuthCoordinator(store: store);
    addTearDown(coordinator.close);

    final refresh = coordinator.accessTokenFor(server);
    await fixture.refreshReceived.future;
    await coordinator.cancel(server.id);
    fixture.refreshRelease.complete();

    await expectLater(refresh, throwsA(isA<DirectMcpOAuthException>()));
    expect((await store.load()).single.oauthTokens?.accessToken, 'old-access');
  });
}

DirectMcpServerStore _store() => DirectMcpServerStore(
  SecureCredentialStorage(instance: const FlutterSecureStorage()),
);

Future<DirectMcpServer> _saveOAuthServer(
  DirectMcpServerStore store,
  Uri endpoint,
) async {
  final server = DirectMcpServer(
    id: 'oauth-server',
    name: 'OAuth server',
    endpoint: endpoint.toString(),
    authMode: DirectMcpAuthMode.oauth,
  );
  await store.upsert(server);
  return server;
}

Future<DirectMcpServer> _saveTokenServer(
  DirectMcpServerStore store,
  _OAuthFixture fixture, {
  required bool expired,
}) async {
  final server = DirectMcpServer(
    id: 'oauth-server',
    name: 'OAuth server',
    endpoint: fixture.endpoint.toString(),
    authMode: DirectMcpAuthMode.oauth,
    oauthTokens: DirectMcpOAuthTokens(
      accessToken: 'old-access',
      refreshToken: 'refresh-one',
      grantedScope: 'tools.read',
      expiresAt: DateTime.now().toUtc().add(
        expired ? const Duration(seconds: 10) : const Duration(hours: 1),
      ),
      authorizationServerIssuer: fixture.issuer.toString(),
      resource: fixture.endpoint.toString(),
      clientId: 'public-client-id',
      tokenEndpoint: fixture.origin.replace(path: '/token').toString(),
    ),
  );
  await store.upsert(server);
  return server;
}

Future<void> _deliverCallback(
  Uri authorizationUri, {
  String? state,
  String? issuer,
}) async {
  final redirectUri = Uri.parse(
    authorizationUri.queryParameters['redirect_uri']!,
  );
  final response = await http.get(
    redirectUri.replace(
      queryParameters: {
        'code': 'authorization-code',
        'state': state ?? authorizationUri.queryParameters['state']!,
        'iss': ?issuer,
      },
    ),
  );
  if (response.statusCode != HttpStatus.ok) {
    throw StateError('Callback was rejected.');
  }
}

String _challenge(String verifier) =>
    base64UrlEncode(sha256.convert(utf8.encode(verifier)).bytes)
        .replaceAll('=', '');

final class _OAuthFixture {
  _OAuthFixture._(
    this.server,
    this.subscription, {
    required this.authorizationServer,
    required this.oversizedProtectedMetadata,
    required this.mismatchedMetadataIssuer,
    required this.registeredAuthMethod,
    required this.invalidGrant,
    required this.holdRefresh,
    required this.rotateRefreshToken,
  });

  final HttpServer server;
  final StreamSubscription<HttpRequest> subscription;
  final Uri? authorizationServer;
  final bool oversizedProtectedMetadata;
  final bool mismatchedMetadataIssuer;
  final String registeredAuthMethod;
  final bool invalidGrant;
  final bool holdRefresh;
  final bool rotateRefreshToken;
  final List<String> discoveryPaths = [];
  final List<Map<String, dynamic>> registrationBodies = [];
  final List<Map<String, String>> tokenForms = [];
  final Completer<void> refreshReceived = Completer<void>();
  final Completer<void> refreshRelease = Completer<void>();

  Uri get origin =>
      Uri.parse('http://${server.address.address}:${server.port}');
  Uri get endpoint => origin.replace(path: '/mcp');
  Uri get issuer => origin.replace(path: '/issuer');

  static Future<_OAuthFixture> start({
    Uri? authorizationServer,
    bool oversizedProtectedMetadata = false,
    bool mismatchedMetadataIssuer = false,
    String registeredAuthMethod = 'none',
    bool invalidGrant = false,
    bool holdRefresh = false,
    bool rotateRefreshToken = false,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    late _OAuthFixture fixture;
    final subscription = server.listen((request) => fixture._handle(request));
    fixture = _OAuthFixture._(
      server,
      subscription,
      authorizationServer: authorizationServer,
      oversizedProtectedMetadata: oversizedProtectedMetadata,
      mismatchedMetadataIssuer: mismatchedMetadataIssuer,
      registeredAuthMethod: registeredAuthMethod,
      invalidGrant: invalidGrant,
      holdRefresh: holdRefresh,
      rotateRefreshToken: rotateRefreshToken,
    );
    return fixture;
  }

  Future<void> _handle(HttpRequest request) async {
    if (request.method == 'POST' && request.uri.path == '/mcp') {
      await request.drain<void>();
      request.response
        ..statusCode = HttpStatus.unauthorized
        ..headers.set(
          HttpHeaders.wwwAuthenticateHeader,
          'Bearer resource_metadata="${origin.replace(path: '/prm')}"',
        );
      await request.response.close();
      return;
    }
    if (request.method == 'GET' && request.uri.path == '/prm') {
      request.response.headers.contentType = ContentType.json;
      if (oversizedProtectedMetadata) {
        request.response.write(jsonEncode({'padding': 'x' * (300 * 1024)}));
      } else {
        request.response.write(
          jsonEncode({
            'resource': endpoint.toString(),
            'authorization_servers': [
              (authorizationServer ?? issuer).toString(),
            ],
            'scopes_supported': ['tools.read', 'tools.call'],
          }),
        );
      }
      await request.response.close();
      return;
    }
    if (request.method == 'GET' &&
        request.uri.path == '/.well-known/oauth-authorization-server/issuer') {
      discoveryPaths.add(request.uri.path);
      request.response
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'issuer': mismatchedMetadataIssuer
                ? origin.replace(path: '/different-issuer').toString()
                : issuer.toString(),
            'authorization_endpoint': origin
                .replace(path: '/authorize')
                .toString(),
            'token_endpoint': origin.replace(path: '/token').toString(),
            'registration_endpoint': origin
                .replace(path: '/register')
                .toString(),
            'code_challenge_methods_supported': ['S256'],
            'token_endpoint_auth_methods_supported': ['none'],
            'authorization_response_iss_parameter_supported': true,
          }),
        );
      await request.response.close();
      return;
    }
    if (request.method == 'POST' && request.uri.path == '/register') {
      registrationBodies.add(
        jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>,
      );
      request.response
        ..statusCode = HttpStatus.created
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'client_id': 'public-client-id',
            'token_endpoint_auth_method': registeredAuthMethod,
          }),
        );
      await request.response.close();
      return;
    }
    if (request.method == 'POST' && request.uri.path == '/token') {
      final form = Uri.splitQueryString(await utf8.decodeStream(request));
      tokenForms.add(form);
      if (form['grant_type'] == 'refresh_token') {
        if (!refreshReceived.isCompleted) refreshReceived.complete();
        if (holdRefresh) await refreshRelease.future;
        if (invalidGrant) {
          request.response
            ..statusCode = HttpStatus.badRequest
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'error': 'invalid_grant'}));
          await request.response.close();
          return;
        }
        request.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'access_token': 'access-two',
              if (rotateRefreshToken) 'refresh_token': 'refresh-two',
              'token_type': 'Bearer',
              'scope': 'tools.read',
              'expires_in': 7200,
            }),
          );
        await request.response.close();
        return;
      }
      request.response
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'access_token': 'access-one',
            'refresh_token': 'refresh-one',
            'token_type': 'Bearer',
            'scope': 'tools.read tools.call',
            'expires_in': 3600,
          }),
        );
      await request.response.close();
      return;
    }
    await request.drain<void>();
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  Future<void> close() async {
    if (!refreshRelease.isCompleted) refreshRelease.complete();
    await subscription.cancel();
    await server.close(force: true);
  }
}
