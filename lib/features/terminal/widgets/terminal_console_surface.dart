import 'package:flutter/widgets.dart';
import 'package:xterm/xterm.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/utf16_sanitizer.dart';
import 'terminal_key_toolbar.dart';

/// Terminal console body shared by the inline sidebar pane and the full-screen
/// page: the xterm [TerminalView] plus the [TerminalKeyToolbar] accessory row.
///
/// The [terminal]/[controller] are owned elsewhere and passed by reference, so
/// only one [TerminalConsoleSurface] should be mounted against a given
/// [terminal] at a time (xterm drives resize/focus from the live view).
class TerminalConsoleSurface extends StatelessWidget {
  const TerminalConsoleSurface({
    super.key,
    required this.terminal,
    required this.controller,
    required this.connected,
    this.overlayMessage,
    this.autofocus = true,
    this.roundedBottom = true,
  });

  final Terminal terminal;
  final TerminalController controller;
  final bool connected;
  final String? overlayMessage;
  final bool autofocus;
  final bool roundedBottom;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final message = overlayMessage;

    Widget content = Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(color: theme.codeBackground),
                  child: MediaQuery.removePadding(
                    context: context,
                    removeTop: true,
                    child: TerminalView(
                      terminal,
                      controller: controller,
                      autofocus: autofocus,
                      padding: const EdgeInsets.symmetric(
                        horizontal: Spacing.sm,
                        vertical: Spacing.xs,
                      ),
                      theme: buildTerminalTheme(context),
                      textStyle: TerminalStyle.fromTextStyle(
                        AppTypography.codeStyle,
                      ),
                      backgroundOpacity: 1,
                      deleteDetection: true,
                    ),
                  ),
                ),
              ),
              if (message != null) _TerminalOverlayMessage(message: message),
            ],
          ),
        ),
        if (message == null)
          TerminalKeyToolbar(
            terminal: terminal,
            controller: controller,
            connected: connected,
          ),
      ],
    );

    if (roundedBottom) {
      content = ClipRRect(
        borderRadius: const BorderRadius.vertical(
          bottom: Radius.circular(AppBorderRadius.standard),
        ),
        child: content,
      );
    }

    return content;
  }
}

TerminalTheme buildTerminalTheme(BuildContext context) {
  final theme = context.conduitTheme;
  return TerminalTheme(
    cursor: theme.codeText,
    selection: theme.buttonPrimary.withValues(alpha: 0.25),
    foreground: theme.codeText,
    background: theme.codeBackground,
    black: const Color(0xFF000000),
    white: const Color(0xFFE5E5E5),
    red: const Color(0xFFCD3131),
    green: const Color(0xFF0DBC79),
    yellow: const Color(0xFFE5E510),
    blue: const Color(0xFF2472C8),
    magenta: const Color(0xFFBC3FBC),
    cyan: const Color(0xFF11A8CD),
    brightBlack: const Color(0xFF666666),
    brightRed: const Color(0xFFF14C4C),
    brightGreen: const Color(0xFF23D18B),
    brightYellow: const Color(0xFFF5F543),
    brightBlue: const Color(0xFF3B8EEA),
    brightMagenta: const Color(0xFFD670D6),
    brightCyan: const Color(0xFF29B8DB),
    brightWhite: const Color(0xFFFFFFFF),
    searchHitBackground: theme.buttonPrimary.withValues(alpha: 0.35),
    searchHitBackgroundCurrent: theme.buttonPrimary.withValues(alpha: 0.55),
    searchHitForeground: theme.textPrimary,
  );
}

class _TerminalOverlayMessage extends StatelessWidget {
  const _TerminalOverlayMessage({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Positioned.fill(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.codeBackground.withValues(alpha: 0.88),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(Spacing.lg),
            child: Text(
              sanitizeUtf16(message),
              textAlign: TextAlign.center,
              style: AppTypography.bodyMediumStyle.copyWith(
                color: theme.codeText,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
