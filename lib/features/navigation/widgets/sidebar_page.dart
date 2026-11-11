import 'dart:async';
import 'dart:io' show Platform;

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/features/navigation/models/sidebar_navigation_model.dart';

import 'package:conduit_core/sync/sync_engine.dart';

import '../../../core/services/haptic_service.dart';
import '../../../shared/services/navigation_service.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/adaptive_toolbar_components.dart';
import '../../../shared/widgets/chrome_gradient_fade.dart';
import '../../../shared/widgets/sidebar_layout_contract.dart';
import '../../../shared/widgets/sidebar_layout_constants.dart';
import '../../../shared/widgets/sidebar_ios26_scaffold.dart';
import '../../../shared/widgets/themed_sheets.dart';
import '../providers/sidebar_providers.dart';
import '../providers/sidebar_tab_scroll_registry.dart';
import '../utils/sidebar_create_action.dart';
import 'sidebar_user_pill.dart';
import 'sidebar_tab_registry.dart';
import 'chats_drawer.dart';
import 'conversation_tile.dart'
    show
        ChatStyleSidebarTile,
        kConversationTileMinHeight,
        kSidebarRowHorizontalPadding,
        sidebarRowTitleLineStyle;
import '../../../shared/widgets/chat_action_button.dart' show NativeSymbolGlyph;
import '../../hermes/widgets/hermes_connection_switcher.dart';
import '../../hermes/widgets/hermes_sessions_tab.dart';

/// Compact bottom bar height on Material (default M3 bar is ~80 logical px).
const double _kSidebarNavigationBarHeight = 56;
const double _kSidebarSearchCloseActionReserve = 64;
const double _kSidebarSearchFieldReserve = 96;
// Mirrors Conduit platform UI's iPadOS window-control reservation.
const double _kSidebarWindowedLeadingInset = 62;

@visibleForTesting
double resolveSidebarWindowedLeadingInset({
  required bool usesNativeIOS26Chrome,
  required bool isWindowed,
  required bool isIOSAppOnMac,
}) => usesNativeIOS26Chrome && isWindowed && !isIOSAppOnMac
    ? _kSidebarWindowedLeadingInset
    : 0;

void selectSidebarTab(BuildContext context, WidgetRef ref, int index) {
  if (ref.read(appSettingsProvider).slidingSidebarEnabled) {
    _selectSlidingSidebarTab(context, ref, index);
    return;
  }
  final navigation = ref.read(sidebarNavigationSnapshotProvider);
  if (index < 0 || index >= navigation.tabs.length) return;

  final selectedTab = sidebarTabDescriptor(navigation.tabs[index]);
  if (selectedTab.id == navigation.selectedTab) {
    if (navigation.isLegacySelection) {
      ref.read(sidebarActiveTabProvider.notifier).set(selectedTab.id);
    }
    unawaited(
      ref
          .read(sidebarTabScrollRegistryProvider)
          .scrollToTop(
            selectedTab.id,
            duration: context.motionDuration(AnimationDuration.fast),
          ),
    );
    return;
  }

  sidebarTabDescriptor(navigation.selectedTab).behavior.onDeselected(ref);
  ref.read(sidebarActiveTabProvider.notifier).set(selectedTab.id);
  selectedTab.behavior.onSelected(ref);
}

class _SidebarNavigationItem {
  const _SidebarNavigationItem({
    required this.label,
    required this.destination,
    required this.descriptor,
  });

  final String label;
  final AdaptiveNavigationDestination destination;
  final SidebarTabDescriptor descriptor;
}

/// Keeps all sidebar tab subtrees mounted and only toggles which one is active.
///
/// This preserves scroll position and local widget state across tab switches on
/// every platform, including the iOS 26 native-tab workaround.
class _SidebarTabStack extends StatelessWidget {
  const _SidebarTabStack({
    required this.tabs,
    required this.activeIndex,
    required this.showBottomNavigation,
  });

  final List<SidebarTabDescriptor> tabs;
  final int activeIndex;
  final bool showBottomNavigation;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        for (var index = 0; index < tabs.length; index++)
          KeyedSubtree(
            key: tabs[index].layerKey,
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
                      child: tabs[index].bodyBuilder(
                        showBottomNavigation: showBottomNavigation,
                        active: index == activeIndex,
                      ),
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

class _SidebarSyncProgressBar extends StatelessWidget {
  const _SidebarSyncProgressBar({required this.status});

  final SyncStatus status;

  @override
  Widget build(BuildContext context) {
    if (status.phase != SyncPhase.running) return const SizedBox.shrink();

    final localizations = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final label = switch (status.stage) {
      SyncStage.notes => localizations.sidebarSyncingNotes,
      SyncStage.finalizing => localizations.sidebarFinishingSync,
      SyncStage.chats || null => localizations.sidebarSyncingChats,
    };
    final progress = status.progress;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final semanticsValue = progress == null
        ? null
        : '${(progress * 100).round()}%';

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppBorderRadius.pill),
      child: LinearProgressIndicator(
        key: const ValueKey<String>('sidebar-sync-progress'),
        minHeight: 3,
        value: progress ?? (reduceMotion ? 0.08 : null),
        semanticsLabel: label,
        semanticsValue: semanticsValue,
        color: theme.sidebarPrimary,
        backgroundColor: theme.sidebarBorder.withValues(alpha: 0.45),
      ),
    );
  }
}

/// Tab-bar rendering of the Hermes logo as a theme-aware alpha mask.
///
/// The bundled asset is black with transparency, so a raw [Image] would stay
/// black in dark mode instead of inheriting the navigation icon color.
class _SidebarAssetTabImage extends StatelessWidget {
  const _SidebarAssetTabImage(this.assetName, {this.size = IconSize.tabBar});

  final String assetName;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ImageIcon(AssetImage(assetName), size: size);
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
              size: IconSize.tabBar,
            );
          }),
          labelTextStyle: WidgetStateProperty.resolveWith<TextStyle?>((states) {
            final selected = states.contains(WidgetState.selected);
            return AppTypography.materialChromeLabelSmallStyle.copyWith(
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
                icon: item.descriptor.assetName == null
                    ? Icon(item.descriptor.materialIcon)
                    : _SidebarAssetTabImage(
                        item.descriptor.assetName!,
                        size: item.descriptor.assetIconSize ?? IconSize.tabBar,
                      ),
                selectedIcon: item.descriptor.assetName == null
                    ? Icon(item.descriptor.selectedMaterialIcon)
                    : _SidebarAssetTabImage(
                        item.descriptor.assetName!,
                        size: item.descriptor.assetIconSize ?? IconSize.tabBar,
                      ),
                label: item.label,
              ),
          ],
        ),
      ),
    );
  }
}

/// Full-page tabbed sidebar with Chats, Notes (optional), Terminal, and
/// Channels (optional) tabs.
///
/// Replaces the single-purpose [ChatsDrawer] as the drawer content
/// in the responsive drawer layout. Tab selection is persisted via
/// [sidebarActiveTabProvider].
///
/// Notes, Terminal, and Channels tabs are each independently optional. When a
/// persisted tab is unavailable, Chats is shown without overwriting the saved
/// identity, so the selection can be restored if that feature returns.
class SidebarPage extends ConsumerStatefulWidget {
  const SidebarPage({super.key});

  @override
  ConsumerState<SidebarPage> createState() => _SidebarPageState();
}

class _SidebarPageState extends ConsumerState<SidebarPage>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Tapping the status bar scrolls the list the sidebar shows to the top
  /// while the sidebar covers the main pane and nothing covers the sidebar.
  /// The main pane then leaves its own scroll position alone.
  @override
  void handleStatusBarTap() {
    super.handleStatusBarTap();
    if (!mounted || !sidebarCoversMainPane(context)) return;
    // A page pushed over the shell, such as Settings, has the tap instead.
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    final tab = ref.read(appSettingsProvider).slidingSidebarEnabled
        ? ref.read(sidebarSelectedHistoryTabProvider)
        : ref.read(sidebarNavigationSnapshotProvider).selectedTab;
    unawaited(
      ref
          .read(sidebarTabScrollRegistryProvider)
          .scrollToTop(
            tab,
            duration: context.motionDuration(AnimationDuration.slow),
          ),
    );
  }

  AdaptiveBottomNavigationBar _sidebarBottomNavigationBar(
    List<_SidebarNavigationItem> navigationItems,
    ConduitThemeExtension conduitTheme,
    int selectedIndex,
    ValueChanged<int> onTap, {
    required bool useFullWidthRenderer,
  }) {
    return AdaptiveBottomNavigationBar(
      items: [for (final item in navigationItems) item.destination],
      selectedIndex: selectedIndex,
      onTap: onTap,
      renderer: useFullWidthRenderer
          ? AdaptiveBottomNavigationRenderer.fullWidth
          : AdaptiveBottomNavigationRenderer.nativeOverlay,
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
    List<SidebarTabDescriptor> tabs,
    AppLocalizations localizations, {
    required bool useNativeOverlay,
  }) {
    return <_SidebarNavigationItem>[
      for (final descriptor in tabs)
        _SidebarNavigationItem(
          label: descriptor.label(localizations),
          destination: AdaptiveNavigationDestination(
            icon: switch (useNativeOverlay
                ? descriptor.nativeAssetName
                : descriptor.assetName) {
              final assetName? => AdaptiveNavigationIcon.asset(
                assetName,
                size: useNativeOverlay
                    ? descriptor.nativeAssetIconSize ?? 24.0
                    : 24.0,
              ),
              null => AdaptiveNavigationIcon.symbol(descriptor.sfSymbol),
            },
            selectedIcon: switch (useNativeOverlay
                ? descriptor.nativeAssetName
                : descriptor.assetName) {
              final assetName? => AdaptiveNavigationIcon.asset(
                assetName,
                size: useNativeOverlay
                    ? descriptor.nativeAssetIconSize ?? 24.0
                    : 24.0,
              ),
              null => AdaptiveNavigationIcon.symbol(
                descriptor.selectedSfSymbol,
              ),
            },
            label: descriptor.label(localizations),
          ),
          descriptor: descriptor,
        ),
    ];
  }

  Widget _sidebarAppBarLeading({
    required AppLocalizations localizations,
    required bool isSearchExpanded,
    required double toolbarWidth,
    double leadingInset = 0,
  }) {
    final availableLeadingWidth = (toolbarWidth - leadingInset)
        .clamp(0.0, toolbarWidth)
        .toDouble();
    return isSearchExpanded
        ? SidebarSearchAppBarLeading(
            hintText: sidebarTabDescriptor(
              ref.watch(sidebarNavigationSnapshotProvider).selectedTab,
            ).searchHint(localizations),
            maxWidth: availableLeadingWidth - _kSidebarSearchFieldReserve,
          )
        : const SidebarProfileAppBarLeading();
  }

  bool _isWindowed(BuildContext context) {
    final displaySize = View.of(context).display.size;
    final logicalSize = MediaQuery.sizeOf(context);
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    final viewportSize = Size(
      logicalSize.width * devicePixelRatio,
      logicalSize.height * devicePixelRatio,
    );

    return (displaySize.longestSide != viewportSize.longestSide) ||
        (displaySize.shortestSide != viewportSize.shortestSide);
  }

  List<AdaptiveAppBarAction> _sidebarAppBarActions({
    required BuildContext context,
    required AppLocalizations localizations,
    required bool isSearchExpanded,
    required SidebarTabDescriptor activeTab,
  }) {
    final defaultTint = context.conduitTheme.textPrimary;
    if (isSearchExpanded) {
      return [
        AdaptiveAppBarAction(
          iosSymbol: 'xmark',
          icon: UiUtils.closeIcon,
          semanticLabel: localizations.closeButtonSemantic,
          tintColor: defaultTint,
          onPressed: () => closeSidebarSearch(ref),
        ),
      ];
    }

    final contextualActions = activeTab.behavior.contextualActions(
      context,
      defaultTint,
    );

    final createAction = activeTab.createAction;
    return [
      AdaptiveAppBarAction(
        iosSymbol: 'magnifyingglass',
        icon: Icons.search,
        semanticLabel: MaterialLocalizations.of(context).searchFieldLabel,
        tintColor: defaultTint,
        onPressed: () => openSidebarSearch(ref),
      ),
      ...contextualActions,
      if (createAction != null)
        AdaptiveAppBarAction(
          iosSymbol: createAction.sfSymbol,
          icon: createAction.icon,
          semanticLabel: createAction.label(localizations),
          tintColor: defaultTint,
          onPressed: () => createAction.run(context, ref),
        ),
    ];
  }

  PreferredSizeWidget _sidebarMaterialAppBar({
    required BuildContext context,
    required Widget leading,
    required List<AdaptiveAppBarAction> actions,
    required bool isSearchExpanded,
    required double toolbarWidth,
    Widget? middle,
  }) {
    final backgroundColor = context.conduitTheme.surfaceBackground;
    return AppBar(
      backgroundColor: backgroundColor,
      elevation: Elevation.none,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      toolbarHeight: kTextTabBarHeight,
      title: middle,
      centerTitle: true,
      leadingWidth: isSearchExpanded
          ? (toolbarWidth - _kSidebarSearchCloseActionReserve)
                .clamp(0.0, toolbarWidth)
                .toDouble()
          : 60,
      leading: Padding(
        padding: const EdgeInsets.only(left: Spacing.inputPadding),
        child: Align(alignment: Alignment.centerLeft, child: leading),
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
                semanticLabel: actions[index].semanticLabel,
                onPressed: actions[index].onPressed,
                iconColor: context.conduitTheme.textPrimary,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildSidebarBodyWithBottomFade(
    Widget sidebarBody, {
    required bool hasBottomNavigationBar,
  }) {
    if (Platform.isAndroid || !hasBottomNavigationBar) {
      return sidebarBody;
    }

    return Stack(
      children: [
        Positioned.fill(child: sidebarBody),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: ConduitChromeGradientFade.bottom(
            contentHeight:
                MediaQuery.viewPaddingOf(context).bottom +
                sidebarNativeBottomBarContentHeight,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(appSettingsProvider.select((s) => s.slidingSidebarEnabled))) {
      return const _SlidingSidebarPage();
    }
    final localizations = AppLocalizations.of(context)!;
    final navigation = ref.watch(sidebarNavigationSnapshotProvider);
    final tabs = [
      for (final tabId in navigation.tabs) sidebarTabDescriptor(tabId),
    ];
    final hasMultipleTabs = tabs.length > 1;
    final persistentTabletSidebar = PersistentTabletSidebarScope.isActive(
      context,
    );
    final hasBottomNavigationBar = hasMultipleTabs;
    final activeIndex = navigation.selectedIndex;
    final navigationItems = _sidebarNavigationItems(
      tabs,
      localizations,
      useNativeOverlay: !persistentTabletSidebar,
    );

    final conduitTheme = context.conduitTheme;
    final isSearchExpanded = ref.watch(sidebarHeaderSearchExpandedProvider);
    final useNativeIos26Chrome = PlatformInfo.isIOS26OrHigher();
    final composeNativeIos26Chrome = DrawerChromeCompositionScope.shouldCompose(
      context,
    );
    final activeTab = sidebarTabDescriptor(navigation.selectedTab);
    final appBarActions = _sidebarAppBarActions(
      context: context,
      localizations: localizations,
      isSearchExpanded: isSearchExpanded,
      activeTab: activeTab,
    );
    // Hermes names its connection at the centre when there is another to
    // switch to; an open search field takes the whole bar.
    final appBarMiddle =
        activeTab.id == SidebarTabId.hermes && !isSearchExpanded
        ? const HermesConnectionHeaderSwitcher()
        : null;

    void onTap(int index) {
      ConduitHaptics.selectionClick();
      selectSidebarTab(context, ref, index);
    }

    final sidebarTabStack = _SidebarTabStack(
      tabs: tabs,
      activeIndex: activeIndex,
      showBottomNavigation: hasBottomNavigationBar,
    );

    Widget withSyncProgress(Widget child) => Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(child: child),
        Positioned(
          top: Spacing.xs,
          left: Spacing.md,
          right: Spacing.md,
          child: Consumer(
            builder: (context, ref, _) =>
                _SidebarSyncProgressBar(status: ref.watch(syncEngineProvider)),
          ),
        ),
      ],
    );

    return KeyedSubtree(
      key: const ValueKey<String>('sidebar-page-surface'),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final toolbarWidth = constraints.hasBoundedWidth
              ? constraints.maxWidth
              : MediaQuery.sizeOf(context).width;
          final windowedLeadingInset = resolveSidebarWindowedLeadingInset(
            usesNativeIOS26Chrome: useNativeIos26Chrome,
            isWindowed: _isWindowed(context),
            isIOSAppOnMac: PlatformInfo.isIOSAppOnMac,
          );
          final appBarLeading = _sidebarAppBarLeading(
            localizations: localizations,
            isSearchExpanded: isSearchExpanded,
            toolbarWidth: toolbarWidth,
            leadingInset: windowedLeadingInset,
          );
          final adaptiveAppBarLeading = useNativeIos26Chrome
              ? Padding(
                  padding: EdgeInsets.only(left: windowedLeadingInset),
                  child: appBarLeading,
                )
              : appBarLeading;

          final bottomNavigationBar = hasBottomNavigationBar
              ? _sidebarBottomNavigationBar(
                  navigationItems,
                  conduitTheme,
                  activeIndex,
                  onTap,
                  useFullWidthRenderer: persistentTabletSidebar,
                )
              : null;
          final tabContent = withSyncProgress(
            _buildSidebarBodyWithBottomFade(
              sidebarTabStack,
              hasBottomNavigationBar: hasBottomNavigationBar,
            ),
          );
          final sidebarBody = SidebarTabLayoutScope(
            parentOwnsHeaderInset: false,
            bottomNavigationVisible: hasBottomNavigationBar,
            child: tabContent,
          );

          if (useNativeIos26Chrome) {
            return SidebarIos26Scaffold(
              bottomNavigationBar: bottomNavigationBar,
              leading: adaptiveAppBarLeading,
              middle: appBarMiddle,
              actions: appBarActions,
              showNativeView: composeNativeIos26Chrome,
              body: sidebarBody,
            );
          }

          return AdaptiveScaffold(
            appBar: AdaptiveAppBar(
              useNativeToolbar: true,
              leading: adaptiveAppBarLeading,
              titleWidget: appBarMiddle,
              actions: appBarActions,
              appBar: _sidebarMaterialAppBar(
                context: context,
                leading: appBarLeading,
                actions: appBarActions,
                isSearchExpanded: isSearchExpanded,
                toolbarWidth: toolbarWidth,
                middle: appBarMiddle,
              ),
            ),
            bottomNavigationBar: bottomNavigationBar,
            body: sidebarBody,
          );
        },
      ),
    );
  }
}

void _selectSlidingSidebarTab(BuildContext context, WidgetRef ref, int index) {
  final navigation = ref.read(sidebarNavigationSnapshotProvider);
  if (index < 0 || index >= navigation.tabs.length) return;
  final selected = sidebarTabDescriptor(navigation.tabs[index]);
  final current = sidebarTabForLocation(NavigationService.currentRoute ?? '');
  if (current != selected.id) {
    sidebarTabDescriptor(current).behavior.onDeselected(ref);
    selected.behavior.onSelected(ref);
  }
  ref.read(sidebarActiveTabProvider.notifier).set(selected.id);
  closeSidebarSearch(ref);
  NavigationService.router.go(selected.location);
  closeSidebarDrawerIfOverlay(context);
}

/// Width of each backend in the sliding sidebar's bottom tab bar.
const double _kSlidingSidebarBackendWidth = 72;

/// Least gap below the sliding sidebar's bottom bar: the chat composer's, so
/// the bar lines up with the composer beside it.
const double _kSlidingSidebarBarMinimumBottomInset = Spacing.sm;

/// Opt-in navigation with main-pane destinations and separate backend
/// histories, under a floating header and bottom bar.
class _SlidingSidebarPage extends ConsumerWidget {
  const _SlidingSidebarPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = context.conduitTheme;
    final navigation = ref.watch(sidebarNavigationSnapshotProvider);
    final historyTabs = [
      for (final id in navigation.tabs)
        if (id == SidebarTabId.chats || id == SidebarTabId.hermes)
          sidebarTabDescriptor(id),
    ];
    final historyTab = ref.watch(sidebarSelectedHistoryTabProvider);
    final chatTab = historyTabs.firstWhere((tab) => tab.id == historyTab);
    final isSearching = ref.watch(sidebarHeaderSearchExpandedProvider);
    final composeChrome = DrawerChromeCompositionScope.shouldCompose(context);
    final display = View.of(context).display.size;
    final viewport =
        MediaQuery.sizeOf(context) * MediaQuery.devicePixelRatioOf(context);
    final leadingInset = resolveSidebarWindowedLeadingInset(
      usesNativeIOS26Chrome: PlatformInfo.isIOS26OrHigher(),
      isWindowed:
          display.longestSide != viewport.longestSide ||
          display.shortestSide != viewport.shortestSide,
      isIOSAppOnMac: PlatformInfo.isIOSAppOnMac,
    );
    // The tabbed sidebar's surface, so both layouts follow the theme alike.
    final surface = theme.surfaceBackground;
    final safePadding = MediaQuery.paddingOf(context);
    final controlExtent = conduitScaledControlExtent(context);
    final toolbarHeight = conduitAdaptiveToolbarHeightOf(context);
    final chromeInsets = EdgeInsets.only(
      top: safePadding.top + toolbarHeight,
      bottom: AdaptiveFloatingTabBar.extentOf(
        context,
        controlExtent: controlExtent,
        minimumBottomInset: _kSlidingSidebarBarMinimumBottomInset,
      ),
    );
    final history = KeyedSubtree(
      key: const ValueKey<String>('sidebar-chat-history'),
      child: IndexedStack(
        index: historyTabs.indexOf(chatTab),
        children: [
          for (final tab in historyTabs)
            tab.id == SidebarTabId.chats
                // Notes, Terminal and Channels are Open WebUI features, so
                // they lead only its history.
                ? const SidebarHistoryHeaderScope(
                    header: _SlidingSidebarDestinations(),
                    child: ChatsDrawer(),
                  )
                : const HermesSessionsTab(showBottomNavigationBar: false),
        ],
      ),
    );

    return Material(
      key: const ValueKey<String>('sidebar-page-surface'),
      color: surface,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Stack(
          fit: StackFit.expand,
          children: [
            SidebarTabLayoutScope(
              parentOwnsHeaderInset: false,
              bottomNavigationVisible: true,
              floatingChromeInsets: chromeInsets,
              child: history,
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: ConduitChromeGradientFade.top(
                contentHeight: chromeInsets.top,
                backgroundColor: surface,
              ),
            ),
            Positioned(
              top: chromeInsets.top,
              left: Spacing.md,
              right: Spacing.md,
              child: Consumer(
                builder: (context, ref, _) => _SidebarSyncProgressBar(
                  status: ref.watch(syncEngineProvider),
                ),
              ),
            ),
            Positioned(
              top: safePadding.top,
              left: 0,
              right: 0,
              height: toolbarHeight,
              child: Padding(
                padding: EdgeInsetsDirectional.only(
                  start: Spacing.inputPadding + leadingInset,
                  end: Spacing.inputPadding,
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) => Stack(
                    fit: StackFit.expand,
                    children: [
                      _slidingSidebarToolbarRow(
                        context: context,
                        ref: ref,
                        constraints: constraints,
                        isSearching: isSearching,
                        composeChrome: composeChrome,
                        chatTab: chatTab,
                        controlExtent: controlExtent,
                      ),
                      // Hermes names its connection at the centre when there
                      // is another to switch to.
                      if (chatTab.id == SidebarTabId.hermes &&
                          composeChrome &&
                          !isSearching)
                        Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: controlExtent + Spacing.sm,
                          ),
                          child: const Center(
                            child: HermesConnectionHeaderSwitcher(),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: ConduitChromeGradientFade.bottom(
                contentHeight: chromeInsets.bottom,
                backgroundColor: surface,
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: composeChrome
                  ? ThemedSheets.hideNativeChromeWhileCovered(
                      replacement: SizedBox(height: chromeInsets.bottom),
                      child: _SlidingSidebarBottomBar(
                        tabs: historyTabs,
                        selectedTab: chatTab.id,
                        onSelected: (tab) {
                          closeSidebarSearch(ref);
                          ref
                              .read(sidebarHistoryTabProvider.notifier)
                              .select(tab);
                        },
                        createAction: chatTab.createAction!,
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  /// The sliding sidebar's bar: the profile (or the search field) at the
  /// start, the search button at the end.
  Widget _slidingSidebarToolbarRow({
    required BuildContext context,
    required WidgetRef ref,
    required BoxConstraints constraints,
    required bool isSearching,
    required bool composeChrome,
    required SidebarTabDescriptor chatTab,
    required double controlExtent,
  }) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    return Row(
      children: [
        Expanded(
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: isSearching
                ? SidebarSearchAppBarLeading(
                    hintText: l10n.searchConversations,
                    maxWidth: constraints.maxWidth - controlExtent - Spacing.sm,
                  )
                : composeChrome
                ? const SidebarProfileAppBarLeading()
                : SizedBox.square(dimension: controlExtent),
          ),
        ),
        const SizedBox(width: Spacing.sm),
        // Search filters the Open WebUI history only.
        if (chatTab.id == SidebarTabId.hermes)
          const SizedBox.shrink()
        else if (composeChrome)
          ConduitAdaptiveAppBarIconButton(
            key: const ValueKey<String>('sidebar-search-button'),
            icon: isSearching ? UiUtils.closeIcon : Icons.search,
            iosSymbol: isSearching ? 'xmark' : 'magnifyingglass',
            semanticLabel: isSearching ? l10n.close : l10n.searchConversations,
            onPressed: () =>
                isSearching ? closeSidebarSearch(ref) : openSidebarSearch(ref),
            iconColor: theme.textPrimary,
          )
        else
          SizedBox.square(dimension: controlExtent),
      ],
    );
  }
}

/// Notes, Terminal and Channels, scrolling at the top of the history the
/// main pane's chats already come from.
class _SlidingSidebarDestinations extends ConsumerWidget {
  const _SlidingSidebarDestinations();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final navigation = ref.watch(sidebarNavigationSnapshotProvider);
    final destinations = [
      for (final id in navigation.tabs)
        if (id != SidebarTabId.hermes && id != SidebarTabId.chats)
          sidebarTabDescriptor(id),
    ];
    if (destinations.isEmpty) return const SizedBox.shrink();
    final selectedTab = sidebarTabForLocation(
      GoRouterState.of(context).uri.path,
    );

    // The sidebar's own rows: a symbol in the leading column, as folder
    // and channel rows have, and the same highlight when one is open. The
    // sections below set themselves apart with their headers.
    return Column(
      key: const ValueKey<String>('sidebar-destinations'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final destination in destinations)
          ChatStyleSidebarTile(
            key: ValueKey<String>('sidebar-destination-${destination.id.name}'),
            selected: destination.id == selectedTab,
            onTap: () {
              ConduitHaptics.selectionClick();
              _selectSlidingSidebarTab(
                context,
                ref,
                navigation.tabs.indexOf(destination.id),
              );
            },
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: kConversationTileMinHeight,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: kSidebarRowHorizontalPadding,
                  vertical: Spacing.sm,
                ),
                child: Row(
                  children: [
                    // The symbol starts where chat titles do, and the name
                    // follows it.
                    _SidebarDestinationGlyph(
                      destination: destination,
                      color: theme.textPrimary,
                    ),
                    const SizedBox(width: _SidebarDestinationGlyph.gap),
                    Expanded(
                      child: Text(
                        destination.label(l10n),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: sidebarRowTitleLineStyle().copyWith(
                          color: theme.textPrimary,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// A destination's symbol: the SF Symbol its tab shows on iOS, else its
/// icon, at a row symbol's full size and in the label colour, its ink
/// starting on the row's leading edge.
class _SidebarDestinationGlyph extends StatelessWidget {
  const _SidebarDestinationGlyph({
    required this.destination,
    required this.color,
  });

  final SidebarTabDescriptor destination;
  final Color color;

  /// The symbol's size: a list row's, a little over the 17 pt title.
  static const double symbolSize = 20;

  /// The column every symbol takes, so the names after them share an edge.
  static const double extent = 24;

  /// Between the symbol's column and the name.
  static const double gap = 12;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final glyph = NativeSymbolGlyph.isAvailable
        ? NativeSymbolGlyph(
            symbol: destination.sfSymbol,
            fallbackIcon: destination.materialIcon,
            pointSize: scaler.scale(symbolSize),
            color: color,
          )
        : destination.assetName != null
        ? ImageIcon(
            AssetImage(destination.assetName!),
            size: scaler.scale(extent),
            color: color,
          )
        : Icon(
            destination.materialIcon,
            size: scaler.scale(extent),
            color: color,
          );
    return SizedBox(
      width: scaler.scale(extent),
      child: Align(alignment: AlignmentDirectional.centerStart, child: glyph),
    );
  }
}

/// Backend icons at the leading edge and New Chat at the trailing edge.
class _SlidingSidebarBottomBar extends ConsumerWidget {
  const _SlidingSidebarBottomBar({
    required this.tabs,
    required this.selectedTab,
    required this.onSelected,
    required this.createAction,
  });

  final List<SidebarTabDescriptor> tabs;
  final SidebarTabId selectedTab;
  final ValueChanged<SidebarTabId> onSelected;
  final SidebarCreateAction createAction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final selectedIndex = tabs.indexWhere((tab) => tab.id == selectedTab);
    return AdaptiveFloatingTabBar(
      key: const ValueKey<String>('sidebar-backend-selector'),
      tabsKey: const ValueKey<String>('sidebar-backend-tabs'),
      actionKey: const ValueKey<String>('sidebar-create-button'),
      tabs: [
        if (tabs.length > 1)
          for (final tab in tabs)
            tab.id == SidebarTabId.chats
                ? const AdaptiveFloatingTab(
                    label: 'Open WebUI',
                    icon: _SidebarAssetTabImage(
                      _kOpenWebUiTabIcon,
                      size: _kOpenWebUiTabIconSize,
                    ),
                    nativeAsset: _kOpenWebUiTabIcon,
                  )
                : AdaptiveFloatingTab(
                    label: tab.label(l10n),
                    icon: _SidebarAssetTabImage(
                      tab.assetName!,
                      size: tab.assetIconSize ?? IconSize.tabBar,
                    ),
                    nativeAsset: tab.assetName!,
                  ),
      ],
      selectedIndex: selectedIndex,
      onTap: (index) {
        if (index == selectedIndex) return;
        ConduitHaptics.selectionClick();
        onSelected(tabs[index].id);
      },
      action: AdaptiveFloatingBarAction(
        label: createAction.label(l10n),
        icon: createAction.icon,
        sfSymbol: createAction.sfSymbol,
        onPressed: () => unawaited(createAction.run(context, ref)),
      ),
      itemWidth: _kSlidingSidebarBackendWidth,
      selectedItemColor: theme.buttonPrimary,
      unselectedItemColor: theme.textSecondary,
      actionForegroundColor: PlatformUiCapabilities.isIOS
          ? theme.textPrimary
          : theme.buttonPrimaryText,
      actionBackgroundColor: theme.buttonPrimary,
      backgroundColor: theme.surfaceBackground,
      borderColor: theme.cardBorder,
      // As the header's search button, so the two bars match.
      controlExtent: conduitScaledControlExtent(context),
      edgeInset: Spacing.inputPadding,
      minimumBottomInset: _kSlidingSidebarBarMinimumBottomInset,
      actionSymbolSize: kConduitNativeSingleActionSymbolExtent,
    );
  }
}

/// Single-colour Open WebUI mark whose letters are cut out, so it reads when
/// tinted as a template.
const String _kOpenWebUiTabIcon = 'assets/icons/open_webui_tab.png';
const double _kOpenWebUiTabIconSize = 22;
