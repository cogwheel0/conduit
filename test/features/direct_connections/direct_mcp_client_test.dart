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
  });

  final HttpServer server;
  final StreamSubscription<HttpRequest> subscription;
  final bool holdToolCalls;
  final List<String> toolNames;
  final bool invalidSchema;
  final String resultText;
  final bool includeImage;
  final bool failDiscovery;
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
    );
    return fixture;
  }

  Future<void> _handle(HttpRequest request) async {
    authorizationHeaders.add(
      request.headers.value(HttpHeaders.authorizationHeader),
    );
    customHeaders.add(request.headers.value('X-Conduit-Test'));
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
        result = {
          'tools': [
            for (final name in toolNames)
              {
                'name': name,
                'description': 'Returns its value.',
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
          'ttlMs': 0,
          'cacheScope': mcp.CacheScope.private,
        };
      case mcp.Method.toolsCall:
        callCount++;
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
