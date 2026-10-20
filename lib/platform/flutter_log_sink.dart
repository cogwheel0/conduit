import 'package:conduit_core/conduit_core.dart';
import 'package:flutter/foundation.dart';

/// The Flutter app's [LogSink].
///
/// Keeps `debugPrint` and `kDebugMode` — both Flutter — out of
/// `lib/core/utils/debug_logger.dart`, while preserving exactly what the
/// console showed before: records only in debug builds, one line each,
/// rate-limited by `debugPrint`'s own throttle so a fast stream cannot drop
/// frames.
class FlutterLogSink implements LogSink {
  const FlutterLogSink();

  /// Release builds stay silent, as they always have.
  @override
  bool get isVerbose => kDebugMode;

  @override
  void write(
    LogLevel level,
    String message, {
    String? scope,
    Object? error,
    StackTrace? stackTrace,
  }) {
    // `message` arrives fully composed — DebugLogger already folded in the
    // scope, the key/value data and any error — so this only forwards it.
    debugPrint(message);
  }
}
