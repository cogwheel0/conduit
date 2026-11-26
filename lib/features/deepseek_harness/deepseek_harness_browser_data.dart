import 'dart:async';
import 'dart:convert';

import 'package:conduit_core/features/deepseek_harness/deepseek_harness.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/webview_cookie_helper.dart';

class HarnessCleanupException implements Exception {
  const HarnessCleanupException();
}

final deepSeekHarnessBrowserDataProvider = Provider(
  (ref) => HarnessBrowserData(),
);

class HarnessBrowserData {
  HarnessBrowserData([this._cookies = CookieManager.instance]);

  final CookieManager Function() _cookies;

  // The shared cookie jar can also be changed by a closing workspace or
  // an Open WebUI sign-in performed while this page is opening.
  Future<void> _enqueue(Future<bool> Function() change) =>
      WebViewCookieHelper.runSerializedDataOperation(() async {
        if (!await change()) throw StateError('Cookie store unavailable');
      });

  Future<void> install(DeepSeekHarnessConnection connection) => _enqueue(
    () => _cookies().setCookie(
      url: WebUri.uri(connection.root),
      name: connection.cookieName,
      value: connection.cookieValue,
      path: connection.cookiePath,
      isHttpOnly: true,
      isSecure: connection.root.scheme == 'https',
      sameSite: HTTPCookieSameSitePolicy.STRICT,
    ),
  );

  Future<void> remove(
    DeepSeekHarnessConnection connection,
  ) => _enqueue(() async {
    final manager = _cookies();
    final url = WebUri.uri(connection.root);
    final ios = defaultTargetPlatform == TargetPlatform.iOS;
    // Editing disposes the workspace, so its session cookie may already
    // have gone. WebKit returns false in that case. Check the postcondition.
    await manager.deleteCookie(
      url: url,
      name: connection.cookieName,
      path: connection.cookiePath,
      domain: ios ? connection.root.host : null,
    );
    return !(await manager.getCookies(url: url)).any(
      (cookie) =>
          cookie.name == connection.cookieName &&
          webViewCookieBelongsToExactHost(
            cookie.domain,
            connection.root.host,
          ) &&
          (cookie.path == connection.cookiePath ||
              // Older Android WebViews omit path and domain in cookie reads.
              (cookie.path == null && cookie.value == connection.cookieValue)),
    );
  });

  Future<void> forget(DeepSeekHarnessConnection previous) async {
    try {
      await remove(previous);
      await WebViewCookieHelper.runSerializedDataOperation(
        () => _clearLocalStorage(previous.root),
      );
    } catch (_) {
      throw const HarnessCleanupException();
    }
  }

  // Native WebKit's data records group multiple origins under one domain.
  // An empty, offline document can remove just Harness's keys, even after
  // a restart, without touching other apps hosted on the same server.
  Future<void> _clearLocalStorage(Uri root) async {
    final cleared = Completer<bool>();
    final view = HeadlessInAppWebView(
      initialData: InAppWebViewInitialData(
        data: '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'">',
        baseUrl: WebUri.uri(root),
        historyUrl: WebUri.uri(root),
      ),
      initialSettings: InAppWebViewSettings(
        javaScriptBridgeEnabled: false,
        javaScriptCanOpenWindowsAutomatically: false,
        allowFileAccess: false,
        allowContentAccess: false,
        sharedCookiesEnabled: false,
        thirdPartyCookiesEnabled: false,
      ),
      onLoadStop: (controller, _) async {
        if (cleared.isCompleted) return;
        try {
          final result = await controller.evaluateJavascript(
            source:
                '''
(() => {
  if (window.origin !== ${jsonEncode(root.origin)}) return false;
  for (const key of Object.keys(localStorage)) {
    if (key.startsWith('dsh.')) localStorage.removeItem(key);
  }
  return true;
})()
''',
          );
          if (!cleared.isCompleted) cleared.complete(result == true);
        } catch (_) {
          if (!cleared.isCompleted) cleared.complete(false);
        }
      },
    );
    try {
      await view.run();
      final ok = await cleared.future.timeout(const Duration(seconds: 10));
      if (!ok) throw const HarnessCleanupException();
    } finally {
      await view.dispose();
    }
  }
}
