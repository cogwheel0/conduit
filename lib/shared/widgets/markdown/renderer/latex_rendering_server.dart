import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter_tex/flutter_tex.dart';

/// Coordinates startup of the shared MathJax rendering server.
///
/// `flutter_tex` uses a hidden WebView-backed server on mobile and desktop.
/// Starting it during `main()` delays first paint, so the app warms it after
/// startup and lets math widgets await the same shared future when needed.
class LatexRenderingServer {
  LatexRenderingServer._();

  static Future<void>? _startFuture;
  static bool _started = false;
  @visibleForTesting
  static Future<void> Function()? debugStartOverride;
  @visibleForTesting
  static int debugStartInvocationCount = 0;

  /// Whether the renderer has completed startup.
  static bool get isStarted => _started;

  /// Starts the renderer once and returns the in-flight startup future.
  static Future<void> ensureStarted() {
    if (_started) return Future<void>.value();

    final existingFuture = _startFuture;
    if (existingFuture != null) return existingFuture;

    debugStartInvocationCount += 1;
    final future = _start();
    _startFuture = future;
    return future;
  }

  /// Best-effort startup that does not surface errors to the caller.
  static void prewarm() {
    unawaited(
      ensureStarted().catchError((Object error, StackTrace stackTrace) {
        developer.log(
          'Failed to prewarm LaTeX renderer',
          name: 'conduit.markdown.latex',
          error: error,
          stackTrace: stackTrace,
        );
      }),
    );
  }

  static Future<void> _start() async {
    final startOverride = debugStartOverride;
    try {
      if (startOverride != null) {
        await startOverride();
      } else {
        await TeXRenderingServer.start();
      }
      _started = true;
    } catch (error, stackTrace) {
      _startFuture = null;
      developer.log(
        'Failed to start LaTeX renderer',
        name: 'conduit.markdown.latex',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  @visibleForTesting
  static void debugReset() {
    _startFuture = null;
    _started = false;
    debugStartOverride = null;
    debugStartInvocationCount = 0;
  }
}
