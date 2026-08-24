import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../utils/debug_logger.dart';

/// Asks the platform to hold the display at its peak refresh rate for the
/// duration of a user interaction.
///
/// ProMotion idles the panel down to 10–40 Hz and only ramps back up
/// reactively after frames start arriving; frame-cadence profiling showed
/// entire drags rendered at a tight ~24 ms (40 Hz) cadence — every frame on
/// time, but at a third of the panel's rate, which reads as streaky text.
/// The iOS side pins an idle CADisplayLink at the panel's maximum while a
/// boost is held (see ios/Runner/DisplayBoostBridge.swift). Android instead
/// requests its peak display mode once at startup (MainActivity), so no
/// boost calls are needed there.
abstract final class DisplayBoost {
  // A/B-verified on device (profile build, cold panel): with the boost
  // disabled, drags after an idle gap were visibly not smooth — the panel
  // ramping from its 40 Hz idle step mid-fling. With it enabled, cadence
  // logs show first drags opening at ≥93% on the 120 Hz slot. This is the
  // load-bearing half of iOS scroll feel; do not remove without repeating
  // the idle-gap experiment.
  static const MethodChannel _channel = MethodChannel(
    'app.cogwheel.conduit/display_boost',
  );

  static bool _unavailable = false;

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS && !_unavailable;

  /// Deliberately not latched: every begin passes through so the native
  /// side can re-arm its leak-guard timeout. A long continuous scroll sends
  /// repeated begins (pointer-down, drag-start), keeping the boost alive
  /// past the native safety window; a single latched begin would let the
  /// guard expire mid-interaction.
  static void begin() {
    if (!_supported) return;
    unawaited(_invoke('begin'));
  }

  static void end() {
    if (!_supported) return;
    unawaited(_invoke('end'));
  }

  static Future<void> _invoke(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } on MissingPluginException {
      // Headless engines (background isolates, tests) have no bridge.
      _unavailable = true;
    } catch (error) {
      DebugLogger.warning(
        'display-boost-failed',
        scope: 'perf',
        data: {'method': method, 'error': error.toString()},
      );
    }
  }
}
