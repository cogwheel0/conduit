import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart' as mcp;

/// A minimal MCP server on a loopback port: one `echo` tool, and an
/// optional bearer token it insists on.
///
/// Enough of the protocol for the daemon's `mcp.*` and a direct turn's
/// tool calls, over the real HTTP client the core uses.
final class McpFixture {
  McpFixture._(this._server, {this.requiredToken});

  final HttpServer _server;
  final String? requiredToken;
  final List<Map<String, dynamic>> calls = <Map<String, dynamic>>[];

  Uri get endpoint =>
      Uri.parse('http://${_server.address.address}:${_server.port}/mcp');

  static Future<McpFixture> start({String? requiredToken}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = McpFixture._(server, requiredToken: requiredToken);
    server.listen(fixture._handle);
    return fixture;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    if (requiredToken != null &&
        request.headers.value(HttpHeaders.authorizationHeader) !=
            'Bearer $requiredToken') {
      await request.drain<void>();
      request.response.statusCode = HttpStatus.unauthorized;
      await request.response.close();
      return;
    }
    if (request.method != 'POST' || request.uri.path != '/mcp') {
      await request.drain<void>();
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
      return;
    }
    final body =
        jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>;
    final Map<String, dynamic> result;
    switch (body['method']) {
      case mcp.Method.serverDiscover:
        result = const mcp.DiscoverResult(
          supportedVersions: [mcp.stableProtocolVersion],
          capabilities: mcp.ServerCapabilities(
            tools: mcp.ServerCapabilitiesTools(listChanged: false),
          ),
          serverInfo: mcp.Implementation(name: 'fixture', version: '1.0.0'),
          ttlMs: 0,
          cacheScope: mcp.CacheScope.private,
        ).toJson();
      case mcp.Method.toolsList:
        result = <String, dynamic>{
          'tools': [
            {
              'name': 'echo',
              'description': 'Returns its value.',
              'inputSchema': {
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
        final params = body['params'] as Map<String, dynamic>;
        calls.add(params);
        final arguments = params['arguments'] as Map<String, dynamic>;
        result = <String, dynamic>{
          'content': [
            {'type': 'text', 'text': '${arguments['value']}'},
          ],
          'isError': false,
        };
      default:
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
    }
    result.putIfAbsent('resultType', () => mcp.resultTypeComplete);
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(
        jsonEncode(
          mcp.JsonRpcResponse(id: body['id'] as int, result: result).toJson(),
        ),
      );
    await request.response.close();
  }
}
