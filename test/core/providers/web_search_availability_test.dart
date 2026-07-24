import 'package:checks/checks.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/models/backend_config.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/models/user.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit/features/direct_connections/services/direct_model_registry.dart';
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

    test('direct web search requires every trusted Cloud capability', () async {
      Future<bool> availability({
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
        return container.read(webSearchAvailableProvider);
      }

      check(
        await availability(
          adapterKey: kOllamaAdapterKey,
          capabilities: const {'web_search': true},
        ),
      ).isFalse();
      check(
        await availability(
          adapterKey: kOllamaAdapterKey,
          capabilities: const {'ollama_cloud': false, 'web_search': true},
        ),
      ).isFalse();
      check(
        await availability(
          adapterKey: kOllamaAdapterKey,
          capabilities: const {'ollama_cloud': true, 'web_search': false},
        ),
      ).isFalse();
      check(
        await availability(
          adapterKey: kOpenAiCompatibleAdapterKey,
          capabilities: const {'ollama_cloud': true, 'web_search': true},
        ),
      ).isFalse();
    });

    test('local direct models never inherit Open WebUI web search', () async {
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
          'features': {'web_search': true},
        }),
        backendConfig: const BackendConfig(enableWebSearch: true),
        selectedModel: model,
        directModelRegistry: registry,
      );
      addTearDown(container.dispose);

      await container.read(backendConfigProvider.future);

      check(container.read(webSearchAvailableProvider)).isFalse();
    });

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
