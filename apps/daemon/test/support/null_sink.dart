import 'dart:io';

/// Swallows daemon log output so a test run stays readable.
///
/// `noSuchMethod` covers the rest of [IOSink]: the log only ever calls
/// `write` and `writeln`, and stubbing the other fifteen members by hand
/// would be noise that hides that fact.
class NullSink implements IOSink {
  @override
  void writeln([Object? object = '']) {}

  @override
  void write(Object? object) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
