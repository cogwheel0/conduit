import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:collection/collection.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:test/test.dart';

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

  group('patchFolderDataWithOutbox', () {
    const files = [
      {'type': 'collection', 'id': 'kb-1', 'name': 'Docs'},
    ];
    final project = <String, dynamic>{
      'user_id': 'owner',
      'meta': {'icon': 'briefcase'},
      'is_expanded': true,
      'items': {
        'chats': ['c-1'],
      },
      'data': {
        'system_prompt': 'Be brief',
        'files': files,
        'custom': {'keep': 1},
      },
      'some_future_key': [1, 2],
    };

    Future<Map<String, dynamic>> storedExtra(String id) async =>
        jsonDecode((await db.foldersDao.getFolder(id))!.rawExtra)
            as Map<String, dynamic>;

    Future<List<Map<String, dynamic>>> queuedPayloads(String id) async => [
      for (final op in await db.outboxDao.pendingForChat(id))
        jsonDecode(op.payload) as Map<String, dynamic>,
    ];

    Future<void> patch(String id, Map<String, dynamic> dataPatch) =>
        db.foldersDao.patchFolderDataWithOutbox(id: id, dataPatch: dataPatch);

    Future<void> expectRefused(
      Future<void> write,
      FolderProjectWriteFailure reason,
    ) async {
      await check(write).throws<FolderProjectWriteException>(
        (error) => error.has((e) => e.reason, 'reason').equals(reason),
      );
    }

    test('changes only the edited key and queues only that key', () async {
      await db.foldersDao.replaceServerFolders([
        _rawFolder('p', extra: project),
      ]);

      await patch('p', {
        'model_ids': ['m-a', 'm-b'],
      });

      final extra = await storedExtra('p');
      check(
        _deepEq.equals(extra, {
          ...project,
          'data': {
            ...(project['data'] as Map<String, dynamic>),
            'model_ids': ['m-a', 'm-b'],
          },
        }),
        because: 'system prompt, files, unknown data/meta/items keys survive',
      ).isTrue();
      final row = (await db.foldersDao.getFolder('p'))!;
      check(row.dirty).isTrue();
      check(row.serverUpdatedAt).equals(1749700050);
      check(await queuedPayloads('p')).deepEquals([
        {
          'folderId': 'p',
          'createIfAbsent': false,
          'data': {
            'model_ids': ['m-a', 'm-b'],
          },
        },
      ]);
    });

    test('patches the current data, not what the editor opened with', () async {
      await db.foldersDao.replaceServerFolders([
        _rawFolder('p', extra: project),
      ]);
      // The form was opened on this copy; another client then changed the
      // prompt and a pull landed it before Save.
      await db.foldersDao.replaceServerFolders([
        _rawFolder(
          'p',
          extra: {
            ...project,
            'data': {
              ...(project['data'] as Map<String, dynamic>),
              'system_prompt': 'Changed elsewhere',
            },
          },
        ),
      ]);

      await patch('p', {'files': <Object?>[]});

      final data = (await storedExtra('p'))['data'] as Map<String, dynamic>;
      check(data['system_prompt']).equals('Changed elsewhere');
      check(data['files']).isA<List<dynamic>>().isEmpty();
      final queued = await queuedPayloads('p');
      check(queued.single['data'])
          .isA<Map<String, dynamic>>()
          .deepEquals({'files': <Object?>[]});
    });

    test('two edits before the first push reach the server as one', () async {
      await db.foldersDao.replaceServerFolders([
        _rawFolder('p', extra: project),
      ]);

      await patch('p', {
        'files': [
          {'type': 'file', 'id': 'f-9', 'name': 'Notes.pdf'},
        ],
      });
      await patch('p', {
        'model_ids': ['m-a'],
      });

      final queued = await queuedPayloads('p');
      check(queued).length.equals(1);
      check(queued.single['data']).isA<Map<String, dynamic>>().deepEquals({
        'files': [
          {'type': 'file', 'id': 'f-9', 'name': 'Notes.pdf'},
        ],
        'model_ids': ['m-a'],
      });
      final data = (await storedExtra('p'))['data'] as Map<String, dynamic>;
      check(data['system_prompt']).equals('Be brief');
      check(data['model_ids']).isA<List<dynamic>>().deepEquals(['m-a']);
    });

    test(
      'a recipient with a write grant can edit; a read grant cannot',
      () async {
        await db.foldersDao.replaceServerFolders([
          _rawFolder(
            'write',
            extra: {'shared': true, 'permission': 'write', ...project},
          ),
          _rawFolder(
            'read',
            extra: {'shared': true, 'permission': 'read', ...project},
          ),
        ]);

        await patch('write', {
          'model_ids': ['m-a'],
        });
        await expectRefused(
          patch('read', {
            'model_ids': ['m-a'],
          }),
          FolderProjectWriteFailure.readOnly,
        );

        check(await queuedPayloads('write')).length.equals(1);
        check(await queuedPayloads('read')).isEmpty();
        check((await db.foldersDao.getFolder('read'))!.dirty).isFalse();
        check(
          _deepEq.equals(await storedExtra('read'), {
            'shared': true,
            'permission': 'read',
            ...project,
          }),
        ).isTrue();
      },
    );

    test('a grant downgraded since the editor opened is refused at commit', () async {
      await db.foldersDao.replaceServerFolders([
        _rawFolder(
          'p',
          extra: {'shared': true, 'permission': 'write', ...project},
        ),
      ]);
      // The editor opened while the grant was `write`; a pull then lowered it.
      await db.foldersDao.replaceServerFolders([
        _rawFolder(
          'p',
          extra: {'shared': true, 'permission': 'read', ...project},
        ),
      ]);

      await expectRefused(
        patch('p', {
          'model_ids': ['m-a'],
        }),
        FolderProjectWriteFailure.readOnly,
      );
      check(await queuedPayloads('p')).isEmpty();
    });

    test('a server verdict of no write access refuses the next edit', () async {
      await db.foldersDao.replaceServerFolders([
        _rawFolder(
          'p',
          extra: {'shared': true, 'permission': 'write', ...project},
        ),
      ]);
      // An unsent edit already waits on the row.
      await patch('p', {
        'model_ids': ['m-offline'],
      });
      final before = await queuedPayloads('p');

      await db.foldersDao.recordWriteAccess(id: 'p', writeAccess: false);

      // Only the verdict is added; the unsent data, the dirty flag, the cached
      // grant and the queued request are as they were.
      final extra = await storedExtra('p');
      check(extra['write_access']).equals(false);
      final data = extra['data'] as Map<String, dynamic>;
      check(data['model_ids']).isA<List<dynamic>>().deepEquals(['m-offline']);
      check(data['system_prompt']).equals('Be brief');
      check(extra['permission']).equals('write');
      check((await db.foldersDao.getFolder('p'))!.dirty).isTrue();
      check(await queuedPayloads('p')).deepEquals(before);

      await expectRefused(
        patch('p', {
          'model_ids': ['m-a'],
        }),
        FolderProjectWriteFailure.readOnly,
      );
      check(await queuedPayloads('p')).deepEquals(before);

      // A later verdict that allows the write lifts it again, and a folder
      // that is not there is not invented.
      await db.foldersDao.recordWriteAccess(id: 'p', writeAccess: true);
      check((await storedExtra('p')).containsKey('write_access')).isFalse();
      await patch('p', {
        'model_ids': ['m-a'],
      });
      await db.foldersDao.recordWriteAccess(id: 'nope', writeAccess: false);
      check(await db.foldersDao.getFolder('nope')).isNull();
    });

    test('a missing or deleted folder is not written', () async {
      await db.foldersDao.replaceServerFolders([
        _rawFolder('gone', extra: project),
      ]);
      await db.foldersDao.tombstoneFolderWithOutbox('gone');
      final queuedBefore = (await db.outboxDao.pendingForChat('gone')).length;

      await expectRefused(
        patch('gone', {'files': <Object?>[]}),
        FolderProjectWriteFailure.unavailable,
      );
      await expectRefused(
        patch('never-existed', {'files': <Object?>[]}),
        FolderProjectWriteFailure.unavailable,
      );

      check((await db.outboxDao.pendingForChat('gone')).length)
          .equals(queuedBefore);
      check(await db.foldersDao.getFolder('never-existed')).isNull();
    });
  });

  // The server's folder list is lean (FolderNameIdResponse): it never carries
  // `data`, so project defaults reach the row from a save or a folder read by
  // id and have to outlive every pull.
  group('project data and the lean folder list', () {
    final saved = <String, dynamic>{
      'system_prompt': 'Be brief',
      'model_ids': ['m-a'],
    };

    Map<String, dynamic> lean({
      int updatedAt = 1749700050,
      Map<String, dynamic> extra = const {},
    }) => _rawFolder(
      'p',
      updatedAt: updatedAt,
      extra: {'meta': null, 'is_expanded': false, 'unread_count': 0, ...extra},
    );

    Future<Map<String, dynamic>> storedExtra() async =>
        jsonDecode((await db.foldersDao.getFolder('p'))!.rawExtra)
            as Map<String, dynamic>;

    Future<void> record(
      FolderRow requestedFor,
      Value<Map<String, dynamic>?> data, {
      int? updatedAt = 1749700050,
    }) => db.foldersDao.recordServerFolderData(
      requestedFor: requestedFor,
      data: data,
      serverUpdatedAt: updatedAt,
    );

    setUp(() async {
      await db.foldersDao.replaceServerFolders([
        _rawFolder(
          'p',
          extra: {'data': saved, 'shared': true, 'permission': 'write'},
        ),
      ]);
    });

    test(
      'a pull or upsert without data keeps it; an explicit data wins',
      () async {
        await db.foldersDao.replaceServerFolders([
          lean(
            updatedAt: 1749700060,
            extra: {'shared': true, 'permission': 'write'},
          ),
        ]);
        var row = (await db.foldersDao.getFolder('p'))!;
        var extra = await storedExtra();
        check(extra['data']).isA<Map<String, dynamic>>().deepEquals(saved);
        // The rest of the row is still what the pull says.
        check(row.serverUpdatedAt).equals(1749700060);
        check(extra['unread_count']).equals(0);
        check(extra['permission']).equals('write');

        await db.foldersDao.upsertServerFolder(lean(updatedAt: 1749700070));
        check((await storedExtra())['data'])
            .isA<Map<String, dynamic>>()
            .deepEquals(saved);

        await db.foldersDao.replaceServerFolders([
          lean(
            extra: {
              'data': {'system_prompt': 'Elsewhere'},
            },
          ),
        ]);
        check((await storedExtra())['data'])
            .isA<Map<String, dynamic>>()
            .deepEquals({'system_prompt': 'Elsewhere'});

        // A data the server states as null is a clear, not an omission.
        await db.foldersDao.replaceServerFolders([
          lean(extra: {'data': null}),
        ]);
        extra = await storedExtra();
        check(extra.containsKey('data')).isTrue();
        check(extra['data']).isNull();
      },
    );

    test('a lean pull leaves an unsent edit and its queued request', () async {
      await db.foldersDao.patchFolderDataWithOutbox(
        id: 'p',
        dataPatch: {
          'model_ids': ['m-offline'],
        },
      );

      await db.foldersDao.replaceServerFolders([lean()]);

      final data = (await storedExtra())['data'] as Map<String, dynamic>;
      check(data['model_ids']).isA<List<dynamic>>().deepEquals(['m-offline']);
      check((await db.outboxDao.pendingForChat('p')).length).equals(1);
    });

    test('server data is stored, cleared or ignored without touching the '
        'rest of the row', () async {
      final before = (await db.foldersDao.getFolder('p'))!;
      final other = {
        'system_prompt': 'Changed elsewhere',
        'model_ids': ['m-b'],
      };

      await record(before, Value(other));
      var row = (await db.foldersDao.getFolder('p'))!;
      var extra = await storedExtra();
      check(extra['data']).isA<Map<String, dynamic>>().deepEquals(other);
      check(extra['shared']).equals(true);
      check(extra['permission']).equals('write');
      check(row.dirty).isFalse();
      check(row.serverUpdatedAt).equals(before.serverUpdatedAt);
      check(row.name).equals(before.name);
      check(await db.outboxDao.pendingForChat('p')).isEmpty();

      // An answer without a data key says nothing.
      await record(row, const Value.absent());
      check((await storedExtra())['data'])
          .isA<Map<String, dynamic>>()
          .deepEquals(other);

      await record(row, const Value(null));
      extra = await storedExtra();
      check(extra.containsKey('data')).isTrue();
      check(extra['data']).isNull();
    });

    test(
      'unsent edits, tombstones and rows that are not there are kept',
      () async {
        final before = (await db.foldersDao.getFolder('p'))!;
        await db.foldersDao.patchFolderDataWithOutbox(
          id: 'p',
          dataPatch: {
            'model_ids': ['m-offline'],
          },
        );

        await record(before, const Value(null));
        var data = (await storedExtra())['data'] as Map<String, dynamic>;
        check(data['model_ids']).isA<List<dynamic>>().deepEquals(['m-offline']);

        await db.foldersDao.tombstoneFolderWithOutbox('p');
        await record(before, Value({'model_ids': <Object?>[]}));
        data = (await storedExtra())['data'] as Map<String, dynamic>;
        check(data['model_ids']).isA<List<dynamic>>().deepEquals(['m-offline']);

        await record(
          (await db.foldersDao.getFolder('p'))!.copyWith(id: 'never-existed'),
          Value(saved),
        );
        check(await db.foldersDao.getFolder('never-existed')).isNull();
      },
    );

    test('a read held up behind newer data does not replace it', () async {
      final heldRead = (await db.foldersDao.getFolder('p'))!;

      // The row's data changes while the read is out, with no newer
      // `updated_at` to tell the two copies apart.
      await db.foldersDao.replaceServerFolders([
        lean(
          extra: {
            'data': {'system_prompt': 'Newer'},
          },
        ),
      ]);
      await record(heldRead, Value(saved));
      check((await storedExtra())['data'])
          .isA<Map<String, dynamic>>()
          .deepEquals({'system_prompt': 'Newer'});

      // An answer older than what the row already knows is dropped even when
      // the data was not touched since the read began.
      final current = (await db.foldersDao.getFolder('p'))!;
      await record(current, Value(saved), updatedAt: 1749700000);
      check((await storedExtra())['data'])
          .isA<Map<String, dynamic>>()
          .deepEquals({'system_prompt': 'Newer'});
    });
  });
}
