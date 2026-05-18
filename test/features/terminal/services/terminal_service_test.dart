import 'package:conduit/features/terminal/models/terminal_models.dart';
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
      final updated = applyDirectTerminalSelectionForTest(<String, dynamic>{
        'terminalServers': <Map<String, dynamic>>[
          <String, dynamic>{'name': 'Primary', 'url': 'https://a.example'},
          <String, dynamic>{
            'name': 'Secondary',
            'url': 'https://b.example',
            'enabled': true,
          },
        ],
      }, 'https://a.example');

      final servers = (updated['terminalServers']! as List<dynamic>)
          .cast<Map<String, dynamic>>();
      expect(servers[0]['enabled'], isTrue);
      expect(servers[1]['enabled'], isFalse);
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
  });
}
