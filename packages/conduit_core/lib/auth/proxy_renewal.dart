import 'package:meta/meta.dart';
import 'package:riverpod/riverpod.dart' show AsyncValue;

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

/// A renewal whose captured session is not the renewed account's own user
/// (someone else signed in at the proxy's window): nothing of it is saved.
class ProxyRenewalWrongUser implements Exception {
  const ProxyRenewalWrongUser();

  @override
  String toString() => 'ProxyRenewalWrongUser';
}

/// Renews an expired reverse-proxy session of [activeServer] in place, with
/// what a new proxy sign-in left behind ([capture]), so the account stays
/// signed in to Conduit (issues #690, #698).
///
/// Nothing is written until the session the renewed cookies carry is shown
/// to be the account's own: the server is asked, through those cookies, who
/// the captured session is (or, with no token captured, who the kept one
/// is), and it must be the user the account is signed in as. Another user
/// throws [ProxyRenewalWrongUser], a refusal throws, and nothing is saved.
///
/// Then the fresh cookies replace the old ones in the server's saved headers
/// -- the same server identity, so storage keeps the account's session --
/// and the route resolver forgets the refusals of the session just
/// replaced. A captured session is adopted as a first-time proxy sign-in
/// is; otherwise the kept session is checked again and shown signed in only
/// once the server takes it.
///
/// [stillWanted] is asked once everything that waits is done, before
/// anything is written: a host whose page went away stops there.
/// [canCommit] is asked right before the first write, with nothing awaited
/// between the two: before the cookies are saved, or, with a session
/// captured, as its commit begins (the cookies are saved in that commit).
/// A host whose facts changed while the renewal worked (another account, a
/// newer sign-in) stops there, and nothing is written. Throws when a step
/// fails; the host shows its own words for that.
///
/// [ref] is a `Ref`, a `WidgetRef` or a `ProviderContainer`.
Future<void> renewProxySessionInPlace(
  dynamic ref, {
  required ServerConfig activeServer,
  required ProxyAuthCapture capture,
  bool Function()? stillWanted,
  bool Function()? canCommit,
}) async {
  bool mayCommit() => canCommit == null || canCommit();
  final updatedServer = activeServer.copyWith(
    customHeaders: mergeCapturedProxyCookiesIntoHeaders(
      headers: activeServer.customHeaders,
      capturedCookies: capture.cookies,
    ),
  );
  // Who the account is signed in as, read before anything is awaited.
  final AsyncValue<AuthState> state = ref.read(authStateManagerProvider);
  final kept = state.value;
  final keptUser = kept?.user;
  final token = capture.isFullyAuthenticated ? capture.token : kept?.token;
  if (keptUser == null || token == null || token.isEmpty) {
    throw StateError('no kept session to renew');
  }
  final api = ApiService(
    serverConfig: updatedServer,
    workerManager: ref.read(workerManagerProvider) as WorkerManager,
    authToken: token,
  );
  final User user;
  try {
    user = await api.getCurrentUser(suppressAuthFailureNotification: true);
  } finally {
    api.dispose();
  }
  if (user.id != keptUser.id) throw const ProxyRenewalWrongUser();

  final storage = ref.read(optimizedStorageServiceProvider);
  final configs = await storage.getServerConfigsStrict() as List<ServerConfig>;
  // Where the cookies are filed; the app can have moved to another route
  // while the sign-in was open.
  final renewedRoute = renewedProxyRouteId(
    await storage.getOpenWebUiRegistryStrict() as OpenWebUiRegistry,
    activeServer,
    selection: storage.endpointSelection as Map<String, String>,
  );
  if (stillWanted != null && !stillWanted()) return;
  final AuthStateManager authManager = ref.read(
    authStateManagerProvider.notifier,
  );
  authManager.resetRetryCounter();

  // Everything that waits is done. From here, each write is preceded by
  // [canCommit] with nothing awaited between them.
  if (capture.isFullyAuthenticated) {
    // The proxy's web view completed Open WebUI SSO too: that session, its
    // user shown above to be the account's, is adopted as the first-time
    // connect flow adopts one, the renewed cookies saved with it in the
    // commit's own transaction. [canCommit] is asked as the commit begins,
    // before its first write.
    final AuthActions actions = ref.read(authActionsProvider);
    final committed = await actions.commitPrevalidatedProxySession(
      serverConfig: updatedServer,
      token: capture.token!,
      user: user,
      mayBegin: canCommit,
    );
    if (!committed) return;
  } else {
    if (!mayCommit()) return;
    // Same server identity: the storage layer keeps the account session
    // when only custom headers change.
    await storage.saveServerConfigs([
      for (final config in configs)
        if (config.id == updatedServer.id) updatedServer else config,
    ]);
    ref.invalidate(serverConfigsProvider);
    ref.invalidate(activeServerProvider);
  }
  // Its refusals were of the session just replaced.
  ref
      .read(openWebUiRouteResolverProvider.notifier)
      .proxySessionRenewed(renewedRoute);
  if (!capture.isFullyAuthenticated) {
    await ref.read(activeServerProvider.future);
    // The kept session is asked about through the renewed cookies before it
    // shows signed in, as Retry asks: a refresh trusts it at once. Refused,
    // the connection issue stays. Only while that issue is still the state,
    // with the kept session, and [canCommit] still holds after the waits
    // above: a sign-in begun or committed meanwhile is newer, and Retry's
    // fallback (a refresh, a new attempt) would supersede it.
    final AsyncValue<AuthState> now = ref.read(authStateManagerProvider);
    final current = now.value;
    if (!mayCommit() ||
        current == null ||
        current.status != AuthStatus.error ||
        current.token != kept?.token) {
      return;
    }
    await authManager.retryConnectionIssue();
  }
  DebugLogger.auth('Proxy session renewed in place', scope: 'auth/connection');
}
