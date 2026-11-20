/// Audio and video a web embed names on the account's own server.
///
/// An embed's page runs untrusted scripts on a made-up origin, so it never
/// holds the account's credentials or the bytes they fetch: a server path in
/// it resolves nowhere, and a server address arrives signed out. The app
/// takes such media out of the page ([extractWebEmbedServerMedia]) and plays
/// it in its own player beside the embed, fetched with
/// [webEmbedMediaClient]. Media on any other origin stays in the page and
/// loads as it always has.
library;

import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart';

import '../../models/server_config.dart';
import '../../network/server_origin.dart';
import '../../services/server_tls_http_client_factory.dart';
import 'web_embed_document.dart' show escapeHtmlAttribute;

// ---------------------------------------------------------------------------
// Taking media out of a page.
// ---------------------------------------------------------------------------

enum WebEmbedMediaKind { audio, video }

/// An audio or video element [extractWebEmbedServerMedia] took out of a page.
final class WebEmbedMediaItem {
  const WebEmbedMediaItem({required this.kind, required this.url, this.label});

  final WebEmbedMediaKind kind;

  /// Its absolute address on the server's origin.
  final Uri url;

  /// The element's `aria-label` or `title`, when it has one.
  final String? label;

  @override
  bool operator ==(Object other) =>
      other is WebEmbedMediaItem &&
      other.kind == kind &&
      other.url == url &&
      other.label == label;

  @override
  int get hashCode => Object.hash(kind, url, label);

  @override
  String toString() => 'WebEmbedMediaItem(${kind.name}, $url, $label)';
}

/// A page with the media it names on the server taken out.
final class WebEmbedServerMedia {
  const WebEmbedServerMedia({
    required this.html,
    this.items = const [],
    this.mediaOnly = false,
  });

  /// The page to show: the source unchanged when nothing was taken.
  final String html;

  /// The media taken out, in page order.
  final List<WebEmbedMediaItem> items;

  /// Whether the page showed nothing but the media taken out of it.
  final bool mediaOnly;
}

/// The most media [extractWebEmbedServerMedia] takes from one page; any
/// more stays in the page.
const int kWebEmbedMaxServerMedia = 10;

const String _htmlNamespace = 'http://www.w3.org/1999/xhtml';

final RegExp _mediaTag = RegExp(
  r'<(?:audio|video)[\s/>]',
  caseSensitive: false,
);

/// Never shown, or shown only through what they hold.
const Set<String> _unrendered = {
  'meta',
  'link',
  'style',
  'title',
  'base',
  'template',
  'noscript',
};

/// Show nothing of their own but what they hold (a box at most).
const Set<String> _containers = {
  'html',
  'head',
  'body',
  'div',
  'span',
  'p',
  'section',
  'main',
  'article',
  'header',
  'footer',
  'center',
  'figure',
  'br',
  'wbr',
};

/// [html] with each `<audio>` and `<video>` whose media is on [server] taken
/// out, at most [maxItems] of them, and an empty box of its size left in its
/// place.
///
/// The page is parsed as a browser parses it, so markup inside a script, a
/// style, a comment, an attribute or a template is not an element and stays.
/// An element moves when the media it would load is on the server: its
/// `src`, or without one, every `<source>` it holds. Everything else in the
/// page stays exactly as written.
WebEmbedServerMedia extractWebEmbedServerMedia(
  String html, {
  required Uri? server,
  int maxItems = kWebEmbedMaxServerMedia,
}) {
  final unchanged = WebEmbedServerMedia(html: html);
  if (server == null ||
      !_isHttp(server.scheme) ||
      server.host.isEmpty ||
      !_mediaTag.hasMatch(html)) {
    return unchanged;
  }

  // The parser's offsets count line breaks as one, as a browser reads them.
  final text = html.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final scan = _MediaScan(server, maxItems)
    ..visit(HtmlParser(text, generateSpans: true).parse());
  final taken = scan.taken..sort((a, b) => a.start.compareTo(b.start));
  if (taken.isEmpty) return unchanged;

  final out = StringBuffer();
  var cursor = 0;
  for (final media in taken) {
    // A tree the parser rebuilt can put an element's source anywhere; never
    // cut text that two elements share.
    if (media.start < cursor) return unchanged;
    out
      ..write(text.substring(cursor, media.start))
      ..write(media.placeholder);
    cursor = media.end;
  }
  out.write(text.substring(cursor));

  return WebEmbedServerMedia(
    html: out.toString(),
    items: [for (final media in taken) media.item],
    mediaOnly: !scan.hasOtherContent,
  );
}

/// Where [src], an address in a page, is on [server]; null for anywhere
/// else, or one carrying a user name.
///
/// It is read as a browser reads an http(s) address: surrounding space, tabs
/// and line breaks dropped, and a backslash as a slash. A path from the root
/// joins the server's own path, as the app joins a server path for images; a
/// relative one resolves under it.
Uri? resolveWebEmbedServerMediaUrl(String src, Uri server) {
  final raw = src
      .trim()
      .replaceAll(RegExp('[\t\n\r]'), '')
      .replaceAll(r'\', '/');
  if (raw.isEmpty) return null;
  final Uri reference;
  try {
    reference = Uri.parse(raw);
  } on FormatException {
    return null;
  }

  final Uri resolved;
  if (reference.hasScheme || raw.startsWith('//')) {
    resolved = server.resolveUri(reference);
  } else if (raw.startsWith('/')) {
    final root = server.path.endsWith('/')
        ? server.path.substring(0, server.path.length - 1)
        : server.path;
    resolved = Uri(
      scheme: server.scheme,
      host: server.host,
      port: server.hasPort ? server.port : null,
      path: '$root${reference.path}',
      query: reference.hasQuery ? reference.query : null,
    );
  } else {
    final base = server.path.endsWith('/')
        ? server
        : server.replace(path: '${server.path}/');
    resolved = base.resolveUri(reference);
  }

  if (resolved.userInfo.isNotEmpty ||
      !resolved.hasScheme ||
      !imageUrlIsServerOrigin(server.toString(), resolved.toString())) {
    return null;
  }
  return resolved.removeFragment().normalizePath();
}

final class _Taken {
  _Taken(this.start, this.end, this.item, this.placeholder);

  final int start;
  final int end;
  final WebEmbedMediaItem item;
  final String placeholder;
}

final class _MediaScan {
  _MediaScan(this.server, this.maxItems);

  final Uri server;
  final int maxItems;
  final List<_Taken> taken = [];

  /// Whether anything but the media taken would show.
  bool hasOtherContent = false;

  void visit(Node node) {
    for (final child in node.nodes) {
      if (child is Element) {
        _visitElement(child);
      } else if (child is Text && child.data.trim().isNotEmpty) {
        hasOtherContent = true;
      }
    }
  }

  void _visitElement(Element element) {
    final name = element.localName;
    if (element.namespaceUri != _htmlNamespace) {
      // SVG or MathML: it shows, and a foreignObject holds HTML again.
      hasOtherContent = true;
      visit(element);
    } else if (name == 'audio' || name == 'video') {
      _visitMedia(element);
    } else if (!_unrendered.contains(name)) {
      if (!_containers.contains(name)) hasOtherContent = true;
      visit(element);
    }
  }

  void _visitMedia(Element element) {
    final url = _serverUrl(element);
    final start = element.sourceSpan?.start.offset;
    final end = _endOffset(element);
    if (url == null ||
        start == null ||
        end == null ||
        taken.length >= maxItems) {
      hasOtherContent = true;
      return;
    }
    final kind = element.localName == 'audio'
        ? WebEmbedMediaKind.audio
        : WebEmbedMediaKind.video;
    taken.add(
      _Taken(
        start,
        end,
        WebEmbedMediaItem(kind: kind, url: url, label: _label(element)),
        _placeholder(element, kind),
      ),
    );
  }

  Uri? _serverUrl(Element element) {
    final sources = element.attributes.containsKey('src')
        ? [element.attributes['src']!]
        : [
            for (final child in element.children)
              if (child.localName == 'source' &&
                  child.namespaceUri == _htmlNamespace &&
                  child.attributes.containsKey('src'))
                child.attributes['src']!,
          ];
    Uri? first;
    for (final source in sources) {
      final url = resolveWebEmbedServerMediaUrl(source, server);
      if (url == null) return null;
      first ??= url;
    }
    return first;
  }
}

/// Where [element]'s text ends: its end tag, or without one, the last thing
/// the parser put inside it.
int? _endOffset(Element element) {
  final close = element.endSourceSpan;
  if (close != null) return close.end.offset;
  var end = element.sourceSpan?.end.offset;
  if (end == null) return null;
  void reach(Node node) {
    for (final child in node.nodes) {
      end = math.max(end!, child.sourceSpan?.end.offset ?? 0);
      if (child is Element) {
        end = math.max(end!, child.endSourceSpan?.end.offset ?? 0);
      }
      reach(child);
    }
  }

  reach(element);
  return end;
}

String? _label(Element element) {
  for (final name in const ['aria-label', 'title']) {
    final value = element.attributes[name]
        ?.replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (value != null && value.isNotEmpty) {
      return value.runes.length <= 120
          ? value
          : '${String.fromCharCodes(value.runes.take(119))}…';
    }
  }
  return null;
}

/// An empty box the size the element took, so the page around it stays put.
String _placeholder(Element element, WebEmbedMediaKind kind) {
  final attributes = StringBuffer(' data-conduit-media aria-hidden="true"');
  final className = element.attributes['class']?.trim() ?? '';
  if (className.isNotEmpty) {
    attributes.write(' class="${escapeHtmlAttribute(className)}"');
  }
  // Audio without controls shows nothing.
  if (kind == WebEmbedMediaKind.audio &&
      !element.attributes.containsKey('controls')) {
    return '<span$attributes hidden></span>';
  }
  final size = switch (kind) {
    WebEmbedMediaKind.audio => 'width:300px;height:40px',
    WebEmbedMediaKind.video => _videoSize(element),
  };
  final style =
      'display:inline-block;max-width:100%;$size;'
      '${element.attributes['style'] ?? ''}';
  attributes.write(' style="${escapeHtmlAttribute(style)}"');
  return '<span$attributes></span>';
}

String _videoSize(Element element) {
  final width = _dimension(element.attributes['width']) ?? 300;
  final height = _dimension(element.attributes['height']) ?? 150;
  return 'width:${width}px;aspect-ratio:$width/$height';
}

int? _dimension(String? raw) {
  final value = int.tryParse(raw?.trim() ?? '');
  return value != null && value > 0 && value <= 10000 ? value : null;
}

bool _isHttp(String scheme) {
  final lower = scheme.toLowerCase();
  return lower == 'http' || lower == 'https';
}

// ---------------------------------------------------------------------------
// Fetching it.
// ---------------------------------------------------------------------------

const Duration kWebEmbedMediaConnectTimeout = Duration(seconds: 15);

/// How long the server may take to start answering.
const Duration kWebEmbedMediaReceiveTimeout = Duration(seconds: 30);

/// The client the app's player fetches embed media with: [headers], the
/// account's credentials, sent only to [server] and with its TLS settings,
/// following no redirect.
///
/// It is kept apart from the account's API client, whose interceptors take a
/// refusal, a sign-in page or a gateway error as the session or the route
/// failing; an address a page names says neither.
Dio webEmbedMediaClient(ServerConfig server, Map<String, String> headers) {
  final dio = Dio(
    BaseOptions(
      headers: headers,
      connectTimeout: kWebEmbedMediaConnectTimeout,
      receiveTimeout: kWebEmbedMediaReceiveTimeout,
      followRedirects: false,
      maxRedirects: 0,
      validateStatus: (status) => status == 200 || status == 206,
    ),
  );
  ServerTlsHttpClientFactory.configureDio(dio, server);
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        final uri = options.uri;
        if (uri.hasScheme && imageUrlIsServerOrigin(server.url, '$uri')) {
          handler.next(options);
        } else {
          handler.reject(
            DioException(
              requestOptions: options,
              error: StateError('Embed media is fetched only from the server'),
            ),
          );
        }
      },
    ),
  );
  return dio;
}

/// A server reply that is not audio or video, such as a page or data.
final class WebEmbedMediaRefused implements Exception {
  const WebEmbedMediaRefused(this.contentType);

  final String? contentType;

  @override
  String toString() => 'WebEmbedMediaRefused($contentType)';
}

/// Part of a media file: [stream] holds [contentLength] bytes from [offset]
/// in a file [sourceLength] long; a null length is one the server did not
/// give. [rangeable] says whether the server answered a range.
typedef WebEmbedMediaBody = ({
  Stream<List<int>> stream,
  int offset,
  int? contentLength,
  int? sourceLength,
  String? contentType,
  bool rangeable,
});

final RegExp _contentRange = RegExp(
  r'^\s*bytes\s+(\d+)-(\d+)/(\d+|\*)\s*$',
  caseSensitive: false,
);

/// Streams [url] with [client] ([webEmbedMediaClient]) from byte [start] up
/// to [end], exclusive; null for the start or the end of the file.
///
/// It asks for the range; a server that sends the whole file instead is read
/// from [start]. Throws [WebEmbedMediaRefused] for a reply that is not audio
/// or video.
Future<WebEmbedMediaBody> openWebEmbedServerMedia(
  Dio client,
  Uri url, {
  int? start,
  int? end,
  CancelToken? cancelToken,
}) async {
  final from = start ?? 0;
  final response = await client.getUri<ResponseBody>(
    url,
    cancelToken: cancelToken,
    options: Options(
      responseType: ResponseType.stream,
      headers: {
        'Range': 'bytes=$from-${end == null ? '' : end - 1}',
        'Accept': 'audio/*, video/*, */*;q=0.1',
      },
    ),
  );
  final body = response.data!;
  final contentType = response.headers
      .value(Headers.contentTypeHeader)
      ?.split(';')
      .first
      .trim()
      .toLowerCase();
  final type = contentType == null || contentType.isEmpty ? null : contentType;
  if (!_isPlayableType(type)) {
    await body.stream.listen(null).cancel();
    throw WebEmbedMediaRefused(type);
  }

  final length = int.tryParse(
    response.headers.value(Headers.contentLengthHeader) ?? '',
  );
  if (response.statusCode == 206) {
    final range = _contentRange.firstMatch(
      response.headers.value('content-range') ?? '',
    );
    if (range == null) {
      await body.stream.listen(null).cancel();
      throw WebEmbedMediaRefused(type);
    }
    final first = int.parse(range[1]!);
    return (
      stream: body.stream,
      offset: first,
      contentLength: int.parse(range[2]!) - first + 1,
      sourceLength: int.tryParse(range[3]!),
      contentType: type,
      rangeable: true,
    );
  }

  final available = length == null ? null : math.max(0, length - from);
  final wanted = end == null ? null : math.max(0, end - from);
  final take = available == null
      ? wanted
      : (wanted == null ? available : math.min(available, wanted));
  return (
    stream: _slice(body.stream, skip: from, take: take),
    offset: from,
    contentLength: take,
    sourceLength: length,
    contentType: type,
    rangeable: false,
  );
}

bool _isPlayableType(String? type) =>
    type == null ||
    type.startsWith('audio/') ||
    type.startsWith('video/') ||
    type == 'application/ogg' ||
    type == 'application/octet-stream' ||
    type == 'binary/octet-stream';

Stream<List<int>> _slice(
  Stream<List<int>> source, {
  required int skip,
  int? take,
}) async* {
  var toSkip = skip;
  var left = take;
  await for (final chunk in source) {
    var data = chunk;
    if (toSkip > 0) {
      if (data.length <= toSkip) {
        toSkip -= data.length;
        continue;
      }
      data = data.sublist(toSkip);
      toSkip = 0;
    }
    if (left != null) {
      if (data.length >= left) {
        yield data.sublist(0, left);
        return;
      }
      left -= data.length;
    }
    yield data;
  }
}
