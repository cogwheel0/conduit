import 'dart:io';

import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/features/chat/composer/composer_draft_store.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> addChat(AppDatabase db, String id) async {
  await db
      .into(db.chats)
      .insert(
        ChatsCompanion.insert(
          id: id,
          title: 'Example chat',
          createdAt: 1,
          updatedAt: 1,
        ),
      );
}

void main() {
  late bool previousWarning;
  setUp(() {
    previousWarning = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });
  tearDown(
    () => driftRuntimeOptions.dontWarnAboutMultipleDatabases = previousWarning,
  );

  test(
    'drafts survive reopening and remain separate by account and chat',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'composer-drafts-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final accountA = File('${directory.path}/a.sqlite');
      final accountB = File('${directory.path}/b.sqlite');
      var db = AppDatabase(NativeDatabase(accountA));
      try {
        await addChat(db, 'birch');
        await addChat(db, 'cedar');
        final store = ComposerDraftStore(db);
        const first = '  Check the basil 🌱\nKeep this next line.\n';
        await store.save('chat', 'birch', first);
        await store.save('chat', 'cedar', 'Bring a blue watering can.');
        await db.close();
        db = AppDatabase(NativeDatabase(accountA));
        expect(
          (await db.composerDraftsDao.readDraft('chat', 'birch'))?.content,
          first,
        );
        expect(
          (await db.composerDraftsDao.readDraft('chat', 'cedar'))?.content,
          'Bring a blue watering can.',
        );
        final other = AppDatabase(NativeDatabase(accountB));
        try {
          expect(
            await other.composerDraftsDao.readDraft('chat', 'birch'),
            isNull,
          );
        } finally {
          await other.close();
        }
      } finally {
        await db.close();
      }
    },
  );

  test(
    'send cleanup cannot overwrite a newer draft from another editor',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final original = ComposerDraftStore(db);
      final newer = ComposerDraftStore(db);
      await original.save('new:project', '', 'First paper lantern.');
      await newer.save('new:project', '', 'Newer paper lantern.');
      await original.clearIfUnchanged(
        'new:project',
        '',
        'First paper lantern.',
      );
      expect(await newer.read('new:project', ''), 'Newer paper lantern.');
      await newer.clearIfUnchanged('new:project', '', 'Newer paper lantern.');
      expect(await newer.read('new:project', ''), isNull);
    },
  );

  test('a cleared input stays cleared after older queued edits', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await addChat(db, 'birch');
    final store = ComposerDraftStore(db);
    await Future.wait([
      store.save('chat', 'birch', 'First thought'),
      store.save('chat', 'birch', 'Revised thought'),
      store.save('chat', 'birch', ''),
    ]);
    expect(await store.read('chat', 'birch'), isNull);
    await store.save('new:project', '', 'Another unsent thought');
    expect(await store.read('chat', ''), isNull);
    expect(await store.read('new:project', ''), 'Another unsent thought');
  });

  test(
    'remapping keeps the latest input and removes the old identity',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await addChat(db, 'local:birch');
      await addChat(db, 'server:birch');
      final dao = db.composerDraftsDao;
      await dao.saveDraft(
        scope: 'chat',
        chatId: 'local:birch',
        content: 'Newer input',
        updatedAt: 20,
      );
      await dao.saveDraft(
        scope: 'chat',
        chatId: 'server:birch',
        content: 'Older input',
        updatedAt: 10,
      );
      await db.transaction(
        () => dao.remapDraft('chat', 'local:birch', 'server:birch'),
      );
      expect(await dao.readDraft('chat', 'local:birch'), isNull);
      expect(
        (await dao.readDraft('chat', 'server:birch'))?.content,
        'Newer input',
      );
      await dao.saveDraft(
        scope: 'chat',
        chatId: 'local:birch',
        content: 'Old input',
        updatedAt: 15,
      );
      await db.transaction(
        () => dao.remapDraft('chat', 'local:birch', 'server:birch'),
      );
      expect(
        (await dao.readDraft('chat', 'server:birch'))?.content,
        'Newer input',
      );
    },
  );

  test('a delayed old-id edit or clear follows a committed remap', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await addChat(db, 'local:birch');
    await addChat(db, 'server:birch');
    final dao = db.composerDraftsDao;
    await dao.saveDraft(
      scope: 'chat',
      chatId: 'local:birch',
      content: 'First input',
      updatedAt: 1,
    );
    await db.transaction(() async {
      await dao.remapDraft('chat', 'local:birch', 'server:birch');
      await db.syncMetaDao.setChatRemapTarget('local:birch', 'server:birch');
    });
    await dao.saveDraft(
      scope: 'chat',
      chatId: 'local:birch',
      content: 'Revised input',
      updatedAt: 2,
    );
    expect(
      (await dao.readDraft('chat', 'server:birch'))?.content,
      'Revised input',
    );
    await dao.saveDraft(
      scope: 'chat',
      chatId: 'local:birch',
      content: '',
      updatedAt: 3,
    );
    expect(await dao.readDraft('chat', 'server:birch'), isNull);
  });

  test('a late edit cannot recreate a deleted chat draft', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await addChat(db, 'local:birch');
    final store = ComposerDraftStore(db);
    await store.save('chat', 'local:birch', 'A thought');
    await db.chatsDao.dropLocalChat('local:birch');
    await expectLater(
      store.save('chat', 'local:birch', 'A late edit'),
      throwsStateError,
    );
    expect(await store.read('chat', 'local:birch'), isNull);
  });
  test(
    'closing drains edits queued before the account database closes',
    () async {
      final directory = await Directory.systemTemp.createTemp('draft-close-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/account.sqlite');
      final db = AppDatabase(NativeDatabase(file));
      await addChat(db, 'birch');
      final store = ComposerDraftStore(db);
      final writes = [
        store.save('chat', 'birch', 'First edit'),
        store.save('chat', 'birch', 'Latest edit'),
      ];
      await db.close();
      await Future.wait(writes);
      final reopened = AppDatabase(NativeDatabase(file));
      addTearDown(reopened.close);
      expect(
        (await reopened.composerDraftsDao.readDraft('chat', 'birch'))?.content,
        'Latest edit',
      );
    },
  );

  test('schema 10 upgrades without changing existing chat rows', () async {
    final directory = await Directory.systemTemp.createTemp('draft-migration-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/account.sqlite');
    final original = AppDatabase(NativeDatabase(file));
    await addChat(original, 'birch');
    // Remove later additions so the real onUpgrade path runs against an
    // on-disk version-10 database.
    await original.customStatement('DROP TABLE composer_recording_chunks');
    await original.customStatement('DROP TABLE composer_recordings');
    await original.customStatement('DROP TABLE composer_drafts');
    await original.customStatement('PRAGMA user_version = 10');
    await original.close();
    final upgraded = AppDatabase(NativeDatabase(file));
    addTearDown(upgraded.close);
    expect((await upgraded.select(upgraded.chats).get()).single.id, 'birch');
    await ComposerDraftStore(upgraded).save('chat', 'birch', 'After migration');
    expect(
      (await upgraded.composerDraftsDao.readDraft('chat', 'birch'))?.content,
      'After migration',
    );
    expect(
      (await upgraded.customSelect('PRAGMA user_version').getSingle())
          .data
          .values
          .single,
      12,
    );
  });
  test('native session moves stay ordered with edits and scoped to their connection', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final store = ComposerDraftStore(db);
    await store.save('hermes:first', 'runtime', 'First input');
    await store.save('hermes:other', 'runtime', 'Another connection');
    await Future.wait([
      store.save('hermes:first', 'runtime', 'Last edit before remap'),
      store.remap('hermes:first', 'runtime', 'session'),
      store.save('hermes:first', 'session', 'Edit after remap'),
    ]);
    expect(await store.read('hermes:first', 'runtime'), isNull);
    expect(await store.read('hermes:first', 'session'), 'Edit after remap');
    expect(await store.read('hermes:other', 'runtime'), 'Another connection');
  });
}
