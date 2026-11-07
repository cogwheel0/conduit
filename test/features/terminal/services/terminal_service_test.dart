import 'dart:convert';
import 'dart:io';

import 'package:conduit/features/terminal/models/terminal_models.dart';
import 'package:conduit/features/terminal/services/terminal_service.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('terminal service helpers', () {
    test('builds proxy URLs without dropping a base path', () {
      expect(
        buildSystemTerminalProxyBaseUrlForTest(
          'https://example.com/openwebui/',
          'system-terminal',
        ),
        'https://example.com/openwebui/api/v1/terminals/system-terminal',
      );
    });

    test('rewrites HTTP schemes for websocket transport', () {
      expect(
        toWebSocketBaseUrlForTest('https://example.com/openwebui'),
        'wss://example.com/openwebui',
      );
      expect(
        toWebSocketBaseUrlForTest('http://localhost:8080'),
        'ws://localhost:8080',
      );
    });

    test('toggles direct terminal selection inside user settings', () {
      final original = <String, dynamic>{
        'terminalServers': <Map<String, dynamic>>[
          <String, dynamic>{'name': 'Primary', 'url': 'https://a.example'},
          <String, dynamic>{
            'name': 'Secondary',
            'url': 'https://b.example',
            'enabled': true,
          },
        ],
      };
      final updated = applyDirectTerminalSelectionForTest(
        original,
        'https://a.example',
      );

      final servers = (updated['terminalServers']! as List<dynamic>)
          .cast<Map<String, dynamic>>();
      expect(servers[0]['enabled'], isTrue);
      expect(servers[1]['enabled'], isFalse);

      final originalServers = (original['terminalServers']! as List<dynamic>)
          .cast<Map<String, dynamic>>();
      expect(originalServers[0].containsKey('enabled'), isFalse);
      expect(originalServers[1]['enabled'], isTrue);
    });

    test('direct terminals come from the ui list when it is present', () {
      final service = TerminalService(
        ApiService(
          serverConfig: const ServerConfig(
            id: 'terminal-precedence',
            name: 'Terminal precedence',
            url: 'https://example.test',
          ),
          workerManager: WorkerManager(),
        ),
      );
      Map<String, dynamic> terminal(String url) => <String, dynamic>{
        'url': url,
        'enabled': true,
      };

      List<String> urls(Map<String, dynamic> settings) => service
          .parseDirectTerminalServers(settings)
          .map((server) => server.selectionId)
          .toList();

      // A newer ui list wins over the root list an older client left behind.
      expect(
        urls(<String, dynamic>{
          'terminalServers': [terminal('https://stale.example')],
          'ui': {
            'terminalServers': [terminal('https://fresh.example')],
          },
        }),
        ['https://fresh.example'],
      );
      // An explicitly empty ui list means no terminals, not the stale ones.
      expect(
        urls(<String, dynamic>{
          'terminalServers': [terminal('https://stale.example')],
          'ui': {'terminalServers': <Object>[]},
        }),
        isEmpty,
      );
      // Without a ui list the root list is still honoured.
      expect(
        urls(<String, dynamic>{
          'terminalServers': [terminal('https://legacy.example')],
        }),
        ['https://legacy.example'],
      );
    });

    test('selecting a terminal edits the list consumers read', () {
      final updated = applyDirectTerminalSelectionForTest(<String, dynamic>{
        'terminalServers': [
          {'url': 'https://stale.example', 'enabled': true},
        ],
        'ui': {
          'terminalServers': [
            {'url': 'https://a.example'},
            {'url': 'https://b.example'},
          ],
        },
      }, 'https://b.example');

      final ui = (updated['ui']! as Map)['terminalServers']! as List;
      expect(ui.map((s) => (s as Map)['enabled']), [false, true]);
      // The stale root list is left exactly as it was.
      expect((updated['terminalServers']! as List).single, {
        'url': 'https://stale.example',
        'enabled': true,
      });
    });

    test('resolves explicit and enabled direct selections', () {
      final servers = <TerminalServerInfo>[
        TerminalServerInfo(
          kind: TerminalServerKind.direct,
          selectionId: 'https://direct.example',
          baseUrl: Uri.parse('https://direct.example'),
          selectedEnabled: true,
        ),
        TerminalServerInfo(
          kind: TerminalServerKind.system,
          selectionId: 'system-1',
          systemServerId: 'system-1',
          baseUrl: Uri.parse('https://example.com/api/v1/terminals/system-1'),
        ),
      ];

      expect(
        resolveSelectedTerminalServerForTest(servers, 'system-1')?.selectionId,
        'system-1',
      );
      expect(
        resolveSelectedTerminalServerForTest(servers, null)?.selectionId,
        'https://direct.example',
      );
    });

    test('normalizes and navigates terminal paths', () {
      expect(
        normalizeTerminalPath(r'C:\Users\ava\workspace'),
        'C:/Users/ava/workspace',
      );
      expect(ensureTerminalDirectoryPath('/tmp/data'), '/tmp/data/');
      expect(joinTerminalPath('/tmp/data', 'notes.md'), '/tmp/data/notes.md');
      expect(parentTerminalPath('/tmp/data/project/'), '/tmp/data/');
    });

    test('parses chat context availability and saved-chat scoping', () {
      expect(parseTerminalChatContextForTest(null), (
        available: true,
        requiresSavedChat: false,
      ));
      expect(parseTerminalChatContextForTest(const {'chat': false}), (
        available: false,
        requiresSavedChat: false,
      ));
      expect(
        parseTerminalChatContextForTest(const {
          'chat': {'context_id': 'chat_id'},
        }),
        (available: true, requiresSavedChat: true),
      );

      final scoped = TerminalServerInfo(
        kind: TerminalServerKind.system,
        selectionId: 'scoped',
        baseUrl: Uri.parse('https://example.test'),
        requiresSavedChatContext: true,
      );
      expect(scoped.isAvailableForChatScope('sidebar-terminal'), isFalse);
      expect(scoped.isAvailableForChatScope('local:draft'), isFalse);
      expect(scoped.isAvailableForChatScope('temporary:socket'), isFalse);
      expect(scoped.isAvailableForChatScope('channel:team'), isFalse);
      expect(scoped.isAvailableForChatScope('saved-chat'), isTrue);
    });

    test('system websocket auth carries only a saved chat id', () {
      final system = TerminalServerInfo(
        kind: TerminalServerKind.system,
        selectionId: 'system',
        baseUrl: Uri.parse('https://example.test'),
      );
      final direct = TerminalServerInfo(
        kind: TerminalServerKind.direct,
        selectionId: 'direct',
        baseUrl: Uri.parse('https://terminal.example.test'),
      );

      expect(
        buildTerminalWebSocketAuthPayload(
          system,
          token: 'token',
          sessionScopeId: 'saved-chat',
        ),
        {'type': 'auth', 'token': 'token', 'chat_id': 'saved-chat'},
      );
      expect(
        buildTerminalWebSocketAuthPayload(
          direct,
          token: 'key',
          sessionScopeId: 'saved-chat',
        ),
        {'type': 'auth', 'token': 'key'},
      );
      for (final unsavedId in [
        'sidebar-terminal',
        'local:draft',
        'temporary:socket',
        'channel:team',
      ]) {
        expect(
          buildTerminalWebSocketAuthPayload(
            system,
            token: 'token',
            sessionScopeId: unsavedId,
          ),
          {'type': 'auth', 'token': 'token'},
        );
      }
    });

    test('events sockets live next to the terminal API', () {
      final service = TerminalService(
        ApiService(
          serverConfig: const ServerConfig(
            id: 'events',
            name: 'Events',
            url: 'https://example.com/openwebui/',
          ),
          workerManager: WorkerManager(),
        ),
      );

      expect(
        service.buildEventsWebSocketUri(
          TerminalServerInfo(
            kind: TerminalServerKind.system,
            selectionId: 'term-1',
            systemServerId: 'term-1',
            baseUrl: Uri.parse(
              'https://example.com/openwebui/api/v1/terminals/term-1',
            ),
          ),
        ),
        Uri.parse('wss://example.com/openwebui/api/v1/terminals/term-1/events'),
      );
      expect(
        service.buildEventsWebSocketUri(
          TerminalServerInfo(
            kind: TerminalServerKind.direct,
            selectionId: 'http://10.0.0.5:8000/',
            baseUrl: Uri.parse('http://10.0.0.5:8000/'),
          ),
        ),
        Uri.parse('ws://10.0.0.5:8000/events'),
      );
    });

    test('subscriptions and events follow the terminal protocol', () {
      expect(buildTerminalEventsSubscribePayload(path: '/w/', ports: true), {
        'type': 'subscribe',
        'path': '/w/',
        'ports': true,
      });
      expect(buildTerminalEventsSubscribePayload(ports: true), {
        'type': 'subscribe',
        'ports': true,
      });

      expect(
        parseTerminalEvent('{"type":"fs:ready"}'),
        isA<TerminalFilesChanged>(),
      );
      expect(
        parseTerminalEvent(utf8.encode('{"type":"fs:change"}')),
        isA<TerminalFilesChanged>(),
      );
      final ports = parseTerminalEvent(
        '{"type":"ports:change","ports":[{"port":"3000","pid":7},'
        '{"port":-1},{"process":"none"}]}',
      );
      expect(ports, isA<TerminalPortsChanged>());
      final parsed = (ports! as TerminalPortsChanged).ports;
      expect(parsed.map((port) => port.port), [3000]);
      expect(parsed.single.pid, 7);
      expect(
        (parseTerminalEvent('{"type":"ports:change"}')! as TerminalPortsChanged)
            .ports,
        isEmpty,
      );
      for (final frame in <Object?>[
        '{"type":"chat"}',
        'output',
        '[1,2]',
        42,
        null,
      ]) {
        expect(parseTerminalEvent(frame), isNull, reason: '$frame');
      }
    });

    test('features count only what the terminal turns on', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final replies = <Object?>[
        {
          'features': {'terminal': false, 'events': true, 'browser': true},
        },
        // An older terminal: no events or browser flags at all.
        {
          'features': {'terminal': true, 'notebooks': true},
        },
        {
          'features': {'events': 'true', 'browser': 1},
        },
        'not a config',
      ];
      final requests = <HttpRequest>[];
      server.listen((request) async {
        requests.add(request);
        final reply = replies.removeAt(0);
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(reply));
        await request.response.close();
      });
      final terminal = TerminalServerInfo(
        kind: TerminalServerKind.direct,
        selectionId: 'local',
        baseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
        apiKey: 'secret',
      );
      final service = TerminalService(
        ApiService(
          serverConfig: const ServerConfig(
            id: 'features',
            name: 'Features',
            url: 'https://example.test',
          ),
          workerManager: WorkerManager(),
        ),
      );

      final current = await service.getFeatures(terminal, sessionScopeId: 's');
      expect(current.terminal, isFalse);
      expect(current.events, isTrue);
      expect(current.browser, isTrue);
      expect(requests.single.uri.path, '/api/config');
      expect(
        requests.single.headers.value('authorization'),
        'Bearer secret',
      );

      final older = await service.getFeatures(terminal);
      expect(older.terminal, isTrue);
      expect(older.events, isFalse);
      expect(older.browser, isFalse);

      final loose = await service.getFeatures(terminal);
      expect(loose.events, isFalse);
      expect(loose.browser, isFalse);

      final unreadable = await service.getFeatures(terminal);
      expect(unreadable.terminal, isTrue);
      expect(unreadable.events, isFalse);
    });

    test('opens and closes browser sessions for one chat', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final requests = <({String method, String path, String? scope,
          String? auth, Object? body})>[];
      final replies = <Object?>[
        {
          'id': 'abc',
          'token': 'cap-token',
          'url': 'http://localhost:5173/',
          'title': '',
          'mode': 'proxy',
          'chrome_available': false,
        },
        {'status': 'closed'},
        // An older terminal routes the path nowhere useful.
        {'detail': 'Not Found'},
      ];
      server.listen((request) async {
        final body = await utf8.decoder.bind(request).join();
        requests.add((
          method: request.method,
          path: request.uri.path,
          scope: request.headers.value('x-session-id'),
          auth: request.headers.value('authorization'),
          body: body.isEmpty ? null : jsonDecode(body),
        ));
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(replies.removeAt(0)));
        await request.response.close();
      });
      final terminal = TerminalServerInfo(
        kind: TerminalServerKind.direct,
        selectionId: 'local',
        baseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
        apiKey: 'secret',
      );
      final service = TerminalService(
        ApiService(
          serverConfig: const ServerConfig(
            id: 'sessions',
            name: 'Sessions',
            url: 'https://example.test',
          ),
          workerManager: WorkerManager(),
        ),
      );

      final session = await service.createBrowserSession(
        terminal,
        url: 'http://localhost:5173/',
        sessionScopeId: 'chat-1',
      );
      expect(session.id, 'abc');
      expect(session.token, 'cap-token');
      expect(session.mode, 'proxy');
      await service.closeBrowserSession(
        terminal,
        session.id,
        sessionScopeId: 'chat-1',
      );

      expect(requests[0].method, 'POST');
      expect(requests[0].path, '/browser/sessions');
      expect(requests[0].body, {'url': 'http://localhost:5173/'});
      expect(requests[1].method, 'DELETE');
      expect(requests[1].path, '/browser/sessions/abc');
      // The terminal only closes a session for the chat that opened it.
      expect(requests.map((r) => r.scope), ['chat-1', 'chat-1']);
      expect(requests.map((r) => r.auth), ['Bearer secret', 'Bearer secret']);

      await expectLater(
        service.createBrowserSession(
          terminal,
          url: 'http://localhost:5173/',
          sessionScopeId: 'chat-1',
        ),
        throwsA(isA<Exception>()),
      );
    });
  });
}
