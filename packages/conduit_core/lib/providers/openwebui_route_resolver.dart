/// Chooses which route the active Open WebUI account's server is reached
/// through.
///
/// A saved server can list several addresses -- a LAN address, a Tailscale
/// name, a public reverse proxy -- in the user's order of preference. The app
/// uses the first of them that answers, checking again when the account,
/// the network or the server's reachability changes and when the app comes
/// back to the foreground.
library;

import 'dart:async';

import 'package:meta/meta.dart';
import 'package:riverpod/misc.dart' show ProviderListenable;
import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/ports/app_lifecycle.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/host_ports.dart';
import 'package:conduit_core/providers/openwebui_accounts_controller.dart';
import 'package:conduit_core/services/connectivity_service.dart';
import 'package:conduit_core/utils/debug_logger.dart';

/// Where the active account's server is being reached.
@immutable
final class OpenWebUiRouteStatus {
  const OpenWebUiRouteStatus({
    this.serverId,
    this.endpointId,
    this.checking = false,
    this.noneAnswered = false,
  });

  final String? serverId;

  /// The route in use, when the server has been resolved.
  final String? endpointId;

  /// Probing the routes right now.
  final bool checking;

  /// The last check found no route answering; the route in use is kept.
  final bool noneAnswered;

  OpenWebUiRouteStatus copyWith({bool? checking, bool? noneAnswered}) =>
      OpenWebUiRouteStatus(
        serverId: serverId,
        endpointId: endpointId,
        checking: checking ?? this.checking,
        noneAnswered: noneAnswered ?? this.noneAnswered,
      );

  @override
  bool operator ==(Object other) =>
      other is OpenWebUiRouteStatus &&
      other.serverId == serverId &&
      other.endpointId == endpointId &&
      other.checking == checking &&
      other.noneAnswered == noneAnswered;

  @override
  int get hashCode => Object.hash(serverId, endpointId, checking, noneAnswered);
}

/// Whether one route answers. Injected so tests can answer without a
/// network.
typedef OpenWebUiRouteProbe = Future<bool> Function(ServerConfig route);

final openWebUiRouteProbeProvider = Provider<OpenWebUiRouteProbe>(
  (ref) =>
      (route) => probeServerHealth(
        route,
        // Routes carry their captured proxy cookies; an incomplete logout
        // keeps them off every request, probes included.
        suppressCustomCookieHeader: logoutFenceSuppressesCookies(ref.read),
      ),
);

/// Whether an incomplete logout keeps a proxy cookie off a request right
/// now, as [read] finds the fence, for a client built outside the app's
/// own that can carry a cookie a route keeps.
///
/// Asked on every request: the fence can rise after the client is built. A
/// read that fails, as one racing provider teardown does, keeps the cookie
/// off rather than reattach it.
bool Function() logoutFenceSuppressesCookies(
  T Function<T>(ProviderListenable<T> provider) read,
) => () {
  try {
    return read(incompleteLogoutFenceProvider) ||
        read(incompleteLogoutFenceProvider.notifier).desiredSuppressed;
  } catch (_) {
    return true;
  }
};

/// Whether the active account has no session yet: it is being signed in to,
/// or its saved session is still being restored.
///
/// A sign-in is checked on the client for the address it was given, and
/// moving to a better route then would rebuild that client under it.
final openWebUiSignInPendingProvider = Provider<bool Function()>((ref) {
  return () {
    try {
      return !ref.read(isAuthenticatedProvider2);
    } catch (_) {
      return false;
    }
  };
});

/// Whether the address editor has the reverse-proxy sign-in open, to check a
/// proxy-protected address of a saved server.
///
/// The router keeps a signed-in user away from sign-in screens, and editing
/// addresses happens signed in. While this is set, it lets that one screen
/// through.
final proxySignInForRouteEditingProvider =
    NotifierProvider<ProxySignInForRouteEditing, bool>(
      ProxySignInForRouteEditing.new,
    );

class ProxySignInForRouteEditing extends Notifier<bool> {
  @override
  bool build() => false;

  void begin() => state = true;

  void end() => state = false;
}

final openWebUiRouteResolverProvider =
    NotifierProvider<OpenWebUiRouteResolver, OpenWebUiRouteStatus>(
      OpenWebUiRouteResolver.new,
    );

class OpenWebUiRouteResolver extends Notifier<OpenWebUiRouteStatus> {
  static const Duration _retryDelay = Duration(seconds: 30);
  static const Duration _failureCheckInterval = Duration(seconds: 15);

  int _generation = 0;
  Timer? _retry;

  /// The origin of the route in use as the last check left it; null before
  /// one has, or with no server to reach.
  String? _inUseOrigin;

  @override
  OpenWebUiRouteStatus build() {
    ref.listen<String?>(settledActiveAccountIdProvider, (previous, next) {
      if (previous != next) _schedule('account');
    });
    // Requests failing to reach the server mean the route in use may have
    // gone. Watched through the static signal rather than the connectivity
    // provider, which would start its health polling just by being listened
    // to. A burst of failures checks once. Every client reports its own
    // failures -- an address being checked, another account's server -- and
    // only the route in use says anything about it.
    DateTime? lastFailureCheck;
    final failures = ConnectivityService.transportFailures.listen((uri) {
      final inUse = _inUseOrigin;
      if (inUse != null && ConnectivityService.originKey(uri) != inUse) {
        return;
      }
      final now = DateTime.now();
      if (lastFailureCheck != null &&
          now.difference(lastFailureCheck!) < _failureCheckInterval) {
        return;
      }
      lastFailureCheck = now;
      _schedule('unreachable');
    }, onError: (Object _) {});
    final network = ref.read(connectivityPortProvider).onChanged.listen((
      hasInterface,
    ) {
      if (hasInterface) _schedule('network');
    }, onError: (Object _) {});
    final lifecycle = ref.read(appLifecycleProvider).changes.listen((phase) {
      if (phase == AppLifecyclePhase.resumed) _schedule('resumed');
    }, onError: (Object _) {});
    ref.onDispose(() {
      _retry?.cancel();
      unawaited(failures.cancel());
      unawaited(network.cancel());
      unawaited(lifecycle.cancel());
    });
    _schedule('start');
    return const OpenWebUiRouteStatus();
  }

  void _schedule(String reason) {
    Future<void>.microtask(() {
      if (ref.mounted) return resolve(reason: reason);
    });
  }

  /// Checks every route to the active account's server and uses the first,
  /// in the user's order, that answers.
  ///
  /// Moving to a better route while a reply is being written would cut it
  /// off, and while the active account is being signed in to would rebuild
  /// the client the sign-in is checked on, so that waits; leaving a route
  /// that stopped answering does not.
  Future<void> resolve({String reason = 'manual'}) async {
    final generation = ++_generation;
    _retry?.cancel();
    try {
      final storage = ref.read(optimizedStorageServiceProvider);
      final accountId = await storage.getActiveServerId();
      final registry = await storage.getOpenWebUiRegistryStrict();
      if (!_owns(generation)) return;
      final account = accountId == null ? null : registry.account(accountId);
      final server = account == null ? null : registry.server(account.serverId);
      if (account == null || server == null) {
        _inUseOrigin = null;
        state = const OpenWebUiRouteStatus();
        return;
      }
      final current = server.selectedEndpoint(
        storage.endpointSelection[server.id],
      );
      // Until a check settles otherwise, the route in use stays in use.
      _inUseOrigin = ConnectivityService.originKey(Uri.tryParse(current.url));
      if (server.endpoints.length < 2) {
        state = OpenWebUiRouteStatus(
          serverId: server.id,
          endpointId: current.id,
        );
        return;
      }

      state = OpenWebUiRouteStatus(
        serverId: server.id,
        endpointId: current.id,
        checking: true,
      );
      final probes = [
        for (final route in server.endpoints)
          _answers(registry, account, server, route),
      ];
      final chosen = await _firstAnswering(server.endpoints, probes);
      if (!_owns(generation)) return;
      if (chosen == null) {
        DebugLogger.warning(
          'no-route-answered',
          scope: 'connectivity/routes',
          data: {'reason': reason, 'routes': server.endpoints.length},
        );
        state = state.copyWith(checking: false, noneAnswered: true);
        _retry = Timer(_retryDelay, () => _schedule('retry'));
        return;
      }

      if (chosen.id != current.id) {
        // A route ahead of the one in use answering is an upgrade, and the
        // one in use may still be fine; it is already being probed.
        final upgrade =
            server.endpoints.indexOf(chosen) <
            server.endpoints.indexOf(current);
        final currentStillAnswers =
            upgrade && await probes[server.endpoints.indexOf(current)];
        if (!_owns(generation)) return;
        if (currentStillAnswers &&
            (ref.read(accountChangeReplyGuardProvider)() ||
                ref.read(openWebUiSignInPendingProvider)())) {
          state = state.copyWith(checking: false, noneAnswered: false);
          _retry = Timer(_retryDelay, () => _schedule('deferred'));
          return;
        }
        final changed = await storage.selectEndpoint(server.id, chosen.id);
        // Even when a newer check has started: one that picks the same route
        // finds it already selected and leaves the configs alone, which would
        // keep the client on the old URL.
        if (changed && ref.mounted) ref.invalidate(serverConfigsProvider);
        if (!_owns(generation)) return;
        _inUseOrigin = ConnectivityService.originKey(Uri.tryParse(chosen.url));
        if (changed) {
          DebugLogger.log(
            'route-selected',
            scope: 'connectivity/routes',
            data: {
              'reason': reason,
              'position': server.endpoints.indexOf(chosen),
            },
          );
        }
      }
      state = OpenWebUiRouteStatus(serverId: server.id, endpointId: chosen.id);
    } catch (error, stackTrace) {
      if (!_owns(generation)) return;
      DebugLogger.error(
        'route-resolve-failed',
        scope: 'connectivity/routes',
        error: error,
        stackTrace: stackTrace,
      );
      state = state.copyWith(checking: false);
    }
  }

  bool _owns(int generation) => ref.mounted && generation == _generation;

  Future<bool> _answers(
    OpenWebUiRegistry registry,
    OpenWebUiAccount account,
    OpenWebUiServer server,
    OpenWebUiEndpoint endpoint,
  ) {
    final route = registry.project(
      account.id,
      selectedEndpoints: {server.id: endpoint.id},
    );
    if (route == null) return Future<bool>.value(false);
    return ref
        .read(openWebUiRouteProbeProvider)(route)
        .catchError((_) => false);
  }

  /// Settles as soon as the answer is known: the earliest route that
  /// answered, once every route before it has not.
  Future<OpenWebUiEndpoint?> _firstAnswering(
    List<OpenWebUiEndpoint> routes,
    List<Future<bool>> probes,
  ) {
    final outcomes = List<bool?>.filled(routes.length, null);
    final decided = Completer<OpenWebUiEndpoint?>();

    void decide() {
      if (decided.isCompleted) return;
      for (var index = 0; index < routes.length; index++) {
        final outcome = outcomes[index];
        if (outcome == null) return;
        if (outcome) {
          decided.complete(routes[index]);
          return;
        }
      }
      decided.complete(null);
    }

    for (var index = 0; index < routes.length; index++) {
      unawaited(
        probes[index].then((answered) {
          outcomes[index] = answered;
          decide();
        }),
      );
    }
    return decided.future;
  }
}
