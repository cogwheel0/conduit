import 'package:material_ui/material_ui.dart';

import '../../../l10n/app_localizations.dart';
import '../../channels/widgets/channel_list_tab.dart';
import '../../hermes/widgets/hermes_sessions_tab.dart';
import '../../notes/widgets/notes_list_tab.dart';
import '../../terminal/widgets/terminal_tab.dart';
import '../../terminal/controllers/terminal_sidebar_tab_behavior.dart';
import '../controllers/sidebar_tab_behavior.dart';
import '../models/sidebar_navigation_model.dart';
import '../utils/sidebar_create_action.dart';
import 'chats_drawer.dart';

const AssetImage kHermesTabIcon = AssetImage('assets/icons/hermes_agent.png');

/// Optical size for the full-bleed Hermes artwork in compact navigation.
///
/// System tab glyphs include padding inside their nominal 20-point canvas;
/// the Hermes asset does not, so it needs a smaller painted extent to match.
const double kHermesTabIconSize = 17.0;

/// Optical size for Hermes in UIKit's native bottom tab bar.
const double kHermesNativeTabIconSize = 26.0;

typedef SidebarTabLabelBuilder = String Function(AppLocalizations l10n);
typedef SidebarTabBodyBuilder = Widget Function({
  required bool showBottomNavigation,
  required bool active,
});
typedef SidebarTabVisibilityPredicate = bool Function(
  SidebarTabAvailability availability,
);

/// Canonical visibility, presentation, and behavior for a sidebar destination.
@immutable
final class SidebarTabDescriptor {
  const SidebarTabDescriptor({
    required this.id,
    required this.labelBuilder,
    required this.searchHintBuilder,
    required this.bodyBuilder,
    required this.materialIcon,
    required this.selectedMaterialIcon,
    required this.sfSymbol,
    required this.selectedSfSymbol,
    required this.isVisible,
    this.assetName,
    this.nativeAssetName,
    this.assetIconSize,
    this.nativeAssetIconSize,
    this.createAction,
    this.behavior = standardSidebarTabBehavior,
  });

  final SidebarTabId id;
  final SidebarTabLabelBuilder labelBuilder;
  final SidebarTabLabelBuilder searchHintBuilder;
  final SidebarTabBodyBuilder bodyBuilder;
  final IconData materialIcon;
  final IconData selectedMaterialIcon;
  final String sfSymbol;
  final String selectedSfSymbol;
  final SidebarTabVisibilityPredicate isVisible;
  final String? assetName;
  final String? nativeAssetName;
  final double? assetIconSize;
  final double? nativeAssetIconSize;
  final SidebarCreateAction? createAction;
  final SidebarTabBehavior behavior;

  String label(AppLocalizations l10n) => labelBuilder(l10n);
  String searchHint(AppLocalizations l10n) => searchHintBuilder(l10n);

  ValueKey<String> get layerKey =>
      ValueKey<String>('sidebar-tab-layer-${id.name}');
}

String _chatsLabel(AppLocalizations l10n) => l10n.sidebarChatsTab;
String _hermesLabel(AppLocalizations l10n) => l10n.sidebarHermesTab;
String _notesLabel(AppLocalizations l10n) => l10n.sidebarNotesTab;
String _terminalLabel(AppLocalizations l10n) => l10n.sidebarTerminalTab;
String _channelsLabel(AppLocalizations l10n) => l10n.sidebarChannelsTab;
String _conversationSearchHint(AppLocalizations l10n) =>
    l10n.searchConversations;
String _notesSearchHint(AppLocalizations l10n) => l10n.searchNotes;
String _terminalSearchHint(AppLocalizations l10n) => l10n.searchFiles;
String _channelsSearchHint(AppLocalizations l10n) => l10n.searchChannels;

Widget _chatsBody({required bool showBottomNavigation, required bool active}) =>
    const ChatsDrawer();

Widget _hermesBody({
  required bool showBottomNavigation,
  required bool active,
}) => HermesSessionsTab(showBottomNavigationBar: showBottomNavigation);

Widget _notesBody({required bool showBottomNavigation, required bool active}) =>
    const NotesListTab();

Widget _terminalBody({
  required bool showBottomNavigation,
  required bool active,
}) => TerminalTab(isActive: active);

Widget _channelsBody({
  required bool showBottomNavigation,
  required bool active,
}) => const ChannelListTab();

bool _chatsVisible(SidebarTabAvailability availability) =>
    !availability.hermesOnly;

bool _hermesVisible(SidebarTabAvailability availability) =>
    availability.hermesOnly || availability.hermesEnabled;

bool _notesVisible(SidebarTabAvailability availability) =>
    availability.hasOpenWebUi &&
    !availability.hermesOnly &&
    availability.notesEnabled;

bool _terminalVisible(SidebarTabAvailability availability) =>
    availability.hasOpenWebUi &&
    !availability.hermesOnly &&
    availability.terminalEnabled;

bool _channelsVisible(SidebarTabAvailability availability) =>
    availability.hasOpenWebUi &&
    !availability.hermesOnly &&
    availability.channelsEnabled;

const sidebarTabRegistry = <SidebarTabDescriptor>[
  SidebarTabDescriptor(
    id: SidebarTabId.chats,
    labelBuilder: _chatsLabel,
    searchHintBuilder: _conversationSearchHint,
    bodyBuilder: _chatsBody,
    materialIcon: Icons.chat_bubble_outline,
    selectedMaterialIcon: Icons.chat_bubble,
    sfSymbol: 'bubble.left',
    selectedSfSymbol: 'bubble.left.fill',
    isVisible: _chatsVisible,
    createAction: chatSidebarCreateAction,
  ),
  SidebarTabDescriptor(
    id: SidebarTabId.hermes,
    labelBuilder: _hermesLabel,
    searchHintBuilder: _conversationSearchHint,
    bodyBuilder: _hermesBody,
    materialIcon: Icons.smart_toy_outlined,
    selectedMaterialIcon: Icons.smart_toy,
    sfSymbol: 'sparkles',
    selectedSfSymbol: 'sparkles',
    isVisible: _hermesVisible,
    assetName: 'assets/icons/hermes_agent.png',
    nativeAssetName: 'assets/icons/hermes_agent_tab.svg',
    assetIconSize: kHermesTabIconSize,
    nativeAssetIconSize: kHermesNativeTabIconSize,
    createAction: hermesChatSidebarCreateAction,
  ),
  SidebarTabDescriptor(
    id: SidebarTabId.notes,
    labelBuilder: _notesLabel,
    searchHintBuilder: _notesSearchHint,
    bodyBuilder: _notesBody,
    materialIcon: Icons.note_outlined,
    selectedMaterialIcon: Icons.note,
    sfSymbol: 'doc.text',
    selectedSfSymbol: 'doc.text.fill',
    isVisible: _notesVisible,
    createAction: noteSidebarCreateAction,
  ),
  SidebarTabDescriptor(
    id: SidebarTabId.terminal,
    labelBuilder: _terminalLabel,
    searchHintBuilder: _terminalSearchHint,
    bodyBuilder: _terminalBody,
    materialIcon: Icons.terminal_rounded,
    selectedMaterialIcon: Icons.terminal,
    sfSymbol: 'terminal',
    selectedSfSymbol: 'terminal',
    isVisible: _terminalVisible,
    behavior: terminalSidebarTabBehavior,
  ),
  SidebarTabDescriptor(
    id: SidebarTabId.channels,
    labelBuilder: _channelsLabel,
    searchHintBuilder: _channelsSearchHint,
    bodyBuilder: _channelsBody,
    materialIcon: Icons.tag,
    selectedMaterialIcon: Icons.tag,
    sfSymbol: 'number',
    selectedSfSymbol: 'number',
    isVisible: _channelsVisible,
    createAction: channelSidebarCreateAction,
  ),
];

SidebarTabDescriptor sidebarTabDescriptor(SidebarTabId id) =>
    sidebarTabRegistry.firstWhere((descriptor) => descriptor.id == id);

List<SidebarTabId> visibleSidebarTabIds(SidebarTabAvailability availability) =>
    [
      for (final descriptor in sidebarTabRegistry)
        if (descriptor.isVisible(availability)) descriptor.id,
    ];
