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
        unawaited(
          _deliverCallback(
            uri,
            issuer: fixture.issuer.toString(),
            extraQueryParameters: const {'session_state': 'browser-session'},
          ),
        );
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
    expect(query, isNot(contains('scope')));
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
    expect(tokenForm, isNot(contains('scope')));
    expect(connected.oauthTokens?.accessToken, 'access-one');
    expect(connected.oauthTokens?.refreshToken, 'refresh-one');
    expect(
      connected.oauthTokens?.authorizationServerIssuer,
      fixture.issuer.toString(),
    );
    expect((await store.load()).single.oauthTokens?.accessToken, 'access-one');
  });

  test('ignores a state mismatch before the valid callback', () async {
    final fixture = await _OAuthFixture.start();
    addTearDown(fixture.close);
    final store = _store();
    final server = await _saveOAuthServer(store, fixture.endpoint);
    final coordinator = DirectMcpOAuthCoordinator(
      store: store,
      launchBrowser: (uri) async {
        unawaited(() async {
          await expectLater(
            _deliverCallback(
              uri,
              state: 'wrong-state',
              issuer: fixture.issuer.toString(),
            ),
            throwsStateError,
          );
          await _deliverCallback(uri, issuer: fixture.issuer.toString());
        }());
        return true;
      },
    );
    addTearDown(coordinator.close);

    final connected = await coordinator.connect(server);

    expect(connected.oauthTokens?.accessToken, 'access-one');
    expect(fixture.tokenForms, hasLength(1));
  });

  test('requests the exact scope advertised by the OAuth challenge', () async {
    final fixture = await _OAuthFixture.start(challengeScope: 'tools.read');
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

    await coordinator.connect(server);

    expect(authorizationUri.queryParameters['scope'], 'tools.read');
  });

  test('preserves the endpoint query in fallback metadata discovery', () async {
    final fixture = await _OAuthFixture.start(
      useWellKnownProtectedMetadata: true,
    );
    addTearDown(fixture.close);
    final store = _store();
    final server = await _saveOAuthServer(store, fixture.endpoint);
    final coordinator = DirectMcpOAuthCoordinator(
      store: store,
      launchBrowser: (uri) async {
        unawaited(_deliverCallback(uri, issuer: fixture.issuer.toString()));
        return true;
      },
    );
    addTearDown(coordinator.close);

    await coordinator.connect(server);

    expect(fixture.protectedMetadataQueries.single, 'tenant=a');
  });

  test('requires RFC 9207 iss and ignores a mismatched callback', () async {
    final fixture = await _OAuthFixture.start();
    addTearDown(fixture.close);
    final store = _store();
    final server = await _saveOAuthServer(store, fixture.endpoint);
    final coordinator = DirectMcpOAuthCoordinator(
      store: store,
      launchBrowser: (uri) async {
        unawaited(() async {
          await expectLater(
            _deliverCallback(uri, issuer: 'https://wrong.example'),
            throwsStateError,
          );
          await _deliverCallback(uri, issuer: fixture.issuer.toString());
        }());
        return true;
      },
    );
    addTearDown(coordinator.close);

    final connected = await coordinator.connect(server);
    expect(connected.oauthTokens?.accessToken, 'access-one');
    expect(fixture.tokenForms, hasLength(1));
  });

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

  test('rejects cross-origin protected-resource metadata', () async {
    final fixture = await _OAuthFixture.start(
      crossOriginProtectedMetadata: true,
    );
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
      throwsA(isA<DirectMcpOAuthException>()),
    );
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

  test(
    'preserves the raw authorization-server issuer for exact matching',
    () async {
      final fixture = await _OAuthFixture.start(nonCanonicalIssuer: true);
      addTearDown(fixture.close);
      final store = _store();
      final server = await _saveOAuthServer(store, fixture.endpoint);
      final coordinator = DirectMcpOAuthCoordinator(
        store: store,
        launchBrowser: (uri) async {
          unawaited(_deliverCallback(uri, issuer: fixture.advertisedIssuer));
          return true;
        },
      );
      addTearDown(coordinator.close);

      final connected = await coordinator.connect(server);

      expect(
        connected.oauthTokens?.authorizationServerIssuer,
        fixture.advertisedIssuer,
      );
    },
  );

  test(
    'rejects an empty authorization-server list with a typed error',
    () async {
      final fixture = await _OAuthFixture.start(
        emptyAuthorizationServers: true,
      );
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
            contains('protected-resource metadata'),
          ),
        ),
      );
    },
  );

  test('rejects an out-of-range token expiry with a typed error', () async {
    final fixture = await _OAuthFixture.start(tokenExpiresIn: 1e100);
    addTearDown(fixture.close);
    final store = _store();
    final server = await _saveOAuthServer(store, fixture.endpoint);
    final coordinator = DirectMcpOAuthCoordinator(
      store: store,
      launchBrowser: (uri) async {
        unawaited(_deliverCallback(uri, issuer: fixture.advertisedIssuer));
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
          contains('expiry'),
        ),
      ),
    );
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

  test('rejects a registration that changes the callback URI', () async {
    final fixture = await _OAuthFixture.start(
      changeRegisteredRedirectUri: true,
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
    expect(fixture.tokenForms, isEmpty);
  });

  test('requires explicit public-client token endpoint support', () async {
    final fixture = await _OAuthFixture.start(omitTokenAuthMethods: true);
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
      final server = await _saveTokenServer(
        store,
        fixture,
        withinRefreshWindow: true,
      );
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
    final staleServer = await _saveTokenServer(
      store,
      fixture,
      withinRefreshWindow: true,
    );
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
    final server = await _saveTokenServer(
      store,
      fixture,
      withinRefreshWindow: true,
    );
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

  test('disconnect accepts a securely rotated OAuth token record', () async {
    final fixture = await _OAuthFixture.start();
    addTearDown(fixture.close);
    final store = _store();
    final staleServer = await _saveTokenServer(
      store,
      fixture,
      withinRefreshWindow: false,
    );
    final approvedServer = staleServer.copyWith(
      rememberedApprovals: [
        DirectMcpRememberedApproval(
          digest: 'a' * 64,
          remoteToolName: 'lookup',
          displayName: 'Lookup',
          createdAt: DateTime.utc(2026),
        ),
      ],
    );
    await store.upsert(approvedServer, expectedPrevious: staleServer);
    final rotatedServer = approvedServer.copyWith(
      oauthTokens: staleServer.oauthTokens!.copyWith(
        accessToken: 'rotated-access',
        refreshToken: 'refresh-two',
      ),
    );
    await store.upsert(
      rotatedServer,
      expectedPrevious: approvedServer,
      oauthFlowCompletedForExactMutation: true,
    );
    final coordinator = DirectMcpOAuthCoordinator(store: store);
    addTearDown(coordinator.close);

    final disconnected = await coordinator.disconnect(approvedServer);

    expect(disconnected.oauthTokens, isNull);
    expect(disconnected.rememberedApprovals, isEmpty);
    expect((await store.load()).single.oauthTokens, isNull);
  });

  test('cancellation prevents a late refresh write', () async {
    final fixture = await _OAuthFixture.start(holdRefresh: true);
    addTearDown(fixture.close);
    final store = _store();
    final server = await _saveTokenServer(
      store,
      fixture,
      withinRefreshWindow: true,
    );
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
  required bool withinRefreshWindow,
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
        withinRefreshWindow
            ? const Duration(seconds: 10)
            : const Duration(hours: 1),
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
  Map<String, String> extraQueryParameters = const {},
}) async {
  final redirectUri = Uri.parse(
    authorizationUri.queryParameters['redirect_uri']!,
  );
  final response = await http.get(
    redirectUri.replace(
      queryParameters: {
        ...extraQueryParameters,
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
    required this.crossOriginProtectedMetadata,
    required this.mismatchedMetadataIssuer,
    required this.nonCanonicalIssuer,
    required this.emptyAuthorizationServers,
    required this.omitTokenAuthMethods,
    required this.registeredAuthMethod,
    required this.changeRegisteredRedirectUri,
    required this.invalidGrant,
    required this.holdRefresh,
    required this.rotateRefreshToken,
    required this.challengeScope,
    required this.useWellKnownProtectedMetadata,
    required this.tokenExpiresIn,
  });

  final HttpServer server;
  final StreamSubscription<HttpRequest> subscription;
  final Uri? authorizationServer;
  final bool oversizedProtectedMetadata;
  final bool crossOriginProtectedMetadata;
  final bool mismatchedMetadataIssuer;
  final bool nonCanonicalIssuer;
  final bool emptyAuthorizationServers;
  final bool omitTokenAuthMethods;
  final String registeredAuthMethod;
  final bool changeRegisteredRedirectUri;
  final bool invalidGrant;
  final bool holdRefresh;
  final bool rotateRefreshToken;
  final String? challengeScope;
  final bool useWellKnownProtectedMetadata;
  final num tokenExpiresIn;
  final List<String> discoveryPaths = [];
  final List<String> protectedMetadataQueries = [];
  final List<Map<String, dynamic>> registrationBodies = [];
  final List<Map<String, String>> tokenForms = [];
  final Completer<void> refreshReceived = Completer<void>();
  final Completer<void> refreshRelease = Completer<void>();

  Uri get origin =>
      Uri.parse('http://${server.address.address}:${server.port}');
  Uri get endpoint => origin.replace(
    path: '/mcp',
    query: useWellKnownProtectedMetadata ? 'tenant=a' : null,
  );
  Uri get issuer => origin.replace(path: '/issuer');
  String get advertisedIssuer => nonCanonicalIssuer
      ? 'HTTP://${server.address.address}:${server.port}/issuer'
      : issuer.toString();

  static Future<_OAuthFixture> start({
    Uri? authorizationServer,
    bool oversizedProtectedMetadata = false,
    bool crossOriginProtectedMetadata = false,
    bool mismatchedMetadataIssuer = false,
    bool nonCanonicalIssuer = false,
    bool emptyAuthorizationServers = false,
    bool omitTokenAuthMethods = false,
    String registeredAuthMethod = 'none',
    bool changeRegisteredRedirectUri = false,
    bool invalidGrant = false,
    bool holdRefresh = false,
    bool rotateRefreshToken = false,
    String? challengeScope,
    bool useWellKnownProtectedMetadata = false,
    num tokenExpiresIn = 3600,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    late _OAuthFixture fixture;
    final subscription = server.listen((request) => fixture._handle(request));
    fixture = _OAuthFixture._(
      server,
      subscription,
      authorizationServer: authorizationServer,
      oversizedProtectedMetadata: oversizedProtectedMetadata,
      crossOriginProtectedMetadata: crossOriginProtectedMetadata,
      mismatchedMetadataIssuer: mismatchedMetadataIssuer,
      nonCanonicalIssuer: nonCanonicalIssuer,
      emptyAuthorizationServers: emptyAuthorizationServers,
      omitTokenAuthMethods: omitTokenAuthMethods,
      registeredAuthMethod: registeredAuthMethod,
      changeRegisteredRedirectUri: changeRegisteredRedirectUri,
      invalidGrant: invalidGrant,
      holdRefresh: holdRefresh,
      rotateRefreshToken: rotateRefreshToken,
      challengeScope: challengeScope,
      useWellKnownProtectedMetadata: useWellKnownProtectedMetadata,
      tokenExpiresIn: tokenExpiresIn,
    );
    return fixture;
  }

  Future<void> _handle(HttpRequest request) async {
    if (request.method == 'POST' && request.uri.path == '/mcp') {
      await request.drain<void>();
      request.response.statusCode = HttpStatus.unauthorized;
      if (!useWellKnownProtectedMetadata) {
        request.response.headers.set(
          HttpHeaders.wwwAuthenticateHeader,
          'Bearer resource_metadata="${crossOriginProtectedMetadata ? 'https://attacker.example/prm' : origin.replace(path: '/prm')}"${challengeScope == null ? '' : ', scope="$challengeScope"'}',
        );
      }
      await request.response.close();
      return;
    }
    if (request.method == 'GET' &&
        (request.uri.path == '/prm' ||
            request.uri.path == '/.well-known/oauth-protected-resource/mcp')) {
      protectedMetadataQueries.add(request.uri.query);
      request.response.headers.contentType = ContentType.json;
      if (oversizedProtectedMetadata) {
        request.response.write(jsonEncode({'padding': 'x' * (300 * 1024)}));
      } else {
        request.response.write(
          jsonEncode({
            'resource': endpoint.toString(),
            'authorization_servers': emptyAuthorizationServers
                ? const <String>[]
                : [(authorizationServer?.toString() ?? advertisedIssuer)],
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
                : advertisedIssuer,
            'authorization_endpoint': origin
                .replace(path: '/authorize')
                .toString(),
            'token_endpoint': origin.replace(path: '/token').toString(),
            'registration_endpoint': origin
                .replace(path: '/register')
                .toString(),
            'code_challenge_methods_supported': ['S256'],
            if (!omitTokenAuthMethods)
              'token_endpoint_auth_methods_supported': ['none'],
            'authorization_response_iss_parameter_supported': true,
          }),
        );
      await request.response.close();
      return;
    }
    if (request.method == 'POST' && request.uri.path == '/register') {
      final registration =
          jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>;
      registrationBodies.add(registration);
      request.response
        ..statusCode = HttpStatus.created
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'client_id': 'public-client-id',
            'token_endpoint_auth_method': registeredAuthMethod,
            'redirect_uris': changeRegisteredRedirectUri
                ? ['http://127.0.0.1/wrong']
                : registration['redirect_uris'],
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
            'expires_in': tokenExpiresIn,
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
