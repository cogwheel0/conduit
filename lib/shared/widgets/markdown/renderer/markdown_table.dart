import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:conduit/l10n/app_localizations.dart';

import 'markdown_style.dart';

/// Wrapping rows keep chat tables readable at phone widths and large text sizes.
/// Column sizes belong to this table's state, so streaming updates preserve them.
class MarkdownTableView extends StatefulWidget {
  const MarkdownTableView({
    super.key,
    required this.columns,
    required this.rows,
    required this.style,
  });
  final List<DataColumn> columns;
  final List<DataRow> rows;
  final ConduitMarkdownStyle style;

  @override
  State<MarkdownTableView> createState() => _MarkdownTableViewState();
}

class _MarkdownTableViewState extends State<MarkdownTableView> {
  List<double> _widths = [];
  double _viewportWidth = 0;
  bool _resized = false;

  void _resize(int column, double delta) => setState(() {
    _widths[column] = (_widths[column] + delta).clamp(112, 640);
    _resized = true;
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final count = widget.columns.length;
      if (count == 0) return const SizedBox.shrink();
      final available = constraints.hasBoundedWidth
          ? constraints.maxWidth
          : 320.0;
      if (_widths.length != count ||
          (!_resized && _viewportWidth != available)) {
        _widths = List.filled(count, math.max(112, available / count));
        _viewportWidth = available;
      }
      final totalWidth = _widths.fold<double>(0, (sum, width) => sum + width);
      Widget cell(Widget child, {bool header = false}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: DefaultTextStyle.merge(
          style: header ? widget.style.tableHeader : widget.style.tableCell,
          child: child,
        ),
      );
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(widget.style.tableRadius),
          child: SizedBox(
            width: totalWidth,
            child: Table(
              columnWidths: {
                for (var index = 0; index < count; index++)
                  index: FixedColumnWidth(_widths[index]),
              },
              defaultVerticalAlignment: TableCellVerticalAlignment.top,
              border: TableBorder(
                top: BorderSide(color: widget.style.tableBorderColor),
                bottom: BorderSide(color: widget.style.tableBorderColor),
                left: BorderSide(color: widget.style.tableBorderColor),
                right: BorderSide(color: widget.style.tableBorderColor),
                horizontalInside: BorderSide(
                  color: widget.style.tableBorderColor,
                ),
                borderRadius: BorderRadius.circular(widget.style.tableRadius),
              ),
              children: [
                TableRow(
                  decoration: BoxDecoration(
                    color: widget.style.tableHeaderBackground,
                  ),
                  children: [
                    for (var index = 0; index < count; index++)
                      cell(
                        Row(
                          children: [
                            Expanded(
                              child: Semantics(
                                header: true,
                                child: widget.columns[index].label,
                              ),
                            ),
                            if (index < count - 1)
                              Semantics(
                                label: AppLocalizations.of(context)!
                                    .markdownResizeColumn(index + 1),
                                value: '${_widths[index].round()}',
                                increasedValue:
                                    '${(_widths[index] + 16).round()}',
                                decreasedValue:
                                    '${(_widths[index] - 16).round()}',
                                onIncrease: () => _resize(index, 16),
                                onDecrease: () => _resize(index, -16),
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onHorizontalDragUpdate: (details) =>
                                      _resize(index, details.delta.dx),
                                  onDoubleTap: () => setState(() {
                                    _resized = false;
                                    _viewportWidth = 0;
                                  }),
                                  child: SizedBox(
                                    width: 48,
                                    height: 48,
                                    child: Icon(
                                      Icons.drag_indicator,
                                      size: 16,
                                      color: widget.style.textSecondary,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        header: true,
                      ),
                  ],
                ),
                for (final row in widget.rows)
                  TableRow(
                    children: [for (final data in row.cells) cell(data.child)],
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
