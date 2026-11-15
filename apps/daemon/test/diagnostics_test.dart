@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:conduit_core/ports/log_sink.dart';
import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

import 'support/lines_sink.dart';

/// Every credential below is made up for these tests. The JWT is put
/// together from its parts ({"alg":"HS256"}, {"sub":"test"}, a fake
/// signature), so the source holds no token-shaped text for secret scanners.
final String _jwt = [
  base64Url.encode(utf8.encode('{"alg":"HS256"}')),
  base64Url.encode(utf8.encode('{"sub":"test"}')),
  base64Url.encode(utf8.encode('signature-not-real')),
].map((part) => part.replaceAll('=', '')).join('.');
const String _sessionToken = 'cJkVQ1mEo3nT7pZs9YbXwF2gH5LdRaUvNi0KqMtBxCe';

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('conduitd_diag'));
  tearDown(() => temp.deleteSync(recursive: true));

  group('redactSecrets', () {
    // A run of backslashes inside a quoted value can be read in many ways
    // by a pattern whose alternatives overlap; left open, the run then
    // takes exponential time: here, about half a minute for the earlier
    // pattern, and no time at all for a linear one.
    test('a long unterminated run of backslashes is scrubbed at once', () {
      final run = r'\' * 60;
      expect(redactSecrets('{"cookie":"$run'), isNot(contains('made-up')));
      expect(
        redactSecrets('{"cookie":"$run$run sid=made-up"}'),
        isNot(contains('made-up')),
      );
    });

    test('scrubs the shapes credentials come in', () {
      final cases = <String, String>{
        'Authorization: Bearer abcdefghijklmnop': 'abcdefghijklmnop',
        'sent bearer abcdefghijklmnopqrst to it': 'abcdefghijklmnopqrst',
        'token $_jwt arrived': _jwt,
        'key sk-test-0123456789abcdef in use': '0123456789abcdef',
        'Cookie: owui_session=deadbeefcafe; other=1': 'deadbeefcafe',
        'set-cookie: token=zzz-made-up': 'zzz-made-up',
        '{"apiKey": "made-up-key-123"}': 'made-up-key-123',
        'GET /x?token=made-up-token-456&page=2': 'made-up-token-456',
        'password=correct-horse': 'correct-horse',
        'https://someone:pa55word@example.com/x': 'pa55word',
        'refresh_token: r-made-up-789': 'r-made-up-789',
        '{"Cookie":"sid=made-up-session-value"}': 'made-up-session-value',
        '{"Authorization": "Bearer short"}': 'short',
        '{"password":";made-up-horse"}': 'made-up-horse',
        '{"passphrase": "made up words here"}': 'up words here',
        r'{"secret": "made-\"up\"-value"}': 'up',
        "{'token': 'made-up single'}": 'single',
      };
      cases.forEach((input, secret) {
        expect(redactSecrets(input), isNot(contains(secret)), reason: input);
      });
      expect(redactSecrets('GET /x?token=abc&page=2'), contains('page=2'));
    });

    test('leaves ordinary text alone', () {
      const text = 'hasToken: true; 3 servers; basic auth enabled; tokens 12';
      expect(redactSecrets(text), text);
    });

    test('scrubs secrets known by value', () {
      expect(
        redactSecrets(
          'boot with $_sessionToken',
          exact: <String>[_sessionToken],
        ),
        isNot(contains(_sessionToken)),
      );
    });
  });

  test('originOnly keeps scheme, host and port', () {
    expect(
      originOnly('https://u:p@chat.example.com:8443/a/b?c=d#e'),
      'https://chat.example.com:8443',
    );
    expect(originOnly('http://example.com/'), 'http://example.com');
    expect(originOnly(''), isNull);
    expect(originOnly('not a url'), '[not a url]');
  });

  group('RotatingLogFile', () {
    test('rolls over at its size and keeps only so many files', () async {
      final log = RotatingLogFile(temp, maxBytes: 200, keep: 3);
      for (var i = 0; i < 60; i++) {
        log.writeln('line $i ${'x' * 20}');
      }
      await log.close();
      final names = temp.listSync().map((f) => f.uri.pathSegments.last).toSet();
      expect(names, <String>{
        'conduitd.log',
        'conduitd.1.log',
        'conduitd.2.log',
      });
      for (final file in log.files) {
        expect(file.lengthSync(), lessThanOrEqualTo(200));
      }
      // The newest line is in the current file, and the oldest are gone.
      expect(log.fileAt(0).readAsStringSync(), contains('line 59 '));
      final all = log.files.map((f) => f.readAsStringSync()).join();
      expect(all, isNot(contains('line 0 ')));
    });

    test('appends to what an earlier run left', () async {
      final first = RotatingLogFile(temp)..writeln('before');
      await first.close();
      final second = RotatingLogFile(temp)..writeln('after');
      await second.close();
      expect(second.fileAt(0).readAsStringSync(), 'before\nafter\n');
    });
  });

  group('DaemonLog', () {
    test('writes the same scrubbed line to stderr and to its file', () async {
      final sink = LinesSink();
      final file = RotatingLogFile(temp);
      final log = DaemonLog(sink: sink)
        ..redactExactly(<String>[_sessionToken])
        ..attachFile(file);
      log.info('auth header Authorization: Bearer abcdefghijklmnop');
      log.info('session $_sessionToken');
      await log.close();

      final written = file.fileAt(0).readAsStringSync();
      expect(sink.lines.join('\n'), isNot(contains('abcdefghijklmnop')));
      expect(sink.lines.join('\n'), isNot(contains(_sessionToken)));
      expect(written, isNot(contains('abcdefghijklmnop')));
      expect(written, isNot(contains(_sessionToken)));
      expect(written.trim().split('\n'), hasLength(2));
    });

    test('takes the core\'s records, errors included', () {
      final sink = LinesSink();
      final core = DaemonLogSink(DaemonLog(sink: sink));
      // DebugLogger drops everything, errors too, when its sink is quiet.
      expect(core.isVerbose, isTrue);
      core.write(LogLevel.error, 'ERR[sync] drain failed');
      core.write(LogLevel.debug, 'DBG chatter');
      expect(sink.lines, hasLength(1));
      expect(sink.lines.single, contains('[error]'));
      expect(sink.lines.single, contains('core: ERR[sync] drain failed'));
    });
  });

  test('the zip holds scrubbed logs and the snapshot', () async {
    final logs = Directory('${temp.path}/logs')..createSync();
    File('${logs.path}/conduitd.log').writeAsStringSync(
      'line one\nAuthorization: Bearer abcdefghijklmnop\n'
      'boot $_sessionToken\n',
    );
    File('${logs.path}/conduitd.1.log').writeAsStringSync('older\n');
    File('${logs.path}/notes.txt').writeAsStringSync('not a log');

    final zip = await writeDiagnosticsZip(
      logs: logs,
      staging: Directory('${temp.path}/staging'),
      snapshot: <String, Object?>{
        'daemonVersion': '0.0.0-test',
        'note': 'api_key=made-up-key-123',
      },
      exactSecrets: <String>[_sessionToken],
      now: DateTime.utc(2026, 1, 2, 3, 4, 5),
    );

    expect(zip.path, endsWith('conduit-diagnostics-2026-01-02T030405Z.zip'));
    final archive = ZipDecoder().decodeBytes(zip.readAsBytesSync());
    expect(archive.files.map((f) => f.name).toSet(), <String>{
      'config.json',
      'logs/conduitd.1.log',
      'logs/conduitd.log',
    });
    final everything = archive.files
        .map((f) => utf8.decode(f.content))
        .join('\n');
    expect(everything, contains('line one'));
    expect(everything, contains('older'));
    for (final secret in <String>[
      'abcdefghijklmnop',
      _sessionToken,
      'made-up-key-123',
    ]) {
      expect(everything, isNot(contains(secret)), reason: secret);
    }
    final config = jsonDecode(
      utf8.decode(archive.findFile('config.json')!.content),
    ) as Map<String, dynamic>;
    expect(config['daemonVersion'], '0.0.0-test');
  });
}
