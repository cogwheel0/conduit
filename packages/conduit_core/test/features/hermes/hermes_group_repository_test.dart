import 'dart:convert';

import 'package:test/test.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot_group.dart';
import 'package:conduit_core/features/hermes/services/hermes_group_repository.dart';

HermesGroupMessage message(
  String id, {
  String text = 'Reply',
  int minute = 0,
  String? bot,
}) => HermesGroupMessage(
  id: id,
  text: text,
  at: DateTime(2026, 10, 11, 12, minute),
  botProfile: bot,
  speaker: bot ?? 'You',
);
HermesBotGroup room({String id = 'team', List<HermesGroupMessage>? messages}) =>
    HermesBotGroup(
      key: 'id:$id',
      roomId: id,
      name: 'Build team',
      memberProfiles: const ['research', 'coding'],
      coordinator: 'coding',
      purpose: 'Compare and build',
      messages: messages ?? [message('one')],
    );

class Gateway {
  final Map<String, dynamic> meta = {};
  final Map<String, dynamic> revisions = {
    hermesGroupsNamespace: 0,
    conduitGroupOptionsNamespace: 0,
  };
  final List<({String method, Map<String, dynamic> parameters})> requests = [];
  bool protocol = true, cas = true, conflict = false, confirm = true;
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, dynamic> parameters,
  ) async {
    requests.add((method: method, parameters: parameters));
    if (method == 'profiles.list')
      return {
        'bot_mode_protocol': protocol,
        'profiles': [
          {
            'name': 'default',
            'ui_meta': jsonDecode(jsonEncode(meta)),
            if (cas) 'ui_meta_revisions': Map.of(revisions),
          },
        ],
      };
    expect(method, 'profiles.configure');
    expect(parameters['name'], 'default');
    expect(parameters['profile'], 'default');
    final expected = parameters['ui_meta_expected_revisions'] as Map;
    if (conflict) throw StateError('Metadata revision conflict');
    for (final entry in expected.entries) {
      expect(entry.value, revisions[entry.key]);
    }
    final patches = parameters['ui_meta'] as Map;
    for (final entry in patches.entries) {
      meta[entry.key as String] = entry.value;
      revisions[entry.key as String] = (revisions[entry.key] as int) + 1;
    }
    return {
      'applied': {
        'ui_meta': true,
        if (confirm) 'ui_meta_revisions': Map.of(revisions),
      },
    };
  }

  HermesGroupRepository get repository => HermesGroupRepository(request);
}

void main() {
  test(
    'saves Hermes version-3 rooms and independent coordinator options with CAS',
    () async {
      final gateway = Gateway();
      final saved = await gateway.repository.save(room());
      final snapshot = gateway.meta[hermesGroupsNamespace] as Map;
      expect(snapshot['version'], 3);
      expect((snapshot['rooms'] as Map)['id:team']['members'], [
        {'name': 'research', 'handle': 'research'},
        {'name': 'coding', 'handle': 'coding'},
      ]);
      final read = (await gateway.repository.list()).single;
      expect(read.name, saved.name);
      expect(read.coordinator, 'coding');
      expect(read.purpose, 'Compare and build');
      expect(read.messages.single.text, 'Reply');
    },
  );
  test(
    'preserves unrelated rooms, options and deleted-room tombstones',
    () async {
      final gateway = Gateway();
      await gateway.repository.save(room(id: 'other'));
      (gateway.meta[hermesGroupsNamespace] as Map)['deleted'] = {
        'id:removed': 2,
      };
      await gateway.repository.save(room());
      final snapshot = gateway.meta[hermesGroupsNamespace] as Map;
      expect((snapshot['rooms'] as Map).length, 2);
      expect(snapshot['deleted'], {'id:removed': 2});
      expect(
        (gateway.meta[conduitGroupOptionsNamespace] as Map).containsKey(
          'id:other',
        ),
        isTrue,
      );
    },
  );
  test('merges a concurrent remote reply rather than losing it', () async {
    final gateway = Gateway();
    await gateway.repository.save(
      room(messages: [message('remote', text: 'Remote update', minute: 1)]),
    );
    final saved = await gateway.repository.save(
      room(messages: [message('local', text: 'Local update', minute: 2)]),
    );
    expect(saved.messages.map((m) => m.id), ['remote', 'local']);
  });
  test('deduplicates message IDs across saves', () async {
    final gateway = Gateway();
    await gateway.repository.save(room());
    await gateway.repository.save(room());
    expect((await gateway.repository.list()).single.messages.length, 1);
  });
  test('bounds shared history while returning full device history', () async {
    final gateway = Gateway();
    final log = [for (var i = 0; i < 25; i++) message('m-$i', minute: i)];
    final saved = await gateway.repository.save(room(messages: log));
    expect(saved.messages.length, 25);
    final synced = (await gateway.repository.list()).single;
    expect(synced.messages.length, 16);
    expect(synced.omitted, 9);
    expect(synced.messages.first.id, 'm-9');
  });
  test(
    'bounds long shared messages without replacing the full local reply',
    () async {
      final gateway = Gateway();
      final text = 'Long answer ' * 1000;
      final saved = await gateway.repository.save(
        room(messages: [message('long', text: text)]),
      );
      expect(saved.messages.single.text, text);
      expect(
        (await gateway.repository.list()).single.messages.single.text.length,
        lessThanOrEqualTo(1200),
      );
    },
  );
  test('never resurrects a remotely deleted room', () async {
    final gateway = Gateway()
      ..meta[hermesGroupsNamespace] = {
        'version': 3,
        'rooms': {},
        'deleted': {'id:team': 1},
      };
    await expectLater(gateway.repository.save(room()), throwsStateError);
    expect(
      gateway.requests.where((r) => r.method == 'profiles.configure'),
      isEmpty,
    );
  });
  test(
    'rejects groups on gateways without revision guards before mutation',
    () async {
      final gateway = Gateway()..cas = false;
      await expectLater(
        gateway.repository.save(room()),
        throwsUnsupportedError,
      );
      expect(
        gateway.requests.where((r) => r.method == 'profiles.configure'),
        isEmpty,
      );
    },
  );
  test('surfaces a CAS conflict and never retries the write', () async {
    final gateway = Gateway()..conflict = true;
    await expectLater(gateway.repository.save(room()), throwsStateError);
    expect(
      gateway.requests.where((r) => r.method == 'profiles.configure').length,
      1,
    );
  });
  test(
    'requires the gateway to acknowledge advancing both namespaces',
    () async {
      final gateway = Gateway()..confirm = false;
      await expectLater(gateway.repository.save(room()), throwsStateError);
    },
  );
  test(
    'rejects invalid participant counts before touching a profile',
    () async {
      final gateway = Gateway();
      await expectLater(
        gateway.repository.save(room().copyWith(memberProfiles: ['research'])),
        throwsArgumentError,
      );
      expect(gateway.requests, isEmpty);
    },
  );
  test('rejects gateways without Bot Mode', () async {
    final gateway = Gateway()..protocol = false;
    await expectLater(gateway.repository.list(), throwsUnsupportedError);
  });
  test(
    'keeps member session ownership distinct from canonical bot chats',
    () async {
      final gateway = Gateway();
      await gateway.repository.save(
        room().copyWith(
          memberSessions: {
            'research': 'group-research',
            'coding': 'group-coding',
          },
        ),
      );
      final group = (await gateway.repository.list()).single;
      expect(group.memberSessions, {
        'research': 'group-research',
        'coding': 'group-coding',
      });
    },
  );
  test(
    'bot drafts validate profile scope and do not share auth by default',
    () {
      const draft = HermesBotDraft(
        profile: 'research',
        title: 'Researcher',
        description: 'Find sources',
        instructions: 'Cite sources',
      );
      draft.validate();
      expect(draft.shareAuth, isFalse);
      expect(
        () => const HermesBotDraft(
          profile: '../other',
          title: 'Bot',
          description: '',
          instructions: '',
        ).validate(),
        throwsArgumentError,
      );
    },
  );
  test('rejects a stale room membership edit before a mutation', () async {
    final gateway = Gateway();
    final original = await gateway.repository.save(room());
    await gateway.repository.save(original.copyWith(name: 'Changed elsewhere'));
    final writes = gateway.requests
        .where((r) => r.method == 'profiles.configure')
        .length;
    await expectLater(gateway.repository.save(original), throwsStateError);
    expect(
      gateway.requests.where((r) => r.method == 'profiles.configure').length,
      writes,
    );
  });
  test(
    'migrates legacy room keys and tombstones without removing other rooms',
    () async {
      final gateway = Gateway()
        ..meta[hermesGroupsNamespace] = {
          'version': 2,
          'rooms': {'Legacy': room().roomJson()},
          'deleted': {'Removed': 2},
        };
      final legacy = (await gateway.repository.list()).single;
      expect(legacy.key, 'name:Legacy');
      expect(legacy.name, 'Legacy');
      await gateway.repository.save(room(id: 'new'));
      final snapshot = gateway.meta[hermesGroupsNamespace] as Map;
      expect((snapshot['rooms'] as Map).keys, contains('name:Legacy'));
      expect(snapshot['deleted'], {'name:Removed': 2});
    },
  );
  test(
    'keeps gateway member provenance and tool detail out of shared snapshots',
    () async {
      final gateway = Gateway();
      final scoped = room().copyWith(
        raw: {
          'members': [
            {
              'name': 'research',
              'connectionId': 'elsewhere',
              'sourceScoped': true,
            },
            {'name': 'coding'},
          ],
        },
        messages: [
          HermesGroupMessage(
            id: 'tool',
            text: 'Complete',
            at: DateTime(2026),
            botProfile: 'research',
            toolUpdates: [
              ChatStatusUpdate(action: 'terminal', description: 'Ran command'),
            ],
          ),
        ],
      );
      await gateway.repository.save(scoped);
      final raw =
          (gateway.meta[hermesGroupsNamespace] as Map)['rooms']['id:team']
              as Map;
      expect(raw['members'][0]['connectionId'], 'elsewhere');
      expect(raw['log'][0].containsKey('toolUpdates'), isFalse);
      expect((await gateway.repository.list()).single.hasScopedMembers, isTrue);
    },
  );
  test(
    'invalid numeric dates are rejected instead of crashing room discovery',
    () {
      expect(
        HermesGroupMessage.fromJson({'text': 'hello', 'at': 1e100}),
        isNull,
      );
    },
  );
}
