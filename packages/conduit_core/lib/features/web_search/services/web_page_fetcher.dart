import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_ddgs/conduit_ddgs.dart' show kDdgsDefaultUserAgent;

import 'package:conduit_core/features/web_search/services/public_web_address.dart';

/// Why a page could not be fetched. The message is written for the model,
/// which reads it as the tool result.
final class WebFetchException implements Exception {
  const WebFetchException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'WebFetchException: $message';
}

/// A fetched page body, decoded to text.
final class FetchedWebPage {
  const FetchedWebPage({
    required this.url,
    required this.contentType,
    required this.body,
    required this.truncated,
  });

  /// The final URL after redirects.
  final Uri url;

  /// Lower-cased MIME type without parameters, e.g. `text/html`.
  final String contentType;
  final String body;

  /// Whether the body was cut at the fetcher's byte limit.
  final bool truncated;
}

typedef HostLookup = Future<List<InternetAddress>> Function(String host);

/// Fetches public web pages from the device for the `web_fetch` tool.
///
/// The device can usually reach the user's LAN, so every connection is
/// vetted where it is made: the host is resolved, every resolved address
/// must be public, and the socket is opened to one of those vetted
/// addresses. A hostname that re-resolves to a private address between a
/// check and the connect (DNS rebinding) therefore still cannot reach the
/// LAN. Redirects are followed by hand so each hop goes through the same
/// check.
class WebPageFetcher {
  WebPageFetcher({
    HostLookup? lookup,
    this.timeout = const Duration(seconds: 15),
    this.connectTimeout = const Duration(seconds: 6),
    this.maxBytes = 2 * 1024 * 1024,
    this.maxRedirects = 5,
    this.userAgent = kDdgsDefaultUserAgent,
  }) : _lookup = lookup ?? InternetAddress.lookup;

  final HostLookup _lookup;
  final Duration timeout;
  final Duration connectTimeout;
  final int maxBytes;
  final int maxRedirects;
  final String userAgent;

  static const Set<String> supportedContentTypes = {
    'text/html',
    'application/xhtml+xml',
    'text/plain',
    'text/markdown',
    'text/x-markdown',
    'application/json',
  };

  /// Fetches [url], which must already have passed [normalizePublicWebUrl].
  ///
  /// Throws [WebFetchException] for any failure, and completes with a
  /// [WebFetchException] when [cancel] fires first.
  Future<FetchedWebPage> fetch(
    Uri url, {
    String? acceptLanguage,
    Future<void>? cancel,
  }) async {
    final client = HttpClient()
      ..findProxy = ((_) => 'DIRECT')
      ..connectionFactory = _connect
      ..connectionTimeout = connectTimeout
      ..autoUncompress = true
      ..userAgent = userAgent;
    var stopped = false;
    final stopSignal = Completer<FetchedWebPage>();
    void stop() {
      if (stopped) return;
      stopped = true;
      client.close(force: true);
      // Closing the client can't interrupt a DNS lookup or a connect still
      // inside the connection factory, so the fetch races this signal too.
      stopSignal.completeError(
        const WebFetchException('The page took too long to load.'),
      );
    }

    final timer = Timer(timeout, stop);
    unawaited(cancel?.then((_) => stop()));
    final work = _fetchWith(client, url, acceptLanguage, () => stopped);
    work.ignore();
    stopSignal.future.ignore();

    try {
      return await Future.any([work, stopSignal.future]);
    } finally {
      timer.cancel();
      if (!stopped) {
        stopped = true;
        client.close(force: true);
      }
    }
  }

  Future<FetchedWebPage> _fetchWith(
    HttpClient client,
    Uri url,
    String? acceptLanguage,
    bool Function() stopped,
  ) async {
    try {
      var current = url;
      for (var hop = 0; ; hop++) {
        final request = await client.getUrl(current);
        request.followRedirects = false;
        request.headers
          ..set(
            HttpHeaders.acceptHeader,
            'text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5',
          )
          ..set(HttpHeaders.acceptLanguageHeader, acceptLanguage ?? 'en');
        final response = await request.close();

        if (response.isRedirect) {
          await response.drain<void>();
          final location = response.headers.value(HttpHeaders.locationHeader);
          if (location == null || hop >= maxRedirects) {
            throw const WebFetchException('The page redirected too often.');
          }
          current = Uri.parse(
            normalizePublicWebUrl(current.resolve(location).toString()),
          );
          continue;
        }
        if (response.statusCode != HttpStatus.ok) {
          await response.drain<void>();
          throw WebFetchException(
            'The page returned HTTP ${response.statusCode}.',
            statusCode: response.statusCode,
          );
        }

        final contentType = response.headers.contentType;
        final mimeType = contentType?.mimeType.toLowerCase() ?? 'text/html';
        if (!supportedContentTypes.contains(mimeType)) {
          await response.drain<void>();
          throw WebFetchException(
            'The page is $mimeType, which cannot be read as text.',
          );
        }
        final (bytes, truncated) = await _readBounded(response);
        return FetchedWebPage(
          url: current,
          contentType: mimeType,
          body: _decode(bytes, contentType?.charset),
          truncated: truncated,
        );
      }
    } on WebFetchException {
      rethrow;
    } on FormatException catch (error) {
      throw WebFetchException(error.message);
    } on Exception {
      if (stopped()) {
        throw const WebFetchException('The page took too long to load.');
      }
      throw const WebFetchException('The page could not be reached.');
    }
  }

  Future<ConnectionTask<Socket>> _connect(
    Uri url,
    String? proxyHost,
    int? proxyPort,
  ) async {
    final host = url.host;
    final port = url.hasPort ? url.port : (url.scheme == 'https' ? 443 : 80);
    final addresses = await _vettedAddresses(host);
    final socket = _connectAny(addresses, port).then<Socket>(
      (socket) => url.scheme == 'https'
          ? SecureSocket.secure(socket, host: host)
          : socket,
    );
    return ConnectionTask.fromSocket(socket, () {});
  }

  Future<List<InternetAddress>> _vettedAddresses(String host) async {
    final literal = InternetAddress.tryParse(host);
    final addresses = literal == null ? await _lookup(host) : [literal];
    if (addresses.isEmpty) {
      throw const WebFetchException('The page could not be reached.');
    }
    // Fail closed: a public hostname has no reason to resolve to a private
    // address, so one private answer taints the whole lookup.
    if (!addresses.every(isPublicInternetAddress)) {
      throw const WebFetchException('Web fetch requires a public URL.');
    }
    return addresses;
  }

  Future<Socket> _connectAny(List<InternetAddress> addresses, int port) async {
    Object? lastError;
    for (final address in addresses.take(4)) {
      try {
        return await Socket.connect(address, port, timeout: connectTimeout);
      } on SocketException catch (error) {
        lastError = error;
      }
    }
    throw lastError ?? const SocketException('No address to connect to');
  }

  Future<(List<int>, bool)> _readBounded(HttpClientResponse response) async {
    final bytes = <int>[];
    await for (final chunk in response) {
      final room = maxBytes - bytes.length;
      if (chunk.length >= room) {
        bytes.addAll(chunk.take(room));
        return (bytes, true);
      }
      bytes.addAll(chunk);
    }
    return (bytes, false);
  }

  static String _decode(List<int> bytes, String? charset) {
    switch (charset?.toLowerCase()) {
      case 'iso-8859-1' || 'latin1' || 'latin-1':
        return latin1.decode(bytes);
      case 'windows-1252' || 'cp1252':
        return String.fromCharCodes([
          for (final byte in bytes)
            byte >= 0x80 && byte < 0xa0 ? _cp1252High[byte - 0x80] : byte,
        ]);
      default:
        return utf8.decode(bytes, allowMalformed: true);
    }
  }

  /// Windows-1252's 0x80–0x9F, where it differs from Latin-1 (smart quotes,
  /// dashes, €). Unassigned bytes map to U+FFFD.
  static const List<int> _cp1252High = [
    0x20AC, 0xFFFD, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, //
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0xFFFD, 0x017D, 0xFFFD, //
    0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, //
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0xFFFD, 0x017E, 0x0178, //
  ];
}
