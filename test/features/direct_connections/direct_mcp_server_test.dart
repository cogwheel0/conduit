import 'dart:convert';

import 'package:conduit/core/services/secure_credential_storage.dart';
import 'package:conduit/features/direct_connections/models/direct_mcp_server.dart';
import 'package:conduit/features/direct_connections/services/direct_mcp_server_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('document round-trips server credentials', () {
    final source = DirectMcpServersDocument([
      DirectMcpServer(
        id: 'home',
        name: 'Home tools',
        endpoint: 'http://192.168.1.2:3000/mcp?tenant=one',
        bearerToken: 'secret',
        customHeaders: const {'X-Tenant': 'one'},
      ),
    ]).encode();

    final server = DirectMcpServersDocument.decode(source).servers.single;

    expect(server.id, 'home');
    expect(server.bearerToken, 'secret');
    expect(server.customHeaders, {'X-Tenant': 'one'});
  });

  test('version 1 document migrates to version 2 auth modes', () {
    final server = DirectMcpServersDocument.decode(
      jsonEncode({
        'version': 1,
        'servers': [
          {
            'schemaVersion': 1,
            'id': 'legacy',
            'name': 'Legacy',
            'endpoint': 'https://example.test/mcp',
            'bearerToken': 'legacy-secret',
          },
        ],
      }),
    ).servers.single;

    expect(server.schemaVersion, DirectMcpServer.currentSchemaVersion);
    expect(server.authMode, DirectMcpAuthMode.bearer);
    expect(server.bearerToken, 'legacy-secret');
    expect(
      jsonDecode(DirectMcpServersDocument([server]).encode())['version'],
      DirectMcpServersDocument.currentVersion,
    );
  });

  test('OAuth token record round-trips without entering diagnostics', () {
    const accessToken = 'oauth-access-secret-91a7';
    const refreshToken = 'oauth-refresh-secret-48ce';
    final server = DirectMcpServer(
      id: 'oauth',
      name: 'OAuth server',
      endpoint: 'https://resource.example/mcp',
      authMode: DirectMcpAuthMode.oauth,
      oauthTokens: _oauthTokens(
        accessToken: accessToken,
        refreshToken: refreshToken,
      ),
    );

    final decoded = DirectMcpServersDocument.decode(
      DirectMcpServersDocument([server]).encode(),
    ).servers.single;

    expect(decoded.authMode, DirectMcpAuthMode.oauth);
    expect(decoded.oauthTokens?.accessToken, accessToken);
    expect(decoded.oauthTokens?.refreshToken, refreshToken);
    expect(decoded.oauthTokens?.grantedScope, 'tools.read tools.call');
    expect(decoded.toString(), isNot(contains(accessToken)));
    expect(decoded.oauthTokens.toString(), isNot(contains(refreshToken)));
  });

  test('OAuth JSON rejects malformed and mixed credentials', () {
    final valid = DirectMcpServer(
      id: 'oauth',
      name: 'OAuth server',
      endpoint: 'https://resource.example/mcp',
      authMode: DirectMcpAuthMode.oauth,
      oauthTokens: _oauthTokens(),
    ).toJson();

    expect(
      () => DirectMcpServer.fromJson({
        ...valid,
        'oauthTokens': {
          ...(valid['oauthTokens']! as Map<String, dynamic>),
          'accessToken': 42,
        },
      }),
      throwsFormatException,
    );
    expect(
      () =>
          DirectMcpServer.fromJson({...valid, 'bearerToken': 'manual-secret'}),
      throwsFormatException,
    );
    expect(
      () => DirectMcpServer.fromJson({...valid, 'authMode': 'future-mode'}),
      throwsFormatException,
    );
    expect(
      () => DirectMcpServer(
        id: 'wrong-resource',
        name: 'Wrong resource',
        endpoint: 'https://resource.example/mcp',
        authMode: DirectMcpAuthMode.oauth,
        oauthTokens: _oauthTokens(resource: 'https://other.example/mcp'),
      ).validate(),
      throwsFormatException,
    );
  });

  test('document rejects duplicate ids', () {
    final server = DirectMcpServer(
      id: 'duplicate',
      name: 'One',
      endpoint: 'https://example.test/mcp',
    );
    expect(
      () => DirectMcpServersDocument([server, server]),
      throwsFormatException,
    );
  });

  test('validation rejects malformed URLs and headers', () {
    for (final server in [
      DirectMcpServer(
        id: 'bad-url',
        name: 'Bad URL',
        endpoint: 'file:///tmp/mcp',
      ),
      DirectMcpServer(
        id: 'bad-user',
        name: 'Bad user',
        endpoint: 'https://user@example.test/mcp',
      ),
      DirectMcpServer(
        id: 'bad-header',
        name: 'Bad header',
        endpoint: 'https://example.test/mcp',
        customHeaders: const {'Authorization': 'secret'},
      ),
      DirectMcpServer(
        id: 'bad-connection',
        name: 'Bad connection',
        endpoint: 'https://example.test/mcp',
        customHeaders: const {'Connection': 'keep-alive'},
      ),
    ]) {
      expect(server.validate, throwsFormatException);
    }
  });

  test('validation rejects case-insensitive duplicate header names', () {
    final server = DirectMcpServer(
      id: 'duplicate-headers',
      name: 'Duplicate headers',
      endpoint: 'https://example.test/mcp',
      customHeaders: const {'X-Tenant': 'one', 'x-tenant': 'two'},
    );

    expect(server.validate, throwsFormatException);
  });

  test('origin changes clear credentials unless explicitly confirmed', () {
    final previous = DirectMcpServer(
      id: 'server',
      name: 'Server',
      endpoint: 'https://old.example/mcp',
      bearerToken: 'old-secret',
      customHeaders: const {'X-Secret': 'old-header'},
    );
    final next = previous.copyWith(
      endpoint: 'https://new.example/mcp',
      bearerToken: 'new-secret',
      customHeaders: const {'X-Secret': 'new-header'},
    );

    final cleared = DirectMcpServer.secureUpdate(
      previous: previous,
      next: next,
    );
    final confirmed = DirectMcpServer.secureUpdate(
      previous: previous,
      next: next,
      secretsConfirmedForNewOrigin: true,
    );

    expect(cleared.bearerToken, isNull);
    expect(cleared.customHeaders, isEmpty);
    expect(confirmed.bearerToken, 'new-secret');
    expect(confirmed.customHeaders['X-Secret'], 'new-header');
  });

  test('origin, issuer, and auth mode changes clear OAuth credentials', () {
    final previous = DirectMcpServer(
      id: 'server',
      name: 'Server',
      endpoint: 'https://resource.example/mcp',
      authMode: DirectMcpAuthMode.oauth,
      oauthTokens: _oauthTokens(),
      customHeaders: const {'X-Tenant': 'one'},
    );

    final moved = DirectMcpServer.secureUpdate(
      previous: previous,
      next: previous.copyWith(endpoint: 'https://new.example/mcp'),
    );
    final issuerChanged = DirectMcpServer.secureUpdate(
      previous: previous,
      next: previous.copyWith(
        oauthTokens: _oauthTokens(issuer: 'https://new-auth.example'),
      ),
    );
    final modeChanged = DirectMcpServer.secureUpdate(
      previous: previous,
      next: previous.copyWith(
        authMode: DirectMcpAuthMode.none,
        oauthTokens: null,
      ),
    );
    final verifiedIssuerChange = DirectMcpServer.secureUpdate(
      previous: previous,
      next: previous.copyWith(
        oauthTokens: _oauthTokens(issuer: 'https://new-auth.example'),
      ),
      oauthFlowCompletedForExactMutation: true,
    );

    expect(moved.authMode, DirectMcpAuthMode.oauth);
    expect(moved.oauthTokens, isNull);
    expect(moved.customHeaders, isEmpty);
    expect(issuerChanged.oauthTokens, isNull);
    expect(modeChanged.authMode, DirectMcpAuthMode.none);
    expect(modeChanged.oauthTokens, isNull);
    expect(modeChanged.customHeaders, {'X-Tenant': 'one'});
    expect(
      verifiedIssuerChange.oauthTokens?.authorizationServerIssuer,
      'https://new-auth.example',
    );
  });

  test(
    'store serializes mutations and persists only secure document',
    () async {
      const platformStorage = FlutterSecureStorage();
      final secure = SecureCredentialStorage(instance: platformStorage);
      final store = DirectMcpServerStore(secure);
      final first = DirectMcpServer(
        id: 'first',
        name: 'First',
        endpoint: 'https://first.example/mcp',
      );
      final second = DirectMcpServer(
        id: 'second',
        name: 'Second',
        endpoint: 'https://second.example/mcp',
      );

      await Future.wait([store.upsert(first), store.upsert(second)]);

      expect((await store.load()).map((server) => server.id), [
        'first',
        'second',
      ]);
      expect(await secure.getDirectMcpServers(), isNotNull);
    },
  );

  test('malformed document failure never logs its payload', () async {
    const secret = 'mcp-document-secret-91a7';
    final source = jsonEncode({
      'version': 1,
      'servers': [
        {
          'schemaVersion': 1,
          'id': 'server',
          'name': 'Server',
          'endpoint': 'file:///$secret',
          'bearerToken': secret,
        },
      ],
    });
    final previousDebugPrint = debugPrint;
    final output = StringBuffer();
    debugPrint = (message, {wrapWidth}) {
      if (message != null) output.writeln(message);
    };

    try {
      expect(
        () => DirectMcpServersDocument.decode(source),
        throwsFormatException,
      );
    } finally {
      debugPrint = previousDebugPrint;
    }

    expect(output.toString(), isNot(contains(secret)));
  });
}

DirectMcpOAuthTokens _oauthTokens({
  String accessToken = 'access-secret',
  String? refreshToken = 'refresh-secret',
  String issuer = 'https://auth.example',
  String resource = 'https://resource.example/mcp',
}) => DirectMcpOAuthTokens(
  accessToken: accessToken,
  refreshToken: refreshToken,
  grantedScope: 'tools.read tools.call',
  expiresAt: DateTime.utc(2030),
  authorizationServerIssuer: issuer,
  resource: resource,
  clientId: 'public-client-id',
  tokenEndpoint: '$issuer/token',
);
