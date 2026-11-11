import 'dart:io';
import 'dart:typed_data';

import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/features/chat/composer/composer_draft_store.dart';
import 'package:conduit_core/features/chat/composer/composer_recording_store.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> addChat(AppDatabase db, String id) async {
  await db
      .into(db.chats)
      .insert(
        ChatsCompanion.insert(
          id: id,
          title: 'Example',
          createdAt: 1,
          updatedAt: 1,
        ),
      );
}

void main() {
  late bool warning;
  setUp(() {
    warning = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });
  tearDown(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = warning);

  test(
    'committed audio reopens per chat and account without sync data',
    () async {
      final directory = await Directory.systemTemp.createTemp('draft-audio-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/account.sqlite');
      var db = AppDatabase(NativeDatabase(file));
      try {
        await addChat(db, 'birch');
        await addChat(db, 'cedar');
        final store = ComposerDraftStore(db).recordings;
        final first = await store.begin(
          id: 'first',
          scope: 'chat',
          chatId: 'birch',
          onFailure: () => fail('write'),
        );
        first.add(Uint8List.fromList([1, 2, 3, 4]));
        await first.flush();
        first.add(Uint8List.fromList([5, 6]));
        await first.close();
        final second = await store.begin(
          id: 'second',
          scope: 'chat',
          chatId: 'cedar',
          onFailure: () => fail('write'),
        );
        second.add(Uint8List.fromList([7, 8]));
        await second.close();
        await db.close();
        db = AppDatabase(NativeDatabase(file));
        expect(
          (await db.composerRecordingsDao.watch('chat', 'birch').first)
              .single
              .id,
          'first',
        );
        expect(await db.composerRecordingsDao.readPcm('first'), [
          1,
          2,
          3,
          4,
          5,
          6,
        ]);
        expect(
          (await db.composerRecordingsDao.watch('chat', 'cedar').first)
              .single
              .id,
          'second',
        );
        expect(await db.select(db.outboxOps).get(), isEmpty);
        final other = AppDatabase(NativeDatabase.memory());
        try {
          expect(await other.composerRecordingsDao.readPcm('first'), isEmpty);
        } finally {
          await other.close();
        }
        final wav = await ComposerDraftStore(db).recordings.readWav('first');
        final header = ByteData.sublistView(wav);
        expect(String.fromCharCodes(wav.take(4)), 'RIFF');
        expect(header.getUint32(24, Endian.little), 16000);
        expect(header.getUint32(40, Endian.little), 6);
        expect(wav.sublist(44), [1, 2, 3, 4, 5, 6]);
      } finally {
        await db.close();
      }
    },
  );

  test(
    'discard cascades chunks and a late capture cannot resurrect them',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await addChat(db, 'birch');
      final dao = db.composerRecordingsDao;
      await dao.create(
        id: 'first',
        scope: 'chat',
        chatId: 'birch',
        createdAt: 1,
      );
      await dao.append('first', Uint8List(4));
      await dao.discard('first');
      await dao.append('first', Uint8List(4));
      expect(await dao.readPcm('first'), isEmpty);
      expect(await db.select(db.composerRecordingChunks).get(), isEmpty);
      expect(await dao.watch('chat', 'birch').first, isEmpty);
    },
  );

  test('audio-only drafts follow remaps and exact chat deletion', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await addChat(db, 'local');
    await addChat(db, 'stored');
    final dao = db.composerRecordingsDao;
    await dao.create(id: 'first', scope: 'chat', chatId: 'local', createdAt: 1);
    await dao.append('first', Uint8List(4));
    await db.composerDraftsDao.remapDraft('chat', 'local', 'stored');
    await db.composerDraftsDao.deleteChatDraft('local');
    expect((await dao.watch('chat', 'stored').first).single.byteCount, 4);
    await db.composerDraftsDao.deleteChatDraft('stored');
    expect(await dao.readPcm('first'), isEmpty);
  });

  test(
    'bulk chat purge removes only reached drafts and raw recording chunks',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final store = ComposerDraftStore(db);
      for (final id in ['stored', 'local:kept']) {
        await addChat(db, id);
        await store.save('chat', id, 'Fold a paper lantern.');
        final writer = await store.recordings.begin(
          id: id,
          scope: 'chat',
          chatId: id,
          onFailure: () => fail('save failed'),
        );
        writer.add(Uint8List(4));
        await writer.close();
      }
      expect(await db.chatsDao.purgeServerWideChats('reader'), ['stored']);
      expect(await store.read('chat', 'stored'), isNull);
      expect(await store.recordings.readPcm('stored'), isEmpty);
      expect(await store.read('chat', 'local:kept'), isNotNull);
      expect(await store.recordings.readPcm('local:kept'), isNotEmpty);
    },
  );

  test(
    'deleting a remapped draft uses the same identity for text and audio',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await addChat(db, 'stored');
      final store = ComposerDraftStore(db);
      await store.save('chat', 'stored', 'Fold a paper lantern.');
      final writer = await store.recordings.begin(
        id: 'recording',
        scope: 'chat',
        chatId: 'stored',
        onFailure: () => fail('save failed'),
      );
      writer.add(Uint8List(4));
      await writer.close();
      await db.syncMetaDao.setChatRemapTarget('local:old', 'stored');
      await db.composerDraftsDao.deleteChatDraft('local:old');
      expect(await store.read('chat', 'stored'), isNull);
      expect(await store.recordings.readPcm('recording'), isEmpty);
    },
  );

  test('deleted chats reject new recordings and further writes', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await expectLater(
      db.composerRecordingsDao.create(
        id: 'first',
        scope: 'chat',
        chatId: 'missing',
        createdAt: 1,
      ),
      throwsStateError,
    );
    expect(await db.select(db.composerRecordings).get(), isEmpty);
  });

  test('schema eleven upgrades without losing the text input', () async {
    final directory = await Directory.systemTemp.createTemp(
      'draft-audio-upgrade-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/account.sqlite');
    var db = AppDatabase(NativeDatabase(file));
    try {
      await addChat(db, 'birch');
      await ComposerDraftStore(db)
          .save('chat', 'birch', 'A new synthetic thought');
      await db.customStatement('DROP TABLE composer_recording_chunks');
      await db.customStatement('DROP TABLE composer_recordings');
      await db.customStatement('PRAGMA user_version = 11');
      await db.close();
      db = AppDatabase(NativeDatabase(file));
      expect(
        await ComposerDraftStore(db).read('chat', 'birch'),
        'A new synthetic thought',
      );
      expect(
        await db.composerRecordingsDao.watch('chat', 'birch').first,
        isEmpty,
      );
    } finally {
      await db.close();
    }
  });

  test(
    'failed flush retains bytes, retry writes once, close drains the tail',
    () async {
      final committed = <int>[];
      var failing = true;
      var failures = 0;
      final writer = ComposerRecordingWriter((bytes) async {
        if (failing) throw const FileSystemException('Synthetic disk failure');
        committed.addAll(bytes);
      }, onFailure: () => failures++);
      addTearDown(writer.close);
      writer.add(Uint8List.fromList([1, 2]));
      await expectLater(writer.flush(), throwsA(isA<FileSystemException>()));
      writer.add(Uint8List.fromList([3, 4]));
      failing = false;
      await writer.flush();
      writer.add(Uint8List.fromList([5, 6]));
      await writer.close();
      writer.add(Uint8List.fromList([7, 8]));
      await writer.flush();
      expect(committed, [1, 2, 3, 4, 5, 6]);
      expect(failures, 1);
    },
  );

  testWidgets('capture saves periodically without lifecycle or Stop events', (
    tester,
  ) async {
    final committed = <int>[];
    final writer = ComposerRecordingWriter(
      (bytes) async => committed.addAll(bytes),
      onFailure: () => fail('write'),
    );
    writer.add(Uint8List.fromList([1, 2]));
    await tester.pump(const Duration(seconds: 1));
    expect(committed, [1, 2]);
    writer.add(Uint8List.fromList([3, 4]));
    await writer.close();
    expect(committed, [1, 2, 3, 4]);
  });
}
