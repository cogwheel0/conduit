import 'package:dio/dio.dart';
import 'package:meta/meta.dart';
import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/auth/token_validator.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_http_transport.dart';
import 'package:conduit_core/features/push/models/push_status.dart';
import 'package:conduit_core/features/push/models/push_target.dart';
import 'package:conduit_core/features/push/services/hermes_push_backend.dart';
import 'package:conduit_core/features/push/services/openwebui_push_backend.dart';
import 'package:conduit_core/features/push/services/push_backend.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';

/// Opens a [PushBackend] for one target. Each backend is short-lived: the
/// coordinator closes it after one pass.
abstract interface class PushBackendFactory {
  /// A backend for the server [target] names. Throws [PushBackendException]
  /// with `signInNeeded` when the target's session is gone or expired.
  ///
  /// A Hermes [target] is reached with the settings it was listed with: once
  /// its connection is edited to another server, profile or key, only the
  /// settings [retain] kept from before reach the old server, and without
  /// them this throws `connection_changed` rather than reach the new one.
  Future<PushBackend> open(PushTarget target);

  /// Remembers, for this process, how to reach [target]'s server as it is
  /// now, so its subscription can still be removed there after the
  /// connection is edited. Never throws.
  Future<void> retain(PushTarget target);

  /// A Hermes client for the saved connection [connectionId], for cron jobs.
  /// The caller closes it.
  Future<HermesBackendService> openHermesService(String connectionId);

  /// Writes the Open WebUI account [accountId]'s own notifications switch to
  /// its server, as the Notifications page does: through the live client
  /// for the active account, after the settings writes it has queued, and a
  /// client of its own for any other.
  Future<void> setOpenWebUiNotificationsEnabled(
    String accountId, {
    required bool enabled,
  });
}

/// Builds backends from the app's own sessions and saved connections.
///
/// An Open WebUI account gets its own short-lived client, active or not, so
/// an account switch mid-pass never sends one account's token to another's
/// server: the token and the server it was issued for are read together.
final class AppPushBackendFactory implements PushBackendFactory {
  AppPushBackendFactory(this._ref);

  final Ref _ref;

  /// Hermes settings by connection, then by [HermesPushTarget.serverIdentity],
  /// the last few each, so an edited connection's old server stays reachable
  /// until its subscription is gone. In memory only.
  final Map<String, Map<String, HermesConfig>> _retainedHermes = {};
  static const int _retainedPerConnection = 3;

  @override
  Future<PushBackend> open(PushTarget target) => switch (target) {
    OpenWebUiPushTarget() => _openWebUi(target),
    HermesPushTarget() => _hermes(target),
  };

  @override
  Future<void> retain(PushTarget target) async {
    if (target is! HermesPushTarget) return;
    try {
      await hermesConfigFor(target);
    } catch (_) {
      // Nothing to remember; removing the old subscription falls back to a
      // tombstone for its own server.
    }
  }

  Future<ApiService> _openWebUiApi(String accountId) async {
    final session = await _openWebUiSession(accountId);
    if (session == null) throw _signInNeeded;
    final token = session.token;
    if (TokenValidator.validateTokenFormat(token).isExpired) {
      throw _signInNeeded;
    }
    final api = _ref.read(savedCredentialAuthApiFactoryProvider)(
      serverConfig: session.config,
      workerManager: _ref.read(workerManagerProvider),
    );
    api.updateAuthToken(token);
    return api;
  }

  Future<PushBackend> _openWebUi(OpenWebUiPushTarget target) async {
    final api = await _openWebUiApi(target.accountId);
    return OpenWebUiPushBackend(
      dio: api.dio,
      bundledFunction: _ref.read(pushOpenWebUiFunctionSourceProvider),
      onClose: api.dispose,
    );
  }

  @override
  Future<void> setOpenWebUiNotificationsEnabled(
    String accountId, {
    required bool enabled,
  }) async {
    // The active account's write queues behind the app's other settings
    // writes on its live client: each replaces the whole document, so one
    // from a client of its own could undo them.
    final live = _liveOpenWebUi(accountId);
    if (live != null) {
      if (TokenValidator.validateTokenFormat(live.authToken!).isExpired) {
        throw _signInNeeded;
      }
      await live.updateUserNotificationSettings(notificationEnabled: enabled);
      return;
    }
    final api = await _openWebUiApi(accountId);
    try {
      await api.updateUserNotificationSettings(notificationEnabled: enabled);
    } finally {
      api.dispose();
    }
  }

  /// The live client when it is signed in to [accountId], or null.
  ApiService? _liveOpenWebUi(String accountId) {
    final live = _ref.read(apiServiceProvider);
    final token = live?.authToken;
    if (live == null ||
        live.serverConfig.id != accountId ||
        token == null ||
        token.isEmpty) {
      return null;
    }
    return live;
  }

  /// The account's token with the server it belongs to: the live client's
  /// pair for the active account, the vault's for any other.
  Future<({ServerConfig config, String token})?> _openWebUiSession(
    String accountId,
  ) async {
    final live = _liveOpenWebUi(accountId);
    if (live != null) {
      return (config: live.serverConfig, token: live.authToken!);
    }
    final sessions = await _ref
        .read(optimizedStorageServiceProvider)
        .vaultedSessions(accountIds: {accountId});
    return sessions.isEmpty ? null : sessions.first;
  }

  Future<HermesConfig> _hermesConfig(String connectionId) async {
    final HermesConfig config;
    try {
      config =
          (await _ref
                  .read(hermesConfigProvider.notifier)
                  .savedConnectionConfig(connectionId))
              .copyWith(enabled: true);
    } on StateError {
      throw const PushBackendException(
        PushFailure(PushFailureReason.serverRejected, detail: 'no_connection'),
      );
    }
    if (HermesConfig.connectionOrigin(config.baseUrl) == null) {
      throw const PushBackendException(
        PushFailure(PushFailureReason.serverRejected, detail: 'invalid_url'),
      );
    }
    return config;
  }

  HermesDesktopApiService _desktopService(HermesConfig config) =>
      HermesDesktopApiService(
        config: config,
        dashboardBridgeFactory: _ref.read(
          hostHermesDashboardBridgeFactoryProvider,
        ),
        onCredentialsChanged: _ref
            .read(hermesConfigProvider.notifier)
            .credentialsWriterFor(config),
      );

  @override
  Future<HermesBackendService> openHermesService(String connectionId) async {
    final config = await _hermesConfig(connectionId);
    return switch (config.mode) {
      HermesBackendMode.responsesApi => HermesApiService(config: config),
      HermesBackendMode.desktopGateway => _desktopService(config),
    };
  }

  /// The settings that reach [target]'s server: the connection's saved ones
  /// while they still name it, else those kept from before it was edited.
  /// Throws `connection_changed` when neither does, or `invalid_url` when
  /// the saved address is unusable and nothing was kept.
  @visibleForTesting
  Future<HermesConfig> hermesConfigFor(HermesPushTarget target) async {
    final connectionId = target.connectionId;
    HermesConfig? current;
    String? identity;
    PushBackendException? unusable;
    try {
      // The principal is read before and after the settings: an edit that
      // lands in between leaves them unpaired, and they are not used.
      final principal = _principalOf(connectionId);
      final config = await _hermesConfig(connectionId);
      if (principal != null && principal == _principalOf(connectionId)) {
        current = config;
        identity = HermesPushTarget.identityOf(
          baseUrl: config.baseUrl,
          mode: config.mode,
          desktopProfile: config.desktopProfile,
          credentialsRevision: principal,
        );
      }
    } on PushBackendException catch (error) {
      // A connection whose saved address is cleared (an edit under way, or
      // one rolled back) can still reach the old server with the settings
      // kept from before.
      if (error.failure.detail == 'invalid_url') {
        unusable = error;
      } else if (error.failure.detail != 'no_connection') {
        rethrow;
      }
    }
    if (current != null && identity == target.serverIdentity) {
      final kept = _retainedHermes.putIfAbsent(connectionId, () => {});
      kept
        ..remove(identity)
        ..[identity!] = current;
      while (kept.length > _retainedPerConnection) {
        kept.remove(kept.keys.first);
      }
      return current;
    }
    final kept = _retainedHermes[connectionId]?[target.serverIdentity];
    if (kept != null) return kept;
    if (unusable != null) throw unusable;
    throw const PushBackendException(
      PushFailure(
        PushFailureReason.serverRejected,
        detail: 'connection_changed',
      ),
    );
  }

  /// The saved connection's credentials revision (its document-trust
  /// principal), which [HermesPushTarget.credentialsRevision] carries.
  String? _principalOf(String connectionId) {
    for (final profile in _ref.read(hermesConnectionsProvider)) {
      if (profile.id == connectionId) return profile.documentTrustPrincipalId;
    }
    return null;
  }

  Future<PushBackend> _hermes(HermesPushTarget target) async {
    final config = await hermesConfigFor(target);
    switch (config.mode) {
      case HermesBackendMode.responsesApi:
        final key = config.apiKey?.trim() ?? '';
        if (key.isEmpty) {
          throw const PushBackendException(
            PushFailure(
              PushFailureReason.hermesAuthFailed,
              detail: 'missing_api_key',
            ),
          );
        }
        final dio = Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 30),
            headers: {'Authorization': 'Bearer $key'},
          ),
        );
        configureHermesTransport(dio, config);
        return HermesApiPushBackend(
          root: HermesApiPushBackend.rootOf(config.baseUrl),
          dio: dio,
        );
      case HermesBackendMode.desktopGateway:
        return HermesDashboardPushBackend(
          client: HermesDesktopDashboardClient(_desktopService(config)),
          profile: config.desktopProfile,
        );
    }
  }

  static const PushBackendException _signInNeeded = PushBackendException(
    PushFailure(PushFailureReason.serverRejected, detail: 'signed_out'),
    signInNeeded: true,
  );
}

/// The function bundled with the app, which only the host can load (it is a
/// Flutter asset). The default answers that there is none, so admins see
/// "Needs admin setup" instead of an install that cannot work.
final pushOpenWebUiFunctionSourceProvider =
    Provider<OpenWebUiFunctionSourceLoader>(
      (ref) =>
          () async => null,
    );
