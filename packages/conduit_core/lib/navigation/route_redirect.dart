import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/providers/chat_entry_readiness_providers.dart';
import 'package:conduit_core/providers/openwebui_accounts_controller.dart';
import 'package:conduit_core/providers/openwebui_route_resolver.dart'
    show proxySignInForRouteEditingProvider;
import 'package:riverpod/misc.dart';
import 'package:riverpod/riverpod.dart';

/// Reads a provider without listening: `Ref.read`, `WidgetRef.read` and
/// `ProviderContainer.read` all fit.
typedef ProviderRead = T Function<T>(ProviderListenable<T> provider);

/// The providers [resolveRouteRedirect] depends on. A host re-evaluates its
/// redirect whenever one of them changes.
final List<ProviderListenable<Object?>> routeRedirectDependencies = [
  reviewerModeProvider,
  activeServerProvider,
  authNavigationStateProvider,
  workspaceCapabilitiesProvider,
  // Hermes-only routing: re-evaluate when the preferred backend changes or
  // the Hermes config becomes usable (secrets finish loading).
  preferredBackendProvider,
  accountAdditionOriginProvider,
  proxySignInForRouteEditingProvider,
  hermesConfigProvider,
  hermesSecretsLoadingProvider,
  effectiveDirectConnectionProfilesProvider,
];

/// App-local destinations that remain meaningful without an OpenWebUI account.
/// The Hermes MCP page is not listed, here or in any other location check:
/// it needs a usable Desktop Gateway, so the accountless redirect decides it
/// from the Hermes configuration itself.
/// Keep this list explicit so adding an OWUI-only profile route does not expose
/// it to Hermes-only users by accident.
bool isHermesOnlyAppLocation(String location) =>
    _isAccountlessBackendLocation(location);

bool _isAccountlessBackendLocation(String location) {
  return location == Routes.chat ||
      location == Routes.profile ||
      // The saved accounts are on the device: switching to one still
      // signed in needs no session on the active account.
      location == Routes.accounts ||
      // A server's addresses are on the device too, and Manage accounts
      // opens them.
      location == Routes.serverAddresses ||
      location == Routes.serverAddressEditor ||
      location == Routes.audioSettings ||
      location == Routes.appearanceSettings ||
      location == Routes.chatSettings ||
      location == Routes.dataConnectionSettings ||
      location == Routes.personalization ||
      isDirectConnectionsLocation(location) ||
      location == Routes.hermesSettings ||
      location == Routes.hermesJobs ||
      location == Routes.about;
}

bool isDirectConnectionsLocation(String location) {
  return location == Routes.directConnections ||
      location.startsWith('${Routes.directConnections}/');
}

/// App-local surfaces available when direct APIs are the primary backend.
bool isDirectOnlyAppLocation(String location) =>
    _isAccountlessBackendLocation(location);

String incompleteHermesDestination({
  required bool secretsLoading,
  bool activeServerLoading = false,
}) {
  return secretsLoading || activeServerLoading
      ? Routes.splash
      : Routes.hermesSettings;
}

/// Where the app should send a user who asked for [location], or null to let
/// them stay.
///
/// The router's redirect policy, kept here so it is tested without
/// go_router or Flutter.
String? resolveRouteRedirect(String location, ProviderRead read) {
  final reviewerMode = read(reviewerModeProvider);
  if (reviewerMode) {
    // Stay on whatever route if already in chat; otherwise go to chat.
    if (location == Routes.chat) return null;
    return Routes.chat;
  }

  final activeServerAsync = read(activeServerProvider);
  final authState = read(authNavigationStateProvider);
  final preferredBackend = read(preferredBackendProvider);
  final hermesConfig = read(hermesConfigProvider);
  final hermesUsable = hermesConfig.isUsable;
  final hermesSecretsLoading = read(hermesSecretsLoadingProvider);
  final prefersHermes = preferredBackend == PreferredBackend.hermes;
  final prefersDirect = preferredBackend == PreferredBackend.direct;
  final directProfiles = read(effectiveDirectConnectionProfilesProvider);
  final directProfilesLoading = directProfiles.isLoading;
  final directUsable =
      !directProfiles.isLoading &&
      !directProfiles.hasError &&
      (directProfiles.value?.any((profile) => profile.isUsable) ?? false);
  final usesAccountlessPrimaryBackend = read(
    accountlessPrimaryBackendUsableProvider,
  );
  final isLocalBackendSetup =
      location == Routes.backendChooser ||
      location == Routes.hermesSettings ||
      isDirectConnectionsLocation(location);

  // A stale optional Open WebUI credential must not block local-backend
  // recovery or an explicit authentication/recovery flow. Other backend
  // modes retain forced auth.
  final authSnapshot = read(authStateManagerProvider)
      .maybeWhen(data: (s) => s, orElse: () => null);
  if (!usesAccountlessPrimaryBackend &&
      !prefersDirect &&
      !(prefersHermes && hermesConfig.enabled) &&
      !isLocalBackendSetup &&
      !isAuthLocation(location) &&
      authSnapshot?.error?.contains('apiKey') == true) {
    return Routes.authentication;
  }

  // Authentication is authoritative even while the selected server
  // provider is refreshing or recovering from a transient storage error.
  // In particular, Direct-primary installs may add OpenWebUI from an auth
  // route while their optional server provider is still loading. Do not let
  // the accountless fallback below strand a completed sign-in on that page.
  if (authState == AuthNavigationState.authenticated &&
      isAuthLocation(location) &&
      location != Routes.connectionIssue &&
      !_isAddingAccountFromActive(read) &&
      !_isProxySignInForRouteEditing(location, read)) {
    return Routes.chat;
  }

  // Onboarding and local backend setup screens always render.
  if (isLocalBackendSetup) {
    return null;
  }

  // A refresh of the server already known keeps the user where they are:
  // re-reading its addresses, or moving to another of them, does not change
  // whose app this is, and an account change shows its own loading through
  // auth. Only a first lookup holds the splash.
  if (activeServerAsync.isLoading && !activeServerAsync.hasValue) {
    // Avoid redirect loops: do not override explicit auth routes while loading
    if (isAuthLocation(location)) return null;
    if (prefersDirect && !directUsable) {
      final destination = directProfilesLoading
          ? Routes.splash
          : '${Routes.directConnections}?onboarding=true';
      return location == Uri.parse(destination).path ? null : destination;
    }
    if (usesAccountlessPrimaryBackend) {
      return _accountlessOrAuthRedirect(location, read);
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
    // A failed read of the active server leaves an addition's pages open
    // while the account it began from is the one last settled active: the
    // read can fail for a moment, as the Keychain can be locked.
    if (isAuthLocation(location) && _isAddingAccountFromActive(read)) {
      return null;
    }
    if (prefersDirect && !directUsable) {
      if (isAuthLocation(location)) return null;
      final destination = directProfilesLoading
          ? Routes.splash
          : '${Routes.directConnections}?onboarding=true';
      return location == Uri.parse(destination).path ? null : destination;
    }
    if (usesAccountlessPrimaryBackend) {
      return _accountlessOrAuthRedirect(location, read);
    }
    if (prefersHermes && hermesConfig.enabled) {
      if (isAuthLocation(location)) return null;
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

  final activeServer = activeServerAsync.value;
  final hasActiveServer = activeServer != null;
  // A preferred Direct backend is usable only while at least one validated,
  // enabled profile has resolved. With an authenticated OpenWebUI session we
  // can fall back to mixed mode; otherwise recover Direct setup instead of
  // leaving the user in a model-less chat.
  if (prefersDirect &&
      !directUsable &&
      (!hasActiveServer || authState != AuthNavigationState.authenticated)) {
    if (isAuthLocation(location)) return null;
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
    if (isAuthLocation(location)) return null;
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
    return _accountlessOrAuthRedirect(location, read);
  }

  // Incomplete Hermes-only mode: recover setup without an OWUI server.
  if (prefersHermes && !hasActiveServer) {
    // Let a Hermes-only user reach the OWUI connect/auth flow so they can add
    // an Open WebUI server (bidirectional switching). Once connected,
    // preferredBackend flips to owui and this branch no longer applies.
    if (isAuthLocation(location)) return null;
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
        location == Routes.addServer ||
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
    return authState == AuthNavigationState.authenticated ? Routes.chat : null;
  }

  switch (authState) {
    case AuthNavigationState.loading:
      // Keep user on auth routes while loading to prevent bounce
      if (isAuthLocation(location)) return null;
      // Otherwise keep splash during session establishment
      return location == Routes.splash ? null : Routes.splash;
    case AuthNavigationState.needsLogin:
      if (location == Routes.connectionIssue) return null;
      // Redirect to authentication page if not already on an auth route
      // This handles the post-logout case where we want sign-in, not server setup
      if (isAuthLocation(location)) return null;
      return Routes.authentication;
    case AuthNavigationState.error:
      // A request refused for the account an addition began from, which
      // keeps its token, is that account's: the addition's pages stay.
      if (isAuthLocation(location) && _isAddingAccountFromActive(read)) {
        return null;
      }
      final authSnapshot = read(authStateManagerProvider)
          .maybeWhen(data: (state) => state, orElse: () => null);
      final hasValidToken = authSnapshot?.hasValidToken ?? false;
      final isAuthFormRoute = isAuthLocation(location);
      if (!hasValidToken && isAuthFormRoute) {
        // Keep user on the login/authentication flow to show inline errors
        return null;
      }
      // Proxy re-authentication keeps the token and runs from the
      // connection issue page; do not bounce it back there.
      if (location == Routes.proxyAuth) return null;
      // Otherwise show connection issue page for recoverable auth errors
      return location == Routes.connectionIssue ? null : Routes.connectionIssue;
    case AuthNavigationState.authenticated:
      // Adding another account passes through sign-in screens while the
      // current one is still signed in. Stay until the new account is the
      // active one; then this rule no longer applies and chat takes over.
      if (isAuthLocation(location) && _isAddingAccountFromActive(read)) {
        return null;
      }
      if (_isProxySignInForRouteEditing(location, read)) return null;
      // Avoid unnecessary redirects if already on a non-auth route
      if (isAuthLocation(location) ||
          location == Routes.splash ||
          location == Routes.connectionIssue) {
        return Routes.chat;
      }
      return _workspaceRedirect(location, read);
  }
}

String? _workspaceRedirect(String location, ProviderRead read) {
  if (location != Routes.workspace &&
      !location.startsWith('${Routes.workspace}/')) {
    return null;
  }

  final capabilities = read(workspaceCapabilitiesProvider);
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

/// Whether another account is being added and the account it began from is
/// still the active one. Signing in to the new account makes it active,
/// which ends this, and ordinary routing lands it in chat.
bool _isAddingAccountFromActive(ProviderRead read) {
  final origin = read(accountAdditionOriginProvider);
  if (origin == null || origin.isEmpty) return false;
  final active = read(activeServerProvider);
  // A read that failed names no account; the one last settled active
  // stands for it.
  final activeId = active.hasError && !active.hasValue
      ? read(settledActiveAccountIdProvider)
      : active.value?.id;
  return origin == activeId;
}

/// Whether [location] is the proxy sign-in the address editor opened to check
/// a proxy-protected address, which it does while signed in.
bool _isProxySignInForRouteEditing(String location, ProviderRead read) =>
    location == Routes.proxyAuth && read(proxySignInForRouteEditingProvider);

bool isAuthLocation(String location) {
  return location == Routes.serverConnection ||
      location == Routes.addServer ||
      location == Routes.login ||
      location == Routes.authentication ||
      location == Routes.connectionIssue ||
      location == Routes.ssoAuth ||
      location == Routes.proxyAuth;
}

String? _accountlessOrAuthRedirect(String location, ProviderRead read) {
  if (isAuthLocation(location)) return null;
  final prefersDirect =
      read(preferredBackendProvider) == PreferredBackend.direct;
  final bool isAllowed;
  if (location == Routes.hermesMcp) {
    // The MCP page talks to the Hermes Desktop Gateway. In any other backend
    // mode, or with an incomplete gateway configuration, it can only fail to
    // load while still offering to add servers, so the destination exists
    // only where that gateway is usable.
    final hermes = read(hermesConfigProvider);
    isAllowed =
        hermes.isUsable && hermes.mode == HermesBackendMode.desktopGateway;
  } else {
    isAllowed = prefersDirect
        ? isDirectOnlyAppLocation(location)
        : isHermesOnlyAppLocation(location);
  }
  return isAllowed ? null : Routes.chat;
}
