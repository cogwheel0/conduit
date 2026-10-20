import 'package:material_ui/material_ui.dart';

import 'package:conduit_core/utils/folder_tree_guides.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';

// The tree ordering and the guide geometry live in conduit_core, where they
// are tested without Flutter.
export 'package:conduit_core/utils/folder_tree_guides.dart'
    show FolderTreeListEntry, folderTreeEntriesForTargets;

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
    this.guideInset = 0,
  });

  /// Horizontal space per nesting level for guide lines.
  static const double segmentWidth = folderTreeSegmentWidth;

  /// See [FolderTreeListEntry.ancestorHasMoreSiblings].
  final List<bool> ancestorHasMoreSiblings;

  /// Whether this row shows the horizontal branch from the spine.
  final bool showBranch;

  /// Whether more siblings follow under the same parent after this row.
  final bool hasMoreSiblings;

  /// Content placed to the right of the guide column (folder tile, etc.).
  final Widget child;

  /// Extra leading inset for the painted guides, without moving [child].
  final double guideInset;

  @override
  Widget build(BuildContext context) {
    if (!showBranch && ancestorHasMoreSiblings.every((value) => !value)) {
      return child;
    }

    final sidebarTheme = context.sidebarTheme;
    final guideWidth = folderTreeGuideWidth(
      ancestorCount: ancestorHasMoreSiblings.length,
      showBranch: showBranch,
    );
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
          left: guideInset,
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
      ..strokeWidth = folderTreeGuideStrokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.square
      ..strokeJoin = StrokeJoin.miter
      ..isAntiAlias = true;

    for (final line in folderTreeHierarchyLines(
      ancestorHasMoreSiblings: ancestorHasMoreSiblings,
      showBranch: showBranch,
      hasMoreSiblings: hasMoreSiblings,
      width: size.width,
      height: size.height,
    )) {
      canvas.drawLine(
        Offset(line.x1, line.y1),
        Offset(line.x2, line.y2),
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
    this.guideInset = 0,
  });

  /// Same ancestry flags as the rows below this gap.
  final List<bool> ancestorHasMoreSiblings;

  /// Extra leading inset for the painted guides.
  final double guideInset;

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
      child: Padding(
        padding: EdgeInsets.only(left: guideInset),
        child: CustomPaint(
          painter: _FolderTreeIntergroupGapPainter(
            ancestorHasMoreSiblings: ancestorHasMoreSiblings,
            lineColor: lineColor,
          ),
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
      ..strokeWidth = folderTreeGuideStrokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.square
      ..isAntiAlias = true;

    for (final line in folderTreeIntergroupGapLines(
      ancestorHasMoreSiblings: ancestorHasMoreSiblings,
      height: size.height,
    )) {
      canvas.drawLine(
        Offset(line.x1, line.y1),
        Offset(line.x2, line.y2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _FolderTreeIntergroupGapPainter oldDelegate) {
    return oldDelegate.ancestorHasMoreSiblings != ancestorHasMoreSiblings ||
        oldDelegate.lineColor != lineColor;
  }
}
