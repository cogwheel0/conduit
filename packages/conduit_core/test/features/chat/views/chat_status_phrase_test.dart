import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/views/chat_status_display.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:test/test.dart';

void main() {
  test('core names the lines it words itself, and their English is kept', () {
    const cases = <(ChatStatusUpdate, ChatStatusPhrase?, String)>[
      (
        ChatStatusUpdate(action: 'knowledge_search', query: 'seed trays'),
        ChatStatusPhrase.knowledgeSearch,
        'Searching Knowledge for "seed trays"',
      ),
      (
        ChatStatusUpdate(
          action: 'web_search_queries_generated',
          queries: <String>['frost dates'],
          description: 'Generating queries',
        ),
        ChatStatusPhrase.searching,
        'Searching',
      ),
      (
        ChatStatusUpdate(
          action: 'queries_generated',
          queries: <String>['compost'],
        ),
        ChatStatusPhrase.querying,
        'Querying',
      ),
      (
        ChatStatusUpdate(action: 'sources_retrieved', count: 0),
        ChatStatusPhrase.sourcesRetrieved,
        'No sources found',
      ),
      (
        ChatStatusUpdate(action: 'sources_retrieved', count: 1),
        ChatStatusPhrase.sourcesRetrieved,
        'Retrieved 1 source',
      ),
      (
        ChatStatusUpdate(action: 'sources_retrieved', count: 4),
        ChatStatusPhrase.sourcesRetrieved,
        'Retrieved 4 sources',
      ),
      (ChatStatusUpdate(), ChatStatusPhrase.processing, 'Processing'),
      // Open WebUI's own words, and an action's name: not core's.
      (
        ChatStatusUpdate(
          action: 'web_search',
          description: 'Searched {{count}} sites',
          urls: <String>['https://a.example', 'https://b.example'],
        ),
        null,
        'Searched 2 sites',
      ),
      (ChatStatusUpdate(action: 'web_search'), null, 'Web search'),
      (ChatStatusUpdate(action: 'knowledge_search'), null, 'Knowledge search'),
    ];
    for (final (update, phrase, english) in cases) {
      check(because: '$update', resolveStatusPhrase(update)).equals(phrase);
      check(
        because: '$update',
        resolveStatusDescription(update),
      ).equals(english);
    }
  });
}
