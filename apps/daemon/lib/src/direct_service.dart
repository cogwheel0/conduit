import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/models/ollama_keep_alive.dart';
import 'package:conduit_core/features/direct_connections/models/ollama_thinking.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/direct_connections/services/direct_provider_adapter.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';
import 'package:uuid/uuid.dart';

import 'settled.dart';

/// Implements `direct.*`: connections the app talks to itself (WP-4.1).
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
    return DirectConnectionList(
      connections: <DirectConnectionSummary>[
        for (final profile in profiles)
          // Apple's connections are the app's own, managed in M8.
          if (profile.adapterKey == kOpenAiCompatibleAdapterKey ||
              profile.adapterKey == kOllamaAdapterKey)
            _summarize(profile),
      ],
      localHistory:
          _container.read(directHistoryPolicyProvider) ==
          DirectHistoryPolicy.localOnly,
    );
  }

  Future<DirectConnectionList> save(DirectConnectionEdit edit) async {
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
                edit.apiKey != null || edit.customHeaders != null,
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

  Future<DirectConnectionList> remove(String id) async {
    await _container.read(directConnectionProfilesProvider.notifier).remove(id);
    return list();
  }

  Future<DirectConnectionList> setEnabled(String id, bool enabled) async {
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

  /// An Ollama connection's models and what can be done to them (M4).
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
        manualModelIds: profile.manualModelIds,
        allowSelfSignedCertificates: profile.allowSelfSignedCertificates,
        openRouter: profile.isOpenRouter,
        ollamaCloud: profile.isOllamaCloud,
      );
}
