import 'package:checks/checks.dart';
import 'package:conduit_core/features/navigation/providers/sidebar_tablet_width_provider.dart';
import 'package:conduit_core/features/navigation/sidebar_layout.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

void main() {
  tearDown(PreferencesStore.debugReset);

  ProviderContainer container() {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container;
  }

  Future<void> afterPersistDebounce() =>
      Future<void>.delayed(const Duration(milliseconds: 250));

  test('starts at the default width', () {
    PreferencesStore.debugOverride(InMemoryKeyValueStore());
    check(container().read(sidebarTabletWidthProvider))
        .equals(defaultSidebarTabletWidth);
  });

  test('restores, clamps and persists the width', () async {
    PreferencesStore.debugOverride(
      InMemoryKeyValueStore({PreferenceKeys.sidebarTabletWidth: 440.0}),
    );
    final first = container();
    check(first.read(sidebarTabletWidthProvider)).equals(440);
    final controller = first.read(sidebarTabletWidthProvider.notifier);

    controller.setWidth(600);
    check(first.read(sidebarTabletWidthProvider))
        .equals(maximumSidebarTabletWidth);
    await afterPersistDebounce();
    check(PreferencesStore.get<num>(PreferenceKeys.sidebarTabletWidth))
        .equals(maximumSidebarTabletWidth);

    controller.setWidth(120);
    check(first.read(sidebarTabletWidthProvider))
        .equals(minimumSidebarTabletWidth);
    await afterPersistDebounce();
    check(PreferencesStore.get<num>(PreferenceKeys.sidebarTabletWidth))
        .equals(minimumSidebarTabletWidth);

    controller.setWidth(400);
    await afterPersistDebounce();
    // A relaunch reads the stored width.
    check(container().read(sidebarTabletWidthProvider)).equals(400);
  });

  test('writes once per burst of drag updates', () async {
    final writes = <Object?>[];
    PreferencesStore.debugOverride(
      InMemoryKeyValueStore(),
      writeInterceptor: (_, key, value) async {
        if (key == PreferenceKeys.sidebarTabletWidth) writes.add(value);
        return null; // Write through.
      },
    );
    final controller = container().read(sidebarTabletWidthProvider.notifier);
    for (final width in [330.0, 350.0, 370.0, 390.0]) {
      controller.setWidth(width);
    }
    check(writes).isEmpty();
    await afterPersistDebounce();
    check(writes).deepEquals([390.0]);
  });

  test('reset returns to the default width', () async {
    PreferencesStore.debugOverride(
      InMemoryKeyValueStore({PreferenceKeys.sidebarTabletWidth: 460.0}),
    );
    final first = container();
    first.read(sidebarTabletWidthProvider.notifier).reset();
    check(first.read(sidebarTabletWidthProvider))
        .equals(defaultSidebarTabletWidth);
    await afterPersistDebounce();
    check(container().read(sidebarTabletWidthProvider))
        .equals(defaultSidebarTabletWidth);
  });

  test('a legacy width below 320 restores at the minimum', () {
    PreferencesStore.debugOverride(
      InMemoryKeyValueStore({PreferenceKeys.sidebarTabletWidth: 280.0}),
    );
    check(container().read(sidebarTabletWidthProvider))
        .equals(minimumSidebarTabletWidth);
  });
}
