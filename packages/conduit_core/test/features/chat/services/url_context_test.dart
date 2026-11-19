import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/services/url_context.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:test/test.dart';

/// Answers the two retrieval routes the way Open WebUI 0.13 does with
/// retrieval bypassed: the text under `file.data.content`.
class _RetrievalApi extends ApiService {
  _RetrievalApi(this.answer)
    : super(
        serverConfig: const ServerConfig(
          id: 'server-a',
          name: 'Server A',
          url: 'https://server-a.example.test',
        ),
        workerManager: WorkerManager(),
        authToken: 'session-a',
      );

  final Map<String, dynamic>? answer;
  final calls = <String>[];

  @override
  Future<Map<String, dynamic>?> processWebpage({
    required String url,
    String? collectionName,
  }) async {
    calls.add('web $url');
    return answer;
  }

  @override
  Future<Map<String, dynamic>?> processYoutube({
    required String url,
    String? collectionName,
  }) async {
    calls.add('youtube $url');
    return answer;
  }
}

void main() {
  test('a YouTube address is read for its transcript, any other page for '
      'its text', () async {
    check(isYoutubeUrl('https://youtu.be/abc')).isTrue();
    check(isYoutubeUrl('https://m.youtube.com/watch?v=abc')).isTrue();
    check(isYoutubeUrl('https://example.test/youtube.com')).isFalse();
    // The host decides, not how the address starts.
    check(isYoutubeUrl('https://youtube.com.example.test/watch')).isFalse();
    check(isYoutubeUrl('https://youtu.be.example.test/abc')).isFalse();
    check(isYoutubeUrl('https://www.youtube.community/watch')).isFalse();
    check(isYoutubeUrl('https://youtube.com/watch?v=abc')).isTrue();
    check(isYoutubeUrl('https://WWW.YouTube.com/watch?v=abc')).isTrue();
    check(isFetchableUrl(' https://example.test/a ')).isTrue();
    check(isFetchableUrl('ftp://example.test/a')).isFalse();
    check(isFetchableUrl('not a url')).isFalse();

    final api = _RetrievalApi({
      'collection_name': 'web-1',
      'file': {
        'data': {'content': 'Raised beds drain faster.'},
        'meta': {'name': 'Garden guide'},
      },
    });
    final page = await readUrlContext(api, 'https://example.test/beds');
    check(api.calls).deepEquals(['web https://example.test/beds']);
    check(page.youtube).isFalse();
    check(page.displayName).equals('Garden guide');
    check(page.content).equals('Raised beds drain faster.');
    check(page.collectionName).equals('web-1');

    final video = await readUrlContext(api, 'https://youtu.be/abc');
    check(api.calls.last).equals('youtube https://youtu.be/abc');
    check(video.youtube).isTrue();
  });

  test(
    'a page with nothing readable comes back empty, named by its host',
    () async {
      final page = await readUrlContext(
        _RetrievalApi(null),
        'https://example.test/empty',
      );
      check(page.content).isEmpty();
      check(page.displayName).equals('example.test');
    },
  );
}
