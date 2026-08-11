import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/adaptive_glass.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/utils/utf16_sanitizer.dart';
import '../../../shared/widgets/utility_components.dart';

class TerminalIconActionButton extends StatelessWidget {
  const TerminalIconActionButton({
    required this.tooltip,
    required this.iosIcon,
    required this.materialIcon,
    required this.onPressed,
    this.compact = false,
    super.key,
  });

  final String tooltip;
  final IconData iosIcon;
  final IconData materialIcon;
  final VoidCallback? onPressed;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final iconSize = compact ? IconSize.sm : IconSize.medium;
    final minSide = compact ? TouchTarget.micro : TouchTarget.medium;
    final usesOpaqueFallback = conduitUsesOpaqueGlassFallback();
    return AdaptiveTooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: onPressed != null,
        label: tooltip,
        child: AdaptiveButton.child(
          onPressed: onPressed,
          enabled: onPressed != null,
          style: usesOpaqueFallback
              ? AdaptiveButtonStyle.filled
              : AdaptiveButtonStyle.glass,
          color: usesOpaqueFallback ? theme.surfaceContainerHighest : null,
          size: compact ? AdaptiveButtonSize.small : AdaptiveButtonSize.medium,
          minSize: Size(minSide, minSide),
          padding: compact
              ? const EdgeInsets.all(Spacing.xxs)
              : EdgeInsets.zero,
          borderRadius: BorderRadius.circular(AppBorderRadius.circular),
          useSmoothRectangleBorder: false,
          child: Icon(
            UiUtils.platformIcon(ios: iosIcon, android: materialIcon),
            size: iconSize,
            color: onPressed != null ? theme.iconSecondary : theme.iconDisabled,
          ),
        ),
      ),
    );
  }
}

class TerminalInfoCard extends StatelessWidget {
  const TerminalInfoCard(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    return InsetGroupedSection(
      padding: const EdgeInsets.all(Spacing.md),
      child: Text(
        sanitizeUtf16(message),
        style: AppTypography.bodyMediumStyle.copyWith(
          color: context.conduitTheme.textSecondary,
        ),
      ),
    );
  }
}
