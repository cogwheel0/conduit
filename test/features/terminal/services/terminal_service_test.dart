import 'package:conduit/features/terminal/models/terminal_models.dart';
import 'package:conduit/features/terminal/controllers/terminal_session_controller.dart';
import 'package:conduit/features/terminal/services/terminal_service.dart';
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
  });
}
