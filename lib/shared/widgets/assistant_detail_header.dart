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
    this.allowWrap = false,
    this.useInlineChevron = false,
    this.isExpanded = false,
  });

  final String title;
  final bool showShimmer;
  final bool showChevron;
  final bool allowWrap;
  final bool useInlineChevron;
  final bool isExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final textTheme = Theme.of(context).textTheme;
    final header = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Flexible(
          child: Text(
            title,
            overflow: allowWrap ? null : TextOverflow.ellipsis,
            maxLines: allowWrap ? null : 1,
            style:
                textTheme.bodyLarge?.copyWith(
                  color: theme.textPrimary.withValues(alpha: 0.6),
                ) ??
                AppTypography.chatMessageStyle.copyWith(
                  color: theme.textPrimary.withValues(alpha: 0.6),
                ),
          ),
        ),
        if (showChevron) ...[
          const SizedBox(width: 4),
          AnimatedRotation(
            turns: useInlineChevron ? (isExpanded ? 0 : -0.25) : 0,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            child: Icon(
              useInlineChevron
                  ? Icons.expand_more_rounded
                  : Icons.chevron_right_rounded,
              size: 16,
              color: theme.textPrimary.withValues(alpha: 0.6),
            ),
          ),
        ],
      ],
    );

    if (!showShimmer) {
      return header;
    }

    final disableAnimations =
        MediaQuery.maybeDisableAnimationsOf(context) ??
        WidgetsBinding
            .instance
            .platformDispatcher
            .accessibilityFeatures
            .disableAnimations;
    if (disableAnimations) {
      return header;
    }

    final bindingType = WidgetsBinding.instance.runtimeType.toString();
    final isWidgetTestBinding = bindingType.contains('Test');

    if (isWidgetTestBinding) {
      // Avoid flutter_animate timers in widget tests so pumpAndSettle and
      // disposal-based assertions remain stable.
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
