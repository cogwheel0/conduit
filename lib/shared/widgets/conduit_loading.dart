import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:io' show Platform;
import '../services/brand_service.dart';
import '../theme/color_tokens.dart';
import '../theme/theme_extensions.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'skeleton_loader.dart';
import 'conduit_components.dart';

// ---------------------------------------------------------------------------
// From loading_states.dart
// ---------------------------------------------------------------------------

/// Standard loading indicators following Conduit design patterns
class ConduitLoading {
  // Private constructor to prevent instantiation
  ConduitLoading._();

  /// Primary loading indicator
  static Widget primary({
    double size = IconSize.lg,
    Color? color,
    String? message,
  }) {
    return _LoadingIndicator(
      size: size,
      color: color,
      message: message,
      type: _LoadingType.primary,
    );
  }

  /// Inline loading for content areas
  static Widget inline({
    double size = IconSize.md,
    Color? color,
    String? message,
    BuildContext? context,
  }) {
    return _LoadingIndicator(
      size: size,
      color:
          color ??
          (context?.conduitTheme.loadingIndicator ??
              context?.conduitTheme.buttonPrimary ??
              BrandService.primaryBrandColor(context: context)),
      message: message,
      type: _LoadingType.inline,
    );
  }

  /// Button loading state
  static Widget button({
    double size = IconSize.sm,
    Color? color,
    BuildContext? context,
  }) {
    final tokens = context?.colorTokens ?? AppColorTokens.fallback();
    return _LoadingIndicator(
      size: size,
      color:
          color ??
          (context?.conduitTheme.buttonPrimaryText ??
              context?.conduitTheme.textPrimary ??
              tokens.neutralTone00),
      type: _LoadingType.button,
    );
  }

  /// Overlay loading for full screen
  static Widget overlay({String? message, bool darkBackground = true}) {
    return _LoadingOverlay(message: message, darkBackground: darkBackground);
  }

  /// Skeleton loading for content placeholders
  static Widget skeleton({
    double width = double.infinity,
    double height = 20,
    BorderRadius? borderRadius,
  }) {
    return _SkeletonLoader(
      width: width,
      height: height,
      borderRadius: borderRadius ?? BorderRadius.circular(AppBorderRadius.xs),
    );
  }

  /// List item skeleton
  static Widget listItemSkeleton({bool showAvatar = true, int lines = 2}) {
    return _ListItemSkeleton(showAvatar: showAvatar, lines: lines);
  }
}

enum _LoadingType { primary, inline, button }

class _LoadingIndicator extends StatelessWidget {
  final double size;
  final Color? color;
  final String? message;
  final _LoadingType type;

  const _LoadingIndicator({
    required this.size,
    this.color,
    this.message,
    required this.type,
  });

  @override
  Widget build(BuildContext context) {
    final resolvedColor = color ?? context.conduitTheme.loadingIndicator;

    Widget indicator;

    if (Platform.isIOS) {
      indicator = CupertinoActivityIndicator(
        color: resolvedColor,
        radius: size / 2,
      );
    } else {
      indicator = SizedBox(
        width: size,
        height: size,
        child: CircularProgressIndicator(
          strokeWidth: size / 8,
          valueColor: AlwaysStoppedAnimation<Color>(resolvedColor),
        ),
      );
    }

    if (message == null) {
      return indicator;
    }

    final spacing = type == _LoadingType.button ? Spacing.sm : Spacing.xs;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        indicator,
        SizedBox(height: spacing),
        Text(
          message!,
          style:
              (type == _LoadingType.button
                      ? AppTypography.bodySmallStyle
                      : AppTypography.bodyLargeStyle)
                  .copyWith(color: color, fontWeight: FontWeight.w500),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _LoadingOverlay extends StatelessWidget {
  final String? message;
  final bool darkBackground;

  const _LoadingOverlay({this.message, required this.darkBackground});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: darkBackground
          ? context.conduitTheme.surfaceBackground.withValues(
              alpha: Alpha.strong,
            )
          : context.conduitTheme.surfaceBackground.withValues(
              alpha: Alpha.intense,
            ),
      child: Center(
        child: Container(
          padding: const EdgeInsets.all(Spacing.lg),
          decoration: BoxDecoration(
            color: darkBackground
                ? context.conduitTheme.surfaceBackground
                : context.conduitTheme.surfaceBackground,
            borderRadius: BorderRadius.circular(AppBorderRadius.lg),
            boxShadow: ConduitShadows.high(context),
          ),
          child: ConduitLoading.primary(
            size: IconSize.xl,
            color: context.conduitTheme.buttonPrimary,
            message: message,
          ),
        ),
      ),
    ).animate().fadeIn(duration: AnimationDuration.fast);
  }
}

class _SkeletonLoader extends StatefulWidget {
  final double width;
  final double height;
  final BorderRadius borderRadius;

  const _SkeletonLoader({
    required this.width,
    required this.height,
    required this.borderRadius,
  });

  @override
  State<_SkeletonLoader> createState() => _SkeletonLoaderState();
}

class _SkeletonLoaderState extends State<_SkeletonLoader>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: AnimationDuration.ultra,
      vsync: this,
    );
    _animation =
        Tween<double>(
          begin: AnimationValues.shimmerBegin,
          end: AnimationValues.shimmerEnd,
        ).animate(
          CurvedAnimation(
            parent: _controller,
            curve: AnimationCurves.easeInOut,
          ),
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
      _controller.repeat();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        borderRadius: widget.borderRadius,
        color: context.conduitTheme.shimmerBase,
      ),
      child: AnimatedBuilder(
        animation: _animation,
        builder: (context, child) {
          return Container(
            decoration: BoxDecoration(
              borderRadius: widget.borderRadius,
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  Colors.transparent,
                  context.conduitTheme.shimmerHighlight,
                  Colors.transparent,
                ],
                stops: [
                  (_animation.value - 0.3).clamp(0.0, 1.0),
                  _animation.value.clamp(0.0, 1.0),
                  (_animation.value + 0.3).clamp(0.0, 1.0),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ListItemSkeleton extends StatelessWidget {
  final bool showAvatar;
  final int lines;

  const _ListItemSkeleton({required this.showAvatar, required this.lines});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.xs,
      ),
      child: Row(
        children: [
          if (showAvatar) ...[
            ConduitLoading.skeleton(
              width: TouchTarget.minimum,
              height: TouchTarget.minimum,
              borderRadius: BorderRadius.circular(AppBorderRadius.xl),
            ),
            const SizedBox(width: Spacing.xs),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: List.generate(lines, (index) {
                return Padding(
                  padding: EdgeInsets.only(
                    bottom: index < lines - 1 ? Spacing.sm : 0,
                  ),
                  child: ConduitLoading.skeleton(
                    width: index == lines - 1 ? 150 : double.infinity,
                    height: index == 0 ? 16 : 14,
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }
}

/// Loading state wrapper for async operations
class LoadingStateWrapper<T> extends StatelessWidget {
  final AsyncValue<T> asyncValue;
  final Widget Function(T data) builder;
  final Widget? loadingWidget;
  final Widget Function(Object error, StackTrace stackTrace)? errorBuilder;
  final bool showLoadingOverlay;

  const LoadingStateWrapper({
    super.key,
    required this.asyncValue,
    required this.builder,
    this.loadingWidget,
    this.errorBuilder,
    this.showLoadingOverlay = false,
  });

  @override
  Widget build(BuildContext context) {
    return asyncValue.when(
      data: builder,
      loading: () => showLoadingOverlay
          ? ConduitLoading.overlay(
              message: AppLocalizations.of(context)!.loadingContent,
            )
          : loadingWidget ??
                ConduitLoading.primary(
                  message: AppLocalizations.of(context)!.loadingContent,
                ),
      error: (error, stackTrace) {
        if (errorBuilder != null) {
          return errorBuilder!(error, stackTrace);
        }

        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Platform.isIOS
                    ? CupertinoIcons.exclamationmark_triangle
                    : Icons.error_outline,
                size: IconSize.xxl,
                color: context.conduitTheme.error,
              ),
              const SizedBox(height: Spacing.md),
              Text(
                AppLocalizations.of(context)!.errorMessage,
                style: AppTypography.headlineSmallStyle.copyWith(
                  color: context.conduitTheme.textSecondary,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: Spacing.sm),
              Text(
                error.toString(),
                style: AppTypography.bodySmallStyle.copyWith(
                  color: context.conduitTheme.textSecondary,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Button with loading state
class LoadingButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final Widget child;
  final bool isLoading;
  final bool isPrimary;

  const LoadingButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.isLoading = false,
    this.isPrimary = true,
  });

  @override
  Widget build(BuildContext context) {
    return AdaptiveButton.child(
      onPressed: isLoading ? null : onPressed,
      color: isPrimary ? context.conduitTheme.buttonPrimary : null,
      style: AdaptiveButtonStyle.filled,
      child: isLoading ? ConduitLoading.button(context: context) : child,
    );
  }
}

/// Refresh indicator with Conduit styling.
///
/// Uses platform-appropriate refresh controls:
/// - iOS: Native Cupertino-style refresh control (when child is CustomScrollView)
/// - Android/Other: Material RefreshIndicator
///
/// Set [edgeOffset] to position the indicator below an app bar or other
/// overlay. For example, use `MediaQuery.of(context).padding.top + kToolbarHeight`
/// to position below a transparent/floating app bar.
///
/// Note: On iOS with a CustomScrollView child, [edgeOffset] is ignored since
/// CupertinoSliverRefreshControl naturally positions itself based on scroll
/// content. The scroll view's existing padding should handle app bar clearance.
class ConduitRefreshIndicator extends StatelessWidget {
  final Widget child;
  final Future<void> Function() onRefresh;

  /// The distance from the top of the scroll view where the refresh indicator
  /// will appear. Useful for positioning below a floating/transparent app bar.
  ///
  /// Note: This is only effective on Android/non-iOS platforms, or on iOS when
  /// the child is not a CustomScrollView. For iOS with CustomScrollView, the
  /// refresh control naturally positions based on scroll content.
  final double edgeOffset;

  const ConduitRefreshIndicator({
    super.key,
    required this.child,
    required this.onRefresh,
    this.edgeOffset = 0.0,
  });

  @override
  Widget build(BuildContext context) {
    // On iOS, try to use CupertinoSliverRefreshControl for native feel
    // when the child is directly a CustomScrollView
    if (Platform.isIOS && child is CustomScrollView) {
      final csv = child as CustomScrollView;
      return CustomScrollView(
        key: csv.key,
        controller: csv.controller,
        scrollDirection: csv.scrollDirection,
        reverse: csv.reverse,
        primary: csv.primary,
        physics: csv.physics,
        shrinkWrap: csv.shrinkWrap,
        cacheExtent: csv.cacheExtent,
        keyboardDismissBehavior: csv.keyboardDismissBehavior,
        clipBehavior: csv.clipBehavior,
        center: csv.center,
        anchor: csv.anchor,
        semanticChildCount: csv.semanticChildCount,
        dragStartBehavior: csv.dragStartBehavior,
        restorationId: csv.restorationId,
        slivers: [
          // CupertinoSliverRefreshControl naturally positions itself based on
          // scroll content; the scroll view's existing padding handles app bar
          // clearance, so no edgeOffset adjustment is needed here.
          CupertinoSliverRefreshControl(onRefresh: onRefresh),
          ...csv.slivers,
        ],
      );
    }

    // For Android, other platforms, or when child is not a CustomScrollView,
    // use Material RefreshIndicator which works with any scrollable
    return RefreshIndicator(
      onRefresh: onRefresh,
      color: context.conduitTheme.buttonPrimary,
      backgroundColor: context.conduitTheme.surfaceBackground,
      edgeOffset: edgeOffset,
      child: child,
    );
  }
}

// ---------------------------------------------------------------------------
// From improved_loading_states.dart
// ---------------------------------------------------------------------------

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
class ImprovedLoadingButton extends StatefulWidget {
  final String text;
  final VoidCallback? onPressed;
  final bool isLoading;
  final bool isDestructive;
  final bool isSecondary;
  final IconData? icon;
  final double? width;
  final bool isFullWidth;
  final bool isCompact;

  const ImprovedLoadingButton({
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
  State<ImprovedLoadingButton> createState() => _ImprovedLoadingButtonState();
}

class _ImprovedLoadingButtonState extends State<ImprovedLoadingButton> {
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
                color: context.conduitTheme.textSecondary.withValues(
                  alpha: 0.6,
                ),
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
