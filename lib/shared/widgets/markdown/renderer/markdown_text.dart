import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../platform_ui/platform_ui.dart';

/// Keeps Flutter's text selection while including line spacing in iOS highlights.
class MarkdownText extends StatelessWidget {
  const MarkdownText(this.span, {super.key});

  final InlineSpan span;

  @override
  Widget build(BuildContext context) {
    if (!PlatformInfo.isIOS || SelectionContainer.maybeOf(context) == null) {
      return Text.rich(span);
    }
    return _SelectionText(span);
  }
}

class _SelectionText extends StatefulWidget {
  const _SelectionText(this.span);

  final InlineSpan span;

  @override
  State<_SelectionText> createState() => _SelectionTextState();
}

class _SelectionTextState extends State<_SelectionText> {
  final _selection = StaticSelectionContainerDelegate();

  @override
  Widget build(BuildContext context) => _SelectionBackground(
    selection: _selection,
    color:
        DefaultSelectionStyle.of(context).selectionColor ??
        DefaultSelectionStyle.defaultColor,
    child: SelectionContainer(
      delegate: _selection,
      // Only replace this paragraph's highlight. WidgetSpan children still
      // inherit their usual selection color and retain their own painting.
      child: Text.rich(widget.span, selectionColor: const Color(0x00000000)),
    ),
  );

  @override
  void dispose() {
    _selection.dispose();
    super.dispose();
  }
}

class _SelectionBackground extends SingleChildRenderObjectWidget {
  const _SelectionBackground({
    required this.selection,
    required this.color,
    required super.child,
  });

  final StaticSelectionContainerDelegate selection;
  final Color color;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSelectionBackground(selection, color);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSelectionBackground renderObject,
  ) {
    renderObject
      ..selection = selection
      ..color = color;
  }
}

class _RenderSelectionBackground extends RenderProxyBox {
  _RenderSelectionBackground(this._selection, Color color)
    : _color = color,
      _paint = (Paint()..color = color);

  StaticSelectionContainerDelegate _selection;
  Color _color;
  final Paint _paint;

  set selection(StaticSelectionContainerDelegate value) {
    if (identical(value, _selection)) return;
    if (attached) _selection.removeListener(markNeedsPaint);
    _selection = value;
    if (attached) _selection.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  set color(Color value) {
    if (_color == value) return;
    _color = value;
    _paint.color = value;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _selection.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _selection.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final geometry = _selection.value;
    final start = geometry.startSelectionPoint;
    final end = geometry.endSelectionPoint;
    final paragraph =
        geometry.status == SelectionStatus.uncollapsed && child != null
        ? _findParagraph(child!)
        : null;
    if (geometry.status == SelectionStatus.uncollapsed &&
        start != null &&
        end != null &&
        paragraph != null) {
      final paragraphToParent = paragraph.getTransformTo(this);
      final selectionToParagraph = paragraphToParent.clone()..invert();
      selectionToParagraph.multiply(_selection.getTransformTo(this));
      // Selection points are at the bottom of their carets. Hit-test their
      // vertical centers so a boundary does not resolve to the following line.
      int position(SelectionPoint point) => paragraph
          .getPositionForOffset(
            MatrixUtils.transformPoint(
              selectionToParagraph,
              point.localPosition - Offset(0, point.lineHeight / 2),
            ),
          )
          .offset;
      final a = position(start);
      final b = position(end);
      final low = math.min(a, b);
      final high = math.max(a, b);

      void paintText(int from, int to) {
        final first = math.max(from, low);
        final last = math.min(to, high);
        if (first >= last) return;
        for (final box in paragraph.getBoxesForSelection(
          TextSelection(baseOffset: first, extentOffset: last),
          boxHeightStyle: ui.BoxHeightStyle.includeLineSpacingMiddle,
        )) {
          context.canvas.drawRect(
            MatrixUtils.transformRect(
              paragraphToParent,
              box.toRect(),
            ).shift(offset),
            _paint,
          );
        }
      }

      var cursor = 0;
      var runStart = 0;
      void visit(InlineSpan span) {
        if (span is TextSpan) {
          cursor += span.text?.length ?? 0;
          span.children?.forEach(visit);
        } else if (span is PlaceholderSpan) {
          paintText(runStart, cursor);
          runStart = ++cursor;
        }
      }

      visit(paragraph.text);
      paintText(runStart, cursor);
    }
    super.paint(context, offset);
  }

  static RenderParagraph? _findParagraph(RenderObject object) {
    if (object is RenderParagraph) return object;
    RenderParagraph? result;
    object.visitChildren((child) => result ??= _findParagraph(child));
    return result;
  }
}
