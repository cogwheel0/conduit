import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/mcp_apps/mcp_app_host.dart';
import 'package:conduit_core/features/mcp_apps/openwebui_mcp_app.dart';
import 'package:test/test.dart';

const _app = OpenWebUiMcpApp(
  serverId: 'maps',
  toolName: 'show_map',
  binding: 'b',
  arguments: {'city': 'Oslo'},
  result: {
    'content': [
      {'type': 'text', 'text': 'A map of Oslo'},
    ],
  },
);

const _resource = OpenWebUiMcpAppResource(
  html: '<p>app</p>',
  csp: "default-src 'none'",
  ui: {
    'csp': {
      'connectDomains': ['https://tiles.example.com'],
    },
  },
  tool: {'name': 'show_map'},
);

/// A host whose sent messages, RPC requests, confirmations and links are
/// recorded; [allow] answers each confirmation.
final class _Rig {
  _Rig({this.allow = true, this.rpcError, this.linkOpens = true}) {
    host = McpAppHost(
      app: _app,
      resource: _resource,
      runRequest: (method, params) async {
        requests.add((method: method, params: params));
        final error = rpcError;
        if (error != null) throw McpAppRpcException(error);
        return {'echo': method};
      },
      confirmToolCall: (name, arguments) async {
        confirmations.add((name: name, arguments: arguments));
        return allow;
      },
      openLink: (url) async {
        links.add(url);
        return linkOpens;
      },
      send: (message) => sent.add(jsonDecode(message) as Map<String, dynamic>),
      hostContext: () => {'theme': 'dark', 'displayMode': 'inline'},
      onSizeChanged: heights.add,
    );
  }

  final bool allow;
  final String? rpcError;
  final bool linkOpens;
  late final McpAppHost host;
  final sent = <Map<String, dynamic>>[];
  final requests = <({String method, Map<String, dynamic> params})>[];
  final confirmations = <({String name, Map<String, dynamic> arguments})>[];
  final links = <Uri>[];
  final heights = <double>[];

  Future<void> request(Object id, String method, [Object? params]) =>
      host.receive(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'method': method,
          'params': ?params,
        }),
      );

  Future<void> notify(String method, [Object? params]) => host.receive(
    jsonEncode({'jsonrpc': '2.0', 'method': method, 'params': ?params}),
  );

  Map<String, dynamic> answerTo(Object id) =>
      sent.lastWhere((message) => message['id'] == id);
}

void main() {
  group('McpAppHost', () {
    test('answers the handshake, then sends the tool input and result', () async {
      final rig = _Rig();

      await rig.request(1, 'ui/initialize', {
        'protocolVersion': kMcpAppsProtocolVersion,
        'appCapabilities': <String, dynamic>{},
      });
      final result = rig.answerTo(1)['result'] as Map<String, dynamic>;
      check(result['protocolVersion']).equals(kMcpAppsProtocolVersion);
      check(result['hostCapabilities'] as Map).containsKey('serverTools');
      check(
        ((result['hostCapabilities'] as Map)['sandbox'] as Map)['csp'] as Map,
      ).deepEquals({
        'connectDomains': ['https://tiles.example.com'],
      });
      check(result['hostContext'] as Map).deepEquals({
        'theme': 'dark',
        'displayMode': 'inline',
        'toolInfo': {
          'tool': {'name': 'show_map'},
        },
      });
      // Nothing is pushed before the app says it is ready.
      check(rig.sent).length.equals(1);

      await rig.notify('ui/notifications/initialized');
      await rig.notify('ui/notifications/initialized');

      check(rig.host.initialized).isTrue();
      check(rig.sent.skip(1).map((m) => m['method']).toList()).deepEquals([
        'ui/notifications/tool-input',
        'ui/notifications/tool-result',
      ]);
      check(rig.sent[1]['params'] as Map).deepEquals({
        'arguments': {'city': 'Oslo'},
      });
      check(rig.sent[2]['params'] as Map).deepEquals(_app.result);
    });

    test('runs a tool call the user allows through the server', () async {
      final rig = _Rig();

      await rig.request('c1', 'tools/call', {
        'name': 'zoom',
        'arguments': {'level': 3},
      });

      check(rig.confirmations.single.name).equals('zoom');
      check(rig.requests.single.method).equals('tools/call');
      check(rig.requests.single.params).deepEquals({
        'name': 'zoom',
        'arguments': {'level': 3},
      });
      check(rig.answerTo('c1')['result'] as Map).deepEquals({
        'echo': 'tools/call',
      });
    });

    test('asks the user one thing at a time', () async {
      final answer = Completer<bool>();
      final sent = <Map<String, dynamic>>[];
      var asked = 0;
      final host = McpAppHost(
        app: _app,
        resource: _resource,
        runRequest: (method, params) async => {'ok': true},
        confirmToolCall: (name, arguments) {
          asked++;
          return answer.future;
        },
        openLink: (_) async => true,
        send: (message) => sent.add(jsonDecode(message) as Map<String, dynamic>),
        hostContext: () => const {},
      );
      Future<void> call(int id) => host.receive(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'method': 'tools/call',
          'params': {'name': 'zoom'},
        }),
      );

      final first = call(1);
      await call(2);
      // The second call is refused while the first is being asked about.
      check(asked).equals(1);
      check((sent.single['error'] as Map)['message']).equals(
        'Tool call cancelled',
      );

      answer.complete(true);
      await first;
      check(sent.last['result'] as Map).deepEquals({'ok': true});
    });

    test('a page that starts over gets its input and result again', () async {
      final rig = _Rig();
      await rig.request(1, 'ui/initialize');
      await rig.notify('ui/notifications/initialized');
      await rig.request(2, 'ui/initialize');
      await rig.notify('ui/notifications/initialized');

      check(
        rig.sent
            .where((m) => m['method'] == 'ui/notifications/tool-result')
            .length,
      ).equals(2);
    });

    test('refuses a tool call the user declines, without asking the server', () async {
      final rig = _Rig(allow: false);

      await rig.request(7, 'tools/call', {'name': 'delete_all'});

      check(rig.requests).isEmpty();
      check(rig.answerTo(7)['error'] as Map).deepEquals({
        'code': -32000,
        'message': 'Tool call cancelled',
      });
    });

    test("passes on the server's refusal", () async {
      final rig = _Rig(rpcError: 'Tool is unavailable to this app');

      await rig.request(2, 'resources/read', {'uri': 'ui://maps/tile'});

      check(rig.answerTo(2)['error'] as Map).deepEquals({
        'code': -32000,
        'message': 'Tool is unavailable to this app',
      });
    });

    test('reads and lists resources', () async {
      final rig = _Rig();

      await rig.request(3, 'resources/read', {'uri': 'ui://maps/tile'});
      await rig.request(4, 'resources/list');
      await rig.request(5, 'resources/list', {'cursor': 'next'});

      check(rig.requests.map((r) => r.params).toList()).deepEquals([
        {'uri': 'ui://maps/tile'},
        <String, dynamic>{},
        {'cursor': 'next'},
      ]);
    });

    test('opens web links only', () async {
      final rig = _Rig();

      await rig.request(1, 'ui/open-link', {'url': 'https://example.com/a'});
      await rig.request(2, 'ui/open-link', {'url': 'javascript:alert(1)'});
      await rig.request(3, 'ui/open-link', {'url': 'https://u:p@example.com'});
      await rig.request(4, 'ui/open-link', {'url': 'ftp://example.com/a'});

      check(rig.links.single).equals(Uri.parse('https://example.com/a'));
      check(rig.answerTo(1)['result'] as Map).isEmpty();
      check((rig.answerTo(2)['error'] as Map)['message']).equals('Invalid URL');
      check((rig.answerTo(3)['error'] as Map)['message']).equals('Invalid URL');
      check((rig.answerTo(4)['error'] as Map)['message']).equals('Invalid URL');
    });

    test('says so when a link was not opened', () async {
      final rig = _Rig(linkOpens: false);

      await rig.request(1, 'ui/open-link', {'url': 'https://example.com/a'});

      check(
        (rig.answerTo(1)['error'] as Map)['message'],
      ).equals('Link opening denied');
    });

    test('keeps the app inline and refuses what it does not offer', () async {
      final rig = _Rig();

      await rig.request(1, 'ui/request-display-mode', {'mode': 'fullscreen'});
      await rig.request(2, 'ui/message', {
        'role': 'user',
        'content': {'type': 'text', 'text': 'hi'},
      });
      await rig.request(3, 'ping');

      check(rig.answerTo(1)['result'] as Map).deepEquals({'mode': 'inline'});
      check((rig.answerTo(2)['error'] as Map)['code']).equals(-32601);
      check(rig.answerTo(3)['result'] as Map).isEmpty();
    });

    test('reports the size the app asks for', () async {
      final rig = _Rig();

      await rig.notify('ui/notifications/size-changed', {
        'width': 320,
        'height': 480,
      });
      await rig.notify('ui/notifications/size-changed', {'height': -1});

      check(rig.heights).deepEquals([480.0]);
    });

    test('drops messages that are not JSON-RPC or are too large', () async {
      final rig = _Rig();

      await rig.host.receive('not json');
      await rig.host.receive(jsonEncode({'id': 1, 'method': 'ping'}));
      await rig.host.receive(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 2,
          'method': 'ping',
          'params': {'pad': 'x' * (kMcpAppMaxMessageBytes + 1)},
        }),
      );

      check(rig.sent).isEmpty();
    });

    test('counts a message in bytes, not characters', () async {
      final rig = _Rig();

      // Half the limit in characters, half as much again over it in bytes.
      await rig.request(1, 'ping', {
        'pad': '漢' * (kMcpAppMaxMessageBytes ~/ 2),
      });

      check(rig.sent).isEmpty();
    });

    test('tells a started app it is going and stops answering at once', () async {
      final rig = _Rig();
      await rig.notify('ui/notifications/initialized');

      rig.host.teardown();

      final request = rig.sent.last;
      check(request['method']).equals('ui/resource-teardown');
      // Its web view goes with its widget, so nothing waits for its answer.
      final count = rig.sent.length;
      await rig.request(9, 'ping');
      await rig.host.receive(
        jsonEncode({'jsonrpc': '2.0', 'id': request['id'], 'result': {}}),
      );
      check(rig.sent).length.equals(count);
    });

    test('an app that never started is closed without a teardown', () async {
      final rig = _Rig();

      rig.host.teardown();
      await rig.request(1, 'ping');

      check(rig.sent).isEmpty();
    });
  });

  group('OpenWebUiMcpApp', () {
    test('is the same app only with the same input and result', () {
      const other = OpenWebUiMcpApp(
        serverId: 'maps',
        toolName: 'show_map',
        binding: 'b',
        arguments: {'city': 'Bergen'},
        result: {'content': <Object>[]},
      );
      check(other == _app).isFalse();
      check(
        const OpenWebUiMcpApp(
              serverId: 'maps',
              toolName: 'show_map',
              binding: 'b',
              arguments: {'city': 'Oslo'},
              result: {
                'content': [
                  {'type': 'text', 'text': 'A map of Oslo'},
                ],
              },
            ) ==
            _app,
      ).isTrue();
    });

    test('reads an mcp_app embed and nothing else', () {
      final apps = OpenWebUiMcpApp.listFrom([
        'https://example.com',
        {
          'type': 'mcp_app',
          'server_id': 'maps',
          'tool_name': 'show_map',
          'binding': 'b' * 64,
          'arguments': {'city': 'Oslo'},
          'result': {'content': <Object>[]},
        },
        {'type': 'mcp_app', 'server_id': 'maps'},
      ]);

      check(apps).length.equals(1);
      check(apps.single.serverId).equals('maps');
      check(apps.single.arguments).deepEquals({'city': 'Oslo'});
    });

    test('a resource without a page is refused', () {
      check(
        () => OpenWebUiMcpAppResource.fromJson({'html': ''}),
      ).throws<McpAppRpcException>();
      final resource = OpenWebUiMcpAppResource.fromJson({
        'html': '<p></p>',
        'csp': "default-src 'none'",
        'additional_csp': "frame-ancestors 'none'",
        'ui': {
          'csp': {
            'resourceDomains': ['https://cdn.example.com'],
          },
        },
      });
      check(
        resource.declaredDomains('resourceDomains'),
      ).deepEquals(['https://cdn.example.com']);
      check(resource.declaredDomains('connectDomains')).isEmpty();
    });

    test('a resource without a security policy is refused', () {
      // Without one the page could load from anywhere: iOS has no request
      // hook for its images, scripts and styles.
      for (final csp in <Object?>[null, '', '  ', 42]) {
        check(
          () => OpenWebUiMcpAppResource.fromJson({
            'html': '<p></p>',
            'csp': ?csp,
          }),
        ).throws<McpAppRpcException>();
      }
    });
  });
}
