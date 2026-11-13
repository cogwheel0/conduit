/// A web page's readable text or a YouTube video's transcript, read through
/// the Open WebUI server, as the composer attaches it (mobile's Web Page
/// dialog, the desktop's `context.fetchUrl`).
library;

import 'package:conduit_core/services/api_service.dart';

/// Whether [url] is a YouTube video, whose transcript is read instead of
/// the page.
bool isYoutubeUrl(String url) =>
    url.startsWith('https://www.youtube.com') ||
    url.startsWith('https://youtu.be') ||
    url.startsWith('https://youtube.com') ||
    url.startsWith('https://m.youtube.com');

/// Whether [url] is something the dialog may fetch: an http or https
/// address.
bool isFetchableUrl(String url) {
  final parsed = Uri.tryParse(url.trim());
  return parsed != null &&
      (parsed.isScheme('http') || parsed.isScheme('https'));
}

/// What the server read from a URL. [content] is empty when it found no
/// readable text (or no transcript): the caller says so instead of
/// attaching nothing.
typedef UrlContext = ({
  bool youtube,
  String url,
  String displayName,
  String content,
  String? collectionName,
});

/// Reads [url] (already trimmed) through the server: its transcript for a
/// YouTube video, its readable text otherwise. Throws what the request
/// throws.
Future<UrlContext> readUrlContext(ApiService api, String url) async {
  final youtube = isYoutubeUrl(url);
  final result = youtube
      ? await api.processYoutube(url: url)
      : await api.processWebpage(url: url);
  final file = (result?['file'] as Map?)?.cast<String, dynamic>();
  final data = (file?['data'] as Map?)?.cast<String, dynamic>();
  final meta = (file?['meta'] as Map?)?.cast<String, dynamic>();
  return (
    youtube: youtube,
    url: url,
    displayName: meta?['name']?.toString() ?? Uri.parse(url).host,
    content: data?['content']?.toString() ?? '',
    collectionName: result?['collection_name']?.toString(),
  );
}
