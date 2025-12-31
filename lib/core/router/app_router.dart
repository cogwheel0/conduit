import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../auth/auth_state_manager.dart';
import '../providers/app_providers.dart';
import '../services/connectivity_service.dart';
import '../services/navigation_service.dart';
import '../utils/debug_logger.dart';
import '../../features/auth/providers/unified_auth_providers.dart';
import '../../features/chat/providers/chat_providers.dart';
import '../../features/auth/views/authentication_page.dart';
import '../../features/auth/views/connect_signin_page.dart';
import '../../features/auth/views/connection_issue_page.dart';
import '../../features/auth/views/proxy_auth_page.dart';
import '../../features/auth/views/server_connection_page.dart';
import '../../features/auth/views/sso_auth_page.dart';
import '../../features/chat/views/chat_page.dart';
import '../../features/navigation/views/splash_launcher_page.dart';
import '../../features/notes/views/notes_list_page.dart';
import '../../features/notes/views/note_editor_page.dart';
import '../../features/profile/views/app_customization_page.dart';
import '../../features/profile/views/profile_page.dart';
import '../../features/wrapped/views/wrapped_page.dart';
import '../../l10n/app_localizations.dart';
import '../models/server_config.dart';

class RouterNotifier extends ChangeNotifier {
  RouterNotifier(this.ref) {
    _subscriptions = [
      ref.listen<bool>(reviewerModeProvider, _onStateChanged),
      ref.listen<AsyncValue<ServerConfig?>>(
        activeServerProvider,
        _onStateChanged,
      ),
      ref.listen<AuthNavigationState>(
        authNavigationStateProvider,
        _onStateChanged,
      ),
      ref.listen<ConnectivityStatus>(
        connectivityStatusProvider,
        _onStateChanged,
      ),
      ref.listen<bool>(isChatStreamingProvider, _onStateChanged),
    ];
  }

  final Ref ref;
  late final List<ProviderSubscription<dynamic>> _subscriptions;

  void _onStateChanged(dynamic previous, dynamic next) {
    // Debounce router refreshes to avoid thrashing on rapid state changes
    _scheduleRefresh();
  }

  Timer? _refreshDebounce;
  void _scheduleRefresh() {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 50), () {
      notifyListeners();
    });
  }

  String? redirect(BuildContext context, GoRouterState state) {
    final location = state.uri.path.isEmpty ? Routes.splash : state.uri.path;
    final reviewerMode = ref.read(reviewerModeProvider);
    final activeServerAsync = ref.read(activeServerProvider);

    // Check for API key forced logout first - redirect to authentication
    final authSnapshot = ref
        .read(authStateManagerProvider)
        .maybeWhen(data: (s) => s, orElse: () => null);
    if (authSnapshot?.error?.contains('apiKey') == true) {
      return location == Routes.authentication ? null : Routes.authentication;
    }

    if (reviewerMode) {
      // Stay on whatever route if already in chat; otherwise go to chat
      if (location == Routes.chat) return null;
      return Routes.chat;
    }

    if (activeServerAsync.isLoading) {
      // Avoid redirect loops: do not override explicit auth routes while loading
      if (_isAuthLocation(location)) return null;
      // Keep splash during server loading otherwise
      return location == Routes.splash ? null : Routes.splash;
    }

    if (activeServerAsync.hasError) {
      return location == Routes.connectionIssue ? null : Routes.connectionIssue;
    }

    final activeServer = activeServerAsync.asData?.value;
    final hasActiveServer = activeServer != null;
    if (!hasActiveServer) {
      // No server configured - redirect to server connection
      // Exception: allow staying on server connection, authentication,
      // proxy auth, and SSO pages during the connection/auth flow.
      // But always redirect away from connection issue page (user logged out)
      if (location == Routes.serverConnection ||
          location == Routes.authentication ||
          location == Routes.proxyAuth ||
          location == Routes.ssoAuth ||
          location == Routes.login) {
        return null;
      }
      return Routes.serverConnection;
    }

    final authState = ref.read(authNavigationStateProvider);
    final connectivityService = ref.read(connectivityServiceProvider);

    // Allow staying on server connection page
    if (location == Routes.serverConnection) {
      // If authenticated but on server connection page, go to chat
      // Otherwise stay on server connection page (for back navigation)
      return authState == AuthNavigationState.authenticated
          ? Routes.chat
          : null;
    }

    // Check connectivity status to determine if we should show connection issue
    final connectivity = ref.read(connectivityStatusProvider);

    // Only show connection issue page if:
    // 1. Not in reviewer mode
    // 2. Connectivity is explicitly offline
    // 3. Auth is authenticated (don't interrupt auth flow)
    // 4. App is in foreground and offline warning isn't suppressed
    // 5. No active streaming is in progress (avoid interrupting chat streams)
    final hasActiveStreams = ref.read(isChatStreamingProvider);
    final shouldShowConnectionIssue =
        !reviewerMode &&
        connectivity == ConnectivityStatus.offline &&
        authState == AuthNavigationState.authenticated &&
        connectivityService.isAppForeground &&
        !connectivityService.isOfflineSuppressed &&
        !hasActiveStreams;

    if (shouldShowConnectionIssue) {
      return location == Routes.connectionIssue ? null : Routes.connectionIssue;
    }

    switch (authState) {
      case AuthNavigationState.loading:
        // Keep user on auth routes while loading to prevent bounce
        if (_isAuthLocation(location)) return null;
        // Otherwise keep splash during session establishment
        return location == Routes.splash ? null : Routes.splash;
      case AuthNavigationState.needsLogin:
        if (location == Routes.connectionIssue) return null;
        // Redirect to authentication page if not already on an auth route
        // This handles the post-logout case where we want sign-in, not server setup
        if (_isAuthLocation(location)) return null;
        return Routes.authentication;
      case AuthNavigationState.error:
        final authSnapshot = ref
            .read(authStateManagerProvider)
            .maybeWhen(data: (state) => state, orElse: () => null);
        final hasValidToken = authSnapshot?.hasValidToken ?? false;
        final isAuthFormRoute =
            location == Routes.login || location == Routes.authentication;
        if (!hasValidToken && isAuthFormRoute) {
          // Keep user on the login/authentication flow to show inline errors
          return null;
        }
        // Otherwise show connection issue page for recoverable auth errors
        return location == Routes.connectionIssue
            ? null
            : Routes.connectionIssue;
      case AuthNavigationState.authenticated:
        // Avoid unnecessary redirects if already on a non-auth route
        if (_isAuthLocation(location) ||
            location == Routes.splash ||
            location == Routes.connectionIssue) {
          return Routes.chat;
        }
        return null;
    }
  }

  bool _isAuthLocation(String location) {
    return location == Routes.serverConnection ||
        location == Routes.login ||
        location == Routes.authentication ||
        location == Routes.connectionIssue ||
        location == Routes.ssoAuth ||
        location == Routes.proxyAuth;
  }

  @override
  void dispose() {
    _refreshDebounce?.cancel();
    for (final sub in _subscriptions) {
      sub.close();
    }
    super.dispose();
  }
}

final routerNotifierProvider = Provider<RouterNotifier>((ref) {
  final notifier = RouterNotifier(ref);
  ref.onDispose(notifier.dispose);
  return notifier;
});

final goRouterProvider = Provider<GoRouter>((ref) {
  final notifier = ref.watch(routerNotifierProvider);

  final routes = <RouteBase>[
    GoRoute(
      path: Routes.splash,
      name: RouteNames.splash,
      builder: (context, state) => const SplashLauncherPage(),
    ),
    GoRoute(
      path: Routes.chat,
      name: RouteNames.chat,
      builder: (context, state) => const ChatPage(),
    ),
    GoRoute(
      path: Routes.login,
      name: RouteNames.login,
      builder: (context, state) => const ConnectAndSignInPage(),
    ),
    GoRoute(
      path: Routes.serverConnection,
      name: RouteNames.serverConnection,
      builder: (context, state) => const ServerConnectionPage(),
    ),
    GoRoute(
      path: Routes.connectionIssue,
      name: RouteNames.connectionIssue,
      builder: (context, state) => const ConnectionIssuePage(),
    ),
    GoRoute(
      path: Routes.authentication,
      name: RouteNames.authentication,
      builder: (context, state) {
        final extra = state.extra;
        // Support both AuthFlowConfig (new) and ServerConfig (legacy)
        if (extra is AuthFlowConfig) {
          return AuthenticationPage(
            serverConfig: extra.serverConfig,
            backendConfig: extra.backendConfig,
          );
        }
        return AuthenticationPage(
          serverConfig: extra is ServerConfig ? extra : null,
        );
      },
    ),
    GoRoute(
      path: Routes.ssoAuth,
      name: RouteNames.ssoAuth,
      builder: (context, state) {
        final config = state.extra;
        return SsoAuthPage(
          serverConfig: config is ServerConfig ? config : null,
        );
      },
    ),
    GoRoute(
      path: Routes.proxyAuth,
      name: RouteNames.proxyAuth,
      builder: (context, state) {
        final config = state.extra;
        if (config is! ProxyAuthConfig) {
          // Fallback - should not happen in normal flow
          return const ServerConnectionPage();
        }
        return ProxyAuthPage(config: config);
      },
    ),
    GoRoute(
      path: Routes.profile,
      name: RouteNames.profile,
      builder: (context, state) => const ProfilePage(),
    ),
    GoRoute(
      path: Routes.appCustomization,
      name: RouteNames.appCustomization,
      builder: (context, state) => const AppCustomizationPage(),
    ),
    GoRoute(
      path: Routes.notes,
      name: RouteNames.notes,
      builder: (context, state) => const NotesListPage(),
    ),
    GoRoute(
      path: Routes.noteEditor,
      name: RouteNames.noteEditor,
      builder: (context, state) {
        final noteId = state.pathParameters['id'];
        if (noteId == null || noteId.isEmpty) {
          return const NotesListPage();
        }
        return NoteEditorPage(noteId: noteId);
      },
    ),
    GoRoute(
      path: Routes.wrapped,
      name: RouteNames.wrapped,
      builder: (context, state) => const WrappedPage(),
    ),
  ];

  final router = GoRouter(
    navigatorKey: NavigationService.navigatorKey,
    initialLocation: Routes.splash,
    refreshListenable: notifier,
    redirect: notifier.redirect,
    routes: routes,
    observers: [NavigationLoggingObserver()],
    errorBuilder: (context, state) {
      final l10n = AppLocalizations.of(context);
      final message =
          l10n?.routeNotFound(state.uri.path) ??
          'Route not found: ${state.uri.path}';
      return Scaffold(
        body: Center(child: Text(message, textAlign: TextAlign.center)),
      );
    },
  );

  NavigationService.attachRouter(router);
  return router;
});

class NavigationLoggingObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    final previous = previousRoute?.settings.name ?? previousRoute?.settings;
    DebugLogger.navigation(
      'Pushed: ${route.settings.name ?? route.settings} (from ${previous ?? 'root'})',
    );
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    DebugLogger.navigation('Popped: ${route.settings.name ?? route.settings}');
  }
}
