import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit/core/providers/storage_providers.dart';
import 'package:conduit/features/direct_connections/models/direct_completion.dart';
import 'package:conduit/features/direct_connections/models/direct_mcp_content.dart';
import 'package:conduit/features/direct_connections/models/direct_mcp_server.dart';
import 'package:conduit/features/direct_connections/providers/direct_mcp_providers.dart';
import 'package:conduit/features/direct_connections/services/direct_mcp_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart' as mcp;

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('content cleanup preserves the primary failure', () async {
    final operationError = StateError('operation failed');
    final closeError = StateError('close failed');

    await expectLater(
      runDirectMcpContentOperation<void>(
        operation: () async => throw operationError,
        close: () async => throw closeError,
      ),
      throwsA(same(operationError)),
    );
    await expectLater(
      runDirectMcpContentOperation<void>(
        operation: () async {},
        close: () async => throw closeError,
      ),
      throwsA(same(closeError)),
    );
  });

  test(
    'lists, gets, and reads explicit text content without calling tools',
    () async {
      final fixture = await _ContentFixture.start(
        requiredAuthorization: 'Bearer secret',
      );
      addTearDown(fixture.close);
      final session = await DirectMcpContentSession.open(
        _server(fixture, bearerToken: 'secret'),
      );
      addTearDown(session.close);

      final inventory = await session.loadInventory();
      final prompt = inventory.prompts.single;
      expect(prompt.arguments.single.name, 'topic');
      final promptPreview = await session.getPrompt(prompt, const {
        'topic': 'MCP',
      });
      expect(promptPreview.messages.single.text, 'Explain MCP');
      final resource = inventory.resources.first;
      final resourcePreview = await session.readResource(resource);

      expect(resourcePreview.text, 'local resource');
      expect(fixture.toolCallCount, 0);
      expect(fixture.authorizationHeaders, everyElement('Bearer secret'));
    },
  );

  test('rejects repeated cursors and inventories above fixed bounds', () async {
    final repeated = await _ContentFixture.start(repeatPromptCursor: true);
    addTearDown(repeated.close);
    final repeatedSession = await DirectMcpContentSession.open(
      _server(repeated),
    );
    addTearDown(repeatedSession.close);
    await expectLater(
      repeatedSession.loadInventory(),
      throwsA(isA<DirectProviderException>()),
    );

    final oversized = await _ContentFixture.start(
      promptCount: kDirectMcpMaxPrompts + 1,
    );
    addTearDown(oversized.close);
    final oversizedSession = await DirectMcpContentSession.open(
      _server(oversized),
    );
    addTearDown(oversizedSession.close);
    await expectLater(
      oversizedSession.loadInventory(),
      throwsA(isA<DirectProviderException>()),
    );
  });

  test('rejects changed prompt and resource inventory ownership', () async {
    final fixture = await _ContentFixture.start(changeInventory: true);
    addTearDown(fixture.close);
    final session = await DirectMcpContentSession.open(_server(fixture));
    addTearDown(session.close);
    final inventory = await session.loadInventory();

    await expectLater(
      session.getPrompt(inventory.prompts.single, const {'topic': 'safe'}),
      throwsA(isA<DirectProviderException>()),
    );
    await expectLater(
      session.readResource(inventory.resources.first),
      throwsA(isA<DirectProviderException>()),
    );
    expect(fixture.promptGetCount, 0);
    expect(fixture.resourceReadCount, 0);
  });

  test('validates required, unknown, and oversized prompt arguments', () async {
    final fixture = await _ContentFixture.start();
    addTearDown(fixture.close);
    final session = await DirectMcpContentSession.open(_server(fixture));
    addTearDown(session.close);
    final prompt = (await session.loadInventory()).prompts.single;

    for (final arguments in <Map<String, String>>[
      const {},
      const {'topic': 'ok', 'unknown': 'no'},
      {'topic': 'x' * (kDirectMcpMaxPromptArgumentValueBytes + 1)},
    ]) {
      await expectLater(
        session.getPrompt(prompt, arguments),
        throwsA(isA<DirectProviderException>()),
      );
    }
    expect(fixture.promptGetCount, 0);
  });

  test('rejects binary, non-text MIME, and oversized content', () async {
    for (final fixture in <_ContentFixture>[
      await _ContentFixture.start(binaryResource: true),
      await _ContentFixture.start(resourceMimeType: 'application/json'),
      await _ContentFixture.start(
        resourceText: 'x' * (kDirectMcpMaxContentItemBytes + 1),
      ),
    ]) {
      addTearDown(fixture.close);
      final session = await DirectMcpContentSession.open(_server(fixture));
      addTearDown(session.close);
      final resource = (await session.loadInventory()).resources.first;
      await expectLater(
        session.readResource(resource),
        throwsA(isA<DirectProviderException>()),
      );
    }
  });

  test('rejects prompt and resource responses with too many parts', () async {
    for (final fixture in <_ContentFixture>[
      await _ContentFixture.start(
        promptMessageCount: kDirectMcpMaxContentParts + 1,
      ),
      await _ContentFixture.start(
        resourceContentCount: kDirectMcpMaxContentParts + 1,
      ),
    ]) {
      addTearDown(fixture.close);
      final session = await DirectMcpContentSession.open(_server(fixture));
      addTearDown(session.close);
      final inventory = await session.loadInventory();
      await expectLater(
        fixture.promptMessageCount > 1
            ? session.getPrompt(inventory.prompts.single, const {
                'topic': 'MCP',
              })
            : session.readResource(inventory.resources.first),
        throwsA(isA<DirectProviderException>()),
      );
    }
  });

  test('cancels an in-flight prompt get', () async {
    final fixture = await _ContentFixture.start(holdPromptGet: true);
    addTearDown(fixture.close);
    final session = await DirectMcpContentSession.open(_server(fixture));
    addTearDown(session.close);
    final prompt = (await session.loadInventory()).prompts.single;
    final abort = mcp.BasicAbortController();
    final pending = session.getPrompt(prompt, const {
      'topic': 'wait',
    }, signal: abort.signal);
    await fixture.promptGetReceived.future.timeout(const Duration(seconds: 5));

    abort.abort();

    await expectLater(
      pending,
      throwsA(isA<mcp.AbortError>()),
    ).timeout(const Duration(seconds: 5));
    expect(fixture.toolCallCount, 0);
  });

  test(
    'per-server providers refresh independently and persist no content',
    () async {
      var firstLoads = 0;
      const storage = FlutterSecureStorage();
      final container = ProviderContainer(
        overrides: [
          secureStorageProvider.overrideWithValue(storage),
          directMcpContentInventoryLoaderProvider.overrideWithValue((
            server,
          ) async {
            if (server.id == 'second') throw StateError('fixture failure');
            firstLoads++;
            return DirectMcpContentInventory(
              serverId: server.id,
              serverName: server.name,
              prompts: const [],
              resources: const [],
            );
          }),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(directMcpServersProvider.notifier);
      await notifier.upsert(
        DirectMcpServer(
          id: 'first',
          name: 'First',
          endpoint: 'https://first.example/mcp',
        ),
      );
      await notifier.upsert(
        DirectMcpServer(
          id: 'second',
          name: 'Unavailable',
          endpoint: 'http://127.0.0.1:1/mcp',
        ),
      );

      expect(
        (await container.read(
          directMcpContentInventoryProvider('first').future,
        )).serverId,
        'first',
      );
      await expectLater(
        container.read(directMcpContentInventoryProvider('second').future),
        throwsA(anything),
      );
      final before = firstLoads;
      await container.refresh(
        directMcpContentInventoryProvider('first').future,
      );
      expect(firstLoads, before + 1);
      expect(
        (await container.read(directMcpServerStoreProvider).load()).map(
          (server) => server.id,
        ),
        ['first', 'second'],
      );
    },
  );
}

DirectMcpServer _server(
  _ContentFixture fixture, {
  String id = 'content',
  String? bearerToken,
}) => DirectMcpServer(
  id: id,
  name: 'Local content',
  endpoint: fixture.endpoint.toString(),
  authMode: bearerToken == null
      ? DirectMcpAuthMode.none
      : DirectMcpAuthMode.bearer,
  bearerToken: bearerToken,
);

final class _ContentFixture {
  _ContentFixture._(
    this.server,
    this.subscription, {
    required this.repeatPromptCursor,
    required this.promptCount,
    required this.changeInventory,
    required this.binaryResource,
    required this.resourceMimeType,
    required this.resourceText,
    required this.promptMessageCount,
    required this.resourceContentCount,
    required this.holdPromptGet,
    required this.requiredAuthorization,
  });

  final HttpServer server;
  final StreamSubscription<HttpRequest> subscription;
  final bool repeatPromptCursor;
  final int promptCount;
  final bool changeInventory;
  final bool binaryResource;
  final String? resourceMimeType;
  final String resourceText;
  final int promptMessageCount;
  final int resourceContentCount;
  final bool holdPromptGet;
  final String? requiredAuthorization;
  final List<String?> authorizationHeaders = [];
  final Completer<void> promptGetReceived = Completer<void>();
  int promptListCount = 0;
  int resourceListCount = 0;
  int promptGetCount = 0;
  int resourceReadCount = 0;
  int toolCallCount = 0;

  Uri get endpoint =>
      Uri.parse('http://${server.address.address}:${server.port}/mcp');

  static Future<_ContentFixture> start({
    bool repeatPromptCursor = false,
    int promptCount = 1,
    bool changeInventory = false,
    bool binaryResource = false,
    String? resourceMimeType = 'text/plain',
    String resourceText = 'local resource',
    int promptMessageCount = 1,
    int resourceContentCount = 1,
    bool holdPromptGet = false,
    String? requiredAuthorization,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    late _ContentFixture fixture;
    final subscription = server.listen((request) => fixture._handle(request));
    fixture = _ContentFixture._(
      server,
      subscription,
      repeatPromptCursor: repeatPromptCursor,
      promptCount: promptCount,
      changeInventory: changeInventory,
      binaryResource: binaryResource,
      resourceMimeType: resourceMimeType,
      resourceText: resourceText,
      promptMessageCount: promptMessageCount,
      resourceContentCount: resourceContentCount,
      holdPromptGet: holdPromptGet,
      requiredAuthorization: requiredAuthorization,
    );
    return fixture;
  }

  Future<void> _handle(HttpRequest request) async {
    authorizationHeaders.add(
      request.headers.value(HttpHeaders.authorizationHeader),
    );
    if (requiredAuthorization != null &&
        request.headers.value(HttpHeaders.authorizationHeader) !=
            requiredAuthorization) {
      await request.drain<void>();
      request.response.statusCode = HttpStatus.unauthorized;
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
        result = const mcp.DiscoverResult(
          supportedVersions: [mcp.stableProtocolVersion],
          capabilities: mcp.ServerCapabilities(
            prompts: mcp.ServerCapabilitiesPrompts(listChanged: false),
            resources: mcp.ServerCapabilitiesResources(
              subscribe: false,
              listChanged: false,
            ),
          ),
          serverInfo: mcp.Implementation(name: 'content-fixture', version: '1'),
          ttlMs: 0,
          cacheScope: mcp.CacheScope.private,
        ).toJson();
      case mcp.Method.promptsList:
        promptListCount++;
        result = {
          'prompts': [
            for (var index = 0; index < promptCount; index++)
              {
                'name': index == 0 ? 'explain' : 'prompt_$index',
                'title': changeInventory && promptListCount > 1
                    ? 'Changed prompt'
                    : 'Explain topic',
                'description': 'Builds a short explanation.',
                'arguments': [
                  {'name': 'topic', 'required': true},
                ],
              },
          ],
          if (repeatPromptCursor) 'nextCursor': 'repeat',
          'ttlMs': 0,
          'cacheScope': mcp.CacheScope.private,
        };
      case mcp.Method.resourcesList:
        resourceListCount++;
        result = {
          'resources': [
            {
              'uri': 'file:///notes/readme.txt',
              'name': changeInventory && resourceListCount > 1
                  ? 'Changed notes'
                  : 'Local notes',
              if (resourceMimeType != null) 'mimeType': resourceMimeType,
            },
          ],
          'ttlMs': 0,
          'cacheScope': mcp.CacheScope.private,
        };
      case mcp.Method.promptsGet:
        promptGetCount++;
        if (!promptGetReceived.isCompleted) promptGetReceived.complete();
        if (holdPromptGet) return;
        final arguments =
            (body['params'] as Map<String, dynamic>)['arguments']
                as Map<String, dynamic>;
        result = {
          'messages': [
            for (var index = 0; index < promptMessageCount; index++)
              {
                'role': 'user',
                'content': {
                  'type': 'text',
                  'text': 'Explain ${arguments['topic']}',
                },
              },
          ],
          'ttlMs': 0,
          'cacheScope': mcp.CacheScope.private,
        };
      case mcp.Method.resourcesRead:
        resourceReadCount++;
        result = {
          'contents': [
            for (var index = 0; index < resourceContentCount; index++)
              if (binaryResource)
                {
                  'uri': 'file:///notes/readme.txt',
                  'mimeType': 'application/octet-stream',
                  'blob': 'aGVsbG8=',
                }
              else
                {
                  'uri': 'file:///notes/readme.txt',
                  if (resourceMimeType != null) 'mimeType': resourceMimeType,
                  'text': resourceText,
                },
          ],
          'ttlMs': 0,
          'cacheScope': mcp.CacheScope.private,
        };
      case mcp.Method.toolsCall:
        toolCallCount++;
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      default:
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
    }
    result.putIfAbsent('resultType', () => mcp.resultTypeComplete);
    request.response
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(mcp.JsonRpcResponse(id: id, result: result).toJson()));
    await request.response.close();
  }

  Future<void> close() async {
    await subscription.cancel();
    await server.close(force: true);
  }
}
