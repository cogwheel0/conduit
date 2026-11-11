part of 'hermes_desktop_api_service.dart';

/// A dashboard response, whatever its status.
///
/// Push setup tells "plugin missing" from "plugin installed but not loaded"
/// by the status and body of a 404, which the JSON helpers throw away.
final class HermesDashboardResponse {
  const HermesDashboardResponse(this.status, this.body);

  final int status;
  final String body;

  bool get ok => status >= 200 && status < 300;

  /// The body as JSON, or null when it is not JSON.
  Object? get json {
    if (body.isEmpty) return null;
    try {
      validateHermesJsonSource(body);
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }
}

extension _HermesDesktopRawRest on HermesDesktopApiService {
  /// [method] [path] with the dashboard's own authentication, answering any
  /// status instead of throwing. Sign-in problems still throw, as they do for
  /// every other dashboard request.
  Future<HermesDashboardResponse> _rawRequest(
    String method,
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    int retry = 0,
  }) async {
    final uri = _uri(path, query == null || query.isEmpty ? null : query);
    if (config.desktopAuthKind == HermesDesktopAuthKind.dashboardCookie) {
      if (!hermesDashboardHeadersSupported(
        isIOS: Platform.isIOS,
        accessHeaders: config.accessHeaders,
      )) {
        throw HermesDashboardUnavailable(
          'Dashboard cookie requests with gateway headers are unavailable on iOS.',
        );
      }
      final bridgeFactory = _dashboardBridgeFactory;
      if (bridgeFactory == null) {
        throw StateError(
          'This host has no WebView, so the Hermes dashboard cannot be reached.',
        );
      }
      final bridge = _dashboardBridge ??= bridgeFactory(
        root: _root,
        accessHeaders: config.accessHeaders,
      );
      final response = await bridge.request(
        method,
        uri,
        body: body == null ? null : jsonEncode(body),
      );
      if (response.body.length > kMaxHermesDesktopFrameCharacters) {
        throw const HermesResponseTooLargeException();
      }
      if ((response.status == 401 || response.status == 403) && retry < 2) {
        await bridge.reload();
        return _rawRequest(
          method,
          path,
          body: body,
          query: query,
          retry: retry + 1,
        );
      }
      return HermesDashboardResponse(response.status, response.body);
    }
    // Dio's response stream doesn't pass a cancel on to the connection, so
    // stopping at the limit cancels the request itself.
    final cancel = CancelToken();
    final response = await _dio.request<ResponseBody>(
      uri.toString(),
      data: body,
      cancelToken: cancel,
      options: Options(
        method: method,
        headers: await _headers(authenticated: true),
        // Read as a stream and stopped at the limit, so a huge body is never
        // held whole.
        responseType: ResponseType.stream,
        validateStatus: (_) => true,
        receiveDataWhenStatusError: true,
      ),
    );
    final bytes = await _readDashboardBody(response.data, cancel);
    final status = response.statusCode ?? 0;
    if (status == 401 &&
        retry == 0 &&
        config.desktopAuthKind == HermesDesktopAuthKind.nativePkce) {
      final previous = _nativeTokens;
      final refreshed = await _validNativeTokens(forceRefresh: true);
      if (hermesNativeRefreshAllowsRetry(previous, refreshed)) {
        return _rawRequest(method, path, body: body, query: query, retry: 1);
      }
    }
    return HermesDashboardResponse(
      status,
      utf8.decode(bytes, allowMalformed: true),
    );
  }

  /// [body], up to [kMaxHermesDesktopFrameBytes]. Past that, [cancel] stops
  /// the download.
  Future<List<int>> _readDashboardBody(
    ResponseBody? body,
    CancelToken cancel,
  ) async {
    if (body == null) return const <int>[];
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in body.stream) {
      if (bytes.length + chunk.length > kMaxHermesDesktopFrameBytes) {
        cancel.cancel('The Hermes dashboard answer is too large.');
        throw const HermesResponseTooLargeException();
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }
}
