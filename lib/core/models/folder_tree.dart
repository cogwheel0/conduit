import 'folder.dart';

/// Immutable tree node representing a folder and its nested children.
class FolderTreeNode {
  const FolderTreeNode({required this.folder, this.children = const []});

  final Folder folder;
  final List<FolderTreeNode> children;

  /// Builds a hierarchical folder tree from a flat folder list.
  static List<FolderTreeNode> buildTree(List<Folder> folders) {
    final foldersByParent = <String?, List<Folder>>{};
    for (final folder in folders) {
      foldersByParent.putIfAbsent(folder.parentId, () => <Folder>[]).add(folder);
    }

    int compareByName(Folder a, Folder b) =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase());

    FolderTreeNode buildNode(Folder folder) {
      final children = <FolderTreeNode>[];
      final childFolders = foldersByParent[folder.id] ?? const <Folder>[];
      final sortedChildren = <Folder>[...childFolders]..sort(compareByName);
      for (final child in sortedChildren) {
        children.add(buildNode(child));
      }
      return FolderTreeNode(folder: folder, children: children);
    }

    final roots = <Folder>[];
    final rootCandidates = foldersByParent[null] ?? const <Folder>[];
    roots.addAll(rootCandidates);

    final ids = folders.map((folder) => folder.id).toSet();
    for (final folder in folders) {
      final parentId = folder.parentId;
      if (parentId != null && !ids.contains(parentId)) {
        roots.add(folder);
      }
    }

    final uniqueRoots = <String, Folder>{
      for (final folder in roots) folder.id: folder,
    }.values.toList()
      ..sort(compareByName);

    return uniqueRoots.map(buildNode).toList(growable: false);
  }

  /// Returns all descendants of [folderId] from a flat folder list.
  static Set<String> getDescendantIds(String folderId, List<Folder> folders) {
    final childrenByParent = <String, List<String>>{};
    for (final folder in folders) {
      final parentId = folder.parentId;
      if (parentId == null) {
        continue;
      }
      childrenByParent.putIfAbsent(parentId, () => <String>[]).add(folder.id);
    }

    final descendants = <String>{};
    final stack = <String>[folderId];
    while (stack.isNotEmpty) {
      final current = stack.removeLast();
      final children = childrenByParent[current] ?? const <String>[];
      for (final child in children) {
        if (descendants.add(child)) {
          stack.add(child);
        }
      }
    }

    return descendants;
  }
}
