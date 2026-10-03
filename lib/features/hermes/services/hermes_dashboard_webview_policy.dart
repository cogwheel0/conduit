import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'package:conduit_core/features/hermes/services/hermes_dashboard_access.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_webview_rules.dart';

final class HermesDashboardWebViewPolicy {
  HermesDashboardWebViewPolicy({
    required this.root,
    required this.accessHeaders,
  }) : _resourceClient = Dio(
         BaseOptions(
           connectTimeout: const Duration(seconds: 15),
           receiveTimeout: const Duration(seconds: 30),
           followRedirects: false,
           validateStatus: (_) => true,
         ),
       );

  final Uri root;
  final Map<String, String> accessHeaders;
  final Dio _resourceClient;

  bool get supported => hermesDashboardHeadersSupported(
    isIOS: defaultTargetPlatform == TargetPlatform.iOS,
    accessHeaders: accessHeaders,
  );

  bool isExact(Uri target) => hermesDashboardIsExactOrigin(target, root);

  Map<String, String> sameOriginHeaders(Map<String, dynamic>? headers) =>
      hermesDashboardSameOriginHeaders(headers, accessHeaders);

  Map<String, String> crossOriginHeaders(Map<String, String>? headers) =>
      hermesHeadersWithoutAccessCredentials(headers ?? const {}, accessHeaders);

  /// The page's fetch/XHR header script (core's
  /// [hermesDashboardRequestHeaderScript]) for non-GET dashboard calls, run
  /// only on the dashboard's origin. GETs get the headers from
  /// [interceptSubresource]. The values never become readable by the page:
  /// no inappwebview fetch/XHR interceptor (which hands the modified request
  /// back to page JavaScript) and no script in other origins' documents.
  List<UserScript> get userScripts => accessHeaders.isEmpty
      ? const []
      : [
          UserScript(
            source: hermesDashboardRequestHeaderScript(
              root: root,
              accessHeaders: accessHeaders,
            ),
            injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
            allowedOriginRules: {root.origin},
          ),
        ];

  Future<WebResourceResponse?> interceptSubresource(
    WebResourceRequest request,
  ) async {
    final target = request.url.uriValue;
    if (!hermesDashboardInterceptsSubresource(
      method: request.method,
      isMainFrame: request.isForMainFrame == true,
      target: target,
      root: root,
    )) {
      return null;
    }
    late final Response<List<int>> response;
    try {
      final cookies = await CookieManager.instance().getCookies(
        url: request.url,
      );
      response = await _resourceClient.get<List<int>>(
        target.toString(),
        options: Options(
          responseType: ResponseType.bytes,
          headers: {
            ...sameOriginHeaders(request.headers),
            if (cookies.isNotEmpty)
              'Cookie': cookies
                  .map((cookie) => '${cookie.name}=${cookie.value}')
                  .join('; '),
          },
        ),
      );
    } catch (_) {
      return WebResourceResponse(
        data: Uint8List(0),
        contentType: 'text/plain',
        contentEncoding: 'utf-8',
        statusCode: 502,
        reasonPhrase: 'Bad Gateway',
      );
    }
    final status = response.statusCode ?? 500;
    if (status >= 300 && status < 400) return null;
    final contentType = response.headers.value(Headers.contentTypeHeader);
    final charset = contentType == null
        ? null
        : RegExp(
            r'charset=([^;\s]+)',
            caseSensitive: false,
          ).firstMatch(contentType)?.group(1);
    return WebResourceResponse(
      data: Uint8List.fromList(response.data ?? const []),
      contentType: contentType?.split(';').first ?? 'application/octet-stream',
      contentEncoding: charset,
      statusCode: status,
      reasonPhrase: status < 400 ? 'OK' : 'Error',
      headers: {
        for (final entry in response.headers.map.entries)
          if (entry.key.toLowerCase() != 'set-cookie')
            entry.key: entry.value.join(', '),
      },
    );
  }

  void close() => _resourceClient.close(force: true);
}
