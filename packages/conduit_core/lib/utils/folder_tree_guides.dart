/// The folder tree's ordering and its guide lines (the connectors drawn to the
/// left of a nested folder or chat).
///
/// The app paints [FolderTreeGuideLine]s on its canvas; where a rail or a
/// branch goes is decided here.
library;

import '../models/folder.dart';

String? _normalizeFolderParentId(String? parentId) {
  if (parentId == null || parentId.isEmpty) {
    return null;
  }
  return parentId;
}

/// One folder row plus metadata needed to draw hierarchy guides (sidebar,
/// move targets, etc.).
class FolderTreeListEntry {
  /// Creates a folder row descriptor for tree-aligned lists.
  const FolderTreeListEntry({
    required this.folder,
    required this.ancestorHasMoreSiblings,
    required this.hasMoreSiblings,
  });

  /// The folder for this row.
  final Folder folder;

  /// Per ancestor depth: whether that ancestor level still has more siblings
  /// below this row (used for vertical rails).
  final List<bool> ancestorHasMoreSiblings;

  /// Whether this folder has more sibling folders after it under the same
  /// parent.
  final bool hasMoreSiblings;
}

/// Depth-first folder rows in tree order for bottom sheets and pickers.
///
/// [omitFolderId] skips one folder row (e.g. current chat folder) but keeps
/// descendants so nesting guides stay consistent.
List<FolderTreeListEntry> folderTreeEntriesForTargets({
  required List<Folder> folders,
  String? omitFolderId,
}) {
  final foldersById = <String, Folder>{
    for (final folder in folders) folder.id: folder,
  };
  final childFoldersByParentId = <String?, List<Folder>>{};
  for (final folder in folders) {
    final parentId = _normalizeFolderParentId(folder.parentId);
    final resolvedParentId =
        parentId != null && foldersById.containsKey(parentId) ? parentId : null;
    childFoldersByParentId
        .putIfAbsent(resolvedParentId, () => <Folder>[])
        .add(folder);
  }
  for (final childFolders in childFoldersByParentId.values) {
    childFolders.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
  }

  final rootFolders = childFoldersByParentId[null] ?? const <Folder>[];
  final result = <FolderTreeListEntry>[];

  void visit(
    Folder folder,
    List<bool> ancestorHasMoreSiblings,
    bool hasMoreSiblings,
  ) {
    final omit = omitFolderId != null && folder.id == omitFolderId;
    if (!omit) {
      result.add(
        FolderTreeListEntry(
          folder: folder,
          ancestorHasMoreSiblings: ancestorHasMoreSiblings,
          hasMoreSiblings: hasMoreSiblings,
        ),
      );
    }

    final children = childFoldersByParentId[folder.id] ?? const <Folder>[];
    final nextAncestor = [...ancestorHasMoreSiblings, hasMoreSiblings];
    for (var index = 0; index < children.length; index++) {
      visit(children[index], nextAncestor, index < children.length - 1);
    }
  }

  for (var index = 0; index < rootFolders.length; index++) {
    visit(rootFolders[index], const <bool>[], index < rootFolders.length - 1);
  }

  return result;
}

/// Horizontal space per nesting level for guide lines.
const double folderTreeSegmentWidth = 15;

/// Stroke width of a guide line.
const double folderTreeGuideStrokeWidth = 1.25;

/// A straight guide line in the guide box's own coordinates.
class FolderTreeGuideLine {
  const FolderTreeGuideLine(this.x1, this.y1, this.x2, this.y2);

  final double x1;
  final double y1;
  final double x2;
  final double y2;

  @override
  bool operator ==(Object other) =>
      other is FolderTreeGuideLine &&
      other.x1 == x1 &&
      other.y1 == y1 &&
      other.x2 == x2 &&
      other.y2 == y2;

  @override
  int get hashCode => Object.hash(x1, y1, x2, y2);

  @override
  String toString() => 'FolderTreeGuideLine($x1, $y1 -> $x2, $y2)';
}

/// The width of the guide column: one segment per ancestor level, plus one
/// for the branch when [showBranch] is set.
double folderTreeGuideWidth({
  required int ancestorCount,
  required bool showBranch,
}) => (ancestorCount + (showBranch ? 1 : 0)) * folderTreeSegmentWidth;

/// The lines beside one row: a vertical rail for each ancestor level that
/// still has siblings below (the top level, index 0, never draws one), then
/// the row's own branch: down from the top to the row's middle, across to
/// the row, and on to the bottom when more siblings follow.
///
/// [width] and [height] are the guide box's size; the branch runs across to
/// [width] at the row's vertical middle.
List<FolderTreeGuideLine> folderTreeHierarchyLines({
  required List<bool> ancestorHasMoreSiblings,
  required bool showBranch,
  required bool hasMoreSiblings,
  required double width,
  required double height,
}) {
  const seg = folderTreeSegmentWidth;
  final lines = <FolderTreeGuideLine>[];

  for (var index = 0; index < ancestorHasMoreSiblings.length; index++) {
    if (index == 0 || !ancestorHasMoreSiblings[index]) {
      continue;
    }
    final x = (index * seg) + (seg / 2);
    lines.add(FolderTreeGuideLine(x, 0, x, height));
  }

  if (!showBranch) {
    return lines;
  }

  final jointY = height / 2;
  final branchX = (ancestorHasMoreSiblings.length * seg) + (seg / 2);
  lines
    ..add(FolderTreeGuideLine(branchX, 0, branchX, jointY))
    ..add(FolderTreeGuideLine(branchX, jointY, width, jointY));
  if (hasMoreSiblings) {
    lines.add(FolderTreeGuideLine(branchX, jointY, branchX, height));
  }
  return lines;
}

/// The lines in the gap between two subtree blocks: the rails that keep
/// running, and the spine of the folder whose content follows.
List<FolderTreeGuideLine> folderTreeIntergroupGapLines({
  required List<bool> ancestorHasMoreSiblings,
  required double height,
}) {
  const seg = folderTreeSegmentWidth;
  final list = ancestorHasMoreSiblings;
  final lines = <FolderTreeGuideLine>[];

  for (var index = 1; index < list.length; index++) {
    if (!list[index]) {
      continue;
    }
    final x = (index * seg) + (seg / 2);
    lines.add(FolderTreeGuideLine(x, 0, x, height));
  }

  if (list.isEmpty) {
    return lines;
  }

  final branchSpineX = (list.length * seg) + (seg / 2);
  lines.add(FolderTreeGuideLine(branchSpineX, 0, branchSpineX, height));
  return lines;
}
