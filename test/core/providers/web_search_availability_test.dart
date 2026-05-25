import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/models/backend_config.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/models/user.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a [ProviderContainer] with [userPermissionsProvider] overridden
/// to emit the given [AsyncValue].
ProviderContainer _container(
  AsyncValue<Map<String, dynamic>> permissions, {
  BackendConfig? backendConfig,
  User? currentUser,
  Model? selectedModel,
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
