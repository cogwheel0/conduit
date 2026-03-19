import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/responsive_drawer_layout.dart';
import '../providers/sidebar_providers.dart';
import '../../channels/widgets/channel_list_tab.dart';
import '../../notes/widgets/notes_list_tab.dart';
import 'chats_drawer.dart';

/// Full-page tabbed sidebar with Chats, Notes, and Channels tabs.
///
/// Replaces the single-purpose [ChatsDrawer] as the drawer content
/// in [ResponsiveDrawerLayout]. Tab selection is persisted via
/// [sidebarActiveTabProvider].
///
/// When the notes feature is disabled via [notesFeatureEnabledProvider],
/// the Notes tab is hidden and only Chats and Channels are shown.
class SidebarPage extends ConsumerStatefulWidget {
  const SidebarPage({super.key});

  @override
  ConsumerState<SidebarPage> createState() => _SidebarPageState();
}

class _SidebarPageState extends ConsumerState<SidebarPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _notesEnabled = true;

  @override
  void initState() {
    super.initState();
    _notesEnabled = ref.read(notesFeatureEnabledProvider);
    final tabCount = _notesEnabled ? 3 : 2;
    final initialIndex =
        ref.read(sidebarActiveTabProvider).clamp(0, tabCount - 1);
    _tabController = TabController(
      length: tabCount,
      vsync: this,
      initialIndex: initialIndex,
    );
    _tabController.addListener(_onTabChanged);
  }

  void _onTabChanged() {
    if (!_tabController.indexIsChanging) {
      ref.read(sidebarActiveTabProvider.notifier).set(
            _tabController.index,
          );
    }
  }

  /// Rebuilds the [TabController] when the notes feature flag changes.
  void _rebuildTabController(bool notesEnabled) {
    if (notesEnabled == _notesEnabled) return;
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();

    _notesEnabled = notesEnabled;
    final tabCount = _notesEnabled ? 3 : 2;
    final currentIndex =
        ref.read(sidebarActiveTabProvider).clamp(0, tabCount - 1);
    _tabController = TabController(
      length: tabCount,
      vsync: this,
      initialIndex: currentIndex,
    );
    _tabController.addListener(_onTabChanged);
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final notesEnabled = ref.watch(notesFeatureEnabledProvider);
    _rebuildTabController(notesEnabled);

    final tabs = <Tab>[
      Tab(text: AppLocalizations.of(context)!.sidebarChatsTab),
      if (notesEnabled)
        Tab(text: AppLocalizations.of(context)!.sidebarNotesTab),
      Tab(text: AppLocalizations.of(context)!.sidebarChannelsTab),
    ];

    final bodies = <Widget>[
      const ChatsDrawer(),
      if (notesEnabled) const NotesListTab(),
      const ChannelListTab(),
    ];

    return Column(
      children: [
        // Header: close button + tab bar
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: FloatingAppBarIconButton(
                  icon: UiUtils.closeIcon,
                  onTap: () =>
                      ResponsiveDrawerLayout.of(context)?.close(),
                ),
              ),
              Expanded(
                child: TabBar(
                  controller: _tabController,
                  tabs: tabs,
                  labelColor: theme.colorScheme.primary,
                  unselectedLabelColor:
                      theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  indicatorColor: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 52), // Balance the close button
            ],
          ),
        ),
        // Tab bodies
        Expanded(
          child: TabBarView(
            controller: _tabController,
            // Disable swipe between tabs — conflicts with drawer
            // close gesture at full width.
            physics: const NeverScrollableScrollPhysics(),
            children: bodies,
          ),
        ),
      ],
    );
  }
}
