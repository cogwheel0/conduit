import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/models/openwebui_direct_connection.dart';
import 'package:conduit_core/features/direct_connections/models/ollama_keep_alive.dart';
import 'package:conduit_core/features/direct_connections/models/ollama_thinking.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/direct_connections/services/direct_chat_bridge.dart';
import 'package:conduit_core/features/direct_connections/services/direct_provider_adapter.dart';
import 'package:conduit_core/features/direct_connections/services/model_logo_catalog.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';
import 'package:uuid/uuid.dart';

import 'settled.dart';

/// Implements `direct.*`: connections the app talks to itself.
///
/// Everything that decides what is safe is the core's -- validation, the
/// rule that a key does not follow a URL to a new origin, the secure store
/// the profiles live in. This only translates between the protocol, which
/// never carries a secret back out, and the core's profile.
final class DirectService {
  DirectService(this._container);

  final ProviderContainer _container;

  Future<DirectConnectionList> list() async {
    final profiles = await readSettled(
      _container,
      directConnectionProfilesProvider.future,
    );
    await _settleAccountSources();
    final (snapshot: account, failed: accountFailed) = await _openWebUi();
    return DirectConnectionList(
      connections: <DirectConnectionSummary>[
        for (final profile in profiles)
          // Apple's connections are the app's own, managed elsewhere.
          if (profile.adapterKey == kOpenAiCompatibleAdapterKey ||
              profile.adapterKey == kOllamaAdapterKey)
            _summarize(profile),
        for (final record
            in account?.records ?? const <OpenWebUiDirectConnectionRecord>[])
          _summarize(record.profile)
              .copyWith(openWebUi: true, compatible: record.isCompatible),
      ],
      localHistory:
          _container.read(directHistoryPolicyProvider) ==
          DirectHistoryPolicy.localOnly,
      openWebUiAvailable: _container.read(
        openWebUiDirectConnectionsAvailableProvider,
      ),
      openWebUiMovedToTether: _container.read(
        openWebUiDirectConnectionsMovedToTetherProvider,
      ),
      preferred:
          _container.read(preferredBackendProvider) == PreferredBackend.direct,
      usable: await _usable(profiles),
      openWebUiLoadFailed: accountFailed,
    );
  }

  /// Whether Direct can carry the app, as the core decides it when the
  /// last Open WebUI account signs out (`_fallBackWithoutOpenWebUi`): any
  /// effective profile usable -- Apple's on-device one too, while the Mac
  /// offers it -- so a window the core handed over to Direct is a Direct
  /// window. The stored connections alone when that list cannot be read.
  Future<bool> _usable(List<DirectConnectionProfile> stored) async {
    try {
      final effective = await readSettled(
        _container,
        effectiveDirectConnectionProfilesFutureProvider.future,
      );
      return effective.any((profile) => profile.isUsable);
    } on Object {
      return stored.any(
        (profile) =>
            profile.isUsable &&
            (profile.adapterKey == kOpenAiCompatibleAdapterKey ||
                profile.adapterKey == kOllamaAdapterKey),
      );
    }
  }

  /// The Open WebUI account's connections read again, as mobile does when
  /// its page opens, then the list.
  Future<DirectConnectionList> reload() async {
    if (_container.read(openWebUiDirectConnectionsAvailableProvider)) {
      try {
        await _container
            .read(openWebUiDirectConnectionsProvider.notifier)
            .reload();
      } on Object {
        // The list says so; the last connections read stay listed.
      }
    }
    return list();
  }

  /// What applies to every connection's models: images per request, and
  /// the context limits of the models that report no window of their own
  /// (mobile's Context Compaction).
  Future<DirectOptions> options() async {
    List<Model> models;
    try {
      models = (await readSettled(
        _container,
        directModelDiscoveryProvider.future,
      )).models;
    } on Object {
      // No models listed now; the images setting still applies.
      models = const <Model>[];
    }
    final overrides = _container.read(directContextLengthOverridesProvider);
    return DirectOptions(
      imagesPerRequest: _container.read(directMaxImagesPerRequestProvider),
      imagesPerRequestChoices: kDirectMaxImagesPerRequestOptions,
      contextModels: <DirectContextModel>[
        for (final model in models)
          if (directModelAdvertisedContextLength(model) == null)
            DirectContextModel(
              id: model.id,
              name: model.name,
              connection: model.metadata?['profileName'] as String?,
              limit: overrides[model.id] ?? kDefaultDirectContextLength,
              ollama: model.metadata?['adapterKey'] == kOllamaAdapterKey,
              logo: directModelLogoAvatarUrl(model)
                  ?.substring(kModelLogoUrlScheme.length),
            ),
      ],
      contextLimitChoices: kDirectContextLengthOptions,
    );
  }

  Future<DirectOptions> setImagesPerRequest(int count) async {
    if (!kDirectMaxImagesPerRequestOptions.contains(count)) {
      throw RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: '$count is not one of the choices',
      );
    }
    await _container
        .read(directMaxImagesPerRequestProvider.notifier)
        .set(count);
    return options();
  }

  Future<DirectOptions> setContextLimit(DirectContextLimit request) async {
    if (request.modelId.trim().isEmpty || request.tokens <= 0) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'a model and a positive limit',
      );
    }
    await _container
        .read(directContextLengthOverridesProvider.notifier)
        .set(request.modelId, request.tokens);
    return options();
  }

  /// Waits for what decides whether the account can hold connections: the
  /// server's config and this device's identity key. Both load
  /// asynchronously, and read cold the answer is "no" -- which hid the
  /// section from a window that asked straight after signing in.
  Future<void> _settleAccountSources() async {
    final api = _container.read(apiServiceProvider);
    if (api == null) return;
    for (final source in <Future<Object?> Function()>[
      () async {
        // The config answers from a cache first and refreshes behind it; a
        // fresh install has no cache, so ask for the refresh itself.
        final config = await readSettled(
          _container,
          backendConfigProvider.future,
        );
        if (config?.serverId != api.serverConfig.id) {
          await _container.read(backendConfigProvider.notifier).refresh();
        }
        return null;
      },
      () => readSettled(_container, openWebUiDirectIdentityKeyProvider.future),
    ]) {
      try {
        await source();
      } on Object {
        // Unavailable, then; the flag says so.
      }
    }
  }

  /// The connections kept in the Open WebUI account, when the server
  /// allows them and they could be read, with whether this read of them
  /// [failed]: the two go together, so another read meanwhile (another
  /// window's, another account's) never lends a list its own outcome.
  Future<({OpenWebUiDirectConnectionsSnapshot? snapshot, bool failed})>
  _openWebUi() async {
    if (!_container.read(openWebUiDirectConnectionsAvailableProvider)) {
      return (snapshot: null, failed: false);
    }
    try {
      final snapshot = await readSettled(
        _container,
        openWebUiDirectConnectionsProvider.future,
      );
      // A failed reload keeps the last snapshot as data, with the error.
      return (
        snapshot: snapshot,
        failed: _container.read(openWebUiDirectConnectionsProvider).hasError,
      );
    } on Object {
      // Unreadable account settings should not hide this computer's own
      // connections.
      return (
        snapshot: _container.read(openWebUiDirectConnectionsProvider).value,
        failed: true,
      );
    }
  }

  /// [id]'s record in the Open WebUI account, if it is one of those.
  Future<OpenWebUiDirectConnectionRecord?> _accountRecord(String? id) async =>
      id == null ? null : (await _openWebUi()).snapshot?.recordByProfileId(id);

  Future<DirectConnectionList> save(DirectConnectionEdit edit) async {
    final record = await _accountRecord(edit.id);
    if (record != null || (edit.id == null && edit.openWebUi)) {
      return _saveToAccount(edit, record);
    }
    final previous = await _existing(edit.id);
    final profile = apply(edit, previous);
    try {
      await _container
          .read(directConnectionProfilesProvider.notifier)
          .upsert(
            profile,
            expectedPrevious: previous,
            // Only a key typed again in this edit may move with the URL; the
            // core strips the stored ones otherwise.
            secretsConfirmedForNewOrigin: _secretsConfirmed(edit),
          );
    } on DirectConnectionProfileConflictException {
      throw const RpcError(
        code: ConduitErrorCodes.conflict,
        debugMessage: 'the connection changed elsewhere; reopen it',
      );
    } on FormatException catch (error) {
      // The core's validation: a missing name, a URL that is not http(s).
      throw RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: error.message,
      );
    }
    return list();
  }

  /// A connection kept in the Open WebUI account: the core's store writes
  /// it into the user's settings, under the same checks.
  Future<DirectConnectionList> _saveToAccount(
    DirectConnectionEdit edit,
    OpenWebUiDirectConnectionRecord? record,
  ) async {
    if (record != null && !record.isCompatible) {
      throw const RpcError(
        code: ConduitErrorCodes.unsupported,
        debugMessage: 'this connection signs in a way the app cannot use',
      );
    }
    // Open WebUI keeps no name for these -- the core names them after the
    // host on reading -- so a window need not ask for one.
    final named = edit.name.trim().isNotEmpty
        ? edit
        : edit.copyWith(
            name: Uri.tryParse(edit.baseUrl.trim())?.host ?? 'Open WebUI',
          );
    final profile = apply(named, record?.profile);
    final invalid = profile.validateOrNull();
    if (invalid != null) {
      throw RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: invalid,
      );
    }
    final controller = _container.read(
      openWebUiDirectConnectionsProvider.notifier,
    );
    try {
      if (record == null) {
        await controller.add(profile);
      } else {
        // The sign-in the form chose: Open WebUI keeps a key only under
        // bearer.
        await controller.updateConnection(
          record,
          profile,
          authType: openWebUiAuthType(named, record.authType),
        );
      }
    } on StateError catch (error) {
      throw RpcError(
        code: ConduitErrorCodes.conflict,
        debugMessage: error.message,
      );
    }
    return list();
  }

  Future<DirectConnectionList> remove(String id) async {
    if (await _accountRecord(id) case final record?) {
      await _container
          .read(openWebUiDirectConnectionsProvider.notifier)
          .delete(record);
      return list();
    }
    await _container.read(directConnectionProfilesProvider.notifier).remove(id);
    return list();
  }

  Future<DirectConnectionList> setEnabled(String id, bool enabled) async {
    if (await _accountRecord(id) case final record?) {
      await _container
          .read(openWebUiDirectConnectionsProvider.notifier)
          .updateConnection(
            record,
            record.profile.copyWith(enabled: enabled),
            authType: record.authType,
          );
      return list();
    }
    await _container
        .read(directConnectionProfilesProvider.notifier)
        .setEnabled(id, enabled);
    return list();
  }

  /// The connection as edited, tried without being saved.
  Future<DirectTestResult> test(DirectConnectionEdit edit) async {
    final previous = await _existing(edit.id);
    final profile = apply(edit, previous);
    final invalid = profile.validateOrNull();
    if (invalid != null) {
      return DirectTestResult(reachable: false, message: invalid);
    }
    final probe = await _container
        .read(directConnectionProfilesProvider.notifier)
        .probe(profile);
    return DirectTestResult(
      reachable: probe.reachable,
      modelCount: probe.modelCount,
      message: probe.message,
    );
  }

  /// The welcome screen's choice: direct connections as the way the app
  /// is used, or back to a server.
  Future<DirectConnectionList> setPreferred({required bool preferred}) async {
    await _container
        .read(preferredBackendProvider.notifier)
        .set(preferred ? PreferredBackend.direct : PreferredBackend.owui);
    return list();
  }

  Future<DirectConnectionList> setHistory({required bool localOnly}) async {
    await _container
        .read(directHistoryPolicyProvider.notifier)
        .setPolicy(
          localOnly
              ? DirectHistoryPolicy.localOnly
              : DirectHistoryPolicy.syncWithOpenWebUI,
        );
    return list();
  }

  /// An Ollama connection's models and what can be done to them.
  ///
  /// Listed from the server itself rather than from the model picker, so a
  /// connection that is switched off can still be managed.
  Future<OllamaModelList> ollamaModels(String id) async {
    final profile = await _ollama(id);
    final adapter = _container
        .read(directProviderAdapterRegistryProvider)
        .require(profile.adapterKey);
    final models = await adapter.listModels(profile);
    Set<String>? loaded;
    if (profile.supportsOllamaModelLifecycle &&
        adapter is DirectModelLifecycleAdapter) {
      try {
        loaded = await (adapter as DirectModelLifecycleAdapter)
            .listRunningModelIds(profile);
      } on Object {
        loaded = null;
      }
    }
    return OllamaModelList(
      lifecycle: profile.supportsOllamaModelLifecycle,
      cloud: profile.isOllamaCloud,
      models: <OllamaModelStatus>[
        for (final model in models)
          OllamaModelStatus(
            id: model.id,
            name: model.name,
            loaded: loaded?.contains(model.id),
            keepAlive: profile.ollamaKeepAliveFor(model.id),
            thinking: profile.ollamaThinkingFor(model.id)?.storageValue,
            logo: installedModelLogoCatalog?.logoFor(
              remoteModelId: model.id,
              baseHost: Uri.tryParse(profile.baseUrl)?.host,
              adapterKey: profile.adapterKey,
            ),
          ),
      ],
    );
  }

  Future<OllamaModelList> ollamaLoad(OllamaModelAction action) async {
    final profile = await _ollama(action.id);
    final configured = profile.ollamaKeepAliveFor(action.model);
    // `0` means "unload after the request", which would undo the load
    // straight away: warm it for the server's default instead, as mobile
    // does. Chats still honour the saved zero.
    await _lifecycle(profile).loadModel(
      profile,
      action.model,
      keepAlive: configured == '0' ? null : configured,
    );
    return ollamaModels(action.id);
  }

  Future<OllamaModelList> ollamaUnload(OllamaModelAction action) async {
    final profile = await _ollama(action.id);
    await _lifecycle(profile).unloadModel(profile, action.model);
    return ollamaModels(action.id);
  }

  Future<OllamaModelList> ollamaKeepAlive(OllamaModelAction action) async {
    final profile = await _ollama(action.id);
    final String? value;
    try {
      value = action.value == null
          ? null
          : normalizeOllamaKeepAlive(action.value!);
    } on FormatException catch (error) {
      throw RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: error.message,
      );
    }
    final updated = Map<String, String>.of(profile.ollamaKeepAliveByModel);
    if (value == null) {
      updated.remove(action.model.trim());
    } else {
      updated[action.model.trim()] = value;
    }
    await _container
        .read(directConnectionProfilesProvider.notifier)
        .upsert(
          profile.copyWith(ollamaKeepAliveByModel: updated),
          expectedPrevious: profile,
        );
    return ollamaModels(action.id);
  }

  Future<OllamaModelList> ollamaThinking(OllamaModelAction action) async {
    await _ollama(action.id);
    final OllamaThinkingSetting? setting;
    try {
      setting = action.value == null
          ? null
          : OllamaThinkingSetting.fromStorage(action.value!);
    } on FormatException catch (error) {
      throw RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: error.message,
      );
    }
    await _container
        .read(directConnectionProfilesProvider.notifier)
        .setOllamaThinking(action.id, action.model, setting);
    return ollamaModels(action.id);
  }

  Future<DirectConnectionProfile> _ollama(String id) async {
    final profile = (await _existing(id))!;
    if (profile.adapterKey != kOllamaAdapterKey) {
      throw RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'connection $id is not an Ollama server',
      );
    }
    return profile;
  }

  DirectModelLifecycleAdapter _lifecycle(DirectConnectionProfile profile) {
    final adapter = _container
        .read(directProviderAdapterRegistryProvider)
        .require(profile.adapterKey);
    if (!profile.supportsOllamaModelLifecycle ||
        adapter is! DirectModelLifecycleAdapter) {
      throw const RpcError(
        code: ConduitErrorCodes.unsupported,
        debugMessage: 'Ollama Cloud does not load or unload models',
      );
    }
    return adapter as DirectModelLifecycleAdapter;
  }

  Future<DirectConnectionProfile?> _existing(String? id) async {
    if (id == null) return null;
    if (await _accountRecord(id) case final record?) return record.profile;
    final profiles = await readSettled(
      _container,
      directConnectionProfilesProvider.future,
    );
    final found = profiles.where((profile) => profile.id == id).firstOrNull;
    if (found == null) {
      throw RpcError(
        code: ConduitErrorCodes.notFound,
        debugMessage: 'no connection $id',
      );
    }
    return found;
  }

  /// The Open WebUI `auth_type` to store for an account connection [edit]
  /// changes, [stored] before it.
  static String openWebUiAuthType(DirectConnectionEdit edit, String stored) =>
      switch (edit.apiKey) {
        null => stored,
        final key when key.trim().isEmpty => 'none',
        _ => 'bearer',
      };

  /// Whether [edit] typed the key or the headers again, which is what lets
  /// them move with a URL to a new origin. A client certificate typed for
  /// the new place is not: the core keeps no TLS setting across origins.
  static bool _secretsConfirmed(DirectConnectionEdit edit) =>
      edit.apiKey != null || typesHeaders(edit.customHeaders);

  /// [edit] over [previous], or a new profile. Secrets follow the servers
  /// rule: null keeps, empty clears.
  ///
  /// When the edit moves the connection to another origin, the stored
  /// secrets stay behind unless this edit typed them again -- the core's
  /// [DirectConnectionProfile.secureUpdate] rule. Here rather than only in
  /// the local store, because a test probe and a save into the Open WebUI
  /// account both take this profile too. Public for the daemon's tests.
  static DirectConnectionProfile apply(
    DirectConnectionEdit edit,
    DirectConnectionProfile? previous,
  ) {
    final applied = _apply(edit, previous);
    if (previous == null) return applied;
    // Somewhere else, only what was typed again goes along: a header typed
    // again takes no saved key, and a key no saved header.
    final moved = previous.origin != applied.origin
        ? applied.copyWith(
            apiKey: edit.apiKey == null ? null : applied.apiKey,
            customHeaders: mergeCustomHeaders(edit.customHeaders, null),
          )
        : applied;
    return DirectConnectionProfile.secureUpdate(
      previous: previous,
      next: moved,
      secretsConfirmedForNewOrigin: _secretsConfirmed(edit),
    );
  }

  static DirectConnectionProfile _apply(
    DirectConnectionEdit edit,
    DirectConnectionProfile? previous,
  ) {
    final adapterKey = edit.kind == DirectKind.ollama
        ? kOllamaAdapterKey
        : kOpenAiCompatibleAdapterKey;
    final apiMode = edit.apiMode == DirectApiMode.responses
        ? DirectOpenAiApiMode.responses
        : DirectOpenAiApiMode.chatCompletions;
    final authMode = edit.apiKeyHeader
        ? DirectApiKeyAuthMode.apiKeyHeader
        : DirectApiKeyAuthMode.bearer;
    String? key(String? given, String? stored) =>
        given == null ? stored : (given.trim().isEmpty ? null : given.trim());
    // A PEM and the name it was picked under move together: a new file
    // brings its name, clearing one clears both.
    String? pem(String? given, String? stored) =>
        given == null ? stored : (given.trim().isEmpty ? null : given);
    String? label(String? pemGiven, String? labelGiven, String? stored) =>
        pemGiven == null
        ? stored
        : (pemGiven.trim().isEmpty ? null : labelGiven);
    final tags = <String>[
      for (final tag in edit.tags)
        if (tag.trim().isNotEmpty) tag.trim(),
    ];

    if (previous == null) {
      return DirectConnectionProfile(
        id: const Uuid().v4(),
        name: edit.name.trim(),
        adapterKey: adapterKey,
        baseUrl: edit.baseUrl.trim(),
        openAiApiMode: apiMode,
        apiKeyAuthMode: authMode,
        apiVersion: edit.apiVersion,
        modelIdPrefix: edit.modelIdPrefix,
        enabled: edit.enabled,
        apiKey: key(edit.apiKey, null),
        customHeaders: mergeCustomHeaders(edit.customHeaders, null),
        manualModelIds: edit.manualModelIds,
        allowSelfSignedCertificates: edit.allowSelfSignedCertificates,
        tags: tags,
        mtlsCertificateChainPem: pem(edit.certificatePem, null),
        mtlsCertificateLabel: label(
          edit.certificatePem,
          edit.certificateLabel,
          null,
        ),
        mtlsPrivateKeyPem: pem(edit.privateKeyPem, null),
        mtlsPrivateKeyLabel: label(
          edit.privateKeyPem,
          edit.privateKeyLabel,
          null,
        ),
        mtlsPrivateKeyPassword: key(edit.privateKeyPassword, null),
      );
    }
    return previous.copyWith(
      name: edit.name.trim(),
      adapterKey: adapterKey,
      baseUrl: edit.baseUrl.trim(),
      openAiApiMode: apiMode,
      apiKeyAuthMode: authMode,
      apiVersion: edit.apiVersion,
      modelIdPrefix: edit.modelIdPrefix,
      enabled: edit.enabled,
      apiKey: key(edit.apiKey, previous.apiKey),
      customHeaders: mergeCustomHeaders(
        edit.customHeaders,
        previous.customHeaders,
      ),
      manualModelIds: edit.manualModelIds,
      allowSelfSignedCertificates: edit.allowSelfSignedCertificates,
      tags: tags,
      mtlsCertificateChainPem: pem(
        edit.certificatePem,
        previous.mtlsCertificateChainPem,
      ),
      mtlsCertificateLabel: label(
        edit.certificatePem,
        edit.certificateLabel,
        previous.mtlsCertificateLabel,
      ),
      mtlsPrivateKeyPem: pem(edit.privateKeyPem, previous.mtlsPrivateKeyPem),
      mtlsPrivateKeyLabel: label(
        edit.privateKeyPem,
        edit.privateKeyLabel,
        previous.mtlsPrivateKeyLabel,
      ),
      mtlsPrivateKeyPassword: key(
        edit.privateKeyPassword,
        previous.mtlsPrivateKeyPassword,
      ),
    );
  }

  static DirectConnectionSummary _summarize(DirectConnectionProfile profile) =>
      DirectConnectionSummary(
        id: profile.id,
        name: profile.name,
        kind: profile.adapterKey == kOllamaAdapterKey
            ? DirectKind.ollama
            : DirectKind.openai,
        baseUrl: profile.baseUrl,
        apiMode: profile.openAiApiMode == DirectOpenAiApiMode.responses
            ? DirectApiMode.responses
            : DirectApiMode.chat,
        apiVersion: profile.apiVersion,
        apiKeyHeader:
            profile.apiKeyAuthMode == DirectApiKeyAuthMode.apiKeyHeader,
        modelIdPrefix: profile.modelIdPrefix,
        enabled: profile.enabled,
        hasApiKey: (profile.apiKey ?? '').isNotEmpty,
        customHeaderNames: profile.customHeaders.keys.toList(growable: false),
        tags: profile.tags,
        certificateLabel: profile.mtlsCertificateChainPem == null
            ? null
            : (profile.mtlsCertificateLabel ?? 'certificate.pem'),
        privateKeyLabel: profile.mtlsPrivateKeyPem == null
            ? null
            : (profile.mtlsPrivateKeyLabel ?? 'key.pem'),
        manualModelIds: profile.manualModelIds,
        allowSelfSignedCertificates: profile.allowSelfSignedCertificates,
        openRouter: profile.isOpenRouter,
        ollamaCloud: profile.isOllamaCloud,
      );
}

/// Custom headers as an edit gives them over [stored]: the window knows
/// saved headers by name only, so null keeps them, an empty set clears them,
/// and otherwise each header given replaces the saved one of its name (in
/// any case), an empty value taking it away.
Map<String, String> mergeCustomHeaders(
  Map<String, String>? given,
  Map<String, String>? stored,
) {
  if (given == null) return stored ?? const <String, String>{};
  if (given.isEmpty) return const <String, String>{};
  final out = <String, String>{...?stored};
  for (final MapEntry(:key, :value) in given.entries) {
    out.removeWhere((name, _) => name.toLowerCase() == key.toLowerCase());
    if (value.trim().isNotEmpty) out[key] = value;
  }
  return out;
}

/// Whether [headers] types a header value again (an empty set, or only
/// headers taken away, types none).
bool typesHeaders(Map<String, String>? headers) =>
    headers?.values.any((value) => value.trim().isNotEmpty) ?? false;
