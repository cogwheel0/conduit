import 'dart:io';

/// Everything the daemon prints goes to stderr.
///
/// stdout is reserved for the one `{"ready":true,"port":N}` line Electron
/// parses at startup; a stray `print` there would desynchronize the handshake
/// and look like a daemon that never came up.
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

  void debug(String message) => _write('debug', message);
  void info(String message) => _write('info', message);
  void warn(String message) => _write('warn', message);
  void error(String message, [Object? err, StackTrace? stack]) {
    _write('error', err == null ? message : '$message: $err');
    if (stack != null && _threshold == 0) _sink.writeln(stack);
  }

  void _write(String level, String message) {
    if (_levels[level]! < _threshold) return;
    _sink.writeln(
      '${DateTime.now().toUtc().toIso8601String()} [$level] conduitd: '
      '$message',
    );
  }
}
