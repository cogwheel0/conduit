import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/core/services/platform_service.dart';
import 'package:conduit/core/services/settings_service.dart';

class ChatActionButton extends ConsumerStatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const ChatActionButton({
    super.key,
    required this.icon,
    required this.label,
    this.onTap,
  });

  @override
  ConsumerState<ChatActionButton> createState() => _ChatActionButtonState();
}

class _ChatActionButtonState extends ConsumerState<ChatActionButton> {
  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final hapticEnabled = ref.read(hapticEnabledProvider);
    final handleTap = widget.onTap == null
        ? null
        : () {
            PlatformService.hapticFeedbackWithSettings(
              type: HapticType.selection,
              hapticEnabled: hapticEnabled,
            );
            widget.onTap!();
          };

    return AdaptiveTooltip(
      message: widget.label,
      waitDuration: const Duration(milliseconds: 600),
      child: Semantics(
        button: true,
        label: widget.label,
        child: AdaptiveButton.child(
          onPressed: handleTap,
          style: AdaptiveButtonStyle.glass,
          size: AdaptiveButtonSize.small,
          minSize: const Size(32, 32),
          padding: EdgeInsets.zero,
          useSmoothRectangleBorder: false,
          child: Icon(
            widget.icon,
            size: IconSize.sm,
            color: theme.textPrimary.withValues(alpha: 0.8),
          ),
        ),
      ),
    );
  }
}
