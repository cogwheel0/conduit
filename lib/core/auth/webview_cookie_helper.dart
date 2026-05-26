import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../utils/debug_logger.dart';

final Set<WebsiteDataType> _appleWebsiteDataTypes = <WebsiteDataType>{
  WebsiteDataType.WKWebsiteDataTypeLocalStorage,
  WebsiteDataType.WKWebsiteDataTypeSessionStorage,
  WebsiteDataType.WKWebsiteDataTypeIndexedDBDatabases,
  WebsiteDataType.WKWebsiteDataTypeWebSQLDatabases,
  WebsiteDataType.WKWebsiteDataTypeOfflineWebApplicationCache,
  WebsiteDataType.WKWebsiteDataTypeFetchCache,
  WebsiteDataType.WKWebsiteDataTypeServiceWorkerRegistrations,
};

/// Check if WebView is supported on the current platform.
///
/// Proxy/SSO auth WebViews are only supported on iOS and Android.
bool get isWebViewSupported =>
    !kIsWeb && (Platform.isIOS || Platform.isAndroid);

/// Helper for managing WebView data and cookies.
///
/// This is isolated in its own file to prevent platform coupling issues
/// when the WebView package isn't available.
class WebViewCookieHelper {
  /// Clears all WebView cookies.
  ///
  /// Returns true if cookies were cleared, false if not supported or failed.
  /// Checks platform support internally, so safe to call on any platform.
  static Future<bool> clearCookies() async {
    // Only supported on mobile platforms
    if (!isWebViewSupported) return false;

    try {
      return await CookieManager.instance().deleteAllCookies();
    } catch (e) {
      // Silently fail - WebView may not be available
      return false;
    }
  }

  /// Clears all WebView data including cookies, localStorage, and cache.
  ///
  /// This should be called on logout to ensure SSO sessions are fully cleared.
  /// Returns true if all data was cleared successfully.
  static Future<bool> clearAllWebViewData() async {
    if (!isWebViewSupported) return false;

    var success = true;

    // Clear cookies
    try {
      await CookieManager.instance().deleteAllCookies();
      DebugLogger.auth('WebView cookies cleared');
    } catch (e) {
      DebugLogger.warning(
        'webview-cookie-clear-failed',
        scope: 'auth/webview',
        data: {'error': e.toString()},
      );
      success = false;
    }

    // Clear localStorage and other persistent website data.
    try {
      await _clearWebStorage();
      DebugLogger.auth('WebView storage cleared');
    } catch (e) {
      DebugLogger.warning(
        'webview-storage-clear-failed',
        scope: 'auth/webview',
        data: {'error': e.toString()},
      );
      success = false;
    }

    // Clear the shared WebView cache separately so unsupported storage APIs
    // don't skip cache removal on supported platforms.
    try {
      await InAppWebViewController.clearAllCache();
      DebugLogger.auth('WebView cache cleared');
    } catch (e) {
      DebugLogger.warning(
        'webview-cache-clear-failed',
        scope: 'auth/webview',
        data: {'error': e.toString()},
      );
      success = false;
    }

    return success;
  }

  static Future<void> _clearWebStorage() async {
    if (Platform.isAndroid) {
      await WebStorageManager.instance().deleteAllData();
      return;
    }

    if (Platform.isIOS) {
      await WebStorageManager.instance().removeDataModifiedSince(
        dataTypes: _appleWebsiteDataTypes,
        date: DateTime.fromMillisecondsSinceEpoch(0),
      );
      return;
    }
  }

  /// Gets cookies from the current WebView cookie store.
  ///
  /// This can be used to extract session cookies set by proxy authentication
  /// and pass them to HTTP clients like Dio.
  ///
  /// Returns a map of cookie names to values, or empty map if unavailable.
  static Future<Map<String, String>> getCookiesFromController(
    InAppWebViewController controller,
  ) async {
    if (!isWebViewSupported) return {};

    try {
      final url = await controller.getUrl();
      if (url == null) return {};

      final cookies = await CookieManager.instance().getCookies(
        url: url,
        webViewController: controller,
      );
      final cookieMap = <String, String>{};
      for (final cookie in cookies) {
        cookieMap[cookie.name] = cookie.value;
      }

      DebugLogger.auth('Retrieved ${cookieMap.length} cookies from WebView');
      return cookieMap;
    } catch (e) {
      DebugLogger.warning(
        'webview-get-cookies-failed',
        scope: 'auth/webview',
        data: {'error': e.toString()},
      );
      return {};
    }
  }

  /// Formats cookies as a Cookie header string.
  ///
  /// This converts a map of cookie names to values into a properly formatted
  /// Cookie header that can be sent with HTTP requests.
  static String formatCookieHeader(Map<String, String> cookies) {
    if (cookies.isEmpty) return '';
    return cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }
}

@visibleForTesting
Set<WebsiteDataType> get appleWebsiteDataTypesForTesting =>
    _appleWebsiteDataTypes;
