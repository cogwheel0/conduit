import 'package:conduit/core/providers/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a [ProviderContainer] with [userPermissionsProvider] overridden
/// to emit the given [AsyncValue].
ProviderContainer _container(AsyncValue<Map<String, dynamic>> permissions) {
  return ProviderContainer(
    overrides: [
      userPermissionsProvider.overrideWith(
        (ref) => permissions.when(
          data: (d) => d,
          loading: () => throw StateError('loading'),
          error: (e, s) => throw e,
        ),
      ),
    ],
  );
}

void main() {
  group('imageGenerationAvailableProvider', () {
    // ── Explicit bool ──────────────────────────────────────────────

    test('explicit true -> visible', () {
      final container = _container(
        const AsyncData<Map<String, dynamic>>({
          'features': {'image_generation': true},
        }),
      );
      addTearDown(container.dispose);

      expect(container.read(imageGenerationAvailableProvider), isTrue);
    });

    test('explicit false -> hidden', () {
      final container = _container(
        const AsyncData<Map<String, dynamic>>({
          'features': {'image_generation': false},
        }),
      );
      addTearDown(container.dispose);

      expect(container.read(imageGenerationAvailableProvider), isFalse);
    });

    // ── String coercion ────────────────────────────────────────────

    test("string 'true' -> visible", () {
      final container = _container(
        const AsyncData<Map<String, dynamic>>({
          'features': {'image_generation': 'true'},
        }),
      );
      addTearDown(container.dispose);

      expect(container.read(imageGenerationAvailableProvider), isTrue);
    });

    test("string 'True' (mixed case) -> visible", () {
      final container = _container(
        const AsyncData<Map<String, dynamic>>({
          'features': {'image_generation': 'True'},
        }),
      );
      addTearDown(container.dispose);

      expect(container.read(imageGenerationAvailableProvider), isTrue);
    });

    test("string 'false' -> hidden", () {
      final container = _container(
        const AsyncData<Map<String, dynamic>>({
          'features': {'image_generation': 'false'},
        }),
      );
      addTearDown(container.dispose);

      expect(container.read(imageGenerationAvailableProvider), isFalse);
    });

    test("string 'FALSE' (upper case) -> hidden", () {
      final container = _container(
        const AsyncData<Map<String, dynamic>>({
          'features': {'image_generation': 'FALSE'},
        }),
      );
      addTearDown(container.dispose);

      expect(container.read(imageGenerationAvailableProvider), isFalse);
    });

    // ── Malformed / unknown string ─────────────────────────────────

    test("malformed string 'maybe' -> visible (fallback)", () {
      final container = _container(
        const AsyncData<Map<String, dynamic>>({
          'features': {'image_generation': 'maybe'},
        }),
      );
      addTearDown(container.dispose);

      expect(container.read(imageGenerationAvailableProvider), isTrue);
    });

    test("empty string '' -> visible (fallback)", () {
      final container = _container(
        const AsyncData<Map<String, dynamic>>({
          'features': {'image_generation': ''},
        }),
      );
      addTearDown(container.dispose);

      expect(container.read(imageGenerationAvailableProvider), isTrue);
    });

    // ── Missing feature key ────────────────────────────────────────

    test('features map present but no image_generation key -> visible', () {
      final container = _container(
        const AsyncData<Map<String, dynamic>>({
          'features': <String, dynamic>{},
        }),
      );
      addTearDown(container.dispose);

      expect(container.read(imageGenerationAvailableProvider), isTrue);
    });

    test('no features key at all -> visible', () {
      final container = _container(const AsyncData<Map<String, dynamic>>({}));
      addTearDown(container.dispose);

      expect(container.read(imageGenerationAvailableProvider), isTrue);
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

      expect(container.read(imageGenerationAvailableProvider), isTrue);
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

      // Before the future resolves, the provider is in loading state,
      // which should fall back to visible.
      expect(container.read(imageGenerationAvailableProvider), isTrue);
    });
  });
}
