import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:conduit/shared/widgets/platform_ui/vocabulary.dart';

import '../../../core/services/haptic_service.dart';
import '../../../shared/theme/color_tokens.dart';
import '../../../shared/theme/theme_extensions.dart';
import 'conversation_tile.dart';

/// Space above the first section header, below the sidebar toolbar.
const double kSidebarFirstSectionTopSpacing = Spacing.md;

/// Space above every later section header, between it and the rows of the
/// section before.
const double kSidebarSectionTopSpacing = 20;

/// Space between a section header and its first row.
const double kSidebarSectionHeaderBottomSpacing = Spacing.xs;

/// Where a section header starts and ends: on the list's 16 pt margin,
/// outside its rows' content edge ([kSidebarRowContentInset]).
const double kSidebarSectionHeaderInset = Spacing.md;

/// Section header of a sidebar list: a disclosure chevron on the list's
/// margin, pointing down while the section is open, then the title, with
/// any control (New Folder) at the trailing end.
///
/// A section that cannot collapse keeps the chevron's column empty, so every
/// section title starts on one edge.
///
/// A trailing control sits in the column of the rows' own trailing controls
/// (a folder's disclosure button), centred on the title's line, and leaves
/// the header as tall as one without it.
class SidebarSectionHeader extends StatelessWidget {
  const SidebarSectionHeader({
    super.key,
    required this.title,
    this.isFirst = false,
    this.isExpanded,
    this.onToggle,
    this.trailing,
    this.chevronKey,
  }) : assert(
         (isExpanded == null) == (onToggle == null),
         'A collapsible header needs both isExpanded and onToggle.',
       );

  final String title;

  /// Whether this header opens the list, right below the toolbar.
  final bool isFirst;

  /// Whether the section's rows show; null for a section that cannot
  /// collapse.
  final bool? isExpanded;

  /// Opens or closes the section.
  final VoidCallback? onToggle;

  /// A compact control at the trailing end, such as New Folder: laid out
  /// [TouchTarget.minimum] wide and as tall as the header, it should centre
  /// its content.
  ///
  /// At the default text size a later section's header is about 44 pt tall,
  /// but the first section's is about 40 pt, below the toolbar's tighter
  /// spacing. The control keeps that shorter target rather than make the
  /// header taller than the others.
  final Widget? trailing;

  final Key? chevronKey;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final expanded = isExpanded;
    final collapsible = expanded != null;
    // Material's pair reads "Expanded" for an open section and "Collapsed"
    // for a closed one, in every language Flutter ships.
    final localizations = MaterialLocalizations.of(context);
    final titleText = Semantics(
      header: true,
      button: collapsible,
      expanded: expanded,
      label: title,
      value: expanded == null
          ? null
          : expanded
          ? localizations.collapsedHint
          : localizations.expandedHint,
      onTap: collapsible ? _toggle : null,
      excludeSemantics: true,
      child: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: sidebarSectionHeaderStyle(theme),
      ),
    );

    final topSpacing = isFirst
        ? kSidebarFirstSectionTopSpacing
        : kSidebarSectionTopSpacing;
    final row = Padding(
      padding: EdgeInsetsDirectional.only(
        start: kSidebarSectionHeaderInset,
        end: kSidebarSectionHeaderInset,
        top: topSpacing,
        bottom: kSidebarSectionHeaderBottomSpacing,
      ),
      child: Row(
        children: [
          // Main's icon column, wider should the chevron outgrow it.
          SizedBox(
            width: math.max(
              MediaQuery.textScalerOf(context).scale(IconSize.listItem),
              _sectionChevronExtent(context),
            ),
            child: expanded == null
                ? null
                : Center(
                    child: ExcludeSemantics(
                      child: _SectionChevron(
                        key: chevronKey,
                        expanded: expanded,
                      ),
                    ),
                  ),
          ),
          const SizedBox(width: Spacing.xxs),
          Expanded(child: titleText),
          // Room for the trailing control, which the stack below lays over
          // the row so that it does not make the row taller.
          if (trailing != null)
            const SizedBox(
              width:
                  Spacing.sm +
                  TouchTarget.minimum +
                  kSidebarRowContentInset -
                  kSidebarSectionHeaderInset,
            ),
        ],
      ),
    );

    final header = switch (trailing) {
      null => row,
      final Widget trailing => Stack(
        clipBehavior: Clip.none,
        children: [
          row,
          PositionedDirectional(
            top: 0,
            bottom: 0,
            end: kSidebarRowContentInset,
            width: TouchTarget.minimum,
            // The control takes taps across the header's whole height, so
            // no row below takes any part of its target, while its content,
            // centred on the header, is drawn down on the title's line: half
            // the difference between the space above the title and the
            // space below it. Merged above the move, it is one node for
            // assistive technologies, over the same box that takes taps.
            child: MergeSemantics(
              child: Transform.translate(
                offset: Offset(
                  0,
                  (topSpacing - kSidebarSectionHeaderBottomSpacing) / 2,
                ),
                transformHitTests: false,
                child: trailing,
              ),
            ),
          ),
        ],
      ),
    };

    if (!collapsible) return header;
    // The whole header toggles, not just its title; a trailing control
    // keeps its own taps.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggle,
      excludeFromSemantics: true,
      child: header,
    );
  }

  void _toggle() {
    ConduitHaptics.selectionClick();
    onToggle?.call();
  }
}

/// Footnote-weight label for sidebar section headers: semibold secondary
/// text, quieter than the 17pt rows it introduces.
TextStyle sidebarSectionHeaderStyle(ConduitThemeExtension theme) =>
    AppTypography.titleMediumStyle.copyWith(
      color: sidebarSectionHeaderColor(theme),
      fontWeight: FontWeight.w600,
      decoration: TextDecoration.none,
    );

/// How far dark mode moves section headers from the secondary text tone
/// toward the page.
const double _kDarkSectionHeaderQuieting = 0.15;

/// Tone of sidebar section headers and their chevrons: the secondary text
/// tone, a little quieter in dark mode.
///
/// Light text on a dark page reads brighter and heavier than dark text on a
/// light one, and dark rows use a soft white, so at the full secondary tone
/// dark headers sat almost level with the rows below them (2.4:1 between
/// the two, against 4.1:1 in light). Moved toward the page they keep the
/// step iOS keeps between its label and secondary label colours in dark
/// mode (about 3.3:1), and never fall below 4.5:1 on the page.
Color sidebarSectionHeaderColor(ConduitThemeExtension theme) {
  if (!theme.isDark) return theme.textSecondary;
  final page = theme.surfaceBackground;
  return withMinContrast(
    Color.lerp(theme.textSecondary, page, _kDarkSectionHeaderQuieting)!,
    page,
    4.5,
  );
}

/// The disclosure chevron of a collapsible section header, drawn as the SF
/// Symbol chevron set in the header's font would be: as tall and heavy as
/// its semibold title (SF chevron.down at 16 pt semibold is 14.7 by 8.7 pt,
/// with the 2 pt stroke of the title's stems), in the title's tone, centred
/// on the title's line before it. It points down while the section is open
/// and toward the trailing edge while it is closed, turning between the two
/// as UIKit's outline disclosure does.
class _SectionChevron extends StatelessWidget {
  const _SectionChevron({super.key, required this.expanded});

  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final style = sidebarSectionHeaderStyle(theme);
    final fontSize = _sectionChevronFontSize(context);
    final extent = _sectionChevronExtent(context);
    final closedTurns = Directionality.of(context) == TextDirection.rtl
        ? 0.25
        : -0.25;
    return AnimatedRotation(
      turns: expanded ? 0 : closedTurns,
      duration: context.motionDuration(AnimationDuration.fast),
      curve: Curves.easeOutCubic,
      child: CustomPaint(
        size: Size.square(extent),
        painter: _ChevronPainter(
          color: style.color ?? theme.iconSecondary,
          strokeWidth: fontSize * _kSectionChevronStrokePerPoint,
          height: fontSize * _kSectionChevronHeightPerPoint,
        ),
      ),
    );
  }
}

/// The header title's font size under the current text scale: the chevron
/// scales with the title under Dynamic Type, as a symbol in text would.
double _sectionChevronFontSize(BuildContext context) =>
    MediaQuery.textScalerOf(context)
        .scale(sidebarSectionHeaderStyle(context.conduitTheme).fontSize ?? 16);

/// The side of the chevron's square.
double _sectionChevronExtent(BuildContext context) =>
    _sectionChevronFontSize(context) * _kSectionChevronWidthPerPoint;

/// Ink width of SF chevron.down per point of its font size, at semibold:
/// 14.7 pt at 16 pt.
const double _kSectionChevronWidthPerPoint = 0.917;

/// Ink height of SF chevron.down per point of its font size, at semibold:
/// 8.7 pt at 16 pt.
const double _kSectionChevronHeightPerPoint = 0.542;

/// Stroke of SF chevron.down per point of its font size, at semibold: the
/// 2 pt stem of semibold SF text at 16 pt.
const double _kSectionChevronStrokePerPoint = 0.125;

/// A down-pointing chevron across the full width of its square box, with
/// round caps and joins, centred in the box.
class _ChevronPainter extends CustomPainter {
  const _ChevronPainter({
    required this.color,
    required this.strokeWidth,
    required this.height,
  });

  final Color color;
  final double strokeWidth;

  /// Ink height, caps included.
  final double height;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    // The caps reach half a stroke past each end of the path.
    final halfWidth = (size.width - strokeWidth) / 2;
    final halfHeight = (height - strokeWidth) / 2;
    final centre = size.center(Offset.zero);
    final path = Path()
      ..moveTo(centre.dx - halfWidth, centre.dy - halfHeight)
      ..lineTo(centre.dx, centre.dy + halfHeight)
      ..lineTo(centre.dx + halfWidth, centre.dy - halfHeight);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_ChevronPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.strokeWidth != strokeWidth ||
      oldDelegate.height != height;
}
