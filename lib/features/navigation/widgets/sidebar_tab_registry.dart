import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../channels/widgets/channel_list_tab.dart';
import '../../hermes/widgets/hermes_sessions_tab.dart';
import '../../notes/widgets/notes_list_tab.dart';
import '../../terminal/widgets/terminal_tab.dart';
import '../models/sidebar_navigation_model.dart';
import 'chats_drawer.dart';

const AssetImage kHermesTabIcon = AssetImage('assets/icons/hermes_agent.png');

enum SidebarCreateActionKind { chat, hermesChat, note, channel }

enum SidebarSelectionPolicy { standard, terminal }

typedef SidebarTabLabelBuilder = String Function(AppLocalizations l10n);
typedef SidebarTabBodyBuilder =
    Widget Function({required bool showBottomNavigation, required bool active});

/// Presentation and composition metadata consumed only by the sidebar UI.
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
    this.assetName,
    this.createAction,
    this.selectionPolicy = SidebarSelectionPolicy.standard,
  });

  final SidebarTabId id;
  final SidebarTabLabelBuilder labelBuilder;
  final SidebarTabLabelBuilder searchHintBuilder;
  final SidebarTabBodyBuilder bodyBuilder;
  final IconData materialIcon;
  final IconData selectedMaterialIcon;
  final String sfSymbol;
  final String selectedSfSymbol;
  final String? assetName;
  final SidebarCreateActionKind? createAction;
  final SidebarSelectionPolicy selectionPolicy;

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
    createAction: SidebarCreateActionKind.chat,
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
    assetName: 'assets/icons/hermes_agent.png',
    createAction: SidebarCreateActionKind.hermesChat,
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
    createAction: SidebarCreateActionKind.note,
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
    selectionPolicy: SidebarSelectionPolicy.terminal,
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
    createAction: SidebarCreateActionKind.channel,
  ),
];

SidebarTabDescriptor sidebarTabDescriptor(SidebarTabId id) =>
    sidebarTabRegistry.firstWhere((descriptor) => descriptor.id == id);
