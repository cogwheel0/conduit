import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../providers/sidebar_providers.dart';
import '../../channels/widgets/channel_list_tab.dart';
import '../../notes/widgets/notes_list_tab.dart';
import 'chats_drawer.dart';
import 'sidebar_user_pill.dart';

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

class _SidebarPillTabBar extends StatelessWidget {
  const _SidebarPillTabBar({
    required this.tabController,
    required this.tabDefinitions,
    required this.theme,
  });

  final TabController tabController;
  final List<_SidebarTabDefinition> tabDefinitions;
  final ConduitThemeExtension theme;

  Widget _buildSlidingPill(double tabWidth) {
    final pillDecoration = BoxDecoration(
      color: theme.textPrimary.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(7),
    );

    final animation = tabController.animation;
    if (animation == null) {
      return Positioned(
        left: tabController.index * tabWidth,
        top: 0,
        bottom: 0,
        width: tabWidth,
        child: DecoratedBox(decoration: pillDecoration),
      );
    }

    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final left = animation.value * tabWidth;

        return Positioned(
          left: left,
          top: 0,
          bottom: 0,
          width: tabWidth,
          child: DecoratedBox(decoration: pillDecoration),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final tabCount = tabDefinitions.length;

    return Container(
      key: const ValueKey<String>('sidebar-pill-tab-bar'),
      height: 46,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      decoration: BoxDecoration(
        color: theme.surfaceContainer,
        borderRadius: BorderRadius.circular(9),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final tabWidth = constraints.maxWidth / tabCount;

          return Stack(
            children: [
              _buildSlidingPill(tabWidth),
              Semantics(
                container: true,
                label: 'Tab bar',
                child: Row(
                  children: [
                    for (var i = 0; i < tabCount; i++)
                      Expanded(
                        child: GestureDetector(
                          key: tabDefinitions[i].selectorKey,
                          behavior: HitTestBehavior.opaque,
                          onTap: () => tabController.animateTo(i),
                          child: AnimatedBuilder(
                            animation: tabController,
                            builder: (context, _) {
                              final isActive = tabController.index == i;
                              return Semantics(
                                label: tabDefinitions[i].label,
                                selected: isActive,
                                button: true,
                                child: Center(
                                  child: Text(
                                    tabDefinitions[i].label,
                                    style: AppTypography.sidebarLabelStyle
                                        .copyWith(
                                          fontWeight: isActive
                                              ? FontWeight.w600
                                              : FontWeight.normal,
                                          color: isActive
                                              ? theme.textPrimary
                                              : theme.textSecondary,
                                        ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Full-page tabbed sidebar with Chats, Notes, and Channels tabs.
///
/// Replaces the single-purpose [ChatsDrawer] as the drawer content
/// in [ResponsiveDrawerLayout]. Tab selection is persisted via
/// [sidebarActiveTabProvider].
///
/// Notes and Channels tabs are each independently optional. When the
/// server disables a feature (via [notesFeatureEnabledProvider] or
/// [channelsFeatureEnabledProvider]), the corresponding tab is hidden
/// and the [TabController] is rebuilt with the correct count.
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
  bool _channelsEnabled = true;
  ProviderSubscription<bool>? _channelsEnabledSubscription;

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
    _channelsEnabled = ref.read(channelsFeatureEnabledProvider);
    final tabCount = 1 + (_notesEnabled ? 1 : 0) + (_channelsEnabled ? 1 : 0);
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
          _rebuildTabController(notesEnabled: next);
        }
      },
    );
    _channelsEnabledSubscription = ref.listenManual<bool>(
      channelsFeatureEnabledProvider,
      (previous, next) {
        if (next != _channelsEnabled) {
          _rebuildTabController(channelsEnabled: next);
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

  /// Rebuilds the [TabController] when a feature flag changes.
  ///
  /// Pass [notesEnabled] or [channelsEnabled] (or both) to update
  /// the corresponding flag and recompute the tab count. The previous
  /// [TabController] is disposed after the next frame to avoid
  /// use-after-dispose during the rebuild.
  void _rebuildTabController({bool? notesEnabled, bool? channelsEnabled}) {
    final newNotes = notesEnabled ?? _notesEnabled;
    final newChannels = channelsEnabled ?? _channelsEnabled;

    if (newNotes == _notesEnabled && newChannels == _channelsEnabled) return;

    final previousController = _tabController;
    previousController.removeListener(_onTabChanged);

    final resolvedTabCount = 1 + (newNotes ? 1 : 0) + (newChannels ? 1 : 0);

    final currentIndex = _resolveIndex(resolvedTabCount);
    final nextController = TabController(
      length: resolvedTabCount,
      vsync: this,
      initialIndex: currentIndex,
    );
    nextController.addListener(_onTabChanged);

    setState(() {
      _notesEnabled = newNotes;
      _channelsEnabled = newChannels;
      _tabController = nextController;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      previousController.dispose();
    });
  }

  @override
  void dispose() {
    _notesEnabledSubscription?.close();
    _channelsEnabledSubscription?.close();
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
      if (_channelsEnabled)
        _SidebarTabDefinition(
          id: _SidebarTabId.channels,
          label: localizations.sidebarChannelsTab,
          body: const ChannelListTab(),
        ),
    ];

    final conduitTheme = context.conduitTheme;
    final sidebarTheme = context.sidebarTheme;
    final backgroundColor = conduitTheme.surfaceBackground;

    return Container(
      key: const ValueKey<String>('sidebar-page-surface'),
      decoration: BoxDecoration(
        color: backgroundColor,
        border: Border(right: BorderSide(color: sidebarTheme.border)),
      ),
      child: Column(
        children: [
          _SidebarPillTabBar(
            tabController: _tabController,
            tabDefinitions: tabDefinitions,
            theme: conduitTheme,
          ),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
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
                          for (
                            var index = 0;
                            index < tabDefinitions.length;
                            index++
                          )
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
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: SidebarUserPillOverlay(
                    backgroundColor: backgroundColor,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
