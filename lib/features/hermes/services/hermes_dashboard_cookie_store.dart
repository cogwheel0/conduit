import '../../../platform/webview_cookie_helper.dart';

import 'package:conduit_core/features/hermes/services/hermes_dashboard_cookie_registry.dart';

/// The WebView side of [HermesDashboardCookieRegistry]: reads the cookies a
/// dashboard sign-in left in the WebView store, and deletes them again, inside
/// [WebViewCookieHelper]'s serialized data queue.
final class HermesDashboardCookieStore {
  const HermesDashboardCookieStore._();

  static int begin(String origin) =>
      HermesDashboardCookieRegistry.begin(origin);

  static Future<Set<String>> snapshot(String origin) =>
      WebViewCookieHelper.cookieIdentitiesForOrigin(origin);

  static Future<void> register(
    String origin, {
    required int generation,
    Set<String> baseline = const {},
    Set<String> retainedNames = const {},
  }) => WebViewCookieHelper.runSerializedDataOperation(() async {
    if (!HermesDashboardCookieRegistry.isCurrent(origin, generation)) return;
    final identities = hermesDashboardCookieIdentityDelta(
      current: await snapshot(origin),
      baseline: baseline,
      retainedNames: retainedNames,
    );
    await HermesDashboardCookieRegistry.record(
      origin,
      identities: identities,
      retainedNames: retainedNames,
    );
  });

  static Future<bool> clear(String origin) async {
    if (!HermesDashboardCookieRegistry.invalidate(origin)) return true;
    return WebViewCookieHelper.runSerializedDataOperation(() async {
      final success =
          await WebViewCookieHelper.deleteCookieIdentitiesForOriginUnlocked(
            origin,
            HermesDashboardCookieRegistry.identitiesFor(origin),
          );
      if (success) await HermesDashboardCookieRegistry.forget(origin);
      return success;
    });
  }
}
