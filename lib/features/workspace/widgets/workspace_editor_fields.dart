import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/material.dart';

import 'package:conduit/shared/theme/theme_extensions.dart';

/// Wraps a form input and renders optional helper text beneath it.
///
/// Adaptive form inputs ([ConduitInput]/[AdaptiveTextField]) do not carry a
/// Material-style `helperText`, so section editors compose it here to keep the
/// same guidance copy the raw fields used to show.
class WorkspaceLabeledField extends StatelessWidget {
  const WorkspaceLabeledField({
    super.key,
    required this.child,
    this.helperText,
  });

  final Widget child;
  final String? helperText;

  @override
  Widget build(BuildContext context) {
    final helper = helperText;
    if (helper == null || helper.isEmpty) {
      return child;
    }
    final theme = context.conduitTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        child,
        const SizedBox(height: Spacing.xs),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
          child: Text(
            helper,
            style: theme.caption?.copyWith(color: theme.textSecondary),
          ),
        ),
      ],
    );
  }
}

/// A plain (borderless) adaptive text+icon button used for inline editor
/// affordances such as "Change image" or "Add" actions, replacing Material
/// [TextButton.icon] with a native-feeling control.
class WorkspacePlainIconButton extends StatelessWidget {
  const WorkspacePlainIconButton({
    super.key,
    this.buttonKey,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.isDestructive = false,
  });

  /// Key applied to the underlying button so widget tests can target it.
  final Key? buttonKey;
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  /// Uses the theme error color for destructive actions (e.g. delete).
  final bool isDestructive;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final color = onPressed == null
        ? theme.iconSecondary
        : isDestructive
        ? theme.error
        : theme.buttonPrimary;
    return AdaptiveButton.child(
      key: buttonKey,
      onPressed: onPressed,
      enabled: onPressed != null,
      style: AdaptiveButtonStyle.plain,
      size: AdaptiveButtonSize.small,
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.sm,
        vertical: Spacing.xs,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: IconSize.small, color: color),
          const SizedBox(width: Spacing.xs),
          Text(
            label,
            style: AppTypography.standard.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
