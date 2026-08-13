import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// App-wide helper for Flutter's system haptics on supported mobile platforms.
class ConduitHaptics {
  ConduitHaptics._();

  /// Whether the current target supports mobile haptics.
  static bool get supportsHaptics =>
      !kIsWeb &&
      switch (defaultTargetPlatform) {
        TargetPlatform.android || TargetPlatform.iOS => true,
        _ => false,
      };

  /// Triggers a light impact haptic.
  static Future<void> lightImpact() => _feedback(HapticFeedback.lightImpact);

  /// Triggers a medium impact haptic.
  static Future<void> mediumImpact() => _feedback(HapticFeedback.mediumImpact);

  /// Triggers a heavy impact haptic.
  static Future<void> heavyImpact() => _feedback(HapticFeedback.heavyImpact);

  /// Triggers a selection haptic.
  static Future<void> selectionClick() =>
      _feedback(HapticFeedback.selectionClick);

  /// Triggers a success haptic.
  static Future<void> success() =>
      _feedback(HapticFeedback.successNotification);

  /// Triggers a warning haptic.
  static Future<void> warning() =>
      _feedback(HapticFeedback.warningNotification);

  /// Triggers an error haptic.
  static Future<void> error() => _feedback(HapticFeedback.errorNotification);

  /// Triggers a general-purpose vibration.
  static Future<void> vibrate() async {
    if (!supportsHaptics) {
      return;
    }

    await _fallback('vibration', HapticFeedback.vibrate);
  }

  static Future<void> _feedback(Future<void> Function() callback) async {
    if (!supportsHaptics) {
      return;
    }
    await _fallback('system haptic', callback);
  }

  static Future<void> _fallback(
    String action,
    Future<void> Function() callback,
  ) async {
    try {
      await callback();
    } on MissingPluginException {
      // Ignore when no platform haptics channel is available.
    } on PlatformException catch (error, stackTrace) {
      _logFailure('Failed to trigger $action', error, stackTrace);
    }
  }

  static void _logFailure(String message, Object error, StackTrace stackTrace) {
    developer.log(
      message,
      name: 'ConduitHaptics',
      level: 900,
      error: error,
      stackTrace: stackTrace,
    );
  }
}
