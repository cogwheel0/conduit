import 'package:conduit_markdown/conduit_markdown.dart';
import 'package:test/test.dart';

void main() {
  const app = {
    'type': 'mcp_app',
    'server_id': 'maps',
    'tool_name': 'show_map',
    'binding': 'b',
    'arguments': {'city': 'Oslo'},
    'result': {'content': <Object>[]},
  };

  group('MCP App embeds (Open WebUI 0.13)', () {
    test('are kept as they are, beside sourced embeds', () {
      final embeds = normalizeEmbedList([
        'https://example.com/widget',
        app,
        {'type': 'mcp_app'},
        {'unrelated': true},
      ]);

      expect(embeds, hasLength(3));
      expect(embeds[0], {'src': 'https://example.com/widget'});
      expect(embeds[1], app);
      expect(isMcpAppEmbed(embeds[1]), isTrue);
      expect(isMcpAppEmbed(embeds[0]), isFalse);
    });

    test('are written back whole, so the app can still run', () {
      expect(
        sanitizeEmbedsForWebUi([
          {'src': 'https://example.com/widget'},
          app,
        ]),
        ['https://example.com/widget', app],
      );
    });
  });
}
