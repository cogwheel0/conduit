import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../utils/debug_logger.dart';

/// Native cookie manager for accessing cookies from the platform's cookie store.
///
/// On iOS, this accesses WKHTTPCookieStore (shared with WKWebView).
/// On Android, this accesses CookieManager (shared with WebView).
///
/// This is necessary because dart:io HttpClient has its own isolated cookie
/// store that doesn't share with WebView.
class NativeCookieManager {
  static const _channel = MethodChannel('com.qonduit.app/cookies');

  /// Gets all cookies for a given URL from the native cookie store.
  ///
  /// Returns a map of cookie name -> value.
  /// Returns empty map on web or if native method fails.
  static Future<Map<String, String>> getCookiesForUrl(String url) async {
    if (kIsWeb) return {};

    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'getCookies',
        {'url': url},
      );

      if (result == null) return {};

      final cookies = <String, String>{};
      for (final entry in result.entries) {
        cookies[entry.key.toString()] = entry.value.toString();
      }

      DebugLogger.auth('Retrieved ${cookies.length} cookies from native store');
      return cookies;
    } on MissingPluginException {
      // Platform channels not implemented - fall back gracefully
      DebugLogger.log(
        'Native cookie manager not available on this platform',
        scope: 'auth/cookies',
      );
      return {};
    } catch (e) {
      DebugLogger.warning(
        'Failed to get native cookies',
        scope: 'auth/cookies',
        data: {'error': e.toString()},
      );
      return {};
    }
  }

  /// Formats cookies as a Cookie header string.
  static String formatCookieHeader(Map<String, String> cookies) {
    if (cookies.isEmpty) return '';
    return cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }
}


