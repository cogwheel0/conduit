import 'sidebar_tab_descriptor.dart';

export 'sidebar_tab_descriptor.dart';

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
    required List<SidebarTabDescriptor> tabs,
    required this.selectedTab,
    this.isLegacySelection = false,
  }) : tabs = List.unmodifiable(tabs);

  final List<SidebarTabDescriptor> tabs;
  final SidebarTabId selectedTab;
  final bool isLegacySelection;

  List<SidebarTabId> get tabIds => [for (final tab in tabs) tab.id];
  int get selectedIndex => tabs.indexWhere((tab) => tab.id == selectedTab);
  SidebarTabDescriptor get selectedDescriptor => tabs[selectedIndex];
  bool isVisible(SidebarTabId tab) => tabs.any((item) => item.id == tab);
}
