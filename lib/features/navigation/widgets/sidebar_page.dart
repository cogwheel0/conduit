import 'dart:async';
import 'dart:io' show Platform;

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/sync/sync_engine.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/adaptive_toolbar_components.dart';
import '../../../shared/widgets/chrome_gradient_fade.dart';
import '../../../shared/widgets/responsive_drawer_layout.dart';
import '../../../shared/widgets/sidebar_ios26_scaffold.dart';
import '../providers/sidebar_providers.dart';
import '../utils/sidebar_create_action.dart';
import '../../channels/widgets/channel_list_tab.dart';
import '../../hermes/providers/hermes_providers.dart';
import '../../hermes/widgets/hermes_sessions_tab.dart';
import '../../notes/widgets/notes_list_tab.dart';
import '../../terminal/models/terminal_models.dart';
import '../../terminal/providers/terminal_providers.dart';
import '../../terminal/widgets/terminal_sidebar_controls_sheet.dart';
import '../../terminal/widgets/terminal_tab.dart';
import 'chats_drawer.dart';
import 'sidebar_user_pill.dart';

/// Compact bottom bar height on Material (default M3 bar is ~80 logical px).
const double _kSidebarNavigationBarHeight = 56;
const double _kSidebarNavigationBarIconSize = 22;
const double _kSidebarSearchCloseActionReserve = 64;
const double _kSidebarSearchFieldReserve = 96;
const double _kSidebarNativeLeadingVerticalOffset = 3;
// Mirrors adaptive_platform_ui's iPadOS window-control reservation.
const double _kSidebarWindowedLeadingInset = 62;
const double _kSidebarNativeBottomBarContentHeight = 50;

enum _SidebarTabId { chats, hermes, terminal, notes, channels }

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

IconData _materialTabIcon(_SidebarTabId id, {bool selected = false}) {
  switch (id) {
    case _SidebarTabId.chats:
      return selected ? Icons.chat_bubble : Icons.chat_bubble_outline;
    case _SidebarTabId.hermes:
      return selected ? Icons.smart_toy : Icons.smart_toy_outlined;
    case _SidebarTabId.notes:
      return selected ? Icons.note : Icons.note_outlined;
    case _SidebarTabId.terminal:
      return selected ? Icons.terminal : Icons.terminal_rounded;
    case _SidebarTabId.channels:
      return Icons.tag;
  }
}

/// The real Hermes Agent logo (bundled from the official 48×48 icon), used for
/// the Hermes tab instead of a generic glyph.
const AssetImage kHermesTabIcon = AssetImage('assets/icons/hermes_agent.png');

/// Tab-bar rendering of the Hermes logo as a theme-aware alpha mask.
///
/// The bundled asset is black with transparency, so a raw [Image] would stay
/// black in dark mode instead of inheriting the navigation icon color.
class _HermesTabImage extends StatelessWidget {
  const _HermesTabImage();

  @override
  Widget build(BuildContext context) {
    return const ImageIcon(
      kHermesTabIcon,
      size: _kSidebarNavigationBarIconSize,
    );
  }
}

String _sfSymbolTabIcon(_SidebarTabId id, {bool selected = false}) {
  switch (id) {
    case _SidebarTabId.chats:
      return selected ? 'bubble.left.fill' : 'bubble.left';
    case _SidebarTabId.hermes:
      return 'sparkles';
    case _SidebarTabId.notes:
      return selected ? 'doc.text.fill' : 'doc.text';
    case _SidebarTabId.terminal:
      return 'terminal';
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
                icon: item.tabDefinition.id == _SidebarTabId.hermes
                    ? const _HermesTabImage()
                    : Icon(_materialTabIcon(item.tabDefinition.id)),
                selectedIcon: item.tabDefinition.id == _SidebarTabId.hermes
                    ? const _HermesTabImage()
                    : Icon(
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

/// Full-page tabbed sidebar with Chats, Notes (optional), Terminal, and
/// Channels (optional) tabs.
///
/// Replaces the single-purpose [ChatsDrawer] as the drawer content
/// in [ResponsiveDrawerLayout]. Tab selection is persisted via
/// [sidebarActiveTabProvider].
///
/// Notes, Terminal, and Channels tabs are each independently optional. When a
/// feature or its backing terminal servers are unavailable, the corresponding
/// tab is hidden and the persisted index is clamped to the visible tab range.
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
            // ImageIcon keeps the alpha-mask asset tintable on Cupertino and
            // is also recognized by the native iOS tab-bar asset extractor.
            // Let Cupertino supply size so selected/unselected icons match.
            icon: def.id == _SidebarTabId.hermes
                ? const ImageIcon(kHermesTabIcon)
                : _sfSymbolTabIcon(def.id),
            selectedIcon: def.id == _SidebarTabId.hermes
                ? const ImageIcon(kHermesTabIcon)
                : _sfSymbolTabIcon(def.id, selected: true),
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
    required bool showTerminalPanelPicker,
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

    final panelPicker = showTerminalPanelPicker
        ? <AdaptiveAppBarAction>[
            AdaptiveAppBarAction(
              iosSymbol: 'chevron.down.circle',
              icon: Icons.arrow_drop_down_circle_outlined,
              tintColor: defaultTint,
              onPressed: () {
                unawaited(showTerminalSidebarControlsSheet(context));
              },
            ),
          ]
        : const <AdaptiveAppBarAction>[];

    final createAction = sidebarCreateActionForActiveTab(ref);
    return [
      AdaptiveAppBarAction(
        iosSymbol: 'magnifyingglass',
        icon: Icons.search,
        tintColor: defaultTint,
        onPressed: _openSidebarSearch,
      ),
      ...panelPicker,
      if (createAction != null)
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
                _kSidebarNativeBottomBarContentHeight,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;
    // Hermes-only mode hides every OpenWebUI surface; the Hermes tab is home.
    final hermesOnly = ref.watch(hermesOnlyModeProvider);
    final hasOpenWebUi = ref.watch(apiServiceProvider) != null;
    final hermesEnabled = ref.watch(hermesEnabledProvider);
    final notesEnabled =
        hasOpenWebUi && !hermesOnly && ref.watch(notesFeatureEnabledProvider);
    final channelsEnabled =
        hasOpenWebUi &&
        !hermesOnly &&
        ref.watch(channelsFeatureEnabledProvider);
    // Live when the server list resolves; cached last-known value when offline
    // (so a terminal-disabled server doesn't surface the tab offline).
    final showTerminalTab =
        hasOpenWebUi && !hermesOnly && ref.watch(terminalTabVisibleProvider);
    final visibleTabIds = <_SidebarTabId>[
      if (!hermesOnly) _SidebarTabId.chats,
      if (hermesOnly || hermesEnabled) _SidebarTabId.hermes,
      if (notesEnabled) _SidebarTabId.notes,
      if (showTerminalTab) _SidebarTabId.terminal,
      if (channelsEnabled) _SidebarTabId.channels,
    ];
    final hasBottomNavigationBar = visibleTabIds.length > 1;
    final persistedIndex = ref.watch(sidebarActiveTabProvider);
    final activeIndex = _clampIndex(persistedIndex, visibleTabIds.length);
    if (activeIndex != persistedIndex) {
      _schedulePersistedIndexSync(activeIndex);
    }
    final isTerminalTabSelected =
        visibleTabIds[activeIndex] == _SidebarTabId.terminal;
    final tabDefinitions = <_SidebarTabDefinition>[
      if (!hermesOnly)
        _SidebarTabDefinition(
          id: _SidebarTabId.chats,
          label: localizations.sidebarChatsTab,
          body: const ChatsDrawer(),
        ),
      if (hermesOnly || hermesEnabled)
        _SidebarTabDefinition(
          id: _SidebarTabId.hermes,
          label: 'Hermes',
          body: HermesSessionsTab(
            showBottomNavigationBar: hasBottomNavigationBar,
          ),
        ),
      if (notesEnabled)
        _SidebarTabDefinition(
          id: _SidebarTabId.notes,
          label: localizations.sidebarNotesTab,
          body: const NotesListTab(),
        ),
      if (showTerminalTab)
        _SidebarTabDefinition(
          id: _SidebarTabId.terminal,
          label: localizations.sidebarTerminalTab,
          body: TerminalTab(isActive: isTerminalTabSelected),
        ),
      if (channelsEnabled)
        _SidebarTabDefinition(
          id: _SidebarTabId.channels,
          label: localizations.sidebarChannelsTab,
          body: const ChannelListTab(),
        ),
    ];
    final navigationItems = _sidebarNavigationItems(tabDefinitions);

    final conduitTheme = context.conduitTheme;
    final isSearchExpanded = ref.watch(sidebarHeaderSearchExpandedProvider);
    final useNativeIos26Chrome = PlatformInfo.isIOS26OrHigher();
    final composeNativeIos26Chrome = DrawerChromeCompositionScope.shouldCompose(
      context,
    );
    final isTerminalTabActive =
        tabDefinitions[activeIndex].id == _SidebarTabId.terminal;
    final showTerminalPanelInAppBar = isTerminalTabActive && !isSearchExpanded;
    final appBarActions = _sidebarAppBarActions(
      context: context,
      localizations: localizations,
      isSearchExpanded: isSearchExpanded,
      showTerminalPanelPicker: showTerminalPanelInAppBar,
    );

    void onTap(int index) {
      ref.read(sidebarActiveTabProvider.notifier).set(index);
      if (tabDefinitions[index].id != _SidebarTabId.terminal) {
        ref
            .read(terminalSidebarPanelProvider.notifier)
            .setPanel(TerminalSidebarPanel.console);
      } else {
        final servers = ref
            .read(terminalAvailableServersProvider)
            .asData
            ?.value;
        if (servers != null && servers.length == 1) {
          ref
              .read(terminalSidebarPanelProvider.notifier)
              .setPanel(TerminalSidebarPanel.files);
        }
      }
    }

    final sidebarBody = _SidebarTabStack(
      tabDefinitions: tabDefinitions,
      activeIndex: activeIndex,
    );
    final sidebarBodyWithBottomFade = _buildSidebarBodyWithBottomFade(
      sidebarBody,
      hasBottomNavigationBar: hasBottomNavigationBar,
    );
    final sidebarBodyWithSyncProgress = Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(child: sidebarBodyWithBottomFade),
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
                  child: Transform.translate(
                    offset: const Offset(
                      0,
                      _kSidebarNativeLeadingVerticalOffset,
                    ),
                    child: appBarLeading,
                  ),
                )
              : appBarLeading;

          final bottomNavigationBar = hasBottomNavigationBar
              ? _sidebarBottomNavigationBar(
                  navigationItems,
                  conduitTheme,
                  activeIndex,
                  onTap,
                )
              : null;

          if (useNativeIos26Chrome) {
            return SidebarIos26Scaffold(
              bottomNavigationBar: bottomNavigationBar,
              leading: adaptiveAppBarLeading,
              actions: appBarActions,
              minimizeBehavior: TabBarMinimizeBehavior.never,
              showNativeView: composeNativeIos26Chrome,
              body: sidebarBodyWithSyncProgress,
            );
          }

          return AdaptiveScaffold(
            minimizeBehavior: TabBarMinimizeBehavior.never,
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
            body: sidebarBodyWithSyncProgress,
          );
        },
      ),
    );
  }
}
