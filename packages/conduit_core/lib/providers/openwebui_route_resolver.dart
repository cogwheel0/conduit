/// Chooses which route the active Open WebUI account's server is reached
/// through.
///
/// A saved server can list several addresses -- a LAN address, a Tailscale
/// name, a public reverse proxy -- in the user's order of preference. The app
/// uses the first of them that answers, checking again when the account,
/// the network or the server's reachability changes, when a proxy in front
/// of it turns requests away, and when the app comes back to the foreground.
library;

import 'dart:async';

import 'package:meta/meta.dart';
import 'package:riverpod/misc.dart' show ProviderListenable;
import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/auth/auth_state_manager.dart';
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
  /// How long after a check a failure waits before checking again.
  @visibleForTesting
  static Duration failureCheckInterval = const Duration(seconds: 15);

  /// How long a route a proxy refused is not taken to answer.
  static const Duration _refusedFor = Duration(minutes: 5);

  int _generation = 0;
  Timer? _retry;

  /// A check held back by [failureCheckInterval], run once it has passed.
  Timer? _trailing;

  /// The origin of the route in use as the last check left it; null before
  /// one has, or with no server to reach.
  String? _inUseOrigin;

  /// The id of that route, and the server it belongs to.
  String? _inUseRouteId;
  OpenWebUiServer? _inUseServer;

  /// Routes a proxy turned the active account's requests away from, by id,
  /// and when. Their health check can still pass, so for [_refusedFor] no
  /// check takes them to answer, nor moves back to them. Recorded as each
  /// refusal is reported, for the route it came from: a check run later may
  /// find another route in use. A proxy session is the account's own, so
  /// another account starts afresh, and saving the server's addresses -- a
  /// new session among them -- forgets them too.
  final Map<String, DateTime> _refused = {};

  /// A check moved the route in use, and the session has not been checked
  /// on it since; see [_recheckSession].
  bool _recheckOwed = false;

  @override
  OpenWebUiRouteStatus build() {
    ref.listen<String?>(settledActiveAccountIdProvider, (previous, next) {
      if (previous == next) return;
      // The move owed a check to the account it was made for.
      _recheckOwed = false;
      _refused.clear();
      _schedule('account');
    });
    // Requests failing to reach the server mean the route in use may have
    // gone, and a proxy turning them away means its session there expired.
    // Watched through the static signals rather than the connectivity
    // provider, which would start its health polling just by being listened
    // to. A burst of failures checks once. Every client reports its own
    // failures -- an address being checked, another account's server -- and
    // only the route in use says anything about it.
    DateTime? lastFailureCheck;
    void failed(Uri uri, String reason, {ServerConfig? connection}) {
      final inUse = _inUseOrigin;
      if (inUse != null && ConnectivityService.originKey(uri) != inUse) {
        return;
      }
      if (reason == 'rejected') {
        final route = _inUseRouteId;
        final server = _inUseServer;
        // Routes can share a URL and differ in headers or client identity:
        // a request still out on the route a check left can be refused once
        // another with its URL is in use, and that one was not refused.
        if (route != null && server != null && connection != null) {
          final sentOver = server.routeForConnection(
            connection,
            selectedEndpointId: route,
          );
          if (sentOver.id != route) return;
        }
        if (route != null) _refused[route] = DateTime.now();
      }
      // Nor would it be checked; resuming checks anyway.
      if (_inBackground) return;
      final now = DateTime.now();
      final last = lastFailureCheck;
      final wait = last == null
          ? Duration.zero
          : failureCheckInterval - now.difference(last);
      if (wait > Duration.zero) {
        // Held back, not dropped: a route a check just moved to may be the
        // one failing now, and nothing else would look again.
        _trailing ??= Timer(wait, () {
          _trailing = null;
          lastFailureCheck = DateTime.now();
          _schedule(reason);
        });
        return;
      }
      lastFailureCheck = now;
      _schedule(reason);
    }

    final failures = ConnectivityService.transportFailures.listen(
      (uri) => failed(uri, 'unreachable'),
      onError: (Object _) {},
    );
    final rejections = ConnectivityService.routeRejections.listen(
      (rejection) => failed(
        rejection.server,
        'rejected',
        connection: rejection.connection,
      ),
      onError: (Object _) {},
    );
    final network = ref.read(connectivityPortProvider).onChanged.listen((
      hasInterface,
    ) {
      if (hasInterface) _schedule('network');
    }, onError: (Object _) {});
    final lifecycle = ref.read(appLifecycleProvider).changes.listen((phase) {
      if (phase == AppLifecyclePhase.resumed) {
        _schedule('resumed');
      } else if (phase.isBackground) {
        // Nothing is checked in the background; coming back checks again.
        _retry?.cancel();
        _retry = null;
        _trailing?.cancel();
        _trailing = null;
      }
    }, onError: (Object _) {});
    ref.onDispose(() {
      _retry?.cancel();
      _trailing?.cancel();
      unawaited(failures.cancel());
      unawaited(rejections.cancel());
      unawaited(network.cancel());
      unawaited(lifecycle.cancel());
    });
    _schedule('start');
    return const OpenWebUiRouteStatus();
  }

  void _schedule(String reason) {
    Future<void>.microtask(() {
      if (ref.mounted && !_inBackground) return resolve(reason: reason);
    });
  }

  /// Backgrounded far enough that periodic work should stop: a check asked
  /// for then waits for the app to come back, which checks anyway.
  bool get _inBackground =>
      ref.read(appLifecycleProvider).current?.isBackground ?? false;

  /// Whether a check is waiting to run again.
  @visibleForTesting
  bool get retryPending => _retry?.isActive ?? false;

  /// Whether a check held back after a recent one is waiting to run.
  @visibleForTesting
  bool get trailingCheckPending => _trailing?.isActive ?? false;

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
    if (reason == 'routes-edited') _refused.clear();
    try {
      final storage = ref.read(optimizedStorageServiceProvider);
      // As storage counts it: an account can be active with no id kept for
      // it, flagged active or the only one saved. A failed read throws.
      final accountId = await storage.getEffectiveActiveServerId();
      final registry = await storage.getOpenWebUiRegistryStrict();
      if (!_owns(generation)) return;
      final account = accountId == null ? null : registry.account(accountId);
      final server = account == null ? null : registry.server(account.serverId);
      if (account == null || server == null) {
        _inUseOrigin = null;
        _inUseRouteId = null;
        _inUseServer = null;
        _recheckOwed = false;
        state = const OpenWebUiRouteStatus();
        return;
      }
      final current = server.selectedEndpoint(
        storage.endpointSelection[server.id],
      );
      // Until a check settles otherwise, the route in use stays in use.
      _inUseOrigin = ConnectivityService.originKey(Uri.tryParse(current.url));
      _inUseRouteId = current.id;
      _inUseServer = server;
      if (server.endpoints.length < 2) {
        state = OpenWebUiRouteStatus(
          serverId: server.id,
          endpointId: current.id,
        );
        if (_recheckOwed) _recheckSession();
        return;
      }

      state = OpenWebUiRouteStatus(
        serverId: server.id,
        endpointId: current.id,
        checking: true,
      );
      // A proxy turning requests away from a route can still let its health
      // check through; for a while, that route does not answer.
      final now = DateTime.now();
      _refused.removeWhere((_, at) => now.difference(at) >= _refusedFor);
      final probes = [
        for (final route in server.endpoints)
          if (_refused.containsKey(route.id))
            Future<bool>.value(false)
          else
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
        if (!_inBackground) {
          _retry = Timer(_retryDelay, () => _schedule('retry'));
        }
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
          if (!_inBackground) {
            _retry = Timer(_retryDelay, () => _schedule('deferred'));
          }
          return;
        }
        final changed = await storage.selectEndpoint(server.id, chosen.id);
        // Even when a newer check has started: one that picks the same route
        // finds it already selected and leaves the configs alone, which would
        // keep the client on the old URL and the session left unchecked.
        if (changed && ref.mounted) {
          ref.invalidate(serverConfigsProvider);
          _recheckOwed = true;
        }
        if (!_owns(generation)) return;
        _inUseOrigin = ConnectivityService.originKey(Uri.tryParse(chosen.url));
        _inUseRouteId = chosen.id;
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
      if (_recheckOwed) _recheckSession();
    } catch (error, stackTrace) {
      if (!_owns(generation)) return;
      DebugLogger.error(
        'route-resolve-failed',
        scope: 'connectivity/routes',
        error: error,
        stackTrace: stackTrace,
      );
      state = state.copyWith(checking: false);
      // Storage coming back -- a Keychain unlocking -- starts no check, and
      // any check waiting to run again was cancelled for this one.
      if (!_inBackground) {
        _retry = Timer(_retryDelay, () => _schedule('retry'));
      }
    }
  }

  bool _owns(int generation) => ref.mounted && generation == _generation;

  /// After a check moved the route in use. A proxy turning requests away
  /// on the route left shows a connection issue, and nothing would look at
  /// the session again until Retry; auth checks it on the route moved to,
  /// once for the move. Not in the background, nor while a reply is being
  /// written: the check is owed until then, since no later check moves to
  /// that route again. Coming back checks the routes, and a reply waits for
  /// the next check.
  void _recheckSession() {
    try {
      if (_inBackground) return;
      if (ref.read(accountChangeReplyGuardProvider)()) {
        _retry?.cancel();
        _retry = Timer(_retryDelay, () => _schedule('recheck'));
        return;
      }
      _recheckOwed = false;
      if (ref.read(authStateManagerProvider).value?.status !=
          AuthStatus.error) {
        return;
      }
      unawaited(
        ref
            .read(authStateManagerProvider.notifier)
            .recheckSessionAfterRouteChange(),
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'session-recheck-failed',
        scope: 'connectivity/routes',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

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
