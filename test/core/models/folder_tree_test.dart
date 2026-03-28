import 'package:conduit/core/models/folder.dart';
import 'package:conduit/core/models/folder_tree.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FolderTreeNode.buildTree', () {
    test('builds nested tree with sorted siblings', () {
      final folders = <Folder>[
        const Folder(id: 'b', name: 'Beta'),
        const Folder(id: 'a', name: 'Alpha'),
        const Folder(id: 'a2', name: 'A Child 2', parentId: 'a'),
        const Folder(id: 'a1', name: 'A Child 1', parentId: 'a'),
        const Folder(id: 'a1x', name: 'Nested', parentId: 'a1'),
      ];

      final tree = FolderTreeNode.buildTree(folders);

      expect(tree.length, 2);
      expect(tree[0].folder.id, 'a');
      expect(tree[1].folder.id, 'b');

      expect(tree[0].children.map((n) => n.folder.id).toList(), ['a1', 'a2']);
      expect(tree[0].children.first.children.single.folder.id, 'a1x');
    });

    test('treats missing-parent folders as roots', () {
      final folders = <Folder>[
        const Folder(id: 'root', name: 'Root'),
        const Folder(id: 'orphan', name: 'Orphan', parentId: 'missing'),
      ];

      final tree = FolderTreeNode.buildTree(folders);
      expect(tree.map((node) => node.folder.id).toList(), ['orphan', 'root']);
    });
  });

  group('FolderTreeNode.getDescendantIds', () {
    test('returns all descendants recursively', () {
      final folders = <Folder>[
        const Folder(id: 'a', name: 'A'),
        const Folder(id: 'b', name: 'B', parentId: 'a'),
        const Folder(id: 'c', name: 'C', parentId: 'b'),
        const Folder(id: 'd', name: 'D', parentId: 'a'),
      ];

      final descendants = FolderTreeNode.getDescendantIds('a', folders);
      expect(descendants, {'b', 'c', 'd'});
    });

    test('returns empty set for leaf folder', () {
      final folders = <Folder>[
        const Folder(id: 'a', name: 'A'),
        const Folder(id: 'b', name: 'B', parentId: 'a'),
      ];

      final descendants = FolderTreeNode.getDescendantIds('b', folders);
      expect(descendants, isEmpty);
    });
  });
}
