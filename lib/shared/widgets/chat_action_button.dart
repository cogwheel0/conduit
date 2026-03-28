import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qonduit/shared/theme/theme_extensions.dart';
import 'package:qonduit/core/services/platform_service.dart';
import 'package:qonduit/core/services/settings_service.dart';

class ChatActionButton extends ConsumerStatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final BorderRadius? borderRadius;

  /// SF Symbol name for iOS 26+ native rendering (e.g. 'doc.on.clipboard').
  final String? sfSymbol;

  const ChatActionButton({
    super.key,
    required this.icon,
    required this.label,
    this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    this.borderRadius,
    this.sfSymbol,
  });

  @override
  ConsumerState<ChatActionButton> createState() => _ChatActionButtonState();
}

class _ChatActionButtonState extends ConsumerState<ChatActionButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = context.qonduitTheme;
    final hapticEnabled = ref.read(hapticEnabledProvider);
    final radius = BorderRadius.circular(AppBorderRadius.circular);

    if (PlatformInfo.isIOS26OrHigher() && widget.sfSymbol != null) {
      return AdaptiveTooltip(
        message: widget.label,
        waitDuration: const Duration(milliseconds: 600),
        child: Semantics(
          button: true,
          label: widget.label,
          child: AdaptiveButton.child(
            onPressed: widget.onTap == null
                ? null
                : () {
                    PlatformService.hapticFeedbackWithSettings(
                      type: HapticType.selection,
                      hapticEnabled: hapticEnabled,
                    );
                    widget.onTap!();
                  },
            style: AdaptiveButtonStyle.glass,
            size: AdaptiveButtonSize.small,
            minSize: const Size(30, 30),
            useSmoothRectangleBorder: false,
            child: Icon(
              widget.icon,
              size: 13,
              color: theme.textPrimary.withValues(alpha: 0.8),
            ),
          ),
        ),
      );
    }

    final overlay = theme.buttonPrimary.withValues(alpha: 0.08);

    return AdaptiveTooltip(
      message: widget.label,
      waitDuration: const Duration(milliseconds: 600),
      child: Semantics(
        button: true,
        label: widget.label,
        child: AnimatedScale(
          scale: _pressed ? 0.95 : 1.0,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOutCubic,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: radius,
              splashColor: overlay,
              highlightColor: theme.textPrimary.withValues(alpha: 0.06),
              onHighlightChanged: (v) => setState(() => _pressed = v),
              onTap: widget.onTap == null
                  ? null
                  : () {
                      PlatformService.hapticFeedbackWithSettings(
                        type: HapticType.selection,
                        hapticEnabled: hapticEnabled,
                      );
                      widget.onTap!();
                    },
              child: Ink(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: theme.textPrimary.withValues(alpha: 0.04),
                  borderRadius: radius,
                  border: Border.all(
                    color: theme.textPrimary.withValues(alpha: 0.08),
                    width: BorderWidth.regular,
                  ),
                ),
                child: Icon(
                  widget.icon,
                  size: IconSize.sm,
                  color: theme.textPrimary.withValues(alpha: 0.8),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
