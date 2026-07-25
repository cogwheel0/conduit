import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/core/persistence/persistence_keys.dart';
import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/features/chat/providers/reasoning_effort_provider.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit/features/direct_connections/models/ollama_thinking.dart';
import 'package:conduit/features/direct_connections/models/openrouter_reasoning.dart';
import 'package:conduit/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit/features/direct_connections/services/direct_model_registry.dart';
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
