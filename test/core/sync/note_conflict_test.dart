/// CDT-RFC-001 D-11 note conflict resolution: field-level LWW (title and data
/// resolved INDEPENDENTLY) with a conflict copy on a concurrent data edit —
/// never a silent local-edit loss, never an infinite copy chain.
library;

import 'package:checks/checks.dart';
import 'package:conduit/core/sync/note_conflict.dart';
import 'package:flutter_test/flutter_test.dart';

NoteMergeLocal local({
  int? base = 100,
  bool deleted = false,
  bool dirtyTitle = false,
  bool dirtyData = false,
  bool dirtyPinned = false,
  bool isConflictCopy = false,
}) => NoteMergeLocal(
  serverUpdatedAt: base,
  deleted: deleted,
  dirtyTitle: dirtyTitle,
  dirtyData: dirtyData,
  dirtyPinned: dirtyPinned,
  isConflictCopy: isConflictCopy,
);

void main() {
  group('resolveNoteMerge (D-11 field-LWW + conflict copy)', () {
    test('never-synced row / null local → fast-forward, no copy', () {
      for (final l in [null, local(base: null)]) {
        final d = resolveNoteMerge(serverUpdatedAt: 200, local: l);
        check(d.kind).equals(NoteMergeKind.fastForward);
        check(d.takeServerTitle).isTrue();
        check(d.takeServerData).isTrue();
        check(d.spawnConflictCopy).isFalse();
        check(d.mustPush).isFalse();
      }
    });

    test(
      'dirty tombstone is skipped (pending delete wins, never resurrects)',
      () {
        final d = resolveNoteMerge(
          serverUpdatedAt: 999,
          local: local(deleted: true, dirtyData: true),
        );
        check(d.kind).equals(NoteMergeKind.skipDirtyTombstone);
        check(d.spawnConflictCopy).isFalse();
        check(d.takeServerData).isFalse();
      },
    );

    test('overlap window (server.updatedAt <= base) is a no-op', () {
      final d = resolveNoteMerge(
        serverUpdatedAt: 100,
        local: local(base: 100, dirtyData: true),
      );
      check(d.kind).equals(NoteMergeKind.noRemoteChange);
      check(d.spawnConflictCopy).isFalse();
      // A pending local edit still owes a push.
      check(d.mustPush).isTrue();
    });

    test('field-LWW: title dirty, data clean → server data, local title kept, '
        'NO copy', () {
      final d = resolveNoteMerge(
        serverUpdatedAt: 200,
        local: local(base: 100, dirtyTitle: true),
      );
      check(d.kind).equals(NoteMergeKind.fieldLww);
      check(d.takeServerData).isTrue();
      check(d.takeServerTitle).isFalse(); // local title wins
      check(d.spawnConflictCopy).isFalse();
      check(d.canonicalDirtyTitle).isTrue(); // still owes a push
      check(d.mustPush).isTrue();
    });

    test('field-LWW: data clean → take server data with no copy', () {
      final d = resolveNoteMerge(serverUpdatedAt: 200, local: local(base: 100));
      check(d.takeServerData).isTrue();
      check(d.spawnConflictCopy).isFalse();
      check(d.canonicalDirtyData).isFalse();
    });

    test('CARDINAL: concurrent data edit (data dirty + remote bump) spawns a '
        'conflict copy — local data is NOT silently dropped', () {
      final d = resolveNoteMerge(
        serverUpdatedAt: 200,
        local: local(base: 100, dirtyData: true),
      );
      check(d.kind).equals(NoteMergeKind.fieldLww);
      check(d.spawnConflictCopy).isTrue(); // local data preserved on the copy
      check(d.takeServerData).isTrue(); // server data lands on canonical
      check(d.canonicalDirtyData).isFalse(); // canonical data now clean
      check(d.advanceServerUpdatedAt).isTrue();
    });

    test(
      'NO INFINITE COPY CHAIN: after a conflict copy the canonical is clean '
      'and base advanced, so the next identical pull makes no further copy',
      () {
        const serverTs = 200;
        // Round 1: concurrent data edit → one copy.
        final first = resolveNoteMerge(
          serverUpdatedAt: serverTs,
          local: local(base: 100, dirtyData: true),
        );
        check(first.spawnConflictCopy).isTrue();

        // The canonical row now reflects first's outcome: data clean, base
        // advanced to the server timestamp.
        final canonicalAfter = local(
          base: first.advanceServerUpdatedAt ? serverTs : 100,
          dirtyData: first.canonicalDirtyData,
          dirtyTitle: first.canonicalDirtyTitle,
        );

        // Round 2: the SAME server note pulled again — no new copy.
        final second = resolveNoteMerge(
          serverUpdatedAt: serverTs,
          local: canonicalAfter,
        );
        check(second.kind).equals(NoteMergeKind.noRemoteChange);
        check(second.spawnConflictCopy).isFalse();
      },
    );

    test('conflict-copy dirty data wins locally instead of forking again', () {
      final d = resolveNoteMerge(
        serverUpdatedAt: 200,
        local: local(base: 100, dirtyData: true, isConflictCopy: true),
      );
      check(d.kind).equals(NoteMergeKind.fieldLww);
      check(d.spawnConflictCopy).isFalse();
      check(d.takeServerData).isFalse();
      check(d.canonicalDirtyData).isTrue();
      check(d.advanceServerUpdatedAt).isFalse();
      check(d.mustPush).isTrue();
    });

    test('field-LWW independence: title-dirty and data-dirty resolve on their '
        'own axes (title kept locally AND a data copy spawned)', () {
      final d = resolveNoteMerge(
        serverUpdatedAt: 200,
        local: local(base: 100, dirtyTitle: true, dirtyData: true),
      );
      check(d.takeServerTitle).isFalse(); // title: local wins
      check(d.spawnConflictCopy).isTrue(); // data: conflict copy
      check(d.canonicalDirtyTitle).isTrue();
      check(d.mustPush).isTrue();
    });

    test('a pending pin keeps mustPush set even with clean title/data', () {
      final d = resolveNoteMerge(
        serverUpdatedAt: 200,
        local: local(base: 100, dirtyPinned: true),
      );
      check(d.mustPush).isTrue();
      check(d.spawnConflictCopy).isFalse();
    });
  });
}
