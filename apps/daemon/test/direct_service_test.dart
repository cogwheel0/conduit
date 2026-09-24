@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

import 'support/null_sink.dart';

/// `direct.*` over the real core: profiles land in the daemon's
/// secure store, and nothing secret ever comes back out.
void main() {
  late Directory temporary;
  late CoreRuntime runtime;
  late DirectService direct;

  setUpAll(() async {
    temporary = Directory.systemTemp.createTempSync('direct-service-test');
    runtime = await CoreRuntime.start(
      config: BootstrapConfig(
        sessionToken: 'a' * 43,
        masterKey: base64.encode(List<int>.generate(32, (i) => i)),
        userDataDir: temporary.path,
      ),
      directories: DaemonDirectories.create(temporary.path),
      log: DaemonLog(level: 'error', sink: NullSink()),
    );
    direct = DirectService(runtime.container);
  });

  tearDownAll(() async {
    await runtime.dispose();
    temporary.deleteSync(recursive: true);
  });

  const edit = DirectConnectionEdit(
    name: 'Work gateway',
    kind: DirectKind.openai,
    baseUrl: 'https://llm.example.com/v1',
    apiKey: 'sk-secret-value',
    customHeaders: <String, String>{'X-Team': 'platform'},
  );

  test('starts empty', () async {
    expect((await direct.list()).connections, isEmpty);
  });

  test('a saved key is reported, never returned', () async {
    final list = await direct.save(edit);
    final saved = list.connections.single;
    expect(saved.hasApiKey, isTrue);
    expect(saved.customHeaderNames, <String>['X-Team']);
    final wire = jsonEncode(list.toJson());
    expect(wire, isNot(contains('sk-secret-value')));
    expect(wire, isNot(contains('platform')));
  });

  test('null keeps the key; empty clears it', () async {
    final id = (await direct.list()).connections.single.id;
    final kept = await direct.save(
      DirectConnectionEdit(
        id: id,
        name: 'Renamed',
        kind: DirectKind.openai,
        baseUrl: 'https://llm.example.com/v1',
      ),
    );
    expect(kept.connections.single.name, 'Renamed');
    expect(kept.connections.single.hasApiKey, isTrue);

    final cleared = await direct.save(
      DirectConnectionEdit(
        id: id,
        name: 'Renamed',
        kind: DirectKind.openai,
        baseUrl: 'https://llm.example.com/v1',
        apiKey: '',
      ),
    );
    expect(cleared.connections.single.hasApiKey, isFalse);
  });

  test('a key does not follow the URL to a new origin', () async {
    final id = (await direct.list()).connections.single.id;
    await direct.save(edit.copyWith(id: id));
    final moved = await direct.save(
      DirectConnectionEdit(
        id: id,
        name: 'Work gateway',
        kind: DirectKind.openai,
        baseUrl: 'https://elsewhere.example.net/v1',
      ),
    );
    expect(moved.connections.single.hasApiKey, isFalse);
    expect(moved.connections.single.customHeaderNames, isEmpty);
  });

  test('an invalid address is refused, not stored', () async {
    await expectLater(
      direct.save(
        const DirectConnectionEdit(
          name: 'Broken',
          kind: DirectKind.ollama,
          baseUrl: 'ftp://nope',
        ),
      ),
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.invalidParams,
        ),
      ),
    );
    expect((await direct.list()).connections, hasLength(1));
  });

  test('testing an unreachable server says so', () async {
    final result = await direct.test(
      const DirectConnectionEdit(
        name: 'Nothing here',
        kind: DirectKind.ollama,
        // A port nothing listens on.
        baseUrl: 'http://127.0.0.1:9',
      ),
    );
    expect(result.reachable, isFalse);
  });

  test('tags, and a client certificate known only by its file name', () async {
    final current = (await direct.list()).connections.single;
    final id = current.id;
    // At the address it has now: moving it drops TLS material by design.
    final here = edit.copyWith(baseUrl: current.baseUrl);
    const pem =
        '-----BEGIN CERTIFICATE-----\nMIIBfake\n-----END CERTIFICATE-----\n';
    final list = await direct.save(
      here.copyWith(
        id: id,
        apiKey: null,
        customHeaders: null,
        tags: const <String>[' work ', ''],
        certificatePem: pem,
        certificateLabel: 'client.pem',
      ),
    );
    final saved = list.connections.single;
    expect(saved.tags, <String>['work']);
    expect(saved.certificateLabel, 'client.pem');
    expect(jsonEncode(list.toJson()), isNot(contains('MIIBfake')));

    // Left out, it stays; sent empty, it goes -- with its name.
    final kept = await direct.save(here.copyWith(id: id, apiKey: null));
    expect(kept.connections.single.certificateLabel, 'client.pem');
    final cleared = await direct.save(
      here.copyWith(id: id, apiKey: null, certificatePem: ''),
    );
    expect(cleared.connections.single.certificateLabel, isNull);
  });

  test('disable, remove, and where history is kept', () async {
    final id = (await direct.list()).connections.single.id;
    expect(
      (await direct.setEnabled(id, false)).connections.single.enabled,
      isFalse,
    );
    expect((await direct.setHistory(localOnly: true)).localHistory, isTrue);
    expect((await direct.setHistory(localOnly: false)).localHistory, isFalse);
    expect((await direct.remove(id)).connections, isEmpty);
  });
}
