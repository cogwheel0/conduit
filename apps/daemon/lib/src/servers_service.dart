import 'dart:async';
import 'dart:math';

import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
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
    return ServerList(
      servers: configs
          .map((config) => _summarize(config, activeId: activeId))
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
    return list();
  }

  /// Connects to [id], and supersedes everything else.
  ///
  /// This is not the "switch account" that a multi-server sidebar implies,
  /// and the method is named for what the core actually does:
  /// `selectUnauthenticatedServerConfig` deletes the stored auth token,
  /// deletes the saved credentials, and writes back a one-element config
  /// list. That is coherent rather than careless -- the core keeps a single
  /// `auth_token_v3`, so two simultaneous sessions are not a representable
  /// state, and leaving the previous account's token in place while pointing
  /// at a new server is exactly the leak the deletion prevents.
  ///
  /// Callers must confirm with the user first when another server is
  /// configured. The returned list makes the outcome visible rather than
  /// surprising.
  Future<ServerList> connect(String id) async {
    final configs = await _storage.getServerConfigsStrict();
    final config = configs.firstWhere(
      (candidate) => candidate.id == id,
      orElse: () => throw _notFound(id),
    );

    // Through the auth manager rather than writing the active id directly:
    // the sign-out sequencing and the rollback-on-supersede handling live in
    // the core, and skipping them is how a half-switched session happens.
    await _container
        .read(authStateManagerProvider.notifier)
        .selectUnauthenticatedServerConfig(config);
    return list();
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
  static ServerSummary _summarize(ServerConfig config, {String? activeId}) =>
      ServerSummary(
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
