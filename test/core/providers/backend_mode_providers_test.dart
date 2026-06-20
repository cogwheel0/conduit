import 'package:checks/checks.dart';
import 'package:conduit/core/persistence/persistence_keys.dart';
import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/core/providers/backend_mode_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Unit tests for the synchronous, persisted [preferredBackendProvider] that the
/// router reads for boot-deterministic Hermes-only routing.
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugReset();
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
  });

  tearDown(() {
    PreferencesStore.debugReset();
  });

  ProviderContainer makeContainer() {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container;
  }

  group('preferredBackendProvider', () {
    test('defaults to unset when nothing is persisted', () {
      final container = makeContainer();
      check(
        container.read(preferredBackendProvider),
      ).equals(PreferredBackend.unset);
    });

    test('parses a persisted owui value at build time', () async {
      await PreferencesStore.put(PreferenceKeys.preferredBackend, 'owui');
      final container = makeContainer();
      check(
        container.read(preferredBackendProvider),
      ).equals(PreferredBackend.owui);
    });

    test('parses a persisted hermes value at build time', () async {
      await PreferencesStore.put(PreferenceKeys.preferredBackend, 'hermes');
      final container = makeContainer();
      check(
        container.read(preferredBackendProvider),
      ).equals(PreferredBackend.hermes);
    });

    test('falls back to unset for an unrecognized persisted value', () async {
      await PreferencesStore.put(PreferenceKeys.preferredBackend, 'garbage');
      final container = makeContainer();
      check(
        container.read(preferredBackendProvider),
      ).equals(PreferredBackend.unset);
    });

    test('set() updates state and persists the enum name', () async {
      final container = makeContainer();
      await container
          .read(preferredBackendProvider.notifier)
          .set(PreferredBackend.hermes);

      check(
        container.read(preferredBackendProvider),
      ).equals(PreferredBackend.hermes);
      check(
        PreferencesStore.getString(PreferenceKeys.preferredBackend),
      ).equals('hermes');
    });

    test('set() round-trips through a fresh container (persistence)', () async {
      final first = makeContainer();
      await first
          .read(preferredBackendProvider.notifier)
          .set(PreferredBackend.owui);

      // A new container rebuilds the controller from persisted prefs.
      final second = ProviderContainer();
      addTearDown(second.dispose);
      check(
        second.read(preferredBackendProvider),
      ).equals(PreferredBackend.owui);
    });
  });
}
