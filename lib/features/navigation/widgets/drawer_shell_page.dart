import 'dart:async';
import 'dart:io' show Platform;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../../core/services/navigation_service.dart';
import '../../../core/services/haptic_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/sidebar_layout_constants.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../chat/providers/chat_providers.dart';
import '../providers/sidebar_providers.dart';
import 'responsive_drawer_layout.dart';
import '../../../shared/widgets/sidebar_layout_contract.dart';
import 'sidebar_page.dart';
import 'sidebar_tab_registry.dart';

/// Shell widget that wraps child routes with a persistent
/// [ResponsiveDrawerLayout] + [SidebarPage] drawer.
///
/// Used inside a [ShellRoute] so the drawer survives navigation
/// between chat, channel, and note-editor pages on tablets.
///
/// This shell intentionally does not own an `AdaptiveRouteShell` because the
/// child routes still need route-specific app bars, native tab bars, and
/// fullscreen overlays.
class DrawerShellPage extends ConsumerWidget {
  final Widget child;

  const DrawerShellPage({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isTablet = usesPersistentTabletSidebar(context);
    final tabletWidth = ref.watch(sidebarTabletWidthProvider);
    final localizations = AppLocalizations.of(context)!;
    final scrim = Platform.isIOS
        ? context.colorTokens.scrimMedium
        : context.colorTokens.scrimStrong;

    return ResponsiveDrawerLayout(
      maxFraction: isTablet ? 0.42 : 1.0,
      edgeFraction: isTablet ? 0.36 : 1.0,
      settleFraction: 0.06,
      scrimColor: scrim,
      pushContent: true,
      contentScaleDelta: 0.0,
      mobileBottomDragGestureExclusion: isTablet
          ? 0.0
          : sidebarBottomBarGestureExclusionHeight(context),
      tabletDrawerWidth: tabletWidth,
      tabletDrawerMinWidth: minimumSidebarTabletWidth,
      tabletDrawerMaxWidth: maximumSidebarTabletWidth,
      tabletMinimumContentWidth: defaultSidebarTabletWidth,
      tabletResizable: isTablet,
      tabletResizeSemanticsLabel: localizations.sidebarResizeHandle,
      tabletResizeSemanticsHint: localizations.sidebarResizeResetHint,
      tabletResizeSemanticsValueBuilder: (width) =>
          localizations.sidebarWidthValue(width.round()),
      onTabletDrawerWidthChanged: (width) {
        ref.read(sidebarTabletWidthProvider.notifier).setWidth(width);
        ConduitHaptics.selectionClick();
      },
      onOpenStart: () {
        // Suppress composer auto-focus when drawer opens on mobile
        try {
          ref.read(composerAutofocusEnabledProvider.notifier).set(false);
        } catch (_) {}
      },
      drawer: const SidebarPage(),
      layoutBuilder: (layout) => MacDesktopShortcuts(child: layout),
      child: child,
    );
  }
}

class MacDesktopShortcuts extends ConsumerWidget {
  const MacDesktopShortcuts({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!PlatformInfo.isIOSAppOnMac) return child;

    void createForActiveTab() {
      final navigation = ref.read(sidebarNavigationSnapshotProvider);
      final action = sidebarTabDescriptor(navigation.selectedTab).createAction;
      if (action != null) unawaited(action.run(context, ref));
    }

    void focusSidebarSearch() {
      final drawer = SidebarDrawerControllerScope.maybeOf(context);
      if (drawer?.isOpen == false) drawer?.open();
      openSidebarSearch(ref);
    }

    void dismissDesktopLayer() {
      if (ref.read(sidebarHeaderSearchExpandedProvider)) {
        closeSidebarSearch(ref);
        return;
      }
      final drawer = SidebarDrawerControllerScope.maybeOf(context);
      if (!usesPersistentTabletSidebar(context) && drawer?.isOpen == true) {
        drawer?.close();
        return;
      }
      FocusManager.instance.primaryFocus?.unfocus();
    }

    void openSettings() {
      final path = Uri.tryParse(NavigationService.currentRoute ?? '')?.path;
      if (path == Routes.profile ||
          path?.startsWith('${Routes.profile}/') == true) {
        return;
      }
      unawaited(NavigationService.pushTo(Routes.profile));
    }

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true):
            createForActiveTab,
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
            focusSidebarSearch,
        const SingleActivator(LogicalKeyboardKey.digit1, meta: true): () =>
            selectSidebarTab(context, ref, 0),
        const SingleActivator(LogicalKeyboardKey.digit2, meta: true): () =>
            selectSidebarTab(context, ref, 1),
        const SingleActivator(LogicalKeyboardKey.digit3, meta: true): () =>
            selectSidebarTab(context, ref, 2),
        const SingleActivator(LogicalKeyboardKey.digit4, meta: true): () =>
            selectSidebarTab(context, ref, 3),
        const SingleActivator(LogicalKeyboardKey.digit5, meta: true): () =>
            selectSidebarTab(context, ref, 4),
        const SingleActivator(LogicalKeyboardKey.comma, meta: true):
            openSettings,
        const SingleActivator(LogicalKeyboardKey.escape): dismissDesktopLayer,
      },
      child: child,
    );
  }
}
