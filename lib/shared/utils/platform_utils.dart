import 'dart:async';

import 'package:conduit/core/services/haptic_service.dart';

/// Platform-specific utilities for enhanced user experience.
///
/// Provides convenience methods for triggering haptic feedback
/// on supported platforms (iOS and Android).
class PlatformUtils {
  PlatformUtils._();

  /// Whether the current device supports haptic feedback.
  static bool get supportsHaptics => ConduitHaptics.supportsHaptics;

  /// Trigger light haptic feedback.
  static void lightHaptic() {
    if (supportsHaptics) {
      unawaited(ConduitHaptics.lightImpact());
    }
  }

  /// Trigger medium haptic feedback.
  static void mediumHaptic() {
    if (supportsHaptics) {
      unawaited(ConduitHaptics.mediumImpact());
    }
  }

  /// Trigger heavy haptic feedback.
  static void heavyHaptic() {
    if (supportsHaptics) {
      unawaited(ConduitHaptics.heavyImpact());
    }
  }

  /// Trigger selection haptic feedback.
  static void selectionHaptic() {
    if (supportsHaptics) {
      unawaited(ConduitHaptics.selectionClick());
    }
  }
}
