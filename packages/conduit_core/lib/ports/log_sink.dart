/// Severity of a log record, ordered least to most serious.
enum LogLevel { debug, info, warning, error }

/// Where diagnostics go.
///
/// `debugPrint` is a Flutter function and, on desktop, the wrong destination
/// anyway: the daemon has no attached console, so records have to reach
/// rotating files under `userData/logs` that "Export diagnostics" can zip.
///
/// Implementations must be cheap and must never throw — the logger is called
/// from error paths, and a logger that fails there hides the original fault.
abstract interface class LogSink {
  /// True when debug-level records are worth building at all.
  ///
  /// Callers check this before interpolating expensive strings, which is what
  /// `kDebugMode` used to do at the call site.
  bool get isVerbose;

  void write(
    LogLevel level,
    String message, {
    String? scope,
    Object? error,
    StackTrace? stackTrace,
  });
}

/// Discards everything. The default, so a core object constructed without a
/// host still runs — logging is never load-bearing.
class NullLogSink implements LogSink {
  const NullLogSink();

  @override
  bool get isVerbose => false;

  @override
  void write(
    LogLevel level,
    String message, {
    String? scope,
    Object? error,
    StackTrace? stackTrace,
  }) {}
}
