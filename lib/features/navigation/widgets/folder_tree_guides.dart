import 'package:flutter/material.dart';

import 'package:conduit/core/models/folder.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';

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

/// Draws folder-tree connector lines to the left of [child], matching the
/// chats drawer hierarchy styling.
class FolderTreeHierarchyNode extends StatelessWidget {
  /// Creates a widget that paints tree guides beside [child].
  const FolderTreeHierarchyNode({
    super.key,
    required this.ancestorHasMoreSiblings,
    required this.showBranch,
    required this.hasMoreSiblings,
    required this.child,
  });

  /// Horizontal space per nesting level for guide lines.
  static const double segmentWidth = 15;

  /// See [FolderTreeListEntry.ancestorHasMoreSiblings].
  final List<bool> ancestorHasMoreSiblings;

  /// Whether this row shows the horizontal branch from the spine.
  final bool showBranch;

  /// Whether more siblings follow under the same parent after this row.
  final bool hasMoreSiblings;

  /// Content placed to the right of the guide column (folder tile, etc.).
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!showBranch && ancestorHasMoreSiblings.every((value) => !value)) {
      return child;
    }

    final sidebarTheme = context.sidebarTheme;
    final guideSegments = ancestorHasMoreSiblings.length + (showBranch ? 1 : 0);
    final guideWidth = guideSegments * segmentWidth;
    final lineColor = Color.alphaBlend(
      sidebarTheme.foreground.withValues(alpha: 0.30),
      sidebarTheme.background,
    );

    return Stack(
      children: [
        Padding(
          padding: EdgeInsets.only(left: guideWidth),
          child: child,
        ),
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: guideWidth,
          child: ExcludeSemantics(
            child: CustomPaint(
              painter: _FolderTreeHierarchyPainter(
                ancestorHasMoreSiblings: ancestorHasMoreSiblings,
                showBranch: showBranch,
                hasMoreSiblings: hasMoreSiblings,
                lineColor: lineColor,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _FolderTreeHierarchyPainter extends CustomPainter {
  const _FolderTreeHierarchyPainter({
    required this.ancestorHasMoreSiblings,
    required this.showBranch,
    required this.hasMoreSiblings,
    required this.lineColor,
  });

  final List<bool> ancestorHasMoreSiblings;
  final bool showBranch;
  final bool hasMoreSiblings;
  final Color lineColor;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = 1.25
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.square
      ..strokeJoin = StrokeJoin.miter
      ..isAntiAlias = true;

    final centerY = size.height / 2;
    final seg = FolderTreeHierarchyNode.segmentWidth;

    for (var index = 0; index < ancestorHasMoreSiblings.length; index++) {
      if (index == 0 || !ancestorHasMoreSiblings[index]) {
        continue;
      }

      final x = (index * seg) + (seg / 2);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }

    if (!showBranch) {
      return;
    }

    final branchX = (ancestorHasMoreSiblings.length * seg) + (seg / 2);
    final jointY = centerY;

    canvas.drawLine(Offset(branchX, 0), Offset(branchX, jointY), paint);
    canvas.drawLine(Offset(branchX, jointY), Offset(size.width, jointY), paint);

    if (hasMoreSiblings) {
      canvas.drawLine(
        Offset(branchX, jointY),
        Offset(branchX, size.height),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _FolderTreeHierarchyPainter oldDelegate) {
    return oldDelegate.ancestorHasMoreSiblings != ancestorHasMoreSiblings ||
        oldDelegate.showBranch != showBranch ||
        oldDelegate.hasMoreSiblings != hasMoreSiblings ||
        oldDelegate.lineColor != lineColor;
  }
}

/// Vertical spacer that paints continuing rails between subtree blocks.
class FolderTreeIntergroupGap extends StatelessWidget {
  /// Creates a spacer that paints hierarchy rails for the given ancestry path.
  const FolderTreeIntergroupGap({
    super.key,
    required this.ancestorHasMoreSiblings,
  });

  /// Same ancestry flags as the rows below this gap.
  final List<bool> ancestorHasMoreSiblings;

  @override
  Widget build(BuildContext context) {
    final sidebarTheme = context.sidebarTheme;
    final lineColor = Color.alphaBlend(
      sidebarTheme.foreground.withValues(alpha: 0.30),
      sidebarTheme.background,
    );

    return SizedBox(
      height: Spacing.sm,
      width: double.infinity,
      child: CustomPaint(
        painter: _FolderTreeIntergroupGapPainter(
          ancestorHasMoreSiblings: ancestorHasMoreSiblings,
          lineColor: lineColor,
        ),
      ),
    );
  }
}

class _FolderTreeIntergroupGapPainter extends CustomPainter {
  const _FolderTreeIntergroupGapPainter({
    required this.ancestorHasMoreSiblings,
    required this.lineColor,
  });

  final List<bool> ancestorHasMoreSiblings;
  final Color lineColor;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = 1.25
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.square
      ..isAntiAlias = true;

    final seg = FolderTreeHierarchyNode.segmentWidth;
    final list = ancestorHasMoreSiblings;

    for (var index = 1; index < list.length; index++) {
      if (!list[index]) {
        continue;
      }
      final x = (index * seg) + (seg / 2);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }

    if (list.isEmpty) {
      return;
    }

    final branchSpineX = (list.length * seg) + (seg / 2);
    canvas.drawLine(
      Offset(branchSpineX, 0),
      Offset(branchSpineX, size.height),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _FolderTreeIntergroupGapPainter oldDelegate) {
    return oldDelegate.ancestorHasMoreSiblings != ancestorHasMoreSiblings ||
        oldDelegate.lineColor != lineColor;
  }
}
