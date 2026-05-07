import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/chat/providers/chat_providers.dart';
import '../../features/navigation/widgets/sidebar_page.dart';
import '../../shared/theme/theme_extensions.dart';
import 'responsive_drawer_layout.dart';
import 'sidebar_primary_circle_button.dart';

/// Shell widget that wraps child routes with a persistent
/// [ResponsiveDrawerLayout] + [SidebarPage] drawer.
///
/// Used inside a [ShellRoute] so the drawer survives navigation
/// between chat, channel, and note-editor pages on tablets.
class DrawerShellPage extends ConsumerWidget {
  final Widget child;

  const DrawerShellPage({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final size = MediaQuery.of(context).size;
    final isTablet = size.shortestSide >= 600;
    final scrim = Platform.isIOS
        ? context.colorTokens.scrimMedium
        : context.colorTokens.scrimStrong;

    return ResponsiveDrawerLayout(
      maxFraction: isTablet ? 0.42 : 1.0,
      edgeFraction: isTablet ? 0.36 : 0.50,
      settleFraction: 0.06,
      scrimColor: scrim,
      pushContent: true,
      contentScaleDelta: 0.0,
      mobileBottomDragGestureExclusion: isTablet
          ? 0.0
          : sidebarBottomBarGestureExclusionHeight(context),
      tabletDrawerWidth: 320.0,
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
