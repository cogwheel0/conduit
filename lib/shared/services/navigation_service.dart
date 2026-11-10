import 'package:conduit/l10n/app_localizations.dart';
import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';

import '../widgets/themed_dialogs.dart';

import 'package:conduit_core/navigation/routes.dart';

export 'package:conduit_core/navigation/routes.dart' show RouteNames, Routes;

/// Marks routes opened from a native sheet as it slides away, so Flutter does
/// not layer a second platform transition over the outgoing sheet.
final class NativeSheetNavigationOrigin {
  const NativeSheetNavigationOrigin();
}

typedef NativeSheetNavigationRequest = ({String routeName, Object extra});

/// Direct Connections is pushed as the native profile sheet starts to slide
/// away, so the page is already underneath when it has gone. Keep its route and transition marker coupled so this entry point cannot
/// accidentally restore a second Cupertino transition over the native sheet.
const NativeSheetNavigationRequest
directConnectionsNativeSheetNavigationRequest = (
  routeName: RouteNames.directConnections,
  extra: NativeSheetNavigationOrigin(),
);

/// Personal connections open the same way: the list page is pushed as the
/// native sheet slides away, without a second transition over it.
const NativeSheetNavigationRequest
personalConnectionsNativeSheetNavigationRequest = (
  routeName: RouteNames.personalConnections,
  extra: NativeSheetNavigationOrigin(),
);

/// Scheduled tasks open the same way, from the native Settings sheet.
const NativeSheetNavigationRequest scheduledTasksNativeSheetNavigationRequest =
    (
      routeName: RouteNames.scheduledTasks,
      extra: NativeSheetNavigationOrigin(),
    );

/// The calendar opens the same way, from the native Settings sheet.
const NativeSheetNavigationRequest calendarNativeSheetNavigationRequest = (
  routeName: RouteNames.calendar,
  extra: NativeSheetNavigationOrigin(),
);

/// LibreChat's Personalization opens the same way, from the native Settings
/// sheet.
const NativeSheetNavigationRequest
libreChatPersonalizationNativeSheetNavigationRequest = (
  routeName: RouteNames.personalization,
  extra: NativeSheetNavigationOrigin(),
);

/// Data controls open the same way, from the native Settings sheet.
const NativeSheetNavigationRequest
chatDataControlsNativeSheetNavigationRequest = (
  routeName: RouteNames.chatDataControls,
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

  /// Locations visited, oldest first, without repeats: returning to one
  /// drops everything after it, so back never cycles between two pages.
  static final List<String> _history = [];
  static const int _maxHistory = 32;

  static void attachRouter(GoRouter router) {
    _router?.routeInformationProvider.removeListener(_handleRouteChanged);
    _router = router;
    _lastRoute = router.routeInformationProvider.value.uri.toString();
    _routeRevision += 1;
    _history
      ..clear()
      ..add(_lastRoute!);
    router.routeInformationProvider.addListener(_handleRouteChanged);
  }

  static void _handleRouteChanged() {
    final route = _router?.routeInformationProvider.value.uri.toString();
    if (route == _lastRoute) return;
    _lastRoute = route;
    _routeRevision += 1;
    if (route != null) _recordVisit(route);
  }

  static void _recordVisit(String route) {
    final earlier = _history.lastIndexOf(route);
    if (earlier != -1) {
      _history.removeRange(earlier + 1, _history.length);
      return;
    }
    _history.add(route);
    if (_history.length > _maxHistory) _history.removeAt(0);
  }

  /// Whether [location] is a page of the main pane beside the sidebar, which
  /// back may return to, rather than a settings or sign-in screen.
  static bool _isMainPaneLocation(String location) {
    final path = Uri.tryParse(location)?.path ?? location;
    return path == Routes.chat ||
        path == Routes.notes ||
        path == Routes.channels ||
        path == Routes.terminal ||
        path == Routes.hermesSessions ||
        path.startsWith('/folder/') ||
        path.startsWith('/notes/') ||
        path.startsWith('/channel/') ||
        path.startsWith('/hermes-room/');
  }

  /// Goes back to the main-pane page shown before the current one, or to
  /// [fallback] when there was none, such as after a link opened the app.
  static void returnToPreviousPage({required String fallback}) {
    final router = _router;
    if (router == null) return;
    final current = currentRoute;
    final index = current == null ? -1 : _history.lastIndexOf(current);
    if (index != -1) _history.removeRange(index, _history.length);
    while (_history.isNotEmpty && !_isMainPaneLocation(_history.last)) {
      _history.removeLast();
    }
    // The history always ends with the page shown, even when the router
    // reports no change because back stays where it is.
    if (_history.isEmpty) _history.add(fallback);
    router.go(_history.last);
  }

  static NavigatorState? get navigator => navigatorKey.currentState;
  static BuildContext? get context => navigatorKey.currentContext;

  /// Changes whenever the attached router or its location changes.
  static int get currentRouteRevision => _routeRevision;

  /// Whether the page [context] belongs to is on screen as the route named
  /// [name] with [pathParameters]. It is not while the shell keeps it in a
  /// branch no longer shown, or while a page covers it, whether that page was
  /// pushed through the router, which leaves the location as it was, or
  /// straight onto a navigator.
  static bool isShowingNamed(
    BuildContext context,
    String name, {
    Map<String, String> pathParameters = const {},
  }) {
    final router = _router;
    if (router == null || !context.mounted) return false;
    // The top-most route, which a push through the router replaces.
    return router.state.matchedLocation ==
            router.namedLocation(name, pathParameters: pathParameters) &&
        // A page covering this one, or a branch not shown, mutes its tickers.
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true);
  }

  /// Drops the route named [name] with [pathParameters] from the pages back
  /// returns to, as once the page it shows is gone. Nothing navigates: a page
  /// on screen stays, and back from it goes to the page before.
  static void forgetNamed(
    String name, {
    Map<String, String> pathParameters = const {},
  }) {
    final router = _router;
    if (router == null) return;
    forgetPath(router.namedLocation(name, pathParameters: pathParameters));
  }

  /// Drops the pages at [path] from the pages back returns to, as
  /// [forgetNamed] does.
  static void forgetPath(String path) {
    _history.removeWhere(
      (location) => (Uri.tryParse(location)?.path ?? location) == path,
    );
  }

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

  /// Opens the Open WebUI connect flow from a native sheet.
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
