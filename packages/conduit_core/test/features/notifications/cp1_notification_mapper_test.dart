import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/notifications/models/app_notification.dart';
import 'package:conduit_core/features/notifications/services/cp1_notification_mapper.dart';
import 'package:test/test.dart';

/// The shared push test vectors, found from the repo root or this package.
Map<String, dynamic> _vectors() {
  var directory = Directory.current;
  while (true) {
    final file = File('${directory.path}/push/test-vectors/cp1_vectors.json');
    if (file.existsSync()) {
      return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError('push/test-vectors/cp1_vectors.json not found');
    }
    directory = parent;
  }
}

Map<String, dynamic> _reply({
  String src = 'owui',
  Map<String, dynamic> ids = const {'chat': 'c1', 'msg': 'm1'},
}) => {
  'v': 1,
  'k': 'reply',
  'src': src,
  'ids': ids,
  't': 'Title',
  'b': 'Body',
  'ts': 1760000000,
  'dk': 'chat:c1:m1',
  'g': 'chat:c1',
};

void main() {
  final vectors = _vectors();
  final cases = (vectors['cases'] as List).cast<Map<String, dynamic>>();
  final rejects = (vectors['payload_reject'] as List)
      .cast<Map<String, dynamic>>();

  group('shared vectors', () {
    for (final vector in cases) {
      test('${vector['name']} maps to its app dedup key', () {
        final plaintext = utf8.decode(
          base64Url.decode(base64Url.normalize(vector['plaintext'] as String)),
        );
        final notification = appNotificationFromCp1Json(
          plaintext,
          scope: vector['scope'] as String,
        );

        check(notification).isNotNull();
        check(notification!.dedupKey).equals(vector['app_dedup_key'] as String);
        check(notification.scope).equals(vector['scope'] as String);
        // The decoded map maps the same way as its JSON text.
        check(
          appNotificationFromCp1(
            vector['payload'],
            scope: vector['scope'] as String,
          ),
        ).equals(notification);
      });
    }

    for (final vector in rejects) {
      test('${vector['name']} is rejected', () {
        check(
          appNotificationFromCp1Json(
            vector['plaintext'] as String,
            scope: 'owui:acct-1',
          ),
        ).isNull();
      });
    }
  });

  group('kinds and targets', () {
    AppNotification mapCase(String name) {
      final vector = cases.singleWhere((c) => c['name'] == name);
      return appNotificationFromCp1(
        vector['payload'],
        scope: vector['scope'] as String,
      )!;
    }

    test('an Open WebUI reply opens its chat', () {
      final n = mapCase('owui_reply');
      check(n.kind).equals(NotificationKind.chatCompletion);
      check(n.sourceId).equals('4f1c2a7e');
      check(n.title).equals('Trip ideas');
      check(n.body).equals('Here are three routes along the coast:');
      check(n.group).equals('chat:4f1c2a7e');
    });

    test('a failed reply is replyFailed', () {
      final n = mapCase('owui_reply_failed');
      check(n.kind).equals(NotificationKind.replyFailed);
      check(n.sourceId).equals('4f1c2a7e');
    });

    test('a channel message names its author and channel', () {
      final n = mapCase('owui_channel_unicode');
      check(n.kind).equals(NotificationKind.channelMessage);
      check(n.sourceId).equals('ch-9');
      check(n.title).equals('Zoë 🦊 (#général)');
    });

    test('a direct message names only its sender', () {
      final n = appNotificationFromCp1({
        ..._reply(ids: const {'channel': 'dm-1', 'msg': 'm-1'}),
        'k': 'channel',
        't': 'Zoë',
        'a': 'Zoë',
        'dk': 'channel:dm-1:m-1',
      }, scope: 'owui:acct-1')!;
      check(n.title).equals('Zoë');
    });

    test('a Hermes reply opens its session', () {
      final n = mapCase('hermes_reply');
      check(n.kind).equals(NotificationKind.chatCompletion);
      check(n.sourceId).equals('20261010_101500_ab12cd');
      check(n.group).equals('hermes:20261010_101500_ab12cd');
    });

    test('a Hermes cron result opens its job', () {
      final n = mapCase('hermes_cron');
      check(n.kind).equals(NotificationKind.scheduledTask);
      check(n.sourceId).equals('a1b2c3d4e5f6');
    });

    test('a Hermes delivery from no job is kept, under its dedup key', () {
      Map<String, dynamic> delivery(Map<String, dynamic> ids) => {
        ..._reply(src: 'hermes', ids: ids),
        'k': 'cron',
        't': 'Agent',
        'b': 'Your build finished.',
        'dk': 'cron:send:r-1',
        'g': null,
      };
      // The plugin leaves the job out, or (older plugins) sends it empty.
      for (final ids in [
        const <String, dynamic>{'run': 'r-1'},
        const <String, dynamic>{'job': '', 'run': 'r-1'},
      ]) {
        final n = appNotificationFromCp1(delivery(ids), scope: 'hermes:c-1')!;
        check(n.kind).equals(NotificationKind.scheduledTask);
        check(n.sourceId).equals('cron:send:r-1');
        check(n.dedupKey).equals('hermes:c-1|cron:send:r-1');
        check(n.body).equals('Your build finished.');
      }
    });

    test('a test push carries its nonce', () {
      final n = mapCase('test');
      check(n.kind).equals(NotificationKind.pushTest);
      check(n.sourceId).equals('Nn3wq0Xk');
      check(n.group).isNull();
    });
  });

  group('rejects', () {
    test('a source that does not match the scope', () {
      check(
        appNotificationFromCp1(_reply(), scope: 'hermes:conn-1'),
      ).isNull();
      check(
        appNotificationFromCp1(
          _reply(src: 'hermes', ids: const {'session': 's', 'turn': 't'}),
          scope: 'owui:acct-1',
        ),
      ).isNull();
      check(appNotificationFromCp1(_reply(), scope: 'direct')).isNull();
    });

    test('an unparseable scope', () {
      check(appNotificationFromCp1(_reply(), scope: 'owui:')).isNull();
      check(appNotificationFromCp1(_reply(), scope: 'nope')).isNull();
    });

    test('a reply without the id it points at', () {
      check(
        appNotificationFromCp1(
          _reply(ids: const {'msg': 'm1'}),
          scope: 'owui:acct-1',
        ),
      ).isNull();
    });

    test('known keys of the wrong type', () {
      check(
        appNotificationFromCp1({..._reply(), 't': 3}, scope: 'owui:acct-1'),
      ).isNull();
      check(
        appNotificationFromCp1({..._reply(), 'ids': 'c1'}, scope: 'owui:a'),
      ).isNull();
      check(
        appNotificationFromCp1({..._reply(), 'v': '1'}, scope: 'owui:a'),
      ).isNull();
    });

    test('a channel message from Hermes and a cron result from Open WebUI', () {
      check(
        appNotificationFromCp1({
          ..._reply(src: 'hermes', ids: const {'channel': 'x'}),
          'k': 'channel',
        }, scope: 'hermes:conn-1'),
      ).isNull();
      check(
        appNotificationFromCp1({
          ..._reply(ids: const {'job': 'j'}),
          'k': 'cron',
        }, scope: 'owui:acct-1'),
      ).isNull();
    });
  });

  test('unknown keys are ignored', () {
    final n = appNotificationFromCp1({
      ..._reply(),
      'future': {'x': 1},
    }, scope: 'owui:acct-1');
    check(n).isNotNull();
    check(n!.dedupKey).equals('owui:acct-1|chat:c1:m1');
  });
}
