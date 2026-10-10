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
        throw StateError(
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
    final response = await _dio.request<List<int>>(
      uri.toString(),
      data: body,
      options: Options(
        method: method,
        headers: await _headers(authenticated: true),
        responseType: ResponseType.bytes,
        validateStatus: (_) => true,
        receiveDataWhenStatusError: true,
      ),
    );
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
    final bytes = response.data ?? const <int>[];
    if (bytes.length > kMaxHermesDesktopFrameBytes) {
      throw const HermesResponseTooLargeException();
    }
    return HermesDashboardResponse(
      status,
      utf8.decode(bytes, allowMalformed: true),
    );
  }
}
