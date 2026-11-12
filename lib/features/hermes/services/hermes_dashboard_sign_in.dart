import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_webview_rules.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/native_sheet_bridge.dart';
import '../../../core/utils/current_localizations.dart';
import '../../../shared/services/navigation_service.dart';
import '../views/hermes_dashboard_auth_page.dart';
import 'hermes_dashboard_cookie_store.dart';

final hermesDashboardSignInProvider = Provider<HermesDashboardSignIn>(
  (ref) => const HermesDashboardSignIn(),
);

/// Signs in to a Hermes Desktop Gateway's dashboard, whose session lives in
/// the web view's cookies. Passwords and identity-provider credentials stay
/// inside the web view and are never read by Conduit.
class HermesDashboardSignIn {
  const HermesDashboardSignIn();

  /// Signs in to [config]'s dashboard. Over the native Settings sheet the
  /// sign-in opens in a web view of the sheet's own; elsewhere it is the
  /// Flutter page. Answers whether the dashboard says the user is signed in.
  Future<bool> signIn(HermesConfig config) async {
    final bridge = NativeSheetBridge.instance;
    // A dashboard behind access headers is never reached on iOS (its web
    // view cannot add them), which the Flutter page says.
    if (bridge.settingsSheetOpen && config.accessHeaders.isEmpty) {
      return _signInOverSheet(bridge, config);
    }
    final context = NavigationService.context;
    if (context == null || !context.mounted) return false;
    return HermesDashboardAuthPage.open(context, config);
  }

  Future<bool> _signInOverSheet(
    NativeSheetBridge bridge,
    HermesConfig config,
  ) async {
    final root = hermesDashboardRoot(config.baseUrl);
    final origin = root.toString();
    final generation = HermesDashboardCookieStore.begin(origin);
    Set<String> baseline;
    try {
      baseline = await HermesDashboardCookieStore.snapshot(origin);
    } catch (_) {
      baseline = const {};
    }
    // The dashboard may send the user to an identity provider once; back on
    // the dashboard, it may not leave again.
    var leftDashboard = false;
    var returnedToDashboard = false;
    final l10n = currentAppLocalizations();
    final signedIn = await bridge.presentWebSignIn(
      title: l10n.hermesDashboardSignInTitle,
      cancelLabel: l10n.cancel,
      reloadLabel: l10n.retry,
      url: hermesDashboardLoginUrl(root).toString(),
      checkScript: kHermesDashboardSignInCheckScript,
      checkUrl: hermesDashboardAuthCheckUrl(root).toString(),
      loadFailedMessage: l10n.hermesDashboardSignInLoadFailed,
      allowsNavigation: (url) {
        final target = Uri.tryParse(url);
        if (target == null) return false;
        final transition = hermesDashboardNavigationTransition(
          target: target,
          dashboardRoot: root,
          leftDashboard: leftDashboard,
          returnedToDashboard: returnedToDashboard,
        );
        leftDashboard = transition.leftDashboard;
        returnedToDashboard = transition.returnedToDashboard;
        return transition.allowed;
      },
      checksPage: (url) => hermesDashboardShouldCheckSignIn(
        loaded: Uri.tryParse(url),
        root: root,
        checking: false,
      ),
    );
    if (!signedIn) return false;
    try {
      await HermesDashboardCookieStore.register(
        origin,
        generation: generation,
        baseline: baseline,
        retainedNames: kHermesDashboardRetainedCookieNames,
      );
    } catch (error) {
      DebugLogger.warning(
        'dashboard-cookie-register-failed',
        scope: 'hermes/desktop/auth',
        data: {'errorType': error.runtimeType.toString()},
      );
    }
    return true;
  }
}
