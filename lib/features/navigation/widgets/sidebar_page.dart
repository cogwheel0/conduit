import 'dart:async';
import 'dart:io' show Platform;

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sync/sync_engine.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/adaptive_toolbar_components.dart';
import '../../../shared/widgets/chrome_gradient_fade.dart';
import '../../../shared/widgets/sidebar_layout_contract.dart';
import '../../../shared/widgets/sidebar_layout_constants.dart';
import '../../../shared/widgets/sidebar_ios26_scaffold.dart';
import '../providers/sidebar_providers.dart';
import '../providers/sidebar_tab_scroll_registry.dart';
import 'sidebar_user_pill.dart';
import 'sidebar_tab_registry.dart';

/// Compact bottom bar height on Material (default M3 bar is ~80 logical px).
const double _kSidebarNavigationBarHeight = 56;
const double _kSidebarSearchCloseActionReserve = 64;
const double _kSidebarSearchFieldReserve = 96;
// Mirrors Conduit platform UI's iPadOS window-control reservation.
const double _kSidebarWindowedLeadingInset = 62;

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
  const _SidebarAssetTabImage(this.assetName);

  final String assetName;

  @override
  Widget build(BuildContext context) {
    return ImageIcon(AssetImage(assetName), size: IconSize.tabBar);
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
                    : _SidebarAssetTabImage(item.descriptor.assetName!),
                selectedIcon: item.descriptor.assetName == null
                    ? Icon(item.descriptor.selectedMaterialIcon)
                    : _SidebarAssetTabImage(item.descriptor.assetName!),
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

class _SidebarPageState extends ConsumerState<SidebarPage> {
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
    AppLocalizations localizations,
  ) {
    return <_SidebarNavigationItem>[
      for (final descriptor in tabs)
        _SidebarNavigationItem(
          label: descriptor.label(localizations),
          destination: AdaptiveNavigationDestination(
            icon: descriptor.assetName == null
                ? AdaptiveNavigationIcon.symbol(descriptor.sfSymbol)
                : AdaptiveNavigationIcon.asset(descriptor.assetName!),
            selectedIcon: descriptor.assetName == null
                ? AdaptiveNavigationIcon.symbol(descriptor.selectedSfSymbol)
                : AdaptiveNavigationIcon.asset(descriptor.assetName!),
            label: descriptor.label(localizations),
          ),
          descriptor: descriptor,
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
    required double toolbarWidth,
    double leadingInset = 0,
  }) {
    final availableLeadingWidth = (toolbarWidth - leadingInset)
        .clamp(0.0, toolbarWidth)
        .toDouble();
    return isSearchExpanded
        ? SidebarSearchAppBarLeading(
            hintText: sidebarSearchHintForActiveTab(ref, localizations),
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
          tintColor: defaultTint,
          onPressed: _closeSidebarSearch,
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
        tintColor: defaultTint,
        onPressed: _openSidebarSearch,
      ),
      ...contextualActions,
      if (createAction != null)
        AdaptiveAppBarAction(
          iosSymbol: createAction.sfSymbol,
          icon: createAction.icon,
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
  }) {
    final backgroundColor = context.conduitTheme.surfaceBackground;
    return AppBar(
      backgroundColor: backgroundColor,
      elevation: Elevation.none,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      toolbarHeight: kTextTabBarHeight,
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
    final activeTabNotifier = ref.read(sidebarActiveTabProvider.notifier);
    final activeIndex = navigation.selectedIndex;
    final navigationItems = _sidebarNavigationItems(tabs, localizations);

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

    void onTap(int index) {
      final selectedTab = tabs[index];
      if (index == activeIndex) {
        if (navigation.isLegacySelection) {
          activeTabNotifier.set(selectedTab.id);
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
      final previousTab = tabs[activeIndex];
      previousTab.behavior.onDeselected(ref);
      ref.read(sidebarActiveTabProvider.notifier).set(selectedTab.id);
      selectedTab.behavior.onSelected(ref);
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
          final windowedLeadingInset =
              useNativeIos26Chrome && _isWindowed(context)
              ? _kSidebarWindowedLeadingInset
              : 0.0;
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
              actions: appBarActions,
              showNativeView: composeNativeIos26Chrome,
              body: sidebarBody,
            );
          }

          return AdaptiveScaffold(
            appBar: AdaptiveAppBar(
              useNativeToolbar: true,
              leading: adaptiveAppBarLeading,
              actions: appBarActions,
              appBar: _sidebarMaterialAppBar(
                context: context,
                leading: appBarLeading,
                actions: appBarActions,
                isSearchExpanded: isSearchExpanded,
                toolbarWidth: toolbarWidth,
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
