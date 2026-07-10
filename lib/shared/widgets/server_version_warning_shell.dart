import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/app_providers.dart';
import '../../core/utils/server_version_compat.dart';
import '../../features/auth/providers/unified_auth_providers.dart';
import '../../l10n/app_localizations.dart';
import '../theme/theme_extensions.dart';

/// Adds a persistent warning above every authenticated route when the selected
/// server reports a version newer than this app build has validated.
class ServerVersionWarningShell extends ConsumerWidget {
  const ServerVersionWarningShell({super.key, required this.child});

  final Widget child;

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

    if (!showWarning) return child;

    return Column(
      children: [
        _ServerVersionWarningBanner(serverVersion: serverVersion),
        Expanded(child: child),
      ],
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
