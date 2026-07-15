import 'dart:convert';

import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/models/openwebui_direct_connection.dart';
import 'package:conduit/features/direct_connections/services/openwebui_direct_connection_store.dart';
import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OpenWebUiDirectConnectionsCodec', () {
    test('maps indexed OpenAI settings without leaking owner or secrets', () {
      final settings = <String, dynamic>{
        'ui': <String, dynamic>{
          'theme': 'dark',
          'directConnections': <String, dynamic>{
            'futureDocumentField': <String, dynamic>{'enabled': true},
            'OPENAI_API_BASE_URLS': <String>[
              'https://alpha.test/v1/',
              'https://session.test/v1',
            ],
            'OPENAI_API_KEYS': <String>['alpha-secret', 'session-placeholder'],
            'OPENAI_API_CONFIGS': <String, dynamic>{
              '0': <String, dynamic>{
                'enable': false,
                'prefix_id': 'corp',
                'model_ids': <String>['first-model', 'second-model'],
                'api_type': 'responses',
                'api_version': '2026-07-01',
                'headers': <String, String>{'X-Tenant': 'blue'},
                'tags': <Object>[
                  'plain',
                  <String, String>{'name': 'object'},
                  <String, String>{'ignored': 'value'},
                ],
                'auth_type': 'bearer',
                'futureConfig': <String, dynamic>{'nested': true},
              },
              '1': <String, dynamic>{'auth_type': 'session'},
            },
          },
        },
      };
      final codec = OpenWebUiDirectConnectionsCodec(
        serverId: 'private-server-id',
        accountId: 'private-account-id',
      );

      final snapshot = codec.decode(settings);
      final first = snapshot.records.first;
      final second = snapshot.records.last;

      check(snapshot.serverId).equals('private-server-id');
      check(snapshot.accountId).equals('private-account-id');
      check(snapshot.ui['theme']).equals('dark');
      check(first.profile.adapterKey).equals(kOpenAiCompatibleAdapterKey);
      check(first.profile.name).equals('alpha.test · 1');
      check(first.profile.baseUrl).equals('https://alpha.test/v1/');
      check(first.profile.openAiApiMode).equals(DirectOpenAiApiMode.responses);
      check(first.profile.apiVersion).equals('2026-07-01');
      check(first.profile.modelIdPrefix).equals('corp');
      check(
        first.profile.manualModelIds,
      ).deepEquals(['first-model', 'second-model']);
      check(first.profile.tags).deepEquals(['plain', 'object']);
      check(first.profile.enabled).isFalse();
      check(first.profile.apiKey).equals('alpha-secret');
      check(first.profile.customHeaders).deepEquals({'X-Tenant': 'blue'});
      check(first.isCompatible).isTrue();
      check(
        first.rawConfig['futureConfig'],
      ).isA<Map>().deepEquals({'nested': true});

      check(second.compatibility).equals(
        OpenWebUiDirectConnectionCompatibility.unsupportedAuthentication,
      );
      check(second.authType).equals('session');
      check(second.profile.apiKey).isNull();
      check(snapshot.compatibleProfiles).deepEquals([first.profile]);

      final otherOwner = OpenWebUiDirectConnectionsCodec(
        serverId: 'private-server-id',
        accountId: 'different-account',
      ).decode(settings);
      check(
        otherOwner.records.first.profile.id,
      ).not((it) => it.equals(first.profile.id));
      check(first.profile.id).not((it) => it.contains('private-server-id'));
      check(first.profile.id).not((it) => it.contains('private-account-id'));
      check(first.profile.id).not((it) => it.contains('alpha-secret'));
      check(first.revision).not((it) => it.contains('alpha-secret'));
      check(first.toString()).not((it) => it.contains('alpha-secret'));
      check(first.toString()).not((it) => it.contains('https://alpha.test'));
      check(snapshot.toString()).not((it) => it.contains('alpha-secret'));

      check(
        () => (first.rawConfig['futureConfig'] as Map)['nested'] = false,
      ).throws<UnsupportedError>();
    });

    test('supports no-auth records without mapping their key', () {
      final snapshot =
          OpenWebUiDirectConnectionsCodec(
            serverId: 'server',
            accountId: 'account',
          ).decode(<String, dynamic>{
            'ui': <String, dynamic>{
              'directConnections': <String, dynamic>{
                'OPENAI_API_BASE_URLS': <String>['https://none.test/v1'],
                'OPENAI_API_KEYS': <String>['must-not-be-used'],
                'OPENAI_API_CONFIGS': <String, dynamic>{
                  '0': <String, dynamic>{'auth_type': 'none'},
                },
              },
            },
          });

      check(snapshot.records.single.isCompatible).isTrue();
      check(snapshot.records.single.profile.apiKey).isNull();
    });

    test(
      'disambiguates bit-for-bit duplicate records without using indexes',
      () {
        final identityKey = List<int>.generate(32, (index) => index);
        final codec = OpenWebUiDirectConnectionsCodec(
          serverId: 'server',
          accountId: 'account',
          identityKey: identityKey,
        );
        final settings = <String, dynamic>{
          'ui': <String, dynamic>{
            'directConnections': <String, dynamic>{
              'OPENAI_API_BASE_URLS': <String>[
                'https://distinct.test/v1',
                'https://duplicate.test/v1',
                'https://duplicate.test/v1',
              ],
              'OPENAI_API_KEYS': <String>[
                'distinct-key',
                'duplicate-key',
                'duplicate-key',
              ],
              'OPENAI_API_CONFIGS': <String, dynamic>{
                '0': <String, dynamic>{'auth_type': 'bearer'},
                '1': <String, dynamic>{'auth_type': 'bearer'},
                '2': <String, dynamic>{'auth_type': 'bearer'},
              },
            },
          },
        };

        final before = codec.decode(settings);
        final duplicateIds = before.records
            .skip(1)
            .map((record) => record.profile.id)
            .toList(growable: false);
        final direct = (settings['ui'] as Map)['directConnections'] as Map;
        direct['OPENAI_API_BASE_URLS'] =
            (direct['OPENAI_API_BASE_URLS'] as List).skip(1).toList();
        direct['OPENAI_API_KEYS'] = (direct['OPENAI_API_KEYS'] as List)
            .skip(1)
            .toList();
        direct['OPENAI_API_CONFIGS'] = <String, dynamic>{
          '0': <String, dynamic>{'auth_type': 'bearer'},
          '1': <String, dynamic>{'auth_type': 'bearer'},
        };

        final after = OpenWebUiDirectConnectionsCodec(
          serverId: 'server',
          accountId: 'account',
          identityKey: identityKey,
        ).decode(settings);

        check(duplicateIds[0]).not((it) => it.equals(duplicateIds[1]));
        check(
          after.records.map((record) => record.profile.id),
        ).deepEquals(duplicateIds);
      },
    );

    test('normalizes non-identity edits across codec recreation', () {
      final identityKey = List<int>.generate(32, (index) => index + 1);
      final before =
          OpenWebUiDirectConnectionsCodec(
            serverId: 'server',
            accountId: 'account',
            identityKey: identityKey,
          ).decode(<String, dynamic>{
            'ui': <String, dynamic>{
              'directConnections': <String, dynamic>{
                'OPENAI_API_BASE_URLS': <String>[
                  'https://identity.example/v1/',
                ],
                'OPENAI_API_KEYS': <String>['stable-key'],
                'OPENAI_API_CONFIGS': <String, dynamic>{
                  '0': <String, dynamic>{
                    'auth_type': 'bearer',
                    'enable': true,
                    'tags': <String>['before'],
                    'model_ids': <String>['model-b', ' model-a ', 'model-a'],
                    'headers': <String, String>{'X-Secret': 'stable-header'},
                  },
                },
              },
            },
          });
      final normalized =
          OpenWebUiDirectConnectionsCodec(
            serverId: 'server',
            accountId: 'account',
            identityKey: identityKey,
          ).decode(<String, dynamic>{
            'ui': <String, dynamic>{
              'directConnections': <String, dynamic>{
                'OPENAI_API_BASE_URLS': <String>['https://identity.example/v1'],
                'OPENAI_API_KEYS': <String>['stable-key'],
                'OPENAI_API_CONFIGS': <String, dynamic>{
                  '0': <String, dynamic>{
                    'auth_type': 'bearer',
                    'enable': false,
                    'tags': <String>['after'],
                    'connection_type': 'external',
                    'azure': false,
                    'api_type': 'chat-completions',
                    'model_ids': <String>['model-a', 'model-b'],
                    'headers': <String, String>{'X-Secret': 'stable-header'},
                  },
                },
              },
            },
          });

      check(
        normalized.records.single.profile.id,
      ).equals(before.records.single.profile.id);
      check(
        normalized.records.single.revision,
      ).not((it) => it.equals(before.records.single.revision));
    });

    test('keyed identity rotates for secret and semantic edits', () {
      final identityKey = List<int>.generate(32, (index) => index + 2);
      Map<String, dynamic> settings({
        String key = 'first-key',
        String header = 'first-header',
        String futureCredential = 'first-future-secret',
        String prefix = 'public-prefix',
      }) => <String, dynamic>{
        'ui': <String, dynamic>{
          'directConnections': <String, dynamic>{
            'OPENAI_API_BASE_URLS': <String>['https://identity.example/v1'],
            'OPENAI_API_KEYS': <String>[key],
            'OPENAI_API_CONFIGS': <String, dynamic>{
              '0': <String, dynamic>{
                'auth_type': 'bearer',
                'prefix_id': prefix,
                'headers': <String, String>{'X-Secret': header},
                'futureCredential': futureCredential,
              },
            },
          },
        },
      };
      String profileId(Map<String, dynamic> value, {List<int>? keyOverride}) =>
          OpenWebUiDirectConnectionsCodec(
            serverId: 'server',
            accountId: 'account',
            identityKey: keyOverride ?? identityKey,
          ).decode(value).records.single.profile.id;

      final baseline = profileId(settings());
      for (final changed in <Map<String, dynamic>>[
        settings(key: 'second-key'),
        settings(header: 'second-header'),
        settings(futureCredential: 'second-future-secret'),
        settings(prefix: 'different-public-prefix'),
      ]) {
        check(profileId(changed)).not((it) => it.equals(baseline));
      }
      check(
        profileId(
          settings(),
          keyOverride: List<int>.generate(32, (index) => index + 3),
        ),
      ).not((it) => it.equals(baseline));
      for (final secret in <String>[
        'first-key',
        'first-header',
        'first-future-secret',
      ]) {
        check(baseline).not((it) => it.contains(secret));
      }
    });

    test(
      'credential-only duplicates keep identity after an earlier deletion',
      () {
        final identityKey = List<int>.generate(32, (index) => index + 4);
        Map<String, dynamic> settings(List<String> keys) => <String, dynamic>{
          'ui': <String, dynamic>{
            'directConnections': <String, dynamic>{
              'OPENAI_API_BASE_URLS': <String>[
                for (final _ in keys) 'https://tenant.example/v1',
              ],
              'OPENAI_API_KEYS': keys,
              'OPENAI_API_CONFIGS': <String, dynamic>{
                for (var index = 0; index < keys.length; index++)
                  '$index': <String, dynamic>{'auth_type': 'bearer'},
              },
            },
          },
        };
        OpenWebUiDirectConnectionsSnapshot decode(List<String> keys) =>
            OpenWebUiDirectConnectionsCodec(
              serverId: 'server',
              accountId: 'account',
              identityKey: identityKey,
            ).decode(settings(keys));

        final before = decode(<String>['tenant-a-key', 'tenant-b-key']);
        final after = decode(<String>['tenant-b-key']);

        check(
          before.records.first.profile.id,
        ).not((it) => it.equals(before.records.last.profile.id));
        check(
          after.records.single.profile.id,
        ).equals(before.records.last.profile.id);
      },
    );

    test('does not activate a URL without its indexed config', () {
      final snapshot =
          OpenWebUiDirectConnectionsCodec(
            serverId: 'server',
            accountId: 'account',
          ).decode(<String, dynamic>{
            'ui': <String, dynamic>{
              'directConnections': <String, dynamic>{
                'OPENAI_API_BASE_URLS': <String>['https://partial.test/v1'],
                'OPENAI_API_KEYS': <String>['partial-secret'],
                'OPENAI_API_CONFIGS': <String, dynamic>{},
              },
            },
          });

      check(snapshot.records).length.equals(1);
      check(
        snapshot.records.single.compatibility,
      ).equals(OpenWebUiDirectConnectionCompatibility.invalidProfile);
      check(snapshot.compatibleProfiles).isEmpty();
    });
  });

  group('OpenWebUiDirectConnectionStore', () {
    test(
      'freshly merges an edit and returns the authoritative server record',
      () async {
        final server = _FakeSettingsServer(<String, dynamic>{
          'rootField': <String, dynamic>{'preserved': true},
          'ui': <String, dynamic>{
            'theme': 'dark',
            'futureUi': <String, dynamic>{'keep': true},
            'directConnections': <String, dynamic>{
              'futureDocumentField': 42,
              'OPENAI_API_BASE_URLS': <String>['https://old.test/v1/'],
              'OPENAI_API_KEYS': <String>['old-secret'],
              'OPENAI_API_CONFIGS': <String, dynamic>{
                '0': <String, dynamic>{
                  'auth_type': 'bearer',
                  'connection_type': 'external',
                  'futureConfig': <String, dynamic>{'keep': true},
                },
              },
            },
          },
        });
        final store = OpenWebUiDirectConnectionStore(
          serverId: 'server-one',
          accountId: 'account-one',
          readSettings: server.read,
          writeSettings: server.write,
        );
        final before = await store.load();
        final record = before.records.single;
        final edited = record.profile.copyWith(
          baseUrl: 'https://new.test/openai/v1/',
          openAiApiMode: DirectOpenAiApiMode.responses,
          apiVersion: '2026-07-01',
          modelIdPrefix: 'new-prefix',
          tags: const <String>['one', 'two'],
          manualModelIds: const <String>['model-a'],
          apiKey: 'new-secret',
          customHeaders: const <String, String>{'X-Tenant': 'green'},
        );

        final after = await store.update(record, edited);

        check(store.serverId).equals('server-one');
        check(store.accountId).equals('account-one');
        check(server.readCount).equals(3);
        check(server.writeCount).equals(1);
        check(server.lastPayload!.keys).deepEquals(['rootField', 'ui']);
        check(
          server.lastPayload!['rootField'],
        ).isA<Map>().deepEquals({'preserved': true});
        check(
          server.settings['rootField'],
        ).isA<Map>().deepEquals({'preserved': true});
        final postedUi = server.lastPayload!['ui'] as Map<String, dynamic>;
        check(postedUi['theme']).equals('dark');
        check(postedUi['futureUi']).isA<Map>().deepEquals({'keep': true});
        final direct = postedUi['directConnections'] as Map<String, dynamic>;
        check(direct['futureDocumentField']).equals(42);
        check(
          direct['OPENAI_API_BASE_URLS'],
        ).isA<List>().deepEquals(['https://new.test/openai/v1']);
        check(direct['OPENAI_API_KEYS']).isA<List>().deepEquals(['new-secret']);
        final config = (direct['OPENAI_API_CONFIGS'] as Map)['0'] as Map;
        check(config['connection_type']).equals('external');
        check(config['futureConfig']).isA<Map>().deepEquals({'keep': true});
        check(config['enable']).isA<bool>().isTrue();
        check(config['prefix_id']).equals('new-prefix');
        check(config['model_ids']).isA<List>().deepEquals(['model-a']);
        check(config['api_type']).equals('responses');
        check(config['api_version']).equals('2026-07-01');
        check(config['headers']).isA<Map>().deepEquals({'X-Tenant': 'green'});
        check(config['tags']).isA<List>().deepEquals([
          {'name': 'one'},
          {'name': 'two'},
        ]);

        check(
          after.records.single.profile.baseUrl,
        ).equals('https://new.test/openai/v1');
        check(
          after.records.single.profile.id,
        ).not((it) => it.equals(record.profile.id));
        check(after.records.single.profile.name).equals('new.test · 1');
        check(after.records.single.profile.apiKey).equals('new-secret');
        check(
          after.records.single.rawConfig['futureConfig'],
        ).isA<Map>().deepEquals({'keep': true});
      },
    );

    test('rejects stale revisions using the fresh authoritative GET', () async {
      final server = _FakeSettingsServer(
        _oneConnectionSettings('first-secret'),
      );
      final store = OpenWebUiDirectConnectionStore(
        serverId: 'server',
        accountId: 'account',
        readSettings: server.read,
        writeSettings: server.write,
      );
      final stale = (await store.load()).records.single;
      server.settings = _oneConnectionSettings('winning-secret');

      late OpenWebUiDirectConnectionConflictException conflict;
      try {
        await store.update(stale, stale.profile.copyWith(name: 'Ignored'));
        fail('Expected a conflict');
      } on OpenWebUiDirectConnectionConflictException catch (error) {
        conflict = error;
      }

      check(server.writeCount).equals(0);
      check(
        conflict.currentSnapshot.records.single.profile.apiKey,
      ).equals('winning-secret');
      check(
        conflict.currentSnapshot.records.single.profile.id,
      ).not((it) => it.equals(stale.profile.id));
      check(
        conflict.currentSnapshot.records.single.revision,
      ).not((it) => it.equals(stale.revision));
      for (final secret in <String>['first-secret', 'winning-secret']) {
        check(conflict.toString()).not((it) => it.contains(secret));
      }
      check(conflict.toString()).not((it) => it.contains(stale.revision));
    });

    test('clearing an existing bearer key preserves its auth type', () async {
      final server = _FakeSettingsServer(
        _oneConnectionSettings('existing-secret'),
      );
      final store = OpenWebUiDirectConnectionStore(
        serverId: 'server',
        accountId: 'account',
        readSettings: server.read,
        writeSettings: server.write,
      );
      final record = (await store.load()).records.single;

      final after = await store.update(
        record,
        record.profile.copyWith(apiKey: null),
      );

      final direct = after.ui['directConnections'] as Map;
      check(direct['OPENAI_API_KEYS']).isA<List>().deepEquals(['']);
      check(
        ((direct['OPENAI_API_CONFIGS'] as Map)['0'] as Map)['auth_type'],
      ).equals('bearer');
      check(
        ((direct['OPENAI_API_CONFIGS'] as Map)['0'] as Map).containsKey(
          'connection_type',
        ),
      ).isFalse();
      check(after.records.single.authType).equals('bearer');
      check(after.records.single.profile.apiKey).isNull();
    });

    test('explicit auth type distinguishes empty bearer from none', () async {
      final server = _FakeSettingsServer(<String, dynamic>{
        'ui': <String, dynamic>{
          'directConnections': <String, dynamic>{
            'OPENAI_API_BASE_URLS': <String>[],
            'OPENAI_API_KEYS': <String>[],
            'OPENAI_API_CONFIGS': <String, dynamic>{},
          },
        },
      });
      final store = OpenWebUiDirectConnectionStore(
        serverId: 'server',
        accountId: 'account',
        readSettings: server.read,
        writeSettings: server.write,
      );
      final profile = DirectConnectionProfile(
        id: 'new-profile',
        name: 'New profile',
        adapterKey: kOpenAiCompatibleAdapterKey,
        baseUrl: 'https://new.test/v1',
      );

      final bearer = await store.add(profile, authType: 'BEARER');
      var direct = bearer.ui['directConnections'] as Map;
      check(direct['OPENAI_API_KEYS']).isA<List>().deepEquals(['']);
      check(bearer.records.single.authType).equals('bearer');

      final none = await store.update(
        bearer.records.single,
        bearer.records.single.profile.copyWith(apiKey: 'must-be-discarded'),
        authType: 'none',
      );
      direct = none.ui['directConnections'] as Map;
      check(direct['OPENAI_API_KEYS']).isA<List>().deepEquals(['']);
      check(none.records.single.authType).equals('none');
      check(none.records.single.profile.apiKey).isNull();

      await check(
        store.update(
          none.records.single,
          none.records.single.profile,
          authType: 'session',
        ),
      ).throws<FormatException>();
    });

    test(
      'rejects a URL change that would carry an opaque unsupported key',
      () async {
        final server = _FakeSettingsServer(
          _unsupportedConnectionSettings('opaque-session-key'),
        );
        final store = OpenWebUiDirectConnectionStore(
          serverId: 'server',
          accountId: 'account',
          readSettings: server.read,
          writeSettings: server.write,
        );
        final record = (await store.load()).records.single;

        await check(
          store.update(
            record,
            record.profile.copyWith(baseUrl: 'https://different.test/v1'),
          ),
        ).throws<FormatException>();

        check(server.writeCount).equals(0);
        final direct =
            (server.settings['ui'] as Map)['directConnections'] as Map;
        check(
          direct['OPENAI_API_BASE_URLS'],
        ).isA<List>().deepEquals(['https://session.test/v1']);
        check(
          direct['OPENAI_API_KEYS'],
        ).isA<List>().deepEquals(['opaque-session-key']);
      },
    );

    for (final conversion in <({String authType, String? apiKey})>[
      (authType: 'bearer', apiKey: 'replacement-key'),
      (authType: 'none', apiKey: null),
    ]) {
      test('allows an unsupported-auth URL change when explicitly converted to '
          '${conversion.authType}', () async {
        final server = _FakeSettingsServer(
          _unsupportedConnectionSettings('opaque-session-key'),
        );
        final store = OpenWebUiDirectConnectionStore(
          serverId: 'server',
          accountId: 'account',
          readSettings: server.read,
          writeSettings: server.write,
        );
        final record = (await store.load()).records.single;

        final after = await store.update(
          record,
          record.profile.copyWith(
            baseUrl: 'https://different.test/v1',
            apiKey: conversion.apiKey,
          ),
          authType: conversion.authType,
        );

        final direct = after.ui['directConnections'] as Map;
        check(
          direct['OPENAI_API_BASE_URLS'],
        ).isA<List>().deepEquals(['https://different.test/v1']);
        check(
          direct['OPENAI_API_KEYS'],
        ).isA<List>().deepEquals([conversion.apiKey ?? '']);
        check(
          ((direct['OPENAI_API_CONFIGS'] as Map)['0'] as Map)['auth_type'],
        ).equals(conversion.authType);
        check(
          ((direct['OPENAI_API_CONFIGS'] as Map)['0'] as Map)['future'],
        ).isA<Map>().deepEquals({'preserved': true});
      });
    }

    test(
      'allows same-URL edits to retain unsupported authentication',
      () async {
        final server = _FakeSettingsServer(
          _unsupportedConnectionSettings('opaque-session-key'),
        );
        final store = OpenWebUiDirectConnectionStore(
          serverId: 'server',
          accountId: 'account',
          readSettings: server.read,
          writeSettings: server.write,
        );
        final record = (await store.load()).records.single;

        final after = await store.update(
          record,
          record.profile.copyWith(tags: const <String>['edited']),
        );

        final direct = after.ui['directConnections'] as Map;
        check(
          direct['OPENAI_API_KEYS'],
        ).isA<List>().deepEquals(['opaque-session-key']);
        check(after.records.single.authType).equals('session');
        check(
          ((direct['OPENAI_API_CONFIGS'] as Map)['0'] as Map)['future'],
        ).isA<Map>().deepEquals({'preserved': true});
      },
    );

    test('add honors the expected direct-connections revision', () async {
      final server = _FakeSettingsServer(_oneConnectionSettings('first-key'));
      final store = OpenWebUiDirectConnectionStore(
        serverId: 'server',
        accountId: 'account',
        readSettings: server.read,
        writeSettings: server.write,
      );
      final stale = await store.load();
      server.settings = _oneConnectionSettings('winning-key');
      final profile = DirectConnectionProfile(
        id: 'new-profile',
        name: 'New profile',
        adapterKey: kOpenAiCompatibleAdapterKey,
        baseUrl: 'https://new.test/v1',
      );

      await check(
        store.add(profile, expectedDocumentRevision: stale.documentRevision),
      ).throws<OpenWebUiDirectConnectionConflictException>();

      check(server.writeCount).equals(0);
    });

    test(
      'distinguishes a committed write from a failed authoritative GET',
      () async {
        final server = _FakeSettingsServer(<String, dynamic>{
          'ui': <String, dynamic>{
            'directConnections': <String, dynamic>{
              'OPENAI_API_BASE_URLS': <String>[],
              'OPENAI_API_KEYS': <String>[],
              'OPENAI_API_CONFIGS': <String, dynamic>{},
            },
          },
        })..failReadAt = 2;
        final store = OpenWebUiDirectConnectionStore(
          serverId: 'server',
          accountId: 'account',
          readSettings: server.read,
          writeSettings: server.write,
        );
        final profile = DirectConnectionProfile(
          id: 'new-profile',
          name: 'New profile',
          adapterKey: kOpenAiCompatibleAdapterKey,
          baseUrl: 'https://new.test/v1',
          apiKey: 'committed-secret',
        );

        late OpenWebUiDirectConnectionCommitUncertainException uncertain;
        try {
          await store.add(profile);
          fail('Expected the authoritative GET to fail');
        } on OpenWebUiDirectConnectionCommitUncertainException catch (error) {
          uncertain = error;
        }

        check(server.writeCount).equals(1);
        final committedDirect =
            (server.settings['ui'] as Map)['directConnections'] as Map;
        check(
          committedDirect['OPENAI_API_BASE_URLS'],
        ).isA<List>().deepEquals(['https://new.test/v1']);
        check(
          committedDirect['OPENAI_API_KEYS'],
        ).isA<List>().deepEquals(['committed-secret']);
        check(
          uncertain.toString(),
        ).not((it) => it.contains('committed-secret'));
        check(
          uncertain.toString(),
        ).not((it) => it.contains('reflected-read-error'));

        final reloaded = await store.load();
        check(
          reloaded.records.single.profile.apiKey,
        ).equals('committed-secret');
      },
    );

    test('treats a write response failure as commit-uncertain', () async {
      var settings = <String, dynamic>{
        'ui': <String, dynamic>{
          'directConnections': <String, dynamic>{
            'OPENAI_API_BASE_URLS': <String>[],
            'OPENAI_API_KEYS': <String>[],
            'OPENAI_API_CONFIGS': <String, dynamic>{},
          },
        },
      };
      final store = OpenWebUiDirectConnectionStore(
        serverId: 'server',
        accountId: 'account',
        readSettings: () async => _clone(settings),
        writeSettings: (payload) async {
          settings = _clone(payload);
          throw StateError('response lost after commit');
        },
      );
      final profile = DirectConnectionProfile(
        id: 'new-profile',
        name: 'New profile',
        adapterKey: kOpenAiCompatibleAdapterKey,
        baseUrl: 'https://new.test/v1',
        apiKey: 'committed-secret',
      );

      await check(
        store.add(profile),
      ).throws<OpenWebUiDirectConnectionCommitUncertainException>();

      final direct = (settings['ui'] as Map)['directConnections'] as Map;
      check(
        direct['OPENAI_API_BASE_URLS'],
      ).isA<List>().deepEquals(<String>['https://new.test/v1']);
      check(
        direct['OPENAI_API_KEYS'],
      ).isA<List>().deepEquals(<String>['committed-secret']);
    });

    test(
      'add repairs existing key alignment before appending a secret',
      () async {
        final server = _FakeSettingsServer(<String, dynamic>{
          'ui': <String, dynamic>{
            'directConnections': <String, dynamic>{
              'OPENAI_API_BASE_URLS': <String>[
                'https://a.test/v1',
                'https://b.test/v1',
              ],
              'OPENAI_API_KEYS': <String>['key-a'],
              'OPENAI_API_CONFIGS': <String, dynamic>{
                '0': <String, dynamic>{},
                '1': <String, dynamic>{},
              },
            },
          },
        });
        final store = OpenWebUiDirectConnectionStore(
          serverId: 'server',
          accountId: 'account',
          readSettings: server.read,
          writeSettings: server.write,
        );
        final profile = DirectConnectionProfile(
          id: 'new-profile',
          name: 'New profile',
          adapterKey: kOpenAiCompatibleAdapterKey,
          baseUrl: 'https://c.test/v1',
          apiKey: 'key-c',
        );

        final after = await store.add(profile);

        final direct = after.ui['directConnections'] as Map;
        check(
          direct['OPENAI_API_KEYS'],
        ).isA<List>().deepEquals(['key-a', '', 'key-c']);
        check(after.records[1].profile.apiKey).isNull();
        check(after.records[2].profile.apiKey).equals('key-c');

        final extraKeyServer = _FakeSettingsServer(<String, dynamic>{
          'ui': <String, dynamic>{
            'directConnections': <String, dynamic>{
              'OPENAI_API_BASE_URLS': <String>[
                'https://a.test/v1',
                'https://b.test/v1',
              ],
              'OPENAI_API_KEYS': <String>['key-a', 'key-b', 'stale-extra'],
              'OPENAI_API_CONFIGS': <String, dynamic>{},
            },
          },
        });
        final extraKeyStore = OpenWebUiDirectConnectionStore(
          serverId: 'server',
          accountId: 'account',
          readSettings: extraKeyServer.read,
          writeSettings: extraKeyServer.write,
        );

        final afterExtraKey = await extraKeyStore.add(profile);

        check(
          (afterExtraKey.ui['directConnections'] as Map)['OPENAI_API_KEYS'],
        ).isA<List>().deepEquals(['key-a', 'key-b', 'key-c']);
      },
    );

    test(
      'delete reindexes configs and add appends with aligned arrays',
      () async {
        final server = _FakeSettingsServer(<String, dynamic>{
          'ui': <String, dynamic>{
            'unrelated': 'preserved',
            'directConnections': <String, dynamic>{
              'documentExtra': true,
              'OPENAI_API_BASE_URLS': <String>[
                'https://a.test/v1/',
                'https://b.test/v1//',
                'https://c.test/v1',
              ],
              'OPENAI_API_KEYS': <String>['key-a', 'key-b', 'key-c', 'extra'],
              'OPENAI_API_CONFIGS': <String, dynamic>{
                '0': <String, dynamic>{'marker': 'a'},
                '1': <String, dynamic>{'marker': 'b'},
                '2': <String, dynamic>{'marker': 'c'},
              },
            },
          },
        });
        final store = OpenWebUiDirectConnectionStore(
          serverId: 'server',
          accountId: 'account',
          readSettings: server.read,
          writeSettings: server.write,
        );
        final beforeDelete = await store.load();

        final afterDelete = await store.delete(beforeDelete.records[1]);
        var direct = afterDelete.ui['directConnections'] as Map;
        check(
          direct['OPENAI_API_BASE_URLS'],
        ).isA<List>().deepEquals(['https://a.test/v1', 'https://c.test/v1']);
        check(
          direct['OPENAI_API_KEYS'],
        ).isA<List>().deepEquals(['key-a', 'key-c']);
        check(direct['OPENAI_API_CONFIGS']).isA<Map>().deepEquals({
          '0': {'marker': 'a'},
          '1': {'marker': 'c'},
        });
        check(direct['documentExtra']).isA<bool>().isTrue();
        check(afterDelete.ui['unrelated']).equals('preserved');
        check(afterDelete.records[1].profile.name).equals('c.test · 2');
        check(
          afterDelete.records[1].profile.id,
        ).equals(beforeDelete.records[2].profile.id);

        final addedProfile = DirectConnectionProfile(
          id: 'temporary-local-form-id',
          name: 'Form name is not persisted by Open WebUI',
          adapterKey: kOpenAiCompatibleAdapterKey,
          baseUrl: 'https://d.test/v1///',
          tags: const <String>['new'],
        );
        final afterAdd = await store.add(
          addedProfile,
          expectedDocumentRevision: afterDelete.documentRevision,
        );
        direct = afterAdd.ui['directConnections'] as Map;
        check(direct['OPENAI_API_BASE_URLS']).isA<List>().deepEquals([
          'https://a.test/v1',
          'https://c.test/v1',
          'https://d.test/v1',
        ]);
        check(
          direct['OPENAI_API_KEYS'],
        ).isA<List>().deepEquals(['key-a', 'key-c', '']);
        check((direct['OPENAI_API_CONFIGS'] as Map)['2']).isA<Map>().deepEquals(
          {
            'enable': true,
            'tags': [
              {'name': 'new'},
            ],
            'prefix_id': '',
            'model_ids': <String>[],
            'auth_type': 'none',
            'connection_type': 'external',
          },
        );
        check(
          afterAdd.records.last.profile.id,
        ).not((it) => it.equals(addedProfile.id));
        check(afterAdd.records.last.profile.apiKey).isNull();
        check(afterAdd.records.last.authType).equals('none');
      },
    );
  });
}

Map<String, dynamic> _oneConnectionSettings(String key) => <String, dynamic>{
  'ui': <String, dynamic>{
    'directConnections': <String, dynamic>{
      'OPENAI_API_BASE_URLS': <String>['https://one.test/v1'],
      'OPENAI_API_KEYS': <String>[key],
      'OPENAI_API_CONFIGS': <String, dynamic>{
        '0': <String, dynamic>{'auth_type': 'bearer'},
      },
    },
  },
};

Map<String, dynamic> _unsupportedConnectionSettings(String key) =>
    <String, dynamic>{
      'ui': <String, dynamic>{
        'directConnections': <String, dynamic>{
          'OPENAI_API_BASE_URLS': <String>['https://session.test/v1'],
          'OPENAI_API_KEYS': <String>[key],
          'OPENAI_API_CONFIGS': <String, dynamic>{
            '0': <String, dynamic>{
              'auth_type': 'session',
              'future': <String, dynamic>{'preserved': true},
            },
          },
        },
      },
    };

final class _FakeSettingsServer {
  _FakeSettingsServer(Map<String, dynamic> settings)
    : settings = _clone(settings);

  Map<String, dynamic> settings;
  Map<String, dynamic>? lastPayload;
  int readCount = 0;
  int writeCount = 0;
  int? failReadAt;

  Future<Map<String, dynamic>> read() async {
    readCount++;
    if (readCount == failReadAt) {
      throw Exception('reflected-read-error');
    }
    return _clone(settings);
  }

  Future<void> write(Map<String, dynamic> payload) async {
    writeCount++;
    lastPayload = _clone(payload);
    settings = _clone(payload);
  }
}

Map<String, dynamic> _clone(Map<String, dynamic> source) =>
    (jsonDecode(jsonEncode(source)) as Map).cast<String, dynamic>();
