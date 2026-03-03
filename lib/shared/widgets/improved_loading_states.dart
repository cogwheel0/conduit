import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'skeleton_loader.dart';
import '../theme/theme_extensions.dart';
import 'conduit_components.dart';
import 'package:conduit/l10n/app_localizations.dart';

/// Improved loading state widget with accessibility and better hierarchy
class ImprovedLoadingState extends StatefulWidget {
  final String? message;
  final bool showProgress;
  final double? progress;
  final Widget? customWidget;
  final bool useSkeletonLoader;
  final int skeletonCount;
  final double skeletonHeight;
  final bool isCompact;

  const ImprovedLoadingState({
    super.key,
    this.message,
    this.showProgress = false,
    this.progress,
    this.customWidget,
    this.useSkeletonLoader = false,
    this.skeletonCount = 3,
    this.skeletonHeight = 100,
    this.isCompact = false,
  });

  @override
  State<ImprovedLoadingState> createState() => _ImprovedLoadingStateState();
}

class _ImprovedLoadingStateState extends State<ImprovedLoadingState>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: AnimationDuration.standard,
      vsync: this,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animationController,
      curve: AnimationCurves.standard,
    );
    _animationController.forward();

    // Announce loading state for screen readers using localized messaging.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      final announcement = widget.message ?? l10n?.loadingContent ?? 'Loading';
      final direction = Directionality.maybeOf(context) ?? TextDirection.ltr;
      final view =
          View.maybeOf(context) ??
          WidgetsBinding.instance.platformDispatcher.implicitView;
      if (view != null) {
        SemanticsService.sendAnnouncement(view, announcement, direction);
      }
    });
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.customWidget != null) {
      return widget.customWidget!;
    }

    if (widget.useSkeletonLoader) {
      return _buildSkeletonLoader();
    }

    return FadeTransition(
      opacity: _fadeAnimation,
      child: Center(
        child: Semantics(
          label: widget.message ?? AppLocalizations.of(context)!.loadingContent,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.showProgress && widget.progress != null)
                _buildProgressIndicator()
              else
                _buildCircularIndicator(),

              if (widget.message != null) ...[
                SizedBox(height: widget.isCompact ? Spacing.sm : Spacing.md),
                Text(
                  widget.message!,
                  style: AppTypography.standard.copyWith(
                    color: context.conduitTheme.textSecondary,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCircularIndicator() {
    return SizedBox(
      width: widget.isCompact ? IconSize.large : IconSize.xxl,
      height: widget.isCompact ? IconSize.large : IconSize.xxl,
      child: CircularProgressIndicator(
        strokeWidth: widget.isCompact ? 2 : 3,
        valueColor: AlwaysStoppedAnimation<Color>(
          context.conduitTheme.buttonPrimary,
        ),
      ),
    );
  }

  Widget _buildProgressIndicator() {
    return Column(
      children: [
        SizedBox(
          width: widget.isCompact ? 150 : 200,
          child: LinearProgressIndicator(
            value: widget.progress,
            minHeight: widget.isCompact ? 3 : 4,
            backgroundColor: context.conduitTheme.dividerColor,
            valueColor: AlwaysStoppedAnimation<Color>(
              context.conduitTheme.buttonPrimary,
            ),
          ),
        ),
        SizedBox(height: widget.isCompact ? Spacing.xs : Spacing.sm),
        Text(
          '${(widget.progress! * 100).toInt()}%',
          style: AppTypography.small.copyWith(
            color: context.conduitTheme.textSecondary,
          ),
        ),
      ],
    );
  }

  Widget _buildSkeletonLoader() {
    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: widget.skeletonCount,
      itemBuilder: (context, index) => Padding(
        padding: EdgeInsets.symmetric(
          horizontal: widget.isCompact ? Spacing.sm : Spacing.md,
          vertical: widget.isCompact ? Spacing.xs : Spacing.sm,
        ),
        child: SkeletonLoader(
          height: widget.skeletonHeight,
          isCompact: widget.isCompact,
        ),
      ),
    );
  }
}

/// Improved empty state with better UX and hierarchy
class ImprovedEmptyState extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? customIcon;
  final VoidCallback? onAction;
  final String? actionLabel;
  final bool showAnimation;
  final bool isCompact;

  const ImprovedEmptyState({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.customIcon,
    this.onAction,
    this.actionLabel,
    this.showAnimation = true,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    Widget content = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Icon or custom widget
        if (customIcon != null)
          customIcon!
        else if (icon != null)
          showAnimation
              ? TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.0, end: 1.0),
                  duration: AnimationDuration.standard,
                  curve: AnimationCurves.elastic,
                  builder: (context, value, child) => Transform.scale(
                    scale: value,
                    child: Icon(
                      icon,
                      size: isCompact ? IconSize.large : IconSize.xxl,
                      color: theme.iconSecondary,
                    ),
                  ),
                )
              : Icon(
                  icon,
                  size: isCompact ? IconSize.large : IconSize.xxl,
                  color: theme.iconSecondary,
                ),

        SizedBox(height: isCompact ? Spacing.md : Spacing.lg),

        // Title
        Text(
          title,
          style: AppTypography.headlineSmallStyle.copyWith(
            color: theme.textPrimary,
            fontWeight: FontWeight.w600,
          ),
          textAlign: TextAlign.center,
        ),

        // Subtitle
        if (subtitle != null) ...[
          SizedBox(height: isCompact ? Spacing.xs : Spacing.sm),
          Text(
            subtitle!,
            style: AppTypography.standard.copyWith(color: theme.textSecondary),
            textAlign: TextAlign.center,
          ),
        ],

        // Action button
        if (actionLabel != null && onAction != null) ...[
          SizedBox(height: isCompact ? Spacing.md : Spacing.lg),
          ConduitButton(
            text: actionLabel!,
            onPressed: onAction,
            isCompact: isCompact,
          ),
        ],
      ],
    );

    return Center(
      child: Padding(
        padding: EdgeInsets.all(isCompact ? Spacing.md : Spacing.lg),
        child: showAnimation
            ? content.animate().fadeIn(
                duration: AnimationDuration.standard,
                curve: AnimationCurves.standard,
              )
            : content,
      ),
    );
  }
}

/// Enhanced loading overlay with better hierarchy
class LoadingOverlay extends StatelessWidget {
  final Widget child;
  final bool isLoading;
  final String? message;
  final bool isCompact;

  const LoadingOverlay({
    super.key,
    required this.child,
    required this.isLoading,
    this.message,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        if (isLoading)
          Container(
            color: context.conduitTheme.surfaceBackground.withValues(
              alpha: Alpha.overlay,
            ),
            child: Center(
              child: Container(
                padding: EdgeInsets.all(isCompact ? Spacing.md : Spacing.lg),
                decoration: BoxDecoration(
                  color: context.conduitTheme.cardBackground,
                  borderRadius: BorderRadius.circular(AppBorderRadius.card),
                  boxShadow: ConduitShadows.card(context),
                ),
                child: ImprovedLoadingState(
                  message: message,
                  isCompact: isCompact,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Enhanced loading button with better hierarchy
class LoadingButton extends StatefulWidget {
  final String text;
  final VoidCallback? onPressed;
  final bool isLoading;
  final bool isDestructive;
  final bool isSecondary;
  final IconData? icon;
  final double? width;
  final bool isFullWidth;
  final bool isCompact;

  const LoadingButton({
    super.key,
    required this.text,
    this.onPressed,
    this.isLoading = false,
    this.isDestructive = false,
    this.isSecondary = false,
    this.icon,
    this.width,
    this.isFullWidth = false,
    this.isCompact = false,
  });

  @override
  State<LoadingButton> createState() => _LoadingButtonState();
}

class _LoadingButtonState extends State<LoadingButton> {
  @override
  Widget build(BuildContext context) {
    return ConduitButton(
      text: widget.text,
      onPressed: widget.isLoading ? null : widget.onPressed,
      isLoading: widget.isLoading,
      isDestructive: widget.isDestructive,
      isSecondary: widget.isSecondary,
      icon: widget.icon,
      width: widget.width,
      isFullWidth: widget.isFullWidth,
      isCompact: widget.isCompact,
    );
  }
}

/// Enhanced loading list with better hierarchy
class LoadingList extends StatelessWidget {
  final bool isLoading;
  final Widget child;
  final int skeletonCount;
  final double skeletonHeight;
  final bool isCompact;

  const LoadingList({
    super.key,
    required this.isLoading,
    required this.child,
    this.skeletonCount = 5,
    this.skeletonHeight = 80,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return ListView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: skeletonCount,
        itemBuilder: (context, index) => Padding(
          padding: EdgeInsets.symmetric(
            horizontal: isCompact ? Spacing.sm : Spacing.md,
            vertical: isCompact ? Spacing.xs : Spacing.sm,
          ),
          child: SkeletonLoader(height: skeletonHeight, isCompact: isCompact),
        ),
      );
    }

    return child;
  }
}

/// Enhanced loading card with better hierarchy
class LoadingCard extends StatelessWidget {
  final bool isLoading;
  final Widget child;
  final bool isCompact;

  const LoadingCard({
    super.key,
    required this.isLoading,
    required this.child,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return ConduitCard(
        isCompact: isCompact,
        child: ImprovedLoadingState(
          message: AppLocalizations.of(context)!.loadingContent,
          isCompact: isCompact,
        ),
      );
    }

    return child;
  }
}

/// Shimmer loading effect
class ShimmerLoader extends StatefulWidget {
  final double width;
  final double height;
  final BorderRadius? borderRadius;
  final EdgeInsetsGeometry? margin;

  const ShimmerLoader({
    super.key,
    this.width = double.infinity,
    this.height = 20,
    this.borderRadius,
    this.margin,
  });

  @override
  State<ShimmerLoader> createState() => _ShimmerLoaderState();
}

class _ShimmerLoaderState extends State<ShimmerLoader>
    with SingleTickerProviderStateMixin {
  late AnimationController _shimmerController;
  late Animation<double> _shimmerAnimation;

  @override
  void initState() {
    super.initState();
    _shimmerController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat();

    _shimmerAnimation = Tween<double>(begin: -1.0, end: 2.0).animate(
      CurvedAnimation(parent: _shimmerController, curve: Curves.linear),
    );
  }

  @override
  void dispose() {
    _shimmerController.dispose();
    super.dispose();
  }

  @override
  void deactivate() {
    // Pause shimmer during deactivation to avoid rebuilds in wrong build scope
    _shimmerController.stop();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    if (!_shimmerController.isAnimating) {
      _shimmerController.repeat();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    return Container(
      width: widget.width,
      height: widget.height,
      margin: widget.margin,
      decoration: BoxDecoration(
        borderRadius: widget.borderRadius ?? BorderRadius.circular(4),
        color: theme.surfaceContainer,
      ),
      child: AnimatedBuilder(
        animation: _shimmerAnimation,
        builder: (context, child) {
          return Container(
            decoration: BoxDecoration(
              borderRadius: widget.borderRadius ?? BorderRadius.circular(4),
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  theme.shimmerBase,
                  theme.shimmerHighlight,
                  theme.shimmerBase,
                ],
                stops: [
                  _shimmerAnimation.value - 0.3,
                  _shimmerAnimation.value,
                  _shimmerAnimation.value + 0.3,
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Content placeholder for loading states
class ContentPlaceholder extends StatelessWidget {
  final int lineCount;
  final double lineHeight;
  final double spacing;
  final EdgeInsetsGeometry? padding;
  final bool showAvatar;
  final bool showActions;

  const ContentPlaceholder({
    super.key,
    this.lineCount = 3,
    this.lineHeight = 16,
    this.spacing = 8,
    this.padding,
    this.showAvatar = false,
    this.showActions = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding ?? const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showAvatar)
            Row(
              children: [
                const ShimmerLoader(
                  width: 48,
                  height: 48,
                  borderRadius: BorderRadius.all(Radius.circular(24)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ShimmerLoader(width: 120, height: lineHeight),
                      SizedBox(height: spacing / 2),
                      ShimmerLoader(width: 80, height: lineHeight * 0.8),
                    ],
                  ),
                ),
              ],
            ),

          if (showAvatar) SizedBox(height: spacing * 2),

          ...List.generate(lineCount, (index) {
            final isLast = index == lineCount - 1;
            return Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : spacing),
              child: ShimmerLoader(
                width: isLast ? 200 : double.infinity,
                height: lineHeight,
              ),
            );
          }),

          if (showActions) ...[
            SizedBox(height: spacing * 2),
            Row(
              children: [
                ShimmerLoader(
                  width: 80,
                  height: 32,
                  borderRadius: BorderRadius.circular(16),
                ),
                const SizedBox(width: 8),
                ShimmerLoader(
                  width: 80,
                  height: 32,
                  borderRadius: BorderRadius.circular(16),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Error state widget with retry
class ErrorStateWidget extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;
  final Object? error;
  final bool showDetails;

  const ErrorStateWidget({
    super.key,
    required this.message,
    this.onRetry,
    this.error,
    this.showDetails = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 64, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text(
              AppLocalizations.of(context)!.errorMessage,
              style: theme.textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
              textAlign: TextAlign.center,
            ),

            if (showDetails && error != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  error.toString(),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ],

            if (onRetry != null) ...[
              const SizedBox(height: 24),
              AdaptiveButton.child(
                onPressed: onRetry,
                style: AdaptiveButtonStyle.filled,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.refresh),
                    const SizedBox(width: Spacing.sm),
                    Text(AppLocalizations.of(context)!.retry),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
