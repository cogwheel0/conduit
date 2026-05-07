import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../providers/sidebar_providers.dart';
import '../../channels/widgets/channel_list_tab.dart';
import '../../notes/widgets/notes_list_tab.dart';
import 'chats_drawer.dart';
import 'sidebar_user_pill.dart';

/// Compact bottom bar height on Material (default M3 bar is ~80 logical px).
const double _kSidebarNavigationBarHeight = 56;
const double _kSidebarNavigationBarIconSize = 22;

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

  ValueKey<String> get layerKey =>
      ValueKey<String>('sidebar-tab-layer-${id.name}');
}

class _SidebarNavigationItem {
  const _SidebarNavigationItem.search({
    required this.label,
    required this.destination,
  }) : tabDefinition = null;

  const _SidebarNavigationItem.content({
    required this.label,
    required this.destination,
    required this.tabDefinition,
  });

  final String label;
  final AdaptiveNavigationDestination destination;
  final _SidebarTabDefinition? tabDefinition;

  bool get isSearchAction => tabDefinition == null;
}

IconData _materialTabIcon(_SidebarTabId id, {bool selected = false}) {
  switch (id) {
    case _SidebarTabId.chats:
      return selected ? Icons.chat_bubble : Icons.chat_bubble_outline;
    case _SidebarTabId.notes:
      return selected ? Icons.note : Icons.note_outlined;
    case _SidebarTabId.channels:
      return Icons.tag;
  }
}

IconData _cupertinoTabIcon(_SidebarTabId id, {bool selected = false}) {
  switch (id) {
    case _SidebarTabId.chats:
      return selected
          ? CupertinoIcons.chat_bubble_fill
          : CupertinoIcons.chat_bubble;
    case _SidebarTabId.notes:
      return selected ? CupertinoIcons.doc_text_fill : CupertinoIcons.doc_text;
    case _SidebarTabId.channels:
      return selected ? CupertinoIcons.number_circle_fill : CupertinoIcons.tag;
  }
}

String _sfSymbolTabIcon(_SidebarTabId id, {bool selected = false}) {
  switch (id) {
    case _SidebarTabId.chats:
      return selected ? 'bubble.left.fill' : 'bubble.left';
    case _SidebarTabId.notes:
      return selected ? 'doc.text.fill' : 'doc.text';
    case _SidebarTabId.channels:
      return selected ? 'number.circle.fill' : 'number.circle';
  }
}

class _SidebarMaterialBottomNavigationBar extends StatelessWidget {
  const _SidebarMaterialBottomNavigationBar({
    required this.tabDefinitions,
    required this.selectedIndex,
    required this.onTap,
    required this.conduitTheme,
  });

  final List<_SidebarTabDefinition> tabDefinitions;
  final int selectedIndex;
  final ValueChanged<int> onTap;
  final ConduitThemeExtension conduitTheme;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppBorderRadius.pill),
      child: NavigationBarTheme(
        data: NavigationBarTheme.of(context).copyWith(
          height: _kSidebarNavigationBarHeight,
          backgroundColor: conduitTheme.surfaceBackground,
          elevation: 0,
          indicatorColor: conduitTheme.buttonPrimary.withValues(alpha: 0.12),
          indicatorShape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppBorderRadius.pill),
          ),
          iconTheme: WidgetStateProperty.resolveWith<IconThemeData?>((states) {
            final selected = states.contains(WidgetState.selected);
            return IconThemeData(
              color: selected
                  ? conduitTheme.buttonPrimary
                  : conduitTheme.textSecondary,
              size: _kSidebarNavigationBarIconSize,
            );
          }),
          labelTextStyle: WidgetStateProperty.resolveWith<TextStyle?>((states) {
            final selected = states.contains(WidgetState.selected);
            return AppTypography.labelSmallStyle.copyWith(
              color: selected
                  ? conduitTheme.buttonPrimary
                  : conduitTheme.textSecondary,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
            );
          }),
        ),
        child: NavigationBar(
          selectedIndex: selectedIndex,
          onDestinationSelected: onTap,
          height: _kSidebarNavigationBarHeight,
          backgroundColor: conduitTheme.surfaceBackground,
          elevation: 0,
          indicatorColor: conduitTheme.buttonPrimary.withValues(alpha: 0.12),
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          destinations: [
            for (final def in tabDefinitions)
              NavigationDestination(
                icon: Icon(_materialTabIcon(def.id)),
                selectedIcon: Icon(_materialTabIcon(def.id, selected: true)),
                label: def.label,
              ),
          ],
        ),
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
/// The sidebar is rendered inside one package-owned [AdaptiveScaffold] so
/// `adaptive_platform_ui` can host the native iOS 26 [UITabBar] using its
/// intended full-body layout. Older iOS versions use an explicit
/// [CupertinoTabBar], and Material platforms use an explicit [NavigationBar].
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

  AdaptiveBottomNavigationBar _sidebarAdaptiveBottomNavigationBar(
    List<_SidebarNavigationItem> navigationItems,
    ConduitThemeExtension conduitTheme,
    int selectedIndex,
    ValueChanged<int> onTap,
  ) {
    return AdaptiveBottomNavigationBar(
      items: [for (final item in navigationItems) item.destination],
      selectedIndex: selectedIndex,
      onTap: onTap,
      useNativeBottomBar: true,
      cupertinoTabBar: CupertinoTabBar(
        currentIndex: selectedIndex,
        onTap: onTap,
        height: _kSidebarNavigationBarHeight,
        backgroundColor: conduitTheme.surfaceBackground,
        activeColor: conduitTheme.buttonPrimary,
        inactiveColor: conduitTheme.textSecondary,
        border: null,
        items: [
          for (final item in navigationItems)
            BottomNavigationBarItem(
              icon: Icon(
                item.isSearchAction
                    ? CupertinoIcons.search
                    : _cupertinoTabIcon(item.tabDefinition!.id),
              ),
              activeIcon: Icon(
                item.isSearchAction
                    ? CupertinoIcons.search
                    : _cupertinoTabIcon(item.tabDefinition!.id, selected: true),
              ),
              label: item.label,
            ),
        ],
      ),
      bottomNavigationBar: _SidebarMaterialBottomNavigationBar(
        tabDefinitions: [
          for (final item in navigationItems)
            if (!item.isSearchAction) item.tabDefinition!,
        ],
        selectedIndex: _tabController.index.clamp(
          0,
          navigationItems.where((item) => !item.isSearchAction).length - 1,
        ),
        onTap: onTap,
        conduitTheme: conduitTheme,
      ),
      selectedItemColor: conduitTheme.buttonPrimary,
      unselectedItemColor: conduitTheme.textSecondary,
    );
  }

  List<_SidebarNavigationItem> _sidebarNavigationItems(
    List<_SidebarTabDefinition> tabDefinitions,
    String searchLabel,
    bool includeSearchAction,
  ) {
    return <_SidebarNavigationItem>[
      for (final def in tabDefinitions)
        _SidebarNavigationItem.content(
          label: def.label,
          destination: AdaptiveNavigationDestination(
            icon: _sfSymbolTabIcon(def.id),
            selectedIcon: _sfSymbolTabIcon(def.id, selected: true),
            label: def.label,
          ),
          tabDefinition: def,
        ),
      if (includeSearchAction)
        _SidebarNavigationItem.search(
          label: searchLabel,
          destination: AdaptiveNavigationDestination(
            icon: 'magnifyingglass',
            selectedIcon: 'magnifyingglass',
            label: searchLabel,
            isSearch: true,
          ),
        ),
    ];
  }

  void _openSidebarSearch() {
    ref.read(sidebarHeaderSearchExpandedProvider.notifier).setExpanded(true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(sidebarSearchFieldFocusNodeProvider).requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;
    final searchLabel = MaterialLocalizations.of(context).searchFieldLabel;
    final showsNativeSearchAction = PlatformInfo.isIOS26OrHigher();
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
    final navigationItems = _sidebarNavigationItems(
      tabDefinitions,
      searchLabel,
      showsNativeSearchAction,
    );

    final conduitTheme = context.conduitTheme;
    final sidebarTheme = context.sidebarTheme;
    final backgroundColor = conduitTheme.surfaceBackground;

    return ListenableBuilder(
      listenable: _tabController,
      builder: (context, _) {
        final activeIndex = _tabController.index.clamp(
          0,
          tabDefinitions.length - 1,
        );
        final selectedNavigationIndex = activeIndex;

        void onTap(int index) {
          final item = navigationItems[index];
          if (item.isSearchAction) {
            _openSidebarSearch();
            setState(() {});
            return;
          }

          final tabIndex = tabDefinitions.indexOf(item.tabDefinition!);
          if (tabIndex >= 0) {
            _tabController.animateTo(tabIndex);
          }
        }

        return Container(
          key: const ValueKey<String>('sidebar-page-surface'),
          decoration: BoxDecoration(
            color: backgroundColor,
            border: Border(right: BorderSide(color: sidebarTheme.border)),
          ),
          child: Theme(
            data: Theme.of(
              context,
            ).copyWith(scaffoldBackgroundColor: backgroundColor),
            child: AdaptiveScaffold(
              minimizeBehavior: TabBarMinimizeBehavior.never,
              body: SafeArea(
                top: true,
                bottom: false,
                left: false,
                right: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SidebarUserPillOverlay(),
                    Expanded(
                      child: Stack(
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
                      ),
                    ),
                  ],
                ),
              ),
              bottomNavigationBar: _sidebarAdaptiveBottomNavigationBar(
                navigationItems,
                conduitTheme,
                selectedNavigationIndex,
                onTap,
              ),
            ),
          ),
        );
      },
    );
  }
}
