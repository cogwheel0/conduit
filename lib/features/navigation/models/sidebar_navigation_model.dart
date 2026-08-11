import 'package:flutter/foundation.dart';

/// Stable, persistence-safe identity for a sidebar destination.
enum SidebarTabId { chats, hermes, terminal, notes, channels }

/// Data-only capability snapshot used to decide which destinations exist.
@immutable
final class SidebarTabAvailability {
  const SidebarTabAvailability({
    required this.hermesOnly,
    required this.hasOpenWebUi,
    required this.hermesEnabled,
    required this.notesEnabled,
    required this.terminalEnabled,
    required this.channelsEnabled,
  });

  final bool hermesOnly;
  final bool hasOpenWebUi;
  final bool hermesEnabled;
  final bool notesEnabled;
  final bool terminalEnabled;
  final bool channelsEnabled;
}

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
    required List<SidebarTabId> tabs,
    required this.selectedTab,
    this.isLegacySelection = false,
  }) : tabs = List.unmodifiable(tabs);

  final List<SidebarTabId> tabs;
  final SidebarTabId selectedTab;
  final bool isLegacySelection;

  int get selectedIndex => tabs.indexOf(selectedTab);
  bool isVisible(SidebarTabId tab) => tabs.contains(tab);
}
