import 'package:meta/meta.dart';

import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/auth/proxy_session.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/openwebui_route_resolver.dart'
    show openWebUiRouteResolverProvider;
import 'package:conduit_core/services/api_service.dart'
    show ApiService, HealthCheckResult;
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/utils/debug_logger.dart';

/// Whether [config] carries a reverse-proxy session cookie, i.e. was set up
/// through the proxy sign-in flow and can be re-authenticated in place.
bool serverConfigHasProxyCookie(ServerConfig? config) {
  if (config == null) return false;
  return config.customHeaders.keys.any((key) => key.toLowerCase() == 'cookie');
}

/// Whether a health check's [health] means [server]'s reverse-proxy session
/// expired: the server is reached with a proxy cookie, and the proxy now
/// sends requests to its sign-in page instead of to Open WebUI.
bool proxySessionExpired(ServerConfig? server, HealthCheckResult health) =>
    health == HealthCheckResult.proxyAuthRequired &&
    serverConfigHasProxyCookie(server);

/// The route a renewed proxy session of [account] is saved to: the one its
/// projection was read from, found by the connection it carries as saving
/// it does, though the app may since have selected another.
@visibleForTesting
String? renewedProxyRouteId(
  OpenWebUiRegistry registry,
  ServerConfig account, {
  required Map<String, String> selection,
}) {
  final saved = registry.account(account.id);
  final server = saved == null ? null : registry.server(saved.serverId);
  return server
      ?.routeForConnection(account, selectedEndpointId: selection[server.id])
      .id;
}

/// Renews an expired reverse-proxy session of [activeServer] in place, with
/// what a new proxy sign-in left behind ([capture]), so the account stays
/// signed in to Conduit (issues #690, #698).
///
/// The fresh cookies replace the old ones in the server's saved headers --
/// the same server identity, so storage keeps the account's session -- and
/// the route resolver forgets the refusals of the session just replaced.
/// Then, when the proxy also completed Open WebUI's own sign-in ([capture]
/// holds a token), that session is adopted as a first-time proxy sign-in
/// is; otherwise the kept session is checked again.
///
/// [stillWanted] is asked once the server is saved, before the session is
/// touched: a host whose page went away stops there. Throws when a step
/// fails; the host shows its own words for that.
///
/// [ref] is a `Ref`, a `WidgetRef` or a `ProviderContainer`.
Future<void> renewProxySessionInPlace(
  dynamic ref, {
  required ServerConfig activeServer,
  required ProxyAuthCapture capture,
  bool Function()? stillWanted,
}) async {
  final updatedServer = activeServer.copyWith(
    customHeaders: mergeCapturedProxyCookiesIntoHeaders(
      headers: activeServer.customHeaders,
      capturedCookies: capture.cookies,
    ),
  );
  final storage = ref.read(optimizedStorageServiceProvider);
  final configs = await storage.getServerConfigsStrict() as List<ServerConfig>;
  // Where the save below files the cookies; the app can have moved to
  // another route while the sign-in was open.
  final renewedRoute = renewedProxyRouteId(
    await storage.getOpenWebUiRegistryStrict() as OpenWebUiRegistry,
    activeServer,
    selection: storage.endpointSelection as Map<String, String>,
  );
  // Same server identity: the storage layer keeps the account session when
  // only custom headers change.
  await storage.saveServerConfigs([
    for (final config in configs)
      if (config.id == updatedServer.id) updatedServer else config,
  ]);
  ref.invalidate(serverConfigsProvider);
  ref.invalidate(activeServerProvider);
  // Its refusals were of the session just replaced.
  ref
      .read(openWebUiRouteResolverProvider.notifier)
      .proxySessionRenewed(renewedRoute);
  await ref.read(activeServerProvider.future);
  if (stillWanted != null && !stillWanted()) return;

  final AuthStateManager authManager = ref.read(
    authStateManagerProvider.notifier,
  );
  authManager.resetRetryCounter();
  if (capture.isFullyAuthenticated) {
    // The proxy's web view completed Open WebUI SSO too; adopt that session
    // the same way the first-time connect flow does.
    final api = ApiService(
      serverConfig: updatedServer,
      workerManager: ref.read(workerManagerProvider) as WorkerManager,
      authToken: capture.token,
    );
    try {
      final User user = await api.getCurrentUser(
        suppressAuthFailureNotification: true,
      );
      final AuthActions actions = ref.read(authActionsProvider);
      await actions.commitPrevalidatedProxySession(
        serverConfig: updatedServer,
        token: capture.token!,
        user: user,
      );
    } finally {
      api.dispose();
    }
  } else {
    await authManager.refresh();
  }
  DebugLogger.auth('Proxy session renewed in place', scope: 'auth/connection');
}
