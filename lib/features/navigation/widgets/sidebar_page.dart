import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:conduit_core/sync/sync_engine.dart';

import '../../../core/services/haptic_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/adaptive_toolbar_components.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/sidebar_layout_contract.dart';
import '../providers/sidebar_providers.dart';
import '../providers/sidebar_tab_scroll_registry.dart';
import 'sidebar_user_pill.dart';
import 'sidebar_tab_registry.dart';

// Reserve space for iPad window controls when the app is windowed.
@visibleForTesting
double resolveSidebarWindowedLeadingInset({
  required bool usesNativeIOS26Chrome,
  required bool isWindowed,
  required bool isIOSAppOnMac,
}) => usesNativeIOS26Chrome && isWindowed && !isIOSAppOnMac ? 62 : 0;

void selectSidebarTab(BuildContext context, WidgetRef ref, int index) {
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

/// Shared navigation pane. Destinations stay above their retained lists while
/// settings remain reachable at the bottom, independent of list scroll position.
class SidebarPage extends ConsumerWidget {
  const SidebarPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final navigation = ref.watch(sidebarNavigationSnapshotProvider);
    final tabs = [for (final id in navigation.tabs) sidebarTabDescriptor(id)];
    final activeTab = sidebarTabDescriptor(navigation.selectedTab);
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

    return Material(
      key: const ValueKey<String>('sidebar-page-surface'),
      color: theme.surfaceContainerHighest,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsetsDirectional.fromSTEB(
                Spacing.lg + leadingInset,
                Spacing.sm,
                Spacing.md,
                Spacing.sm,
              ),
              child: LayoutBuilder(
                builder: (context, constraints) => Row(
                  children: [
                    Expanded(
                      child: isSearching
                          ? SidebarSearchAppBarLeading(
                              hintText: sidebarSearchHintForActiveTab(
                                ref,
                                l10n,
                              ),
                              maxWidth:
                                  constraints.maxWidth - TouchTarget.minimum,
                            )
                          : Text(
                              'Conduit',
                              style: TextStyle(
                                color: theme.textPrimary,
                                fontSize: 26,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                    ),
                    if (!composeChrome)
                      const SizedBox.square(dimension: TouchTarget.minimum),
                    if (composeChrome) ...[
                      ConduitAdaptiveAppBarIconButton(
                        key: const ValueKey<String>('sidebar-search-button'),
                        icon: isSearching ? UiUtils.closeIcon : Icons.search,
                        semanticLabel: isSearching
                            ? l10n.close
                            : sidebarSearchHintForActiveTab(ref, l10n),
                        onPressed: () => isSearching
                            ? closeSidebarSearch(ref)
                            : openSidebarSearch(ref),
                        iconColor: theme.textPrimary,
                      ),
                      if (!isSearching) ...[
                        for (final action
                            in activeTab.behavior.contextualActions(
                              context,
                              theme.textPrimary,
                            ))
                          ConduitAdaptiveAppBarIconButton(
                            icon: action.icon ?? Icons.more_horiz,
                            onPressed: action.onPressed,
                            iconColor: theme.textPrimary,
                          ),
                        if (activeTab.createAction case final action?)
                          ConduitAdaptiveAppBarIconButton(
                            key: const ValueKey<String>(
                              'sidebar-create-button',
                            ),
                            icon: action.icon,
                            iosSymbol: action.sfSymbol,
                            onPressed: () => action.run(context, ref),
                            iconColor: theme.textPrimary,
                          ),
                      ],
                    ],
                  ],
                ),
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (tabs.length > 1)
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: constraints.maxHeight * 0.5,
                        ),
                        child: SingleChildScrollView(
                          key: const ValueKey<String>('sidebar-destinations'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: Spacing.sm,
                          ),
                          child: Column(
                            children: [
                              for (var index = 0; index < tabs.length; index++)
                                ListTile(
                                  key: ValueKey<String>(
                                    'sidebar-destination-${tabs[index].id.name}',
                                  ),
                                  minTileHeight: 48,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  selected: index == navigation.selectedIndex,
                                  tileColor: Colors.transparent,
                                  selectedTileColor: theme.textPrimary
                                      .withValues(alpha: 0.08),
                                  selectedColor: theme.textPrimary,
                                  iconColor: theme.textSecondary,
                                  textColor: theme.textPrimary,
                                  leading: tabs[index].assetName != null
                                      ? ImageIcon(
                                          AssetImage(tabs[index].assetName!),
                                          size: tabs[index].assetIconSize ?? 22,
                                        )
                                      : Icon(
                                          tabs[index].materialIcon,
                                          size: 22,
                                        ),
                                  title: Text(tabs[index].label(l10n)),
                                  onTap: () {
                                    ConduitHaptics.selectionClick();
                                    selectSidebarTab(context, ref, index);
                                  },
                                ),
                            ],
                          ),
                        ),
                      ),
                    const Divider(indent: Spacing.md, endIndent: Spacing.md),
                    Expanded(
                      child: SidebarTabLayoutScope(
                        parentOwnsHeaderInset: true,
                        bottomNavigationVisible: false,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            _SidebarTabStack(
                              tabs: tabs,
                              activeIndex: navigation.selectedIndex,
                              showBottomNavigation: false,
                            ),
                            Positioned(
                              top: 0,
                              left: Spacing.md,
                              right: Spacing.md,
                              child: Consumer(
                                builder: (context, ref, _) =>
                                    _SidebarSyncProgressBar(
                                      status: ref.watch(syncEngineProvider),
                                    ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1, indent: Spacing.md, endIndent: Spacing.md),
            const Padding(
              padding: EdgeInsets.all(Spacing.sm),
              child: SidebarProfileAppBarLeading(showLabel: true),
            ),
          ],
        ),
      ),
    );
  }
}
