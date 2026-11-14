import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/features/navigation/models/sidebar_navigation_model.dart';
import 'package:conduit_core/features/navigation/providers/sidebar_availability_provider.dart';
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
  final availability = ref.watch(sidebarTabAvailabilityProvider);
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

/// Asks an overlay sidebar to close, for code with no context under the
/// drawer, such as the Android assistant opening a new chat.
final sidebarOverlayDismissRequestProvider =
    NotifierProvider<SidebarOverlayDismissRequest, int>(
      SidebarOverlayDismissRequest.new,
    );

class SidebarOverlayDismissRequest extends Notifier<int> {
  @override
  int build() => 0;

  void request() => state++;
}

/// The backend history shown by the opt-in sidebar and its New Chat action.
final sidebarHistoryTabProvider =
    NotifierProvider<SidebarHistoryTab, SidebarTabId>(SidebarHistoryTab.new);

class SidebarHistoryTab extends Notifier<SidebarTabId> {
  @override
  SidebarTabId build() => SidebarTabId.chats;

  void select(SidebarTabId tab) => state = tab;
}

final sidebarSelectedHistoryTabProvider = Provider<SidebarTabId>((ref) {
  final tabs = ref.watch(sidebarNavigationSnapshotProvider).tabs;
  final selected = ref.watch(sidebarHistoryTabProvider);
  return tabs.contains(selected)
      ? selected
      : tabs.firstWhere(
          (tab) => tab == SidebarTabId.chats || tab == SidebarTabId.hermes,
        );
});
