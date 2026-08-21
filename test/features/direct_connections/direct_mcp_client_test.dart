import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit/features/direct_connections/models/direct_completion.dart';
import 'package:conduit/features/direct_connections/models/direct_mcp_server.dart';
import 'package:conduit/features/direct_connections/services/direct_mcp_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart' as mcp;

void main() {
  test('lists tools from a Streamable HTTP server', () async {
    final fixture = await _McpFixture.start();
    addTearDown(fixture.close);
    final client = DirectMcpClient(endpoint: fixture.endpoint);
    addTearDown(client.close);

    await client.connect();
    final tools = await client.listTools();

    expect(tools.map((tool) => tool.name), ['echo']);
  });

  test('calls one Streamable HTTP tool', () async {
    final fixture = await _McpFixture.start();
    addTearDown(fixture.close);
    final client = DirectMcpClient(endpoint: fixture.endpoint);
    addTearDown(client.close);

    await client.connect();
    final result = await client.callTool('echo', {'value': 'hello'});

    expect((result.content.single as mcp.TextContent).text, 'hello');
    expect(fixture.callCount, 1);
  });

  test(
    'sends bearer and custom headers only to the configured endpoint',
    () async {
      final fixture = await _McpFixture.start();
      addTearDown(fixture.close);
      final client = DirectMcpClient(
        endpoint: fixture.endpoint,
        headers: const {
          HttpHeaders.authorizationHeader: 'Bearer secret',
          'X-Conduit-Test': 'yes',
        },
      );
      addTearDown(client.close);

      await client.connect();
      await client.listTools();

      expect(fixture.authorizationHeaders, isNotEmpty);
      expect(fixture.authorizationHeaders, everyElement('Bearer secret'));
      expect(fixture.customHeaders, everyElement('yes'));
    },
  );

  test(
    'injects an OAuth token only through the selected server client',
    () async {
      final fixture = await _McpFixture.start();
      addTearDown(fixture.close);
      final server = _oauthServerFor(fixture, accessToken: 'oauth-secret');

      final session = await DirectMcpToolSession.open(
        [server],
        authorizationResolver: (server, {forceRefresh = false}) async =>
            server.oauthTokens!.accessToken,
      );
      addTearDown(session.close);

      expect(fixture.authorizationHeaders, isNotEmpty);
      expect(fixture.authorizationHeaders, everyElement('Bearer oauth-secret'));
    },
  );

  test(
    'refreshes once and retries idempotent MCP preflight after 401',
    () async {
      final fixture = await _McpFixture.start(
        requiredAuthorization: 'Bearer fresh-token',
      );
      addTearDown(fixture.close);
      var forcedRefreshes = 0;

      final session = await DirectMcpToolSession.open(
        [_oauthServerFor(fixture, accessToken: 'stale-token')],
        authorizationResolver: (server, {forceRefresh = false}) async {
          if (forceRefresh) forcedRefreshes++;
          return forceRefresh ? 'fresh-token' : server.oauthTokens!.accessToken;
        },
      );
      addTearDown(session.close);

      expect(session.definitions, hasLength(1));
      expect(forcedRefreshes, 1);
      expect(fixture.authorizationHeaders, contains('Bearer stale-token'));
      expect(fixture.authorizationHeaders, contains('Bearer fresh-token'));
    },
  );

  test('does not replay a tool call after an ambiguous OAuth 401', () async {
    final fixture = await _McpFixture.start(unauthorizedToolCalls: true);
    addTearDown(fixture.close);
    var forcedRefreshes = 0;
    final session = await DirectMcpToolSession.open(
      [_oauthServerFor(fixture, accessToken: 'oauth-secret')],
      authorizationResolver: (server, {forceRefresh = false}) async {
        if (forceRefresh) forcedRefreshes++;
        return 'oauth-secret';
      },
    );
    addTearDown(session.close);

    await expectLater(
      session.execute(session.definitions.single.modelName, const {
        'value': 'once',
      }),
      throwsA(
        isA<DirectProviderException>().having(
          (error) => error.message,
          'message',
          contains('Retry the model turn'),
        ),
      ),
    );

    expect(fixture.callCount, 1);
    expect(forcedRefreshes, 1);
  });

  test('close settles an in-flight tool call', () async {
    final fixture = await _McpFixture.start(holdToolCalls: true);
    addTearDown(fixture.close);
    final client = DirectMcpClient(endpoint: fixture.endpoint);
    addTearDown(client.close);
    await client.connect();

    final call = client.callTool('echo', {'value': 'wait'});
    await fixture.toolCallReceived.future.timeout(const Duration(seconds: 5));
    await client.close().timeout(const Duration(seconds: 5));

    await expectLater(
      call,
      throwsA(anything),
    ).timeout(const Duration(seconds: 5));
  });

  test('normalizes colliding tool names into unique bounded names', () async {
    final fixture = await _McpFixture.start(
      toolNames: ['same.name', 'same name'],
    );
    addTearDown(fixture.close);

    final session = await DirectMcpToolSession.open([
      _serverFor(fixture, id: 'collision-server'),
    ]);
    addTearDown(session.close);

    expect(session.definitions, hasLength(2));
    expect(
      session.definitions.map((tool) => tool.modelName).toSet(),
      hasLength(2),
    );
    for (final definition in session.definitions) {
      expect(definition.modelName, matches(RegExp(r'^[A-Za-z0-9_-]{1,64}$')));
    }
  });

  test('rejects malformed schemas with a sanitized preflight error', () async {
    final fixture = await _McpFixture.start(invalidSchema: true);
    addTearDown(fixture.close);

    await expectLater(
      DirectMcpToolSession.open([_serverFor(fixture)]),
      throwsA(isA<DirectProviderException>()),
    );
  });

  test('rejects inventories above the fixed tool limit', () async {
    final fixture = await _McpFixture.start(
      toolNames: List.generate(
        kDirectMcpMaxTools + 1,
        (index) => 'tool_$index',
      ),
    );
    addTearDown(fixture.close);

    await expectLater(
      DirectMcpToolSession.open([_serverFor(fixture)]),
      throwsA(isA<DirectProviderException>()),
    );
  });

  test('rejects a repeated tools/list pagination cursor', () async {
    final fixture = await _McpFixture.start(repeatListCursor: true);
    addTearDown(fixture.close);
    final client = DirectMcpClient(endpoint: fixture.endpoint);
    addTearDown(client.close);
    await client.connect();

    await expectLater(
      client.listTools(),
      throwsA(isA<DirectProviderException>()),
    );
    expect(fixture.listCount, 2);
  });

  test('rejects cumulative paginated inventory overflow', () async {
    final fixture = await _McpFixture.start(
      listPageCount: 9,
      toolDescriptionCharacters: kDirectMcpMaxInventoryBytes ~/ 8,
    );
    addTearDown(fixture.close);
    final client = DirectMcpClient(endpoint: fixture.endpoint);
    addTearDown(client.close);
    await client.connect();

    await expectLater(
      client.listTools(),
      throwsA(isA<DirectProviderException>()),
    );
    expect(fixture.listCount, greaterThan(1));
  });

  test('rejects oversized arguments before tools/call', () async {
    final fixture = await _McpFixture.start();
    addTearDown(fixture.close);
    final session = await DirectMcpToolSession.open([_serverFor(fixture)]);
    addTearDown(session.close);

    await expectLater(
      session.execute(session.definitions.single.modelName, {
        'value': 'x' * (kDirectMcpMaxArgumentsBytes + 1),
      }),
      throwsA(isA<DirectProviderException>()),
    );
    expect(fixture.callCount, 0);
  });

  test('truncates results and omits unsupported binary content', () async {
    final fixture = await _McpFixture.start(
      resultText: 'x' * (128 * 1024 + 100),
      includeImage: true,
    );
    addTearDown(fixture.close);
    final session = await DirectMcpToolSession.open([_serverFor(fixture)]);
    addTearDown(session.close);

    final result = await session.execute(
      session.definitions.single.modelName,
      const {'value': 'hello'},
    );

    expect(result.text.length, 128 * 1024);
    expect(result.text, endsWith('[truncated]'));
    expect(result.text, isNot(contains('aGVsbG8=')));
  });

  test('rejects unknown model-facing tool names', () async {
    final fixture = await _McpFixture.start();
    addTearDown(fixture.close);
    final session = await DirectMcpToolSession.open([_serverFor(fixture)]);
    addTearDown(session.close);

    await expectLater(
      session.execute('unknown', const {}),
      throwsA(isA<DirectProviderException>()),
    );
    expect(fixture.callCount, 0);
  });

  test('closes earlier clients when a later server fails preflight', () async {
    final first = await _McpFixture.start();
    final second = await _McpFixture.start(failDiscovery: true);
    addTearDown(first.close);
    addTearDown(second.close);

    await expectLater(
      DirectMcpToolSession.open([
        _serverFor(first, id: 'first'),
        _serverFor(second, id: 'second'),
      ]),
      throwsA(isA<DirectProviderException>()),
    );
    expect(first.listCount, 1);
    expect(second.discoverCount, 1);
  });
}

DirectMcpServer _serverFor(_McpFixture fixture, {String id = 'test'}) =>
    DirectMcpServer(
      id: id,
      name: 'Test server',
      endpoint: fixture.endpoint.toString(),
    );

DirectMcpServer _oauthServerFor(
  _McpFixture fixture, {
  required String accessToken,
}) => DirectMcpServer(
  id: 'oauth-test',
  name: 'OAuth test server',
  endpoint: fixture.endpoint.toString(),
  authMode: DirectMcpAuthMode.oauth,
  oauthTokens: DirectMcpOAuthTokens(
    accessToken: accessToken,
    refreshToken: 'refresh-secret',
    expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
    authorizationServerIssuer: fixture.endpoint
        .replace(path: '/issuer')
        .toString(),
    resource: fixture.endpoint.toString(),
    clientId: 'public-client',
    tokenEndpoint: fixture.endpoint.replace(path: '/token').toString(),
  ),
);

final class _McpFixture {
  _McpFixture._(
    this.server,
    this.subscription, {
    required this.holdToolCalls,
    required this.toolNames,
    required this.invalidSchema,
    required this.resultText,
    required this.includeImage,
    required this.failDiscovery,
    required this.repeatListCursor,
    required this.listPageCount,
    required this.toolDescriptionCharacters,
    required this.requiredAuthorization,
    required this.unauthorizedToolCalls,
  });

  final HttpServer server;
  final StreamSubscription<HttpRequest> subscription;
  final bool holdToolCalls;
  final List<String> toolNames;
  final bool invalidSchema;
  final String resultText;
  final bool includeImage;
  final bool failDiscovery;
  final bool repeatListCursor;
  final int listPageCount;
  final int toolDescriptionCharacters;
  final String? requiredAuthorization;
  final bool unauthorizedToolCalls;
  final Completer<void> toolCallReceived = Completer<void>();
  final List<String?> authorizationHeaders = [];
  final List<String?> customHeaders = [];
  int callCount = 0;
  int listCount = 0;
  int discoverCount = 0;

  Uri get endpoint =>
      Uri.parse('http://${server.address.address}:${server.port}/mcp');

  static Future<_McpFixture> start({
    bool holdToolCalls = false,
    List<String> toolNames = const ['echo'],
    bool invalidSchema = false,
    String resultText = '',
    bool includeImage = false,
    bool failDiscovery = false,
    bool repeatListCursor = false,
    int listPageCount = 1,
    int toolDescriptionCharacters = 0,
    String? requiredAuthorization,
    bool unauthorizedToolCalls = false,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    late _McpFixture fixture;
    final subscription = server.listen((request) => fixture._handle(request));
    fixture = _McpFixture._(
      server,
      subscription,
      holdToolCalls: holdToolCalls,
      toolNames: toolNames,
      invalidSchema: invalidSchema,
      resultText: resultText,
      includeImage: includeImage,
      failDiscovery: failDiscovery,
      repeatListCursor: repeatListCursor,
      listPageCount: listPageCount,
      toolDescriptionCharacters: toolDescriptionCharacters,
      requiredAuthorization: requiredAuthorization,
      unauthorizedToolCalls: unauthorizedToolCalls,
    );
    return fixture;
  }

  Future<void> _handle(HttpRequest request) async {
    authorizationHeaders.add(
      request.headers.value(HttpHeaders.authorizationHeader),
    );
    customHeaders.add(request.headers.value('X-Conduit-Test'));
    if (requiredAuthorization != null &&
        request.headers.value(HttpHeaders.authorizationHeader) !=
            requiredAuthorization) {
      request.response.statusCode = HttpStatus.unauthorized;
      await request.response.close();
      return;
    }
    if (request.method != 'POST' || request.uri.path != '/mcp') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
      return;
    }

    final body =
        jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>;
    final id = body['id'] as int;
    final method = body['method'] as String;
    Map<String, dynamic> result;
    switch (method) {
      case mcp.Method.serverDiscover:
        discoverCount++;
        if (failDiscovery) {
          request.response.statusCode = HttpStatus.internalServerError;
          await request.response.close();
          return;
        }
        result = const mcp.DiscoverResult(
          supportedVersions: [mcp.stableProtocolVersion],
          capabilities: mcp.ServerCapabilities(
            tools: mcp.ServerCapabilitiesTools(listChanged: false),
          ),
          serverInfo: mcp.Implementation(
            name: 'conduit-test-server',
            version: '1.0.0',
          ),
          ttlMs: 0,
          cacheScope: mcp.CacheScope.private,
        ).toJson();
      case mcp.Method.toolsList:
        listCount++;
        final params = body['params'] as Map<String, dynamic>?;
        final cursor = params?['cursor'] as String?;
        final page = cursor?.startsWith('page-') == true
            ? int.parse(cursor!.substring('page-'.length))
            : 0;
        result = {
          'tools': [
            for (final name in toolNames)
              {
                'name': name,
                'description': toolDescriptionCharacters == 0
                    ? 'Returns its value.'
                    : 'x' * toolDescriptionCharacters,
                'inputSchema': invalidSchema
                    ? {'type': 'string'}
                    : {
                        'type': 'object',
                        'properties': {
                          'value': {'type': 'string'},
                        },
                      },
              },
          ],
          if (repeatListCursor)
            'nextCursor': 'repeat'
          else if (page + 1 < listPageCount)
            'nextCursor': 'page-${page + 1}',
          'ttlMs': 0,
          'cacheScope': mcp.CacheScope.private,
        };
      case mcp.Method.toolsCall:
        callCount++;
        if (unauthorizedToolCalls) {
          request.response.statusCode = HttpStatus.unauthorized;
          await request.response.close();
          return;
        }
        if (!toolCallReceived.isCompleted) toolCallReceived.complete();
        if (holdToolCalls) return;
        final params = body['params'] as Map<String, dynamic>;
        final arguments = params['arguments'] as Map<String, dynamic>;
        result = {
          'content': [
            {
              'type': 'text',
              'text': resultText.isEmpty
                  ? arguments['value'] as String
                  : resultText,
            },
            if (includeImage)
              {'type': 'image', 'mimeType': 'image/png', 'data': 'aGVsbG8='},
          ],
          'isError': false,
        };
      default:
        request.response
          ..statusCode = HttpStatus.badRequest
          ..write('unsupported');
        await request.response.close();
        return;
    }

    result.putIfAbsent('resultType', () => mcp.resultTypeComplete);
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(mcp.JsonRpcResponse(id: id, result: result).toJson()));
    await request.response.close();
  }

  Future<void> close() async {
    await subscription.cancel();
    await server.close(force: true);
  }
}
