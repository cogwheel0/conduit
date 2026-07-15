import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../auth/auth_state_manager.dart';
import '../providers/app_providers.dart';
import '../providers/backend_mode_providers.dart';
import '../../features/hermes/models/hermes_config.dart';
import '../../features/hermes/providers/hermes_providers.dart';
import '../services/navigation_service.dart';
import '../services/performance_profiler.dart';
import '../utils/debug_logger.dart';
import '../../features/auth/providers/unified_auth_providers.dart';
import '../../features/auth/views/authentication_page.dart';
import '../../features/auth/views/backend_chooser_page.dart';
import '../../features/auth/views/connect_signin_page.dart';
import '../../features/auth/views/connection_issue_page.dart';
import '../../features/auth/views/proxy_auth_page.dart';
import '../../features/auth/views/server_connection_page.dart';
import '../../features/auth/views/sso_auth_page.dart';
import '../../features/chat/views/chat_page.dart';
import '../../features/navigation/views/folder_page.dart';
import '../../shared/widgets/drawer_shell_page.dart';
import '../../shared/widgets/server_version_warning_shell.dart';
import '../../features/navigation/views/splash_launcher_page.dart';
import '../../features/notes/views/notes_list_page.dart';
import '../../shared/widgets/adaptive_route_shell.dart';
import '../../features/channels/views/channel_page.dart';
import '../../features/notes/views/note_editor_page.dart';
import '../../features/profile/views/about_page.dart';
import '../../features/profile/views/account_settings_page.dart';
import '../../features/profile/views/app_customization_page.dart';
import '../../features/profile/views/audio_settings_page.dart';
import '../../features/hermes/views/hermes_settings_page.dart';
import '../../features/hermes/views/hermes_jobs_page.dart';
import '../../features/profile/views/personalization_page.dart';
import '../../features/profile/views/profile_page.dart';
import '../../features/notifications/views/notification_settings_page.dart';
import '../../features/workspace/providers/workspace_capabilities_provider.dart';
import '../../features/workspace/views/workspace_page.dart';
import '../../features/workspace/workspace_navigation.dart';
import '../../features/direct_connections/models/direct_connection_profile.dart';
import '../../features/direct_connections/providers/direct_connection_providers.dart';
import '../../features/direct_connections/views/direct_connection_editor_page.dart';
import '../../features/direct_connections/views/direct_connections_page.dart';
import '../../l10n/app_localizations.dart';
import '../models/server_config.dart';

/// App-local destinations that remain meaningful without an OpenWebUI account.
/// Keep this list explicit so adding an OWUI-only profile route does not expose
/// it to Hermes-only users by accident.
@visibleForTesting
bool isHermesOnlyAppLocation(String location) =>
    _isAccountlessBackendLocation(location);

bool _isAccountlessBackendLocation(String location) {
  return location == Routes.chat ||
      location == Routes.profile ||
      location == Routes.audioSettings ||
      location == Routes.appearanceSettings ||
      location == Routes.chatSettings ||
      location == Routes.dataConnectionSettings ||
      isDirectConnectionsLocation(location) ||
      location == Routes.hermesSettings ||
      location == Routes.hermesJobs ||
      location == Routes.about;
}

@visibleForTesting
bool isDirectConnectionsLocation(String location) {
  return location == Routes.directConnections ||
      location.startsWith('${Routes.directConnections}/');
}

/// App-local surfaces available when direct APIs are the primary backend.
@visibleForTesting
bool isDirectOnlyAppLocation(String location) =>
    _isAccountlessBackendLocation(location);

@visibleForTesting
String incompleteHermesDestination({
  required bool secretsLoading,
  bool activeServerLoading = false,
}) {
  return secretsLoading || activeServerLoading
      ? Routes.splash
      : Routes.hermesSettings;
}

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
      ref.listen(workspaceCapabilitiesProvider, _onStateChanged),
      // Hermes-only routing: re-evaluate when the preferred backend changes or
      // the Hermes config becomes usable (secrets finish loading).
      ref.listen<PreferredBackend>(preferredBackendProvider, _onStateChanged),
      ref.listen<HermesConfig>(hermesConfigProvider, _onStateChanged),
      ref.listen<bool>(hermesSecretsLoadingProvider, _onStateChanged),
      ref.listen<AsyncValue<List<DirectConnectionProfile>>>(
        effectiveDirectConnectionProfilesProvider,
        _onStateChanged,
      ),
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
    if (reviewerMode) {
      // Stay on whatever route if already in chat; otherwise go to chat.
      if (location == Routes.chat) return null;
      return Routes.chat;
    }

    final activeServerAsync = ref.read(activeServerProvider);
    final preferredBackend = ref.read(preferredBackendProvider);
    final hermesConfig = ref.read(hermesConfigProvider);
    final hermesUsable = hermesConfig.isUsable;
    final hermesSecretsLoading = ref.read(hermesSecretsLoadingProvider);
    final prefersHermes = preferredBackend == PreferredBackend.hermes;
    final prefersDirect = preferredBackend == PreferredBackend.direct;
    final directProfiles = ref.read(effectiveDirectConnectionProfilesProvider);
    final directProfilesLoading = directProfiles.isLoading;
    final directUsable =
        !directProfiles.isLoading &&
        !directProfiles.hasError &&
        (directProfiles.value?.any((profile) => profile.isUsable) ?? false);
    final usesAccountlessPrimaryBackend =
        (prefersDirect && directUsable) || (prefersHermes && hermesUsable);
    final isLocalBackendSetup =
        location == Routes.backendChooser ||
        location == Routes.hermesSettings ||
        isDirectConnectionsLocation(location);

    // A stale optional Open WebUI credential must not block local-backend
    // recovery or an explicit authentication/recovery flow. Other backend
    // modes retain forced auth.
    final authSnapshot = ref
        .read(authStateManagerProvider)
        .maybeWhen(data: (s) => s, orElse: () => null);
    if (!usesAccountlessPrimaryBackend &&
        !prefersDirect &&
        !(prefersHermes && hermesConfig.enabled) &&
        !isLocalBackendSetup &&
        !_isAuthLocation(location) &&
        authSnapshot?.error?.contains('apiKey') == true) {
      return Routes.authentication;
    }

    // Onboarding and local backend setup screens always render.
    if (isLocalBackendSetup) {
      return null;
    }

    if (activeServerAsync.isLoading) {
      // Avoid redirect loops: do not override explicit auth routes while loading
      if (_isAuthLocation(location)) return null;
      if (prefersDirect && !directUsable) {
        final destination = directProfilesLoading
            ? Routes.splash
            : '${Routes.directConnections}?onboarding=true';
        return location == Uri.parse(destination).path ? null : destination;
      }
      if (usesAccountlessPrimaryBackend) {
        return _accountlessOrAuthRedirect(location);
      }
      if (prefersHermes && hermesConfig.enabled) {
        if (hermesSecretsLoading && isHermesOnlyAppLocation(location)) {
          return null;
        }
        final destination = incompleteHermesDestination(
          secretsLoading: hermesSecretsLoading,
          activeServerLoading: true,
        );
        return location == destination ? null : destination;
      }
      // Keep splash during server loading otherwise
      return location == Routes.splash ? null : Routes.splash;
    }

    if (activeServerAsync.hasError) {
      if (prefersDirect && !directUsable) {
        if (_isAuthLocation(location)) return null;
        final destination = directProfilesLoading
            ? Routes.splash
            : '${Routes.directConnections}?onboarding=true';
        return location == Uri.parse(destination).path ? null : destination;
      }
      if (usesAccountlessPrimaryBackend) {
        return _accountlessOrAuthRedirect(location);
      }
      if (prefersHermes && hermesConfig.enabled) {
        if (_isAuthLocation(location)) return null;
        if (hermesSecretsLoading && isHermesOnlyAppLocation(location)) {
          return null;
        }
        final destination = incompleteHermesDestination(
          secretsLoading: hermesSecretsLoading,
        );
        return location == destination ? null : destination;
      }
      return location == Routes.connectionIssue ? null : Routes.connectionIssue;
    }

    final activeServer = activeServerAsync.asData?.value;
    final hasActiveServer = activeServer != null;
    final authState = ref.read(authNavigationStateProvider);

    // A preferred Direct backend is usable only while at least one validated,
    // enabled profile has resolved. With an authenticated OpenWebUI session we
    // can fall back to mixed mode; otherwise recover Direct setup instead of
    // leaving the user in a model-less chat.
    if (prefersDirect &&
        !directUsable &&
        (!hasActiveServer || authState != AuthNavigationState.authenticated)) {
      if (_isAuthLocation(location)) return null;
      final destination = directProfilesLoading
          ? Routes.splash
          : '${Routes.directConnections}?onboarding=true';
      return location == Uri.parse(destination).path ? null : destination;
    }

    // Logout intentionally retains the OpenWebUI server. While Hermes secrets
    // hydrate, or when a saved key is missing, that signed-out optional server
    // must not take ownership of routing before Hermes can recover.
    if (prefersHermes &&
        authState != AuthNavigationState.authenticated &&
        hermesConfig.enabled &&
        !hermesUsable) {
      if (_isAuthLocation(location)) return null;
      if (hermesSecretsLoading && isHermesOnlyAppLocation(location)) {
        return null;
      }
      final destination = incompleteHermesDestination(
        secretsLoading: hermesSecretsLoading,
      );
      return location == destination ? null : destination;
    }

    // A usable accountless-primary backend never depends on an Open WebUI auth
    // session. Auth routes remain reachable so users can add or repair an
    // optional Open WebUI connection. Once that session is authenticated, its
    // server-backed surfaces remain available too.
    if (usesAccountlessPrimaryBackend &&
        (!hasActiveServer || authState != AuthNavigationState.authenticated)) {
      return _accountlessOrAuthRedirect(location);
    }

    // Incomplete Hermes-only mode: recover setup without an OWUI server.
    if (prefersHermes && !hasActiveServer) {
      // Let a Hermes-only user reach the OWUI connect/auth flow so they can add
      // an Open WebUI server (bidirectional switching). Once connected,
      // preferredBackend flips to owui and this branch no longer applies.
      if (_isAuthLocation(location)) return null;
      // Hold the splash only while secure storage is actually loading. Once it
      // settles without a usable key, send the user to Hermes settings so the
      // install can recover from a deleted/unavailable secret.
      if (hermesConfig.enabled) {
        if (hermesSecretsLoading && isHermesOnlyAppLocation(location)) {
          return null;
        }
        final destination = incompleteHermesDestination(
          secretsLoading: hermesSecretsLoading,
        );
        return location == destination ? null : destination;
      }
    }

    if (!hasActiveServer) {
      // No server configured - redirect to onboarding chooser.
      // Exception: allow staying on server connection, authentication,
      // proxy auth, and SSO pages during the connection/auth flow.
      if (location == Routes.serverConnection ||
          location == Routes.authentication ||
          location == Routes.proxyAuth ||
          location == Routes.ssoAuth ||
          location == Routes.login) {
        return null;
      }
      return Routes.backendChooser;
    }

    // Allow staying on server connection page
    if (location == Routes.serverConnection) {
      // If authenticated but on server connection page, go to chat
      // Otherwise stay on server connection page (for back navigation)
      return authState == AuthNavigationState.authenticated
          ? Routes.chat
          : null;
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
        final isAuthFormRoute = _isAuthLocation(location);
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
        return _workspaceRedirect(location);
    }
  }

  String? _workspaceRedirect(String location) {
    if (location != Routes.workspace &&
        !location.startsWith('${Routes.workspace}/')) {
      return null;
    }

    final capabilities = ref.read(workspaceCapabilitiesProvider);
    // Fail closed in the page gate while permissions are loading or errored.
    if (!capabilities.hasValue) return null;

    final permitted = permittedWorkspaceSections(capabilities.requireValue);
    if (permitted.isEmpty) {
      return location == Routes.workspace ? null : Routes.workspace;
    }

    if (location == Routes.workspace) return permitted.first.path;
    final requested = workspaceSectionForPath(location);
    if (requested == null || !permitted.contains(requested)) {
      return permitted.first.path;
    }
    return null;
  }

  bool _isAuthLocation(String location) {
    return location == Routes.serverConnection ||
        location == Routes.login ||
        location == Routes.authentication ||
        location == Routes.connectionIssue ||
        location == Routes.ssoAuth ||
        location == Routes.proxyAuth;
  }

  String? _accountlessOrAuthRedirect(String location) {
    if (_isAuthLocation(location)) return null;
    return _isAccountlessBackendLocation(location) ? null : Routes.chat;
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

  final appRoutes = <RouteBase>[
    GoRoute(
      path: Routes.splash,
      name: RouteNames.splash,
      pageBuilder: (context, state) => _buildNoTransitionPage(
        state: state,
        child: const SplashLauncherPage(),
      ),
    ),
    // ShellRoute keeps the drawer/sidebar mounted across page navigations
    // so it doesn't reload on tablets when switching between chat, channels,
    // and notes.
    ShellRoute(
      builder: (context, state, child) => DrawerShellPage(child: child),
      routes: [
        GoRoute(
          path: Routes.chat,
          name: RouteNames.chat,
          pageBuilder: (context, state) =>
              _buildNoTransitionPage(state: state, child: const ChatPage()),
        ),
        GoRoute(
          path: Routes.folder,
          name: RouteNames.folder,
          pageBuilder: (context, state) {
            final folderId = state.pathParameters['id']!;
            return _buildNoTransitionPage(
              state: state,
              child: FolderPage(key: ValueKey(folderId), folderId: folderId),
            );
          },
        ),
        GoRoute(
          path: Routes.noteEditor,
          name: RouteNames.noteEditor,
          pageBuilder: (context, state) {
            final noteId = state.pathParameters['id'];
            if (noteId == null || noteId.isEmpty) {
              return _buildNoTransitionPage(
                state: state,
                child: const NotesListPage(),
              );
            }
            return _buildNoTransitionPage(
              state: state,
              child: NoteEditorPage(key: ValueKey(noteId), noteId: noteId),
            );
          },
        ),
        GoRoute(
          path: Routes.channel,
          name: RouteNames.channel,
          pageBuilder: (context, state) {
            final channelId = state.pathParameters['id']!;
            return _buildNoTransitionPage(
              state: state,
              child: ChannelPage(channelId: channelId),
            );
          },
        ),
      ],
    ),
    GoRoute(
      path: Routes.login,
      name: RouteNames.login,
      pageBuilder: (context, state) =>
          _buildPlatformPage(state: state, child: const ConnectAndSignInPage()),
    ),
    GoRoute(
      path: Routes.backendChooser,
      name: RouteNames.backendChooser,
      pageBuilder: (context, state) =>
          _buildPlatformPage(state: state, child: const BackendChooserPage()),
    ),
    GoRoute(
      path: Routes.serverConnection,
      name: RouteNames.serverConnection,
      pageBuilder: (context, state) =>
          _buildPlatformPage(state: state, child: const ServerConnectionPage()),
    ),
    GoRoute(
      path: Routes.connectionIssue,
      name: RouteNames.connectionIssue,
      pageBuilder: (context, state) =>
          _buildPlatformPage(state: state, child: const ConnectionIssuePage()),
    ),
    GoRoute(
      path: Routes.authentication,
      name: RouteNames.authentication,
      pageBuilder: (context, state) {
        final extra = state.extra;
        // Support both AuthFlowConfig (new) and ServerConfig (legacy)
        if (extra is AuthFlowConfig) {
          return _buildPlatformPage(
            state: state,
            child: AuthenticationPage(
              serverConfig: extra.serverConfig,
              backendConfig: extra.backendConfig,
            ),
          );
        }
        return _buildPlatformPage(
          state: state,
          child: AuthenticationPage(
            serverConfig: extra is ServerConfig ? extra : null,
          ),
        );
      },
    ),
    GoRoute(
      path: Routes.ssoAuth,
      name: RouteNames.ssoAuth,
      pageBuilder: (context, state) {
        final config = state.extra;
        return _buildPlatformPage(
          state: state,
          child: SsoAuthPage(
            serverConfig: config is ServerConfig ? config : null,
          ),
        );
      },
    ),
    GoRoute(
      path: Routes.proxyAuth,
      name: RouteNames.proxyAuth,
      pageBuilder: (context, state) {
        final config = state.extra;
        if (config is! ProxyAuthConfig) {
          // Fallback - should not happen in normal flow
          return _buildPlatformPage(
            state: state,
            child: const ServerConnectionPage(),
          );
        }
        return _buildPlatformPage(
          state: state,
          child: ProxyAuthPage(config: config),
        );
      },
    ),
    GoRoute(
      path: Routes.profile,
      name: RouteNames.profile,
      pageBuilder: (context, state) =>
          _buildPlatformPage(state: state, child: const ProfilePage()),
    ),
    GoRoute(
      path: Routes.personalization,
      name: RouteNames.personalization,
      pageBuilder: (context, state) =>
          _buildPlatformPage(state: state, child: const PersonalizationPage()),
    ),
    GoRoute(
      path: Routes.audioSettings,
      name: RouteNames.audioSettings,
      pageBuilder: (context, state) =>
          _buildPlatformPage(state: state, child: const AudioSettingsPage()),
    ),
    GoRoute(
      path: Routes.accountSettings,
      name: RouteNames.accountSettings,
      pageBuilder: (context, state) =>
          _buildPlatformPage(state: state, child: const AccountSettingsPage()),
    ),
    GoRoute(
      path: Routes.appearanceSettings,
      name: RouteNames.appearanceSettings,
      pageBuilder: (context, state) => _buildPlatformPage(
        state: state,
        child: const AppCustomizationPage(
          section: AppCustomizationSection.appearance,
        ),
      ),
    ),
    GoRoute(
      path: Routes.chatSettings,
      name: RouteNames.chatSettings,
      pageBuilder: (context, state) => _buildPlatformPage(
        state: state,
        child: const AppCustomizationPage(
          section: AppCustomizationSection.chat,
        ),
      ),
    ),
    GoRoute(
      path: Routes.dataConnectionSettings,
      name: RouteNames.dataConnectionSettings,
      pageBuilder: (context, state) => _buildPlatformPage(
        state: state,
        child: const AppCustomizationPage(
          section: AppCustomizationSection.dataConnection,
        ),
      ),
    ),
    GoRoute(
      path: Routes.notificationSettings,
      name: RouteNames.notificationSettings,
      pageBuilder: (context, state) => _buildPlatformPage(
        state: state,
        child: const NotificationSettingsPage(),
      ),
    ),
    GoRoute(
      path: Routes.directConnections,
      name: RouteNames.directConnections,
      pageBuilder: (context, state) => _buildPlatformPage(
        state: state,
        child: DirectConnectionsPage(
          isOnboarding: state.uri.queryParameters['onboarding'] == 'true',
        ),
      ),
    ),
    GoRoute(
      path: Routes.directConnectionEditor,
      name: RouteNames.directConnectionEditor,
      pageBuilder: (context, state) => _buildPlatformPage(
        state: state,
        child: DirectConnectionEditorPage(
          profileId: state.pathParameters['id']!,
          isOnboarding: state.uri.queryParameters['onboarding'] == 'true',
          isOpenWebUi:
              state.uri.queryParameters['source'] ==
              openWebUiDirectConnectionSourceQueryValue,
        ),
      ),
    ),
    GoRoute(
      path: Routes.hermesSettings,
      name: RouteNames.hermesSettings,
      pageBuilder: (context, state) => _buildPlatformPage(
        state: state,
        child: HermesSettingsPage(isOnboarding: state.extra == true),
      ),
    ),
    GoRoute(
      path: Routes.hermesJobs,
      name: RouteNames.hermesJobs,
      pageBuilder: (context, state) =>
          _buildPlatformPage(state: state, child: const HermesJobsPage()),
    ),
    GoRoute(
      path: Routes.about,
      name: RouteNames.about,
      pageBuilder: (context, state) =>
          _buildPlatformPage(state: state, child: const AboutPage()),
    ),
    ..._workspaceRoutes(),
    GoRoute(
      path: Routes.notes,
      name: RouteNames.notes,
      pageBuilder: (context, state) =>
          _buildNoTransitionPage(state: state, child: const NotesListPage()),
    ),
  ];

  final router = GoRouter(
    navigatorKey: NavigationService.navigatorKey,
    initialLocation: Routes.splash,
    refreshListenable: notifier,
    redirect: notifier.redirect,
    routes: [
      ShellRoute(
        builder: (context, state, child) =>
            ServerVersionWarningShell(child: child),
        routes: appRoutes,
      ),
    ],
    observers: [NavigationLoggingObserver()],
    errorBuilder: (context, state) {
      final l10n = AppLocalizations.of(context);
      final message =
          l10n?.routeNotFound(state.uri.path) ??
          'Route not found: ${state.uri.path}';
      return AdaptiveRouteShell(
        body: Center(child: Text(message, textAlign: TextAlign.center)),
      );
    },
  );

  NavigationService.attachRouter(router);
  return router;
});

List<GoRoute> _workspaceRoutes() {
  GoRoute route({
    required String path,
    required String name,
    required WorkspaceSection? section,
    WorkspaceRouteMode mode = WorkspaceRouteMode.collection,
  }) {
    return GoRoute(
      path: path,
      name: name,
      pageBuilder: (context, state) => _buildPlatformPage(
        state: state,
        child: WorkspacePage(
          section: section,
          mode: mode,
          resourceId: state.pathParameters['id'],
        ),
      ),
    );
  }

  return [
    route(path: Routes.workspace, name: RouteNames.workspace, section: null),
    for (final descriptor in workspaceRouteDescriptors) ...[
      route(
        path: descriptor.collectionPath,
        name: descriptor.collectionName,
        section: descriptor.section,
      ),
      route(
        path: descriptor.createPattern,
        name: descriptor.createName,
        section: descriptor.section,
        mode: WorkspaceRouteMode.create,
      ),
      route(
        path: descriptor.detailPattern,
        name: descriptor.detailName,
        section: descriptor.section,
        mode: WorkspaceRouteMode.detail,
      ),
      route(
        path: descriptor.editPattern,
        name: descriptor.editName,
        section: descriptor.section,
        mode: WorkspaceRouteMode.edit,
      ),
    ],
  ];
}

class NavigationLoggingObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    final current = route.settings.name ?? route.settings.toString();
    final previous = previousRoute?.settings.name ?? previousRoute?.settings;
    DebugLogger.navigation('Pushed: $current (from ${previous ?? 'root'})');
    PerformanceProfiler.instance.instant(
      'route_push',
      scope: 'navigation',
      data: {'route': current, 'previous': previous?.toString() ?? 'root'},
    );
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    final current = route.settings.name ?? route.settings.toString();
    final previous = previousRoute?.settings.name ?? previousRoute?.settings;
    DebugLogger.navigation('Popped: $current');
    PerformanceProfiler.instance.instant(
      'route_pop',
      scope: 'navigation',
      data: {'route': current, 'revealed': previous?.toString() ?? 'root'},
    );
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    final current = newRoute?.settings.name ?? newRoute?.settings.toString();
    final previous = oldRoute?.settings.name ?? oldRoute?.settings.toString();
    PerformanceProfiler.instance.instant(
      'route_replace',
      scope: 'navigation',
      data: {'route': current ?? 'unknown', 'previous': previous ?? 'unknown'},
    );
  }
}

Page<void> _buildNoTransitionPage({
  required GoRouterState state,
  required Widget child,
}) {
  return NoTransitionPage<void>(
    key: state.pageKey,
    name: state.name,
    child: child,
  );
}

Page<void> _buildPlatformPage({
  required GoRouterState state,
  required Widget child,
}) {
  if (usesNoTransitionForNativeSheet(state.extra)) {
    return _buildNoTransitionPage(state: state, child: child);
  }

  switch (defaultTargetPlatform) {
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      return CupertinoPage<void>(
        key: state.pageKey,
        name: state.name,
        child: child,
      );
    default:
      return MaterialPage<void>(
        key: state.pageKey,
        name: state.name,
        child: child,
      );
  }
}

@visibleForTesting
bool usesNoTransitionForNativeSheet(Object? extra) =>
    extra is NativeSheetNavigationOrigin;
