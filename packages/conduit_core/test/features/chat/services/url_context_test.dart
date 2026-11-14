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
    expect(isYoutubeUrl('https://youtu.be/abc'), isTrue);
    expect(isYoutubeUrl('https://m.youtube.com/watch?v=abc'), isTrue);
    expect(isYoutubeUrl('https://example.test/youtube.com'), isFalse);
    expect(isFetchableUrl(' https://example.test/a '), isTrue);
    expect(isFetchableUrl('ftp://example.test/a'), isFalse);
    expect(isFetchableUrl('not a url'), isFalse);

    final api = _RetrievalApi({
      'collection_name': 'web-1',
      'file': {
        'data': {'content': 'Raised beds drain faster.'},
        'meta': {'name': 'Garden guide'},
      },
    });
    final page = await readUrlContext(api, 'https://example.test/beds');
    expect(api.calls, ['web https://example.test/beds']);
    expect(page.youtube, isFalse);
    expect(page.displayName, 'Garden guide');
    expect(page.content, 'Raised beds drain faster.');
    expect(page.collectionName, 'web-1');

    final video = await readUrlContext(api, 'https://youtu.be/abc');
    expect(api.calls.last, 'youtube https://youtu.be/abc');
    expect(video.youtube, isTrue);
  });

  test(
    'a page with nothing readable comes back empty, named by its host',
    () async {
      final page = await readUrlContext(
        _RetrievalApi(null),
        'https://example.test/empty',
      );
      expect(page.content, isEmpty);
      expect(page.displayName, 'example.test');
    },
  );
}
