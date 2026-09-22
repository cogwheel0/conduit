import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
import 'package:stream_channel/stream_channel.dart';

import 'auth_service.dart';
import 'event_bus.dart';
import 'log.dart';
import 'servers_service.dart';
import 'settings_service.dart';
import 'system_service.dart';

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
    ServersService? servers,
    AuthService? auth,
    SettingsService? settings,
  }) : _events = events,
       _log = log,
       _system = system,
       _servers = servers,
       _auth = auth,
       _settings = settings,
       _peer = json_rpc.Peer(channel) {
    _register();
  }

  final String sessionId;
  final EventBus _events;
  final DaemonLog _log;
  final SystemService _system;

  /// Null until the core is up. A session can exist before then -- the window
  /// opens while the daemon is still restoring state -- and answering
  /// `servers.list` with an empty list in that window would look to the UI
  /// like a fresh install. It gets `rpc.daemonUnavailable` instead.
  final ServersService? _servers;
  final AuthService? _auth;
  final SettingsService? _settings;
  final json_rpc.Peer _peer;

  /// Set by a successful `system.handshake`. Until then every other method is
  /// refused, so a client cannot skip version negotiation and then be
  /// surprised by a payload it cannot parse.
  HandshakeRequest? _handshake;

  bool get isHandshakeComplete => _handshake != null;

  /// Pending `ui.request` round-trips, keyed by request id.
  final Map<String, Completer<UiResponse>> _pendingUiRequests =
      <String, Completer<UiResponse>>{};

  Future<void> listen() => _peer.listen();

  Future<void> close() async {
    for (final completer in _pendingUiRequests.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          const RpcError(code: ConduitErrorCodes.cancelled),
        );
      }
    }
    _pendingUiRequests.clear();
    _events.detach(sessionId);
    await _peer.close();
  }

  void _register() {
    _events.attach(sessionId, (envelope) {
      // A closed peer still sitting in the bus is a bug, but dropping the
      // event is better than tearing down every other window's fan-out.
      if (_peer.isClosed) return;
      sendEvent(_peer, envelope);
    });

    registerTypedMethod<HandshakeRequest, HandshakeResponse>(
      _peer,
      ConduitMethods.systemHandshake,
      decodeParams: HandshakeRequest.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (request) {
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
      },
    );

    registerTypedMethodNoParams<PongResult>(
      _peer,
      ConduitMethods.systemPing,
      encodeResult: (result) => result.toJson(),
      handler: () {
        _requireHandshake();
        return _system.ping();
      },
    );

    registerTypedMethodNoParams<Capabilities>(
      _peer,
      ConduitMethods.systemCapabilities,
      encodeResult: (result) => result.toJson(),
      handler: () {
        _requireHandshake();
        return _system.capabilities;
      },
    );

    registerTypedMethodNoParams<ShutdownResult>(
      _peer,
      ConduitMethods.systemShutdown,
      encodeResult: (result) => result.toJson(),
      handler: () {
        _requireHandshake();
        return _system.shutdown();
      },
    );

    registerTypedMethodNoParams<DiagnosticsExport>(
      _peer,
      ConduitMethods.systemExportDiagnostics,
      encodeResult: (result) => result.toJson(),
      handler: () {
        _requireHandshake();
        return _system.exportDiagnostics();
      },
    );

    registerTypedMethod<EventSubscription, EventSubscription>(
      _peer,
      ConduitMethods.eventsSubscribe,
      decodeParams: EventSubscription.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (subscription) {
        _requireHandshake();
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
      },
    );

    registerTypedMethod<UiResponse, Map<String, dynamic>>(
      _peer,
      ConduitMethods.uiRespond,
      decodeParams: UiResponse.fromJson,
      encodeResult: (result) => result,
      handler: (response) {
        _requireHandshake();
        final completer = _pendingUiRequests.remove(response.requestId);
        if (completer == null) {
          // Late or duplicate answer — the request already timed out or
          // another window answered first. Not an error worth surfacing.
          _log.debug(
            'session $sessionId: ui.respond for unknown request '
            '${response.requestId}',
          );
          return <String, dynamic>{'accepted': false};
        }
        completer.complete(response);
        return <String, dynamic>{'accepted': true};
      },
    );

    _registerServers();
    _registerAuth();
    _registerSettings();

    _peer.registerFallback((json_rpc.Parameters params) {
      final method = params.method;
      throw RpcError(
        code: ConduitMethods.isReserved(method)
            // A reserved namespace that is not wired up yet is a milestone
            // that has not landed, which is worth telling apart from a typo.
            ? ConduitErrorCodes.unsupported
            : ConduitErrorCodes.methodNotFound,
        args: <String, String>{'method': method},
      ).toException();
    });
  }

  void _registerServers() {
    registerTypedMethodNoParams<ServerList>(
      _peer,
      ConduitMethods.serversList,
      encodeResult: (result) => result.toJson(),
      handler: () {
        _requireHandshake();
        return _requireServers().list();
      },
    );

    registerTypedMethod<ServerDraft, ServerSummary>(
      _peer,
      ConduitMethods.serversAdd,
      decodeParams: ServerDraft.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (draft) {
        _requireHandshake();
        return _requireServers().add(draft);
      },
    );

    registerTypedMethod<ServerDraft, ServerSummary>(
      _peer,
      ConduitMethods.serversUpdate,
      decodeParams: ServerDraft.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (draft) {
        _requireHandshake();
        return _requireServers().update(draft);
      },
    );

    registerTypedMethod<ServerRef, ServerList>(
      _peer,
      ConduitMethods.serversRemove,
      decodeParams: ServerRef.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (ref) {
        _requireHandshake();
        return _requireServers().remove(ref.id);
      },
    );

    registerTypedMethodNoParams<ServerStatus>(
      _peer,
      ConduitMethods.serversStatus,
      encodeResult: (result) => result.toJson(),
      handler: () {
        _requireHandshake();
        return _requireServers().status();
      },
    );

    registerTypedMethod<ServerRef, ServerList>(
      _peer,
      ConduitMethods.serversConnect,
      decodeParams: ServerRef.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (ref) {
        _requireHandshake();
        return _requireServers().connect(ref.id);
      },
    );
  }

  void _registerAuth() {
    registerTypedMethodNoParams<AuthSnapshot>(
      _peer,
      ConduitMethods.authStatus,
      encodeResult: (result) => result.toJson(),
      handler: () {
        _requireHandshake();
        return _requireAuth().status();
      },
    );

    registerTypedMethod<PasswordLogin, AuthSnapshot>(
      _peer,
      ConduitMethods.authLoginWithPassword,
      decodeParams: PasswordLogin.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (params) {
        _requireHandshake();
        return _requireAuth().loginWithPassword(params);
      },
    );

    registerTypedMethod<PasswordLogin, AuthSnapshot>(
      _peer,
      ConduitMethods.authLoginWithLdap,
      decodeParams: PasswordLogin.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (params) {
        _requireHandshake();
        return _requireAuth().loginWithLdap(params);
      },
    );

    registerTypedMethod<ApiKeyLogin, AuthSnapshot>(
      _peer,
      ConduitMethods.authLoginWithApiKey,
      decodeParams: ApiKeyLogin.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (params) {
        _requireHandshake();
        return _requireAuth().loginWithApiKey(params);
      },
    );

    registerTypedMethodNoParams<AuthSnapshot>(
      _peer,
      ConduitMethods.authSilentLogin,
      encodeResult: (result) => result.toJson(),
      handler: () {
        _requireHandshake();
        return _requireAuth().silentLogin();
      },
    );

    registerTypedMethod<ExternalAuthCompletion, AuthSnapshot>(
      _peer,
      ConduitMethods.authCompleteExternal,
      decodeParams: ExternalAuthCompletion.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (params) {
        _requireHandshake();
        return _requireAuth().completeExternal(params);
      },
    );

    registerTypedMethodNoParams<Map<String, dynamic>>(
      _peer,
      ConduitMethods.authHasSavedCredentials,
      encodeResult: (result) => result,
      handler: () async {
        _requireHandshake();
        return <String, dynamic>{
          'hasSavedCredentials': await _requireAuth().hasSavedCredentials(),
        };
      },
    );

    registerTypedMethod<SignOutRequest, SignOutResult>(
      _peer,
      ConduitMethods.authSignOut,
      decodeParams: SignOutRequest.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (request) {
        _requireHandshake();
        return _requireAuth().signOut(request);
      },
    );

    registerTypedMethod<Map<String, dynamic>, AuthSnapshot>(
      _peer,
      ConduitMethods.authSetReviewerMode,
      decodeParams: (json) => json,
      encodeResult: (result) => result.toJson(),
      handler: (params) {
        _requireHandshake();
        final enabled = params['enabled'];
        if (enabled is! bool) {
          throw const RpcError(
            code: ConduitErrorCodes.invalidParams,
            debugMessage: 'auth.setReviewerMode needs a boolean "enabled"',
          );
        }
        return _requireAuth().setReviewerMode(enabled: enabled);
      },
    );
  }

  void _registerSettings() {
    registerTypedMethodNoParams<AppPreferences>(
      _peer,
      ConduitMethods.settingsGetApp,
      encodeResult: (result) => result.toJson(),
      handler: () {
        _requireHandshake();
        return _requireSettings().read();
      },
    );

    registerTypedMethod<AppPreferencesPatch, AppPreferences>(
      _peer,
      ConduitMethods.settingsSetApp,
      decodeParams: AppPreferencesPatch.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (patch) {
        _requireHandshake();
        return _requireSettings().write(patch);
      },
    );
  }

  SettingsService _requireSettings() =>
      _settings ??
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

  /// Asks this window a question and waits for the user.
  ///
  /// Used by the core for tool approvals, Open WebUI input prompts, MCP
  /// approvals, and Hermes decisions.
  Future<UiResponse> requestFromUi(UiRequest request) {
    final completer = Completer<UiResponse>();
    _pendingUiRequests[request.requestId] = completer;
    sendEvent(
      _peer,
      EventEnvelope(
        event: ConduitEvents.uiRequest,
        seq: _events.lastSeq,
        payload: request.toJson(),
      ),
    );

    final timeoutMs = request.timeoutMs;
    if (timeoutMs != null) {
      return completer.future.timeout(
        Duration(milliseconds: timeoutMs),
        onTimeout: () {
          _pendingUiRequests.remove(request.requestId);
          // Falling back to the conservative default is the whole point of
          // `defaultChoice`: a window that never answers must not allow a
          // tool call by omission.
          return UiResponse(
            requestId: request.requestId,
            choice: request.defaultChoice,
          );
        },
      );
    }
    return completer.future;
  }

  void _requireHandshake() {
    if (_handshake == null) {
      throw const RpcError(
        code: ConduitErrorCodes.protocolViolation,
        debugMessage: 'system.handshake must be the first call on a session',
      );
    }
  }
}
