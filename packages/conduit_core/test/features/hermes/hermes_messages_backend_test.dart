import 'package:conduit_core/features/hermes/models/hermes_chat_input.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:conduit_core/features/hermes/models/hermes_bot_group.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_transport.dart';
import 'package:dio/dio.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class _Channel extends Mock implements WebSocketChannel {}

class _Sink extends Mock implements WebSocketSink {}

class _Rest implements HttpClientAdapter {
  final reads = <RequestOptions>[];
  final files = <String, String>{};
  @override
  Future<ResponseBody> fetch(
    RequestOptions request,
    Stream<Uint8List>? body,
    Future<void>? cancel,
  ) async {
    reads.add(request);
    var status = 200;
    Object result;
    if (request.uri.path.endsWith('/api/files/upload')) {
      final data = request.data as Map;
      final path = data['path'] as String;
      if (files.containsKey(path)) {
        status = 409;
        result = {'detail': 'exists'};
      } else {
        files[path] = data['data_url'] as String;
        result = {'ok': true};
      }
    } else if (request.uri.path.endsWith('/api/files/read')) {
      result = {'data_url': files[request.uri.queryParameters['path']]};
    } else if (request.uri.path.endsWith('/api/files')) {
      result = {'path': request.uri.queryParameters['path'], 'entries': []};
    } else {
      result = request.path.endsWith('/status')
          ? {'auth_required': false, 'desktop_gateway': true}
          : request.path.contains('/messages')
          ? {
              'messages': [
                {'role': 'assistant', 'content': 'Stored answer'},
              ],
            }
          : [];
    }

    return ResponseBody.fromString(
      jsonEncode(result),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late HermesDesktopApiService service;
  late HermesDesktopRpcClient rpc;
  late StreamController<Object?> input;
  late List<Map<String, dynamic>> frames;
  late _Rest rest;
  var nativeGroups = false, failGroupSave = false;
  final nativeRooms = <String, Map<String, dynamic>>{};
  final groupMeta = <String, dynamic>{};
  final groupRevisions = <String, int>{
    hermesGroupsNamespace: 0,
    conduitGroupOptionsNamespace: 0,
  };
  var failSetup = false;
  var failCapabilities = false;
  var existingGroupSession = false;
  late Object skillsCatalog;
  setUp(() async {
    PreferencesStore.debugOverride(InMemoryKeyValueStore());
    frames = [];
    skillsCatalog = [
      {'name': 'research', 'enabled': true},
    ];
    nativeGroups = failGroupSave = false;
    nativeRooms.clear();
    groupMeta.clear();
    groupRevisions.updateAll((_, __) => 0);
    input = StreamController<Object?>();
    final channel = _Channel(), sink = _Sink();
    when(() => channel.ready).thenAnswer((_) async {});
    when(() => channel.stream).thenAnswer((_) => input.stream);
    when(() => channel.sink).thenReturn(sink);
    when(() => sink.close()).thenAnswer((_) async {});
    when(() => sink.add(any())).thenAnswer((invocation) {
      final frame = Map<String, dynamic>.from(
        jsonDecode(invocation.positionalArguments.single as String) as Map,
      );
      frames.add(frame);
      if (frame['id'] == null) return;
      final params = frame['params'] as Map? ?? {};
      if (nativeGroups && frame['method'].toString().startsWith('groups.')) {
        final id = params['room_id']?.toString();
        Object result;
        switch (frame['method']) {
          case 'groups.capabilities':
            result = {
              'driver': true,
              'persistent_process': true,
              'methods': ['groups.create', 'groups.send'],
            };
          case 'groups.create':
            final incoming = {
              'room_id': id,
              'name': params['name'],
              'members': params['members'],
            };
            if (nativeRooms[id] != null &&
                jsonEncode(nativeRooms[id]!['members']) !=
                    jsonEncode(params['members']))
              throw StateError('Fixed roster changed');
            nativeRooms.putIfAbsent(id!, () => incoming);
            result = {'room': nativeRooms[id]};
          case 'groups.list':
            result = {
              'rooms': nativeRooms.values
                  .where((r) => r['disbanded_at'] == null)
                  .toList(),
            };
          case 'groups.state':
            result = {'room': nativeRooms[id]};
          case 'groups.disband':
            nativeRooms[id]!['disbanded_at'] = 12345;
            result = {'ok': true};
          case 'groups.log':
            result = {
              'events': [
                {
                  'event_id': 'old-native-reply',
                  'kind': 'message.member',
                  'created_at': 1234,
                  'payload': {
                    'text': 'Retained server reply',
                    'member_id': 'research',
                  },
                },
              ],
              'cursor': 1,
              'has_more': false,
            };
          case 'groups.rename':
            nativeRooms[id]!['name'] = params['name'];
            result = {'ok': true};
          default:
            result = {};
        }
        input.add(
          jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
        );
        return;
      }
      if (nativeGroups && frame['method'] == 'profiles.list') {
        input.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': frame['id'],
            'result': {
              'bot_mode_protocol': true,
              'profiles': [
                {
                  'name': 'default',
                  'ui_meta': groupMeta,
                  'ui_meta_revisions': groupRevisions,
                },
              ],
            },
          }),
        );
        return;
      }
      if (nativeGroups && frame['method'] == 'profiles.configure') {
        if (failGroupSave) {
          failGroupSave = false;
          input.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'error': {
                'code': 5000,
                'message': 'Save temporarily unavailable',
              },
            }),
          );
          return;
        }
        for (final e in (params['ui_meta'] as Map).entries) {
          groupMeta[e.key as String] = e.value;
          groupRevisions[e.key as String] = groupRevisions[e.key]! + 1;
        }
        input.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': frame['id'],
            'result': {
              'applied': {'ui_meta': true, 'ui_meta_revisions': groupRevisions},
            },
          }),
        );
        return;
      }
      if (frame['method'] == 'tools.list' && params.containsKey('profile')) {
        input.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': frame['id'],
            'error': {
              'code': -32602,
              'message': 'profile: Extra inputs are not permitted',
            },
          }),
        );
        return;
      }
      final Object result = switch (frame['method']) {
        'profiles.list' => {'bot_mode_protocol': true, 'profiles': []},
        'profiles.create' => {'name': params['name']},
        'profiles.describe' => {
          'toolsets': [
            {'name': 'terminal', 'label': 'Terminal', 'enabled': false},
            {'name': 'web', 'enabled': true},
          ],
        },
        'profiles.configure' => {
          'applied': {
            'ui_meta': !failSetup,
            'disabled_skills': !failCapabilities,
          },
        },
        'session.list' => {
          'sessions': [
            if (existingGroupSession)
              {
                'id': params['title'] == 'Bot Chat'
                    ? 'canonical-bot-session'
                    : 'dedicated-group-session',
                'title': params['title'],
              },
          ],
        },
        'session.resume' => {
          'session_id': 'runtime-bot',
          'stored_session_id': params['session_id'],
          'running': false,
        },
        'session.create' => {
          'session_id': 'runtime-group',
          'stored_session_id': 'stored-group',
        },
        'skills.manage' => {'skills': skillsCatalog},
        'tools.list' => {
          'sections': [
            {'name': 'terminal', 'enabled': true},
          ],
        },
        _ => {},
      };
      input.add(
        jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
      );
    });
    rpc = HermesDesktopRpcClient(
      channelFactory: (_, _, {httpClient}) => channel,
    );
    final connect = rpc.connect(Uri.parse('ws://fixture.invalid/api/ws'));
    input.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {'type': 'gateway.ready', 'payload': {}},
      }),
    );
    await connect;
    rest = _Rest();
    service = HermesDesktopApiService(
      config: HermesConfig(
        desktopCredentials: HermesDesktopCredentials(
          legacyToken: 'fixture-token',
        ),
        enabled: true,
        baseUrl: 'http://fixture.invalid',
        mode: HermesBackendMode.desktopGateway,
      ),
      rpc: rpc,
      dio: Dio()..httpClientAdapter = rest,
    );
    failSetup = failCapabilities = existingGroupSession = false;
  });
  tearDown(() async {
    service.close();
    await rpc.close();
    await input.close();
    PreferencesStore.debugReset();
  });
  test(
    'new groups use the durable native driver without a members mutation API',
    () async {
      nativeGroups = true;
      final saved = await service.saveBotGroup(
        const HermesBotGroup(
          key: 'id:team',
          roomId: 'team',
          name: 'Team',
          memberProfiles: ['research', 'coding'],
          coordinator: 'research',
        ),
      );
      expect(saved.raw['hosted'], true);
      expect(nativeRooms.length, 1);
      expect((await service.listBotGroups()).single.identity, 'team');
    },
  );
  test(
    'renaming an existing native room avoids idempotent-create conflicts',
    () async {
      nativeGroups = true;
      final original = await service.saveBotGroup(
        const HermesBotGroup(
          key: 'id:team',
          roomId: 'team',
          name: 'Team',
          memberProfiles: ['research', 'coding'],
          coordinator: 'research',
        ),
      );
      final renamed = await service.saveBotGroup(
        original.copyWith(name: 'New team'),
      );
      expect(renamed.name, 'New team');
      expect(nativeRooms['team']!['name'], 'New team');
      expect(frames.where((f) => f['method'] == 'groups.create').length, 1);
    },
  );
  test('changing members atomically replaces the fixed room and preserves server history', () async {
    nativeGroups = true;
    final original = await service.saveBotGroup(
      const HermesBotGroup(
        key: 'id:team',
        roomId: 'team',
        name: 'Team',
        memberProfiles: ['research', 'coding'],
        coordinator: 'research',
        sharedFolder: '/team',
        icon: 'code',
        color: '#5bbf98',
      ),
    );
    final saved = await service.saveBotGroup(
      original.copyWith(memberProfiles: ['research', 'planning']),
    );
    expect(saved.identity, isNot('team'));
    expect(saved.messages.single.text, 'Retained server reply');
    expect(saved.previousRooms.single['room_id'], 'team');
    expect(saved.sharedFolder, '/team');
    expect(nativeRooms['team']!['disbanded_at'], isNotNull);
    final snapshot = groupMeta[hermesGroupsNamespace] as Map;
    expect((snapshot['rooms'] as Map).containsKey('id:team'), false);
    expect((snapshot['deleted'] as Map).containsKey('id:team'), true);
    final listed = (await service.listBotGroups())
        .where((g) => g.identity == saved.identity)
        .single;
    expect(listed.previousRooms, saved.previousRooms);
    await expectLater(
      service.saveBotGroup(
        original.copyWith(memberProfiles: ['research', 'other']),
      ),
      throwsStateError,
    );
    expect(nativeRooms.length, 2);
  });
  test(
    'retrying a failed replacement save recovers the same native room',
    () async {
      nativeGroups = true;
      final original = await service.saveBotGroup(
        const HermesBotGroup(
          key: 'id:team',
          roomId: 'team',
          name: 'Team',
          memberProfiles: ['research', 'coding'],
          coordinator: 'research',
        ),
      );
      final changed = original.copyWith(
        memberProfiles: ['research', 'planning'],
      );
      failGroupSave = true;
      await expectLater(
        service.saveBotGroup(changed),
        throwsA(isA<HermesDesktopRpcException>()),
      );
      final saved = await service.saveBotGroup(changed);
      expect(nativeRooms.length, 2);
      expect(saved.messages.single.text, 'Retained server reply');
      expect((groupMeta[hermesGroupsNamespace]['rooms'] as Map).keys, [
        saved.key,
      ]);
    },
  );
  test('group file retries verify existing bytes and never overwrite a different file', () async {
    const group = HermesBotGroup(
      key: 'id:files',
      roomId: 'files',
      name: 'Files',
      memberProfiles: ['research', 'coding'],
      coordinator: 'research',
      sharedFolder: '/test-group',
    );
    final file = HermesInputFilePart(
      filename: 'check.txt',
      mediaType: 'text/plain',
      base64Data: base64Encode(utf8.encode('Check contents')),
    );
    final uploaded = await service.uploadGroupFiles(group, [file]);
    final retried = await service.uploadGroupFiles(group, [file]);
    expect(retried.paths, uploaded.paths);
    expect(
      rest.reads.where((r) => r.uri.path.endsWith('/api/files/read')).length,
      1,
    );
    rest.files[uploaded.paths.single] =
        'data:text/plain;base64,${base64Encode(utf8.encode('Changed bytes'))}';
    await expectLater(
      service.uploadGroupFiles(group, [file]),
      throwsStateError,
    );
    expect(
      rest.reads
          .where((r) => r.uri.path.endsWith('/api/files/upload'))
          .every((r) => (r.data as Map)['overwrite'] == false),
      true,
    );
  });
  const draft = HermesBotDraft(
    profile: 'planner',
    title: 'Planner',
    description: 'Plan work',
    instructions: 'Check assumptions',
    cloneFrom: 'research',
    model: 'example-model',
    provider: 'example-provider',
    disabledSkills: ['web'],
    toolsets: ['terminal'],
    mcpServers: ['Library'],
  );
  test(
    'bot creation sends clone/auth/model/capabilities to actual profile RPC',
    () async {
      final bot = await service.createBot(draft);
      expect(bot.name, 'planner');
      final create =
          frames.singleWhere((f) => f['method'] == 'profiles.create')['params']
              as Map;
      expect(create['name'], 'planner');
      expect(create['clone_from'], 'research');
      expect(create['share_auth'], false);
      expect(create['model'], 'example-model');
      expect(create['provider'], 'example-provider');
      expect(create['soul'], contains('Check assumptions'));
      expect(create['soul'], 'Check assumptions');
      final setup =
          frames.singleWhere(
                (f) => f['method'] == 'profiles.configure',
              )['params']
              as Map;
      expect(setup['name'], 'planner');
      expect(setup['disabled_skills'], ['web']);
      expect(setup['enabled_toolsets'], ['terminal']);
      expect(setup['enabled_mcp_servers'], ['Library']);
      expect(setup['ui_meta']['hermes-bots']['title'], 'Planner');
    },
  );
  test(
    'bot creation generates the desktop persona even when cloning',
    () async {
      const generated = HermesBotDraft(
        profile: 'trey',
        title: 'Inbox Triage',
        role: 'Inbox Triage',
        description: 'Sort the inbox and flag important mail.',
        instructions: '',
        cloneFrom: 'default',
      );
      await service.createBot(generated);
      final create =
          frames.singleWhere((f) => f['method'] == 'profiles.create')['params']
              as Map;
      expect(create['soul'], '''# Inbox Triage

**Role:** Inbox Triage
**Mission:** Sort the inbox and flag important mail.

You are Inbox Triage, a persistent named agent (profile `trey`) on this machine.
You keep your own memory, skills, and conversation history across sessions.''');
      expect(create['clone_from'], 'default');
      expect(create['soul'], isNot(contains('hermes -p')));
    },
  );
  test('name-only persona omits empty role and mission', () {
    const generated = HermesBotDraft(
      profile: 'trey',
      title: 'Trey',
      role: '',
      description: '',
      instructions: '',
    );
    expect(generated.soul, startsWith('# Trey\n'));
    expect(generated.soul, isNot(contains('**Role:**')));
    expect(generated.soul, isNot(contains('**Mission:**')));
  });
  test(
    'a failed post-create configuration retries only configuration',
    () async {
      failSetup = true;
      await expectLater(
        service.createBot(draft),
        throwsA(isA<HermesBotSetupIncomplete>()),
      );
      failSetup = false;
      await service.finishBotSetup(draft);
      expect(
        frames.where((f) => f['method'] == 'profiles.create'),
        hasLength(1),
      );
      expect(
        frames.where((f) => f['method'] == 'profiles.configure'),
        hasLength(2),
      );
    },
  );
  test(
    'explicitly rejected capabilities cannot report successful setup',
    () async {
      failCapabilities = true;
      await expectLater(
        service.createBot(draft),
        throwsA(isA<HermesBotSetupIncomplete>()),
      );
      failCapabilities = false;
      await service.finishBotSetup(draft);
      expect(
        frames.where((f) => f['method'] == 'profiles.create'),
        hasLength(1),
      );
    },
  );
  test('group sessions ignore canonical IDs and create hidden profile-scoped sessions', () async {
    const group = HermesBotGroup(
      key: 'id:team',
      roomId: 'team',
      name: 'Team',
      memberProfiles: ['research', 'coding'],
      memberSessions: {'research': 'canonical-bot-chat'},
    );
    expect(
      await service.openGroupMemberSession(group, 'research'),
      'stored-group',
    );
    final create =
        frames.singleWhere((f) => f['method'] == 'session.create')['params']
            as Map;
    expect(create['hidden'], true);
    expect(create['profile'], 'research');
    expect(create['title'], 'Conduit group: team');
    expect(frames.where((f) => f['method'] == 'session.resume'), isEmpty);
    existingGroupSession = true;
    expect(
      await service.openGroupMemberSession(group, 'research'),
      'dedicated-group-session',
    );
    expect(frames.where((f) => f['method'] == 'session.create'), hasLength(1));
  });
  test(
    'history and routine reads use their owning profile and never resume',
    () async {
      await service.readStoredTranscript('bot-session', profile: 'research');
      await service.listProfileJobs('coding');
      final transcript = rest.reads.singleWhere(
        (r) => r.uri.path.contains('/messages'),
      );
      final jobs = rest.reads.singleWhere(
        (r) => r.uri.path == '/api/cron/jobs',
      );
      expect(transcript.uri.queryParameters['profile'], 'research');
      expect(jobs.uri.queryParameters['profile'], 'coding');
      expect(frames.where((f) => f['method'] == 'session.resume'), isEmpty);
    },
  );
  test(
    'opening a bot never resumes an ordinary session from cached metadata',
    () async {
      existingGroupSession = true;
      final id = await service.openBotChat(
        const HermesBot(
          name: 'research',
          title: 'Researcher',
          chatSessionId: 'ordinary-chat',
        ),
      );
      expect(id, 'canonical-bot-session');
      final resume =
          frames.singleWhere((f) => f['method'] == 'session.resume')['params']
              as Map;
      expect(resume['session_id'], 'canonical-bot-session');
      expect(resume['profile'], 'research');
      expect(frames.where((f) => f['method'] == 'session.create'), isEmpty);
    },
  );
  test('unconfirmed existing bot chat cannot create a duplicate or open an ordinary chat', () async {
    await expectLater(
      service.openBotChat(
        const HermesBot(
          name: 'research',
          title: 'Researcher',
          chatSessionId: 'existing-bot',
        ),
      ),
      throwsStateError,
    );
    expect(
      frames.where(
        (f) =>
            f['method'] == 'session.resume' || f['method'] == 'session.create',
      ),
      isEmpty,
    );
  });
  test('canonical bot discovery uses the hidden registry without resuming a session', () async {
    existingGroupSession = true;
    final session = await service.findBotChat('research');
    expect(session!.isBotChat, isTrue);
    final list =
        frames.singleWhere((f) => f['method'] == 'session.list')['params']
            as Map;
    expect(list['profile'], 'research');
    expect(list['title'], 'Bot Chat');
    expect(list['include_hidden'], true);
    expect(frames.where((f) => f['method'] == 'session.resume'), isEmpty);
    expect(frames.where((f) => f['method'] == 'session.create'), isEmpty);
  });
  test('catalog reads stay in the selected clone profile', () async {
    await service.listProfileSkills('research');
    expect(await service.listProfileToolsets('coding'), [
      {'name': 'terminal', 'label': 'Terminal', 'enabled': false},
      {'name': 'web', 'enabled': true},
    ]);
    expect(
      frames.singleWhere(
        (f) => f['method'] == 'skills.manage',
      )['params']['profile'],
      'research',
    );
    final description = frames.singleWhere(
      (f) => f['method'] == 'profiles.describe',
    );
    expect(description['params'], {'name': 'coding', 'profile': 'coding'});
    expect(frames.where((f) => f['method'] == 'tools.list'), isEmpty);
  });
  test(
    'profile skills flatten categories and preserve skill metadata',
    () async {
      skillsCatalog = {
        'productivity': ['planning'],
        'writing': [
          {
            'name': 'drafting',
            'description': 'Draft documents',
            'enabled': false,
          },
          {'name': 'editing', 'category': 'custom'},
        ],
        'empty': [],
      };

      expect(await service.listProfileSkills('research'), [
        {'name': 'planning', 'category': 'productivity'},
        {
          'name': 'drafting',
          'description': 'Draft documents',
          'enabled': false,
          'category': 'writing',
        },
        {'name': 'editing', 'category': 'custom'},
      ]);
    },
  );
  test('profile skills preserve skill-keyed maps', () async {
    skillsCatalog = {
      'planning': {'description': 'Plan work', 'enabled': false},
    };

    expect(await service.listProfileSkills('research'), [
      {'name': 'planning', 'description': 'Plan work', 'enabled': false},
    ]);
  });
  test('profile skills preserve flat strings and records', () async {
    skillsCatalog = [
      'planning',
      {'name': 'drafting', 'category': 'writing', 'enabled': false},
    ];

    expect(await service.listProfileSkills('research'), [
      {'name': 'planning'},
      {'name': 'drafting', 'category': 'writing', 'enabled': false},
    ]);
  });
}
