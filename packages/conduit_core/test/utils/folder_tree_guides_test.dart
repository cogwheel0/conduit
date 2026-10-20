import 'package:checks/checks.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduit_core/utils/folder_tree_guides.dart';
import 'package:test/test.dart';

Folder _folder(String id, String name, {String? parentId}) =>
    Folder(id: id, name: name, parentId: parentId);

typedef _Row = (String id, List<bool> ancestors, bool hasMore);

List<_Row> _rows(List<FolderTreeListEntry> entries) => [
  for (final e in entries)
    (e.folder.id, e.ancestorHasMoreSiblings, e.hasMoreSiblings),
];

void main() {
  group('folderTreeEntriesForTargets', () {
    test('lists folders depth first, sorted by name ignoring case', () {
      final entries = folderTreeEntriesForTargets(
        folders: [
          _folder('b', 'beta'),
          _folder('a', 'Alpha'),
          _folder('a2', 'zed', parentId: 'a'),
          _folder('a1', 'Apple', parentId: 'a'),
        ],
      );

      check(entries.map((e) => e.folder.id).toList())
          .deepEquals(['a', 'a1', 'a2', 'b']);
    });

    test('marks siblings and the rails of the ancestors', () {
      final entries = folderTreeEntriesForTargets(
        folders: [
          _folder('a', 'A'),
          _folder('a1', 'A1', parentId: 'a'),
          _folder('a2', 'A2', parentId: 'a'),
          _folder('b', 'B'),
        ],
      );

      check(_rows(entries).map((r) => (r.$1, r.$2.length, r.$3)).toList())
          .deepEquals([
            ('a', 0, true),
            ('a1', 1, true),
            ('a2', 1, false),
            ('b', 0, false),
          ]);
      // a1 and a2 sit under `a`, which has `b` after it.
      check(entries[1].ancestorHasMoreSiblings).deepEquals([true]);
      check(entries[2].ancestorHasMoreSiblings).deepEquals([true]);
    });

    test('a last root has no rail for its children', () {
      final entries = folderTreeEntriesForTargets(
        folders: [
          _folder('a', 'A'),
          _folder('a1', 'A1', parentId: 'a'),
        ],
      );

      check(entries.last.ancestorHasMoreSiblings).deepEquals([false]);
    });

    test('omits one folder but keeps its descendants nested', () {
      final entries = folderTreeEntriesForTargets(
        folders: [
          _folder('a', 'A'),
          _folder('a1', 'A1', parentId: 'a'),
        ],
        omitFolderId: 'a',
      );

      check(entries.map((e) => e.folder.id).toList()).deepEquals(['a1']);
      check(entries.single.ancestorHasMoreSiblings.length).equals(1);
    });

    test('a folder with an unknown or empty parent is a root', () {
      final entries = folderTreeEntriesForTargets(
        folders: [
          _folder('a', 'A', parentId: 'missing'),
          _folder('b', 'B', parentId: ''),
        ],
      );

      check(entries.map((e) => e.ancestorHasMoreSiblings.length).toList())
          .deepEquals([0, 0]);
    });

    test('is empty for no folders', () {
      check(folderTreeEntriesForTargets(folders: const [])).isEmpty();
    });
  });

  group('folderTreeGuideWidth', () {
    test('is one segment per ancestor, plus one for the branch', () {
      check(folderTreeGuideWidth(ancestorCount: 0, showBranch: false))
          .equals(0);
      check(folderTreeGuideWidth(ancestorCount: 1, showBranch: true))
          .equals(30);
      check(folderTreeGuideWidth(ancestorCount: 3, showBranch: false))
          .equals(45);
    });
  });

  group('folderTreeHierarchyLines', () {
    const seg = folderTreeSegmentWidth;

    test('draws nothing without a branch or a rail', () {
      check(
        folderTreeHierarchyLines(
          ancestorHasMoreSiblings: const [true, false],
          showBranch: false,
          hasMoreSiblings: true,
          width: 30,
          height: 40,
        ),
      ).isEmpty();
    });

    test('draws the branch up to the middle and across, without a tail', () {
      final lines = folderTreeHierarchyLines(
        ancestorHasMoreSiblings: const [false],
        showBranch: true,
        hasMoreSiblings: false,
        width: 30,
        height: 40,
      );

      const x = 1 * seg + seg / 2;
      check(lines).deepEquals([
        const FolderTreeGuideLine(x, 0, x, 20),
        const FolderTreeGuideLine(x, 20, 30, 20),
      ]);
    });

    test('continues the branch down when siblings follow', () {
      final lines = folderTreeHierarchyLines(
        ancestorHasMoreSiblings: const [true],
        showBranch: true,
        hasMoreSiblings: true,
        width: 30,
        height: 44,
      );

      const x = 22.5;
      check(lines).deepEquals([
        const FolderTreeGuideLine(x, 0, x, 22),
        const FolderTreeGuideLine(x, 22, 30, 22),
        const FolderTreeGuideLine(x, 22, x, 44),
      ]);
    });

    test(
      'draws a rail for each ancestor level below the top with siblings',
      () {
        final lines = folderTreeHierarchyLines(
          ancestorHasMoreSiblings: const [true, true, false, true],
          showBranch: true,
          hasMoreSiblings: false,
          width: 75,
          height: 40,
        );

        // Index 0 never draws; index 2 has no siblings below.
        check(lines.take(2).toList()).deepEquals([
          const FolderTreeGuideLine(22.5, 0, 22.5, 40),
          const FolderTreeGuideLine(52.5, 0, 52.5, 40),
        ]);
        check(lines.length).equals(4);
        check(lines[2]).equals(const FolderTreeGuideLine(67.5, 0, 67.5, 20));
      },
    );
  });

  group('folderTreeIntergroupGapLines', () {
    test('draws nothing at the top level', () {
      check(
        folderTreeIntergroupGapLines(
          ancestorHasMoreSiblings: const [],
          height: 8,
        ),
      ).isEmpty();
    });

    test('runs the rails and the spine of the folder that follows', () {
      final lines = folderTreeIntergroupGapLines(
        ancestorHasMoreSiblings: const [true, true, false],
        height: 8,
      );

      check(lines).deepEquals([
        const FolderTreeGuideLine(22.5, 0, 22.5, 8),
        const FolderTreeGuideLine(52.5, 0, 52.5, 8),
      ]);
    });

    test('a single ancestor draws only the spine', () {
      final lines = folderTreeIntergroupGapLines(
        ancestorHasMoreSiblings: const [false],
        height: 8,
      );

      check(lines).deepEquals([const FolderTreeGuideLine(22.5, 0, 22.5, 8)]);
    });
  });
}
