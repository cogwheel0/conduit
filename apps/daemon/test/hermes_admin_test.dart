@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

import 'support/fake_hermes_server.dart';
import 'support/null_sink.dart';

/// Hermes's administration (`hermes.connections.*`, `hermes.jobs*`,
/// `hermes.catalog`, `hermes.mcp.*`) against two fakes of its API server.
/// Each test starts from no saved connection and saves what it needs.
void main() {
  late Directory temporary;
  late CoreRuntime runtime;
  late FakeHermesServer first;
  late FakeHermesServer second;
  late HermesAdminService admin;
  late List<String> announced;

  // Each resource's clean-up is registered as soon as it exists, so a
  // setup step that throws still leaves nothing behind.
  setUp(() async {
    temporary = Directory.systemTemp.createTempSync('hermes-admin-test');
    addTearDown(() => temporary.deleteSync(recursive: true));
    runtime = await CoreRuntime.start(
      config: BootstrapConfig(
        sessionToken: 'a' * 43,
        masterKey: base64.encode(List<int>.generate(32, (i) => i)),
        userDataDir: temporary.path,
      ),
      directories: DaemonDirectories.create(temporary.path),
      log: DaemonLog(level: 'error', sink: NullSink()),
    );
    addTearDown(runtime.dispose);
    first = await FakeHermesServer.start();
    addTearDown(first.close);
    second = await FakeHermesServer.start(key: 'second-key');
    addTearDown(second.close);
    final events = EventBus();
    announced = <String>[];
    events.attach('test', (envelope) => announced.add(envelope.event));
    final hermes = HermesService(runtime.container, events: events);
    admin = HermesAdminService(
      runtime.container,
      events: events,
      hermes: hermes,
    );
    addTearDown(() async {
      // Saved connections outlive a runtime (the process's secure
      // storage): the next test starts from none.
      for (final c in (await admin.connections()).connections) {
        await admin.deleteConnection(c.id);
      }
      await admin.setEnabled(false);
      admin.dispose();
    });
  });

  HermesConnectionEdit apiServer(FakeHermesServer server, {String? id}) =>
      HermesConnectionEdit(id: id, baseUrl: server.baseUrl, apiKey: server.key);

  /// The first server saved as Home (the first connection saved is put in
  /// use).
  Future<HermesConnectionDto> saveHome() async {
    final list = await admin.saveConnection(
      apiServer(first).copyWith(name: 'Home'),
    );
    return list.connections.firstWhere((c) => c.name == 'Home');
  }

  /// The second server saved beside it as [name].
  Future<HermesConnectionDto> saveSecond(String name) async {
    final list = await admin.saveConnection(
      apiServer(second).copyWith(name: name),
    );
    return list.connections.firstWhere((c) => c.name == name);
  }

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
    await saveHome();
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
    await saveHome();
    await saveSecond('Studio');
    var list = await admin.setEnabled(false);
    expect(list.enabled, isFalse);
    expect(list.connections, hasLength(2));
    list = await admin.setEnabled(true);
    expect(list.enabled, isTrue);
  });

  test('scheduled agents are made, paused, run and deleted', () async {
    await saveHome();
    final on = (await admin.connections()).connection;
    var jobs = await admin.saveJob(
      HermesJobEdit(
        name: 'Morning brief',
        prompt: 'Summarise the news',
        schedule: '0 8 * * *',
        connection: on,
      ),
    );
    expect(jobs.writable, isTrue);
    expect(jobs.scheduling, isFalse, reason: 'an API server');
    final job = jobs.jobs.single;
    expect(jobs.savedId, job.id, reason: 'the save names the job it made');
    expect(job.name, 'Morning brief');
    expect(job.enabled, isTrue);
    expect(job.scheduleText, isNotNull);
    expect(job.deliver.single.kind, 'local');
    expect(job.running, isFalse);

    // A schedule Hermes cannot read is refused with its field.
    await expectLater(
      admin.saveJob(
        HermesJobEdit(
          name: 'Bad',
          prompt: 'x',
          schedule: 'whenever',
          connection: on,
        ),
      ),
      throwsA(
        isA<RpcError>().having((e) => e.args['field'], 'field', 'schedule'),
      ),
    );

    jobs = await admin.setJobEnabled(
      HermesJobToggle(id: job.id, enabled: false, connection: on),
    );
    expect(jobs.jobs.single.enabled, isFalse);
    jobs = await admin.saveJob(
      HermesJobEdit(
        id: job.id,
        name: 'Morning brief',
        prompt: 'Summarise the tech news',
        schedule: '0 9 * * *',
        connection: on,
      ),
    );
    expect(jobs.jobs.single.prompt, 'Summarise the tech news');
    expect(jobs.savedId, job.id);
    jobs = await admin.runJob(job.id, connection: on);
    expect(jobs.jobs.single.lastStatus, 'ok');
    expect(jobs.jobs.single.running, isFalse);

    // An API server has no Stop and no run history.
    jobs = await admin.stopJob(job.id, connection: on);
    expect(jobs.notices.single.kind, 'stopUnsupported');
    expect((await admin.jobRuns(job.id)).sessions, isEmpty);
    expect((await admin.deliveryOptions()).available, isFalse);

    jobs = await admin.deleteJob(job.id, connection: on);
    expect(jobs.jobs, isEmpty);
  });

  test('the catalog lists skills as the / commands', () async {
    await saveHome();
    final catalog = await admin.catalog();
    expect(catalog.skills.single.name, 'review');
    expect(catalog.toolsets.single.tools, <String>['search', 'fetch']);
    expect(catalog.commands.single.name, 'review');
    expect(catalog.commands.single.description, 'Reviews code');
  });

  test('an API server has no MCP servers to manage', () async {
    await saveHome();
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

  test('a request made under the connection before a switch is refused, '
      'and nothing of it reaches the one in use', () async {
    await saveHome();
    final before = (await admin.connections()).connection;
    expect(before, isNotNull, reason: 'the list names the connection in use');
    final frame = await saveSecond('Cold frame');
    final list = await admin.activate(frame.id);
    final now = list.connection;
    expect(now, isNot(before));
    second.jobs['j-frame'] = <String, dynamic>{
      'id': 'j-frame',
      'name': 'Frame check',
      'prompt': 'Open the vents',
      'schedule': '0 7 * * *',
      'enabled': true,
    };

    final stale = isA<RpcError>().having(
      (e) => e.code,
      'code',
      ConduitErrorCodes.sessionExpired,
    );
    await expectLater(
      admin.saveJob(
        HermesJobEdit(
          name: 'Seed sowing',
          prompt: 'Sow the tomatoes',
          schedule: '0 8 * * *',
          connection: before,
        ),
      ),
      throwsA(stale),
    );
    await expectLater(
      admin.setJobEnabled(
        HermesJobToggle(id: 'j-frame', enabled: false, connection: before),
      ),
      throwsA(stale),
    );
    for (final call in <Future<Object?> Function()>[
      () => admin.runJob('j-frame', connection: before),
      () => admin.stopJob('j-frame', connection: before),
      () => admin.deleteJob('j-frame', connection: before),
      () => admin.jobRuns('j-frame', connection: before),
      () => admin.addMcp(
        HermesMcpAdd(
          name: 'seeds',
          url: 'http://127.0.0.1:1/mcp',
          connection: before,
        ),
      ),
      () => admin.addMcpFromCatalog(
        HermesMcpCatalogAdd(name: 'seeds', connection: before),
      ),
      () => admin.setMcpApiKey(
        HermesMcpApiKey(name: 'seeds', apiKey: 'sk-test', connection: before),
      ),
      () => admin.removeMcp(HermesMcpRef(name: 'seeds', connection: before)),
      () => admin.testMcp(HermesMcpRef(name: 'seeds', connection: before)),
      () => admin.setMcpEnabled(
        HermesMcpToggle(name: 'seeds', enabled: false, connection: before),
      ),
      () => admin.authenticateMcp(
        HermesMcpRef(name: 'seeds', connection: before),
      ),
    ]) {
      await expectLater(call(), throwsA(stale));
    }
    expect(second.jobs.keys, <String>['j-frame'], reason: 'nothing was made');
    expect(second.jobs['j-frame']!['enabled'], isTrue);

    // Made under the connection in use, it goes through.
    final jobs = await admin.setJobEnabled(
      HermesJobToggle(id: 'j-frame', enabled: false, connection: now),
    );
    expect(jobs.jobs.single.enabled, isFalse);
    second.jobs.clear();
  });

  test('the list names the connection it lists as in use, even when another '
      'comes into use while it is read', () async {
    await saveHome();
    final frame = await saveSecond('Cold frame');
    final home = (await admin.connections()).activeId!;
    // Back and forth, each switch made while a list is being read.
    for (final id in <String>[frame.id, home, frame.id, home, frame.id, home]) {
      final before = (await admin.connections()).connection;
      final reading = admin.connections();
      final switching = admin.activate(id);
      final read = await reading;
      await switching;
      final now = (await admin.connections()).connection;
      expect(now, isNot(before));
      expect(
        read.connection,
        read.activeId == id ? now : before,
        reason: 'the list names one connection in use and another one\'s key',
      );
    }
  });

  test('what was read of one connection is never answered once another is '
      'in use', () async {
    await saveHome();
    final frame = await saveSecond('Cold frame');
    final hold = first.holdSkills = Completer<void>();
    final reading = admin.catalog();
    await first.skillsAsked.future;
    await admin.activate(frame.id);
    hold.complete();
    await expectLater(
      reading,
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.sessionExpired,
        ),
      ),
      reason: 'the catalog read of the last connection was answered',
    );
  });

  test(
    'a job whose delivery cannot be read says so, with no routes shown',
    () async {
      await saveHome();
      first.jobs['j-far'] = <String, dynamic>{
        'id': 'j-far',
        'name': 'Seed report',
        'prompt': 'Report the seed stock',
        'schedule': '0 6 * * *',
        'enabled': true,
        // Longer than any route list the core reads.
        'deliver': 'telegram:${'7' * 2100}',
      };
      final job = (await admin.jobs()).jobs.single;
      expect(job.deliveryKnown, isFalse);
      expect(
        job.deliver,
        isEmpty,
        reason: 'shown as local, an edit would replace it',
      );
      first.jobs.clear();
    },
  );

  test('a job made whose list cannot be read after is still answered with '
      'its id', () async {
    await saveHome();
    final on = (await admin.connections()).connection;
    // Read once, so the next reads are the quiet ones a window polls with.
    await admin.jobs();
    first.refuseJobList = true;
    final jobs = await admin.saveJob(
      HermesJobEdit(
        name: 'Seed sowing',
        prompt: 'Sow the tomatoes',
        schedule: '0 8 * * *',
        connection: on,
      ),
    );
    first.refuseJobList = false;
    expect(first.jobs, hasLength(1), reason: 'the job was made');
    expect(jobs.savedId, first.jobs.keys.single, reason: 'its id came back');
    expect(jobs.listFailed, isTrue, reason: 'the list was not read again');
    first.jobs.clear();
  });

  test('a Hermes settings change that names no connection is refused, and '
      'nothing of it reaches the server', () async {
    await saveHome();
    first.jobs['j-home'] = <String, dynamic>{
      'id': 'j-home',
      'name': 'Morning watering',
      'prompt': 'Water the seedlings',
      'schedule': '0 7 * * *',
      'enabled': true,
    };
    final unnamed = isA<RpcError>().having(
      (e) => e.code,
      'code',
      ConduitErrorCodes.invalidParams,
    );
    for (final call in <Future<Object?> Function()>[
      () => admin.saveJob(
        const HermesJobEdit(
          name: 'Seed sowing',
          prompt: 'Sow the tomatoes',
          schedule: '0 8 * * *',
        ),
      ),
      () => admin.setJobEnabled(
        const HermesJobToggle(id: 'j-home', enabled: false),
      ),
      () => admin.runJob('j-home'),
      () => admin.stopJob('j-home'),
      () => admin.deleteJob('j-home'),
      () => admin.addMcp(
        const HermesMcpAdd(name: 'seeds', url: 'http://127.0.0.1:1/mcp'),
      ),
      () => admin.addMcpFromCatalog(const HermesMcpCatalogAdd(name: 'seeds')),
      () => admin.setMcpApiKey(
        const HermesMcpApiKey(name: 'seeds', apiKey: 'sk-test'),
      ),
      () => admin.removeMcp(const HermesMcpRef(name: 'seeds')),
      () => admin.testMcp(const HermesMcpRef(name: 'seeds')),
      () => admin.setMcpEnabled(
        const HermesMcpToggle(name: 'seeds', enabled: false),
      ),
      () => admin.authenticateMcp(const HermesMcpRef(name: 'seeds')),
    ]) {
      await expectLater(call(), throwsA(unnamed));
    }
    expect(first.jobs.keys, <String>['j-home'], reason: 'nothing was made');
    expect(first.jobs['j-home']!['enabled'], isTrue);
    first.jobs.clear();
  });

  test('deleting the connection in use puts another in use', () async {
    await saveHome();
    await saveSecond('Studio agent');
    var list = await admin.connections();
    final home = list.connections.firstWhere((c) => c.active);
    list = await admin.deleteConnection(home.id);
    expect(list.connections, hasLength(1));
    expect(list.connections.single.active, isTrue);
    expect(list.connections.single.name, 'Studio agent');
  });

  test('an edit keeps a phone\'s Notify Me, never lists it', () {
    expect(
      hermesJobDeliverKeepingNotifyMe('telegram', notify: true),
      'telegram,conduit',
    );
    expect(hermesJobDeliverKeepingNotifyMe('', notify: true), 'local,conduit');
    expect(
      hermesJobDeliverKeepingNotifyMe('local,telegram', notify: false),
      'local,telegram',
    );
    // A stray one sent back is dropped when the job had none.
    expect(
      hermesJobDeliverKeepingNotifyMe('telegram,conduit', notify: false),
      'telegram',
    );
  });
}
