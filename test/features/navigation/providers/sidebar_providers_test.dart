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

  test('legacy numeric tab positions resolve against visible tabs', () async {
    SharedPreferences.setMockInitialValues({
      PreferenceKeys.sidebarActiveTab: 2,
    });
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final controller = container.read(sidebarActiveTabProvider.notifier);
    final selected = resolveSidebarTabSelection(
      persistedTab: container.read(sidebarActiveTabProvider),
      legacyIndex: controller.pendingLegacyIndex(),
      visibleTabs: const [
        SidebarTabId.chats,
        SidebarTabId.notes,
        SidebarTabId.channels,
      ],
    );
    check(selected).equals(SidebarTabId.channels);

    // Capability discovery must not rewrite the legacy value. A committed
    // user selection completes the migration to a stable identity.
    check(PreferencesStore.getRaw(PreferenceKeys.sidebarActiveTab)).equals(2);
    controller.set(selected);
    check(
      container.read(sidebarActiveTabProvider),
    ).equals(SidebarTabId.channels);
    check(
      PreferencesStore.get<String>(PreferenceKeys.sidebarActiveTab),
    ).equals(SidebarTabId.channels.name);
  });

  test('legacy selection is not persisted during capability changes', () async {
    SharedPreferences.setMockInitialValues({
      PreferenceKeys.sidebarActiveTab: 1,
    });
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final controller = container.read(sidebarActiveTabProvider.notifier);
    final persisted = container.read(sidebarActiveTabProvider);
    check(persisted).equals(SidebarTabId.chats);
    check(
      resolveSidebarTabSelection(
        persistedTab: persisted,
        legacyIndex: controller.pendingLegacyIndex(),
        visibleTabs: const [SidebarTabId.chats, SidebarTabId.notes],
      ),
    ).equals(SidebarTabId.notes);

    check(
      resolveSidebarTabSelection(
        persistedTab: persisted,
        legacyIndex: controller.pendingLegacyIndex(),
        visibleTabs: const [SidebarTabId.chats],
      ),
    ).equals(SidebarTabId.chats);

    check(PreferencesStore.getRaw(PreferenceKeys.sidebarActiveTab)).equals(1);
  });

  test(
    'clearing a legacy index notifies when the tab value is unchanged',
    () async {
      SharedPreferences.setMockInitialValues({
        PreferenceKeys.sidebarActiveTab: 0,
      });
      PreferencesStore.debugOverride(await SharedPreferences.getInstance());
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifications = <SidebarTabId>[];
      container.listen(
        sidebarActiveTabProvider,
        (_, next) => notifications.add(next),
      );

      container.read(sidebarActiveTabProvider.notifier).set(SidebarTabId.chats);

      check(notifications).deepEquals([SidebarTabId.chats]);
    },
  );

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
