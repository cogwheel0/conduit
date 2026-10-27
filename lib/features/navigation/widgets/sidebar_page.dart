import 'dart:async';

import 'package:conduit_core/features/navigation/models/sidebar_navigation_model.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:conduit_core/sync/sync_engine.dart';

import '../../../core/services/haptic_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/adaptive_glass.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/adaptive_toolbar_components.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/sidebar_layout_contract.dart';
import '../providers/sidebar_providers.dart';
import '../utils/sidebar_create_action.dart';
import '../../../shared/services/navigation_service.dart';

import 'package:go_router/go_router.dart';

import 'chats_drawer.dart';
import '../../hermes/widgets/hermes_sessions_tab.dart';
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
  final selected = sidebarTabDescriptor(navigation.tabs[index]);
  final current = sidebarTabForLocation(NavigationService.currentRoute ?? '');
  if (current != selected.id) {
    sidebarTabDescriptor(current).behavior.onDeselected(ref);
    selected.behavior.onSelected(ref);
  }
  ref.read(sidebarActiveTabProvider.notifier).set(selected.id);
  closeSidebarSearch(ref);
  NavigationService.router.go(selected.location);
  SidebarDrawerControllerScope.maybeOf(context)?.close();
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
    final routeTab = sidebarTabForLocation(GoRouterState.of(context).uri.path);
    final chatTab = tabs.firstWhere(
      (tab) => tab.id == SidebarTabId.chats,
      orElse: () => sidebarTabDescriptor(SidebarTabId.hermes),
    );
    final selectedTab = navigation.tabs.contains(routeTab)
        ? routeTab
        : chatTab.id;
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
                              hintText: l10n.searchConversations,
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
                        iosSymbol: isSearching ? 'xmark' : 'magnifyingglass',
                        semanticLabel: isSearching
                            ? l10n.close
                            : l10n.searchConversations,
                        onPressed: () => isSearching
                            ? closeSidebarSearch(ref)
                            : openSidebarSearch(ref),
                        iconColor: theme.textPrimary,
                      ),
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
                    if (tabs.isNotEmpty)
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
                                  selected: tabs[index].id == selectedTab,
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
                            KeyedSubtree(
                              key: const ValueKey<String>(
                                'sidebar-chat-history',
                              ),
                              child: chatTab.id == SidebarTabId.chats
                                  ? const ChatsDrawer()
                                  : const HermesSessionsTab(
                                      showBottomNavigationBar: false,
                                    ),
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
            Padding(
              padding: const EdgeInsets.all(Spacing.md),
              child: composeChrome
                  ? Row(
                      children: [
                        Expanded(
                          child: Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 220),
                              child: _SidebarCreateButton(
                                action: chatTab.createAction!,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: Spacing.sm),
                        const SidebarProfileAppBarLeading(
                          showSettingsIcon: true,
                        ),
                      ],
                    )
                  : SizedBox(height: conduitScaledControlExtent(context)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Uses the native labelled glass control on iOS and an adaptive pill elsewhere.
class _SidebarCreateButton extends ConsumerWidget {
  const _SidebarCreateButton({required this.action});

  final SidebarCreateAction action;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = context.conduitTheme;
    final label = action.label(AppLocalizations.of(context)!);
    final extent = conduitScaledControlExtent(context);
    void create() => unawaited(action.run(context, ref));

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = resolveConduitAdaptiveTextPillWidth(
          context: context,
          label: label,
          textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          maxWidth: constraints.maxWidth,
          minWidth: extent,
          horizontalPadding: Spacing.md * 2,
          leadingWidth: 22 + Spacing.sm,
        );
        return SizedBox(
          width: width,
          key: const ValueKey<String>('sidebar-create-button'),
          height: extent,
          child: conduitSupportsNativeGlass()
              ? CNButton(
                  label: label,
                  icon: CNSymbol(action.sfSymbol, size: 20),
                  onPressed: create,
                  tint: theme.sidebarPrimary,
                  config: CNButtonConfig(
                    minHeight: extent,
                    width: width,
                    style: CNButtonStyle.prominentGlass,
                    imagePadding: Spacing.sm,
                  ),
                )
              : AdaptiveButton.child(
                  onPressed: create,
                  semanticLabel: label,
                  style: AdaptiveButtonStyle.filled,
                  color: theme.sidebarPrimary,
                  borderRadius: BorderRadius.circular(extent / 2),
                  minSize: Size(0, extent),
                  padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        action.icon,
                        size: 22,
                        color: theme.sidebarPrimaryText,
                      ),
                      const SizedBox(width: Spacing.sm),
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: theme.sidebarPrimaryText),
                        ),
                      ),
                    ],
                  ),
                ),
        );
      },
    );
  }
}
