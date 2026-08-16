import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../core/auth/webview_origin.dart';

Map<String, String> hermesHeadersWithoutAccessCredentials(
  Map<String, String> headers,
  Map<String, String> accessHeaders,
) {
  final reserved = accessHeaders.keys.map((name) => name.toLowerCase()).toSet();
  return {
    for (final entry in headers.entries)
      if (!reserved.contains(entry.key.toLowerCase())) entry.key: entry.value,
  };
}

bool hermesDashboardHeadersSupported({
  required TargetPlatform platform,
  required Map<String, String> accessHeaders,
}) => platform != TargetPlatform.iOS || accessHeaders.isEmpty;

({bool allowed, bool leftDashboard, bool returnedToDashboard})
hermesDashboardNavigationTransition({
  required Uri target,
  required Uri dashboardRoot,
  required bool leftDashboard,
  required bool returnedToDashboard,
}) {
  final exact = webViewUrlHasExactServerOrigin(
    target.toString(),
    dashboardRoot.toString(),
  );
  if (exact) {
    return (
      allowed: true,
      leftDashboard: leftDashboard,
      returnedToDashboard: returnedToDashboard || leftDashboard,
    );
  }
  final allowed = !returnedToDashboard && target.scheme == 'https';
  return (
    allowed: allowed,
    leftDashboard: leftDashboard || allowed,
    returnedToDashboard: returnedToDashboard,
  );
}

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
    platform: defaultTargetPlatform,
    accessHeaders: accessHeaders,
  );

  bool isExact(Uri target) =>
      webViewUrlHasExactServerOrigin(target.toString(), root.toString());

  Map<String, String> sameOriginHeaders(Map<String, dynamic>? headers) => {
    for (final entry in (headers ?? const {}).entries)
      entry.key: entry.value.toString(),
    ...accessHeaders,
  };

  Map<String, String> crossOriginHeaders(Map<String, String>? headers) =>
      hermesHeadersWithoutAccessCredentials(headers ?? const {}, accessHeaders);

  String get bootstrapScript {
    final origin = jsonEncode(root.origin);
    final headers = jsonEncode(accessHeaders);
    return '''(() => {
    const dashboardOrigin = $origin;
    const accessHeaders = $headers;
    const nativeFetch = window.fetch.bind(window);
    const secure = async (element) => {
      const tag = element.tagName;
      const attribute = tag === 'LINK' ? 'href' : 'src';
      if (!['SCRIPT', 'LINK', 'IMG', 'IFRAME'].includes(tag) ||
          element.dataset.hermesHeadersApplied === '1') return;
      const raw = element.getAttribute(attribute);
      if (!raw) return;
      const target = new URL(raw, document.baseURI);
      if (target.origin !== dashboardOrigin) return;
      element.dataset.hermesHeadersApplied = '1';
      const response = await nativeFetch(target.href, {
        headers: accessHeaders,
        credentials: 'include',
        redirect: 'error'
      });
      if (!response.ok) return;
      let blob;
      if (tag === 'IFRAME') {
        const html = await response.text();
        blob = new Blob([
          '<base href="' + target.href.replace(/"/g, '&quot;') + '">',
          html
        ], {type: 'text/html'});
      } else if (tag === 'LINK') {
        const css = (await response.text()).replace(
          /url\\(\\s*(['"]?)(?!data:|blob:|https?:|\\/\\/|#)([^'"\\)]+)\\1\\s*\\)/gi,
          (_, quote, value) => 'url(' + quote + new URL(value, target.href).href + quote + ')'
        ).replace(
          /@import\\s+(['"])(?!data:|blob:|https?:|\\/\\/)([^'"]+)\\1/gi,
          (_, quote, value) => '@import ' + quote + new URL(value, target.href).href + quote
        );
        blob = new Blob([css], {type: 'text/css'});
      } else {
        blob = await response.blob();
      }
      element.setAttribute(attribute, URL.createObjectURL(blob));
    };
    const scan = (node) => {
      if (!(node instanceof Element)) return;
      void secure(node);
      for (const child of node.querySelectorAll('script[src],link[href],img[src],iframe[src]')) {
        void secure(child);
      }
    };
    new MutationObserver((records) => {
      for (const record of records) {
        for (const node of record.addedNodes) scan(node);
      }
    }).observe(document, {childList: true, subtree: true});
    scan(document.documentElement);
  })();''';
  }

  Future<WebResourceResponse?> interceptSubresource(
    WebResourceRequest request,
  ) async {
    final target = request.url.uriValue;
    if (request.isForMainFrame == true ||
        request.method?.toUpperCase() != 'GET' ||
        !isExact(target)) {
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
