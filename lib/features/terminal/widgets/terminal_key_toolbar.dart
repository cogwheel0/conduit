import 'dart:async';

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/adaptive_glass.dart';
import 'terminal_clipboard_actions.dart';

/// Accessory toolbar of touch-friendly keys for the terminal: command history
/// (Up/Down), shell completion (Tab), copy/paste, and Ctrl-C. Operates
/// directly on the shared [terminal]/[controller]; any key routes through the
/// terminal's `onOutput` callback and out to the remote PTY.
class TerminalKeyToolbar extends StatelessWidget {
  const TerminalKeyToolbar({
    super.key,
    required this.terminal,
    required this.controller,
    required this.connected,
  });

  final Terminal terminal;
  final TerminalController controller;
  final bool connected;

  void _sendKey(TerminalKey key, {bool ctrl = false}) {
    terminal.keyInput(key, ctrl: ctrl);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.surfaceBackground,
        border: Border(top: BorderSide(color: theme.cardBorder)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.sm,
          vertical: Spacing.xs,
        ),
        child: Row(
          children: [
            Expanded(
              child: _ToolbarKey(
                icon: Icons.keyboard_arrow_up_rounded,
                tooltip: l10n.terminalKeyUp,
                onPressed: connected
                    ? () => _sendKey(TerminalKey.arrowUp)
                    : null,
              ),
            ),
            const SizedBox(width: Spacing.xs),
            Expanded(
              child: _ToolbarKey(
                icon: Icons.keyboard_arrow_down_rounded,
                tooltip: l10n.terminalKeyDown,
                onPressed: connected
                    ? () => _sendKey(TerminalKey.arrowDown)
                    : null,
              ),
            ),
            const SizedBox(width: Spacing.xs),
            Expanded(
              child: _ToolbarKey(
                label: l10n.terminalKeyTab,
                tooltip: l10n.terminalKeyTab,
                onPressed: connected ? () => _sendKey(TerminalKey.tab) : null,
              ),
            ),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: _ToolbarKey(
                icon: Icons.copy_rounded,
                tooltip: l10n.terminalCopyAction,
                onPressed: () => unawaited(
                  copyTerminalSelection(context, terminal, controller),
                ),
              ),
            ),
            const SizedBox(width: Spacing.xs),
            Expanded(
              child: _ToolbarKey(
                icon: Icons.paste_rounded,
                tooltip: l10n.terminalPasteAction,
                onPressed: () => unawaited(
                  pasteIntoTerminal(context, terminal, connected: connected),
                ),
              ),
            ),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: _ToolbarKey(
                icon: Icons.block_rounded,
                tooltip: l10n.terminalKeyCtrlC,
                onPressed: connected
                    ? () => _sendKey(TerminalKey.keyC, ctrl: true)
                    : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolbarKey extends StatelessWidget {
  const _ToolbarKey({
    required this.tooltip,
    required this.onPressed,
    this.icon,
    this.label,
  }) : assert(icon != null || label != null);

  final String tooltip;
  final VoidCallback? onPressed;
  final IconData? icon;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final enabled = onPressed != null;
    final foreground = enabled ? theme.iconSecondary : theme.iconDisabled;
    final usesOpaqueFallback = conduitUsesOpaqueGlassFallback();

    final Widget child = icon != null
        ? Icon(icon, size: IconSize.sm, color: foreground)
        : Text(
            label!,
            style: AppTypography.labelStyle.copyWith(
              color: foreground,
              fontWeight: FontWeight.w600,
            ),
          );

    return AdaptiveTooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: tooltip,
        child: AdaptiveButton.child(
          onPressed: onPressed,
          enabled: enabled,
          style: usesOpaqueFallback
              ? AdaptiveButtonStyle.filled
              : AdaptiveButtonStyle.glass,
          color: usesOpaqueFallback ? theme.surfaceContainerHighest : null,
          size: AdaptiveButtonSize.small,
          minSize: const Size(TouchTarget.minimum, TouchTarget.minimum),
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.sm,
            vertical: Spacing.xxs,
          ),
          borderRadius: BorderRadius.circular(AppBorderRadius.small),
          useSmoothRectangleBorder: false,
          child: child,
        ),
      ),
    );
  }
}
