import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../shared/theme/theme_extensions.dart';

part 'animation_service.g.dart';

/// Service for managing animations with performance optimization and accessibility
class AnimationService {
  /// Get optimized animation duration based on context and settings
  static Duration getOptimizedDuration(
    BuildContext context,
    Duration defaultDuration, {
    bool respectReducedMotion = true,
  }) {
    if (respectReducedMotion && MediaQuery.of(context).disableAnimations) {
      return Duration.zero;
    }

    // Optimize for 60fps - keep animations under 300ms for snappy feel
    final optimizedDuration = Duration(
      milliseconds: (defaultDuration.inMilliseconds * 0.8).round().clamp(
        100,
        300,
      ),
    );

    return optimizedDuration;
  }

  /// Get optimized curve for smooth 60fps animations
  static Curve getOptimizedCurve({Curve defaultCurve = Curves.easeInOut}) {
    // Use curves that are optimized for mobile performance
    final curveType = defaultCurve.runtimeType.toString();

    // Replace performance-heavy curves with lighter alternatives
    if (curveType.contains('Bounce')) {
      return Curves.easeInOutQuart; // Replace heavy bounce with smooth curve
    } else if (curveType.contains('Elastic')) {
      return Curves.easeInOutBack; // Lighter alternative to elastic
    } else if (defaultCurve == Curves.easeInOut) {
      return Curves.easeInOutCubic; // Better performance than default
    }

    return defaultCurve;
  }

  /// Create performant fade transition
  static Widget createOptimizedFadeTransition({
    required Widget child,
    required Animation<double> animation,
    Duration? duration,
  }) {
    return FadeTransition(opacity: animation, child: child);
  }

  /// Create performant slide transition
  static Widget createOptimizedSlideTransition({
    required Widget child,
    required Animation<Offset> animation,
    Duration? duration,
  }) {
    return SlideTransition(position: animation, child: child);
  }

  /// Create performant scale transition
  static Widget createOptimizedScaleTransition({
    required Widget child,
    required Animation<double> animation,
    Duration? duration,
  }) {
    return ScaleTransition(scale: animation, child: child);
  }

  /// Create optimized page transition
  static PageRouteBuilder createOptimizedPageRoute({
    required Widget page,
    Duration? transitionDuration,
    PageTransitionType type = PageTransitionType.slide,
  }) {
    return PageRouteBuilder(
      pageBuilder: (context, animation, secondaryAnimation) => page,
      transitionDuration:
          transitionDuration ?? const Duration(milliseconds: 250),
      reverseTransitionDuration:
          transitionDuration ?? const Duration(milliseconds: 200),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final optimizedCurve = getOptimizedCurve();
        final curvedAnimation = CurvedAnimation(
          parent: animation,
          curve: optimizedCurve,
        );

        switch (type) {
          case PageTransitionType.fade:
            return FadeTransition(opacity: curvedAnimation, child: child);
          case PageTransitionType.slide:
            return SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(1.0, 0.0),
                end: Offset.zero,
              ).animate(curvedAnimation),
              child: child,
            );
          case PageTransitionType.scale:
            return ScaleTransition(
              scale: Tween<double>(
                begin: 0.8,
                end: 1.0,
              ).animate(curvedAnimation),
              child: FadeTransition(opacity: curvedAnimation, child: child),
            );
        }
      },
    );
  }

  /// Create staggered animation for lists
  static Widget createStaggeredListAnimation({
    required Widget child,
    required int index,
    Duration? delay,
    Duration? duration,
  }) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: duration ?? const Duration(milliseconds: 200),
      curve: getOptimizedCurve(),
      builder: (context, value, child) {
        return Transform.translate(
          offset: Offset(0, 20 * (1 - value)),
          child: Opacity(opacity: value, child: child),
        );
      },
      child: child,
    );
  }

  /// Create performant shimmer animation
  static Widget createOptimizedShimmer({
    required Widget child,
    Duration? duration,
    Color? baseColor,
    Color? highlightColor,
  }) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: duration ?? const Duration(milliseconds: 1500),
      curve: Curves.linear,
      builder: (context, value, child) {
        return ShaderMask(
          shaderCallback: (bounds) {
            return LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                baseColor ?? context.qonduitTheme.shimmerBase,
                highlightColor ?? context.qonduitTheme.shimmerHighlight,
                baseColor ?? context.qonduitTheme.shimmerBase,
              ],
              stops: [0.0, value, 1.0],
            ).createShader(bounds);
          },
          child: child,
        );
      },
      child: child,
    );
  }

  /// Create optimized rotation animation
  static Widget createOptimizedRotation({
    required Widget child,
    required Animation<double> animation,
    double turns = 1.0,
  }) {
    return RotationTransition(
      turns: Tween<double>(begin: 0, end: turns).animate(animation),
      child: child,
    );
  }

  /// Check if device can handle complex animations
  static bool canHandleComplexAnimations(BuildContext context) {
    // Simple heuristic based on screen density and platform
    final devicePixelRatio = MediaQuery.of(context).devicePixelRatio;
    final screenSize = MediaQuery.of(context).size;
    final totalPixels = screenSize.width * screenSize.height * devicePixelRatio;

    // If total pixels exceed 4M, assume it's a high-end device
    return totalPixels > 4000000;
  }

  /// Create adaptive animation based on device capability
  static Widget createAdaptiveAnimation({
    required BuildContext context,
    required Widget child,
    required Widget Function(Widget) complexAnimation,
    required Widget Function(Widget) simpleAnimation,
  }) {
    if (canHandleComplexAnimations(context) &&
        !MediaQuery.of(context).disableAnimations) {
      return complexAnimation(child);
    } else {
      return simpleAnimation(child);
    }
  }
}

/// Enum for page transition types
enum PageTransitionType { fade, slide, scale }

/// Provider for reduced motion preference
@Riverpod(keepAlive: true)
class ReducedMotion extends _$ReducedMotion {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

/// Provider for animation performance settings
final animationPerformanceProvider =
    NotifierProvider<AnimationPerformanceNotifier, AnimationPerformance>(
      AnimationPerformanceNotifier.new,
    );

class AnimationPerformanceNotifier extends Notifier<AnimationPerformance> {
  @override
  AnimationPerformance build() => AnimationPerformance.adaptive;

  void set(AnimationPerformance performance) => state = performance;
}

/// Animation performance levels
enum AnimationPerformance {
  high, // All animations enabled
  adaptive, // Adaptive based on device
  reduced, // Simplified animations
  minimal, // Essential animations only
}

/// Provider for managing animation settings
final animationSettingsProvider =
    NotifierProvider<AnimationSettingsNotifier, AnimationSettings>(
      AnimationSettingsNotifier.new,
    );

class AnimationSettings {
  final bool reduceMotion;
  final AnimationPerformance performance;
  final double animationSpeed;

  const AnimationSettings({
    this.reduceMotion = false,
    this.performance = AnimationPerformance.adaptive,
    this.animationSpeed = 1.0,
  });

  AnimationSettings copyWith({
    bool? reduceMotion,
    AnimationPerformance? performance,
    double? animationSpeed,
  }) {
    return AnimationSettings(
      reduceMotion: reduceMotion ?? this.reduceMotion,
      performance: performance ?? this.performance,
      animationSpeed: animationSpeed ?? this.animationSpeed,
    );
  }
}

class AnimationSettingsNotifier extends Notifier<AnimationSettings> {
  @override
  AnimationSettings build() => const AnimationSettings();

  void setReduceMotion(bool reduce) {
    state = state.copyWith(reduceMotion: reduce);
  }

  void setPerformance(AnimationPerformance performance) {
    state = state.copyWith(performance: performance);
  }

  void setAnimationSpeed(double speed) {
    state = state.copyWith(animationSpeed: speed.clamp(0.5, 2.0));
  }

  Duration adjustDuration(Duration baseDuration) {
    if (state.reduceMotion) return Duration.zero;

    final adjustedMs = (baseDuration.inMilliseconds / state.animationSpeed)
        .round();
    return Duration(milliseconds: adjustedMs);
  }
}
