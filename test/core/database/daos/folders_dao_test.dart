import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:collection/collection.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

const _deepEq = DeepCollectionEquality();

Map<String, dynamic> _rawFolder(
  String id, {
  String name = 'Folder',
  String? parentId,
  Object? createdAt = 1749700000,
  Object? updatedAt = 1749700050,
  Map<String, dynamic> extra = const {},
}) {
  return <String, dynamic>{
    'id': id,
    'name': name,
    'parent_id': parentId,
    'created_at': createdAt,
    'updated_at': updatedAt,
    ...extra,
  };
}

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  group('replaceServerFolders', () {
    test('projects columns and stores serverUpdatedAt/dirty/deleted', () async {
      await db.foldersDao.replaceServerFolders([
        _rawFolder('f-1', name: 'Work', parentId: 'f-root'),
      ]);
      final row = (await db.foldersDao.watchFolders().first).single;
      check(row.id).equals('f-1');
      check(row.name).equals('Work');
      check(row.parentId).equals('f-root');
      check(row.createdAt).equals(1749700000);
      check(row.updatedAt).equals(1749700050);
      check(row.serverUpdatedAt).equals(1749700050);
      check(row.dirty).isFalse();
      check(row.deleted).isFalse();
    });

    test('keeps every non-projected key verbatim in rawExtra', () async {
      final extra = <String, dynamic>{
        'user_id': 'u-1',
        'meta': {'color': '#ff0000'},
        'is_expanded': true,
        'data': {'note': 'hello'},
        'items': {
          'chats': ['c-1', 'c-2'],
        },
        'some_future_key': [1, 2, 3],
      };
      await db.foldersDao.replaceServerFolders([
        _rawFolder('f-extra', extra: extra),
      ]);
      final row = (await db.foldersDao.watchFolders().first).single;
      check(
        _deepEq.equals(jsonDecode(row.rawExtra), extra),
        because:
            'rawExtra must hold meta/is_expanded/data/items/unknown keys '
            'verbatim',
      ).isTrue();
    });

    test('maps non-int timestamps to 0', () async {
      await db.foldersDao.replaceServerFolders([
        _rawFolder('f-bad', createdAt: '2026-06-12T00:00:00Z', updatedAt: null),
      ]);
      final row = (await db.foldersDao.watchFolders().first).single;
      check(row.createdAt).equals(0);
      check(row.updatedAt).equals(0);
      check(row.serverUpdatedAt).equals(0);
    });

    test(
      'hard-deletes rows missing from the payload (full list endpoint)',
      () async {
        await db.foldersDao.replaceServerFolders([
          _rawFolder('f-1', name: 'A'),
          _rawFolder('f-2', name: 'B'),
          _rawFolder('f-3', name: 'C'),
        ]);
        await db.foldersDao.replaceServerFolders([
          _rawFolder('f-2', name: 'B renamed'),
        ]);
        final rows = await db.foldersDao.watchFolders().first;
        check(rows.map((r) => r.id).toList()).deepEquals(['f-2']);
        check(rows.single.name).equals('B renamed');
      },
    );

    test('an empty payload clears the table', () async {
      await db.foldersDao.replaceServerFolders([_rawFolder('f-1')]);
      await db.foldersDao.replaceServerFolders(const []);
      check(await db.foldersDao.watchFolders().first).isEmpty();
    });

    test('skips entries without a usable id', () async {
      await db.foldersDao.replaceServerFolders([
        <String, dynamic>{'name': 'No id', 'updated_at': 1},
        _rawFolder('f-ok'),
      ]);
      final rows = await db.foldersDao.watchFolders().first;
      check(rows.map((r) => r.id).toList()).deepEquals(['f-ok']);
    });
  });

  group('upsertServerFolder', () {
    test('upserts a single row without touching others', () async {
      await db.foldersDao.replaceServerFolders([
        _rawFolder('f-1', name: 'A'),
        _rawFolder('f-2', name: 'B'),
      ]);
      await db.foldersDao.upsertServerFolder(
        _rawFolder('f-1', name: 'A renamed'),
      );
      final rows = await db.foldersDao.watchFolders().first;
      check(rows.map((r) => r.name).toList()).deepEquals(['A renamed', 'B']);
    });
  });

  group('watchFolders', () {
    test('orders by name ASC and hides tombstones', () async {
      await db.foldersDao.replaceServerFolders([
        _rawFolder('f-c', name: 'Cherry'),
        _rawFolder('f-a', name: 'Apple'),
        _rawFolder('f-b', name: 'Banana'),
      ]);
      await (db.update(db.folders)..where((t) => t.id.equals('f-b'))).write(
        const FoldersCompanion(deleted: Value(true)),
      );
      final rows = await db.foldersDao.watchFolders().first;
      check(rows.map((r) => r.name).toList()).deepEquals(['Apple', 'Cherry']);
    });
  });

  group('hardDelete', () {
    test('removes the row', () async {
      await db.foldersDao.replaceServerFolders([
        _rawFolder('f-1'),
        _rawFolder('f-2'),
      ]);
      await db.foldersDao.hardDelete('f-1');
      final rows = await db.foldersDao.watchFolders().first;
      check(rows.map((r) => r.id).toList()).deepEquals(['f-2']);
    });
  });
}
