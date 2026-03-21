import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../providers/sidebar_providers.dart';
import '../../channels/widgets/channel_list_tab.dart';
import '../../notes/widgets/notes_list_tab.dart';
import 'chats_drawer.dart';

enum _SidebarTabId { chats, notes, channels }

class _SidebarTabDefinition {
  const _SidebarTabDefinition({
    required this.id,
    required this.label,
    required this.body,
  });

  final _SidebarTabId id;
  final String label;
  final Widget body;

  ValueKey<String> get selectorKey =>
      ValueKey<String>('sidebar-tab-selector-${id.name}');

  ValueKey<String> get layerKey =>
      ValueKey<String>('sidebar-tab-layer-${id.name}');
}

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
    with TickerProviderStateMixin {
  late TabController _tabController;
  bool _notesEnabled = true;
  ProviderSubscription<bool>? _notesEnabledSubscription;

  int _clampIndex(int tabCount) {
    final persistedIndex = ref.read(sidebarActiveTabProvider);
    return persistedIndex.clamp(0, tabCount - 1);
  }

  void _schedulePersistedIndexSync(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      final persistedIndex = ref.read(sidebarActiveTabProvider);
      if (persistedIndex != index) {
        ref.read(sidebarActiveTabProvider.notifier).set(index);
      }
    });
  }

  int _resolveIndex(int tabCount) {
    final persistedIndex = ref.read(sidebarActiveTabProvider);
    final clampedIndex = _clampIndex(tabCount);
    if (clampedIndex != persistedIndex) {
      _schedulePersistedIndexSync(clampedIndex);
    }
    return clampedIndex;
  }

  @override
  void initState() {
    super.initState();
    _notesEnabled = ref.read(notesFeatureEnabledProvider);
    final tabCount = _notesEnabled ? 3 : 2;
    final initialIndex = _resolveIndex(tabCount);
    _tabController = TabController(
      length: tabCount,
      vsync: this,
      initialIndex: initialIndex,
    );
    _tabController.addListener(_onTabChanged);
    _notesEnabledSubscription = ref.listenManual<bool>(
      notesFeatureEnabledProvider,
      (previous, next) {
        if (next != _notesEnabled) {
          _rebuildTabController(next);
        }
      },
    );
  }

  void _onTabChanged() {
    final persistedIndex = ref.read(sidebarActiveTabProvider);
    if (persistedIndex != _tabController.index) {
      ref.read(sidebarActiveTabProvider.notifier).set(_tabController.index);
    }
  }

  /// Rebuilds the [TabController] when the notes feature flag changes.
  void _rebuildTabController(bool notesEnabled) {
    if (notesEnabled == _notesEnabled) return;

    final previousController = _tabController;
    previousController.removeListener(_onTabChanged);
    final resolvedTabCount = notesEnabled ? 3 : 2;
    final currentIndex = _resolveIndex(resolvedTabCount);
    final nextController = TabController(
      length: resolvedTabCount,
      vsync: this,
      initialIndex: currentIndex,
    );
    nextController.addListener(_onTabChanged);

    setState(() {
      _notesEnabled = notesEnabled;
      _tabController = nextController;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      previousController.dispose();
    });
  }

  @override
  void dispose() {
    _notesEnabledSubscription?.close();
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;
    final tabDefinitions = <_SidebarTabDefinition>[
      _SidebarTabDefinition(
        id: _SidebarTabId.chats,
        label: localizations.sidebarChatsTab,
        body: const ChatsDrawer(),
      ),
      if (_notesEnabled)
        _SidebarTabDefinition(
          id: _SidebarTabId.notes,
          label: localizations.sidebarNotesTab,
          body: const NotesListTab(),
        ),
      _SidebarTabDefinition(
        id: _SidebarTabId.channels,
        label: localizations.sidebarChannelsTab,
        body: const ChannelListTab(),
      ),
    ];

    final conduitTheme = context.conduitTheme;

    return Column(
      children: [
        // Tab bar
        TabBar(
          controller: _tabController,
          tabs: [
            for (final tabDefinition in tabDefinitions)
              Tab(key: tabDefinition.selectorKey, text: tabDefinition.label),
          ],
          labelColor: conduitTheme.textPrimary,
          unselectedLabelColor: conduitTheme.textSecondary,
          labelStyle: AppTypography.bodySmallStyle.copyWith(
            fontWeight: FontWeight.w600,
          ),
          unselectedLabelStyle: AppTypography.bodySmallStyle,
          indicatorColor: conduitTheme.textPrimary,
          indicatorWeight: BorderWidth.thick,
          dividerHeight: 0,
        ),
        Expanded(
          child: AnimatedBuilder(
            animation: _tabController,
            builder: (context, _) {
              final activeIndex = _tabController.index.clamp(
                0,
                tabDefinitions.length - 1,
              );

              return Stack(
                fit: StackFit.expand,
                children: [
                  for (var index = 0; index < tabDefinitions.length; index++)
                    KeyedSubtree(
                      key: tabDefinitions[index].layerKey,
                      child: IgnorePointer(
                        ignoring: index != activeIndex,
                        child: TickerMode(
                          enabled: index == activeIndex,
                          child: ExcludeFocus(
                            excluding: index != activeIndex,
                            child: ExcludeSemantics(
                              excluding: index != activeIndex,
                              child: Opacity(
                                opacity: index == activeIndex ? 1 : 0,
                                child: tabDefinitions[index].body,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}
