import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/models/openwebui_direct_connection.dart';
import 'package:conduit_core/features/direct_connections/models/ollama_keep_alive.dart';
import 'package:conduit_core/features/direct_connections/models/ollama_thinking.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/direct_connections/services/direct_provider_adapter.dart';
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
    final account = await _openWebUi();
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
      preferred:
          _container.read(preferredBackendProvider) == PreferredBackend.direct,
      usable: profiles.any(
        (profile) =>
            profile.isUsable &&
            (profile.adapterKey == kOpenAiCompatibleAdapterKey ||
                profile.adapterKey == kOllamaAdapterKey),
      ),
    );
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
  /// allows them and they could be read.
  Future<OpenWebUiDirectConnectionsSnapshot?> _openWebUi() async {
    if (!_container.read(openWebUiDirectConnectionsAvailableProvider)) {
      return null;
    }
    try {
      return await readSettled(
        _container,
        openWebUiDirectConnectionsProvider.future,
      );
    } on Object {
      // Unreadable account settings should not hide this computer's own
      // connections.
      return null;
    }
  }

  /// [id]'s record in the Open WebUI account, if it is one of those.
  Future<OpenWebUiDirectConnectionRecord?> _accountRecord(String? id) async =>
      id == null ? null : (await _openWebUi())?.recordByProfileId(id);

  Future<DirectConnectionList> save(DirectConnectionEdit edit) async {
    final record = await _accountRecord(edit.id);
    if (record != null || (edit.id == null && edit.openWebUi)) {
      return _saveToAccount(edit, record);
    }
    final previous = await _existing(edit.id);
    final profile = _apply(edit, previous);
    try {
      await _container
          .read(directConnectionProfilesProvider.notifier)
          .upsert(
            profile,
            expectedPrevious: previous,
            // Only a key typed again in this edit may move with the URL; the
            // core strips the stored ones otherwise.
            secretsConfirmedForNewOrigin:
                edit.apiKey != null ||
                edit.customHeaders != null ||
                edit.certificatePem != null ||
                edit.privateKeyPem != null,
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
    final profile = _apply(named, record?.profile);
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
        await controller.updateConnection(
          record,
          profile,
          authType: record.authType,
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
    final profile = _apply(edit, previous);
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

  /// [edit] over [previous], or a new profile. Secrets follow the servers
  /// rule: null keeps, empty clears.
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
        customHeaders: edit.customHeaders ?? const <String, String>{},
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
      customHeaders: edit.customHeaders ?? previous.customHeaders,
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
