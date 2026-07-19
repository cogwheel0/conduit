import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../persistence/persistence_keys.dart';
import '../persistence/preferences_store.dart';
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

/// Deletes cookies and verifies the empty-store postcondition when the
/// platform reports `false`. Android uses `false` both for "nothing removed"
/// and some failures, so the boolean alone is not a safe freshness boundary.
@visibleForTesting
Future<bool> deleteAllWebViewCookiesWithVerification({
  required Future<bool> Function() deleteAllCookies,
  required Future<int> Function() remainingCookieCount,
}) async {
  final bool deleted;
  try {
    deleted = await deleteAllCookies();
  } catch (_) {
    return false;
  }
  if (deleted) return true;
  try {
    return await remainingCookieCount() == 0;
  } on UnimplementedError {
    // Android cannot enumerate cookies (getAllCookies is unimplemented in
    // flutter_inappwebview_android), and its `false` from removeAllCookies
    // means "no cookies were removed" — the normal result for an already-empty
    // store. Treating that as failure would block every fresh SSO sign-in and
    // permanently arm the incomplete-logout fence on Android, so when
    // verification is unavailable the non-throwing delete is the postcondition.
    return true;
  } catch (_) {
    return false;
  }
}

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
  static Future<void> _dataOperationTail = Future<void>.value();
  static bool _fullClearRequired = false;
  static int _fullClearGeneration = 0;

  static Future<T> _serializeDataOperation<T>(Future<T> Function() operation) {
    final result = _dataOperationTail.then<T>((_) => operation());
    // A failed platform operation must not strand later auth flows. Individual
    // callers still receive the original result/error while the shared barrier
    // advances after either outcome.
    _dataOperationTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  /// Waits until every cookie/storage mutation requested before this call has
  /// completed. Proxy auth uses this before constructing its WebView so a late
  /// logout purge cannot erase the new flow's cookies or local storage.
  static Future<void> waitForPendingDataOperations() => _dataOperationTail;

  /// True when a logout full-data purge failed in this process, or its durable
  /// incomplete-logout marker still requires recovery after a restart.
  static bool get requiresSuccessfulFullClear =>
      _fullClearRequired ||
      PreferencesStore.getBool(PreferenceKeys.incompleteLogoutFence) == true;

  /// Establishes a successful full-data boundary before a new auth WebView is
  /// created. Ordinary proxy navigation preserves cookies; only a prior failed
  /// or incomplete logout causes this method to purge them.
  static Future<bool> ensurePendingLogoutDataCleared({
    @visibleForTesting Future<bool> Function()? clearAllDataForTesting,
  }) {
    if (clearAllDataForTesting == null && !isWebViewSupported) {
      return Future<bool>.value(true);
    }
    // Claim a currently-known requirement before queueing so an older purge
    // cannot release the flag while this newer boundary is still pending.
    int? clearGeneration = requiresSuccessfulFullClear
        ? _claimFullClearRequirement()
        : null;
    return _serializeDataOperation(() async {
      if (!requiresSuccessfulFullClear) return true;
      clearGeneration ??= _claimFullClearRequirement();
      final success =
          await (clearAllDataForTesting ?? _clearAllWebViewDataUnlocked)();
      // This helper owns only the serialized WebView boundary. The durable
      // incomplete-logout fence is shared with secure-storage cleanup and must
      // be mutated exclusively through IncompleteLogoutFence's generation-
      // checked queue. AuthStateManager clears it after both cleanup domains
      // succeed; an older WebView completion must never erase a newer logout.
      // A full clear requested while this recovery was running owns the flag.
      // Its queued completion is the only one allowed to release that newer
      // requirement.
      if (clearGeneration == _fullClearGeneration) {
        _fullClearRequired = !success;
      }
      return success;
    });
  }

  static int _claimFullClearRequirement() {
    _fullClearRequired = true;
    return ++_fullClearGeneration;
  }

  static Future<bool> _requestFullClear(Future<bool> Function() clearAllData) {
    // Claim the flag synchronously, before serialisation can queue this clear
    // behind an older operation. Only this newest generation may release it.
    final clearGeneration = _claimFullClearRequirement();
    return _serializeDataOperation(() async {
      final success = await clearAllData();
      if (clearGeneration == _fullClearGeneration) {
        _fullClearRequired = !success;
      }
      return success;
    });
  }

  /// Clears all WebView cookies.
  ///
  /// Returns true if cookies were cleared, false if not supported or failed.
  /// Checks platform support internally, so safe to call on any platform.
  static Future<bool> clearCookies() async {
    // Only supported on mobile platforms
    if (!isWebViewSupported) return false;

    return _serializeDataOperation(_clearCookiesUnlocked);
  }

  /// Clears persistent website storage without changing the logout marker.
  /// Fresh SSO sessions use this together with verified cookie deletion so a
  /// prior identity cannot survive in local/session storage or IndexedDB.
  static Future<bool> clearWebsiteData() async {
    if (!isWebViewSupported) return false;
    return _serializeDataOperation(() async {
      try {
        await _clearWebStorage();
        DebugLogger.auth('WebView storage cleared', scope: 'auth/webview');
        return true;
      } catch (error) {
        DebugLogger.warning(
          'webview-storage-clear-failed',
          scope: 'auth/webview',
          data: {'errorType': error.runtimeType.toString()},
        );
        return false;
      }
    });
  }

  static Future<bool> _clearCookiesUnlocked() {
    final manager = CookieManager.instance();
    return deleteAllWebViewCookiesWithVerification(
      deleteAllCookies: manager.deleteAllCookies,
      remainingCookieCount: () async => (await manager.getAllCookies()).length,
    );
  }

  /// Clears all WebView data including cookies, localStorage, and cache.
  ///
  /// This should be called on logout to ensure SSO sessions are fully cleared.
  /// Returns true if all data was cleared successfully.
  static Future<bool> clearAllWebViewData() async {
    if (!isWebViewSupported) return false;
    return _requestFullClear(_clearAllWebViewDataUnlocked);
  }

  static Future<bool> _clearAllWebViewDataUnlocked() async {
    var success = true;

    // Clear cookies and verify the postcondition. A `false` platform result can
    // mean either an already-empty store or a failure.
    final cookiesCleared = await _clearCookiesUnlocked();
    if (cookiesCleared) {
      DebugLogger.auth('WebView cookies cleared', scope: 'auth/webview');
    } else {
      DebugLogger.warning('webview-cookie-clear-failed', scope: 'auth/webview');
      success = false;
    }

    // Clear localStorage and other persistent website data.
    try {
      await _clearWebStorage();
      DebugLogger.auth('WebView storage cleared', scope: 'auth/webview');
    } catch (e) {
      DebugLogger.warning(
        'webview-storage-clear-failed',
        scope: 'auth/webview',
        data: {'errorType': e.runtimeType.toString()},
      );
      success = false;
    }

    // Clear the shared WebView cache separately so unsupported storage APIs
    // don't skip cache removal on supported platforms.
    try {
      await InAppWebViewController.clearAllCache();
      DebugLogger.auth('WebView cache cleared', scope: 'auth/webview');
    } catch (e) {
      DebugLogger.warning(
        'webview-cache-clear-failed',
        scope: 'auth/webview',
        data: {'errorType': e.runtimeType.toString()},
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

    return _serializeDataOperation(() async {
      try {
        final url = await controller.getUrl();
        if (url == null) return <String, String>{};

        final cookies = await CookieManager.instance().getCookies(
          url: url,
          webViewController: controller,
        );
        final cookieMap = <String, String>{};
        for (final cookie in cookies) {
          cookieMap[cookie.name] = cookie.value;
        }

        DebugLogger.auth(
          'Retrieved ${cookieMap.length} cookies from WebView',
          scope: 'auth/webview',
        );
        return cookieMap;
      } catch (e) {
        DebugLogger.warning(
          'webview-get-cookies-failed',
          scope: 'auth/webview',
          data: {'errorType': e.runtimeType.toString()},
        );
        return <String, String>{};
      }
    });
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

@visibleForTesting
Future<T> serializeWebViewDataOperationForTesting<T>(
  Future<T> Function() operation,
) => WebViewCookieHelper._serializeDataOperation(operation);

@visibleForTesting
Future<bool> requestFullWebViewClearForTesting(
  Future<bool> Function() clearAllData,
) => WebViewCookieHelper._requestFullClear(clearAllData);

@visibleForTesting
bool get webViewFullClearRequiredForTesting =>
    WebViewCookieHelper._fullClearRequired;

@visibleForTesting
Future<void> resetWebViewCookieHelperForTesting() async {
  await WebViewCookieHelper._dataOperationTail;
  WebViewCookieHelper._dataOperationTail = Future<void>.value();
  WebViewCookieHelper._fullClearRequired = false;
  WebViewCookieHelper._fullClearGeneration = 0;
}
