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
    Timer Function(Duration, void Function())? deadline,
  }) : _deadline = deadline ?? Timer.new,
       _sites = VettedConnector(
         allowed: isLanOrPublicHostAddress,
         lookup: lookup,
         connectTimeout: connectTimeout,
       ),
       _server = VettedConnector(
         allowed: (_) => true,
         lookup: lookup,
         connectTimeout: connectTimeout,
       );

  /// A client for one fetch, closed when it ends: no connection outlives
  /// the fetch, so none is reused for another (the account's server and
  /// other sites never share one), and every connection it opens is given
  /// up once [stopped] says the fetch is over (a lookup that answers after
  /// the time limit connects nothing).
  HttpClient _clientFor(bool Function() stopped) {
    final client = HttpClient()
      ..connectionTimeout = connectTimeout
      ..userAgent = userAgent
      ..autoUncompress = true
      // Straight to the vetted address: a proxy would connect elsewhere.
      ..findProxy = ((_) => 'DIRECT')
      ..connectionFactory = (uri, proxyHost, proxyPort) =>
          _connect(uri, stopped);
    _open.add(client);
    return client;
  }

  /// The active account's server, or null without one: its origin is
  /// reached as the app reaches it.
  final Future<Uri?> Function()? ownServer;

  /// Starts a fetch's time limit (a [Timer]; a test fires its own).
  final Timer Function(Duration, void Function()) _deadline;

  /// The clients of fetches still going ([close] ends them).
  final Set<HttpClient> _open = <HttpClient>{};
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

  /// Fetches [raw] as [kind]. One time limit bounds every wait (the
  /// connection, the answer, every byte of the body): when it passes, the
  /// fetch ends as timed out whatever it was waiting on. A fetch that
  /// starts on the account's own server (which the window loads without
  /// asking) follows redirects only on that origin: one to another site is
  /// refused, so it can never load a site the user has not allowed.
  Future<({Uint8List bytes, String contentType})> fetch(
    String raw,
    MediaKind kind,
  ) async {
    final start = parse(raw);
    final limit = limitFor(kind);
    HttpClientRequest? request;
    // An answer whose head arrived and whose body nobody reads yet.
    HttpClientResponse? unread;
    StreamSubscription<List<int>>? body;
    final expired = Completer<Never>();
    expired.future.ignore();
    final deadline = _deadline(timeout, () {
      if (expired.isCompleted) return;
      expired.completeError(const MediaFetchException(MediaFailure.timedOut));
      request?.abort(const MediaFetchException(MediaFailure.timedOut));
      if (unread case final open?) _abandon(open);
      body?.cancel().ignore();
    });
    Future<T> inTime<T>(Future<T> work) =>
        Future.any<T>(<Future<T>>[work, expired.future]);
    final client = _clientFor(() => expired.isCompleted);
    try {
      final own = await inTime(ownServer?.call() ?? Future<Uri?>.value());
      var url = start;
      for (var redirects = 0; ; redirects++) {
        final opening = client.getUrl(url);
        try {
          request = await inTime(opening);
        } on MediaFetchException {
          // Connected after the limit: dropped unsent.
          opening.then((late) => late.abort(), onError: (_) {}).ignore();
          rethrow;
        }
        final open = request!;
        open
          ..followRedirects = false
          ..persistentConnection = true;
        open.headers
          ..set(HttpHeaders.acceptHeader, switch (kind) {
            MediaKind.image =>
              'image/png,image/jpeg,image/gif,image/webp,image/svg+xml,'
                  'image/*;q=0.8',
            MediaKind.pdf => 'application/pdf',
          })
          ..removeAll(HttpHeaders.refererHeader)
          ..removeAll(HttpHeaders.cookieHeader)
          ..removeAll(HttpHeaders.authorizationHeader);
        final response = await inTime(open.close());
        unread = response;
        if (response.isRedirect) {
          // Its body is never read: draining would wait on a site that
          // stalls it.
          unread = null;
          _abandon(response);
          final location = response.headers.value(HttpHeaders.locationHeader);
          if (location == null || redirects >= maxRedirects) {
            throw const MediaFetchException(MediaFailure.failed, 'redirects');
          }
          final next = url.resolve(location).removeFragment();
          if (!(next.scheme == 'http' || next.scheme == 'https') ||
              next.host.isEmpty ||
              next.userInfo.isNotEmpty) {
            throw const MediaFetchException(MediaFailure.failed, 'redirect');
          }
          if (!hopAllowed(start, next, own)) {
            throw const MediaFetchException(
              MediaFailure.refused,
              'a redirect off the host it was allowed for',
            );
          }
          url = next;
          continue;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          unread = null;
          _abandon(response);
          throw MediaFetchException(
            MediaFailure.failed,
            'status ${response.statusCode}',
          );
        }
        final stated = response.contentLength;
        if (stated > limit) {
          unread = null;
          _abandon(response);
          throw const MediaFetchException(MediaFailure.tooLarge);
        }
        final builder = BytesBuilder(copy: false);
        final done = Completer<void>();
        unread = null;
        body = response.listen(
          (chunk) {
            builder.add(chunk);
            if (builder.length > limit && !done.isCompleted) {
              done.completeError(
                const MediaFetchException(MediaFailure.tooLarge),
              );
            }
          },
          onError: (Object error, StackTrace stack) {
            if (!done.isCompleted) done.completeError(error, stack);
          },
          onDone: () {
            if (!done.isCompleted) done.complete();
          },
          cancelOnError: true,
        );
        await inTime(done.future);
        final bytes = builder.takeBytes();
        final statedType = response.headers.contentType?.mimeType ?? '';
        final type = typeOf(kind, statedType, bytes);
        if (type == null) {
          throw const MediaFetchException(MediaFailure.wrongType);
        }
        return (bytes: bytes, contentType: type);
      }
    } on MediaFetchException {
      if (expired.isCompleted) {
        throw const MediaFetchException(MediaFailure.timedOut);
      }
      rethrow;
    } on RefusedAddressException {
      throw const MediaFetchException(MediaFailure.refused);
    } on Object catch (error) {
      if (expired.isCompleted) {
        throw const MediaFetchException(MediaFailure.timedOut);
      }
      throw MediaFetchException(MediaFailure.failed, '$error');
    } finally {
      deadline.cancel();
      body?.cancel().ignore();
      _open.remove(client);
      client.close(force: true);
    }
  }

  /// Lets go of [response] without reading its body: its socket is taken
  /// from the client and destroyed, so a site that stalls the rest holds
  /// nothing open and nothing waits on it (draining would). Every answer
  /// [fetch] does not read ends here.
  static void _abandon(HttpClientResponse response) {
    response
        .detachSocket()
        .then((socket) => socket.destroy(), onError: (Object _) {})
        .ignore();
  }

  /// Every connection [fetch] opens, its redirects' too: to the account's
  /// own server as it is, to anywhere else only at a vetted address.
  Future<ConnectionTask<Socket>> _connect(
    Uri uri,
    bool Function() stopped,
  ) async {
    final own = await ownServer?.call();
    if (stopped()) throw const SocketException('Connection stopped');
    if (own != null && sameOrigin(uri, own)) {
      return _server.connect(uri, stopped: stopped);
    }
    return _sites.connect(uri, stopped: stopped);
  }

  /// Whether a redirect from the fetch that started at [start] may go on to
  /// [next]. The window loads a site only when the user allowed it, by its
  /// host (or loads the account's server, [own], without asking, by its
  /// exact origin), so a hop stays on that same host (any port or scheme
  /// change on the host is still that host), or on that same origin for the
  /// account's server. Anywhere else is refused before it is even asked.
  static bool hopAllowed(Uri start, Uri next, Uri? own) {
    if (own != null && sameOrigin(start, own)) return sameOrigin(next, own);
    String host(Uri u) =>
        u.host.toLowerCase().replaceFirst(RegExp(r'\.+$'), '');
    return host(next) == host(start);
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

  void close() {
    for (final client in _open.toList()) {
      client.close(force: true);
    }
    _open.clear();
  }
}
