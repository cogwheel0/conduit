import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// App-wide haptics helper backed by `gaimon` on mobile.
///
/// Falls back to Flutter's built-in `HapticFeedback` APIs when the plugin is
/// unavailable, such as in tests.
class ConduitHaptics {
  ConduitHaptics._();

  // `gaimon`'s public Dart helpers do not await their platform calls, which
  // makes fallback handling harder in tests. Await the channel directly here.
  static const MethodChannel _pluginChannel = MethodChannel('gaimon');

  /// Whether the current target supports mobile haptics.
  static bool get supportsHaptics =>
      !kIsWeb &&
      switch (defaultTargetPlatform) {
        TargetPlatform.android || TargetPlatform.iOS => true,
        _ => false,
      };

  /// Triggers a light impact haptic.
  static Future<void> lightImpact() =>
      _feedback('light', HapticFeedback.lightImpact);

  /// Triggers a medium impact haptic.
  static Future<void> mediumImpact() =>
      _feedback('medium', HapticFeedback.mediumImpact);

  /// Triggers a heavy impact haptic.
  static Future<void> heavyImpact() =>
      _feedback('heavy', HapticFeedback.heavyImpact);

  /// Triggers a selection haptic.
  static Future<void> selectionClick() =>
      _feedback('selection', HapticFeedback.selectionClick);

  /// Triggers a success haptic.
  static Future<void> success() =>
      _feedback('success', HapticFeedback.lightImpact);

  /// Triggers a warning haptic.
  static Future<void> warning() =>
      _feedback('warning', HapticFeedback.mediumImpact);

  /// Triggers an error haptic.
  static Future<void> error() => _feedback('error', HapticFeedback.heavyImpact);

  /// Triggers a general-purpose vibration.
  static Future<void> vibrate() async {
    if (!supportsHaptics) {
      return;
    }

    await _fallback('vibration', HapticFeedback.vibrate);
  }

  static Future<void> _feedback(
    String pluginMethod,
    Future<void> Function() fallback,
  ) async {
    if (!supportsHaptics) {
      return;
    }

    try {
      await _pluginChannel.invokeMethod<void>(pluginMethod);
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
