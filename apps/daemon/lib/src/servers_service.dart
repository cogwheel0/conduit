import 'dart:async';

import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/services/api_service.dart' show HealthCheckResult;
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/utils/server_version_compat.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';

import 'settled.dart';
import 'voice_service.dart';

/// Implements `servers.update` and `servers.status` over the core's storage
/// service.
///
/// Adding, removing and switching accounts -- each a saved server entry --
/// is `accounts.*`, over the core's accounts controller, which keeps the
/// account registry and its data purge in step. What stays here is editing
/// the server an account is on, and asking how the active one is doing.
///
/// The one rule this file exists to enforce is that nothing secret leaves.
/// [summarize] is the only path from a `ServerConfig` to the wire, and it
/// names each field it copies rather than spreading the object, so adding a
/// secret to `ServerConfig` cannot silently start publishing it.
final class ServersService {
  ServersService(this._container);

  final ProviderContainer _container;

  OptimizedStorageService get _storage =>
      _container.read(optimizedStorageServiceProvider);

  /// Edits in place. A null secret means "leave alone", which is what lets
  /// the setup form save a rename without ever having been given the key.
  Future<ServerSummary> update(ServerDraft draft) async {
    final id = draft.id;
    if (id == null) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'servers.update needs an id',
      );
    }
    final configs = await _storage.getServerConfigsStrict();
    final index = configs.indexWhere((config) => config.id == id);
    if (index < 0) throw _notFound(id);

    final existing = configs[index];
    final updated = existing.copyWith(
      name: validateName(draft.name),
      url: validateUrl(draft.url),
      allowSelfSignedCertificates: draft.allowSelfSignedCertificates,
      customHeaders: draft.customHeaders ?? existing.customHeaders,
      mtlsCertificateChainPem: draft.clearMutualTls
          ? null
          : (draft.mtlsCertificateChainPem ?? existing.mtlsCertificateChainPem),
      mtlsCertificateLabel: draft.clearMutualTls
          ? null
          : (draft.mtlsCertificateLabel ?? existing.mtlsCertificateLabel),
      mtlsPrivateKeyPem: draft.clearMutualTls
          ? null
          : (draft.mtlsPrivateKeyPem ?? existing.mtlsPrivateKeyPem),
      mtlsPrivateKeyLabel: draft.clearMutualTls
          ? null
          : (draft.mtlsPrivateKeyLabel ?? existing.mtlsPrivateKeyLabel),
      mtlsPrivateKeyPassword: draft.clearMutualTls
          ? null
          : (draft.mtlsPrivateKeyPassword ?? existing.mtlsPrivateKeyPassword),
    );

    final next = <ServerConfig>[...configs]..[index] = updated;
    final hadSession = await _storage.getAuthTokenStrict() != null;
    await _storage.saveServerConfigs(next);
    await _endSessionIfMoved(hadSession: hadSession);
    _republishServerConfigs();
    return summarize(
      updated,
      hasStoredSession: (await _storage.accountIdsWithSession()).contains(id),
    );
  }

  /// Ends the live session when the save moved the active account's server
  /// to another address or client identity.
  ///
  /// Storage judges that, and drops the saved token when it does: the
  /// session belongs to the old address. That holds for an edit to another
  /// account too, as accounts on one server share its address. The auth
  /// manager still holds the session, though, and the client rebuilt for the
  /// new address would send it there. So it is ended here, before
  /// [_republishServerConfigs] rebuilds the client; the account then needs a
  /// sign-in on the new address.
  Future<void> _endSessionIfMoved({required bool hadSession}) async {
    if (!hadSession) return;
    if (await _storage.getAuthTokenStrict() != null) return;
    await _container
        .read(authStateManagerProvider.notifier)
        .onTokenInvalidated();
  }

  /// The live state of the active server.
  ///
  /// Deliberately never throws for an unreachable server. "I could not reach
  /// it, and here is the code" is the answer the connection-issue page exists
  /// to render; turning it into an RPC error would leave that page with
  /// nothing to say but "something went wrong".
  Future<ServerStatus> status() async {
    final activeId = await _storage.getActiveServerId();
    if (activeId == null) {
      return const ServerStatus(
        maxSupportedVersion: ServerVersionCompat.maxSupportedVersion,
      );
    }

    // Await the active server before reading the client. `apiServiceProvider`
    // is synchronous and derives from an async one, so immediately after a
    // connect it is still null -- not because there is no server, but because
    // the provider it depends on has not resolved yet. Reading it directly
    // here reported "unknown" for a server that was about to work.
    await readSettled(_container, activeServerProvider.future);
    final api = _container.read(apiServiceProvider);
    if (api == null) {
      return ServerStatus(
        activeServerId: activeId,
        reachability: ServerReachability.unknown,
        maxSupportedVersion: ServerVersionCompat.maxSupportedVersion,
      );
    }

    // `verifyAndGetConfig`, not `backendConfigProvider`. That provider hands
    // back the *cached* config and refreshes in the background, so on a first
    // connection it is null simply because nothing has been fetched yet --
    // which this used to report as "not an Open WebUI server", the one answer
    // guaranteed to send the user back to re-check a URL that was correct.
    //
    // The probe returns a config, or null for every failure: a request
    // that never arrived as much as an answer that is not Open WebUI's.
    // `/health` tells those apart, because every Open WebUI serves it. A
    // server out of reach used to be reported as "not Open WebUI", which
    // sends the user to re-check an address that is fine.
    final BackendConfig? config;
    try {
      config = await api.verifyAndGetConfig();
    } on Object catch (error) {
      return _unreachable(activeId, error);
    }

    if (config == null) {
      try {
        final health = await api.checkHealthWithProxyDetection();
        if (health == HealthCheckResult.unreachable) {
          return _unreachable(activeId, null);
        }
      } on Object catch (error) {
        return _unreachable(activeId, error);
      }
      return ServerStatus(
        activeServerId: activeId,
        reachability: ServerReachability.notOpenWebUi,
        errorCode: ConduitErrorCodes.connectionFailed,
        maxSupportedVersion: ServerVersionCompat.maxSupportedVersion,
      );
    }

    return ServerStatus(
      activeServerId: activeId,
      capabilities: capabilitiesFor(config),
      reachability: ServerReachability.reachable,
      version: config.version,
      isVersionSupported: config.isVersionSupported,
      maxSupportedVersion: ServerVersionCompat.maxSupportedVersion,
    );
  }

  static ServerStatus _unreachable(String activeId, Object? error) =>
      ServerStatus(
        activeServerId: activeId,
        reachability: ServerReachability.unreachable,
        errorCode: error is RpcError
            ? error.code
            : ConduitErrorCodes.connectionFailed,
        maxSupportedVersion: ServerVersionCompat.maxSupportedVersion,
      );

  /// Projects the server's config onto the protocol's capability flags.
  ///
  /// The UI gates navigation on these rather than reading a server config it
  /// does not have, which is the whole reason the flags exist. Anything the
  /// server does not mention stays false: an unknown capability is one the
  /// UI must not offer, because offering it produces a sidebar entry that
  /// dead-ends.
  ///
  /// The flags with no `BackendConfig` counterpart -- Hermes, the terminal,
  /// the Apple helper, the parity-plus features -- are left off here; the
  /// services that implement them answer for themselves.
  static Capabilities capabilitiesFor(BackendConfig config) => Capabilities(
    // Open WebUI has no feature flag for these; they exist on every server
    // this app supports, and the sidebar entries are always meaningful.
    workspace: true,
    notes: true,
    channels: config.enableWebsocket ?? false,
    directConnections: config.enableDirectConnections ?? false,
    serverStt: VoiceService.transcribes(config),
    serverTts: VoiceService.speaks(config),
    // Browser speech synthesis, available wherever the renderer runs.
    deviceTts: true,
    branchNavigation: true,
    // Open WebUI's own client treats an unset flag as on.
    messageRating: config.enableMessageRating ?? true,
    tags: true,
    bulkSelection: true,
  );

  /// Tells the providers that stored configuration changed.
  ///
  /// These writes go straight to `OptimizedStorageService`, which the
  /// providers cache in front of -- so without this, adding the very first
  /// server leaves `serverConfigsProvider` holding the empty list it built
  /// before the server existed, and `apiServiceProvider` therefore stays
  /// null. Every later call then behaves as though no server were
  /// configured, which surfaces as a sign-in that fails for no visible
  /// reason.
  ///
  /// Not covered by the invalidation inside `switchToAccount`: that
  /// method returns early when the target is already the active server, and
  /// a lone stored config *is* already active by the storage layer's own
  /// fallback -- so the first connect after the first add does nothing at
  /// all.
  void _republishServerConfigs() {
    _container
      ..invalidate(serverConfigsProvider)
      ..invalidate(activeServerProvider)
      ..invalidate(apiServiceProvider);
  }

  /// The only `ServerConfig` -> wire conversion.
  ///
  /// Field-by-field on purpose. A spread or a generated mapper would publish
  /// whatever gets added to `ServerConfig` next, and three of its fields are
  /// private keys.
  ///
  /// [activeId] rather than `config.isActive`, when it is known. The stored
  /// flag and the stored active id are two records of one fact, and the id is
  /// the one the core resolves against -- so trusting the flag can produce a
  /// list where `activeServerId` points at a server that reports
  /// `isActive: false`, or at two servers that both report true.
  static ServerSummary summarize(
    ServerConfig config, {
    String? activeId,
    bool hasStoredSession = false,
  }) => ServerSummary(
    id: config.id,
    name: config.name,
    url: config.url,
    isActive: activeId == null ? config.isActive : config.id == activeId,
    lastConnectedMs: config.lastConnected?.millisecondsSinceEpoch,
    allowSelfSignedCertificates: config.allowSelfSignedCertificates,
    hasMutualTlsCredentials: config.hasMutualTlsCredentials,
    mtlsCertificateLabel: config.mtlsCertificateLabel,
    mtlsPrivateKeyLabel: config.mtlsPrivateKeyLabel,
    customHeaderNames: config.customHeaders.keys.toList(growable: false)
      ..sort(),
    hasStoredSession: hasStoredSession,
  );

  static RpcError _notFound(String id) => RpcError(
    code: ConduitErrorCodes.notFound,
    args: <String, String>{'id': id},
    debugMessage: 'no server with id $id',
  );

  /// Rejects anything that is not an absolute http(s) URL.
  ///
  /// Not cosmetic: a `file:` or `data:` URL reaching the request layer would
  /// make the daemon read local files on behalf of the renderer.
  static String validateUrl(String url) {
    final trimmed = url.trim();
    final parsed = Uri.tryParse(trimmed);
    if (parsed == null ||
        !parsed.isAbsolute ||
        (parsed.scheme != 'http' && parsed.scheme != 'https') ||
        parsed.host.isEmpty) {
      throw RpcError(
        code: ConduitErrorCodes.invalidParams,
        args: <String, String>{'url': trimmed},
        debugMessage: 'server url must be an absolute http(s) URL',
      );
    }
    // `user:password@` would be stored, and sent back in every summary;
    // a server's credentials go in the sign-in, never in its address. Not
    // echoed in the error either.
    if (parsed.userInfo.isNotEmpty) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        args: <String, String>{'reason': 'userInfo'},
        debugMessage: 'a server url must not carry a user or password',
      );
    }
    // Stored without a trailing slash so two spellings of the same server do
    // not become two servers.
    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }

  static String validateName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'server name must not be empty',
      );
    }
    return trimmed;
  }
}
