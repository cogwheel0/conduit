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
      check(await db.syncMetaDao.getValue('schema_fixture_hash'))
          .equals('abc123');
      await db.syncMetaDao.setValue('schema_fixture_hash', 'def456');
      check(await db.syncMetaDao.getValue('schema_fixture_hash'))
          .equals('def456');
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
