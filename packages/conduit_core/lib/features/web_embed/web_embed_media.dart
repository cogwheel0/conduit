/// Audio and video a tool's HTML names on the user's own server.
///
/// The embed's page has its own made-up origin and never holds the account's
/// credentials, so a server path in it resolves nowhere and a server address
/// is fetched signed out. Conduit fetches such media itself, with the
/// account's credentials, and hands the page the bytes as a `data:` URL: the
/// page gets the media it names and nothing else, never a token or a cookie.
/// Only audio and video on the server's own origin are fetched; every other
/// address is left for the page to load as it always has.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../models/server_config.dart';
import '../../network/server_origin.dart';
import '../../services/server_tls_http_client_factory.dart';
import 'web_embed_document.dart' show escapeHtmlAttribute;

/// The most media one embed inlines, in bytes; past it, the page is pointed
/// at the server instead.
const int kWebEmbedMediaMaxBytes = 16 * 1024 * 1024;

final RegExp _mediaTag = RegExp(
  r'<(?:audio|video|source)\b[^>]*>',
  caseSensitive: false,
);

final RegExp _srcAttribute = RegExp(
  r'''(?<=\s)src\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))''',
  caseSensitive: false,
);

final RegExp _mediaType = RegExp(r'^(?:audio|video)/[a-z0-9][a-z0-9.+-]*$');

/// The client [inlineWebEmbedServerMedia] fetches with: [headers], the
/// account's credentials, sent to [server] with its TLS settings, following
/// no redirect. It is kept apart from the account's API client, whose
/// interceptors read a refusal, a sign-in page or a gateway error as the
/// session or the route failing; an address a page names says neither.
Dio webEmbedMediaClient(ServerConfig server, Map<String, String> headers) {
  final dio = Dio(BaseOptions(headers: headers, followRedirects: false));
  ServerTlsHttpClientFactory.configureDio(dio, server);
  return dio;
}

/// Where an embed's media [src] is on the server at [serverBase], as an
/// absolute URL; null when it names anywhere else, carries a user name, or
/// is not an http(s) address or a path.
Uri? webEmbedServerMediaUrl(String src, Uri serverBase) {
  final raw = src.trim();
  if (raw.isEmpty || !imageUrlIsServerOrigin(serverBase.toString(), raw)) {
    return null;
  }
  final Uri resolved;
  try {
    resolved = serverBase.resolve(raw);
  } on FormatException {
    return null;
  }
  return resolved.userInfo.isEmpty ? resolved : null;
}

/// [html] with the `src` of each audio, video and source element passed
/// through [rewrite], decoded: a non-null result replaces it.
String rewriteWebEmbedMediaSources(
  String html,
  String? Function(String src) rewrite,
) {
  return html.replaceAllMapped(_mediaTag, (tag) {
    return tag[0]!.replaceFirstMapped(_srcAttribute, (attribute) {
      final value = attribute[1] ?? attribute[2] ?? attribute[3] ?? '';
      final replacement = rewrite(_decodeAttribute(value));
      return replacement == null
          ? attribute[0]!
          : 'src="${escapeHtmlAttribute(replacement)}"';
    });
  });
}

/// [html] with the media it names on the server at [serverBase] fetched
/// with [dio] ([webEmbedMediaClient]): audio and video the server sends are
/// inlined as `data:` URLs, up to [maxBytes] in all. Media the server does
/// not send as audio or video, or past the limit, is pointed at its
/// absolute address on the server. Other addresses are left as they are.
Future<String> inlineWebEmbedServerMedia(
  String html, {
  required Uri serverBase,
  required Dio dio,
  int maxBytes = kWebEmbedMediaMaxBytes,
}) async {
  final addresses = <Uri>{};
  rewriteWebEmbedMediaSources(html, (src) {
    final url = webEmbedServerMediaUrl(src, serverBase);
    if (url != null) addresses.add(url);
    return null;
  });
  if (addresses.isEmpty) return html;

  final inlined = <Uri, String>{};
  var budget = maxBytes;
  for (final url in addresses) {
    final media = await _fetchMedia(dio, url, budget);
    if (media == null) continue;
    budget -= media.length;
    inlined[url] = media.dataUrl;
  }

  return rewriteWebEmbedMediaSources(html, (src) {
    final url = webEmbedServerMediaUrl(src, serverBase);
    if (url == null) return null;
    return inlined[url] ?? url.toString();
  });
}

Future<({int length, String dataUrl})?> _fetchMedia(
  Dio dio,
  Uri url,
  int maxBytes,
) async {
  if (maxBytes <= 0) return null;
  final cancel = CancelToken();
  try {
    final response = await dio.getUri<ResponseBody>(
      url,
      cancelToken: cancel,
      options: Options(
        responseType: ResponseType.stream,
        headers: const {'Accept': 'audio/*, video/*'},
      ),
    );
    final mediaType = _mediaTypeOf(response.headers.value('content-type'));
    final body = response.data;
    final declared = int.tryParse(
      response.headers.value(Headers.contentLengthHeader) ?? '',
    );
    if (mediaType == null ||
        body == null ||
        (declared != null && declared > maxBytes)) {
      cancel.cancel();
      return null;
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in body.stream) {
      bytes.add(chunk);
      if (bytes.length > maxBytes) {
        cancel.cancel();
        return null;
      }
    }
    if (bytes.isEmpty) return null;
    return (
      length: bytes.length,
      dataUrl: 'data:$mediaType;base64,${base64Encode(bytes.takeBytes())}',
    );
  } on DioException {
    return null;
  }
}

String? _mediaTypeOf(String? contentType) {
  final type = contentType?.split(';').first.trim().toLowerCase();
  return type != null && _mediaType.hasMatch(type) ? type : null;
}

String _decodeAttribute(String value) => value
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&');
