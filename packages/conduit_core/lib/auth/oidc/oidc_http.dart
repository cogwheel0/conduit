import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'package:conduit_core/auth/oidc/oidc_exception.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/network/io/public_health_probe.dart';
import 'package:conduit_core/services/server_tls_http_client_factory.dart';

/// Builds the client for requests to the origin of the Open WebUI address in
/// use: one that trusts what that address trusts, and presents its client
/// certificate.
typedef OidcRouteClientFactory = http.Client Function(ServerConfig route);

/// An identity provider's answer to a form POST: its status, and its body
/// when that was a JSON object.
final class OidcHttpResponse {
  const OidcHttpResponse(this.statusCode, this.json);

  final int statusCode;
  final Map<String, dynamic>? json;

  bool get isSuccess => statusCode >= 200 && statusCode < 300;

  @override
  String toString() => 'OidcHttpResponse($statusCode)';
}

/// Sends a sign-in's requests to its identity provider.
///
/// A client of its own: it sends none of Open WebUI's headers, cookies or
/// bearer, never follows a redirect, gives each request [timeout], and reads
/// at most [maxResponseBytes] of an answer.
///
/// It trusts the system's certificate authorities, and never presents a
/// client certificate, except on exactly the origin of [route], the Open
/// WebUI address in use: an identity provider served there is trusted as
/// that address is, self-signed certificate and client certificate included,
/// as the public health check's same-origin redirects are.
final class OidcHttp {
  OidcHttp({
    ServerConfig? route,
    http.Client? client,
    OidcRouteClientFactory? routeClient,
    this.timeout = const Duration(seconds: 15),
    this.maxResponseBytes = 256 * 1024,
  }) : _route = route,
       _client = client ?? http.Client(),
       _ownsClient = client == null,
       _routeClientFactory = routeClient ?? _serverTlsClient;

  final ServerConfig? _route;
  final http.Client _client;
  final bool _ownsClient;
  final OidcRouteClientFactory _routeClientFactory;
  http.Client? _routeClient;
  bool _closed = false;

  final Duration timeout;
  final int maxResponseBytes;

  /// GETs the JSON object at [uri], answered with 200.
  Future<Map<String, dynamic>> getJson(Uri uri) async {
    final request = http.Request('GET', uri)
      ..headers[HttpHeaders.acceptHeader] = 'application/json';
    final response = await _send(request);
    if (response.statusCode != HttpStatus.ok) {
      throw OidcException(
        _statusFailure(response.statusCode),
        statusCode: response.statusCode,
      );
    }
    final json = response.json;
    if (json == null) {
      throw const OidcException(OidcFailureKind.invalidResponse);
    }
    return json;
  }

  /// POSTs [fields] to [uri] as a form, and returns the answer whatever its
  /// status, but for a redirect.
  Future<OidcHttpResponse> postForm(Uri uri, Map<String, String> fields) {
    final request = http.Request('POST', uri)
      ..headers.addAll(const {
        HttpHeaders.acceptHeader: 'application/json',
        HttpHeaders.contentTypeHeader: 'application/x-www-form-urlencoded',
      })
      ..bodyFields = fields;
    return _send(request);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsClient) _client.close();
    _routeClient?.close();
  }

  Future<OidcHttpResponse> _send(http.Request request) async {
    if (_closed) throw StateError('OidcHttp is closed');
    if (request.url.scheme != 'https') {
      throw const OidcException(OidcFailureKind.insecureEndpoint);
    }
    request.followRedirects = false;
    final clock = Stopwatch()..start();
    try {
      final response = await _clientFor(request.url)
          .send(request)
          .timeout(timeout);
      final status = response.statusCode;
      if (response.isRedirect || (status >= 300 && status < 400)) {
        unawaited(response.stream.listen(null).cancel());
        throw OidcException(OidcFailureKind.redirected, statusCode: status);
      }
      final bytes = await _readBytes(response, timeout - clock.elapsed);
      return OidcHttpResponse(status, _decodeObject(bytes));
    } on OidcException {
      rethrow;
    } on TimeoutException {
      throw const OidcException(OidcFailureKind.timeout);
    } on TlsException {
      throw const OidcException(OidcFailureKind.tls);
    } on SocketException {
      throw const OidcException(OidcFailureKind.network);
    } on HttpException {
      throw const OidcException(OidcFailureKind.network);
    } on http.ClientException {
      throw const OidcException(OidcFailureKind.network);
    }
  }

  http.Client _clientFor(Uri uri) {
    final route = _route;
    if (route == null ||
        !ServerTlsHttpClientFactory.requiresCustomHttpClient(route) ||
        !requestUsesServerConnectivityOrigin(
          uri,
          ServerTlsHttpClientFactory.parseBaseUri(route.url),
        )) {
      return _client;
    }
    try {
      return _routeClient ??= _routeClientFactory(route);
    } on StateError {
      // The address's client certificate could not be loaded.
      throw const OidcException(OidcFailureKind.tls);
    }
  }

  Future<List<int>> _readBytes(
    http.StreamedResponse response,
    Duration remaining,
  ) async {
    final contentLength = response.contentLength;
    if (contentLength != null && contentLength > maxResponseBytes) {
      unawaited(response.stream.listen(null).cancel());
      throw const OidcException(OidcFailureKind.responseTooLarge);
    }
    final bytes = <int>[];
    final iterator = StreamIterator<List<int>>(response.stream);
    var timedOut = false;
    final timer = Timer(
      remaining > Duration.zero ? remaining : Duration.zero,
      () {
        timedOut = true;
        unawaited(iterator.cancel());
      },
    );
    try {
      while (await iterator.moveNext()) {
        if (bytes.length + iterator.current.length > maxResponseBytes) {
          throw const OidcException(OidcFailureKind.responseTooLarge);
        }
        bytes.addAll(iterator.current);
      }
    } finally {
      timer.cancel();
      await iterator.cancel();
    }
    if (timedOut) throw const OidcException(OidcFailureKind.timeout);
    return bytes;
  }
}

/// The failure for an answer with [statusCode] that carried nothing better.
OidcFailureKind _statusFailure(int statusCode) {
  if (statusCode == HttpStatus.tooManyRequests) {
    return OidcFailureKind.rateLimited;
  }
  if (statusCode >= 500) return OidcFailureKind.serverError;
  return OidcFailureKind.unexpectedStatus;
}

/// The failure for a non-2xx answer from an OAuth endpoint, from its status
/// and its OAuth `error` code (RFC 6749, section 5.2).
OidcException oidcErrorResponse(OidcHttpResponse response) {
  final status = response.statusCode;
  final error = response.json?['error'];
  final code = error is String ? error : null;
  if (status == HttpStatus.tooManyRequests || status >= 500) {
    return OidcException(
      _statusFailure(status),
      errorCode: code,
      statusCode: status,
    );
  }
  final kind = switch (code) {
    'invalid_grant' => OidcFailureKind.invalidGrant,
    'invalid_client' || 'unauthorized_client' => OidcFailureKind.clientRejected,
    'temporarily_unavailable' || 'server_error' => OidcFailureKind.serverError,
    null => _statusFailure(status),
    _ => OidcFailureKind.tokenRequestFailed,
  };
  return OidcException(kind, errorCode: code, statusCode: status);
}

Map<String, dynamic>? _decodeObject(List<int> bytes) {
  if (bytes.isEmpty) return null;
  try {
    final decoded = jsonDecode(utf8.decode(bytes));
    return decoded is Map<String, dynamic> ? decoded : null;
  } on FormatException {
    return null;
  }
}

http.Client _serverTlsClient(ServerConfig route) =>
    IOClient(ServerTlsHttpClientFactory.createHttpClient(route));
