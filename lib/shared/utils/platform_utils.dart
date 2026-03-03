import 'package:flutter/services.dart';
import 'dart:io' show Platform;

/// Platform-specific utilities for enhanced user experience.
///
/// Provides convenience methods for triggering haptic feedback
/// on supported platforms (iOS and Android).
class PlatformUtils {
  PlatformUtils._();

  /// Whether the current device supports haptic feedback.
  static bool get supportsHaptics =>
      Platform.isIOS || Platform.isAndroid;

  /// Trigger light haptic feedback.
  static void lightHaptic() {
    if (supportsHaptics) {
      HapticFeedback.lightImpact();
    }
  }

  /// Trigger medium haptic feedback.
  ///
  /// Uses medium impact on iOS; falls back to light impact on
  /// Android where medium is not always distinguishable.
  static void mediumHaptic() {
    if (supportsHaptics && Platform.isIOS) {
      HapticFeedback.mediumImpact();
    } else if (Platform.isAndroid) {
      HapticFeedback.lightImpact();
    }
  }

  /// Trigger heavy haptic feedback.
  ///
  /// Uses heavy impact on iOS; falls back to a vibration on
  /// Android.
  static void heavyHaptic() {
    if (supportsHaptics && Platform.isIOS) {
      HapticFeedback.heavyImpact();
    } else if (Platform.isAndroid) {
      HapticFeedback.vibrate();
    }
  }

  /// Trigger selection haptic feedback.
  static void selectionHaptic() {
    if (supportsHaptics) {
      HapticFeedback.selectionClick();
    }
  }
}
