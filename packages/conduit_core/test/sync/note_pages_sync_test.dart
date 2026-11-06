/// Note sync against Open WebUI 0.12.5, where a note holds pages and its
/// attachments are links in the page content: what a save sends, how a note
/// stored before the server was upgraded gets there, and what is kept local.
library;

import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/daos/outbox_dao.dart';
import 'package:conduit_core/database/mappers/note_mapper.dart';
import 'package:conduit_core/features/notes/utils/note_page_data.dart';
import 'package:conduit_core/sync/chat_locks.dart';
import 'package:conduit_core/sync/id_remapper.dart';
import 'package:conduit_core/sync/note_adapter.dart';
import 'package:conduit_core/sync/note_sync.dart';
import 'package:conduit_core/sync/sync_api_client.dart';
import 'package:conduit_core/sync/sync_entity_adapter.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:test/test.dart';

import 'package:conduit_core/testing.dart';

const int kT1 = 1718000000000000000; // ns
const int kT2 = kT1 + 60 * 1000 * 1000 * 1000;

void main() {
  late FakeOpenWebUiServer server;
  late FakeSyncApiClient client;
  late AppDatabase db;
  late NoteLocks locks;
  late IdRemapper remapper;
  bool? pagesServer;

  setUp(() {
    pagesServer = null;
    server = FakeOpenWebUiServer();
    client = FakeSyncApiClient(server);
    db = AppDatabase(NativeDatabase.memory());
    locks = NoteLocks();
    remapper = IdRemapper(db);
  });
  tearDown(() async {
    await remapper.dispose();
    await db.close();
  });

  NotePushSync push() => NotePushSync(
    client: client,
    db: db,
    noteLocks: locks,
    remapper: remapper,
    currentAccountId: () => FakeOpenWebUiServer.userId,
    notePagesServer: () => pagesServer,
  );

  Future<AdapterPullResult> pull() => runPullFor(
    NoteAdapter(
      pull: NotePullSync(
        client: client,
        db: db,
        locks: locks,
        remapper: remapper,
        readerAccountId: () => FakeOpenWebUiServer.userId,
      ),
      push: push(),
    ),
    db: db,
  );

  /// Edits the stored note the way the editor's durable save does
  /// (`durableUpdateNote`): the content applied to [pageId], the row dirty, a
  /// `noteUpdate` queued.
  Future<void> editContent(
    String id,
    String md, {
    String? title,
    String? pageId,
  }) {
    return locks.runExclusive(id, () async {
      final row = (await db.notesDao.getNote(id))!;
      final data = applyNoteContentEdit(decodeNoteData(row.data), {
        'content': {'json': null, 'html': '', 'md': md},
      }, pageId: pageId);
      await db.notesDao.updateNoteWithOutbox(
        id,
        title: title == null ? const Value.absent() : Value(title),
        data: Value(jsonEncode(data)),
        localUpdatedAtNs: kT2,
        enqueue: true,
      );
    });
  }

  Map<String, dynamic> twoPages() => {
    'pages': [
      {
        'id': 'main',
        'title': 'Doc',
        'content': {'json': null, 'html': '', 'md': 'one'},
      },
      {
        'id': 'p2',
        'parent_id': null,
        'title': 'Two',
        'content': {'json': null, 'html': '', 'md': 'two'},
      },
    ],
  };

  Map<String, dynamic> serverData(String id) =>
      server.getNoteById(id)!['data'] as Map<String, dynamic>;

  String serverPageMd(String id, String pageId) {
    final pages = (serverData(id)['pages'] as List).cast<Map>();
    final page = pages.firstWhere((p) => p['id'] == pageId);
    return (page['content'] as Map)['md'] as String;
  }

  test('a save of a note read from 0.12.5 sends only its content, to its '
      'page, and keeps the server shape', () async {
    server.notePagesEnabled = true;
    server.seedNote(
      id: 'n1',
      title: 'Doc',
      data: {
        'content': {'json': null, 'html': '', 'md': 'v1'},
      },
      createdAt: kT1,
      updatedAt: kT1,
    );
    await pull();
    final pulled = decodeNoteData((await db.notesDao.getNote('n1'))!.data);
    check(pulled.keys).contains('pages');

    await editContent('n1', 'v2');
    await push().pushNoteUpdate('n1', const {});

    check(client.notePatches).length.equals(1);
    final patch = client.notePatches.single.patch;
    check(patch['page_id']).equals('main');
    check((patch['data'] as Map).keys.toSet()).deepEquals({'content'});
    check(serverPageMd('n1', 'main')).equals('v2');

    final row = (await db.notesDao.getNote('n1'))!;
    check(row.dirtyData).isFalse();
    check(row.dirtyTitle).isFalse();
    final stored = decodeNoteData(row.data);
    check(stored.keys).contains('pages');
    check((stored['content'] as Map)['md']).equals('v2');
  });

  test('a note stored before the server was upgraded has its files written '
      'into its content when the server refuses the list', () async {
    server.seedNote(
      id: 'n1',
      title: 'Doc',
      data: {
        'content': {'json': null, 'html': '', 'md': 'body'},
        'files': [
          {'type': 'file', 'id': 'f1', 'name': 'Rec [1].m4a'},
        ],
      },
      createdAt: kT1,
      updatedAt: kT1,
    );
    await pull();
    // The server is upgraded; reading a note leaves its updated_at alone, so
    // the stored row keeps its older shape.
    server.notePagesEnabled = true;

    await editContent('n1', 'body edited');
    await push().pushNoteUpdate('n1', const {});

    check(client.notePatches).length.equals(2);
    final refused = client.notePatches.first.patch['data'] as Map;
    check(refused.keys.toSet()).deepEquals({'content', 'files'});
    final sent = client.notePatches.last.patch['data'] as Map;
    check(sent.keys.toSet()).deepEquals({'content'});
    const linked = 'body edited\n\n[Rec 1.m4a](/api/v1/files/f1/content)';
    check((sent['content'] as Map)['md']).equals(linked);
    check(serverPageMd('n1', 'main')).equals(linked);
    check(server.noteAttachedFileIds('n1')).deepEquals(['f1']);

    final row = (await db.notesDao.getNote('n1'))!;
    check(row.dirtyData).isFalse();
    final stored = decodeNoteData(row.data);
    check(stored.keys).contains('pages');
    check(stored.keys).not((it) => it.contains('files'));
    check((stored['content'] as Map)['md']).equals(linked);

    // The next edit goes out in the server's shape at the first try.
    await editContent('n1', '$linked\n\nmore');
    await push().pushNoteUpdate('n1', const {});
    check(client.notePatches).length.equals(3);
    check((client.notePatches.last.patch['data'] as Map).keys.toSet())
        .deepEquals({'content'});
  });

  test(
    'a server before 0.12.5 still gets the file list with the content',
    () async {
      server.seedNote(
        id: 'n1',
        title: 'Doc',
        data: {
          'content': {'json': null, 'html': '', 'md': 'body'},
          'files': [
            {'type': 'file', 'id': 'f1', 'name': 'Rec.m4a'},
          ],
          'versions': <Object>[],
        },
        createdAt: kT1,
        updatedAt: kT1,
      );
      await pull();

      await editContent('n1', 'body edited');
      await push().pushNoteUpdate('n1', const {});

      check(client.notePatches).length.equals(1);
      final sent = client.notePatches.single.patch['data'] as Map;
      check(sent.keys.toSet()).deepEquals({'content', 'files'});
      final data = serverData('n1');
      check((data['content'] as Map)['md']).equals('body edited');
      check(data['files'] as List).length.equals(1);
      check(data['versions'] as List).isEmpty();
    },
  );

  test('a known 0.12.5 server gets an older-shape note\'s files as links at '
      'the first try', () async {
    server.seedNote(
      id: 'n1',
      title: 'Doc',
      data: {
        'content': {'json': null, 'html': '', 'md': 'body'},
        'files': [
          {'type': 'file', 'id': 'f1', 'name': 'Rec.m4a'},
        ],
      },
      createdAt: kT1,
      updatedAt: kT1,
    );
    await pull();
    server.notePagesEnabled = true;
    pagesServer = true;

    await editContent('n1', 'body edited');
    await push().pushNoteUpdate('n1', const {});

    check(client.notePatches).length.equals(1);
    final sent = client.notePatches.single.patch['data'] as Map;
    check(sent.keys.toSet()).deepEquals({'content'});
    check(server.noteAttachedFileIds('n1')).deepEquals(['f1']);
  });

  test(
    'a server known to be older never has files moved into the content',
    () async {
      server.seedNote(
        id: 'n1',
        title: 'Doc',
        data: {
          'content': {'json': null, 'html': '', 'md': 'body'},
          'files': [
            {'type': 'file', 'id': 'f1', 'name': 'Rec.m4a'},
          ],
        },
        createdAt: kT1,
        updatedAt: kT1,
      );
      await pull();
      // A refusal from a server that reports an older version is some other
      // fault: the edit is retried as it is.
      server.notePagesEnabled = true;
      pagesServer = false;

      await editContent('n1', 'body edited');
      await check(push().pushNoteUpdate('n1', const {}))
          .throws<SyncRejectedException>();

      check(client.notePatches).length.equals(1);
      check((await db.notesDao.getNote('n1'))!.dirtyData).isTrue();
    },
  );

  test('an edit of one page of a note with several pages is sent to that '
      'page alone', () async {
    server.notePagesEnabled = true;
    server.seedNote(
      id: 'n1',
      title: 'Doc',
      data: twoPages(),
      createdAt: kT1,
      updatedAt: kT1,
    );
    await pull();

    await editContent('n1', 'two edited', pageId: 'p2');
    await push().pushNoteUpdate('n1', const {});

    check(client.notePatches).length.equals(1);
    check(client.notePatches.single.patch['page_id']).equals('p2');
    check(serverPageMd('n1', 'main')).equals('one');
    check(serverPageMd('n1', 'p2')).equals('two edited');
    final row = (await db.notesDao.getNote('n1'))!;
    check(row.dirtyData).isFalse();
    final stored = decodeNoteData(row.data);
    check(noteDirtyPageIds(stored)).isEmpty();
    check(notePageMarkdown(stored, 'p2')).equals('two edited');
  });

  test('an edit made in an editor opened before the note gained pages goes '
      'to the main page', () async {
    server.notePagesEnabled = true;
    server.seedNote(
      id: 'n1',
      title: 'Doc',
      data: twoPages(),
      createdAt: kT1,
      updatedAt: kT1,
    );
    await pull();

    // The editor edits the main page, whatever the note became meanwhile.
    await editContent('n1', 'one edited', pageId: kNoteMainPageId);
    await push().pushNoteUpdate('n1', const {});

    check(client.notePatches.single.patch['page_id']).equals('main');
    check(serverPageMd('n1', 'main')).equals('one edited');
    check(serverPageMd('n1', 'p2')).equals('two');
    check((await db.notesDao.getNote('n1'))!.dirtyData).isFalse();
  });

  test('changed data that belongs to no page goes no further, and is not '
      'sent again on every sync', () async {
    server.notePagesEnabled = true;
    server.seedNote(
      id: 'n1',
      title: 'Doc',
      data: twoPages(),
      createdAt: kT1,
      updatedAt: kT1,
    );
    await pull();
    // An earlier build wrote the combined view without naming a page.
    await locks.runExclusive('n1', () async {
      final data = decodeNoteData((await db.notesDao.getNote('n1'))!.data);
      await db.notesDao.updateNoteWithOutbox(
        'n1',
        title: const Value('Renamed'),
        data: Value(
          jsonEncode({
            ...data,
            'content': {'json': null, 'html': '', 'md': 'flattened'},
          }),
        ),
        localUpdatedAtNs: kT2,
        enqueue: true,
      );
    });

    await push().pushNoteUpdate('n1', const {});

    check(client.notePatches.single.patch.keys.toSet()).deepEquals({'title'});
    check(server.getNoteById('n1')!['title']).equals('Renamed');
    check(serverPageMd('n1', 'main')).equals('one');
    final row = (await db.notesDao.getNote('n1'))!;
    check(row.dirtyTitle).isFalse();
    check(row.dirtyData).isFalse();

    // The outbox marks the op it ran done; the next pull finds nothing owed,
    // so nothing is queued again.
    for (final op in await db.outboxDao.pendingForChat('n1')) {
      await db.outboxDao.markDone(op.seq);
    }
    await pull();
    check(
      (await db.outboxDao.pendingForChat('n1'))
          .where((op) => op.kind == OutboxKind.noteUpdate.name),
    ).isEmpty();
  });

  test('a create leaves out the pages a conflict copy carries', () async {
    server.notePagesEnabled = true;
    const localId = 'local:copy';
    await locks.runExclusive(localId, () async {
      await db.notesDao.insertLocalNoteWithCreateOp(
        note: NotesCompanion.insert(
          id: localId,
          title: 'Doc (conflict)',
          data: Value(
            jsonEncode({
              'content': {'json': null, 'html': '', 'md': 'mine'},
              'pages': [
                {
                  'id': 'main',
                  'title': 'Doc',
                  'content': {'json': null, 'html': '', 'md': 'mine'},
                },
              ],
              'pages_revision': 3,
              'search_text': 'Doc\nmine',
            }),
          ),
          createdAt: kT1,
          updatedAt: kT1,
        ),
      );
    });

    final serverId = await push().pushNoteCreate(localId);

    check(serverId).isNotNull();
    check(serverPageMd(serverId!, 'main')).equals('mine');
    check(serverData(serverId)['pages_revision']).equals(0);
  });

  test('pull crash-heals a pending create against a 0.12.5 note', () async {
    server.notePagesEnabled = true;
    const localId = 'local:n-crash';
    const serverId = 'server-n-crash';
    final data = {
      'content': {'json': null, 'html': '', 'md': 'body'},
      'versions': <Object>[],
      'files': null,
    };
    await locks.runExclusive(localId, () async {
      await db.notesDao.insertLocalNoteWithCreateOp(
        note: NotesCompanion.insert(
          id: localId,
          title: 'Draft',
          data: Value(jsonEncode(data)),
          createdAt: kT1,
          updatedAt: kT1,
        ),
      );
    });
    // The create reached the server, which answers in its paged shape.
    server.seedNote(
      id: serverId,
      title: 'Draft',
      data: data,
      createdAt: kT1,
      updatedAt: kT2,
    );

    final result = await pull();

    check(result.success).isTrue();
    check(await db.notesDao.getNote(localId)).isNull();
    check(await db.notesDao.getNote(serverId)).isNotNull();
    check(client.createNoteCalls).equals(0);
  });

  test(
    'pull crash-heals a create queued under the earlier fingerprint',
    () async {
      const localId = 'local:n-old';
      const serverId = 'server-n-old';
      final data = {
        'content': {'md': 'body'},
      };
      await locks.runExclusive(localId, () async {
        await db.notesDao.insertLocalNoteWithCreateOp(
          note: NotesCompanion.insert(
            id: localId,
            title: 'Draft',
            data: Value(jsonEncode(data)),
            createdAt: kT1,
            updatedAt: kT1,
          ),
        );
      });
      // An op an earlier build queued carries the whole-data fingerprint.
      final op = (await db.outboxDao.pendingForChat(localId)).single;
      check(op.kind).equals(OutboxKind.noteCreate.name);
      await (db.update(db.outboxOps)..where((t) => t.seq.equals(op.seq))).write(
        OutboxOpsCompanion(
          contentHash: Value(
            legacyNoteCreateContentHash(title: 'Draft', data: data),
          ),
        ),
      );
      server.seedNote(
        id: serverId,
        title: 'Draft',
        data: data,
        createdAt: kT1,
        updatedAt: kT2,
      );

      await pull();

      check(await db.notesDao.getNote(localId)).isNull();
      check(await db.notesDao.getNote(serverId)).isNotNull();
      check(client.createNoteCalls).equals(0);
    },
  );

  test(
    'a create with no text is not matched to another note with its title',
    () async {
      server.notePagesEnabled = true;
      const localId = 'local:empty';
      final data = {
        'content': {'json': null, 'html': '', 'md': ''},
        'versions': <Object>[],
        'files': [
          {'type': 'file', 'id': 'rec', 'name': 'Rec.m4a'},
        ],
      };
      await locks.runExclusive(localId, () async {
        await db.notesDao.insertLocalNoteWithCreateOp(
          note: NotesCompanion.insert(
            id: localId,
            title: '2026-11-03',
            data: Value(jsonEncode(data)),
            createdAt: kT1,
            updatedAt: kT1,
          ),
        );
      });
      // Someone else's empty note of the same day.
      server.seedNote(
        id: 'other',
        title: '2026-11-03',
        data: {
          'content': {'json': null, 'html': '', 'md': ''},
        },
        createdAt: kT1,
        updatedAt: kT2,
      );

      await pull();

      final local = await db.notesDao.getNote(localId);
      check(local).isNotNull();
      check(decodeNoteData(local!.data)['files'] as List).length.equals(1);
      check((await db.outboxDao.pendingForChat(localId)).map((op) => op.kind))
          .contains(OutboxKind.noteCreate.name);
    },
  );

  test('an edit an earlier build left only in a one-page note\'s content is '
      'what gets sent', () async {
    server.notePagesEnabled = true;
    server.seedNote(
      id: 'n1',
      title: 'Doc',
      data: {
        'content': {'json': null, 'html': '', 'md': 'v1'},
      },
      createdAt: kT1,
      updatedAt: kT1,
    );
    await pull();
    // Earlier builds merged the edit over `content` and left the page's own
    // copy as it was; the server refused it, so it is still owed.
    await locks.runExclusive('n1', () async {
      final data = decodeNoteData((await db.notesDao.getNote('n1'))!.data);
      await db.notesDao.updateNoteWithOutbox(
        'n1',
        data: Value(
          jsonEncode({
            ...data,
            'content': {'json': null, 'html': '', 'md': 'my edit'},
          }),
        ),
        localUpdatedAtNs: kT2,
        enqueue: true,
      );
    });

    await push().pushNoteUpdate('n1', const {});

    check(serverPageMd('n1', 'main')).equals('my edit');
    final stored = decodeNoteData((await db.notesDao.getNote('n1'))!.data);
    check((stored['content'] as Map)['md']).equals('my edit');
  });

  test('an earlier build\'s edit of a note with several pages is kept as a '
      'note of its own', () async {
    server.notePagesEnabled = true;
    server.seedNote(
      id: 'n1',
      title: 'Doc',
      data: twoPages(),
      createdAt: kT1,
      updatedAt: kT1,
    );
    await pull();
    await locks.runExclusive('n1', () async {
      final data = decodeNoteData((await db.notesDao.getNote('n1'))!.data);
      await db.notesDao.updateNoteWithOutbox(
        'n1',
        data: Value(
          jsonEncode({
            ...data,
            'content': {'json': null, 'html': '', 'md': 'all of it, edited'},
          }),
        ),
        localUpdatedAtNs: kT2,
        enqueue: true,
      );
    });

    await push().pushNoteUpdate('n1', const {});

    check(serverPageMd('n1', 'main')).equals('one');
    check(serverPageMd('n1', 'p2')).equals('two');
    final copies = await (db.select(
      db.notes,
    )..where((t) => t.isConflictCopy.equals(true))).get();
    check(copies).length.equals(1);
    final copy = decodeNoteData(copies.single.data);
    check(copy.keys).not((it) => it.contains('pages'));
    check((copy['content'] as Map)['md']).equals('all of it, edited');
    check((await db.notesDao.getNote('n1'))!.dirtyData).isFalse();
  });

  test('an unchanged combined view makes no copy', () async {
    server.notePagesEnabled = true;
    server.seedNote(
      id: 'n1',
      title: 'Doc',
      data: twoPages(),
      createdAt: kT1,
      updatedAt: kT1,
    );
    await pull();
    await locks.runExclusive('n1', () {
      return db.notesDao.updateNoteWithOutbox(
        'n1',
        title: const Value('Renamed'),
        localUpdatedAtNs: kT2,
        enqueue: true,
      );
    });

    await push().pushNoteUpdate('n1', const {'data': true});

    final copies = await (db.select(
      db.notes,
    )..where((t) => t.isConflictCopy.equals(true))).get();
    check(copies).isEmpty();
  });

  test('a conflict copy of a page edited here holds that page, as a note of '
      'its own', () async {
    server.notePagesEnabled = true;
    server.seedNote(
      id: 'n1',
      title: 'Doc',
      data: twoPages(),
      createdAt: kT1,
      updatedAt: kT1,
    );
    await pull();
    await editContent('n1', 'main edited here', pageId: kNoteMainPageId);
    // Someone else edits the note before the edit is sent.
    final there = twoPages();
    ((there['pages'] as List)[1] as Map)['content'] = {
      'json': null,
      'html': '',
      'md': 'two edited there',
    };
    server.seedNote(
      id: 'n1',
      title: 'Doc',
      data: there,
      createdAt: kT1,
      updatedAt: kT2 + 1000000000,
    );

    await pull();

    final copies = await (db.select(
      db.notes,
    )..where((t) => t.isConflictCopy.equals(true))).get();
    check(copies).length.equals(1);
    final copy = decodeNoteData(copies.single.data);
    check(copy.keys).not((it) => it.contains('pages'));
    check((copy['content'] as Map)['md']).equals('main edited here');
    final canonical = decodeNoteData((await db.notesDao.getNote('n1'))!.data);
    check(notePageMarkdown(canonical, 'p2')).equals('two edited there');
  });

  test('recordings an earlier build listed on a paged note are moved into '
      'its main page', () async {
    server.notePagesEnabled = true;
    server.seedNote(
      id: 'n1',
      title: 'Doc',
      data: {
        'content': {'json': null, 'html': '', 'md': 'body'},
      },
      createdAt: kT1,
      updatedAt: kT1,
    );
    await pull();
    // The earlier build added the recording to `files` of the paged row.
    await locks.runExclusive('n1', () async {
      final data = decodeNoteData((await db.notesDao.getNote('n1'))!.data);
      await db.notesDao.updateNoteWithOutbox(
        'n1',
        data: Value(
          jsonEncode({
            ...data,
            'files': [
              {'type': 'file', 'id': 'rec', 'name': 'Rec.m4a'},
            ],
          }),
        ),
        localUpdatedAtNs: kT2,
        enqueue: true,
      );
    });

    await push().pushNoteUpdate('n1', const {});

    check(server.noteAttachedFileIds('n1')).deepEquals(['rec']);
    final sent = client.notePatches.single.patch['data'] as Map;
    check(sent.keys.toSet()).deepEquals({'content'});
  });

  test('a recording on a note with no text goes out as its list, or as a '
      'link on 0.12.5', () async {
    for (final pagesNow in [false, true]) {
      final id = 'blank-$pagesNow';
      server.notePagesEnabled = false;
      server.seedNote(
        id: id,
        title: 'Blank',
        data: const {},
        createdAt: kT1,
        updatedAt: kT1,
      );
      await pull();
      server.notePagesEnabled = pagesNow;
      pagesServer = pagesNow;
      await locks.runExclusive(id, () {
        return db.notesDao.updateNoteWithOutbox(
          id,
          data: Value(
            jsonEncode({
              'files': [
                {'type': 'file', 'id': 'rec', 'name': 'Rec.m4a'},
              ],
            }),
          ),
          localUpdatedAtNs: kT2,
          enqueue: true,
        );
      });

      await push().pushNoteUpdate(id, const {});

      if (pagesNow) {
        check(server.noteAttachedFileIds(id)).deepEquals(['rec']);
      } else {
        check(serverData(id)['files'] as List).length.equals(1);
      }
    }
  });

  test('an earlier build\'s combined edit is copied once, even when a page '
      'edit is sent with it and the first try fails', () async {
    server.notePagesEnabled = true;
    server.seedNote(
      id: 'n1',
      title: 'Doc',
      data: twoPages(),
      createdAt: kT1,
      updatedAt: kT1,
    );
    await pull();
    await locks.runExclusive('n1', () async {
      final data = decodeNoteData((await db.notesDao.getNote('n1'))!.data);
      await db.notesDao.updateNoteWithOutbox(
        'n1',
        data: Value(
          jsonEncode({
            ...data,
            'content': {'json': null, 'html': '', 'md': 'whole note, edited'},
          }),
        ),
        localUpdatedAtNs: kT2,
        enqueue: true,
      );
    });
    // Then this build edits the second page.
    await editContent('n1', 'two edited', pageId: 'p2');

    client.failNoteWriteIds.add('n1');
    await check(push().pushNoteUpdate('n1', const {})).throws<StateError>();
    client.failNoteWriteIds.remove('n1');
    await push().pushNoteUpdate('n1', const {});

    final copies = await (db.select(
      db.notes,
    )..where((t) => t.isConflictCopy.equals(true))).get();
    check(copies).length.equals(1);
    check((decodeNoteData(copies.single.data)['content'] as Map)['md'])
        .equals('whole note, edited');
    check(serverPageMd('n1', 'p2')).equals('two edited');
    check(serverPageMd('n1', 'main')).equals('one');
  });

  test('a newer edit there keeps both an earlier build\'s combined edit and '
      'a page edit here, each in a copy', () async {
    server.notePagesEnabled = true;
    server.seedNote(
      id: 'n1',
      title: 'Doc',
      data: twoPages(),
      createdAt: kT1,
      updatedAt: kT1,
    );
    await pull();
    await locks.runExclusive('n1', () async {
      final data = decodeNoteData((await db.notesDao.getNote('n1'))!.data);
      await db.notesDao.updateNoteWithOutbox(
        'n1',
        data: Value(
          jsonEncode({
            ...data,
            'content': {'json': null, 'html': '', 'md': 'whole note, edited'},
          }),
        ),
        localUpdatedAtNs: kT2,
        enqueue: true,
      );
    });
    await editContent('n1', 'two edited here', pageId: 'p2');
    // Someone else edits the note before either edit is sent.
    final there = twoPages();
    ((there['pages'] as List)[0] as Map)['content'] = {
      'json': null,
      'html': '',
      'md': 'one edited there',
    };
    server.seedNote(
      id: 'n1',
      title: 'Doc',
      data: there,
      createdAt: kT1,
      updatedAt: kT2 + 1000000000,
    );

    await pull();

    final copies = await (db.select(
      db.notes,
    )..where((t) => t.isConflictCopy.equals(true))).get();
    check(
      copies.map(
        (copy) => (decodeNoteData(copy.data)['content'] as Map)['md'],
      ),
    ).unorderedEquals(['whole note, edited', 'two edited here']);
    final canonical = decodeNoteData((await db.notesDao.getNote('n1'))!.data);
    check(notePageMarkdown(canonical, 'main')).equals('one edited there');
  });

  test(
    'a create is not matched to a note alike but for its recordings',
    () async {
      const localId = 'local:with-rec';
      final data = {
        'content': {'json': null, 'html': '', 'md': 'same'},
        'files': [
          {'type': 'file', 'id': 'mine', 'name': 'Mine.m4a'},
        ],
      };
      await locks.runExclusive(localId, () async {
        await db.notesDao.insertLocalNoteWithCreateOp(
          note: NotesCompanion.insert(
            id: localId,
            title: 'Same',
            data: Value(jsonEncode(data)),
            createdAt: kT1,
            updatedAt: kT1,
          ),
        );
      });
      server.seedNote(
        id: 'other',
        title: 'Same',
        data: {
          'content': {'json': null, 'html': '', 'md': 'same'},
          'files': [
            {'type': 'file', 'id': 'theirs', 'name': 'Theirs.m4a'},
          ],
        },
        createdAt: kT1,
        updatedAt: kT2,
      );

      await pull();

      check(await db.notesDao.getNote(localId)).isNotNull();
      check((await db.outboxDao.pendingForChat(localId)).map((op) => op.kind))
          .contains(OutboxKind.noteCreate.name);
    },
  );
}
