import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  group('getValue/setValue', () {
    test('returns null for a missing key', () async {
      check(await db.syncMetaDao.getValue('missing')).isNull();
    });

    test('round-trips and overwrites values', () async {
      await db.syncMetaDao.setValue('schema_fixture_hash', 'abc123');
      check(
        await db.syncMetaDao.getValue('schema_fixture_hash'),
      ).equals('abc123');
      await db.syncMetaDao.setValue('schema_fixture_hash', 'def456');
      check(
        await db.syncMetaDao.getValue('schema_fixture_hash'),
      ).equals('def456');
    });
  });

  group('chat remap targets', () {
    test('is write-once and idempotent for the same destination', () async {
      check(await db.syncMetaDao.getChatRemapTarget('local:a')).isNull();

      await db.syncMetaDao.setChatRemapTarget('local:a', 'server:a');
      await db.syncMetaDao.setChatRemapTarget('local:a', 'server:a');

      check(
        await db.syncMetaDao.getChatRemapTarget('local:a'),
      ).equals('server:a');
      await check(
        db.syncMetaDao.setChatRemapTarget('local:a', 'server:other'),
      ).throws<StateError>();
      check(
        await db.syncMetaDao.getChatRemapTarget('local:a'),
      ).equals('server:a');
    });

    test('can delete a source mapping or every mapping to a target', () async {
      await db.syncMetaDao.setChatRemapTarget('local:a', 'server:shared');
      await db.syncMetaDao.setChatRemapTarget('local:b', 'server:shared');
      await db.syncMetaDao.setChatRemapTarget('local:c', 'server:other');
      await db.syncMetaDao.setValue('chatXremap:not-a-map', 'server:shared');

      await db.syncMetaDao.deleteChatRemapTarget('local:a');
      check(await db.syncMetaDao.getChatRemapTarget('local:a')).isNull();
      check(
        await db.syncMetaDao.getChatRemapTarget('local:b'),
      ).equals('server:shared');

      await db.syncMetaDao.deleteChatRemapTargetsForServer('server:shared');
      check(await db.syncMetaDao.getChatRemapTarget('local:b')).isNull();
      check(
        await db.syncMetaDao.getChatRemapTarget('local:c'),
      ).equals('server:other');
      check(
        await db.syncMetaDao.getValue('chatXremap:not-a-map'),
      ).equals('server:shared');
    });
  });

  group('pull watermark', () {
    test('defaults to 0 when unset', () async {
      check(await db.syncMetaDao.getPullWatermark()).equals(0);
    });

    test('defaults to 0 when the stored value is not an int', () async {
      await db.syncMetaDao.setValue('pull_watermark', 'not-a-number');
      check(await db.syncMetaDao.getPullWatermark()).equals(0);
    });

    test('set/get round-trips epoch seconds', () async {
      await db.syncMetaDao.setPullWatermark(1749700123);
      check(await db.syncMetaDao.getPullWatermark()).equals(1749700123);
      await db.syncMetaDao.setPullWatermark(1749800999);
      check(await db.syncMetaDao.getPullWatermark()).equals(1749800999);
    });
  });
}
