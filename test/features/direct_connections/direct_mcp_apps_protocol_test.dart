import 'dart:convert';

import 'package:conduit/features/direct_connections/models/direct_mcp_app.dart';
import 'package:conduit/features/direct_connections/services/direct_mcp_apps_protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart' as mcp;

void main() {
  test(
    'accepts the stable initialize lifecycle and builds bounded host data',
    () {
      final protocol = _protocol();
      final request = protocol.decodeInbound(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'ui/initialize',
          'params': {
            'protocolVersion': kDirectMcpAppsProtocolVersion,
            'appCapabilities': {
              'availableDisplayModes': ['inline'],
            },
          },
        }),
      ) as DirectMcpAppInitializeRequest;

      expect(request.id, 1);
      expect(request.appCapabilities['availableDisplayModes'], ['inline']);
      expect(
        protocol.initializeResult(request.id),
        containsPair(
          'result',
          containsPair('protocolVersion', kDirectMcpAppsProtocolVersion),
        ),
      );
      protocol.completeRequest(request.id);
      expect(
        protocol.decodeInbound(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'ui/notifications/initialized',
            'params': <String, dynamic>{},
          }),
        ),
        isA<DirectMcpAppInitializedNotification>(),
      );
      expect(
        protocol.toolInputNotification(const {'city': 'Pune'}),
        containsPair('method', 'ui/notifications/tool-input'),
      );
      expect(
        protocol.toolResultNotification(const {
          'content': [
            {'type': 'text', 'text': 'clear'},
          ],
        }),
        containsPair('method', 'ui/notifications/tool-result'),
      );
    },
  );

  test('filters model and app tool visibility at the protocol boundary', () {
    final both = _tool('both');
    final appOnly = _tool('app-only', visibility: const ['app']);
    final modelOnly = _tool('model-only', visibility: const ['model']);

    expect(
      directMcpToolsVisibleToModel([
        both,
        appOnly,
        modelOnly,
      ], serverId: 'home').map((tool) => tool.name),
      ['both', 'model-only'],
    );
    expect(
      directMcpAppToolPolicy(appOnly, serverId: 'home').visibleToApp,
      isTrue,
    );
    expect(
      directMcpAppToolPolicy(modelOnly, serverId: 'home').visibleToApp,
      isFalse,
    );
    expect(
      () => directMcpAppToolPolicy(
        _tool('bad', visibility: const ['admin']),
        serverId: 'home',
      ),
      throwsA(isA<DirectMcpAppsProtocolException>()),
    );
    expect(
      () => directMcpAppToolPolicy(
        mcp.Tool(
          name: 'bad-meta',
          inputSchema: mcp.JsonSchema.fromJson(const {'type': 'object'}),
          meta: {
            'ui': {1: 'invalid'},
          },
        ),
        serverId: 'home',
      ),
      throwsA(isA<DirectMcpAppsProtocolException>()),
    );
  });

  test('allows only same-server app-visible tool calls', () {
    final protocol = DirectMcpAppsProtocol(
      serverId: 'home',
      tools: const [
        DirectMcpAppToolPolicy(
          serverId: 'home',
          toolName: 'allowed',
          visibleToModel: false,
          visibleToApp: true,
        ),
        DirectMcpAppToolPolicy(
          serverId: 'home',
          toolName: 'model-only',
          visibleToModel: true,
          visibleToApp: false,
        ),
        DirectMcpAppToolPolicy(
          serverId: 'other',
          toolName: 'other-server',
          visibleToModel: false,
          visibleToApp: true,
        ),
        DirectMcpAppToolPolicy(
          serverId: 'other',
          toolName: 'allowed',
          visibleToModel: false,
          visibleToApp: false,
        ),
      ],
    );

    final allowed = protocol.decodeInbound(
      _toolCall(1, 'allowed', arguments: const {'query': 'safe'}),
    ) as DirectMcpAppToolCallRequest;
    expect(allowed.toolName, 'allowed');
    expect(allowed.arguments, {'query': 'safe'});
    protocol.completeRequest(allowed.id);

    for (final payload in [
      _toolCall(2, 'model-only'),
      _toolCall(3, 'other-server'),
      _toolCall(4, 'allowed', serverId: 'other'),
    ]) {
      expect(
        () => protocol.decodeInbound(payload),
        throwsA(isA<DirectMcpAppsProtocolException>()),
      );
    }
  });

  test('rejects unsupported versions, methods, ids, size, and depth', () {
    for (final payload in [
      jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'ui/initialize',
        'params': {
          'protocolVersion': '2099-01-01',
          'appCapabilities': <String, dynamic>{},
        },
      }),
      jsonEncode({'jsonrpc': '2.0', 'id': 2, 'method': 'ui/open-link'}),
      jsonEncode({
        'jsonrpc': '2.0',
        'id': 'x' * (kDirectMcpAppsMaxIdCharacters + 1),
        'method': 'ping',
      }),
      jsonEncode({
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'x' * (kDirectMcpAppsMaxMethodCharacters + 1),
      }),
    ]) {
      expect(
        () => _protocol().decodeInbound(payload),
        throwsA(isA<DirectMcpAppsProtocolException>()),
      );
    }

    expect(
      () => _protocol().decodeInbound(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'ping',
          'params': {'padding': 'x' * kDirectMcpAppsMaxMessageBytes},
        }),
      ),
      throwsA(isA<DirectMcpAppsProtocolException>()),
    );

    Object nested = 'leaf';
    for (var index = 0; index <= kDirectMcpAppsMaxJsonDepth; index++) {
      nested = [nested];
    }
    expect(
      () => _protocol().decodeInbound(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'ping',
          'params': {'nested': nested},
        }),
      ),
      throwsA(isA<DirectMcpAppsProtocolException>()),
    );
  });

  test('rejects duplicate ids and more than sixteen pending requests', () {
    final duplicate = _protocol();
    duplicate.decodeInbound(_ping(1));
    expect(
      () => duplicate.decodeInbound(_ping(1)),
      throwsA(isA<DirectMcpAppsProtocolException>()),
    );
    duplicate.completeRequest(1);
    expect(duplicate.decodeInbound(_ping(1)), isA<DirectMcpAppPingRequest>());

    final pending = _protocol();
    for (var id = 0; id < kDirectMcpAppsMaxPendingRequests; id++) {
      pending.decodeInbound(_ping(id));
    }
    expect(
      () => pending.decodeInbound(_ping(kDirectMcpAppsMaxPendingRequests)),
      throwsA(isA<DirectMcpAppsProtocolException>()),
    );
  });

  test('closing a view session rejects stale bridge traffic', () {
    final protocol = _protocol();
    protocol.decodeInbound(_ping(1));

    protocol.close();

    expect(
      () => protocol.decodeInbound(_ping(2)),
      throwsA(
        isA<DirectMcpAppsProtocolException>().having(
          (error) => error.message,
          'message',
          contains('closed'),
        ),
      ),
    );
    expect(
      () => protocol.toolInputNotification(const {}),
      throwsA(isA<DirectMcpAppsProtocolException>()),
    );
  });

  test('limits each app instance to twenty messages per second plus burst', () {
    var nowMicros = 0;
    final protocol = _protocol(nowMicros: () => nowMicros);
    final capacity =
        kDirectMcpAppsMaxMessagesPerSecond + kDirectMcpAppsRateBurst;
    for (var id = 0; id < capacity; id++) {
      protocol.decodeInbound(_ping(id));
      protocol.completeRequest(id);
    }
    expect(
      () => protocol.decodeInbound(_ping(capacity)),
      throwsA(isA<DirectMcpAppsProtocolException>()),
    );

    nowMicros = -100;
    expect(
      () => protocol.decodeInbound(_ping(capacity + 1)),
      throwsA(isA<DirectMcpAppsProtocolException>()),
    );
    nowMicros = 49900;
    expect(
      protocol.decodeInbound(_ping(capacity + 2)),
      isA<DirectMcpAppPingRequest>(),
    );
  });

  test('normalizes declarative CSP while keeping permissions ungranted', () {
    final policy = directMcpAppResourcePolicy(const {
      'ui': {
        'csp': {
          'connectDomains': ['https://api.example', 'wss://live.example'],
          'resourceDomains': ['https://*.cdn.example'],
        },
        'permissions': {
          'camera': <String, dynamic>{},
          'clipboardWrite': <String, dynamic>{},
        },
        'prefersBorder': true,
      },
    });

    expect(policy.connectDomains, [
      'https://api.example',
      'wss://live.example',
    ]);
    expect(policy.resourceDomains, ['https://*.cdn.example']);
    expect(policy.requestsCamera, isTrue);
    expect(policy.requestsClipboardWrite, isTrue);
    expect(policy.requestsMicrophone, isFalse);
    expect(policy.prefersBorder, isTrue);

    for (final meta in [
      {
        'ui': {1: 'invalid'},
      },
      const {
        'ui': {'domain': 'dedicated.example'},
      },
      const {
        'ui': {
          'csp': {
            'resourceDomains': ['http://insecure.example'],
          },
        },
      },
      const {
        'ui': {
          'csp': {
            'resourceDomains': ['https://sub.*.example'],
          },
        },
      },
      const {
        'ui': {
          'permissions': {
            'camera': {'unexpected': true},
          },
        },
      },
    ]) {
      expect(
        () => directMcpAppResourcePolicy(meta),
        throwsA(isA<DirectMcpAppsProtocolException>()),
      );
    }
  });

  test('bounds outbound tool results before they reach the view', () {
    expect(
      () => _protocol().toolResultNotification({
        'content': [
          {'type': 'text', 'text': 'x' * kDirectMcpAppsMaxMessageBytes},
        ],
      }),
      throwsA(isA<DirectMcpAppsProtocolException>()),
    );
  });
}

DirectMcpAppsProtocol _protocol({int Function()? nowMicros}) =>
    DirectMcpAppsProtocol(
      serverId: 'home',
      tools: const [],
      nowMicros: nowMicros,
    );

mcp.Tool _tool(String name, {List<String>? visibility}) => mcp.Tool.fromJson({
  'name': name,
  'inputSchema': {'type': 'object'},
  '_meta': {
    'ui': {'resourceUri': 'ui://home/$name', 'visibility': ?visibility},
  },
});

String _ping(int id) =>
    jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': 'ping'});

String _toolCall(
  int id,
  String name, {
  Map<String, dynamic>? arguments,
  String? serverId,
}) => jsonEncode({
  'jsonrpc': '2.0',
  'id': id,
  'method': 'tools/call',
  'params': {'name': name, 'arguments': ?arguments, 'serverId': ?serverId},
});
