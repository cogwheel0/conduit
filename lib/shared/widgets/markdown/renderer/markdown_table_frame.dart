import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../../theme/theme_extensions.dart';
import '../../horizontal_gesture_ownership.dart';
import 'horizontal_overflow_fade.dart';
import 'markdown_style.dart';

/// Heights of a table column's cells, row by row (header first), when the
/// column is [width] wide, cell padding included.
typedef TableCellHeights = List<double> Function(int column, double width);

/// A markdown table set inside the text column: a rounded, hairline-bordered
/// card that keeps the page margins.
///
/// Columns are sized from their content. A table whose cells all fit on one
/// line fills the column in proportion to its content. Otherwise short
/// columns keep their natural width and the rest of the frame goes where it
/// saves the most wrapped lines, so a long header gets room before it wraps
/// to a third line and no column sits half empty. The table scrolls sideways
/// only when its columns cannot fit even at a comfortable reading width
/// ([minComfortableColumnWidth]); then columns may grow to
/// [maxScrollingColumnFraction] so rows stay short.
///
/// The frame stays whole while the table scrolls: the border, header band and
/// row rules span the frame and never move or fade; only the cell text
/// scrolls, fading out inside the cell margin at an edge that hides more of
/// it, above a thin scroll indicator that shows while it moves.
class MarkdownTableFrame extends StatefulWidget {
  const MarkdownTableFrame({
    required this.header,
    required this.rows,
    required this.style,
    super.key,
  });

  /// Largest share of the frame one column takes while other columns compete
  /// for the space, when the cells' heights cannot be measured; past it the
  /// column's cells wrap.
  static const double maxColumnFraction = 0.45;

  /// Width steps tried when sharing spare room between wrapping columns, in
  /// points; coarser for very wide spare room or very long tables.
  static const double widthSearchStep = 4;

  /// Most cell measurements (one text layout each) a table spends on sharing
  /// out spare room, so its first layout stays within a frame; past it the
  /// steps get coarser.
  static const int maxHeightMeasurements = 600;

  /// How much a line of the header row counts against a line of the body
  /// when sharing out room: a tall header band reads heavy above short
  /// rows, so long heads get room before they wrap to a third line.
  static const double headerLineWeight = 1.5;

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

  /// Width of the fade at an edge that hides cell text, inside the cell
  /// margin.
  static const double edgeFadeExtent = 12;

  final List<Widget> header;
  final List<List<Widget>> rows;
  final ConduitMarkdownStyle style;

  /// Column widths (cell padding included) for columns whose content is at
  /// least [minWidths] (longest word) and at most [maxWidths] (every cell on
  /// one line) wide, shared across [availableWidth].
  ///
  /// With [cellHeights], room beyond each column's floor goes, step by step,
  /// to the column whose growth saves the most table height per point, so
  /// the table wraps into as few lines as it can; without it, columns are
  /// capped at [maxFraction] and share what is left by how much they want.
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
    TableCellHeights? cellHeights,
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
    if (sum(floor) > availableWidth) {
      // Too many columns to fit at a readable width: the table scrolls, so
      // let long columns run wider and wrap less.
      final scrollingCap = availableWidth * maxScrollingFraction;
      return [
        for (var i = 0; i < count; i++)
          math.max(floor[i], math.min(natural[i], scrollingCap)),
      ];
    }
    if (cellHeights != null) {
      final fitted = _fitToFewestLines(
        floor: floor,
        natural: natural,
        availableWidth: availableWidth,
        cellHeights: cellHeights,
      );
      if (fitted != null) return fitted;
    }

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

  /// Shares the room above [floor] so the table is as short as it can be,
  /// its header row counting [headerLineWeight] times.
  ///
  /// Widths move in steps of [widthSearchStep]. First each step widens the
  /// column whose next saved line costs the fewest points, until no step
  /// saves a line; then room moves from one column to another wherever that
  /// saves more lines than it costs. What is left goes to the columns in
  /// proportion to how much more they want. Null when the cells cannot be
  /// measured row by row.
  static List<double>? _fitToFewestLines({
    required List<double> floor,
    required List<double> natural,
    required double availableWidth,
    required TableCellHeights cellHeights,
  }) {
    final count = floor.length;
    double sum(Iterable<double> values) => values.fold(0.0, (a, b) => a + b);
    final spare = availableWidth - sum(floor);
    if (spare <= 0) return List<double>.of(floor);
    final flexible = [
      for (var i = 0; i < count; i++)
        if (natural[i] > floor[i]) i,
    ];

    final measured = <int, Map<int, List<double>>>{};
    // Fine steps, unless that would measure too many cells.
    late final double step;
    double widthAt(int column, int steps) =>
        math.min(natural[column], floor[column] + steps * step);
    List<double> heightsAt(int column, int steps) =>
        (measured[column] ??= <int, List<double>>{})[steps] ??= cellHeights(
          column,
          steps == 0 ? floor[column] : widthAt(column, steps),
        );

    final rows = heightsAt(0, 0).length;
    if (rows == 0) return null;
    for (var i = 1; i < count; i++) {
      if (heightsAt(i, 0).length != rows) return null;
    }
    final stepsWithinBudget = math.max(
      1,
      maxHeightMeasurements ~/ math.max(1, rows * flexible.length),
    );
    step = math.max(widthSearchStep, spare / stepsWithinBudget);
    // No column needs to grow past its natural width, nor can it take more
    // than all the spare room.
    final maxSteps = [
      for (var i = 0; i < count; i++)
        math.min(
          ((natural[i] - floor[i]) / step).ceil(),
          (spare / step + 1e-9).floor(),
        ),
    ];

    // Each row is as tall as its tallest cell; the header row counts more.
    double heightOf(List<int> taken) {
      var total = 0.0;
      for (var row = 0; row < rows; row++) {
        var tallest = 0.0;
        for (var i = 0; i < count; i++) {
          final height = heightsAt(i, taken[i])[row];
          if (height > tallest) tallest = height;
        }
        total += row == 0 ? tallest * headerLineWeight : tallest;
      }
      return total;
    }

    double usedBy(List<int> taken) =>
        sum([for (var i = 0; i < count; i++) widthAt(i, taken[i])]);
    bool measurable(int column, int steps) =>
        heightsAt(column, steps).length == rows;

    final taken = List<int>.filled(count, 0);
    // Widen, a step at a time, wherever a saved line costs the least.
    while (true) {
      final room = availableWidth - usedBy(taken);
      final height = heightOf(taken);
      List<int>? best;
      var bestSaving = 0.0;
      for (final column in flexible) {
        for (var s = taken[column] + 1; s <= maxSteps[column]; s++) {
          final growth = widthAt(column, s) - widthAt(column, taken[column]);
          if (growth > room + 0.01) break;
          if (!measurable(column, s)) return null;
          final trial = List<int>.of(taken)..[column] = s;
          final saved = height - heightOf(trial);
          if (saved > 0.5) {
            if (saved / growth > bestSaving) {
              best = trial;
              bestSaving = saved / growth;
            }
            break;
          }
        }
      }
      if (best == null) break;
      taken.setAll(0, best);
    }

    // Then let one column give room to another where that saves lines: the
    // steps above never take room back, so they can stop short of a better
    // split (a long header that needs a little more than one step's worth).
    for (var pass = 0; pass < count * 8; pass++) {
      final room = availableWidth - usedBy(taken);
      final height = heightOf(taken);
      List<int>? best;
      var bestSaved = 0.5;
      for (final gain in flexible) {
        for (final give in flexible) {
          if (give == gain || taken[give] == 0) continue;
          for (var s = taken[gain] + 1; s <= maxSteps[gain]; s++) {
            final needed =
                widthAt(gain, s) - widthAt(gain, taken[gain]) - room - 0.01;
            var g = taken[give];
            while (g > 0 &&
                widthAt(give, taken[give]) - widthAt(give, g) < needed) {
              g--;
            }
            if (widthAt(give, taken[give]) - widthAt(give, g) < needed) break;
            if (!measurable(gain, s) || !measurable(give, g)) return null;
            final trial = List<int>.of(taken)
              ..[gain] = s
              ..[give] = g;
            final saved = height - heightOf(trial);
            if (saved > bestSaved) {
              best = trial;
              bestSaved = saved;
            }
          }
        }
      }
      if (best == null) break;
      taken.setAll(0, best);
    }

    // No further line to save: fill the frame by how much more each column
    // wants. The columns want more than is left (the natural widths do not
    // fit), so none grows past its natural width.
    final widths = [for (var i = 0; i < count; i++) widthAt(i, taken[i])];
    final room = availableWidth - sum(widths);
    if (room > 0) {
      final wants = [for (var i = 0; i < count; i++) natural[i] - widths[i]];
      final totalWant = sum(wants);
      if (totalWant > 0) {
        for (var i = 0; i < count; i++) {
          widths[i] += room * wants[i] / totalWant;
        }
      }
    }
    return widths;
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

    // Every cell, header included, starts on its row's first line, so a
    // short head reads level with the first line of one that wraps, as the
    // body cells below it do.
    Widget cell(Widget child) =>
        Padding(padding: MarkdownTableFrame.cellPadding, child: child);
    // One device pixel, like the system's separators: the outline and the
    // rules read as fine lines rather than as a box drawn around the data.
    final hairline = 1 / MediaQuery.devicePixelRatioOf(context);

    return DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: style.tableBorderColor, width: hairline),
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
                  children: widget.header.map(cell).toList(growable: false),
                ),
                for (final row in widget.rows)
                  TableRow(children: row.map(cell).toList(growable: false)),
              ],
            );
            return _TableChrome(
              geometry: _geometry,
              headerColor: style.tableHeaderBackground,
              ruleColor: style.tableBorderColor,
              ruleWidth: hairline,
              child: HorizontalOverflowFade(
                // Text fades out inside the cell margin instead of running
                // into the border mid-glyph.
                fadeExtent: MarkdownTableFrame.edgeFadeExtent,
                edgeInset: MarkdownTableFrame.cellPadding.left,
                scrollIndicatorColor: style.scrollIndicatorColor,
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

  /// The last plan and the content extents it was made for: the table asks
  /// once per column, several times per layout.
  List<double>? _plan;
  List<double>? _planMinWidths;
  List<double>? _planMaxWidths;

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
    final plan = _plan;
    if (plan != null &&
        listEquals(minWidths, _planMinWidths) &&
        listEquals(maxWidths, _planMaxWidths)) {
      return plan[column];
    }
    final widths = MarkdownTableFrame.solveColumnWidths(
      minWidths: minWidths,
      maxWidths: maxWidths,
      availableWidth: availableWidth,
      comfortableWidth: comfortableWidth,
      cellHeights: (x, width) => [
        for (final cell in table.column(x)) cell.getMinIntrinsicHeight(width),
      ],
    );
    _plan = widths;
    _planMinWidths = minWidths;
    _planMaxWidths = maxWidths;
    return widths[column];
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
        // A hairline centred on a row edge straddles two device pixels and
        // smears to half its strength; snapped to whole rule widths from the
        // frame's top, it lands on one pixel row wherever the frame's own
        // outline does.
        final top = _ruleWidth > 0
            ? ((y - _ruleWidth / 2) / _ruleWidth).round() * _ruleWidth
            : y;
        canvas.drawRect(
          Rect.fromLTWH(offset.dx, offset.dy + top, size.width, _ruleWidth),
          rulePaint,
        );
      }
    }
    super.paint(context, offset);
  }
}
