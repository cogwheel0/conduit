import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:webview_flutter_plus/webview_flutter_plus.dart';

import '../utils/debug_logger.dart';

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
      return await WebViewCookieManager().clearCookies();
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
      await WebViewCookieManager().clearCookies();
      DebugLogger.auth('WebView cookies cleared');
    } catch (e) {
      DebugLogger.warning(
        'webview-cookie-clear-failed',
        scope: 'auth/webview',
        data: {'error': e.toString()},
      );
      success = false;
    }

    // Clear localStorage and cache using a temporary controller
    try {
      final controller = WebViewControllerPlus();
      await controller.clearLocalStorage();
      await controller.clearCache();
      DebugLogger.auth('WebView localStorage and cache cleared');
    } catch (e) {
      DebugLogger.warning(
        'webview-storage-clear-failed',
        scope: 'auth/webview',
        data: {'error': e.toString()},
      );
      success = false;
    }

    return success;
  }

  /// Gets cookies from a WebView controller via JavaScript.
  ///
  /// This can be used to extract session cookies set by proxy authentication
  /// and pass them to HTTP clients like Dio.
  ///
  /// Note: Only works for cookies without the HttpOnly flag.
  /// For HttpOnly cookies, iOS/Android platforms may share cookies
  /// automatically through the shared cookie store.
  ///
  /// Returns a map of cookie names to values, or empty map if unavailable.
  static Future<Map<String, String>> getCookiesFromController(
    WebViewControllerPlus controller,
  ) async {
    if (!isWebViewSupported) return {};

    try {
      final result = await controller.runJavaScriptReturningResult(
        'document.cookie',
      );

      final cookieString = result.toString();
      // Remove surrounding quotes if present
      final cleaned = cookieString.startsWith('"') && cookieString.endsWith('"')
          ? cookieString.substring(1, cookieString.length - 1)
          : cookieString;

      if (cleaned.isEmpty || cleaned == 'null') return {};

      final cookieMap = <String, String>{};
      final pairs = cleaned.split(';');
      for (final pair in pairs) {
        final trimmed = pair.trim();
        final idx = trimmed.indexOf('=');
        if (idx > 0) {
          final name = trimmed.substring(0, idx).trim();
          final value = trimmed.substring(idx + 1).trim();
          cookieMap[name] = value;
        }
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
