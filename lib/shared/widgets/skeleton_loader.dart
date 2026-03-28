import 'package:flutter/material.dart';
import '../theme/theme_extensions.dart';

/// Enhanced skeleton loader with production-grade animations and better hierarchy
class SkeletonLoader extends StatefulWidget {
  final double? width;
  final double? height;
  final BorderRadius? borderRadius;
  final Duration? duration;
  final Color? baseColor;
  final Color? highlightColor;
  final bool isCompact;

  const SkeletonLoader({
    super.key,
    this.width,
    this.height,
    this.borderRadius,
    this.duration,
    this.baseColor,
    this.highlightColor,
    this.isCompact = false,
  });

  @override
  State<SkeletonLoader> createState() => _SkeletonLoaderState();
}

class _SkeletonLoaderState extends State<SkeletonLoader>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: widget.duration ?? AnimationDuration.typingIndicator,
      vsync: this,
    );
    _animation =
        Tween<double>(
          begin: AnimationValues.shimmerBegin,
          end: AnimationValues.shimmerEnd,
        ).animate(
          CurvedAnimation(parent: _controller, curve: AnimationCurves.linear),
        );

    _controller.repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void deactivate() {
    // Pause shimmer during deactivation to avoid rebuilds in wrong build scope
    _controller.stop();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    if (!_controller.isAnimating) {
      // Resume shimmer after re-activation
      _controller.repeat();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius:
                widget.borderRadius ??
                BorderRadius.circular(
                  widget.isCompact ? AppBorderRadius.xs : AppBorderRadius.sm,
                ),
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                widget.baseColor ?? context.qonduitTheme.shimmerBase,
                widget.highlightColor ?? context.qonduitTheme.shimmerHighlight,
                widget.baseColor ?? context.qonduitTheme.shimmerBase,
              ],
              stops: [
                _animation.value - 0.3,
                _animation.value,
                _animation.value + 0.3,
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Enhanced skeleton for chat messages with better hierarchy
class SkeletonChatMessage extends StatelessWidget {
  final bool isUser;
  final int lines;
  final bool isCompact;

  const SkeletonChatMessage({
    super.key,
    this.isUser = false,
    this.lines = 2,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: isCompact ? Spacing.sm : Spacing.messagePadding,
        vertical: isCompact ? Spacing.xs : Spacing.sm,
      ),
      child: Row(
        mainAxisAlignment: isUser
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            SkeletonLoader(
              width: isCompact ? 32 : 40,
              height: isCompact ? 32 : 40,
              borderRadius: BorderRadius.circular(AppBorderRadius.avatar),
            ),
            SizedBox(width: isCompact ? Spacing.xs : Spacing.sm),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: isUser
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                for (int i = 0; i < lines; i++)
                  Padding(
                    padding: EdgeInsets.only(
                      bottom: i < lines - 1
                          ? (isCompact ? Spacing.xs : Spacing.sm)
                          : 0,
                    ),
                    child: SkeletonLoader(
                      width: isUser
                          ? null
                          : (MediaQuery.of(context).size.width * 0.6),
                      height: isCompact ? 12 : 16,
                      borderRadius: BorderRadius.circular(
                        isCompact ? AppBorderRadius.xs : AppBorderRadius.sm,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (isUser) ...[
            SizedBox(width: isCompact ? Spacing.xs : Spacing.sm),
            SkeletonLoader(
              width: isCompact ? 32 : 40,
              height: isCompact ? 32 : 40,
              borderRadius: BorderRadius.circular(AppBorderRadius.avatar),
            ),
          ],
        ],
      ),
    );
  }
}

/// Enhanced skeleton for list items with better hierarchy
class SkeletonListItem extends StatelessWidget {
  final bool showAvatar;
  final bool showSubtitle;
  final bool isCompact;

  const SkeletonListItem({
    super.key,
    this.showAvatar = true,
    this.showSubtitle = true,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.all(isCompact ? Spacing.sm : Spacing.listItemPadding),
      child: Row(
        children: [
          if (showAvatar) ...[
            SkeletonLoader(
              width: isCompact ? 32 : 40,
              height: isCompact ? 32 : 40,
              borderRadius: BorderRadius.circular(AppBorderRadius.avatar),
            ),
            SizedBox(width: isCompact ? Spacing.sm : Spacing.md),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SkeletonLoader(
                  width: double.infinity,
                  height: isCompact ? 14 : 16,
                  borderRadius: BorderRadius.circular(
                    isCompact ? AppBorderRadius.xs : AppBorderRadius.sm,
                  ),
                ),
                if (showSubtitle) ...[
                  SizedBox(height: isCompact ? Spacing.xs : Spacing.sm),
                  SkeletonLoader(
                    width: MediaQuery.of(context).size.width * 0.7,
                    height: isCompact ? 12 : 14,
                    borderRadius: BorderRadius.circular(
                      isCompact ? AppBorderRadius.xs : AppBorderRadius.sm,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Enhanced skeleton for cards with better hierarchy
class SkeletonCard extends StatelessWidget {
  final bool showTitle;
  final bool showContent;
  final bool showActions;
  final bool isCompact;

  const SkeletonCard({
    super.key,
    this.showTitle = true,
    this.showContent = true,
    this.showActions = false,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(isCompact ? Spacing.sm : Spacing.cardPadding),
      decoration: BoxDecoration(
        color: context.qonduitTheme.cardBackground,
        borderRadius: BorderRadius.circular(AppBorderRadius.card),
        border: Border.all(
          color: context.qonduitTheme.cardBorder,
          width: BorderWidth.standard,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showTitle) ...[
            SkeletonLoader(
              width: MediaQuery.of(context).size.width * 0.8,
              height: isCompact ? 16 : 20,
              borderRadius: BorderRadius.circular(
                isCompact ? AppBorderRadius.xs : AppBorderRadius.sm,
              ),
            ),
            SizedBox(height: isCompact ? Spacing.sm : Spacing.md),
          ],
          if (showContent) ...[
            SkeletonLoader(
              width: double.infinity,
              height: isCompact ? 12 : 14,
              borderRadius: BorderRadius.circular(
                isCompact ? AppBorderRadius.xs : AppBorderRadius.sm,
              ),
            ),
            SizedBox(height: isCompact ? Spacing.xs : Spacing.sm),
            SkeletonLoader(
              width: MediaQuery.of(context).size.width * 0.6,
              height: isCompact ? 12 : 14,
              borderRadius: BorderRadius.circular(
                isCompact ? AppBorderRadius.xs : AppBorderRadius.sm,
              ),
            ),
            if (showActions) ...[
              SizedBox(height: isCompact ? Spacing.md : Spacing.lg),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  SkeletonLoader(
                    width: isCompact ? 60 : 80,
                    height: isCompact ? 32 : 40,
                    borderRadius: BorderRadius.circular(AppBorderRadius.button),
                  ),
                  SizedBox(width: isCompact ? Spacing.sm : Spacing.md),
                  SkeletonLoader(
                    width: isCompact ? 60 : 80,
                    height: isCompact ? 32 : 40,
                    borderRadius: BorderRadius.circular(AppBorderRadius.button),
                  ),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// Enhanced skeleton for input fields with better hierarchy
class SkeletonInput extends StatelessWidget {
  final bool showLabel;
  final bool isCompact;

  const SkeletonInput({
    super.key,
    this.showLabel = true,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showLabel) ...[
          SkeletonLoader(
            width: 80,
            height: isCompact ? 14 : 16,
            borderRadius: BorderRadius.circular(
              isCompact ? AppBorderRadius.xs : AppBorderRadius.sm,
            ),
          ),
          SizedBox(height: isCompact ? Spacing.xs : Spacing.sm),
        ],
        SkeletonLoader(
          width: double.infinity,
          height: isCompact ? 40 : 48,
          borderRadius: BorderRadius.circular(AppBorderRadius.input),
        ),
      ],
    );
  }
}

/// Enhanced skeleton for buttons with better hierarchy
class SkeletonButton extends StatelessWidget {
  final bool isFullWidth;
  final bool isCompact;

  const SkeletonButton({
    super.key,
    this.isFullWidth = false,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context) {
    return SkeletonLoader(
      width: isFullWidth ? double.infinity : (isCompact ? 80 : 120),
      height: isCompact ? TouchTarget.medium : TouchTarget.comfortable,
      borderRadius: BorderRadius.circular(AppBorderRadius.button),
    );
  }
}
