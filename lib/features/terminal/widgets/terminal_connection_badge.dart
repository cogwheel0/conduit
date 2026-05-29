import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../models/terminal_models.dart';

/// Pill badge that reflects the terminal connection status. Shared by the
/// inline pane header and the full-screen terminal page.
class TerminalConnectionBadge extends StatelessWidget {
  const TerminalConnectionBadge({super.key, required this.state});

  final TerminalConnectionState state;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;

    final label = switch (state.status) {
      TerminalConnectionStatus.connected => l10n.terminalConnectedStatus,
      TerminalConnectionStatus.connecting => l10n.terminalConnectingStatus,
      TerminalConnectionStatus.error => l10n.errorMessage,
      TerminalConnectionStatus.disconnected => l10n.terminalDisconnectedStatus,
    };
    final color = switch (state.status) {
      TerminalConnectionStatus.connected => const Color(0xFF16A34A),
      TerminalConnectionStatus.connecting => theme.buttonPrimary,
      TerminalConnectionStatus.error => theme.error,
      TerminalConnectionStatus.disconnected => theme.textSecondary,
    };

    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppBorderRadius.pill),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: 6),
        child: Text(
          label,
          style: AppTypography.labelSmallStyle.copyWith(
            color: color,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
