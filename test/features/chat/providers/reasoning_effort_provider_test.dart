import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/models/server_user_settings.dart';
import 'package:conduit/core/persistence/persistence_keys.dart';
import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/chat/providers/reasoning_effort_provider.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit/features/direct_connections/models/ollama_thinking.dart';
import 'package:conduit/features/direct_connections/models/openrouter_reasoning.dart';
import 'package:conduit/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit/features/hermes/models/hermes_model.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class _PendingProfiles extends DirectConnectionProfilesController {
  _PendingProfiles(this.pending);

  final Completer<List<DirectConnectionProfile>> pending;
  final List<({String profileId, String modelId, String? setting})> writes = [];

  @override
  Future<List<DirectConnectionProfile>> build() => pending.future;

  @override
  Future<void> setOllamaThinking(
    String profileId,
    String remoteModelId,
    OllamaThinkingSetting? setting,
  ) async {
    writes.add((
      profileId: profileId,
      modelId: remoteModelId,
      setting: setting?.storageValue,
    ));
  }
}

final class _FixedPersonalizationSettings extends PersonalizationSettings {
  _FixedPersonalizationSettings(this.settings);

  final ServerUserSettings settings;

  @override
  Future<ServerUserSettings> build() async => settings;
}

final class _FixedSelectedModel extends SelectedModel {
  _FixedSelectedModel(this.model);

  final Model model;

  @override
  Model build() => model;
}

final class _ModelDetailsAdapter implements HttpClientAdapter {
  _ModelDetailsAdapter({
    this.failuresBeforeSuccess = 0,
    this.holdSuccessfulResponse = true,
  });

  final int failuresBeforeSuccess;
  final bool holdSuccessfulResponse;
  int requestCount = 0;
  final Completer<void> requested = Completer<void>();
  final Completer<void> release = Completer<void>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestCount++;
    if (!requested.isCompleted) requested.complete();
    check(options.method).equals('GET');
    check(options.path).equals('/api/v1/models/model');
    check(
      options.queryParameters,
    ).deepEquals(<String, dynamic>{'id': 'workspace-reasoning-model'});
    if (requestCount <= failuresBeforeSuccess) {
      return ResponseBody.fromString(
        '{"detail":"temporary failure"}',
        503,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>[Headers.jsonContentType],
        },
      );
    }
    if (holdSuccessfulResponse) await release.future;
    return ResponseBody(
      Stream<Uint8List>.value(
        Uint8List.fromList(
          utf8.encode(
            jsonEncode(<String, dynamic>{
              'id': 'workspace-reasoning-model',
              'name': 'Workspace reasoning model',
              'base_model_id': 'gpt-5',
              'params': <String, dynamic>{'reasoning_effort': 'Vendor_Ultra'},
              'meta': <String, dynamic>{},
              'is_active': true,
              'write_access': true,
            }),
          ),
        ),
      ),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    PreferencesStore.debugReset();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
  });

  tearDown(PreferencesStore.debugReset);

  test('explicit model effort does not follow the global selection', () async {
    final profile = DirectConnectionProfile(
      id: 'profile',
      name: 'Provider',
      adapterKey: kOpenAiCompatibleAdapterKey,
      baseUrl: 'https://provider.example/v1',
    );
    final registry = DirectModelRegistry();
    final models = registry.replaceProfileModels(profile, [
      DirectRemoteModel(id: 'model-a'),
      DirectRemoteModel(id: 'model-b'),
    ]);
    final container = ProviderContainer(
      overrides: [directModelRegistryProvider.overrideWithValue(registry)],
    );
    addTearDown(container.dispose);
    container.read(selectedModelProvider.notifier).set(models.first);

    await setReasoningEffortForModel(container.read, models.last, 'high');

    check(
      reasoningEffortForModel(container.read, models.first),
    ).equals('automatic');
    check(reasoningEffortForModel(container.read, models.last)).equals('high');
    check(container.read(selectedModelProvider)).identicalTo(models.first);
  });

  test('server model reasoning effort takes precedence over user effort', () {
    const model = Model(
      id: 'server-model',
      name: 'Server model',
      metadata: {
        'info': {
          'params': {'reasoning_effort': ' none '},
        },
      },
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(selectedModelProvider.notifier).set(model);

    check(container.read(reasoningEffortProvider)).equals('none');
    check(reasoningEffortForModel(container.read, model)).equals('none');
  });

  test('server model preserves custom reasoning effort values', () {
    const model = Model(
      id: 'custom-server-model',
      name: 'Custom server model',
      metadata: {
        'params': {'reasoning_effort': 'Vendor_Ultra'},
      },
    );

    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(selectedModelProvider.notifier).set(model);

    check(modelConfiguredReasoningEffort(model)).equals('vendor_ultra');
    check(container.read(reasoningEffortProvider)).equals('vendor_ultra');
  });

  test(
    'workspace model detail restores effort stripped from the model catalog',
    () async {
      const model = Model(
        id: 'workspace-reasoning-model',
        name: 'Workspace reasoning model',
        metadata: <String, dynamic>{
          'info': <String, dynamic>{
            'id': 'workspace-reasoning-model',
            'user_id': 'owner',
            'base_model_id': 'gpt-5',
            'meta': <String, dynamic>{},
          },
        },
      );
      final adapter = _ModelDetailsAdapter();
      final api = ApiService(
        serverConfig: const ServerConfig(
          id: 'reasoning-test',
          name: 'Reasoning test',
          url: 'https://example.test',
        ),
        workerManager: WorkerManager(),
      );
      api.dio.httpClientAdapter = adapter;
      api.dio.interceptors.clear();
      final container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWithValue(api),
          personalizationSettingsProvider.overrideWith(
            () => _FixedPersonalizationSettings(
              const ServerUserSettings(reasoningEffort: 'low'),
            ),
          ),
          selectedModelProvider.overrideWith(() => _FixedSelectedModel(model)),
        ],
      );
      addTearDown(container.dispose);
      await container.read(personalizationSettingsProvider.future);
      final subscription = container.listen<String?>(
        configuredReasoningEffortProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      await adapter.requested.future.timeout(const Duration(seconds: 1));
      check(container.read(configuredReasoningEffortProvider)).isNull();
      adapter.release.complete();
      await container.read(serverModelReasoningEffortProvider(model).future);

      check(adapter.requestCount).equals(1);
      check(
        container.read(configuredReasoningEffortProvider),
      ).equals('vendor_ultra');
    },
  );

  test('workspace model detail retries after a transient failure', () async {
    const model = Model(
      id: 'workspace-reasoning-model',
      name: 'Workspace reasoning model',
      metadata: <String, dynamic>{
        'info': <String, dynamic>{
          'id': 'workspace-reasoning-model',
          'user_id': 'owner',
          'base_model_id': 'gpt-5',
        },
      },
    );
    final adapter = _ModelDetailsAdapter(
      failuresBeforeSuccess: 1,
      holdSuccessfulResponse: false,
    );
    final api = ApiService(
      serverConfig: const ServerConfig(
        id: 'reasoning-retry-test',
        name: 'Reasoning retry test',
        url: 'https://example.test',
      ),
      workerManager: WorkerManager(),
    );
    api.dio.httpClientAdapter = adapter;
    api.dio.interceptors.clear();
    final container = ProviderContainer(
      overrides: [apiServiceProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);

    check(
      await container.read(serverModelReasoningEffortProvider(model).future),
    ).isNull();
    await container.pump();
    check(
      await container.read(serverModelReasoningEffortProvider(model).future),
    ).equals('vendor_ultra');
    check(adapter.requestCount).equals(2);
  });

  test('server policy only exposes effort for supported models', () {
    const unsupported = Model(id: 'gpt-4o', name: 'GPT-4o');
    const explicitlyUnsupported = Model(
      id: 'catalog-model',
      name: 'Catalog model',
      capabilities: <String, dynamic>{
        'reasoning': <String, dynamic>{'supported_efforts': <String>[]},
      },
    );
    const supported = Model(id: 'gpt-5', name: 'GPT-5');
    final hermes = hermesSyntheticModel();
    final container = ProviderContainer();
    addTearDown(container.dispose);

    check(
      reasoningEffortPolicyForModel(container.read, unsupported).visible,
    ).isFalse();
    check(
      reasoningEffortPolicyForModel(
        container.read,
        explicitlyUnsupported,
      ).visible,
    ).isFalse();
    check(
      reasoningEffortPolicyForModel(container.read, supported).visible,
    ).isTrue();
    check(
      reasoningEffortPolicyForModel(container.read, hermes).visible,
    ).isTrue();
  });

  test('chat payload omits effort for unsupported server models', () {
    final api = ApiService(
      serverConfig: const ServerConfig(
        id: 'reasoning-test',
        name: 'Reasoning test',
        url: 'https://example.test',
      ),
      workerManager: WorkerManager(),
    );
    final userSettings = <String, dynamic>{
      'params': <String, dynamic>{
        'reasoning_effort': 'medium',
        'temperature': 0.3,
      },
    };

    Map<String, dynamic> build(String model) =>
        api.buildChatCompletionPayloadForTest(
          messages: const <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'Hello'},
          ],
          model: model,
          messageId: 'message-id',
          sessionId: 'session-id',
          modelItem: <String, dynamic>{'id': model, 'name': model},
          userSettings: userSettings,
        );

    final unsupportedParams = build('gpt-4o')['params'] as Map<String, dynamic>;
    final supportedParams = build('gpt-5')['params'] as Map<String, dynamic>;

    check(unsupportedParams.containsKey('reasoning_effort')).isFalse();
    check(unsupportedParams['temperature']).equals(0.3);
    check(supportedParams['reasoning_effort']).equals('medium');
  });

  test('custom OpenWebUI model metadata retains supported effort', () {
    final api = ApiService(
      serverConfig: const ServerConfig(
        id: 'reasoning-test',
        name: 'Reasoning test',
        url: 'https://example.test',
      ),
      workerManager: WorkerManager(),
    );

    Map<String, dynamic> build(Model model, String effort) {
      final modelItem = buildLocalModelItemForTest(model);
      return api.buildChatCompletionPayloadForTest(
        messages: const <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'Hello'},
        ],
        model: model.id,
        messageId: 'message-id',
        sessionId: 'session-id',
        modelItem: modelItem,
        userSettings: <String, dynamic>{
          'params': <String, dynamic>{'reasoning_effort': effort},
        },
      );
    }

    final configuredModel = Model.fromJson(<String, dynamic>{
      'id': 'custom-configured-model',
      'name': 'Custom configured model',
      'params': <String, dynamic>{'reasoning_effort': 'vendor_ultra'},
    });
    final aliasModel = Model.fromJson(<String, dynamic>{
      'id': 'custom-gpt-alias',
      'name': 'Custom GPT alias',
      'base_model_id': 'gpt-5',
    });

    final configuredModelItem = buildLocalModelItemForTest(configuredModel);
    final aliasModelItem = buildLocalModelItemForTest(aliasModel);
    check(configuredModelItem['params']).isA<Map<String, dynamic>>().deepEquals(
      <String, dynamic>{'reasoning_effort': 'vendor_ultra'},
    );
    check(aliasModelItem['base_model_id']).equals('gpt-5');
    check(
      (build(configuredModel, 'vendor_ultra')['params']
          as Map<String, dynamic>)['reasoning_effort'],
    ).equals('vendor_ultra');
    check(
      (build(aliasModel, 'high')['params']
          as Map<String, dynamic>)['reasoning_effort'],
    ).equals('high');
  });

  test(
    'malformed saved effort does not discard valid model settings',
    () async {
      await PreferencesStore.put(
        PreferenceKeys.reasoningEffortByModel,
        jsonEncode(<String, Object>{
          'hermes:valid': 'high',
          'hermes:invalid': 'not valid!',
        }),
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);

      check(
        container.read(localReasoningEffortsProvider),
      ).deepEquals({'hermes:valid': 'high'});
    },
  );

  test('Ollama effort waits for profile hydration', () async {
    final profile = DirectConnectionProfile(
      id: 'ollama-profile',
      name: 'Ollama',
      adapterKey: kOllamaAdapterKey,
      baseUrl: 'https://ollama.com',
    );
    final registry = DirectModelRegistry();
    final model = registry.replaceProfileModels(profile, [
      DirectRemoteModel(id: 'model-a'),
    ]).single;
    final pending = Completer<List<DirectConnectionProfile>>();
    final profiles = _PendingProfiles(pending);
    final container = ProviderContainer(
      overrides: [
        directModelRegistryProvider.overrideWithValue(registry),
        directConnectionProfilesProvider.overrideWith(() => profiles),
      ],
    );
    addTearDown(container.dispose);
    container.read(selectedModelProvider.notifier).set(model);

    check(container.read(configuredReasoningEffortProvider)).isNull();
    check(container.read(reasoningEffortAllowsCustomProvider)).isFalse();
    final policy = reasoningEffortPolicyForModel(container.read, model);
    check(policy.restrictsValues).isTrue();
    await check(
      setReasoningEffortForModel(container.read, model, 'unsupported'),
    ).throws<FormatException>();
    final write = setReasoningEffortForModel(container.read, model, 'high');
    await Future<void>.delayed(Duration.zero);

    check(container.read(localReasoningEffortsProvider)).isEmpty();
    check(profiles.writes).isEmpty();

    pending.complete([profile]);
    await write;
    check(profiles.writes).deepEquals([
      (profileId: 'ollama-profile', modelId: 'model-a', setting: 'high'),
    ]);
  });

  test('Ollama profile hydration failure propagates to the caller', () async {
    final profile = DirectConnectionProfile(
      id: 'ollama-profile',
      name: 'Ollama',
      adapterKey: kOllamaAdapterKey,
      baseUrl: 'https://ollama.com',
    );
    final registry = DirectModelRegistry();
    final model = registry.replaceProfileModels(profile, [
      DirectRemoteModel(id: 'model-a'),
    ]).single;
    final pending = Completer<List<DirectConnectionProfile>>();
    final profiles = _PendingProfiles(pending);
    final container = ProviderContainer(
      overrides: [
        directModelRegistryProvider.overrideWithValue(registry),
        directConnectionProfilesProvider.overrideWith(() => profiles),
      ],
    );
    addTearDown(container.dispose);

    final write = setReasoningEffortForModel(container.read, model, 'high');
    pending.completeError(StateError('profile storage unavailable'));

    await check(write).throws<StateError>();
    check(container.read(localReasoningEffortsProvider)).isEmpty();
    check(profiles.writes).isEmpty();
  });

  test('OpenRouter policy follows supported efforts and mandatory mode', () {
    final profile = DirectConnectionProfile(
      id: 'openrouter-profile',
      name: 'OpenRouter',
      adapterKey: kOpenAiCompatibleAdapterKey,
      baseUrl: kOpenRouterApiBaseUrl,
    );
    final registry = DirectModelRegistry();
    final model = registry.replaceProfileModels(profile, [
      DirectRemoteModel(
        id: 'model',
        capabilities: const {
          'reasoning': {
            'supported_efforts': ['high', 'minimal', 'none'],
            'default_effort': 'minimal',
            'mandatory': true,
          },
        },
      ),
    ]).single;
    final container = ProviderContainer(
      overrides: [directModelRegistryProvider.overrideWithValue(registry)],
    );
    addTearDown(container.dispose);

    final policy = reasoningEffortPolicyForModel(container.read, model);
    check(policy.visible).isTrue();
    check(policy.allowsCustom).isFalse();
    check(policy.restrictsValues).isTrue();
    check(policy.options).deepEquals(['automatic', 'high', 'minimal']);
    check(policy.accepts('none')).isFalse();
    check(policy.effectiveConfiguredEffort('automatic')).isNull();
  });

  test('OpenRouter null supported efforts exposes all gateway levels', () {
    final profile = DirectConnectionProfile(
      id: 'openrouter-profile',
      name: 'OpenRouter',
      adapterKey: kOpenAiCompatibleAdapterKey,
      baseUrl: kOpenRouterApiBaseUrl,
    );
    final registry = DirectModelRegistry();
    final model = registry.replaceProfileModels(profile, [
      DirectRemoteModel(
        id: 'model',
        capabilities: const {
          'reasoning': {'supported_efforts': null, 'mandatory': false},
        },
      ),
    ]).single;
    final container = ProviderContainer(
      overrides: [directModelRegistryProvider.overrideWithValue(registry)],
    );
    addTearDown(container.dispose);

    final policy = reasoningEffortPolicyForModel(container.read, model);
    check(
      policy.options,
    ).deepEquals(['automatic', ...kOpenRouterReasoningEfforts]);
  });

  test(
    'OpenRouter hides absent reasoning and keeps stale preference stored',
    () async {
      final profile = DirectConnectionProfile(
        id: 'openrouter-profile',
        name: 'OpenRouter',
        adapterKey: kOpenAiCompatibleAdapterKey,
        baseUrl: kOpenRouterApiBaseUrl,
      );
      final registry = DirectModelRegistry();
      final models = registry.replaceProfileModels(profile, [
        DirectRemoteModel(id: 'without-reasoning'),
        DirectRemoteModel(
          id: 'limited',
          capabilities: const {
            'reasoning': {
              'supported_efforts': ['high', 'minimal'],
              'mandatory': false,
            },
          },
        ),
      ]);
      final container = ProviderContainer(
        overrides: [directModelRegistryProvider.overrideWithValue(registry)],
      );
      addTearDown(container.dispose);
      const key = 'direct:openrouter-profile:limited';
      await container
          .read(localReasoningEffortsProvider.notifier)
          .set(key, 'medium');

      check(
        reasoningEffortPolicyForModel(container.read, models.first).visible,
      ).isFalse();
      check(
        reasoningEffortForModel(container.read, models.last),
      ).equals('automatic');
      check(
        container.read(localReasoningEffortsProvider)[key],
      ).equals('medium');
      await check(
        setReasoningEffortForModel(container.read, models.last, 'medium'),
      ).throws<FormatException>();
    },
  );
}
