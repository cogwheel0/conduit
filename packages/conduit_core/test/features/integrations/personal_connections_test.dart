import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/integrations/personal_connection_drafts.dart';
import 'package:conduit_core/features/integrations/personal_connection_edits.dart';
import 'package:conduit_core/features/integrations/personal_connection_settings.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

import 'package:conduit_core/testing.dart';

import 'deep_equality.dart';

Map<String, dynamic> _toolServer(
  String id,
  String name, {
  String? key,
  Map<String, dynamic> extra = const {},
}) => <String, dynamic>{
  'type': 'openapi',
  'url': 'https://$id.example',
  'spec_type': 'url',
  'path': 'openapi.json',
  'auth_type': 'bearer',
  'key': key ?? 'key-$id',
  'config': <String, dynamic>{'enable': true, 'access_grants': <dynamic>[]},
  'info': <String, dynamic>{'id': id, 'name': name, 'description': ''},
  ...extra,
};

Map<String, dynamic> _terminal(String url, {bool enabled = false}) =>
    <String, dynamic>{
      'url': url,
      'key': 'terminal-key',
      'name': url,
      'path': '/openapi.json',
      'auth_type': 'bearer',
      'enabled': enabled,
      'config': <String, dynamic>{},
    };

void main() {
  group('personal connection writes', () {
    test(
      'patch one tool server under ui and leave everything else as stored',
      () async {
        final server = FakeUserSettingsServer(<String, dynamic>{
          'ui': <String, dynamic>{
            'theme': 'dark',
            'system': 'Be brief',
            'memory': true,
            'toolServers': <dynamic>[
              _toolServer(
                'alpha',
                'Alpha',
                extra: <String, dynamic>{
                  'x_vendor': <String, dynamic>{'tier': 3},
                  'headers': <String, dynamic>{'X-Org': 'acme'},
                },
              ),
              _toolServer('beta', 'Beta'),
            ],
          },
          // Written by older clients and never removed by the server.
          'toolServers': <dynamic>[_toolServer('stale', 'Stale root')],
          'params': <String, dynamic>{'temperature': 0.2},
          'notificationEnabled': true,
        });
        final api = _api(server);
        final alpha = _toolServer('alpha', 'Alpha');
        final identity = personalConnectionIdentity(
          PersonalConnectionKind.toolServer,
          <dynamic>[alpha],
          0,
        );

        final draft = PersonalToolServerDraft.fromEntry(
          server.settings['ui']['toolServers'][0] as Map<String, dynamic>,
        ).copyWith(name: 'Alpha renamed');
        final write = await api.editPersonalConnections(
          PersonalConnectionKind.toolServer,
          PatchPersonalConnection(
            identity,
            draft.toPatch(server.settings['ui']['toolServers'][0]),
          ),
        );

        final stored = server.settings;
        final ui = stored['ui'] as Map<String, dynamic>;
        final tools = (ui['toolServers'] as List).cast<Map<String, dynamic>>();
        check(tools[0]['info']['name']).equals('Alpha renamed');
        // The credential, unknown fields and the other entry survive.
        check(tools[0]['key']).equals('key-alpha');
        check(tools[0]['x_vendor']).deepEquals(<String, dynamic>{'tier': 3});
        check(tools[0]['headers'])
            .deepEquals(<String, dynamic>{'X-Org': 'acme'});
        check(tools[1]).deepEquals(_toolServer('beta', 'Beta'));
        // Unrelated settings and the stale legacy list are untouched.
        check(ui['theme']).equals('dark');
        check(ui['system']).equals('Be brief');
        check(ui['memory']).equals(true);
        check(stored['params'])
            .deepEquals(<String, dynamic>{'temperature': 0.2});
        check(stored['notificationEnabled']).equals(true);
        check(stored['toolServers'])
            .deepEquals(<dynamic>[_toolServer('stale', 'Stale root')]);
        // The result is what the server returned, not what was sent.
        check(write.after[0]['info']['name']).equals('Alpha renamed');
        check(write.indexMap).deepEquals(<int, int>{0: 0, 1: 1});
      },
    );

    test(
      'deleting the last entry leaves an empty ui list, not a gap',
      () async {
        final server = FakeUserSettingsServer(<String, dynamic>{
          'ui': <String, dynamic>{
            'toolServers': <dynamic>[_toolServer('alpha', 'Alpha')],
          },
          'toolServers': <dynamic>[_toolServer('stale', 'Stale root')],
        });
        final api = _api(server);

        final write = await api.editPersonalConnections(
          PersonalConnectionKind.toolServer,
          const RemovePersonalConnection('alpha'),
        );

        check(server.settings['ui']['toolServers']).deepEquals(<dynamic>[]);
        check(effectivePersonalServerList(server.settings, 'toolServers'))
            .isEmpty();
        check(write.after).isEmpty();
        // Nothing was written for the legacy root list.
        check(server.settings['toolServers'])
            .deepEquals(<dynamic>[_toolServer('stale', 'Stale root')]);
      },
    );

    test(
      'a first edit moves root-only data into ui, keeping the root copy',
      () async {
        final server = FakeUserSettingsServer(<String, dynamic>{
          'terminalServers': <dynamic>[_terminal('https://a.example')],
        });
        final api = _api(server);

        await api.editPersonalConnections(
          PersonalConnectionKind.terminal,
          AddPersonalConnection(_terminal('https://b.example')),
        );

        final ui = server.settings['ui'] as Map<String, dynamic>;
        check((ui['terminalServers'] as List).map((e) => e['url']))
            .deepEquals(<String>['https://a.example', 'https://b.example']);
        check(server.settings['terminalServers'])
            .deepEquals(<dynamic>[_terminal('https://a.example')]);
      },
    );

    test('an edit reads the latest settings inside the shared queue', () async {
      final server = FakeUserSettingsServer(<String, dynamic>{
        'ui': <String, dynamic>{
          'system': 'old prompt',
          'toolServers': <dynamic>[_toolServer('alpha', 'Alpha')],
        },
      })..gateFirstGet();
      final api = _api(server);

      final promptUpdate = api.updateUserSystemPrompt('new prompt');
      await server.firstGetEntered.future;
      final connectionEdit = api.editPersonalConnections(
        PersonalConnectionKind.toolServer,
        AddPersonalConnection(_toolServer('beta', 'Beta')),
      );
      await Future<void>.delayed(Duration.zero);
      check(server.log.map((r) => r.method)).deepEquals(<String>['GET']);

      server.releaseFirstGet.complete();
      await Future.wait<Object?>(<Future<Object?>>[
        promptUpdate,
        connectionEdit,
      ]);

      check(server.log.map((r) => r.method))
          .deepEquals(<String>['GET', 'POST', 'GET', 'POST']);
      check(server.maximumConcurrentRequests).equals(1);
      final ui = server.settings['ui'] as Map<String, dynamic>;
      check(ui['system']).equals('new prompt');
      check((ui['toolServers'] as List).map((e) => e['info']['id']))
          .deepEquals(<String>['alpha', 'beta']);
    });

    test(
      'a write queued under one account is never sent as the next',
      () async {
        final server = FakeUserSettingsServer(<String, dynamic>{
          'ui': <String, dynamic>{'toolServers': <dynamic>[]},
        })..gateFirstGet();
        final api = _api(server, token: 'account-a');

        final blocker = api.updateUserMemoryEnabled(true);
        await server.firstGetEntered.future;
        final queued = api.editPersonalConnections(
          PersonalConnectionKind.toolServer,
          AddPersonalConnection(_toolServer('alpha', 'Alpha')),
        );
        api.updateAuthToken('account-b');
        server.releaseFirstGet.complete();

        await expectLater(blocker, throwsA(isA<DioException>()));
        await expectLater(queued, throwsA(isA<DioException>()));
        check(server.log.where((r) => r.authorization == 'Bearer account-b'))
            .isEmpty();
        check(server.log.where((r) => r.method == 'POST')).isEmpty();
        check(server.settings['ui']['toolServers']).deepEquals(<dynamic>[]);
      },
    );

    test('a server that drops the list is reported, not trusted', () async {
      // Open WebUI silently removes ui.toolServers for a non-admin without
      // features.direct_tool_servers and still answers 200.
      final server = FakeUserSettingsServer(<String, dynamic>{})
        ..stripToolServers = true;
      final api = _api(server);

      await expectLater(
        api.editPersonalConnections(
          PersonalConnectionKind.toolServer,
          AddPersonalConnection(_toolServer('alpha', 'Alpha')),
        ),
        throwsA(isA<PersonalConnectionsWriteRejected>()),
      );
    });

    test(
      'an edit finds its target by identity after another client reordered',
      () async {
        final server = FakeUserSettingsServer(<String, dynamic>{
          'ui': <String, dynamic>{
            'toolServers': <dynamic>[
              _toolServer('beta', 'Beta'),
              _toolServer('alpha', 'Alpha'),
            ],
          },
        });
        final api = _api(server);
        // The screen was opened when alpha was first.
        final identity = personalConnectionIdentity(
          PersonalConnectionKind.toolServer,
          <dynamic>[_toolServer('alpha', 'Alpha'), _toolServer('beta', 'Beta')],
          0,
        );

        final write = await api.editPersonalConnections(
          PersonalConnectionKind.toolServer,
          SetPersonalConnectionEnabled(identity, false),
        );

        final tools = (server.settings['ui']['toolServers'] as List)
            .cast<Map<String, dynamic>>();
        check(tools[0]['config']['enable']).equals(true); // beta untouched
        check(tools[1]['config']['enable']).equals(false); // alpha switched off
        check(write.entryIndex).equals(1);
      },
    );

    test('an edit whose target is gone writes nothing', () async {
      final server = FakeUserSettingsServer(<String, dynamic>{
        'ui': <String, dynamic>{
          'toolServers': <dynamic>[_toolServer('beta', 'Beta')],
        },
      });
      final api = _api(server);

      await expectLater(
        api.editPersonalConnections(
          PersonalConnectionKind.toolServer,
          const PatchPersonalConnection('alpha', <String, dynamic>{'url': 'x'}),
        ),
        throwsA(
          isA<PersonalConnectionEditException>().having(
            (e) => e.failure,
            'failure',
            PersonalConnectionEditFailure.notFound,
          ),
        ),
      );
      check(server.log.where((r) => r.method == 'POST')).isEmpty();
    });

    test(
      'turning a terminal on turns the others off in the same write',
      () async {
        final server = FakeUserSettingsServer(<String, dynamic>{
          'ui': <String, dynamic>{
            'terminalServers': <dynamic>[
              _terminal('https://a.example', enabled: true),
              _terminal('https://b.example'),
            ],
          },
        });
        final api = _api(server);

        await api.editPersonalConnections(
          PersonalConnectionKind.terminal,
          const SetPersonalConnectionEnabled('https://b.example', true),
        );

        final terminals = (server.settings['ui']['terminalServers'] as List)
            .cast<Map<String, dynamic>>();
        check(terminals.map((t) => t['enabled']))
            .deepEquals(<bool>[false, true]);
        check(server.log.where((r) => r.method == 'POST')).length.equals(1);
      },
    );

    test(
      'a key stays untouched unless the draft replaces or clears it',
      () async {
        final stored = _toolServer('alpha', 'Alpha');
        final server = FakeUserSettingsServer(<String, dynamic>{
          'ui': <String, dynamic>{
            'toolServers': <dynamic>[stored],
          },
        });
        final api = _api(server);
        final draft = PersonalToolServerDraft.fromEntry(stored);

        await api.editPersonalConnections(
          PersonalConnectionKind.toolServer,
          PatchPersonalConnection(
            'alpha',
            draft.copyWith(url: 'https://new.example').toPatch(stored),
          ),
        );
        var saved =
            server.settings['ui']['toolServers'][0] as Map<String, dynamic>;
        check(saved['url']).equals('https://new.example');
        check(saved['key']).equals('key-alpha');

        await api.editPersonalConnections(
          PersonalConnectionKind.toolServer,
          PatchPersonalConnection(
            'alpha',
            draft
                .copyWith(
                  key: 'rotated',
                  keyMode: PersonalConnectionSecretMode.replace,
                )
                .toPatch(saved),
          ),
        );
        saved = server.settings['ui']['toolServers'][0] as Map<String, dynamic>;
        check(saved['key']).equals('rotated');

        await api.editPersonalConnections(
          PersonalConnectionKind.toolServer,
          PatchPersonalConnection(
            'alpha',
            draft
                .copyWith(keyMode: PersonalConnectionSecretMode.clear)
                .toPatch(saved),
          ),
        );
        saved = server.settings['ui']['toolServers'][0] as Map<String, dynamic>;
        check(saved['key']).equals('');
      },
    );

    test(
      'adding a duplicate identity is refused before anything is sent',
      () async {
        final server = FakeUserSettingsServer(<String, dynamic>{
          'ui': <String, dynamic>{
            'toolServers': <dynamic>[_toolServer('alpha', 'Alpha')],
          },
        });
        final api = _api(server);

        await expectLater(
          api.editPersonalConnections(
            PersonalConnectionKind.toolServer,
            AddPersonalConnection(_toolServer('alpha', 'Copy')),
          ),
          throwsA(
            isA<PersonalConnectionEditException>().having(
              (e) => e.failure,
              'failure',
              PersonalConnectionEditFailure.duplicate,
            ),
          ),
        );
        check(server.log.where((r) => r.method == 'POST')).isEmpty();
      },
    );
  });
}

ApiService _api(FakeUserSettingsServer server, {String token = 'account-a'}) {
  final api = ApiService(
    serverConfig: const ServerConfig(
      id: 'personal-connections',
      name: 'Personal connections',
      url: 'https://example.test',
    ),
    workerManager: WorkerManager(),
    authToken: token,
  );
  api.dio.httpClientAdapter = server;
  return api;
}
