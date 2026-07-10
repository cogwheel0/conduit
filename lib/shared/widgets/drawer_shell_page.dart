import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/app_providers.dart';
import '../../core/utils/server_version_compat.dart';
import '../../features/chat/providers/chat_providers.dart';
import '../../features/navigation/widgets/sidebar_page.dart';
import '../../l10n/app_localizations.dart';
import '../../shared/theme/theme_extensions.dart';
import 'responsive_drawer_layout.dart';

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
    final size = MediaQuery.of(context).size;
    final isTablet = size.shortestSide >= 600;
    final scrim = Platform.isIOS
        ? context.colorTokens.scrimMedium
        : context.colorTokens.scrimStrong;
    final serverIsNewerThanSupported = ref.watch(serverIncompatibleProvider);
    final serverVersion = ref
        .watch(backendConfigProvider)
        .asData
        ?.value
        ?.version;

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
      child: Column(
        children: [
          if (serverIsNewerThanSupported)
            _ServerVersionWarningBanner(serverVersion: serverVersion),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _ServerVersionWarningBanner extends StatelessWidget {
  const _ServerVersionWarningBanner({required this.serverVersion});

  final String? serverVersion;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final version = serverVersion?.trim();
    final displayedVersion = version == null || version.isEmpty ? '?' : version;
    final warningColor = theme.warning;

    return Semantics(
      container: true,
      liveRegion: true,
      label: l10n.serverIncompatibleTitle,
      child: Container(
        width: double.infinity,
        color: warningColor.withValues(alpha: 0.12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: SafeArea(
          bottom: false,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.warning_amber_rounded, color: warningColor),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.serverIncompatibleTitle,
                      style: theme.bodySmall?.copyWith(
                        color: theme.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      l10n.serverIncompatibleMessage(
                        displayedVersion,
                        ServerVersionCompat.maxSupportedVersion,
                      ),
                      style: theme.bodySmall?.copyWith(
                        color: theme.textPrimary,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
