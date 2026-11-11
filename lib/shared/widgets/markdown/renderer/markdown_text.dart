import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:conduit_markdown/conduit_markdown.dart'
    show removeWordJoiners, wordJoiner;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../platform_ui/platform_ui.dart';

/// Keeps Flutter's text selection while including line spacing in iOS
/// highlights, and copies text without the joiners added for display.
class MarkdownText extends StatelessWidget {
  const MarkdownText(this.span, {super.key});

  final InlineSpan span;

  @override
  Widget build(BuildContext context) {
    if (SelectionContainer.maybeOf(context) == null) {
      return Text.rich(span);
    }
    if (!PlatformInfo.isIOS) {
      // Copy the text as written, without the joiners added for display.
      return _containsWordJoiner(span)
          ? _JoinerFreeSelectionText(span)
          : Text.rich(span);
    }
    return _SelectionText(span);
  }

  static bool _containsWordJoiner(InlineSpan span) {
    var found = false;
    span.visitChildren((child) {
      if (child is TextSpan && (child.text?.contains(wordJoiner) ?? false)) {
        found = true;
      }
      return !found;
    });
    return found;
  }
}

/// Selection that copies text without the invisible word joiners that keep
/// ranges like "4–6" on one line on screen.
class _JoinerFreeSelectionDelegate extends StaticSelectionContainerDelegate {
  @override
  SelectedContent? getSelectedContent() {
    final content = super.getSelectedContent();
    if (content == null || !content.plainText.contains(wordJoiner)) {
      return content;
    }
    return SelectedContent(plainText: removeWordJoiners(content.plainText));
  }
}

class _JoinerFreeSelectionText extends StatefulWidget {
  const _JoinerFreeSelectionText(this.span);

  final InlineSpan span;

  @override
  State<_JoinerFreeSelectionText> createState() =>
      _JoinerFreeSelectionTextState();
}

class _JoinerFreeSelectionTextState extends State<_JoinerFreeSelectionText> {
  final _selection = _JoinerFreeSelectionDelegate();

  @override
  Widget build(BuildContext context) =>
      SelectionContainer(delegate: _selection, child: Text.rich(widget.span));

  @override
  void dispose() {
    _selection.dispose();
    super.dispose();
  }
}

class _SelectionText extends StatefulWidget {
  const _SelectionText(this.span);

  final InlineSpan span;

  @override
  State<_SelectionText> createState() => _SelectionTextState();
}

class _SelectionTextState extends State<_SelectionText> {
  final _selection = _JoinerFreeSelectionDelegate();

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
