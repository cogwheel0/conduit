@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

import 'support/fake_hermes_server.dart';
import 'support/null_sink.dart';

/// Hermes's administration (`hermes.connections.*`, `hermes.jobs*`,
/// `hermes.catalog`, `hermes.mcp.*`) against two fakes of its API server.
void main() {
  late Directory temporary;
  late CoreRuntime runtime;
  late FakeHermesServer first;
  late FakeHermesServer second;
  late HermesAdminService admin;
  late List<String> announced;

  setUpAll(() async {
    temporary = Directory.systemTemp.createTempSync('hermes-admin-test');
    runtime = await CoreRuntime.start(
      config: BootstrapConfig(
        sessionToken: 'a' * 43,
        masterKey: base64.encode(List<int>.generate(32, (i) => i)),
        userDataDir: temporary.path,
      ),
      directories: DaemonDirectories.create(temporary.path),
      log: DaemonLog(level: 'error', sink: NullSink()),
    );
    first = await FakeHermesServer.start();
    second = await FakeHermesServer.start(key: 'second-key');
    final events = EventBus();
    announced = <String>[];
    events.attach('test', (envelope) => announced.add(envelope.event));
    final hermes = HermesService(runtime.container, events: events);
    admin = HermesAdminService(
      runtime.container,
      events: events,
      hermes: hermes,
    );
  });

  tearDownAll(() async {
    admin.dispose();
    await first.close();
    await second.close();
    await runtime.dispose();
    temporary.deleteSync(recursive: true);
  });

  HermesConnectionEdit apiServer(FakeHermesServer server, {String? id}) =>
      HermesConnectionEdit(id: id, baseUrl: server.baseUrl, apiKey: server.key);

  test(
    'the first connection saved is put in use and turns Hermes on',
    () async {
      var list = await admin.connections();
      expect(list.connections, isEmpty);
      expect(list.enabled, isFalse);

      // A test tells a wrong key from a right one, and saves nothing.
      final wrong = await admin.testConnection(
        HermesConnectionEdit(baseUrl: first.baseUrl, apiKey: 'wrong'),
      );
      expect(wrong.ok, isFalse);
      expect((await admin.testConnection(apiServer(first))).ok, isTrue);
      expect((await admin.connections()).connections, isEmpty);

      // An API server without its key is refused before anything is sent.
      final keyless = await admin.testConnection(
        HermesConnectionEdit(baseUrl: first.baseUrl),
      );
      expect(keyless.reason, 'keyRequired');
      await expectLater(
        admin.saveConnection(HermesConnectionEdit(baseUrl: 'not a url')),
        throwsA(
          isA<RpcError>().having(
            (e) => e.args['reason'],
            'reason',
            'invalidUrl',
          ),
        ),
      );

      list = await admin.saveConnection(
        apiServer(first).copyWith(name: 'Home'),
      );
      expect(list.enabled, isTrue);
      expect(list.connections, hasLength(1));
      final home = list.connections.single;
      expect(home.name, 'Home');
      expect(home.active, isTrue);
      expect(home.hasApiKey, isTrue);
      expect(list.activeId, home.id);
      expect(list.savedId, home.id);
      // Secrets never leave the daemon.
      expect(jsonEncode(list.toJson()), isNot(contains(first.key)));
      expect(announced, contains(ConduitEvents.hermesChanged));
    },
  );

  test('a second connection is saved beside it, then switched to', () async {
    var list = await admin.saveConnection(
      apiServer(second).copyWith(name: 'Studio'),
    );
    expect(list.connections, hasLength(2));
    final home = list.connections.firstWhere((c) => c.name == 'Home');
    final studio = list.connections.firstWhere((c) => c.name == 'Studio');
    expect(home.active, isTrue, reason: 'a new one is saved beside it');
    expect(studio.active, isFalse);
    expect(studio.hasApiKey, isTrue);

    // Renamed, its key kept (the same server).
    list = await admin.saveConnection(
      HermesConnectionEdit(
        id: studio.id,
        name: 'Studio agent',
        baseUrl: second.baseUrl,
      ),
    );
    final renamed = list.connections.firstWhere((c) => c.id == studio.id);
    expect(renamed.name, 'Studio agent');
    expect(renamed.hasApiKey, isTrue);

    list = await admin.activate(studio.id);
    expect(list.activeId, studio.id);
    expect(
      list.connections.firstWhere((c) => c.id == studio.id).active,
      isTrue,
    );
    // The jobs are the new connection's.
    second.jobs['j-studio'] = <String, dynamic>{
      'id': 'j-studio',
      'name': 'Studio digest',
      'prompt': 'Summarise the studio notes',
      'schedule': '0 7 * * *',
      'enabled': true,
    };
    final jobs = await admin.jobs();
    expect(jobs.jobs.map((j) => j.name), <String?>['Studio digest']);
    second.jobs.clear();

    list = await admin.activate(home.id);
    expect(list.activeId, home.id);
  });

  test('Hermes is turned off and on, its connections kept', () async {
    var list = await admin.setEnabled(false);
    expect(list.enabled, isFalse);
    expect(list.connections, hasLength(2));
    list = await admin.setEnabled(true);
    expect(list.enabled, isTrue);
  });

  test('scheduled agents are made, paused, run and deleted', () async {
    var jobs = await admin.saveJob(
      const HermesJobEdit(
        name: 'Morning brief',
        prompt: 'Summarise the news',
        schedule: '0 8 * * *',
      ),
    );
    expect(jobs.writable, isTrue);
    expect(jobs.scheduling, isFalse, reason: 'an API server');
    final job = jobs.jobs.single;
    expect(job.name, 'Morning brief');
    expect(job.enabled, isTrue);
    expect(job.scheduleText, isNotNull);
    expect(job.deliver.single.kind, 'local');
    expect(job.running, isFalse);

    // A schedule Hermes cannot read is refused with its field.
    await expectLater(
      admin.saveJob(
        const HermesJobEdit(name: 'Bad', prompt: 'x', schedule: 'whenever'),
      ),
      throwsA(
        isA<RpcError>().having((e) => e.args['field'], 'field', 'schedule'),
      ),
    );

    jobs = await admin.setJobEnabled(
      HermesJobToggle(id: job.id, enabled: false),
    );
    expect(jobs.jobs.single.enabled, isFalse);
    jobs = await admin.saveJob(
      HermesJobEdit(
        id: job.id,
        name: 'Morning brief',
        prompt: 'Summarise the tech news',
        schedule: '0 9 * * *',
      ),
    );
    expect(jobs.jobs.single.prompt, 'Summarise the tech news');
    jobs = await admin.runJob(job.id);
    expect(jobs.jobs.single.lastStatus, 'ok');
    expect(jobs.jobs.single.running, isFalse);

    // An API server has no Stop and no run history.
    jobs = await admin.stopJob(job.id);
    expect(jobs.notices.single.kind, 'stopUnsupported');
    expect((await admin.jobRuns(job.id)).sessions, isEmpty);
    expect((await admin.deliveryOptions()).available, isFalse);

    jobs = await admin.deleteJob(job.id);
    expect(jobs.jobs, isEmpty);
  });

  test('the catalog lists skills as the / commands', () async {
    final catalog = await admin.catalog();
    expect(catalog.skills.single.name, 'review');
    expect(catalog.toolsets.single.tools, <String>['search', 'fetch']);
    expect(catalog.commands.single.name, 'review');
    expect(catalog.commands.single.description, 'Reviews code');
  });

  test('an API server has no MCP servers to manage', () async {
    final servers = await admin.mcpServers();
    expect(servers.available, isFalse);
    await expectLater(
      admin.mcpCatalog(),
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.unsupported,
        ),
      ),
    );
  });

  test('deleting the connection in use puts another in use', () async {
    var list = await admin.connections();
    final home = list.connections.firstWhere((c) => c.active);
    list = await admin.deleteConnection(home.id);
    expect(list.connections, hasLength(1));
    expect(list.connections.single.active, isTrue);
    expect(list.connections.single.name, 'Studio agent');
  });
}
