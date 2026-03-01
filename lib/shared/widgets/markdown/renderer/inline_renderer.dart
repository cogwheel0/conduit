import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:markdown/markdown.dart' as md;

import 'latex_preprocessor.dart';
import 'markdown_style.dart';

/// Callback invoked when a user taps a markdown link.
typedef LinkTapCallback = void Function(String url, String title);

/// Converts markdown AST inline nodes into a Flutter
/// [InlineSpan] tree suitable for use with [Text.rich].
///
/// Handles bold, italic, strikethrough, inline code,
/// links, images (as alt-text fallback), line breaks,
/// and LaTeX placeholder restoration.
class InlineRenderer {
  /// Creates an inline renderer.
  ///
  /// [style] provides all text styles and colors.
  /// [latexPreprocessor] handles LaTeX placeholder
  /// restoration. [onLinkTap] is called when the user
  /// taps a hyperlink.
  InlineRenderer(
    this.style,
    this.latexPreprocessor, [
    this.onLinkTap,
  ]);

  /// The style configuration for rendering.
  final ConduitMarkdownStyle style;

  /// Preprocessor for restoring LaTeX placeholders.
  final LatexPreprocessor latexPreprocessor;

  /// Optional callback for link taps.
  final LinkTapCallback? onLinkTap;

  /// Gesture recognizers created during rendering.
  ///
  /// Callers should dispose these when the widget is
  /// removed from the tree.
  final List<GestureRecognizer> _recognizers = [];

  /// All gesture recognizers created by this renderer.
  List<GestureRecognizer> get recognizers =>
      List.unmodifiable(_recognizers);

  /// Renders a list of inline [nodes] into an
  /// [InlineSpan].
  ///
  /// If [parentStyle] is provided it is used as the base
  /// style; otherwise [style.body] is used.
  InlineSpan render(
    List<md.Node> nodes, {
    TextStyle? parentStyle,
  }) {
    final base = parentStyle ?? style.body;
    final spans = <InlineSpan>[];
    for (final node in nodes) {
      spans.addAll(_renderNode(node, base));
    }
    if (spans.length == 1) return spans.first;
    return TextSpan(children: spans);
  }

  List<InlineSpan> _renderNode(
    md.Node node,
    TextStyle currentStyle,
  ) {
    if (node is md.Text) {
      return _renderText(node.text, currentStyle);
    }
    if (node is md.Element) {
      return _renderElement(node, currentStyle);
    }
    return [TextSpan(text: node.textContent)];
  }

  List<InlineSpan> _renderText(
    String text,
    TextStyle currentStyle,
  ) {
    if (!latexPreprocessor.containsPlaceholder(text)) {
      return [TextSpan(text: text, style: currentStyle)];
    }

    final segments =
        latexPreprocessor.splitOnPlaceholders(text);
    final spans = <InlineSpan>[];

    for (final segment in segments) {
      if (!segment.isLatex) {
        if (segment.content.isNotEmpty) {
          spans.add(
            TextSpan(
              text: segment.content,
              style: currentStyle,
            ),
          );
        }
        continue;
      }
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: LatexPreprocessor.buildLatexWidget(
            segment.content,
            textStyle: currentStyle,
            isBlock: segment.isBlock,
          ),
        ),
      );
    }
    return spans;
  }

  List<InlineSpan> _renderElement(
    md.Element element,
    TextStyle currentStyle,
  ) {
    return switch (element.tag) {
      'strong' => _renderStyled(
          element,
          currentStyle.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
      'em' => _renderStyled(
          element,
          currentStyle.copyWith(
            fontStyle: FontStyle.italic,
          ),
        ),
      'del' => _renderStyled(
          element,
          currentStyle.copyWith(
            decoration: TextDecoration.lineThrough,
          ),
        ),
      'code' => [_buildInlineCode(element.textContent)],
      'a' => _renderLink(element, currentStyle),
      'img' => _renderImage(element, currentStyle),
      'br' => [const TextSpan(text: '\n')],
      _ => _renderChildren(element, currentStyle),
    };
  }

  List<InlineSpan> _renderStyled(
    md.Element element,
    TextStyle styledText,
  ) {
    final children = element.children;
    if (children == null || children.isEmpty) {
      return [
        TextSpan(
          text: element.textContent,
          style: styledText,
        ),
      ];
    }
    final spans = <InlineSpan>[];
    for (final child in children) {
      spans.addAll(_renderNode(child, styledText));
    }
    return spans;
  }

  WidgetSpan _buildInlineCode(String code) {
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: _InlineCodeWidget(
        code: code,
        style: style,
      ),
    );
  }

  List<InlineSpan> _renderLink(
    md.Element element,
    TextStyle currentStyle,
  ) {
    final href = element.attributes['href'] ?? '';
    final title = element.attributes['title'] ?? '';
    final linkStyle = currentStyle.copyWith(
      color: style.linkColor,
      decoration: TextDecoration.underline,
      decorationColor: style.linkColor,
    );

    TapGestureRecognizer? recognizer;
    if (onLinkTap != null) {
      recognizer = TapGestureRecognizer()
        ..onTap = () => onLinkTap!(href, title);
      _recognizers.add(recognizer);
    }

    final children = element.children;
    if (children == null || children.isEmpty) {
      return [
        TextSpan(
          text: element.textContent,
          style: linkStyle,
          recognizer: recognizer,
        ),
      ];
    }

    final spans = <InlineSpan>[];
    for (final child in children) {
      if (child is md.Text) {
        spans.add(
          TextSpan(
            text: child.text,
            style: linkStyle,
            recognizer: recognizer,
          ),
        );
      } else {
        spans.addAll(_renderNode(child, linkStyle));
      }
    }
    return spans;
  }

  List<InlineSpan> _renderImage(
    md.Element element,
    TextStyle currentStyle,
  ) {
    final alt = element.attributes['alt'] ?? '';
    if (alt.isEmpty) return [];
    return [TextSpan(text: alt, style: currentStyle)];
  }

  List<InlineSpan> _renderChildren(
    md.Element element,
    TextStyle currentStyle,
  ) {
    final children = element.children;
    if (children == null || children.isEmpty) {
      final text = element.textContent;
      if (text.isNotEmpty) {
        return _renderText(text, currentStyle);
      }
      return [];
    }
    final spans = <InlineSpan>[];
    for (final child in children) {
      spans.addAll(_renderNode(child, currentStyle));
    }
    return spans;
  }
}

/// Inline code chip with tap-to-copy behavior.
///
/// Displays code in a monospace font with a colored
/// background, styled to match common chat-UI conventions
/// (e.g., OpenWebUI's red-on-gray inline code).
class _InlineCodeWidget extends StatelessWidget {
  const _InlineCodeWidget({
    required this.code,
    required this.style,
  });

  final String code;
  final ConduitMarkdownStyle style;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _copyToClipboard(context),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: 5,
          vertical: 1,
        ),
        decoration: BoxDecoration(
          color: style.codeSpanBackgroundColor,
          borderRadius: BorderRadius.circular(
            style.codeSpanRadius,
          ),
        ),
        child: Text(
          code,
          style: style.codeSpan.copyWith(
            color: style.codeSpanTextColor,
          ),
        ),
      ),
    );
  }

  void _copyToClipboard(BuildContext context) {
    Clipboard.setData(ClipboardData(text: code));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Copied to clipboard'),
        duration: Duration(seconds: 2),
      ),
    );
  }
}
