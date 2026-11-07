import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/features/terminal/models/computer_models.dart';
import 'package:conduit_core/features/terminal/models/terminal_models.dart';
import 'package:conduit_core/features/terminal/services/computer_service.dart';
import 'package:conduit_core/features/terminal/services/terminal_service.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  test('only explicit boolean capability flags enable Computer', () {
    for (final value in [
      null,
      {},
      {
        'features': {'terminal': true},
      },
      {
        'features': {'browser': 'true', 'desktop': 1},
      },
    ]) {
      expect(ComputerCapabilities.fromJson(value).available, isFalse);
    }
    expect(
      ComputerCapabilities.fromJson({
        'features': {'browser': true},
      }).preferred,
      ComputerSurface.browser,
    );
  });

  late HttpServer http;
  late ComputerService service;
  final requests =
      <
        ({
          String path,
          String method,
          String? scope,
          String? auth,
          Object? data,
        })
      >[];
  late Future<void> Function(HttpRequest) respond;

  setUp(() async {
    requests.clear();
    http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final url = 'http://127.0.0.1:${http.port}/nested';
    final api = ApiService(
      serverConfig: ServerConfig(id: 'fixture', name: 'Fixture', url: url),
      authToken: 'synthetic-webui-token',
      workerManager: WorkerManager(),
    );
    service = ComputerService(
      TerminalService(api),
      TerminalServerInfo(
        kind: TerminalServerKind.direct,
        selectionId: 'fixture',
        baseUrl: Uri.parse(url),
        apiKey: 'synthetic-terminal-key',
      ),
      'chat-fixture',
    );
    respond = (request) async {
      request.response.write('{}');
    };
    http.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      requests.add((
        path: request.uri.path,
        method: request.method,
        scope: request.headers.value('X-Session-Id'),
        auth: request.headers.value('Authorization'),
        data: body.isEmpty ? null : jsonDecode(body),
      ));
      request.response.headers.contentType = ContentType.json;
      await respond(request);
      await request.response.close();
    });
  });
  tearDown(() => http.close(force: true));

  test(
    'desktop uses scoped HTTP and first-message auth, preserving base path',
    () async {
      respond = (request) async {
        request.response.write('{"transport":"frames"}');
      };
      final connection = await service.open(ComputerSurface.desktop);
      expect(requests.single.path, '/nested/desktop');
      expect(requests.single.scope, 'chat-fixture');
      expect(requests.single.auth, 'Bearer synthetic-terminal-key');
      expect(connection.streamUri.path, '/nested/desktop/stream');
      expect(connection.streamUri.scheme, 'ws');
      expect(connection.streamUri.query, isEmpty);
      expect(connection.token, 'synthetic-terminal-key');
      expect(connection.chatId, 'chat-fixture');
    },
  );

  test(
    'legacy terminals are hidden; authentication failures are not capabilities',
    () async {
      respond = (request) async {
        request.response.statusCode = 404;
      };
      expect((await service.capabilities()).available, isFalse);
      respond = (request) async {
        request.response.statusCode = 401;
      };
      await expectLater(service.capabilities(), throwsA(isA<DioException>()));
      expect(
        requests.every((request) => request.path == '/nested/api/config'),
        isTrue,
      );
    },
  );

  test('system desktop uses the authenticated Open WebUI proxy', () async {
    final proxy = ComputerService(
      service.terminal,
      TerminalServerInfo(
        kind: TerminalServerKind.system,
        selectionId: 'terminal-fixture',
        systemServerId: 'terminal-fixture',
        baseUrl: Uri.parse(
          'http://127.0.0.1:${http.port}/nested/api/v1/terminals/terminal-fixture',
        ),
      ),
      'chat-fixture',
    );
    respond = (request) async {
      request.response.write('{"transport":"frames"}');
    };
    final connection = await proxy.open(ComputerSurface.desktop);
    expect(
      requests.single.path,
      '/nested/api/v1/terminals/terminal-fixture/desktop',
    );
    expect(requests.single.auth, 'Bearer synthetic-webui-token');
    expect(requests.single.scope, 'chat-fixture');
    expect(connection.token, 'synthetic-webui-token');
    expect(connection.streamUri.query, isEmpty);
    expect(
      connection.streamUri.path,
      '/nested/api/v1/terminals/terminal-fixture/desktop/stream',
    );
  });

  test(
    'reattaches the selected browser without spawning or closing a tab',
    () async {
      respond = (request) async {
        request.response.write(
          request.uri.path.endsWith('/tabs')
              ? '{"current_session_id":"agent-tab"}'
              : '{"id":"agent-tab","token":"scoped-capability","chrome_available":true,"mode":"chrome"}',
        );
      };
      final connection = await service.open(ComputerSurface.browser);
      expect(
        connection.streamUri.path,
        '/nested/browser/view/agent-tab/scoped-capability/stream',
      );
      expect(connection.token, isNull);
      expect(requests.map((request) => request.method), [
        'GET',
        'GET',
        'PATCH',
      ]);
      expect(requests.last.data, {'mode': 'chrome', 'active': true});
      await service.keepAlive(connection);
      expect(requests.last.data, isEmpty);
      expect(
        requests.every((request) => request.scope == 'chat-fixture'),
        isTrue,
      );
    },
  );

  test(
    'new browser belongs to current chat and rejects unsupported Chrome mode',
    () async {
      respond = (request) async {
        request.response.write(
          request.uri.path.endsWith('/tabs') ? '{"tabs":[]}' : '{"id":"new-tab","token":"scoped-capability","chrome_available":false}',
        );
      };
      await expectLater(
        service.open(ComputerSurface.browser),
        throwsA(isA<ComputerBrowserUnavailable>()),
      );
      expect(requests[1].method, 'POST');
      expect(requests[1].scope, 'chat-fixture');
      expect(requests.any((request) => request.method == 'PATCH'), isFalse);
    },
  );

  test('draft identifiers are never sent as saved chat scopes', () async {
    final draft = ComputerService(
      service.terminal,
      service.server,
      'local:unsaved',
    );
    respond = (request) async {
      request.response.write('{"transport":"vnc"}');
    };
    final connection = await draft.open(ComputerSurface.desktop);
    expect(connection.chatId, isEmpty);
    expect(requests.single.scope, isNull);
  });

  test('unrecognized transports fail before opening a socket', () async {
    respond = (request) async {
      request.response.write('{"transport":"unknown"}');
    };
    await expectLater(
      service.open(ComputerSurface.desktop),
      throwsFormatException,
    );
  });
}
