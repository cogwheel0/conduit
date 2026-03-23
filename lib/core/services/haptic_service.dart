import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_vibrate/flutter_vibrate.dart';

/// App-wide haptics helper backed by `flutter_vibrate` on mobile.
///
/// Falls back to Flutter's built-in `HapticFeedback` APIs when the plugin is
/// unavailable, such as in tests.
class ConduitHaptics {
  ConduitHaptics._();

  static const MethodChannel _pluginChannel = MethodChannel('vibrate');

  /// Whether the current target supports mobile haptics.
  static bool get supportsHaptics =>
      !kIsWeb &&
      switch (defaultTargetPlatform) {
        TargetPlatform.android || TargetPlatform.iOS => true,
        _ => false,
      };

  /// Triggers a light impact haptic.
  static Future<void> lightImpact() =>
      _feedback(FeedbackType.light, HapticFeedback.lightImpact);

  /// Triggers a medium impact haptic.
  static Future<void> mediumImpact() =>
      _feedback(FeedbackType.medium, HapticFeedback.mediumImpact);

  /// Triggers a heavy impact haptic.
  static Future<void> heavyImpact() =>
      _feedback(FeedbackType.heavy, HapticFeedback.heavyImpact);

  /// Triggers a selection haptic.
  static Future<void> selectionClick() =>
      _feedback(FeedbackType.selection, HapticFeedback.selectionClick);

  /// Triggers a success haptic.
  static Future<void> success() =>
      _feedback(FeedbackType.success, HapticFeedback.lightImpact);

  /// Triggers a warning haptic.
  static Future<void> warning() =>
      _feedback(FeedbackType.warning, HapticFeedback.mediumImpact);

  /// Triggers an error haptic.
  static Future<void> error() =>
      _feedback(FeedbackType.error, HapticFeedback.heavyImpact);

  /// Triggers a general-purpose vibration.
  static Future<void> vibrate() async {
    if (!supportsHaptics) {
      return;
    }

    try {
      if (await Vibrate.canVibrate) {
        await Vibrate.vibrate();
        return;
      }
    } on MissingPluginException {
      // Fall through to Flutter's built-in haptics for tests.
    } on PlatformException catch (error, stackTrace) {
      _logFailure('Failed to trigger plugin vibration', error, stackTrace);
    }

    await _fallback('vibration', HapticFeedback.vibrate);
  }

  static Future<void> _feedback(
    FeedbackType type,
    Future<void> Function() fallback,
  ) async {
    if (!supportsHaptics) {
      return;
    }

    try {
      await _pluginChannel.invokeMethod<void>(_pluginMethod(type));
      return;
    } on MissingPluginException {
      // Fall through to Flutter's built-in haptics for tests.
    } on PlatformException catch (error, stackTrace) {
      _logFailure('Failed to trigger plugin haptic', error, stackTrace);
    }

    await _fallback('haptic fallback', fallback);
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

  static String _pluginMethod(FeedbackType type) => switch (type) {
    FeedbackType.success => 'success',
    FeedbackType.error => 'error',
    FeedbackType.warning => 'warning',
    FeedbackType.selection => 'selection',
    FeedbackType.impact => 'impact',
    FeedbackType.heavy => 'heavy',
    FeedbackType.medium => 'medium',
    FeedbackType.light => 'light',
  };

  static void _logFailure(
    String message,
    Object error,
    StackTrace stackTrace,
  ) {
    developer.log(
      message,
      name: 'ConduitHaptics',
      level: 900,
      error: error,
      stackTrace: stackTrace,
    );
  }
}
