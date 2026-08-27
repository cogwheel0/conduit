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
        allowInsecureCredentials: true,
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
    expect(server.rememberedApprovals, isEmpty);
  });

  test('version 2 migrates and version 3 approvals round-trip safely', () {
    final migrated = DirectMcpServersDocument.decode(
      jsonEncode({
        'version': 2,
        'servers': [
          {
            'schemaVersion': 2,
            'id': 'legacy',
            'name': 'Legacy',
            'endpoint': 'https://example.test/mcp',
            'authMode': 'none',
          },
        ],
      }),
    ).servers.single;
    final approval = _approval('a', tool: 'lookup');
    final decoded = DirectMcpServersDocument.decode(
      DirectMcpServersDocument([
        migrated.copyWith(rememberedApprovals: [approval]),
      ]).encode(),
    ).servers.single;

    expect(migrated.rememberedApprovals, isEmpty);
    expect(decoded.rememberedApprovals.single.digest, approval.digest);
    expect(decoded.toString(), isNot(contains(approval.digest)));
  });

  test('version 3 drops credentials that would cross LAN HTTP', () {
    final server = DirectMcpServersDocument.decode(
      jsonEncode({
        'version': 3,
        'servers': [
          {
            'schemaVersion': 3,
            'id': 'legacy-lan',
            'name': 'Legacy LAN',
            'endpoint': 'http://192.168.1.20/mcp',
            'authMode': 'bearer',
            'bearerToken': 'secret',
            'customHeaders': {'X-Secret': 'header'},
            'rememberedApprovals': [],
          },
        ],
      }),
    ).servers.single;

    expect(server.authMode, DirectMcpAuthMode.none);
    expect(server.bearerToken, isNull);
    expect(server.customHeaders, isEmpty);
  });

  test('lenient document decode preserves valid unique servers', () {
    final decoded = DirectMcpServersDocument.decodeLenient(
      jsonEncode({
        'version': DirectMcpServersDocument.currentVersion,
        'servers': [
          {
            'schemaVersion': DirectMcpServer.currentSchemaVersion,
            'id': 'valid',
            'name': 'Valid',
            'endpoint': 'https://example.test/mcp',
            'authMode': 'none',
          },
          {'id': 'malformed'},
          {
            'schemaVersion': DirectMcpServer.currentSchemaVersion,
            'id': 'valid',
            'name': 'Duplicate',
            'endpoint': 'https://example.test/other',
            'authMode': 'none',
          },
        ],
      }),
    );

    expect(decoded.document.servers.map((server) => server.name), ['Valid']);
    expect(decoded.dropped, 2);
  });

  test('remembered approvals enforce bounded valid records', () {
    expect(
      () => DirectMcpServer(
        id: 'many',
        name: 'Many',
        endpoint: 'https://example.test/mcp',
        rememberedApprovals: [
          for (
            var index = 0;
            index <= kDirectMcpMaxRememberedApprovals;
            index++
          )
            _approval(index.toRadixString(16).padLeft(64, '0')),
        ],
      ).validate(),
      throwsFormatException,
    );
    expect(
      () => DirectMcpRememberedApproval(
        digest: 'not-a-digest',
        remoteToolName: 'lookup',
        displayName: 'Lookup',
        createdAt: DateTime.utc(2026),
      ).validate(),
      throwsFormatException,
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
        tokenEndpoint: 'https://tokens.example/token',
      ),
    );

    final decoded = DirectMcpServersDocument.decode(
      DirectMcpServersDocument([server]).encode(),
    ).servers.single;

    expect(decoded.authMode, DirectMcpAuthMode.oauth);
    expect(decoded.oauthTokens?.accessToken, accessToken);
    expect(decoded.oauthTokens?.refreshToken, refreshToken);
    expect(decoded.oauthTokens?.grantedScope, 'tools.read tools.call');
    for (final diagnostic in [
      decoded.toString(),
      decoded.oauthTokens.toString(),
    ]) {
      expect(diagnostic, isNot(contains(accessToken)));
      expect(diagnostic, isNot(contains(refreshToken)));
    }
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
    expect(
      () => DirectMcpServer(
        id: 'wrong-resource-path',
        name: 'Wrong resource path',
        endpoint: 'https://resource.example/mcp',
        authMode: DirectMcpAuthMode.oauth,
        oauthTokens: _oauthTokens(
          resource: 'https://resource.example/other-mcp',
        ),
      ).validate(),
      throwsFormatException,
    );
    expect(
      () => DirectMcpServer(
        id: 'wrong-resource-query',
        name: 'Wrong resource query',
        endpoint: 'https://resource.example/mcp?tenant=two',
        authMode: DirectMcpAuthMode.oauth,
        oauthTokens: _oauthTokens(
          resource: 'https://resource.example/mcp?tenant=one',
        ),
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

  test('credential-bearing LAN HTTP requires an explicit confirmation', () {
    final insecure = DirectMcpServer(
      id: 'lan',
      name: 'LAN',
      endpoint: 'http://192.168.1.20/mcp',
      bearerToken: 'secret',
    );

    expect(insecure.validate, throwsFormatException);
    expect(
      insecure.copyWith(allowInsecureCredentials: true).validate,
      returnsNormally,
    );
    expect(
      DirectMcpServer(
        id: 'loopback',
        name: 'Loopback',
        endpoint: 'http://127.0.0.1:3000/mcp',
        bearerToken: 'secret',
      ).validate,
      returnsNormally,
    );
    expect(
      DirectMcpServer(
        id: 'ipv6-loopback',
        name: 'IPv6 loopback',
        endpoint: 'http://[0:0:0:0:0:0:0:1]:3000/mcp',
        bearerToken: 'secret',
      ).validate,
      returnsNormally,
    );
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

  test('security mutations clear grants while token refresh retains them', () {
    final approval = _approval('a');
    final previous = DirectMcpServer(
      id: 'server',
      name: 'Server',
      endpoint: 'https://resource.example/mcp',
      authMode: DirectMcpAuthMode.oauth,
      oauthTokens: _oauthTokens(),
      rememberedApprovals: [approval],
    );

    final refreshed = DirectMcpServer.secureUpdate(
      previous: previous,
      next: previous.copyWith(
        oauthTokens: _oauthTokens(accessToken: 'new-access'),
      ),
    );
    final moved = DirectMcpServer.secureUpdate(
      previous: previous,
      next: previous.copyWith(endpoint: 'https://other.example/mcp'),
    );
    final pathMoved = DirectMcpServer.secureUpdate(
      previous: previous,
      next: previous.copyWith(endpoint: 'https://resource.example/other'),
    );
    final issuerChanged = DirectMcpServer.secureUpdate(
      previous: previous,
      next: previous.copyWith(
        oauthTokens: _oauthTokens(issuer: 'https://other-auth.example'),
      ),
      oauthFlowCompletedForExactMutation: true,
    );

    expect(refreshed.rememberedApprovals, [approval]);
    expect(moved.rememberedApprovals, isEmpty);
    expect(pathMoved.rememberedApprovals, isEmpty);
    expect(issuerChanged.rememberedApprovals, isEmpty);
  });

  test('switching to a supplied bearer token preserves that credential', () {
    final previous = DirectMcpServer(
      id: 'server',
      name: 'Server',
      endpoint: 'https://resource.example/mcp',
    );
    final updated = DirectMcpServer.secureUpdate(
      previous: previous,
      next: previous.copyWith(
        authMode: DirectMcpAuthMode.bearer,
        bearerToken: 'new-secret',
      ),
    );

    expect(updated.authMode, DirectMcpAuthMode.bearer);
    expect(updated.bearerToken, 'new-secret');
  });

  test('unsafe OAuth credential mutations are cleared', () {
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
    final pathMoved = DirectMcpServer.secureUpdate(
      previous: previous,
      next: previous.copyWith(endpoint: 'https://resource.example/other-mcp'),
    );
    final rootBound = previous.copyWith(
      oauthTokens: _oauthTokens(resource: 'https://resource.example/'),
    );
    final rootPathMoved = DirectMcpServer.secureUpdate(
      previous: rootBound,
      next: rootBound.copyWith(endpoint: 'https://resource.example/other-mcp'),
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
    expect(pathMoved.oauthTokens, isNull);
    expect(pathMoved.customHeaders, {'X-Tenant': 'one'});
    expect(rootPathMoved.oauthTokens, isNotNull);
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

  test('store limits enabled MCP servers to the session maximum', () async {
    final store = DirectMcpServerStore(
      SecureCredentialStorage(instance: const FlutterSecureStorage()),
    );

    for (var index = 0; index < kDirectMcpMaxServers; index++) {
      await store.upsert(
        DirectMcpServer(
          id: 'server_$index',
          name: 'Server $index',
          endpoint: 'https://server$index.example/mcp',
        ),
      );
    }

    await expectLater(
      store.upsert(
        DirectMcpServer(
          id: 'overflow',
          name: 'Overflow',
          endpoint: 'https://overflow.example/mcp',
        ),
      ),
      throwsFormatException,
    );
    expect(await store.load(), hasLength(kDirectMcpMaxServers));
  });

  test(
    'store remembers, prunes, and conflicts on configuration drift',
    () async {
      const platformStorage = FlutterSecureStorage();
      final store = DirectMcpServerStore(
        SecureCredentialStorage(instance: platformStorage),
      );
      final original = DirectMcpServer(
        id: 'server',
        name: 'Server',
        endpoint: 'https://resource.example/mcp',
        authMode: DirectMcpAuthMode.oauth,
        oauthTokens: _oauthTokens(),
      );
      await store.upsert(original);
      final withApprovals = (await store.rememberApproval(
        original,
        _approval('a'),
      )).single;
      final rotated = withApprovals.copyWith(
        oauthTokens: _oauthTokens(
          accessToken: 'rotated-access',
          refreshToken: 'rotated-refresh',
        ),
      );
      await store.upsert(rotated, expectedPrevious: withApprovals);
      final remembered = (await store.rememberApproval(
        withApprovals,
        _approval('b'),
      )).single;

      expect(remembered.rememberedApprovals, hasLength(2));
      final pruned = (await store.pruneRememberedApprovals(
        [remembered],
        {
          'server': {_approval('b').digest},
        },
      )).single;
      expect(pruned.rememberedApprovals.single.digest, _approval('b').digest);
      await store.upsert(
        pruned.copyWith(name: 'Changed'),
        expectedPrevious: pruned,
      );
      await expectLater(
        store.rememberApproval(pruned, _approval('c')),
        throwsA(isA<DirectMcpServerConflictException>()),
      );
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

  test('fractional schema versions are rejected', () {
    final server = DirectMcpServer(
      id: 'server',
      name: 'Server',
      endpoint: 'https://server.example/mcp',
    ).toJson();

    expect(
      () => DirectMcpServer.fromJson({...server, 'schemaVersion': 3.5}),
      throwsFormatException,
    );
    expect(
      () => DirectMcpServersDocument.decode(
        jsonEncode({
          'version': 3.5,
          'servers': [server],
        }),
      ),
      throwsFormatException,
    );
  });
}

DirectMcpOAuthTokens _oauthTokens({
  String accessToken = 'access-secret',
  String? refreshToken = 'refresh-secret',
  String issuer = 'https://auth.example',
  String resource = 'https://resource.example/mcp',
  String? tokenEndpoint,
}) => DirectMcpOAuthTokens(
  accessToken: accessToken,
  refreshToken: refreshToken,
  grantedScope: 'tools.read tools.call',
  expiresAt: DateTime.utc(2030),
  authorizationServerIssuer: issuer,
  resource: resource,
  clientId: 'public-client-id',
  tokenEndpoint: tokenEndpoint ?? '$issuer/token',
);

DirectMcpRememberedApproval _approval(String seed, {String tool = 'lookup'}) =>
    DirectMcpRememberedApproval(
      digest: seed.length == 64 ? seed : seed * 64,
      remoteToolName: tool,
      displayName: 'Lookup',
      createdAt: DateTime.utc(2026),
    );
