import 'dart:async';
import 'dart:math';

import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/utils/server_version_compat.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';

/// Implements the `servers.*` family over the core's storage service.
///
/// The one rule this file exists to enforce is that nothing secret leaves.
/// [_summarize] is the only path from a `ServerConfig` to the wire, and it
/// names each field it copies rather than spreading the object, so adding a
/// secret to `ServerConfig` cannot silently start publishing it.
final class ServersService {
  ServersService(this._container);

  final ProviderContainer _container;

  OptimizedStorageService get _storage =>
      _container.read(optimizedStorageServiceProvider);

  Future<ServerList> list() async {
    final configs = await _storage.getServerConfigsStrict();
    final activeId = await _storage.getActiveServerId();
    final vaulted = await _storage.vaultedServerIds();
    // The active server's session is in the live slot rather than the vault,
    // so it needs asking about separately -- otherwise the server you are
    // signed into is the one server that does not say so.
    final activeSignedIn =
        _container.read(authStateManagerProvider).value?.isAuthenticated ??
        false;
    return ServerList(
      servers: configs
          .map(
            (config) => _summarize(
              config,
              activeId: activeId,
              hasStoredSession: config.id == activeId
                  ? activeSignedIn
                  : vaulted.contains(config.id),
            ),
          )
          .toList(growable: false),
      activeServerId: activeId,
    );
  }

  Future<ServerSummary> add(ServerDraft draft) async {
    final url = _validateUrl(draft.url);
    final configs = await _storage.getServerConfigsStrict();
    final config = ServerConfig(
      id: _newId(),
      name: _validateName(draft.name),
      url: url,
      customHeaders: draft.customHeaders ?? const <String, String>{},
      allowSelfSignedCertificates: draft.allowSelfSignedCertificates,
      mtlsCertificateChainPem: draft.mtlsCertificateChainPem,
      mtlsCertificateLabel: draft.mtlsCertificateLabel,
      mtlsPrivateKeyPem: draft.mtlsPrivateKeyPem,
      mtlsPrivateKeyLabel: draft.mtlsPrivateKeyLabel,
      mtlsPrivateKeyPassword: draft.mtlsPrivateKeyPassword,
    );
    await _storage.saveServerConfigs(<ServerConfig>[...configs, config]);
    _republishServerConfigs();
    return _summarize(config);
  }

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
      name: _validateName(draft.name),
      url: _validateUrl(draft.url),
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
    await _storage.saveServerConfigs(next);
    _republishServerConfigs();
    return _summarize(updated);
  }

  Future<ServerList> remove(String id) async {
    final configs = await _storage.getServerConfigsStrict();
    if (!configs.any((config) => config.id == id)) throw _notFound(id);

    await _storage.saveServerConfigs(
      configs.where((config) => config.id != id).toList(growable: false),
    );
    // Removing the active server leaves no active server, rather than
    // silently promoting whichever one happens to be next in the list --
    // that would connect the user somewhere they did not ask to go.
    if (await _storage.getActiveServerId() == id) {
      await _storage.setActiveServerId(null);
    }
    _republishServerConfigs();
    return list();
  }

  /// The live state of the active server (WP-2.2).
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
    await _container.read(activeServerProvider.future);
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
    // This probe also gives exactly the three outcomes the UI distinguishes:
    // it throws when the request did not arrive, returns null when something
    // answered but is not Open WebUI, and returns a config otherwise.
    final BackendConfig? config;
    try {
      config = await api.verifyAndGetConfig();
    } on Object catch (error) {
      return ServerStatus(
        activeServerId: activeId,
        reachability: ServerReachability.unreachable,
        errorCode: error is RpcError
            ? error.code
            : ConduitErrorCodes.connectionFailed,
        maxSupportedVersion: ServerVersionCompat.maxSupportedVersion,
      );
    }

    if (config == null) {
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

  /// Projects the server's config onto the protocol's capability flags.
  ///
  /// The UI gates navigation on these rather than reading a server config it
  /// does not have, which is the whole reason the flags exist. Anything the
  /// server does not mention stays false: an unknown capability is one the
  /// UI must not offer, because offering it produces a sidebar entry that
  /// dead-ends.
  ///
  /// The flags with no `BackendConfig` counterpart -- Hermes, the terminal,
  /// the Apple helper, the parity-plus features -- are left off until the
  /// milestones that implement them can answer honestly.
  static Capabilities capabilitiesFor(BackendConfig config) => Capabilities(
    // Open WebUI has no feature flag for these; they exist on every server
    // this app supports, and the sidebar entries are always meaningful.
    workspace: true,
    notes: true,
    channels: config.enableWebsocket ?? false,
    directConnections: config.enableDirectConnections ?? false,
    serverStt: config.enableAudioInput ?? false,
    serverTts: config.enableAudioOutput ?? false,
    // Browser speech synthesis, available wherever the renderer runs.
    deviceTts: true,
    branchNavigation: true,
    messageRating: true,
    tags: true,
    bulkSelection: true,
  );

  /// Makes [id] the active server, keeping the others.
  ///
  /// Goes through `switchToServerConfig` rather than
  /// `selectUnauthenticatedServerConfig`: the latter is the onboarding path
  /// and deliberately drops the token, the saved credentials and every other
  /// server, which is right for "connect for the first time" and wrong for
  /// "switch account".
  Future<ServerList> connect(String id) async {
    final configs = await _storage.getServerConfigsStrict();
    final config = configs.firstWhere(
      (candidate) => candidate.id == id,
      orElse: () => throw _notFound(id),
    );

    // Through the auth manager rather than writing the active id directly:
    // the token exchange, the client rebind and the rollback-on-supersede
    // handling live in the core, and skipping them is how a half-switched
    // session happens.
    await _container
        .read(authStateManagerProvider.notifier)
        .switchToServerConfig(config);
    return list();
  }

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
  /// Not covered by the invalidation inside `switchToServerConfig`: that
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
  static ServerSummary _summarize(
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
  static String _validateUrl(String url) {
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
    // Stored without a trailing slash so two spellings of the same server do
    // not become two servers.
    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }

  static String _validateName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'server name must not be empty',
      );
    }
    return trimmed;
  }

  static final Random _random = Random.secure();

  /// A v4 UUID, matching the ids the mobile app already writes.
  static String _newId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    String hex(int start, int end) => bytes
        .sublist(start, end)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-'
        '${hex(10, 16)}';
  }
}
