import 'package:conduit/l10n/app_localizations.dart';
import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';

import '../widgets/themed_dialogs.dart';

import 'package:conduit_core/navigation/routes.dart';

export 'package:conduit_core/navigation/routes.dart' show RouteNames, Routes;

/// Marks routes opened after a native sheet dismisses so Flutter does not
/// layer a second platform transition over the outgoing app surface.
final class NativeSheetNavigationOrigin {
  const NativeSheetNavigationOrigin();
}

typedef NativeSheetNavigationRequest = ({String routeName, Object extra});

/// Direct Connections is launched after the native profile sheet dismisses.
/// Keep its route and transition marker coupled so this entry point cannot
/// accidentally restore a second Cupertino transition over the native sheet.
const NativeSheetNavigationRequest
directConnectionsNativeSheetNavigationRequest = (
  routeName: RouteNames.directConnections,
  extra: NativeSheetNavigationOrigin(),
);

/// Service for handling navigation throughout the app.
///
/// With GoRouter in place, this class mostly provides convenient wrappers
/// around the global router so existing callers can trigger navigation
/// without directly depending on BuildContext.
class NavigationService {
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>(debugLabel: 'rootNavigator');

  static GoRouter? _router;
  static int _routeRevision = 0;
  static String? _lastRoute;

  static GoRouter get router {
    final router = _router;
    if (router == null) {
      throw StateError('GoRouter has not been attached to NavigationService.');
    }
    return router;
  }

  static void attachRouter(GoRouter router) {
    _router?.routeInformationProvider.removeListener(_handleRouteChanged);
    _router = router;
    _lastRoute = router.routeInformationProvider.value.uri.toString();
    _routeRevision += 1;
    router.routeInformationProvider.addListener(_handleRouteChanged);
  }

  static void _handleRouteChanged() {
    final route = _router?.routeInformationProvider.value.uri.toString();
    if (route == _lastRoute) return;
    _lastRoute = route;
    _routeRevision += 1;
  }

  static NavigatorState? get navigator => navigatorKey.currentState;
  static BuildContext? get context => navigatorKey.currentContext;

  /// Changes whenever the attached router or its location changes.
  static int get currentRouteRevision => _routeRevision;

  /// The current location reported by GoRouter.
  static String? get currentRoute {
    final router = _router;
    if (router == null) return null;
    return router.routeInformationProvider.value.uri.toString();
  }

  /// The current folder ID when the active route is `/folder/:id`.
  static String? get currentFolderId {
    final current = currentRoute;
    if (current == null) return null;

    final uri = Uri.tryParse(current);
    if (uri == null) return null;

    final segments = uri.pathSegments;
    if (segments.length == 2 && segments.first == 'folder') {
      return segments[1];
    }

    return null;
  }

  /// Navigate to a specific route path.
  static Future<void> navigateTo(String routeName) async {
    final router = _router;
    if (router == null) return;
    router.go(routeName);
  }

  /// Opens the Open WebUI connect flow after a native sheet dismisses.
  ///
  /// The router moves a newly authenticated session out of the auth flow only
  /// when an auth route is the current location. Pushing the flow over
  /// `/chat` keeps `/chat` as that location, so sign-in succeeds while the
  /// Sign in page stays on screen. Go to the flow instead, as the chooser and
  /// the Flutter profile page do.
  static void openOpenWebUIConnectFromNativeSheet() {
    router.goNamed(
      RouteNames.serverConnection,
      extra: const NativeSheetNavigationOrigin(),
    );
  }

  /// Push a route while preserving the current page as the back destination.
  static Future<T?> pushTo<T extends Object?>(String routeName) async {
    final router = _router;
    if (router == null) return null;
    return router.push<T>(routeName);
  }

  /// Navigate back with an optional result payload.
  static void goBack<T>([T? result]) {
    final router = _router;
    if (router?.canPop() == true) {
      router!.pop(result);
    }
  }

  /// Check whether the router can pop the current route.
  static bool canGoBack() => _router?.canPop() ?? false;

  /// Show confirmation dialog before navigation.
  static Future<bool> confirmNavigation({
    required String title,
    required String message,
    String? confirmText,
    String? cancelText,
  }) async {
    final ctx = context;
    if (ctx == null) return false;
    final l10n = AppLocalizations.of(ctx);
    final resolvedConfirm = confirmText ?? l10n?.continueAction ?? 'Continue';
    final resolvedCancel = cancelText ?? l10n?.cancel ?? 'Cancel';

    final result = await ThemedDialogs.confirm(
      ctx,
      title: title,
      message: message,
      confirmText: resolvedConfirm,
      cancelText: resolvedCancel,
      barrierDismissible: false,
    );

    return result;
  }

  static void navigateToChannel(String channelId) {
    router.go('/channel/$channelId');
  }

  static Future<void> navigateToChat() => navigateTo(Routes.chat);
  static Future<void> navigateToFolder(String folderId) =>
      navigateTo(Routes.folderPath(folderId));
  static Future<void> navigateToLogin() => navigateTo(Routes.serverConnection);
  static Future<void> navigateToProfile() => navigateTo(Routes.profile);
  static Future<void> navigateToServerConnection() =>
      navigateTo(Routes.serverConnection);

  /// Clear navigation history. With GoRouter this becomes a simple go call.
  static void clearNavigationStack() {
    final router = _router;
    if (router == null) return;
    router.go(Routes.serverConnection);
  }
}
