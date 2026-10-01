import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/providers/app_providers.dart';

import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';

import '../../terminal/providers/terminal_providers.dart';

import 'package:conduit_core/features/navigation/models/sidebar_navigation_model.dart';
import 'package:conduit_core/features/navigation/providers/sidebar_active_tab_provider.dart';

import '../widgets/sidebar_tab_registry.dart';

export 'sidebar_search_providers.dart';

// The active tab moved to the core, where the chat pipeline switches to the
// terminal tab when a tool displays a file.
export 'package:conduit_core/features/navigation/providers/sidebar_active_tab_provider.dart';
// The tablet width preference moved to conduit_core.
export 'package:conduit_core/features/navigation/providers/sidebar_tablet_width_provider.dart';

final sidebarNavigationSnapshotProvider = Provider<SidebarNavigationSnapshot>((
  ref,
) {
  final hermesOnly = ref.watch(hermesOnlyModeProvider);
  final hasOpenWebUi = ref.watch(openWebUiAccountAvailableProvider);
  final availability = SidebarTabAvailability(
    hermesOnly: hermesOnly,
    hasOpenWebUi: hasOpenWebUi,
    hermesEnabled: ref.watch(hermesEnabledProvider),
    notesEnabled: ref.watch(notesFeatureEnabledProvider),
    terminalEnabled: ref.watch(terminalTabVisibleProvider),
    channelsEnabled: ref.watch(channelsFeatureEnabledProvider),
  );
  final tabs = visibleSidebarTabIds(availability);
  final persistedTab = ref.watch(sidebarActiveTabProvider);
  final legacyIndex = ref
      .read(sidebarActiveTabProvider.notifier)
      .pendingLegacyIndex();
  return SidebarNavigationSnapshot(
    tabs: tabs,
    isLegacySelection: legacyIndex != null,
    selectedTab: resolveSidebarTabSelection(
      persistedTab: persistedTab,
      legacyIndex: legacyIndex,
      visibleTabs: tabs,
    ),
  );
});
