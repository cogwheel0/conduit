import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/core/persistence/persistence_keys.dart';
import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/features/chat/providers/reasoning_effort_provider.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit/features/direct_connections/services/direct_model_registry.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
}
