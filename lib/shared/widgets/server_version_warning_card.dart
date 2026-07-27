import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/app_providers.dart';
import '../../core/utils/server_version_compat.dart';
import '../../features/auth/providers/unified_auth_providers.dart';
import '../../l10n/app_localizations.dart';
import '../theme/theme_extensions.dart';

/// Persistent, in-flow compatibility warning shown with the empty-chat greeting.
class ServerVersionWarningCard extends ConsumerWidget {
  const ServerVersionWarningCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authNavigationStateProvider);
    final serverIsNewerThanSupported = ref.watch(serverIncompatibleProvider);
    final serverVersion = ref
        .watch(backendConfigProvider)
        .asData
        ?.value
        ?.version;

    final showWarning =
        authState == AuthNavigationState.authenticated &&
        serverIsNewerThanSupported;
    if (!showWarning) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final version = serverVersion?.trim();
    final displayedVersion = version == null || version.isEmpty ? '?' : version;
    final warningColor = theme.warning;

    final titleStyle = theme.bodySmall?.copyWith(
      color: theme.textPrimary,
      fontWeight: FontWeight.w600,
      decoration: TextDecoration.none,
      decorationColor: Colors.transparent,
    );
    final messageStyle = theme.bodySmall?.copyWith(
      color: theme.textSecondary,
      height: 1.35,
      decoration: TextDecoration.none,
      decorationColor: Colors.transparent,
    );

    return Padding(
      padding: const EdgeInsets.only(top: Spacing.lg),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Semantics(
          container: true,
          liveRegion: true,
          label: l10n.serverIncompatibleTitle,
          child: Container(
            key: const ValueKey('server-version-warning-card'),
            width: double.infinity,
            padding: const EdgeInsets.all(Spacing.md),
            decoration: BoxDecoration(
              color: theme.warningBackground,
              borderRadius: BorderRadius.circular(AppBorderRadius.card),
              border: Border.all(
                color: warningColor.withValues(alpha: 0.35),
                width: BorderWidth.thin,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 22,
                  color: warningColor,
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.serverIncompatibleTitle, style: titleStyle),
                      const SizedBox(height: Spacing.xs),
                      Text(
                        l10n.serverIncompatibleMessage(
                          displayedVersion,
                          ServerVersionCompat.maxSupportedVersion,
                        ),
                        style: messageStyle,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
