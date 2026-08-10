enum SidebarTabId { chats, hermes, terminal, notes, channels }

SidebarTabId resolveSidebarTabSelection({
  required SidebarTabId persistedTab,
  required int? legacyIndex,
  required List<SidebarTabId> visibleTabs,
}) {
  if (visibleTabs.isEmpty) return SidebarTabId.chats;
  if (legacyIndex != null) {
    return visibleTabs[legacyIndex.clamp(0, visibleTabs.length - 1)];
  }
  return visibleTabs.contains(persistedTab) ? persistedTab : visibleTabs.first;
}

/// One resolved view of sidebar feature visibility and selection.
///
/// Consumers use this snapshot instead of independently rebuilding the tab
/// list, which keeps rendering, search, reselection, and create actions aligned
/// while asynchronous server capabilities are changing.
final class SidebarNavigationSnapshot {
  SidebarNavigationSnapshot({
    required List<SidebarTabId> visibleTabs,
    required this.selectedTab,
    this.isLegacySelection = false,
  }) : visibleTabs = List.unmodifiable(visibleTabs);

  final List<SidebarTabId> visibleTabs;
  final SidebarTabId selectedTab;
  final bool isLegacySelection;

  int get selectedIndex => visibleTabs.indexOf(selectedTab);
  bool isVisible(SidebarTabId tab) => visibleTabs.contains(tab);
}
