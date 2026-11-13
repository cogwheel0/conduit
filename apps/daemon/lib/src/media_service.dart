import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:conduit_core/network/io/vetted_connector.dart';

/// What `GET /media/{kind}` fetches.
enum MediaKind {
  /// A picture an answer shows (`![alt](https://…)`).
  image,

  /// A PDF an answer links to, for its first-page card.
  pdf,
}

/// Why a fetch was refused or failed; the route's status and error code.
enum MediaFailure {
  /// Not an http(s) address, or one carrying a user name or password.
  invalidUrl(400, 'media.invalidUrl'),

  /// On this Mac itself, link-local or multicast (by the address the host
  /// resolves to, on every redirect too).
  refused(403, 'media.refused'),

  /// Larger than the kind's limit, by its stated length or as it arrived.
  tooLarge(413, 'media.tooLarge'),

  /// The bytes are not a picture (or not a PDF).
  wrongType(415, 'media.wrongType'),

  /// Took longer than the limit.
  timedOut(504, 'media.timedOut'),

  /// The site answered with an error, or could not be reached.
  failed(502, 'media.failed');

  const MediaFailure(this.status, this.code);

  final int status;
  final String code;
}

final class MediaFetchException implements Exception {
  const MediaFetchException(this.failure, [this.detail = '']);

  final MediaFailure failure;
  final String detail;

  @override
  String toString() => 'MediaFetchException(${failure.name}: $detail)';
}

/// Fetches a picture or a PDF from another site for the window, which loads
/// it only when the user asks (or has allowed its site): the window never
/// holds a network client of its own, and these rules hold for every fetch.
///
/// * **Anonymous.** No cookies (dart:io keeps no cookie jar), no
///   credentials (an address carrying a user name is refused, and nothing
///   of the account's is sent: not its token, not its custom headers), and
///   no `Referer`, so the site learns nothing of the chat it was linked
///   from. The user agent is the app's bare name.
/// * **Bounded.** A size limit per kind, checked against the stated length
///   and again as the bytes arrive, and a time limit for the whole fetch;
///   at most [maxRedirects] redirects, each to http(s).
/// * **Not this Mac.** Every connection, each redirect's included, goes to
///   an address checked where it is made ([VettedConnector]): never
///   loopback, unspecified, link-local (`169.254/16`, `fe80::/10`: routers,
///   cloud metadata) or multicast, so a name that resolves elsewhere for a
///   check than for the connect (DNS rebinding) cannot reach them. A
///   private LAN address is allowed: loading waits for a click, and people
///   host their own sites. The account's own server ([ownServer], its exact
///   origin) is the one exception: the app reaches it anyway, often on
///   this Mac, and its files go through `/files` with the credential.
/// * **Once.** A failure is answered as it is, never tried again here; the
///   window offers Try Again.
/// * **Typed.** An image must be an image and a PDF a PDF, by the type the
///   site states or, failing that, by the bytes' signature, so an HTML page
///   is never handed to a decoder as if it were a picture.
final class MediaService {
  MediaService({
    this.ownServer,
    HostLookup? lookup,
    this.timeout = const Duration(seconds: 20),
    this.connectTimeout = const Duration(seconds: 10),
    this.maxImageBytes = 15 * 1024 * 1024,
    this.maxPdfBytes = 30 * 1024 * 1024,
  }) : _client = HttpClient(),
       _sites = VettedConnector(
         allowed: isLanOrPublicHostAddress,
         lookup: lookup,
         connectTimeout: connectTimeout,
       ),
       _server = VettedConnector(
         allowed: (_) => true,
         lookup: lookup,
         connectTimeout: connectTimeout,
       ) {
    _client
      ..connectionTimeout = connectTimeout
      ..userAgent = userAgent
      ..autoUncompress = true
      // Straight to the vetted address: a proxy would connect elsewhere.
      ..findProxy = ((_) => 'DIRECT')
      ..connectionFactory = (uri, proxyHost, proxyPort) => _connect(uri);
  }

  /// The active account's server, or null without one: its origin is
  /// reached as the app reaches it.
  final Future<Uri?> Function()? ownServer;

  final HttpClient _client;
  final VettedConnector _sites;
  final VettedConnector _server;
  final Duration timeout;
  final Duration connectTimeout;
  final int maxImageBytes;
  final int maxPdfBytes;

  static const int maxRedirects = 3;
  static const String userAgent = 'Conduit';

  int limitFor(MediaKind kind) => switch (kind) {
    MediaKind.image => maxImageBytes,
    MediaKind.pdf => maxPdfBytes,
  };

  /// The address to fetch, or why it is refused.
  static Uri parse(String raw) {
    final url = Uri.tryParse(raw.trim());
    if (url == null ||
        !(url.scheme == 'http' || url.scheme == 'https') ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty) {
      throw const MediaFetchException(MediaFailure.invalidUrl);
    }
    return url.removeFragment();
  }

  Future<({Uint8List bytes, String contentType})> fetch(
    String raw,
    MediaKind kind,
  ) async {
    final url = parse(raw);
    final limit = limitFor(kind);
    HttpClientRequest? request;
    var timedOut = false;
    final deadline = Timer(timeout, () {
      timedOut = true;
      request?.abort(const MediaFetchException(MediaFailure.timedOut));
    });
    try {
      request = await _client.getUrl(url);
      request
        ..followRedirects = true
        ..maxRedirects = maxRedirects
        ..persistentConnection = true;
      request.headers
        ..set(HttpHeaders.acceptHeader, switch (kind) {
          MediaKind.image =>
            'image/png,image/jpeg,image/gif,image/webp,image/svg+xml,'
                'image/*;q=0.8',
          MediaKind.pdf => 'application/pdf',
        })
        ..removeAll(HttpHeaders.refererHeader)
        ..removeAll(HttpHeaders.cookieHeader)
        ..removeAll(HttpHeaders.authorizationHeader);
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw MediaFetchException(
          MediaFailure.failed,
          'status ${response.statusCode}',
        );
      }
      final stated = response.contentLength;
      if (stated > limit) {
        throw const MediaFetchException(MediaFailure.tooLarge);
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        builder.add(chunk);
        if (builder.length > limit) {
          throw const MediaFetchException(MediaFailure.tooLarge);
        }
      }
      final bytes = builder.takeBytes();
      final statedType = response.headers.contentType?.mimeType ?? '';
      final type = typeOf(kind, statedType, bytes);
      if (type == null) {
        throw const MediaFetchException(MediaFailure.wrongType);
      }
      return (bytes: bytes, contentType: type);
    } on MediaFetchException {
      if (timedOut) {
        throw const MediaFetchException(MediaFailure.timedOut);
      }
      rethrow;
    } on RefusedAddressException {
      throw const MediaFetchException(MediaFailure.refused);
    } on Object catch (error) {
      if (timedOut) {
        throw const MediaFetchException(MediaFailure.timedOut);
      }
      throw MediaFetchException(MediaFailure.failed, '$error');
    } finally {
      deadline.cancel();
    }
  }

  /// Every connection [fetch] opens, its redirects' too: to the account's
  /// own server as it is, to anywhere else only at a vetted address.
  Future<ConnectionTask<Socket>> _connect(Uri uri) async {
    final own = await ownServer?.call();
    if (own != null && sameOrigin(uri, own)) {
      return _server.connect(uri);
    }
    return _sites.connect(uri);
  }

  /// Whether [a] and [b] have one scheme, host and port.
  static bool sameOrigin(Uri a, Uri b) =>
      a.scheme.toLowerCase() == b.scheme.toLowerCase() &&
      a.host.toLowerCase().replaceFirst(RegExp(r'\.+$'), '') ==
          b.host.toLowerCase().replaceFirst(RegExp(r'\.+$'), '') &&
      a.port == b.port;

  /// The type to answer [bytes] with, or null when they are not [kind]:
  /// the stated type when it is one, else the bytes' signature.
  static String? typeOf(MediaKind kind, String stated, Uint8List bytes) {
    final mime = stated.toLowerCase();
    switch (kind) {
      case MediaKind.pdf:
        return _isPdf(bytes) ? 'application/pdf' : null;
      case MediaKind.image:
        final sniffed = _imageSignature(bytes);
        if (sniffed != null) return sniffed;
        // An SVG has no fixed signature: its stated type, and markup that
        // opens as one.
        if (mime == 'image/svg+xml' && _looksLikeSvg(bytes)) {
          return 'image/svg+xml';
        }
        if (mime.isEmpty || mime == 'application/octet-stream') {
          return _looksLikeSvg(bytes) ? 'image/svg+xml' : null;
        }
        return null;
    }
  }

  static bool _startsWith(Uint8List bytes, List<int> prefix, [int at = 0]) {
    if (bytes.length < at + prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[at + i] != prefix[i]) return false;
    }
    return true;
  }

  static bool _isPdf(Uint8List bytes) =>
      _startsWith(bytes, const <int>[0x25, 0x50, 0x44, 0x46, 0x2D]);

  static String? _imageSignature(Uint8List b) {
    if (_startsWith(b, const <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])) {
      return 'image/png';
    }
    if (_startsWith(b, const <int>[0xFF, 0xD8, 0xFF])) return 'image/jpeg';
    if (_startsWith(b, const <int>[0x47, 0x49, 0x46, 0x38])) return 'image/gif';
    if (_startsWith(b, const <int>[0x52, 0x49, 0x46, 0x46]) &&
        _startsWith(b, const <int>[0x57, 0x45, 0x42, 0x50], 8)) {
      return 'image/webp';
    }
    if (_startsWith(b, const <int>[0x42, 0x4D])) return 'image/bmp';
    if (_startsWith(b, const <int>[0x49, 0x49, 0x2A, 0x00]) ||
        _startsWith(b, const <int>[0x4D, 0x4D, 0x00, 0x2A])) {
      return 'image/tiff';
    }
    return null;
  }

  static bool _looksLikeSvg(Uint8List bytes) {
    final head = String.fromCharCodes(
      bytes.sublist(0, bytes.length < 512 ? bytes.length : 512),
    ).trimLeft().toLowerCase();
    return head.startsWith('<svg') ||
        (head.startsWith('<?xml') && head.contains('<svg'));
  }

  void close() => _client.close(force: true);
}
