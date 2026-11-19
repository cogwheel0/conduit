@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

import 'support/mcp_fixture.dart';
import 'support/null_sink.dart';

/// `mcp.*` over the real core, against a real MCP server on a
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

    // The window lists saved headers by name only: a header added to them
    // joins them, an empty value takes one away, and an empty set clears.
    Future<List<String>> names(Map<String, String> headers) async =>
        (await mcp.save(edit(id: saved.id).copyWith(customHeaders: headers)))
            .servers
            .single
            .customHeaderNames;
    expect(await names(const {'X-One': '1'}), <String>['X-One']);
    expect(await names(const {'X-Two': '2'}), <String>['X-One', 'X-Two']);
    expect(await names(const {'x-one': ''}), <String>['X-Two']);
    expect(await names(const {}), isEmpty);
    expect((await mcp.list()).servers.single.hasBearerToken, isTrue);
  });

  // The saved token belongs to the saved address: testing an edit that
  // points elsewhere, without typing the token again, must not send it.
  test('testing an edited address does not send the saved token', () async {
    final saved = (await mcp.list()).servers.single;
    final headers = <String?>[];
    final traces = <String?>[];
    final elsewhere = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => elsewhere.close(force: true));
    elsewhere.listen((request) async {
      headers.add(request.headers.value(HttpHeaders.authorizationHeader));
      traces.add(request.headers.value('X-Trace'));
      await request.drain<void>();
      request.response.statusCode = HttpStatus.unauthorized;
      await request.response.close();
    });

    // An empty set of headers types nothing again either, and a header
    // typed again takes only itself along, not the saved token.
    for (final moved in <McpServerEdit>[
      edit(id: saved.id),
      edit(id: saved.id).copyWith(customHeaders: const <String, String>{}),
      edit(id: saved.id)
          .copyWith(customHeaders: const <String, String>{'X-Trace': 'typed'}),
    ]) {
      final result = await mcp.test(
        moved.copyWith(endpoint: 'http://127.0.0.1:${elsewhere.port}/mcp'),
      );
      expect(result.reachable, isFalse);
    }
    expect(headers, hasLength(greaterThanOrEqualTo(2)));
    expect(headers, everyElement(isNot(contains('mcp-secret-token'))));
    // The header typed again is sent, without a token: the saved token
    // stays behind and bearer with it, as the core's own rule does.
    expect(traces, contains('typed'), reason: 'the moved server was not tried');

    // And saved so: no token, no bearer, only the header typed again.
    final other = (await mcp.save(
      edit(token: 'mcp-secret-token').copyWith(name: 'Other'),
    )).servers.firstWhere((s) => s.name == 'Other');
    final moved = (await mcp.save(
      edit(id: other.id).copyWith(
        name: 'Other',
        endpoint: 'http://127.0.0.1:${elsewhere.port}/mcp',
        customHeaders: const <String, String>{'X-Trace': 'typed'},
      ),
    )).servers.firstWhere((s) => s.id == other.id);
    await mcp.remove(other.id);
    expect(moved.hasBearerToken, isFalse);
    expect(moved.auth, McpAuth.none);
    expect(moved.customHeaderNames, <String>['X-Trace']);
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

  test('offers prompts and resources to insert', () async {
    final id = (await mcp.list()).servers.single.id;
    final content = await mcp.content(id);
    expect(content.prompts.single.name, 'summarize');
    expect(content.prompts.single.arguments.single.required, isTrue);
    expect(content.resources.single.uri, 'file:///notes/today.md');

    final prompt = await mcp.getPrompt(
      McpGetPrompt(
        serverId: id,
        name: 'summarize',
        arguments: const <String, String>{'topic': 'llamas'},
      ),
    );
    expect(prompt.messages.single.role, 'user');
    expect(prompt.messages.single.text, 'Summarize llamas.');

    final resource = await mcp.readResource(
      McpReadResource(serverId: id, uri: 'file:///notes/today.md'),
    );
    expect(resource.messages.single.text, contains('Water the plants.'));

    // Something the list never offered is refused as changed.
    expect(
      mcp.readResource(McpReadResource(serverId: id, uri: 'file:///x')),
      throwsA(
        isA<RpcError>().having((e) => e.args['reason'], 'reason', 'changed'),
      ),
    );
  });

  test('turns off, and is removed', () async {
    final id = (await mcp.list()).servers.single.id;
    expect((await mcp.setEnabled(id, false)).servers.single.enabled, isFalse);
    expect((await mcp.remove(id)).servers, isEmpty);
  });
}
