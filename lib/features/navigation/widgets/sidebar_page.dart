import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/adaptive_toolbar_components.dart';
import '../../../shared/widgets/sidebar_ios26_scaffold.dart';
import '../../../shared/widgets/sidebar_primary_circle_button.dart';
import '../providers/sidebar_providers.dart';
import '../utils/sidebar_create_action.dart';
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
  const _SidebarNavigationItem({
    required this.label,
    required this.destination,
    required this.tabDefinition,
  });

  final String label;
  final AdaptiveNavigationDestination destination;
  final _SidebarTabDefinition tabDefinition;
}

/// Keeps all sidebar tab subtrees mounted and only toggles which one is active.
///
/// This preserves scroll position and local widget state across tab switches on
/// every platform, including the iOS 26 native-tab workaround.
class _SidebarTabStack extends StatelessWidget {
  const _SidebarTabStack({
    required this.tabDefinitions,
    required this.activeIndex,
  });

  final List<_SidebarTabDefinition> tabDefinitions;
  final int activeIndex;

  @override
  Widget build(BuildContext context) {
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
  }
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

String _sfSymbolTabIcon(_SidebarTabId id, {bool selected = false}) {
  switch (id) {
    case _SidebarTabId.chats:
      return selected ? 'bubble.left.fill' : 'bubble.left';
    case _SidebarTabId.notes:
      return selected ? 'doc.text.fill' : 'doc.text';
    case _SidebarTabId.channels:
      return 'number';
  }
}

class _SidebarMaterialBottomNavigationBar extends StatelessWidget {
  const _SidebarMaterialBottomNavigationBar({
    required this.navigationItems,
    required this.selectedIndex,
    required this.onTap,
    required this.conduitTheme,
  });

  final List<_SidebarNavigationItem> navigationItems;
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
            for (final item in navigationItems)
              NavigationDestination(
                icon: Icon(_materialTabIcon(item.tabDefinition.id)),
                selectedIcon: Icon(
                  _materialTabIcon(item.tabDefinition.id, selected: true),
                ),
                label: item.label,
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
/// Notes and Channels tabs are each independently optional. When the
/// server disables a feature (via [notesFeatureEnabledProvider] or
/// [channelsFeatureEnabledProvider]), the corresponding tab is hidden and the
/// persisted index is clamped to the visible tab range.
class SidebarPage extends ConsumerStatefulWidget {
  const SidebarPage({super.key});

  @override
  ConsumerState<SidebarPage> createState() => _SidebarPageState();
}

class _SidebarPageState extends ConsumerState<SidebarPage> {
  int _clampIndex(int index, int tabCount) => index.clamp(0, tabCount - 1);

  void _schedulePersistedIndexSync(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      final persistedIndex = ref.read(sidebarActiveTabProvider);
      if (persistedIndex != index) {
        ref.read(sidebarActiveTabProvider.notifier).set(index);
      }
    });
  }

  AdaptiveBottomNavigationBar _sidebarBottomNavigationBar(
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
      selectedItemColor: conduitTheme.buttonPrimary,
      unselectedItemColor: conduitTheme.textSecondary,
      bottomNavigationBar: _SidebarMaterialBottomNavigationBar(
        navigationItems: navigationItems,
        selectedIndex: selectedIndex.clamp(0, navigationItems.length - 1),
        onTap: onTap,
        conduitTheme: conduitTheme,
      ),
    );
  }

  List<_SidebarNavigationItem> _sidebarNavigationItems(
    List<_SidebarTabDefinition> tabDefinitions,
  ) {
    return <_SidebarNavigationItem>[
      for (final def in tabDefinitions)
        _SidebarNavigationItem(
          label: def.label,
          destination: AdaptiveNavigationDestination(
            icon: _sfSymbolTabIcon(def.id),
            selectedIcon: _sfSymbolTabIcon(def.id, selected: true),
            label: def.label,
          ),
          tabDefinition: def,
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

  void _closeSidebarSearch() {
    ref.read(sidebarSearchFieldControllerProvider).clear();
    ref.read(sidebarSearchFieldFocusNodeProvider).unfocus();
    ref.read(sidebarHeaderSearchExpandedProvider.notifier).setExpanded(false);
  }

  Widget _sidebarAppBarLeading({
    required AppLocalizations localizations,
    required bool isSearchExpanded,
  }) {
    return isSearchExpanded
        ? SidebarSearchAppBarLeading(
            hintText: sidebarSearchHintForActiveTab(ref, localizations),
          )
        : const SidebarProfileAppBarLeading();
  }

  List<AdaptiveAppBarAction> _sidebarAppBarActions({
    required BuildContext context,
    required AppLocalizations localizations,
    required bool isSearchExpanded,
  }) {
    final defaultTint = context.conduitTheme.textPrimary;
    if (isSearchExpanded) {
      return [
        AdaptiveAppBarAction(
          iosSymbol: 'xmark',
          icon: UiUtils.closeIcon,
          tintColor: defaultTint,
          onPressed: _closeSidebarSearch,
        ),
      ];
    }

    final createAction = sidebarCreateActionForActiveTab(ref, localizations);
    return [
      AdaptiveAppBarAction(
        iosSymbol: 'magnifyingglass',
        icon: Icons.search,
        tintColor: defaultTint,
        onPressed: _openSidebarSearch,
      ),
      AdaptiveAppBarAction(
        iosSymbol: createAction.sfSymbol,
        icon: createAction.icon,
        tintColor: defaultTint,
        onPressed: () => runSidebarCreateAction(context, ref),
      ),
    ];
  }

  PreferredSizeWidget _sidebarMaterialAppBar({
    required BuildContext context,
    required Widget leading,
    required List<AdaptiveAppBarAction> actions,
    required bool isSearchExpanded,
  }) {
    final backgroundColor = context.conduitTheme.surfaceBackground;
    return AppBar(
      backgroundColor: backgroundColor,
      elevation: Elevation.none,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      toolbarHeight: kTextTabBarHeight,
      leadingWidth: isSearchExpanded
          ? MediaQuery.sizeOf(context).width - 64
          : 60,
      leading: Padding(
        padding: const EdgeInsets.only(left: Spacing.inputPadding),
        child: leading,
      ),
      actions: [
        for (var index = 0; index < actions.length; index++)
          Padding(
            padding: EdgeInsets.only(
              right: index == actions.length - 1
                  ? Spacing.inputPadding
                  : Spacing.sm,
            ),
            child: Center(
              child: ConduitAdaptiveAppBarIconButton(
                icon: actions[index].icon ?? Icons.circle,
                onPressed: actions[index].onPressed,
                iconColor: context.conduitTheme.textPrimary,
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;
    final notesEnabled = ref.watch(notesFeatureEnabledProvider);
    final channelsEnabled = ref.watch(channelsFeatureEnabledProvider);
    final tabDefinitions = <_SidebarTabDefinition>[
      _SidebarTabDefinition(
        id: _SidebarTabId.chats,
        label: localizations.sidebarChatsTab,
        body: const ChatsDrawer(),
      ),
      if (notesEnabled)
        _SidebarTabDefinition(
          id: _SidebarTabId.notes,
          label: localizations.sidebarNotesTab,
          body: const NotesListTab(),
        ),
      if (channelsEnabled)
        _SidebarTabDefinition(
          id: _SidebarTabId.channels,
          label: localizations.sidebarChannelsTab,
          body: const ChannelListTab(),
        ),
    ];
    final persistedIndex = ref.watch(sidebarActiveTabProvider);
    final activeIndex = _clampIndex(persistedIndex, tabDefinitions.length);
    if (activeIndex != persistedIndex) {
      _schedulePersistedIndexSync(activeIndex);
    }
    final navigationItems = _sidebarNavigationItems(tabDefinitions);

    final conduitTheme = context.conduitTheme;
    final isSearchExpanded = ref.watch(sidebarHeaderSearchExpandedProvider);
    final appBarLeading = _sidebarAppBarLeading(
      localizations: localizations,
      isSearchExpanded: isSearchExpanded,
    );
    final appBarActions = _sidebarAppBarActions(
      context: context,
      localizations: localizations,
      isSearchExpanded: isSearchExpanded,
    );
    final useNativeIos26Chrome = PlatformInfo.isIOS26OrHigher();

    void onTap(int index) =>
        ref.read(sidebarActiveTabProvider.notifier).set(index);

    final sidebarBody = _SidebarTabStack(
      tabDefinitions: tabDefinitions,
      activeIndex: activeIndex,
    );

    return KeyedSubtree(
      key: const ValueKey<String>('sidebar-page-surface'),
      child: SidebarTabScaffoldLayout(
        usesToolbarOverlay: useNativeIos26Chrome,
        usesBottomBarOverlay: useNativeIos26Chrome,
        // iOS 26 uses a small compatibility wrapper so tab changes keep the
        // sidebar body mounted. Other platforms can stay on AdaptiveScaffold.
        child: useNativeIos26Chrome
            ? SidebarIos26Scaffold(
                bottomNavigationBar: _sidebarBottomNavigationBar(
                  navigationItems,
                  conduitTheme,
                  activeIndex,
                  onTap,
                ),
                leading: appBarLeading,
                actions: appBarActions,
                minimizeBehavior: TabBarMinimizeBehavior.never,
                body: sidebarBody,
              )
            : AdaptiveScaffold(
                minimizeBehavior: TabBarMinimizeBehavior.never,
                appBar: AdaptiveAppBar(
                  useNativeToolbar: true,
                  leading: appBarLeading,
                  actions: appBarActions,
                  appBar: _sidebarMaterialAppBar(
                    context: context,
                    leading: appBarLeading,
                    actions: appBarActions,
                    isSearchExpanded: isSearchExpanded,
                  ),
                ),
                bottomNavigationBar: _sidebarBottomNavigationBar(
                  navigationItems,
                  conduitTheme,
                  activeIndex,
                  onTap,
                ),
                body: sidebarBody,
              ),
      ),
    );
  }
}
