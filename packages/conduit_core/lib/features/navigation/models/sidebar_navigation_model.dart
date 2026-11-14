import 'package:meta/meta.dart';

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

  @override
  bool operator ==(Object other) =>
      other is SidebarTabAvailability &&
      other.hermesOnly == hermesOnly &&
      other.hasOpenWebUi == hasOpenWebUi &&
      other.hermesEnabled == hermesEnabled &&
      other.notesEnabled == notesEnabled &&
      other.terminalEnabled == terminalEnabled &&
      other.channelsEnabled == channelsEnabled;

  @override
  int get hashCode => Object.hash(
    hermesOnly,
    hasOpenWebUi,
    hermesEnabled,
    notesEnabled,
    terminalEnabled,
    channelsEnabled,
  );
}

/// The sidebar's destinations in the order every host shows them: the
/// phone's tab bar, the tablet sidebar and the Mac's source list.
const List<SidebarTabId> sidebarTabOrder = <SidebarTabId>[
  SidebarTabId.chats,
  SidebarTabId.hermes,
  SidebarTabId.notes,
  SidebarTabId.terminal,
  SidebarTabId.channels,
];

/// Whether [tab] exists for [availability].
///
/// Chats give way to Hermes's sessions when Hermes is the only backend.
/// Notes, the terminal and channels are Open WebUI's, each behind its own
/// server flag, and none of them shows while Hermes is in charge.
bool isSidebarTabVisible(
  SidebarTabId tab,
  SidebarTabAvailability availability,
) {
  final openWebUi = availability.hasOpenWebUi && !availability.hermesOnly;
  return switch (tab) {
    SidebarTabId.chats => !availability.hermesOnly,
    SidebarTabId.hermes =>
      availability.hermesOnly || availability.hermesEnabled,
    SidebarTabId.notes => openWebUi && availability.notesEnabled,
    SidebarTabId.terminal => openWebUi && availability.terminalEnabled,
    SidebarTabId.channels => openWebUi && availability.channelsEnabled,
  };
}

/// The destinations that exist for [availability], in [sidebarTabOrder].
List<SidebarTabId> visibleSidebarTabs(SidebarTabAvailability availability) => [
  for (final tab in sidebarTabOrder)
    if (isSidebarTabVisible(tab, availability)) tab,
];

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
