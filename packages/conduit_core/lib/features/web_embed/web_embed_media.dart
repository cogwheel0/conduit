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

import 'dart:async';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart';

import '../../models/server_config.dart';
import '../../network/server_origin.dart';
import '../../services/server_tls_http_client_factory.dart';
import '../chat/read_aloud/tts_manager.dart' show audioExtensionForMimeType;
import 'web_embed_document.dart' show escapeHtmlAttribute;

// ---------------------------------------------------------------------------
// Taking media out of a page.
// ---------------------------------------------------------------------------

enum WebEmbedMediaKind { audio, video }

/// An audio or video element [extractWebEmbedServerMedia] took out of a page.
final class WebEmbedMediaItem {
  const WebEmbedMediaItem({
    required this.kind,
    required this.sources,
    this.label,
  });

  final WebEmbedMediaKind kind;

  /// Its absolute addresses on the server's origin, never empty: its `src`,
  /// or each of its `<source>` elements in page order, for a player to try in
  /// turn as a browser does.
  final List<Uri> sources;

  /// The address tried first.
  Uri get url => sources.first;

  /// The element's `aria-label` or `title`, when it has one.
  final String? label;

  @override
  bool operator ==(Object other) =>
      other is WebEmbedMediaItem &&
      other.kind == kind &&
      _sameSources(other.sources, sources) &&
      other.label == label;

  @override
  int get hashCode => Object.hash(kind, Object.hashAll(sources), label);

  @override
  String toString() => 'WebEmbedMediaItem(${kind.name}, $sources, $label)';
}

bool _sameSources(List<Uri> a, List<Uri> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
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
  final document = HtmlParser(text, generateSpans: true).parse();
  final baseHref = _baseHref(document);
  final scan = _MediaScan(
    server,
    maxItems,
    base: baseHref == null ? null : _resolve(baseHref, server),
  )..visit(document);
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
/// relative one resolves under it, or under the page's [base] address when
/// it has one (`<base href>`, resolved the same way).
Uri? resolveWebEmbedServerMediaUrl(String src, Uri server, {Uri? base}) {
  final resolved = _resolve(src, server, base: base);
  if (resolved == null ||
      resolved.userInfo.isNotEmpty ||
      !resolved.hasScheme ||
      !imageUrlIsServerOrigin(server.toString(), resolved.toString())) {
    return null;
  }
  return resolved.removeFragment().normalizePath();
}

Uri? _resolve(String src, Uri server, {Uri? base}) {
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

  if (reference.hasScheme) return reference;
  // A scheme-relative address takes the scheme of the page's base.
  if (raw.startsWith('//')) return (base ?? server).resolveUri(reference);
  // A base anywhere else takes every relative address with it.
  if (base != null &&
      (!raw.startsWith('/') ||
          !imageUrlIsServerOrigin(server.toString(), base.toString()))) {
    return base.resolveUri(reference);
  }
  if (raw.startsWith('/')) {
    final root = server.path.endsWith('/')
        ? server.path.substring(0, server.path.length - 1)
        : server.path;
    return Uri(
      scheme: server.scheme,
      host: server.host,
      port: server.hasPort ? server.port : null,
      path: '$root${reference.path}',
      query: reference.hasQuery ? reference.query : null,
    );
  }
  final directory = server.path.endsWith('/')
      ? server
      : server.replace(path: '${server.path}/');
  return directory.resolveUri(reference);
}

/// The page's base address as written: the first `<base>` with an `href`,
/// wherever it sits, as a browser takes it. A template's content is not in
/// the page, and with scripts on, neither is a noscript's.
String? _baseHref(Node node) {
  for (final child in node.nodes) {
    if (child is! Element) continue;
    final html = child.namespaceUri == _htmlNamespace;
    if (html &&
        (child.localName == 'template' || child.localName == 'noscript')) {
      continue;
    }
    if (html &&
        child.localName == 'base' &&
        child.attributes.containsKey('href')) {
      return child.attributes['href'];
    }
    final found = _baseHref(child);
    if (found != null) return found;
  }
  return null;
}

/// CSS that can show something of its own: generated text, an image, or
/// rules from elsewhere.
final RegExp _showingCss = RegExp(
  r'(?<![\w-])content\s*:|url\s*\(|image-set\s*\(|@import',
  caseSensitive: false,
);

/// Whether [element]'s styles, or a stylesheet it is, can show something in
/// an otherwise empty page; layout and colour alone don't.
bool _stylesShowSomething(Element element) {
  final style = element.attributes['style'];
  if (style != null && _showingCss.hasMatch(style)) return true;
  return switch (element.localName) {
    'style' => _showingCss.hasMatch(element.text),
    'link' =>
      (element.attributes['rel'] ?? '')
          .toLowerCase()
          .split(RegExp(r'\s+'))
          .contains('stylesheet'),
    _ => false,
  };
}

final class _Taken {
  _Taken(this.start, this.end, this.item, this.placeholder);

  final int start;
  final int end;
  final WebEmbedMediaItem item;
  final String placeholder;
}

final class _MediaScan {
  _MediaScan(this.server, this.maxItems, {this.base});

  final Uri server;
  final int maxItems;
  final Uri? base;
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
    } else {
      if (_stylesShowSomething(element)) hasOtherContent = true;
      if (!_unrendered.contains(name)) {
        if (!_containers.contains(name)) hasOtherContent = true;
        visit(element);
      }
    }
  }

  void _visitMedia(Element element) {
    final sources = _serverSources(element);
    final start = element.sourceSpan?.start.offset;
    final end = _endOffset(element);
    if (sources == null ||
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
        WebEmbedMediaItem(kind: kind, sources: sources, label: _label(element)),
        _placeholder(element, kind),
      ),
    );
  }

  List<Uri>? _serverSources(Element element) {
    final sources = element.attributes.containsKey('src')
        ? [element.attributes['src']!]
        : [
            for (final child in element.children)
              if (child.localName == 'source' &&
                  child.namespaceUri == _htmlNamespace &&
                  child.attributes.containsKey('src'))
                child.attributes['src']!,
          ];
    final urls = <Uri>[];
    for (final source in sources) {
      final url = resolveWebEmbedServerMediaUrl(source, server, base: base);
      if (url == null) return null;
      if (!urls.contains(url)) urls.add(url);
    }
    return urls.isEmpty ? null : urls;
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
/// A reply that is not audio or video, such as a proxy's sign-in page, fails
/// with [WebEmbedMediaRefused] as its error as soon as its headers arrive, so
/// a download never writes it.
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
      onResponse: (response, handler) {
        final type = _mediaType(response.headers);
        if (_isPlayableType(type)) {
          handler.next(response);
          return;
        }
        final data = response.data;
        if (data is ResponseBody) unawaited(data.stream.listen(null).cancel());
        handler.reject(
          DioException(
            requestOptions: response.requestOptions,
            response: response,
            error: WebEmbedMediaRefused(type),
          ),
        );
      },
    ),
  );
  return dio;
}

String? _mediaType(Headers headers) {
  final type = headers
      .value(Headers.contentTypeHeader)
      ?.split(';')
      .first
      .trim()
      .toLowerCase();
  return type == null || type.isEmpty ? null : type;
}

/// The extension for a file of audio [source] answered with: the reply's
/// [mediaType] names it, or else the file name its [contentDisposition]
/// gives, or else the address. A player may read a file's format from its
/// name, and a server's file address often has none.
String webEmbedAudioExtension(
  Uri source, {
  String? mediaType,
  String? contentDisposition,
}) {
  final type = (mediaType ?? '').split(';').first.trim().toLowerCase();
  final fromType =
      _audioTypeExtensions[type] ?? audioExtensionForMimeType(type);
  if (fromType != 'audio') return fromType;
  final fileName = _dispositionFileName(contentDisposition);
  return (fileName == null ? null : _audioExtensionOf(fileName)) ??
      _audioExtensionOf(
        source.pathSegments.isEmpty ? '' : source.pathSegments.last,
      ) ??
      'audio';
}

String? _audioExtensionOf(String name) {
  final dot = name.lastIndexOf('.');
  final extension = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  return _audioExtensions.contains(extension) ? extension : null;
}

final RegExp _dispositionFileNameParameter = RegExp(
  r'''(?:^|;)\s*(filename\*?)\s*=\s*("(?:[^"\\]|\\.)*"|[^;]*)''',
  caseSensitive: false,
);

/// The file name a `Content-Disposition` header gives: its `filename*`,
/// which RFC 6266 prefers, or else its `filename`.
String? _dispositionFileName(String? header) {
  if (header == null) return null;
  String? plain;
  for (final match in _dispositionFileNameParameter.allMatches(header)) {
    final value = match.group(2)!.trim();
    if (match.group(1)!.toLowerCase() == 'filename*') {
      // charset'language'percent-encoded-name
      final parts = value.split("'");
      final decoded = parts.length == 3 ? _percentDecoded(parts[2]) : null;
      if (decoded != null) return decoded;
    } else if (value.length > 1 &&
        value.startsWith('"') &&
        value.endsWith('"')) {
      plain ??= value
          .substring(1, value.length - 1)
          .replaceAllMapped(RegExp(r'\\(.)'), (m) => m[1]!);
    } else {
      plain ??= value;
    }
  }
  return plain;
}

String? _percentDecoded(String value) {
  try {
    return Uri.decodeComponent(value);
  } on ArgumentError {
    return null;
  } on FormatException {
    return null;
  }
}

/// Formats the speech helper ([audioExtensionForMimeType]) does not name.
const Map<String, String> _audioTypeExtensions = {
  'audio/flac': 'flac',
  'audio/x-flac': 'flac',
  'audio/webm': 'webm',
  'audio/opus': 'opus',
};

const Set<String> _audioExtensions = {
  'aac',
  'flac',
  'm4a',
  'mp3',
  'mp4',
  'oga',
  'ogg',
  'opus',
  'wav',
  'webm',
};

/// A server reply that is not audio or video, such as a page or data.
final class WebEmbedMediaRefused implements Exception {
  const WebEmbedMediaRefused(this.contentType);

  final String? contentType;

  @override
  String toString() => 'WebEmbedMediaRefused($contentType)';
}

/// One load of a player from one of an item's [sources], at [index], and
/// where a failure of it leads. Before the player is ready, it leads to the
/// next source, as a browser's media element moves on; once the player is
/// ready, or from the last source, to the player showing the failure.
///
/// A player reports a failed load in more than one way (the load throws, and
/// an error event arrives), so a load fails once: its first failure reaches
/// [onFailure], and none does once it has been [cancel]led.
final class WebEmbedMediaLoad {
  WebEmbedMediaLoad(this.sources, {this.index = 0, required this.onFailure});

  final List<Uri> sources;
  final int index;

  /// [retryFrom] is the source the next load starts from, or null for none.
  final void Function(int? retryFrom, Object error, StackTrace stackTrace)
  onFailure;

  bool _ready = false;
  bool _over = false;

  Uri get source => sources[index];

  /// Whether the player's events still count: the load has neither failed
  /// nor been cancelled.
  bool get isCurrent => !_over;

  /// The player can play this load's media.
  void markReady() {
    if (!_over) _ready = true;
  }

  void cancel() => _over = true;

  void fail(Object error, StackTrace stackTrace) {
    if (_over) return;
    _over = true;
    final next = index + 1 < sources.length ? index + 1 : null;
    onFailure(_ready ? null : next, error, stackTrace);
  }
}

bool _isPlayableType(String? type) =>
    type == null ||
    type.startsWith('audio/') ||
    type.startsWith('video/') ||
    type == 'application/ogg' ||
    type == 'application/octet-stream' ||
    type == 'binary/octet-stream';
