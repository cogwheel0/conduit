import 'package:dio/dio.dart';
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
import 'package:conduit_core/services/worker_manager.dart';

/// Opens a [PushBackend] for one target. Each backend is short-lived: the
/// coordinator closes it after one pass.
abstract interface class PushBackendFactory {
  /// Throws [PushBackendException] with `signInNeeded` when the target's
  /// session is gone or expired.
  Future<PushBackend> open(PushTarget target);

  /// A Hermes client for the saved connection [connectionId], for cron jobs.
  /// The caller closes it.
  Future<HermesBackendService> openHermesService(String connectionId);
}

/// Builds backends from the app's own sessions and saved connections.
///
/// An Open WebUI account gets its own short-lived client, active or not, so
/// an account switch mid-pass never sends one account's token to another's
/// server: the token and the server it was issued for are read together.
final class AppPushBackendFactory implements PushBackendFactory {
  AppPushBackendFactory(this._ref);

  final Ref _ref;

  @override
  Future<PushBackend> open(PushTarget target) => switch (target) {
    OpenWebUiPushTarget() => _openWebUi(target),
    HermesPushTarget() => _hermes(target),
  };

  Future<PushBackend> _openWebUi(OpenWebUiPushTarget target) async {
    final session = await _openWebUiSession(target.accountId);
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
    return OpenWebUiPushBackend(
      dio: api.dio,
      bundledFunction: _ref.read(pushOpenWebUiFunctionSourceProvider),
      onClose: api.dispose,
    );
  }

  /// The account's token with the server it belongs to: the live client's
  /// pair for the active account, the vault's for any other.
  Future<({ServerConfig config, String token})?> _openWebUiSession(
    String accountId,
  ) async {
    final live = _ref.read(apiServiceProvider);
    final liveToken = live?.authToken;
    if (live != null &&
        live.serverConfig.id == accountId &&
        liveToken != null &&
        liveToken.isNotEmpty) {
      return (config: live.serverConfig, token: liveToken);
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

  Future<PushBackend> _hermes(HermesPushTarget target) async {
    final config = await _hermesConfig(target.connectionId);
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
