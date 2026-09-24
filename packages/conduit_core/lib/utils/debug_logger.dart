import 'package:conduit_core/conduit_core.dart';

/// Centralized debug logging utility for the entire app.
///
/// Messages are rendered in a compact `PREFIX[scope] message key=value` format
/// to keep Flutter's debug console readable while still providing
/// machine-friendly key/value pairs for quick scanning.
///
/// Formatting lives here; *destination* does not. The Flutter app
/// sends records to `debugPrint`, the `conduitd` sidecar to rotating files
/// under `userData/logs` — it has no attached console, and "Export
/// diagnostics" needs something to zip.
class DebugLogger {
  /// Discards records until a host installs a real sink, so a core object
  /// constructed outside an app still runs. Logging is never load-bearing.
  static LogSink _sink = const NullLogSink();

  /// Installed once at startup: `main.dart` for the app,
  /// `test/flutter_test_config.dart` for tests, bootstrap for the daemon.
  static set sink(LogSink value) => _sink = value;

  /// Whether records would go anywhere. Callers can skip building expensive
  /// messages; this is what the old `kDebugMode` constant gated.
  static bool get isEnabled => _sink.isVerbose;

  /// Log debug information.
  static void log(String message, {String? scope, Map<String, Object?>? data}) {
    _emit(_LogCategory.debug, message, scope: scope, data: data);
  }

  /// Log errors with optional error objects and stack traces.
  static void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? scope,
    Map<String, Object?>? data,
  }) {
    _emit(
      _LogCategory.error,
      message,
      scope: scope,
      data: data,
      error: error,
      stackTrace: stackTrace,
    );
  }

  /// Log warnings.
  static void warning(
    String message, {
    String? scope,
    Map<String, Object?>? data,
  }) {
    _emit(_LogCategory.warning, message, scope: scope, data: data);
  }

  /// Log informational messages.
  static void info(
    String message, {
    String? scope,
    Map<String, Object?>? data,
  }) {
    _emit(_LogCategory.info, message, scope: scope, data: data);
  }

  /// Log navigation events.
  static void navigation(
    String message, {
    String? scope,
    Map<String, Object?>? data,
  }) {
    _emit(
      _LogCategory.navigation,
      message,
      scope: _mergeScope('nav', scope),
      data: data,
    );
  }

  /// Log authentication events.
  static void auth(
    String message, {
    String? scope,
    Map<String, Object?>? data,
  }) {
    _emit(
      _LogCategory.auth,
      message,
      scope: _mergeScope('auth', scope),
      data: data,
    );
  }

  /// Log streaming events.
  static void stream(
    String message, {
    String? scope,
    Map<String, Object?>? data,
  }) {
    _emit(
      _LogCategory.stream,
      message,
      scope: _mergeScope('stream', scope),
      data: data,
    );
  }

  /// Log validation events.
  static void validation(
    String message, {
    String? scope,
    Map<String, Object?>? data,
  }) {
    _emit(
      _LogCategory.validation,
      message,
      scope: _mergeScope('validation', scope),
      data: data,
    );
  }

  /// Log storage events.
  static void storage(
    String message, {
    String? scope,
    Map<String, Object?>? data,
  }) {
    _emit(
      _LogCategory.storage,
      message,
      scope: _mergeScope('storage', scope),
      data: data,
    );
  }

  /// Bridge legacy debugPrint messages onto the structured logger.
  static void fromLegacy(String message, {String? scope}) {
    final trimmed = message.trim();
    if (trimmed.isEmpty) {
      return;
    }

    var working = _stripLegacyDecorations(trimmed);
    var category = _LogCategory.debug;

    String stripPrefix(String prefix) {
      working = working.substring(prefix.length).trimLeft();
      return working;
    }

    final lower = working.toLowerCase();
    if (lower.startsWith('error:')) {
      category = _LogCategory.error;
      stripPrefix('error:');
    } else if (lower.startsWith('warning:')) {
      category = _LogCategory.warning;
      stripPrefix('warning:');
    } else if (lower.startsWith('warn:')) {
      category = _LogCategory.warning;
      stripPrefix('warn:');
    } else if (lower.startsWith('info:')) {
      category = _LogCategory.info;
      stripPrefix('info:');
    } else if (lower.startsWith('debug:')) {
      category = _LogCategory.debug;
      stripPrefix('debug:');
    }

    if (working.isEmpty) {
      return;
    }

    _emit(category, working, scope: scope);
  }

  static void _emit(
    _LogCategory category,
    String message, {
    String? scope,
    Map<String, Object?>? data,
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (!_sink.isVerbose) {
      return;
    }

    final buffer = StringBuffer(_prefixes[category] ?? 'DBG');

    final effectiveScope = scope?.trim();
    if (effectiveScope != null && effectiveScope.isNotEmpty) {
      buffer
        ..write('[')
        ..write(effectiveScope)
        ..write(']');
    }

    final trimmedMessage = message.trim();
    if (trimmedMessage.isNotEmpty) {
      buffer
        ..write(' ')
        ..write(trimmedMessage);
    }

    final formattedData = _formatData(data);
    if (formattedData.isNotEmpty) {
      buffer
        ..write(' ')
        ..write(formattedData);
    }

    if (error != null) {
      buffer
        ..write(' err=')
        ..write(_stringify(error));
    }

    if (stackTrace != null) {
      buffer
        ..write(' stack=')
        ..write(_stringify(stackTrace));
    }

    // The line is already fully composed, scope and error included, so the
    // sink receives it as-is and only decides where it goes.
    _sink.write(_levels[category] ?? LogLevel.debug, buffer.toString());
  }

  static String _formatData(Map<String, Object?>? data) {
    if (data == null || data.isEmpty) {
      return '';
    }

    return data.entries
        .map(
          (entry) => '${entry.key}=${_stringify(entry.value, maxLength: 48)}',
        )
        .join(' ');
  }

  static String _stringify(Object? value, {int maxLength = 96}) {
    if (value == null) {
      return 'null';
    }

    var text = value.toString().replaceAll(RegExp(r'\s+'), ' ');
    if (text.length <= maxLength) {
      return text;
    }
    return '${text.substring(0, maxLength - 1)}…';
  }

  static String? _mergeScope(String base, String? scope) {
    final trimmed = scope?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return base;
    }
    return '$base/$trimmed';
  }
}

enum _LogCategory {
  debug,
  info,
  warning,
  error,
  navigation,
  auth,
  stream,
  validation,
  storage,
}

/// Maps the app's fine-grained categories onto the sink's four severities.
///
/// The categories exist to make the console scannable (`NAV`, `AUT`, `STR`);
/// a file or a remote sink only needs to know how serious a record is.
const Map<_LogCategory, LogLevel> _levels = <_LogCategory, LogLevel>{
  _LogCategory.debug: LogLevel.debug,
  _LogCategory.info: LogLevel.info,
  _LogCategory.warning: LogLevel.warning,
  _LogCategory.error: LogLevel.error,
  _LogCategory.navigation: LogLevel.debug,
  _LogCategory.auth: LogLevel.debug,
  _LogCategory.stream: LogLevel.debug,
  _LogCategory.validation: LogLevel.debug,
  _LogCategory.storage: LogLevel.debug,
};

const Map<_LogCategory, String> _prefixes = <_LogCategory, String>{
  _LogCategory.debug: 'DBG',
  _LogCategory.info: 'INF',
  _LogCategory.warning: 'WRN',
  _LogCategory.error: 'ERR',
  _LogCategory.navigation: 'NAV',
  _LogCategory.auth: 'AUT',
  _LogCategory.stream: 'STR',
  _LogCategory.validation: 'VAL',
  _LogCategory.storage: 'STO',
};

String _stripLegacyDecorations(String value) {
  var text = value;
  // Remove common emoji and decoration prefixes.
  const decorations = <String>['🔍', '✅', '❌', '🟡', '⚠️', 'DEBUG -'];
  for (final decoration in decorations) {
    if (text.startsWith(decoration)) {
      text = text.substring(decoration.length).trimLeft();
    }
  }
  if (text.startsWith('DEBUG:')) {
    text = text.substring(6).trimLeft();
  }
  return text;
}
