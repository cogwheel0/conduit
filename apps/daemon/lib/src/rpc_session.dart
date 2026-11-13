import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
import 'package:stream_channel/stream_channel.dart';

import 'accounts_service.dart';
import 'auth_service.dart';
import 'event_bus.dart';
import 'log.dart';
import 'servers_service.dart';
import 'settings_service.dart';
import 'system_service.dart';

/// The services that need the core. The daemon swaps in a full set when the
/// core attaches; until then every one is null.
final class CoreServices {
  const CoreServices({
    this.accounts,
    this.servers,
    this.auth,
    this.settings,
  });

  final AccountsService? accounts;
  final ServersService? servers;
  final AuthService? auth;
  final SettingsService? settings;
}

/// One connected renderer window.
///
/// A [json_rpc.Peer] rather than a server, because requests flow both ways:
/// the core calls `ui.request` when a tool needs approval, and blocks on a
/// human sitting in front of this window.
class RpcSession {
  RpcSession({
    required this.sessionId,
    required StreamChannel<String> channel,
    required SystemService system,
    required EventBus events,
    required DaemonLog log,
    required CoreServices Function() services,
    void Function(bool online)? reportNetwork,
  }) : _events = events,
       _reportNetwork = reportNetwork,
       _log = log,
       _services = services,
       _system = system,
       _peer = json_rpc.Peer(channel) {
    _register();
  }

  final String sessionId;
  final EventBus _events;
  final DaemonLog _log;
  final SystemService _system;

  /// The daemon's services as they are now: null until the core is up. A
  /// session can exist before then -- the window opens while the daemon is
  /// still restoring state -- and answering `servers.list` with an empty
  /// list in that window would look to the UI like a fresh install. It gets
  /// `rpc.daemonUnavailable` instead, and the real services once the core
  /// attaches, without reconnecting.
  final CoreServices Function() _services;
  AccountsService? get _accounts => _services().accounts;
  ServersService? get _servers => _services().servers;
  AuthService? get _auth => _services().auth;
  SettingsService? get _settings => _services().settings;
  final json_rpc.Peer _peer;

  /// Set by a successful `system.handshake`. Until then every other method is
  /// refused, so a client cannot skip version negotiation and then be
  /// surprised by a payload it cannot parse.
  HandshakeRequest? _handshake;

  bool get isHandshakeComplete => _handshake != null;

  /// Where a window's `online`/`offline` events go: the connectivity port,
  /// which then tells every window. Null before the core is up.
  final void Function(bool online)? _reportNetwork;

  Future<void> listen() => _peer.listen();

  Future<void> close() async {
    _events.detach(sessionId);
    await _peer.close();
  }

  /// Every method this session answers, with the spec it was registered
  /// from. The daemon's tests hold it equal to [ConduitMethodSpecs.all].
  Map<String, ConduitMethodSpec<Object?, Object?>> get registeredMethods =>
      Map<String, ConduitMethodSpec<Object?, Object?>>.unmodifiable(
        _registered,
      );
  final Map<String, ConduitMethodSpec<Object?, Object?>> _registered =
      <String, ConduitMethodSpec<Object?, Object?>>{};

  /// Registers [handler] for [spec]'s method: the only way this session
  /// adds one, so every method it answers decodes its params, and encodes
  /// its result, as the protocol's tables say. Every method but the
  /// handshake needs the handshake first.
  void _on<P, R>(
    ConduitMethodSpec<P, R> spec,
    FutureOr<R> Function(P params) handler, {
    bool beforeHandshake = false,
  }) {
    if (_registered.containsKey(spec.name)) {
      throw StateError('${spec.name} is registered twice');
    }
    _registered[spec.name] = spec;
    registerSpecMethod<P, R>(_peer, spec, (params) {
      if (!beforeHandshake) _requireHandshake();
      return handler(params);
    });
  }

  void _register() {
    _events.attach(sessionId, (envelope) {
      // A closed peer still sitting in the bus is a bug, but dropping the
      // event is better than tearing down every other window's fan-out.
      if (_peer.isClosed) return;
      sendEvent(_peer, envelope);
    });

    _on(ConduitMethodSpecs.systemHandshake, beforeHandshake: true, (request) {
      if (request.protocolVersion != kConduitProtocolVersion) {
        throw RpcError(
          code: ConduitErrorCodes.protocolVersionMismatch,
          args: <String, String>{
            'expected': kConduitProtocolVersion,
            'actual': request.protocolVersion,
          },
          debugMessage:
              'client speaks ${request.protocolVersion}, daemon speaks '
              '$kConduitProtocolVersion',
        );
      }
      _handshake = request;
      _log.info(
        'session $sessionId: ${request.clientName} ${request.clientVersion} '
        '(${request.windowKind.name}, ${request.locale})',
      );
      return _system.handshake(sessionId: sessionId, request: request);
    });

    _on(ConduitMethodSpecs.systemPing, (_) => _system.ping());
    _on(ConduitMethodSpecs.systemCapabilities, (_) => _system.capabilities);
    _on(ConduitMethodSpecs.systemShutdown, (_) => _system.shutdown());
    _on(
      ConduitMethodSpecs.systemExportDiagnostics,
      (_) => _system.exportDiagnostics(),
    );

    _on(ConduitMethodSpecs.systemNetwork, (report) {
      _reportNetwork?.call(report.online);
      return const OkResult(ok: true);
    });

    _on(ConduitMethodSpecs.eventsSubscribe, (subscription) {
      for (final event in subscription.events) {
        if (!ConduitEvents.all.contains(event)) {
          throw RpcError(
            code: ConduitErrorCodes.invalidParams,
            args: <String, String>{'event': event},
            debugMessage: 'unknown event name "$event"',
          );
        }
      }
      _events.subscribe(sessionId, subscription);
      // Echo the accepted filter back so the client can assert on what the
      // daemon actually stored rather than on what it hoped it sent.
      return subscription;
    });

    _registerAccounts();
    _registerServers();
    _registerAuth();
    _registerSettings();

    _peer.registerFallback((json_rpc.Parameters params) {
      final method = params.method;
      throw RpcError(
        code: ConduitMethods.isReserved(method)
            // A reserved namespace that is not wired up yet is a feature
            // that has not landed, which is worth telling apart from a typo.
            ? ConduitErrorCodes.unsupported
            : ConduitErrorCodes.methodNotFound,
        args: <String, String>{'method': method},
      ).toException();
    });
  }

  void _registerAccounts() {
    _on(ConduitMethodSpecs.accountsList, (_) => _requireAccounts().list());
    _on(ConduitMethodSpecs.accountsAdd, (r) => _requireAccounts().add(r));
    _on(
      ConduitMethodSpecs.accountsCancelAdd,
      (_) => _requireAccounts().cancelAdd(),
    );
    _on(
      ConduitMethodSpecs.accountsSwitch,
      (r) => _requireAccounts().switchTo(r),
    );
    _on(ConduitMethodSpecs.accountsRemove, (r) => _requireAccounts().remove(r));
    _on(
      ConduitMethodSpecs.accountsSignOut,
      (r) => _requireAccounts().signOut(r),
    );
  }

  void _registerServers() {
    _on(ConduitMethodSpecs.serversUpdate, (d) => _requireServers().update(d));
    _on(ConduitMethodSpecs.serversStatus, (_) => _requireServers().status());
  }

  void _registerAuth() {
    _on(ConduitMethodSpecs.authStatus, (_) => _requireAuth().status());
    _on(
      ConduitMethodSpecs.authLoginWithPassword,
      (p) => _requireAuth().loginWithPassword(p),
    );
    _on(
      ConduitMethodSpecs.authLoginWithLdap,
      (p) => _requireAuth().loginWithLdap(p),
    );
    _on(
      ConduitMethodSpecs.authLoginWithApiKey,
      (p) => _requireAuth().loginWithApiKey(p),
    );
    _on(
      ConduitMethodSpecs.authSilentLogin,
      (_) => _requireAuth().silentLogin(),
    );
    _on(
      ConduitMethodSpecs.authCompleteExternal,
      (p) => _requireAuth().completeExternal(p),
    );
    _on(
      ConduitMethodSpecs.authHasSavedCredentials,
      (_) async => SavedCredentialsResult(
        hasSavedCredentials: await _requireAuth().hasSavedCredentials(),
      ),
    );
    _on(
      ConduitMethodSpecs.authSetReviewerMode,
      (p) => _requireAuth().setReviewerMode(enabled: p.enabled),
    );
  }

  void _registerSettings() {
    _on(ConduitMethodSpecs.settingsGetApp, (_) => _requireSettings().read());
    _on(
      ConduitMethodSpecs.settingsSetApp,
      (patch) => _requireSettings().write(patch),
    );
  }

  SettingsService _requireSettings() =>
      _settings ??
      (throw const RpcError(
        code: ConduitErrorCodes.daemonUnavailable,
        debugMessage: 'the core is not up yet',
      ));

  AccountsService _requireAccounts() =>
      _accounts ??
      (throw const RpcError(
        code: ConduitErrorCodes.daemonUnavailable,
        debugMessage: 'the core is not up yet',
      ));

  ServersService _requireServers() =>
      _servers ??
      (throw const RpcError(
        code: ConduitErrorCodes.daemonUnavailable,
        debugMessage: 'the core is not up yet',
      ));

  AuthService _requireAuth() =>
      _auth ??
      (throw const RpcError(
        code: ConduitErrorCodes.daemonUnavailable,
        debugMessage: 'the core is not up yet',
      ));

  void _requireHandshake() {
    if (_handshake == null) {
      throw const RpcError(
        code: ConduitErrorCodes.protocolViolation,
        debugMessage: 'system.handshake must be the first call on a session',
      );
    }
  }
}
