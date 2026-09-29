import 'package:checks/checks.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/features/web_search/services/direct_web_search_mode.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a [ProviderContainer] with [userPermissionsProvider] overridden
/// to emit the given [AsyncValue].
ProviderContainer _container(
  AsyncValue<Map<String, dynamic>> permissions, {
  BackendConfig? backendConfig,
  User? currentUser,
  Model? selectedModel,
  DirectModelRegistry? directModelRegistry,
}) {
  return ProviderContainer(
    overrides: [
      userPermissionsProvider.overrideWith(
        (ref) => permissions.when(
          data: (d) => d,
          loading: () => throw StateError('loading'),
          error: (e, s) => throw e,
        ),
      ),
      if (backendConfig != null)
        backendConfigProvider.overrideWith(
          () => _FixedBackendConfigNotifier(backendConfig),
        ),
      if (currentUser != null)
        currentUserProvider.overrideWith((ref) async => currentUser),
      selectedModelProvider.overrideWithValue(selectedModel),
      if (directModelRegistry != null)
        directModelRegistryProvider.overrideWithValue(directModelRegistry),
    ],
  );
}

class _FixedBackendConfigNotifier extends BackendConfigNotifier {
  _FixedBackendConfigNotifier(this._config);

  final BackendConfig _config;

  @override
  Future<BackendConfig?> build() async => _config;
}

void main() {
  group('webSearchAvailableProvider', () {
    // ── Explicit bool ──────────────────────────────────────────────

    test('explicit true -> visible', () {
      final container = _container(
        const AsyncData<Map<String, dynamic>>({
          'features': {'web_search': true},
        }),
      );
      addTearDown(container.dispose);

      expect(container.read(webSearchAvailableProvider), isTrue);
    });

    test('explicit false -> hidden', () {
      final container = _container(
        const AsyncData<Map<String, dynamic>>({
          'features': {'web_search': false},
        }),
      );
      addTearDown(container.dispose);

      expect(container.read(webSearchAvailableProvider), isFalse);
    });

    // ── String coercion ────────────────────────────────────────────

    test("string 'true' -> visible", () {
      final container = _container(
        const AsyncData<Map<String, dynamic>>({
          'features': {'web_search': 'true'},
        }),
      );
      addTearDown(container.dispose);

      expect(container.read(webSearchAvailableProvider), isTrue);
    });

    test("string 'True' (mixed case) -> visible", () {
      final container = _container(
        const AsyncData<Map<String, dynamic>>({
          'features': {'web_search': 'True'},
        }),
      );
      addTearDown(container.dispose);

      expect(container.read(webSearchAvailableProvider), isTrue);
    });

    test("string 'false' -> hidden", () {
      final container = _container(
        const AsyncData<Map<String, dynamic>>({
          'features': {'web_search': 'false'},
        }),
      );
      addTearDown(container.dispose);

      expect(container.read(webSearchAvailableProvider), isFalse);
    });

    test("string 'FALSE' (upper case) -> hidden", () {
      final container = _container(
        const AsyncData<Map<String, dynamic>>({
          'features': {'web_search': 'FALSE'},
        }),
      );
      addTearDown(container.dispose);

      expect(container.read(webSearchAvailableProvider), isFalse);
    });

    // ── Malformed / unknown string ─────────────────────────────────

    test("malformed string 'maybe' -> visible (fallback)", () {
      final container = _container(
        const AsyncData<Map<String, dynamic>>({
          'features': {'web_search': 'maybe'},
        }),
      );
      addTearDown(container.dispose);

      expect(container.read(webSearchAvailableProvider), isTrue);
    });

    test("empty string '' -> visible (fallback)", () {
      final container = _container(
        const AsyncData<Map<String, dynamic>>({
          'features': {'web_search': ''},
        }),
      );
      addTearDown(container.dispose);

      expect(container.read(webSearchAvailableProvider), isTrue);
    });

    // ── Missing feature key ────────────────────────────────────────

    test('features map present but no web_search key -> visible', () {
      final container = _container(
        const AsyncData<Map<String, dynamic>>({
          'features': <String, dynamic>{},
        }),
      );
      addTearDown(container.dispose);

      expect(container.read(webSearchAvailableProvider), isTrue);
    });

    test('no features key at all -> visible', () {
      final container = _container(const AsyncData<Map<String, dynamic>>({}));
      addTearDown(container.dispose);

      expect(container.read(webSearchAvailableProvider), isTrue);
    });

    // ── Unavailable permissions payload ────────────────────────────

    test('permissions loading -> visible', () {
      final container = ProviderContainer(
        overrides: [
          userPermissionsProvider.overrideWith(
            (ref) => Future<Map<String, dynamic>>.delayed(
              const Duration(days: 1),
              () => <String, dynamic>{},
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(webSearchAvailableProvider), isTrue);
    });

    test('permissions error -> visible', () {
      final container = ProviderContainer(
        overrides: [
          userPermissionsProvider.overrideWith(
            (ref) =>
                Future<Map<String, dynamic>>.error(Exception('network error')),
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(webSearchAvailableProvider), isTrue);
    });

    test('global server web search disabled -> hidden', () async {
      final container = _container(
        const AsyncData<Map<String, dynamic>>({
          'features': {'web_search': true},
        }),
        backendConfig: const BackendConfig(enableWebSearch: false),
      );
      addTearDown(container.dispose);

      await container.read(backendConfigProvider.future);

      expect(container.read(webSearchAvailableProvider), isFalse);
    });

    test(
      'trusted Ollama Cloud model bypasses Open WebUI search permissions',
      () async {
        final registry = DirectModelRegistry();
        final model = registry.replaceProfileModels(
          DirectConnectionProfile(
            id: 'ollama-cloud',
            name: 'Ollama Cloud',
            adapterKey: kOllamaAdapterKey,
            baseUrl: 'https://ollama.com',
          ),
          [
            DirectRemoteModel(
              id: 'gpt-oss:120b',
              capabilities: const {'ollama_cloud': true, 'web_search': true},
            ),
          ],
        ).single;
        final container = _container(
          const AsyncData<Map<String, dynamic>>({
            'features': {'web_search': false},
          }),
          backendConfig: const BackendConfig(enableWebSearch: false),
          selectedModel: model,
          directModelRegistry: registry,
        );
        addTearDown(container.dispose);

        await container.read(backendConfigProvider.future);

        check(container.read(webSearchAvailableProvider)).isTrue();
      },
    );

    test(
      'an untrusted capability claim never selects provider-hosted search',
      () async {
        // Models that claim Ollama Cloud's hosted tool without the trusted
        // profile fall back to Conduit's own on-device search instead.
        Future<DirectWebSearchMode?> mode({
          required String adapterKey,
          required Map<String, dynamic> capabilities,
        }) async {
          final registry = DirectModelRegistry();
          final model = registry.replaceProfileModels(
            DirectConnectionProfile(
              id: 'direct-provider',
              name: 'Direct provider',
              adapterKey: adapterKey,
              baseUrl: 'https://ollama.com',
            ),
            [DirectRemoteModel(id: 'model', capabilities: capabilities)],
          ).single;
          final container = _container(
            const AsyncData<Map<String, dynamic>>({
              'features': {'web_search': false},
            }),
            backendConfig: const BackendConfig(enableWebSearch: false),
            selectedModel: model,
            directModelRegistry: registry,
          );
          addTearDown(container.dispose);
          await container.read(backendConfigProvider.future);
          return container.read(selectedDirectWebSearchModeProvider);
        }

        for (final (adapterKey, capabilities) in [
          (kOllamaAdapterKey, const {'web_search': true}),
          (
            kOllamaAdapterKey,
            const {'ollama_cloud': false, 'web_search': true},
          ),
          (
            kOllamaAdapterKey,
            const {'ollama_cloud': true, 'web_search': false},
          ),
          (
            kOpenAiCompatibleAdapterKey,
            const {'ollama_cloud': true, 'web_search': true},
          ),
        ]) {
          check(await mode(adapterKey: adapterKey, capabilities: capabilities))
              .equals(DirectWebSearchMode.onDevice);
        }
      },
    );

    test('device-owned direct models search on the device, whatever the '
        'Open WebUI server allows', () async {
      final registry = DirectModelRegistry();
      final model = registry.replaceProfileModels(
        DirectConnectionProfile(
          id: 'local-ollama',
          name: 'Local Ollama',
          adapterKey: kOllamaAdapterKey,
          baseUrl: 'http://localhost:11434',
        ),
        [DirectRemoteModel(id: 'llama3')],
      ).single;
      final container = _container(
        const AsyncData<Map<String, dynamic>>({
          'features': {'web_search': false},
        }),
        backendConfig: const BackendConfig(enableWebSearch: false),
        selectedModel: model,
        directModelRegistry: registry,
      );
      addTearDown(container.dispose);

      await container.read(backendConfigProvider.future);

      check(container.read(selectedDirectWebSearchModeProvider))
          .equals(DirectWebSearchMode.onDevice);
      check(container.read(webSearchAvailableProvider)).isTrue();
    });

    test(
      'a direct model that reports no tool support hides web search',
      () async {
        final registry = DirectModelRegistry();
        final model = registry.replaceProfileModels(
          DirectConnectionProfile(
            id: 'local-ollama',
            name: 'Local Ollama',
            adapterKey: kOllamaAdapterKey,
            baseUrl: 'http://localhost:11434',
          ),
          [
            DirectRemoteModel(
              id: 'gemma:2b',
              capabilities: const {
                'capabilities': ['completion'],
              },
            ),
          ],
        ).single;
        final container = _container(
          const AsyncData<Map<String, dynamic>>({}),
          selectedModel: model,
          directModelRegistry: registry,
        );
        addTearDown(container.dispose);

        check(container.read(webSearchAvailableProvider)).isFalse();
      },
    );

    test(
      'server-configured direct models follow the server web search policy',
      () async {
        Future<bool> availability({
          required bool serverEnabled,
          required bool permitted,
        }) async {
          final registry = DirectModelRegistry();
          final model = registry
              .replaceProfileModels(
                DirectConnectionProfile(
                  id: 'owui-connection',
                  name: 'Server connection',
                  adapterKey: kOpenAiCompatibleAdapterKey,
                  baseUrl: 'https://llm.example.com/v1',
                ),
                [DirectRemoteModel(id: 'model')],
                source: DirectModelSource.openWebUi,
                openWebUiUrlIndex: 0,
              )
              .single;
          final container = _container(
            AsyncData<Map<String, dynamic>>({
              'features': {'web_search': permitted},
            }),
            backendConfig: BackendConfig(enableWebSearch: serverEnabled),
            selectedModel: model,
            directModelRegistry: registry,
          );
          addTearDown(container.dispose);
          await container.read(backendConfigProvider.future);
          return container.read(webSearchAvailableProvider);
        }

        check(await availability(serverEnabled: true, permitted: true))
            .isTrue();
        check(await availability(serverEnabled: false, permitted: true))
            .isFalse();
        check(await availability(serverEnabled: true, permitted: false))
            .isFalse();
      },
    );

    test(
      'first-party OpenRouter models expose trusted model actions',
      () async {
        final registry = DirectModelRegistry();
        final model = registry.replaceProfileModels(
          DirectConnectionProfile(
            id: 'openrouter',
            name: 'OpenRouter',
            adapterKey: kOpenAiCompatibleAdapterKey,
            baseUrl: kOpenRouterApiBaseUrl,
          ),
          [
            DirectRemoteModel(
              id: 'anthropic/claude-sonnet-4',
              capabilities: const {'image_generation': false},
            ),
          ],
        ).single;
        final container = _container(
          const AsyncData<Map<String, dynamic>>({
            'features': {'web_search': false, 'image_generation': false},
          }),
          backendConfig: const BackendConfig(enableWebSearch: false),
          selectedModel: model,
          directModelRegistry: registry,
        );
        addTearDown(container.dispose);
        await container.read(backendConfigProvider.future);

        check(container.read(webSearchAvailableProvider)).isTrue();
        check(container.read(imageGenerationAvailableProvider)).isTrue();
      },
    );

    test('admin bypasses explicit false permission', () async {
      final container = _container(
        const AsyncData<Map<String, dynamic>>({
          'features': {'web_search': false},
        }),
        currentUser: const User(
          id: 'admin',
          username: 'Admin',
          email: 'admin@example.com',
          role: 'admin',
        ),
      );
      addTearDown(container.dispose);

      await container.read(currentUserProvider.future);

      expect(container.read(webSearchAvailableProvider), isTrue);
    });

    test('model web search capability false -> hidden', () {
      final container = _container(
        const AsyncData<Map<String, dynamic>>({
          'features': {'web_search': true},
        }),
        selectedModel: const Model(
          id: 'no-web-search',
          name: 'No Web Search',
          metadata: {
            'info': {
              'meta': {
                'capabilities': {'web_search': false},
              },
            },
          },
        ),
      );
      addTearDown(container.dispose);

      expect(container.read(webSearchAvailableProvider), isFalse);
    });
  });
}
