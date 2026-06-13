/// CDT-RFC-001 D-11 / R-09 regression guard: note timestamps are NANOSECONDS
/// and chat timestamps are SECONDS, tracked under SEPARATE sync_meta keys and
/// SEPARATE overlap constants that must NEVER be conflated. A future refactor
/// that unified either would silently corrupt one entity's watermark (re-pull
/// forever, or never advance), so this test fails loudly if the two clock
/// domains are merged.
library;

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/daos/sync_meta_dao.dart';
import 'package:conduit/core/sync/note_sync.dart' show kNotePullOverlapNs;
import 'package:conduit/core/sync/pull_sync.dart' show kPullOverlapSeconds;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  group('note vs chat watermark isolation (R-09)', () {
    test('the two watermarks live under DISTINCT sync_meta keys', () {
      check(SyncMetaDao.kNotesPullWatermarkKey).not((k) => k.equals('pull_watermark'));
    });

    test('the two overlap windows are distinct and in their own units', () {
      check(kPullOverlapSeconds).equals(5);
      check(kNotePullOverlapNs).equals(5 * 1000 * 1000 * 1000);
      check(kNotePullOverlapNs).not((o) => o.equals(kPullOverlapSeconds));
    });

    test(
        'a nanosecond note watermark and a seconds chat watermark round-trip '
        'independently — neither leaks into the other', () async {
      // A real time_ns()-scale value (~2024 in ns) must survive byte-for-byte.
      const noteNs = 1718000000000000000;
      const chatSeconds = 1718000000;

      await db.syncMetaDao.setNotesPullWatermark(noteNs);
      await db.syncMetaDao.setPullWatermark(chatSeconds);

      // Each reads back its OWN value, with no cross-contamination.
      check(await db.syncMetaDao.getNotesPullWatermark()).equals(noteNs);
      check(await db.syncMetaDao.getPullWatermark()).equals(chatSeconds);

      // Overwriting one must not disturb the other.
      await db.syncMetaDao.setPullWatermark(chatSeconds + 42);
      check(await db.syncMetaDao.getNotesPullWatermark()).equals(noteNs);
    });

    test('the nanosecond watermark is not silently truncated to seconds',
        () async {
      const noteNs = 1718000000123456789; // sub-second precision present
      await db.syncMetaDao.setNotesPullWatermark(noteNs);
      // A lossy /1000000000 normalization would drop the low digits.
      check(await db.syncMetaDao.getNotesPullWatermark()).equals(noteNs);
    });
  });
}
