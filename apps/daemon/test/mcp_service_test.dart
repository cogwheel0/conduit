@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

import 'support/mcp_fixture.dart';
import 'support/null_sink.dart';

/// `mcp.*` over the real core (M4), against a real MCP server on a
/// loopback port.
void main() {
  late Directory temporary;
  late CoreRuntime runtime;
  late McpService mcp;
  late McpFixture fixture;

  setUpAll(() async {
    temporary = Directory.systemTemp.createTempSync('mcp-service-test');
    runtime = await CoreRuntime.start(
      config: BootstrapConfig(
        sessionToken: 'a' * 43,
        masterKey: base64.encode(List<int>.generate(32, (i) => i)),
        userDataDir: temporary.path,
      ),
      directories: DaemonDirectories.create(temporary.path),
      log: DaemonLog(level: 'error', sink: NullSink()),
    );
    mcp = McpService(runtime.container);
    fixture = await McpFixture.start(requiredToken: 'mcp-secret-token');
  });

  tearDownAll(() async {
    await fixture.close();
    await runtime.dispose();
    temporary.deleteSync(recursive: true);
  });

  McpServerEdit edit({String? id, String? token}) => McpServerEdit(
    id: id,
    name: 'Fixture',
    endpoint: fixture.endpoint.toString(),
    auth: McpAuth.bearer,
    bearerToken: token,
  );

  test('starts empty', () async {
    expect((await mcp.list()).servers, isEmpty);
  });

  test('tests a server before it is saved', () async {
    final wrong = await mcp.test(edit(token: 'nope'));
    expect(wrong.reachable, isFalse);
    final right = await mcp.test(edit(token: 'mcp-secret-token'));
    expect(right.reachable, isTrue, reason: right.message);
    expect(right.toolCount, 1);
  });

  test('a saved token is reported, never returned', () async {
    final list = await mcp.save(edit(token: 'mcp-secret-token'));
    final saved = list.servers.single;
    expect(saved.hasBearerToken, isTrue);
    expect(saved.auth, McpAuth.bearer);
    expect(jsonEncode(list.toJson()), isNot(contains('mcp-secret-token')));

    // An edit that leaves the token out keeps it, and still connects.
    final renamed = await mcp.save(
      edit(id: saved.id).copyWith(name: 'Renamed'),
    );
    expect(renamed.servers.single.name, 'Renamed');
    expect(renamed.servers.single.hasBearerToken, isTrue);
    expect((await mcp.test(edit(id: saved.id))).reachable, isTrue);
  });

  test('credentials over plain HTTP to another computer need a yes', () {
    expect(
      mcp.save(
        const McpServerEdit(
          name: 'Remote',
          endpoint: 'http://mcp.example.com/mcp',
          auth: McpAuth.bearer,
          bearerToken: 't',
        ),
      ),
      throwsA(
        isA<RpcError>()
            .having((e) => e.code, 'code', ConduitErrorCodes.invalidParams)
            .having((e) => e.args['reason'], 'reason', 'insecure'),
      ),
    );
  });

  test('turns off, and is removed', () async {
    final id = (await mcp.list()).servers.single.id;
    expect((await mcp.setEnabled(id, false)).servers.single.enabled, isFalse);
    expect((await mcp.remove(id)).servers, isEmpty);
  });
}
