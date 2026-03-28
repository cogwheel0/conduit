import 'package:flutter/material.dart';

import '../../../shared/theme/theme_extensions.dart';

/// Wrapper widget that highlights a message when selected and shows
/// a check-mark overlay badge.
class SelectableMessageWrapper extends StatelessWidget {
  /// Whether the wrapped message is currently selected.
  final bool isSelected;

  /// Called when the user taps the wrapper.
  final VoidCallback onTap;

  /// Called when the user long-presses the wrapper.
  final VoidCallback? onLongPress;

  /// The message widget to wrap.
  final Widget child;

  const SelectableMessageWrapper({
    super.key,
    required this.isSelected,
    required this.onTap,
    this.onLongPress,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: Spacing.xs),
        decoration: BoxDecoration(
          color: isSelected
              ? context.qonduitTheme.buttonPrimary.withValues(
                  alpha: 0.1,
                )
              : Colors.transparent,
          borderRadius: BorderRadius.circular(
            AppBorderRadius.md,
          ),
          border: isSelected
              ? Border.all(
                  color:
                      context.qonduitTheme.buttonPrimary.withValues(
                    alpha: 0.3,
                  ),
                  width: 2,
                )
              : null,
        ),
        child: Stack(
          children: [
            child,
            if (isSelected)
              Positioned(
                top: Spacing.sm,
                right: Spacing.sm,
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: context.qonduitTheme.buttonPrimary,
                    shape: BoxShape.circle,
                    boxShadow: QonduitShadows.medium(context),
                  ),
                  child: Icon(
                    Icons.check,
                    color: context.qonduitTheme.textInverse,
                    size: 16,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
