import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import '../../../theme/theme_extensions.dart';
import '../../horizontal_gesture_ownership.dart';
import 'horizontal_overflow_fade.dart';
import 'markdown_style.dart';

/// A markdown table set inside the text column: a rounded, hairline-bordered
/// card that keeps the page margins.
///
/// Columns are sized from their content. A table whose cells all fit on one
/// line fills the column in proportion to its content; otherwise narrow
/// columns keep their natural width, no column takes more than
/// [maxColumnFraction] of the frame while others compete for space, and long
/// cells wrap. The table scrolls sideways only when its columns cannot fit
/// even at a comfortable reading width ([minComfortableColumnWidth]); then
/// columns may grow to [maxScrollingColumnFraction] so rows stay short.
///
/// The frame stays whole while the table scrolls: the border, header band and
/// row rules span the frame and never move or fade; only the cell text
/// scrolls, fading at an edge that hides more of it, above a slim scroll
/// indicator.
class MarkdownTableFrame extends StatefulWidget {
  const MarkdownTableFrame({
    required this.header,
    required this.rows,
    required this.style,
    super.key,
  });

  /// Largest share of the frame one column takes while other columns compete
  /// for the space; past it the column's cells wrap.
  static const double maxColumnFraction = 0.45;

  /// Largest share of the frame one column takes once the table scrolls
  /// anyway: wider columns keep rows to fewer lines, and the next column
  /// peeks in at the edge instead of hiding behind a tall wrapped header.
  static const double maxScrollingColumnFraction = 0.6;

  /// Narrowest a column with longer content is squeezed to (cell padding
  /// included) before the table scrolls instead, in points at 100% text
  /// size: about a dozen characters of table text.
  static const double minComfortableColumnWidth = 112;

  /// Column cap used when the frame has no finite width to share.
  static const double unboundedColumnCap = 240;

  /// Inner padding of every cell.
  static const EdgeInsets cellPadding = EdgeInsets.symmetric(
    horizontal: Spacing.md - Spacing.xs,
    vertical: Spacing.sm + 1,
  );

  final List<Widget> header;
  final List<List<Widget>> rows;
  final ConduitMarkdownStyle style;

  /// Column widths (cell padding included) for columns whose content is at
  /// least [minWidths] (longest word) and at most [maxWidths] (every cell on
  /// one line) wide, shared across [availableWidth].
  ///
  /// When the result sums to more than [availableWidth] the table scrolls.
  @visibleForTesting
  static List<double> solveColumnWidths({
    required List<double> minWidths,
    required List<double> maxWidths,
    required double availableWidth,
    double comfortableWidth = minComfortableColumnWidth,
    double maxFraction = maxColumnFraction,
    double maxScrollingFraction = maxScrollingColumnFraction,
  }) {
    assert(minWidths.length == maxWidths.length);
    final count = maxWidths.length;
    if (count == 0) return const <double>[];
    final natural = [
      for (var i = 0; i < count; i++) math.max(minWidths[i], maxWidths[i]),
    ];
    if (!availableWidth.isFinite) {
      return [
        for (var i = 0; i < count; i++)
          math.max(minWidths[i], math.min(natural[i], unboundedColumnCap)),
      ];
    }
    double sum(Iterable<double> values) => values.fold(0.0, (a, b) => a + b);

    final naturalTotal = sum(natural);
    if (naturalTotal <= availableWidth) {
      // Every cell fits on one line: share the spare width in proportion to
      // content so the table fills the column without crowding a short one.
      final spare = availableWidth - naturalTotal;
      if (naturalTotal <= 0) {
        return List<double>.filled(count, availableWidth / count);
      }
      return [
        for (final width in natural) width + spare * width / naturalTotal,
      ];
    }

    // Never below the longest word, nor squeezed under a comfortable reading
    // width unless the content is narrower than that anyway.
    final floor = [
      for (var i = 0; i < count; i++)
        math.max(minWidths[i], math.min(natural[i], comfortableWidth)),
    ];
    // Natural width, capped so one long column cannot crowd out the rest.
    final cap = availableWidth * maxFraction;
    final preferred = [
      for (var i = 0; i < count; i++)
        math.max(floor[i], math.min(natural[i], cap)),
    ];
    final preferredTotal = sum(preferred);
    if (preferredTotal <= availableWidth) {
      // Room to spare: capped columns grow toward their natural width, in
      // proportion to how much more they want. Their combined want exceeds
      // the spare width (the natural total does not fit), so none overshoots.
      final spare = availableWidth - preferredTotal;
      final wants = [for (var i = 0; i < count; i++) natural[i] - preferred[i]];
      final totalWant = sum(wants);
      if (totalWant <= 0) return preferred;
      return [
        for (var i = 0; i < count; i++)
          preferred[i] + spare * wants[i] / totalWant,
      ];
    }

    if (sum(floor) <= availableWidth) {
      // Slightly too wide: take the excess from the columns with the most room
      // above their floor, so no column drops under it.
      final excess = preferredTotal - availableWidth;
      final slack = [for (var i = 0; i < count; i++) preferred[i] - floor[i]];
      final totalSlack = sum(slack);
      return [
        for (var i = 0; i < count; i++)
          preferred[i] - excess * slack[i] / totalSlack,
      ];
    }

    // Too many columns to fit at a readable width: the table scrolls, so let
    // long columns run wider and wrap less.
    final scrollingCap = availableWidth * maxScrollingFraction;
    return [
      for (var i = 0; i < count; i++)
        math.max(floor[i], math.min(natural[i], scrollingCap)),
    ];
  }

  @override
  State<MarkdownTableFrame> createState() => _MarkdownTableFrameState();
}

class _MarkdownTableFrameState extends State<MarkdownTableFrame> {
  final _TableRowGeometry _geometry = _TableRowGeometry();

  @override
  void dispose() {
    _geometry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    final radius = BorderRadius.circular(style.tableRadius);
    final fontSize = style.tableCell.fontSize ?? 15;
    final textScale =
        MediaQuery.textScalerOf(context).scale(fontSize) / fontSize;

    Widget cell(Widget child) =>
        Padding(padding: MarkdownTableFrame.cellPadding, child: child);
    // Column heads sit on the rule above their data, so a short head next to
    // one that wraps lines up with the head's last line, not its first.
    Widget headerCell(Widget child) => TableCell(
      verticalAlignment: TableCellVerticalAlignment.bottom,
      child: cell(child),
    );

    return DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(
          color: style.tableBorderColor,
          width: BorderWidth.regular,
        ),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final solver = _ColumnWidthSolver(
              availableWidth: constraints.maxWidth,
              comfortableWidth:
                  MarkdownTableFrame.minComfortableColumnWidth * textScale,
            );
            final table = Table(
              columnWidths: {
                for (var i = 0; i < widget.header.length; i++)
                  i: _SolvedColumnWidth(i, solver),
              },
              defaultVerticalAlignment: TableCellVerticalAlignment.top,
              children: [
                TableRow(
                  children: widget.header
                      .map(headerCell)
                      .toList(growable: false),
                ),
                for (final row in widget.rows)
                  TableRow(children: row.map(cell).toList(growable: false)),
              ],
            );
            return _TableChrome(
              geometry: _geometry,
              headerColor: style.tableHeaderBackground,
              ruleColor: style.tableBorderColor,
              ruleWidth: BorderWidth.thin,
              child: HorizontalOverflowFade(
                scrollIndicatorColor: style.textPrimary.withValues(
                  alpha: style.isDark ? 0.34 : 0.26,
                ),
                // Clear of the rounded corners.
                scrollIndicatorInset: style.tableRadius,
                builder: (context, controller) =>
                    HorizontalScrollGestureBoundary(
                      child: SingleChildScrollView(
                        controller: controller,
                        scrollDirection: Axis.horizontal,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minWidth: constraints.maxWidth,
                          ),
                          child: _RowGeometryReporter(
                            geometry: _geometry,
                            child: table,
                          ),
                        ),
                      ),
                    ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Shares one width plan across a table's columns.
///
/// [TableColumnWidth] sees one column at a time, but a fair split depends on
/// every column, so each column asks the solver, which measures the whole
/// table through the cells' parent. Intrinsic sizes are cached per layout by
/// the cells themselves, so repeated asks stay cheap.
class _ColumnWidthSolver {
  _ColumnWidthSolver({
    required this.availableWidth,
    required this.comfortableWidth,
  });

  final double availableWidth;
  final double comfortableWidth;

  double widthOf(int column, Iterable<RenderBox> cells) {
    if (cells.isEmpty) return 0;
    final table = cells.first.parent;
    if (table is! RenderTable || column >= table.columns) {
      return _columnExtents(cells).$2;
    }
    final minWidths = <double>[];
    final maxWidths = <double>[];
    for (var x = 0; x < table.columns; x++) {
      final (min, max) = _columnExtents(table.column(x));
      minWidths.add(min);
      maxWidths.add(max);
    }
    return MarkdownTableFrame.solveColumnWidths(
      minWidths: minWidths,
      maxWidths: maxWidths,
      availableWidth: availableWidth,
      comfortableWidth: comfortableWidth,
    )[column];
  }

  static (double, double) _columnExtents(Iterable<RenderBox> cells) {
    var min = 0.0;
    var max = 0.0;
    for (final cell in cells) {
      min = math.max(min, cell.getMinIntrinsicWidth(double.infinity));
      max = math.max(max, cell.getMaxIntrinsicWidth(double.infinity));
    }
    return (min, max);
  }
}

class _SolvedColumnWidth extends TableColumnWidth {
  const _SolvedColumnWidth(this.column, this.solver);

  final int column;
  final _ColumnWidthSolver solver;

  @override
  double minIntrinsicWidth(Iterable<RenderBox> cells, double containerWidth) =>
      solver.widthOf(column, cells);

  @override
  double maxIntrinsicWidth(Iterable<RenderBox> cells, double containerWidth) =>
      solver.widthOf(column, cells);
}

/// Bottom edge of every laid-out table row, measured by the table and painted
/// by the frame.
class _TableRowGeometry extends ChangeNotifier {
  List<double> _rowBottoms = const <double>[];

  List<double> get rowBottoms => _rowBottoms;

  void update(List<double> rowBottoms) {
    if (listEquals(rowBottoms, _rowBottoms)) return;
    _rowBottoms = rowBottoms;
    notifyListeners();
  }
}

/// Records the row edges of the [Table] below it after each layout, and
/// reserves a track for the scroll indicator under the last row when the
/// table is wider than the frame, so the indicator never underlines text.
class _RowGeometryReporter extends SingleChildRenderObjectWidget {
  const _RowGeometryReporter({required this.geometry, super.child});

  final _TableRowGeometry geometry;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderRowGeometryReporter(geometry);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderRowGeometryReporter renderObject,
  ) {
    renderObject.geometry = geometry;
  }
}

class _RenderRowGeometryReporter extends RenderProxyBox {
  _RenderRowGeometryReporter(this.geometry);

  _TableRowGeometry geometry;

  /// Height of the track: the indicator plus a gap on each side.
  static const double scrollTrackHeight =
      HorizontalOverflowFade.scrollIndicatorThickness +
      HorizontalOverflowFade.scrollIndicatorBottomGap;

  /// The table scrolls when it is wider than the frame, which the frame
  /// passes down as the minimum width.
  static double _trackFor(double tableWidth, BoxConstraints constraints) =>
      tableWidth > constraints.minWidth + 0.5 ? scrollTrackHeight : 0;

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final table = child;
    if (table == null) return constraints.smallest;
    final tableSize = table.getDryLayout(constraints);
    return constraints.constrain(
      Size(
        tableSize.width,
        tableSize.height + _trackFor(tableSize.width, constraints),
      ),
    );
  }

  @override
  void performLayout() {
    final table = child;
    if (table == null) {
      size = constraints.smallest;
      return;
    }
    table.layout(constraints, parentUsesSize: true);
    size = constraints.constrain(
      Size(
        table.size.width,
        table.size.height + _trackFor(table.size.width, constraints),
      ),
    );
    if (table is RenderTable) {
      geometry.update([
        for (var row = 0; row < table.rows; row++) table.getRowBox(row).bottom,
      ]);
    }
  }
}

/// Paints the header band and the rules between rows across the whole frame,
/// beneath the scrolling cells, so neither scrolls away nor fades with the
/// cell text at an overflowing edge.
class _TableChrome extends SingleChildRenderObjectWidget {
  const _TableChrome({
    required this.geometry,
    required this.headerColor,
    required this.ruleColor,
    required this.ruleWidth,
    super.child,
  });

  final _TableRowGeometry geometry;
  final Color headerColor;
  final Color ruleColor;
  final double ruleWidth;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderTableChrome(
    geometry: geometry,
    headerColor: headerColor,
    ruleColor: ruleColor,
    ruleWidth: ruleWidth,
  );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderTableChrome renderObject,
  ) {
    renderObject
      ..geometry = geometry
      ..headerColor = headerColor
      ..ruleColor = ruleColor
      ..ruleWidth = ruleWidth;
  }
}

class _RenderTableChrome extends RenderProxyBox {
  _RenderTableChrome({
    required _TableRowGeometry geometry,
    required Color headerColor,
    required Color ruleColor,
    required double ruleWidth,
  }) : _geometry = geometry,
       _headerColor = headerColor,
       _ruleColor = ruleColor,
       _ruleWidth = ruleWidth;

  _TableRowGeometry _geometry;
  set geometry(_TableRowGeometry value) {
    if (identical(value, _geometry)) return;
    if (attached) _geometry.removeListener(markNeedsPaint);
    _geometry = value;
    if (attached) _geometry.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  Color _headerColor;
  set headerColor(Color value) {
    if (value == _headerColor) return;
    _headerColor = value;
    markNeedsPaint();
  }

  Color _ruleColor;
  set ruleColor(Color value) {
    if (value == _ruleColor) return;
    _ruleColor = value;
    markNeedsPaint();
  }

  double _ruleWidth;
  set ruleWidth(double value) {
    if (value == _ruleWidth) return;
    _ruleWidth = value;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _geometry.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _geometry.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final bottoms = _geometry.rowBottoms;
    if (bottoms.isNotEmpty && size.width > 0) {
      final canvas = context.canvas;
      final headerBottom = math.min(bottoms.first, size.height);
      canvas.drawRect(
        Rect.fromLTWH(offset.dx, offset.dy, size.width, headerBottom),
        Paint()..color = _headerColor,
      );
      final rulePaint = Paint()..color = _ruleColor;
      for (var row = 0; row < bottoms.length - 1; row++) {
        final y = bottoms[row];
        if (y >= size.height) break;
        canvas.drawRect(
          Rect.fromLTWH(
            offset.dx,
            offset.dy + y - _ruleWidth / 2,
            size.width,
            _ruleWidth,
          ),
          rulePaint,
        );
      }
    }
    super.paint(context, offset);
  }
}
