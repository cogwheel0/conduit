@TestOn('vm')
library;

import 'dart:convert';

import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

const String _token = 'cJkVQ1mEo3nT7pZs9YbXwF2gH5LdRaUvNi0KqMtBxCe';
final String _masterKey = base64.encode(List<int>.filled(32, 7));

String _line({
  String? sessionToken,
  String? masterKey,
  String? userDataDir = '/tmp/conduit',
  String? logLevel,
}) => jsonEncode(<String, Object?>{
  'sessionToken': sessionToken ?? _token,
  'masterKey': masterKey ?? _masterKey,
  'userDataDir': userDataDir,
  'logLevel': ?logLevel,
});

void main() {
  test('parses a well-formed bootstrap line', () {
    final config = BootstrapConfig.parse(_line(logLevel: 'debug'));
    expect(config.sessionToken, _token);
    expect(config.masterKey, _masterKey);
    expect(config.userDataDir, '/tmp/conduit');
    expect(config.logLevel, 'debug');
  });

  test('defaults the log level', () {
    expect(BootstrapConfig.parse(_line()).logLevel, 'info');
  });

  test('rejects a token with too little entropy', () {
    // A truncated token would still "work", which is exactly the failure
    // mode worth refusing: it silently weakens the only guard on the port.
    expect(
      () => BootstrapConfig.parse(_line(sessionToken: 'short')),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects a master key that is not 32 bytes', () {
    expect(
      () => BootstrapConfig.parse(
        _line(masterKey: base64.encode(List<int>.filled(16, 1))),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects a master key that is not base64', () {
    expect(
      () => BootstrapConfig.parse(_line(masterKey: 'not base64!!')),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects missing fields, non-objects and malformed JSON', () {
    expect(
      () => BootstrapConfig.parse(_line(userDataDir: null)),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => BootstrapConfig.parse('["not", "an", "object"]'),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => BootstrapConfig.parse('{not json'),
      throwsA(isA<FormatException>()),
    );
  });

  test('never puts secrets in toString', () {
    final rendered = BootstrapConfig.parse(_line()).toString();
    expect(rendered, contains('/tmp/conduit'));
    expect(rendered, isNot(contains(_token)));
    expect(rendered, isNot(contains(_masterKey)));
  });

  test('readFrom times out rather than hanging on a silent parent', () async {
    // A daemon that blocks forever holding a bound port is worse than one
    // that exits, so the bootstrap read has a deadline.
    await expectLater(
      BootstrapConfig.readFrom(
        const Stream<String>.empty().asBroadcastStream(),
        timeout: const Duration(milliseconds: 50),
      ),
      throwsA(anything),
    );
  });

  test('readFrom accepts the first line of a stream', () async {
    final config = await BootstrapConfig.readFrom(
      Stream<String>.fromIterable(<String>[_line(), 'ignored']),
    );
    expect(config.sessionToken, _token);
  });
}
