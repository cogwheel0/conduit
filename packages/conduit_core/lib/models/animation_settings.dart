/// Animation preferences.
///
/// Pure values — a flag, an enum and a multiplier. They live here rather than
/// beside the animation widgets because `SettingsService` derives them from
/// the user's stored preferences, and a core service reaching into
/// `lib/shared` for a type was pulling the whole theme and localisation tree
/// into the core's dependency closure.
///
/// Nothing here animates anything; the host decides what to do with them.
library;

enum AnimationPerformance {
  high, // All animations enabled
  adaptive, // Adaptive based on device
  reduced, // Simplified animations
  minimal, // Essential animations only
}

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
