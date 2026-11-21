import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/features/terminal/models/terminal_models.dart';
import 'package:conduit_core/features/terminal/services/terminal_service.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:test/test.dart';

void main() {
  test("the server's terminal opens outside a chat and inside one", () async {
    // As Open WebUI 0.13.4's terminal proxy does: an id without a
    // `local:`, `temporary:` or `channel:` prefix names a saved chat, and
    // one it cannot find is refused.
    const unsaved = ['local:', 'temporary:', 'channel:'];
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => http.close(force: true));
    final sent = <String?>[];
    http.listen((request) async {
      final id = request.headers.value('X-Session-Id');
      sent.add(id);
      final refused =
          id != null && id != 'saved-chat' && !unsaved.any(id.startsWith);
      request.response
        ..statusCode = refused ? HttpStatus.forbidden : HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode(
            refused ? {'detail': 'Chat access denied'} : {'id': 'session-1'},
          ),
        );
      await request.response.close();
    });
    final service = TerminalService(
      ApiService(
        serverConfig: ServerConfig(
          id: 'owui',
          name: 'Synthetic',
          url: 'http://127.0.0.1:${http.port}',
        ),
        authToken: 'synthetic-token',
        workerManager: WorkerManager(),
      ),
    );
    final box = TerminalServerInfo(
      kind: TerminalServerKind.system,
      selectionId: 'box',
      systemServerId: 'box',
      baseUrl: Uri.parse('http://127.0.0.1:${http.port}/api/v1/terminals/box'),
    );

    final page = await service.createSession(
      box,
      sessionScopeId: 'sidebar-terminal',
    );
    final chat = await service.createSession(box, sessionScopeId: 'saved-chat');

    expect(page.sessionId, 'session-1');
    expect(chat.sessionId, 'session-1');
    expect(sent.last, 'saved-chat');
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
    // Open WebUI 0.13.4 lists a terminal template with the scope its
    // machines are made for, and no `contexts`.
    expect(parseTerminalChatContextForTest(null, scope: 'chat'), (
      available: true,
      requiresSavedChat: true,
    ));
    expect(parseTerminalChatContextForTest(null, scope: 'user'), (
      available: true,
      requiresSavedChat: false,
    ));

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
}
