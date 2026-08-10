import 'package:checks/checks.dart';
import 'package:conduit/core/persistence/persistence_keys.dart';
import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/features/navigation/providers/sidebar_providers.dart';
import 'package:conduit/features/navigation/providers/sidebar_tab_scroll_registry.dart';
import 'package:conduit/shared/widgets/sidebar_layout_constants.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  tearDown(PreferencesStore.debugReset);

  test('restores a stable sidebar tab identity', () async {
    SharedPreferences.setMockInitialValues({
      PreferenceKeys.sidebarActiveTab: SidebarTabId.channels.name,
    });
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
    final container = ProviderContainer();
    addTearDown(container.dispose);

    check(
      container.read(sidebarActiveTabProvider),
    ).equals(SidebarTabId.channels);
  });

  test('set persists the selected tab identity', () async {
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(sidebarActiveTabProvider.notifier);

    controller.set(SidebarTabId.channels);
    check(
      container.read(sidebarActiveTabProvider),
    ).equals(SidebarTabId.channels);
    check(
      PreferencesStore.get<String>(PreferenceKeys.sidebarActiveTab),
    ).equals(SidebarTabId.channels.name);
  });

  test(
    'legacy numeric tab positions migrate through historical order',
    () async {
      SharedPreferences.setMockInitialValues({
        PreferenceKeys.sidebarActiveTab: 2,
      });
      PreferencesStore.debugOverride(await SharedPreferences.getInstance());
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final controller = container.read(sidebarActiveTabProvider.notifier);
      final selected = resolveSidebarTabSelection(
        persistedTab: container.read(sidebarActiveTabProvider),
        visibleTabs: const [
          SidebarTabId.chats,
          SidebarTabId.notes,
          SidebarTabId.channels,
        ],
      );
      check(selected).equals(SidebarTabId.notes);

      controller.migrateLegacySelection(
        container.read(sidebarActiveTabProvider),
      );
      check(
        container.read(sidebarActiveTabProvider),
      ).equals(SidebarTabId.notes);
      check(
        PreferencesStore.get<String>(PreferenceKeys.sidebarActiveTab),
      ).equals(SidebarTabId.notes.name);
    },
  );

  test('unavailable legacy identity falls back without replacement', () async {
    SharedPreferences.setMockInitialValues({
      PreferenceKeys.sidebarActiveTab: 1,
    });
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final controller = container.read(sidebarActiveTabProvider.notifier);
    final persisted = container.read(sidebarActiveTabProvider);
    check(persisted).equals(SidebarTabId.hermes);
    check(
      resolveSidebarTabSelection(
        persistedTab: persisted,
        visibleTabs: const [SidebarTabId.chats, SidebarTabId.notes],
      ),
    ).equals(SidebarTabId.chats);

    controller.migrateLegacySelection(persisted);
    check(
      PreferencesStore.get<String>(PreferenceKeys.sidebarActiveTab),
    ).equals(SidebarTabId.hermes.name);
  });

  test('tablet sidebar width restores, clamps, and persists', () async {
    SharedPreferences.setMockInitialValues({
      PreferenceKeys.sidebarTabletWidth: 440.0,
    });
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
    final container = ProviderContainer();
    addTearDown(container.dispose);

    check(container.read(sidebarTabletWidthProvider)).equals(440);
    final controller = container.read(sidebarTabletWidthProvider.notifier);

    controller.setWidth(600);
    check(
      container.read(sidebarTabletWidthProvider),
    ).equals(maximumSidebarTabletWidth);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    check(
      PreferencesStore.get<num>(PreferenceKeys.sidebarTabletWidth),
    ).equals(maximumSidebarTabletWidth);

    controller.setWidth(120);
    check(
      container.read(sidebarTabletWidthProvider),
    ).equals(minimumSidebarTabletWidth);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    check(
      PreferencesStore.get<num>(PreferenceKeys.sidebarTabletWidth),
    ).equals(minimumSidebarTabletWidth);

    final clampedContainer = ProviderContainer();
    addTearDown(clampedContainer.dispose);
    check(
      clampedContainer.read(sidebarTabletWidthProvider),
    ).equals(minimumSidebarTabletWidth);

    controller.reset();
    check(
      container.read(sidebarTabletWidthProvider),
    ).equals(defaultSidebarTabletWidth);
    await Future<void>.delayed(const Duration(milliseconds: 250));

    final restoredContainer = ProviderContainer();
    addTearDown(restoredContainer.dispose);
    check(
      restoredContainer.read(sidebarTabletWidthProvider),
    ).equals(defaultSidebarTabletWidth);
  });

  test('legacy tablet widths below 320 restore at the new minimum', () async {
    SharedPreferences.setMockInitialValues({
      PreferenceKeys.sidebarTabletWidth: 280.0,
    });
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
    final container = ProviderContainer();
    addTearDown(container.dispose);

    check(
      container.read(sidebarTabletWidthProvider),
    ).equals(minimumSidebarTabletWidth);
    check(minimumSidebarTabletWidth).equals(320);
  });
}
