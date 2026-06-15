/// CDT-RFC-001 §6.1 / D-11 note round-trip invariant: a server note mapped into
/// a row and back must be byte-equivalent, with unknown top-level keys
/// (access_grants, access_control, user_id, future keys) preserved verbatim via
/// rawExtra — own-notes sync must never strip fields it doesn't model.
library;

import 'package:checks/checks.dart';
import 'package:collection/collection.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/mappers/note_mapper.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<Map<String, dynamic>> roundTrip(Map<String, dynamic> server) async {
    await db.into(db.notes).insertOnConflictUpdate(serverToNoteRow(server));
    final row = await db.notesDao.getNote(server['id'] as String);
    return noteRowToServer(row!);
  }

  group('note mapper round-trip (§6.1)', () {
    test(
      'a full note with access_grants + unknown keys round-trips equal',
      () async {
        final server = <String, dynamic>{
          'id': 'note-1',
          'user_id': 'user-42',
          'title': 'Quarterly plan',
          'data': {
            'content': {
              'md': '# Heading\n\nbody text',
              'html': '<h1>Heading</h1>',
            },
          },
          'meta': {
            'tags': ['planning', 'q3'],
          },
          'is_pinned': true,
          // Unknown-to-the-client keys that MUST survive via rawExtra (D-11):
          'access_grants': [
            {'id': 'g1', 'permission': 'read'},
            {'id': 'g2', 'permission': 'write'},
          ],
          'access_control': null,
          'a_future_server_key': {
            'nested': 7,
            'list': [1, 2, 3],
          },
          'created_at': 1718000000111222333,
          'updated_at': 1718000000999888777,
        };

        final out = await roundTrip(server);
        check(const DeepCollectionEquality().equals(out, server)).isTrue();
      },
    );

    test(
      'access_grants specifically survives (the D-11 own-notes rule)',
      () async {
        final server = <String, dynamic>{
          'id': 'note-2',
          'title': 'Shared',
          'data': {
            'content': {'md': 'x'},
          },
          'meta': {},
          'is_pinned': false,
          'access_grants': [
            {'id': 'g9', 'permission': 'read', 'group_id': 'team-7'},
          ],
          'created_at': 1718000000000000001,
          'updated_at': 1718000000000000002,
        };
        final out = await roundTrip(server);
        check(
          const DeepCollectionEquality().equals(
            out['access_grants'],
            server['access_grants'],
          ),
        ).isTrue();
      },
    );

    test('nanosecond timestamps are preserved with full precision', () async {
      const ns = 1718000000123456789;
      final server = <String, dynamic>{
        'id': 'note-3',
        'title': 'T',
        'data': {
          'content': {'md': 'y'},
        },
        'meta': {},
        'is_pinned': false,
        'created_at': ns,
        'updated_at': ns,
      };
      final out = await roundTrip(server);
      check(out['updated_at']).equals(ns);
      check(out['created_at']).equals(ns);
    });

    test('null server data and meta normalize to empty maps', () async {
      final server = <String, dynamic>{
        'id': 'note-null-json',
        'title': 'T',
        'data': null,
        'meta': null,
        'is_pinned': false,
        'created_at': 1,
        'updated_at': 2,
      };

      final out = await roundTrip(server);
      check(const DeepCollectionEquality().equals(out['data'], {})).isTrue();
      check(const DeepCollectionEquality().equals(out['meta'], {})).isTrue();
    });

    test('missing server id throws a descriptive argument error', () {
      final server = <String, dynamic>{
        'title': 'Missing id',
        'data': {
          'content': {'md': 'body'},
        },
        'meta': {},
        'is_pinned': false,
        'created_at': 1,
        'updated_at': 1,
      };

      check(() => serverToNoteRow(server)).throws<ArgumentError>();
    });
  });
}
