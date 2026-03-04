import 'package:flutter/material.dart';

import '../../../shared/theme/theme_extensions.dart';

/// A bar displaying follow-up suggestion buttons for the user to continue
/// a conversation with pre-suggested prompts.
class FollowUpSuggestionBar extends StatelessWidget {
  const FollowUpSuggestionBar({
    super.key,
    required this.suggestions,
    required this.onSelected,
    required this.isBusy,
  });

  final List<String> suggestions;
  final ValueChanged<String> onSelected;
  final bool isBusy;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final trimmedSuggestions = suggestions
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);

    if (trimmedSuggestions.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Subtle header
        Row(
          children: [
            Icon(
              Icons.lightbulb_outline,
              size: 12,
              color: theme.textSecondary.withValues(alpha: 0.7),
            ),
            const SizedBox(width: Spacing.xxs),
            Text(
              'Continue with',
              style: TextStyle(
                fontSize: AppTypography.labelSmall,
                color: theme.textSecondary.withValues(alpha: 0.7),
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        const SizedBox(height: Spacing.xs),
        Wrap(
          spacing: Spacing.xs,
          runSpacing: Spacing.xs,
          children: [
            for (final suggestion in trimmedSuggestions)
              _MinimalFollowUpButton(
                label: suggestion,
                onPressed: isBusy ? null : () => onSelected(suggestion),
                enabled: !isBusy,
              ),
          ],
        ),
      ],
    );
  }
}

class _MinimalFollowUpButton extends StatelessWidget {
  const _MinimalFollowUpButton({
    required this.label,
    this.onPressed,
    this.enabled = true,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    return InkWell(
      onTap: enabled ? onPressed : null,
      borderRadius: BorderRadius.circular(AppBorderRadius.small),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.sm,
          vertical: Spacing.xs,
        ),
        decoration: BoxDecoration(
          color: enabled
              ? theme.surfaceContainer.withValues(alpha: 0.2)
              : theme.surfaceContainer.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(AppBorderRadius.small),
          border: Border.all(
            color: enabled
                ? theme.buttonPrimary.withValues(alpha: 0.15)
                : theme.dividerColor.withValues(alpha: 0.2),
            width: BorderWidth.thin,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.arrow_forward,
              size: 11,
              color: enabled
                  ? theme.buttonPrimary.withValues(alpha: 0.7)
                  : theme.textSecondary.withValues(alpha: 0.4),
            ),
            const SizedBox(width: Spacing.xxs),
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  color: enabled
                      ? theme.buttonPrimary.withValues(alpha: 0.9)
                      : theme.textSecondary.withValues(alpha: 0.5),
                  fontSize: AppTypography.bodySmall,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
