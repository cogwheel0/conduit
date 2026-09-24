import 'package:conduit_core/conduit_core.dart';

import 'webview_cookie_helper.dart';
import '../features/hermes/services/hermes_dashboard_cookie_store.dart';

/// The Flutter app's [CookieJarPort].
///
/// Delegates to `WebViewCookieHelper`, now beside it in `lib/platform`:
/// it drives `flutter_inappwebview`, so it never belonged under `lib/core`.
/// Serializing purges,
/// claiming generation-checked clear requirements and coordinating with the
/// durable incomplete-logout fence is WebView bookkeeping, not business
/// logic. The port is the seam; the helper is this host's implementation of
/// it, and Electron will have a very different one.
class FlutterCookieJar implements CookieJarPort {
  const FlutterCookieJar();

  @override
  bool get isSupported => isWebViewSupported;

  @override
  Future<Set<String>> identitiesFor(String origin) =>
      WebViewCookieHelper.cookieIdentitiesForOrigin(origin);

  @override
  Future<bool> clearForOrigin(String origin) =>
      HermesDashboardCookieStore.clear(origin);

  @override
  Future<bool> clearCookies() => WebViewCookieHelper.clearCookies();

  @override
  Future<bool> clearWebsiteData() => WebViewCookieHelper.clearWebsiteData();

  @override
  Future<bool> clearAll() => WebViewCookieHelper.clearAllWebViewData();

  @override
  Future<bool> completePendingClear() =>
      WebViewCookieHelper.ensurePendingLogoutDataCleared();
}
