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
    final trimmedSuggestions = suggestions
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .take(3)
        .toList(growable: false);

    if (trimmedSuggestions.isEmpty) {
      return const SizedBox.shrink();
    }

    return Wrap(
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
    final textStyle = AppTypography.chatMessageStyle.copyWith(
      color: enabled
          ? theme.buttonPrimary.withValues(alpha: 0.75)
          : theme.textSecondary.withValues(alpha: 0.45),
    );
    final iconSize =
        (textStyle.fontSize ?? AppTypography.chatMessageStyle.fontSize ?? 16) +
        1;

    return InkWell(
      onTap: enabled ? onPressed : null,
      borderRadius: BorderRadius.circular(AppBorderRadius.small),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.subdirectory_arrow_right_rounded,
              size: iconSize,
              color: enabled
                  ? theme.buttonPrimary.withValues(alpha: 0.7)
                  : theme.textSecondary.withValues(alpha: 0.4),
            ),
            const SizedBox(width: Spacing.xs),
            Flexible(
              child: Text(
                label,
                style: textStyle,
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
