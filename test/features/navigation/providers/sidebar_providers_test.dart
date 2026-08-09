import 'package:checks/checks.dart';
import 'package:conduit/core/persistence/persistence_keys.dart';
import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/features/navigation/providers/sidebar_providers.dart';
import 'package:conduit/shared/widgets/sidebar_layout_constants.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  tearDown(PreferencesStore.debugReset);

  test('restores the fifth visible sidebar tab', () async {
    SharedPreferences.setMockInitialValues({
      PreferenceKeys.sidebarActiveTab: 4,
    });
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
    final container = ProviderContainer();
    addTearDown(container.dispose);

    check(container.read(sidebarActiveTabProvider)).equals(4);
  });

  test('set supports all five tabs and clamps out-of-range indexes', () async {
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(sidebarActiveTabProvider.notifier);

    controller.set(4);
    check(container.read(sidebarActiveTabProvider)).equals(4);
    check(PreferencesStore.getInt(PreferenceKeys.sidebarActiveTab)).equals(4);

    controller.set(5);
    check(container.read(sidebarActiveTabProvider)).equals(4);

    controller.set(-1);
    check(container.read(sidebarActiveTabProvider)).equals(0);
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
    check(
      PreferencesStore.get<num>(PreferenceKeys.sidebarTabletWidth),
    ).equals(maximumSidebarTabletWidth);

    controller.setWidth(120);
    check(
      container.read(sidebarTabletWidthProvider),
    ).equals(minimumSidebarTabletWidth);

    controller.reset();
    check(
      container.read(sidebarTabletWidthProvider),
    ).equals(defaultSidebarTabletWidth);

    final restoredContainer = ProviderContainer();
    addTearDown(restoredContainer.dispose);
    check(
      restoredContainer.read(sidebarTabletWidthProvider),
    ).equals(defaultSidebarTabletWidth);
  });
}
