import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/platform_service.dart';
import '../../../core/services/settings_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/sidebar_layout_constants.dart';
import '../../chat/providers/chat_providers.dart';
import '../providers/sidebar_providers.dart';
import 'responsive_drawer_layout.dart';
import '../../../shared/widgets/sidebar_layout_contract.dart';
import 'sidebar_page.dart';

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
        PlatformService.hapticFeedbackWithSettings(
          type: HapticType.selection,
          hapticEnabled: ref.read(hapticEnabledProvider),
        );
      },
      onOpenStart: () {
        // Suppress composer auto-focus when drawer opens on mobile
        try {
          ref.read(composerAutofocusEnabledProvider.notifier).set(false);
        } catch (_) {}
      },
      drawer: const SidebarPage(),
      child: child,
    );
  }
}
