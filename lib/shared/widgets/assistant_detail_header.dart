import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../theme/theme_extensions.dart';

/// A minimal expandable header used for assistant-side detail rows.
///
/// This keeps reasoning, tool calls, and execution entries visually aligned.
class AssistantDetailHeader extends StatelessWidget {
  const AssistantDetailHeader({
    super.key,
    required this.title,
    required this.showShimmer,
    this.showChevron = true,
  });

  final String title;
  final bool showShimmer;
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final header = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Flexible(
          child: Text(
            title,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: AppTypography.bodyMedium,
              color: theme.textPrimary.withValues(alpha: 0.6),
              height: 1.3,
            ),
          ),
        ),
        if (showChevron) ...[
          const SizedBox(width: 4),
          Icon(
            Icons.chevron_right_rounded,
            size: 16,
            color: theme.textPrimary.withValues(alpha: 0.6),
          ),
        ],
      ],
    );

    if (!showShimmer) {
      return header;
    }

    return header
        .animate(onPlay: (controller) => controller.repeat())
        .shimmer(
          duration: 1500.ms,
          color: theme.shimmerHighlight.withValues(alpha: 0.6),
        );
  }
}
