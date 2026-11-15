import 'dart:io';

import 'package:conduit_core/ports/log_sink.dart';

import 'daemon_zone.dart';
import 'log_file.dart';
import 'redact.dart';

/// Everything the daemon prints goes to stderr, and, once [attachFile] has
/// run, to its own rotating log as well.
///
/// stdout is reserved for the one `{"ready":true,"port":N}` line the app
/// parses at startup; a stray `print` there would desynchronize the
/// handshake and look like a daemon that never came up.
///
/// Every line is scrubbed of credentials ([redactSecrets]) before it goes
/// anywhere, both those the rules recognise and the bootstrap secrets
/// registered with [redactExactly].
class DaemonLog {
  DaemonLog({this.level = 'info', IOSink? sink})
    : _sink = sink ?? stderr,
      _threshold = _levels[level] ?? _levels['info']!;

  static const Map<String, int> _levels = <String, int>{
    'debug': 0,
    'info': 1,
    'warn': 2,
    'error': 3,
  };

  final String level;
  final IOSink _sink;
  final int _threshold;
  RotatingLogFile? _file;
  final Set<String> _secrets = <String>{};

  /// The log on disk, if one is attached.
  RotatingLogFile? get file => _file;

  /// Whether debug lines are written; callers can skip building them.
  bool get isDebug => _threshold == 0;

  /// Also writes every line to [file] from now on.
  void attachFile(RotatingLogFile file) => _file = file;

  /// Secrets known by value that must never appear in a line, however they
  /// got into it. Short strings are ignored: they would blank out ordinary
  /// words.
  void redactExactly(Iterable<String> secrets) =>
      _secrets.addAll(secrets.where((secret) => secret.length >= 16));

  Future<void> close() async {
    final file = _file;
    _file = null;
    await file?.close();
  }

  void debug(String message) => _write('debug', message);
  void info(String message) => _write('info', message);
  void warn(String message) => _write('warn', message);
  void error(String message, [Object? err, StackTrace? stack]) {
    _write('error', err == null ? message : '$message: $err');
    if (stack != null && _threshold == 0) _emit(stack.toString());
  }

  /// An asynchronous error nothing handled, which the daemon survived (see
  /// [runDaemonZone]). Its stack is written whatever the level, because
  /// that is the only way to find the code that dropped it; like every
  /// line, it is scrubbed of credentials first.
  void stray(Object err, StackTrace stack) {
    _write('error', 'unhandled async error, still serving: $err');
    _emit(trimStack(stack));
  }

  void _write(String level, String message) {
    if (_levels[level]! < _threshold) return;
    _emit(
      '${DateTime.now().toUtc().toIso8601String()} [$level] conduitd: '
      '$message',
    );
  }

  void _emit(String line) {
    final clean = redactSecrets(line, exact: _secrets);
    _sink.writeln(clean);
    _file?.writeln(clean);
  }
}

/// Where the core's `DebugLogger` writes in the daemon: the daemon's log.
///
/// Verbose, because `DebugLogger` drops every record, errors included, when
/// its sink is not; [DaemonLog]'s own level then decides what is kept.
class DaemonLogSink implements LogSink {
  const DaemonLogSink(this._log);

  final DaemonLog _log;

  @override
  bool get isVerbose => true;

  @override
  void write(
    LogLevel level,
    String message, {
    String? scope,
    Object? error,
    StackTrace? stackTrace,
  }) {
    try {
      switch (level) {
        case LogLevel.debug:
          _log.debug('core: $message');
        case LogLevel.info:
          _log.info('core: $message');
        case LogLevel.warning:
          _log.warn('core: $message');
        case LogLevel.error:
          _log.error('core: $message', null, stackTrace);
      }
    } on Object {
      // A logger must never throw from the error path it is reporting.
    }
  }
}
