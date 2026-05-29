import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/adaptive_route_shell.dart';
import '../providers/terminal_providers.dart';
import 'terminal_connection_badge.dart';
import 'terminal_console_surface.dart';

/// Full-screen presentation of the terminal console. The [terminal] and
/// [controller] are owned by the sidebar `TerminalTab` and passed by reference;
/// while this page is on screen the inline pane renders a placeholder so only
/// one `TerminalView` is mounted against the shared session at a time.
class TerminalFullscreenPage extends ConsumerWidget {
  const TerminalFullscreenPage({
    super.key,
    required this.terminal,
    required this.controller,
  });

  final Terminal terminal;
  final TerminalController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final connectionState = ref.watch(terminalConnectionStateProvider);

    return AdaptiveRouteShell(
      backgroundColor: theme.surfaceBackground,
      bodySafeArea: true,
      appBar: AdaptiveAppBar(title: l10n.terminal),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.md,
              Spacing.sm,
              Spacing.md,
              Spacing.sm,
            ),
            child: Row(
              children: [
                const Spacer(),
                TerminalConnectionBadge(state: connectionState),
              ],
            ),
          ),
          Expanded(
            child: TerminalConsoleSurface(
              terminal: terminal,
              controller: controller,
              connected: connectionState.isConnected,
              roundedBottom: false,
            ),
          ),
        ],
      ),
    );
  }
}
