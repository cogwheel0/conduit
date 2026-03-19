import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/responsive_drawer_layout.dart';
import '../providers/sidebar_providers.dart';
import 'chats_drawer.dart';

/// Full-page tabbed sidebar with Chats, Notes, and Channels tabs.
///
/// Replaces the single-purpose [ChatsDrawer] as the drawer content
/// in [ResponsiveDrawerLayout]. Tab selection is persisted via
/// [sidebarActiveTabProvider].
class SidebarPage extends ConsumerStatefulWidget {
  const SidebarPage({super.key});

  @override
  ConsumerState<SidebarPage> createState() => _SidebarPageState();
}

class _SidebarPageState extends ConsumerState<SidebarPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    final initialIndex = ref.read(sidebarActiveTabProvider);
    _tabController = TabController(
      length: 3,
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

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        // Header: close button + tab bar
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  ResponsiveDrawerLayout.of(context)?.close();
                },
                tooltip: AppLocalizations.of(context)!.closeSidebar,
              ),
              Expanded(
                child: TabBar(
                  controller: _tabController,
                  tabs: [
                    Tab(text: AppLocalizations.of(context)!.sidebarChatsTab),
                    Tab(text: AppLocalizations.of(context)!.sidebarNotesTab),
                    Tab(
                      text: AppLocalizations.of(context)!.sidebarChannelsTab,
                    ),
                  ],
                  labelColor: theme.colorScheme.primary,
                  unselectedLabelColor:
                      theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  indicatorColor: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 48), // Balance the close button
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
            children: const [
              ChatsDrawer(),
              // Task 6 will add NotesListTab.
              Center(child: Text('Notes')),
              // Task 9 will add ChannelListTab.
              Center(child: Text('Channels')),
            ],
          ),
        ),
      ],
    );
  }
}
