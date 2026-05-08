import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/core/services/platform_service.dart';
import 'package:conduit/core/services/settings_service.dart';

class ChatActionButton extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = context.conduitTheme;
    final hapticEnabled = ref.read(hapticEnabledProvider);
    final handleTap = onTap == null
        ? null
        : () {
            PlatformService.hapticFeedbackWithSettings(
              type: HapticType.selection,
              hapticEnabled: hapticEnabled,
            );
            onTap!();
          };

    final foreground = theme.textPrimary.withValues(
      alpha: handleTap == null ? 0.36 : 0.8,
    );

    return Tooltip(
      message: label,
      waitDuration: const Duration(milliseconds: 600),
      child: Semantics(
        button: true,
        enabled: handleTap != null,
        label: label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: handleTap,
          child: SizedBox(
            width: 32,
            height: 32,
            child: Center(
              child: Icon(icon, size: IconSize.sm, color: foreground),
            ),
          ),
        ),
      ),
    );
  }
}
