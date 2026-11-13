import 'dart:io';

/// Keeps every line the daemon logs, for tests that assert on them.
class LinesSink implements IOSink {
  final List<String> lines = <String>[];

  @override
  void writeln([Object? object = '']) => lines.add('$object');

  @override
  void write(Object? object) => lines.add('$object');

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
