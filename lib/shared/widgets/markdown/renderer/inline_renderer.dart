import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/models/chat_message.dart';
import '../../../../core/utils/citation_parser.dart';
import '../compiled_markdown_document.dart';
import '../citation_badge.dart';
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
    this.sources,
    this.onSourceTap,
    this.latexStartupFuture,
  ]);

  /// The style configuration for rendering.
  final ConduitMarkdownStyle style;

  /// Preprocessor for restoring LaTeX placeholders.
  final LatexPreprocessor latexPreprocessor;

  /// Optional callback for link taps.
  final LinkTapCallback? onLinkTap;

  /// Optional source references for citation badges.
  final List<ChatSourceReference>? sources;

  /// Callback when a citation badge is tapped.
  final void Function(int sourceIndex)? onSourceTap;

  /// Shared LaTeX startup future for the current visible document.
  final Future<void>? latexStartupFuture;

  /// Gesture recognizers created during rendering.
  ///
  /// Callers should dispose these when the widget is
  /// removed from the tree.
  final List<GestureRecognizer> _recognizers = [];

  /// All gesture recognizers created by this renderer.
  List<GestureRecognizer> get recognizers => List.unmodifiable(_recognizers);

  /// Disposes all gesture recognizers created during
  /// rendering and clears the internal list.
  void disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  /// Renders a list of inline [nodes] into an
  /// [InlineSpan].
  ///
  /// If [parentStyle] is provided it is used as the base
  /// style; otherwise [style.body] is used.
  InlineSpan render(
    List<CompiledMarkdownNode> nodes, {
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
    CompiledMarkdownNode node,
    TextStyle currentStyle,
  ) {
    if (node is CompiledMarkdownText) {
      return _renderText(node, currentStyle);
    }
    if (node is CompiledMarkdownElement) {
      return _renderElement(node, currentStyle);
    }
    return [TextSpan(text: node.textContent)];
  }

  List<InlineSpan> _renderText(
    CompiledMarkdownText node,
    TextStyle currentStyle,
  ) {
    if (node.hasInlineSegments) {
      return _renderInlineSegments(node.inlineSegments, currentStyle);
    }
    if (!node.containsLatexPlaceholders) {
      return _renderTextWithCitations(
        node.text,
        currentStyle,
        containsCitations: node.containsCitations,
      );
    }

    final segments = latexPreprocessor.splitOnPlaceholders(node.text);
    final spans = <InlineSpan>[];

    for (final segment in segments) {
      if (!segment.isLatex) {
        if (segment.content.isNotEmpty) {
          spans.addAll(
            _renderTextWithCitations(
              segment.content,
              currentStyle,
              containsCitations: node.containsCitations,
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
            startupFuture: latexStartupFuture,
          ),
        ),
      );
    }
    return spans;
  }

  List<InlineSpan> _renderInlineSegments(
    List<CompiledMarkdownInlineSegment> segments,
    TextStyle currentStyle,
  ) {
    final spans = <InlineSpan>[];
    for (final segment in segments) {
      if (segment is CompiledMarkdownTextSegment) {
        if (segment.text.isNotEmpty) {
          spans.add(TextSpan(text: segment.text, style: currentStyle));
        }
        continue;
      }
      if (segment is CompiledMarkdownCitationSegment) {
        if (!_canRenderCitationBadge(segment.sourceIds)) {
          spans.add(TextSpan(text: segment.rawText, style: currentStyle));
          continue;
        }
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: _buildCitationBadge(segment.sourceIds),
          ),
        );
        continue;
      }
      if (segment is CompiledMarkdownLatexSegment) {
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: LatexPreprocessor.buildLatexWidget(
              segment.tex,
              textStyle: currentStyle,
              isBlock: segment.isBlock,
              startupFuture: latexStartupFuture,
            ),
          ),
        );
      }
    }
    return spans;
  }

  List<InlineSpan> _renderTextWithCitations(
    String text,
    TextStyle currentStyle, {
    required bool containsCitations,
  }) {
    if (sources == null || sources!.isEmpty || !containsCitations) {
      return [TextSpan(text: text, style: currentStyle)];
    }
    return _renderCitations(text, currentStyle) ??
        [TextSpan(text: text, style: currentStyle)];
  }

  List<InlineSpan>? _renderCitations(String text, TextStyle currentStyle) {
    final segments = CitationParser.parse(text);
    if (segments == null || segments.isEmpty) {
      return null;
    }

    final spans = <InlineSpan>[];
    for (final segment in segments) {
      if (segment.isText && segment.text != null) {
        spans.add(TextSpan(text: segment.text, style: currentStyle));
      } else if (segment.isCitation && segment.citation != null) {
        final citation = segment.citation!;
        if (!_canRenderCitationBadge(citation.sourceIds)) {
          spans.add(TextSpan(text: citation.raw, style: currentStyle));
          continue;
        }
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: _buildCitationBadge(citation.sourceIds),
          ),
        );
      }
    }

    return spans;
  }

  Widget _buildCitationBadge(List<int> sourceIds) {
    final sourceList = sources;
    if (sourceList == null || sourceIds.isEmpty) {
      return const SizedBox.shrink();
    }

    final indices = sourceIds
        .map((id) => id - 1)
        .where((index) => index >= 0 && index < sourceList.length)
        .toList(growable: false);
    if (indices.isEmpty) return const SizedBox.shrink();

    if (indices.length == 1) {
      final index = indices.first;
      return CitationBadge(
        sourceIndex: index,
        sources: sourceList,
        onTap: onSourceTap != null ? () => onSourceTap!(index) : null,
      );
    }

    return CitationBadgeGroup(
      sourceIndices: indices,
      sources: sourceList,
      onSourceTap: onSourceTap,
    );
  }

  bool _canRenderCitationBadge(List<int> sourceIds) {
    final sourceList = sources;
    if (sourceList == null || sourceList.isEmpty || sourceIds.isEmpty) {
      return false;
    }
    return sourceIds.every((id) => id > 0 && id <= sourceList.length);
  }

  List<InlineSpan> _renderElement(
    CompiledMarkdownElement element,
    TextStyle currentStyle,
  ) {
    return switch (element.tag) {
      'strong' => _renderStyled(
        element,
        currentStyle.copyWith(fontWeight: FontWeight.bold),
      ),
      'em' => _renderStyled(
        element,
        currentStyle.copyWith(fontStyle: FontStyle.italic),
      ),
      'del' => _renderStyled(
        element,
        currentStyle.copyWith(decoration: TextDecoration.lineThrough),
      ),
      'code' => [_buildInlineCode(element.textContent)],
      'a' => _renderLink(element, currentStyle),
      'img' => _renderImage(element, currentStyle),
      'mention' => _renderMention(element, currentStyle),
      'br' => [const TextSpan(text: '\n')],
      _ => _renderChildren(element, currentStyle),
    };
  }

  List<InlineSpan> _renderMention(
    CompiledMarkdownElement element,
    TextStyle currentStyle,
  ) {
    return [
      TextSpan(
        text: element.textContent,
        style: currentStyle.copyWith(
          color: style.linkColor,
          fontWeight: FontWeight.w600,
        ),
      ),
    ];
  }

  List<InlineSpan> _renderStyled(
    CompiledMarkdownElement element,
    TextStyle styledText,
  ) {
    final children = element.children;
    if (children.isEmpty) {
      return [TextSpan(text: element.textContent, style: styledText)];
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
      child: _InlineCodeWidget(code: code, style: style),
    );
  }

  List<InlineSpan> _renderLink(
    CompiledMarkdownElement element,
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
    if (children.isEmpty) {
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
      spans.addAll(_withRecognizer(_renderNode(child, linkStyle), recognizer));
    }
    return spans;
  }

  List<InlineSpan> _withRecognizer(
    List<InlineSpan> spans,
    GestureRecognizer? recognizer,
  ) {
    if (recognizer == null) return spans;

    return spans
        .map((span) => _attachRecognizer(span, recognizer))
        .toList(growable: false);
  }

  InlineSpan _attachRecognizer(InlineSpan span, GestureRecognizer recognizer) {
    if (span is TextSpan) {
      return TextSpan(
        text: span.text,
        children: span.children
            ?.map((child) => _attachRecognizer(child, recognizer))
            .toList(growable: false),
        style: span.style,
        recognizer: span.recognizer ?? recognizer,
        mouseCursor: span.mouseCursor,
        onEnter: span.onEnter,
        onExit: span.onExit,
        semanticsLabel: span.semanticsLabel,
        locale: span.locale,
        spellOut: span.spellOut,
      );
    }
    return span;
  }

  List<InlineSpan> _renderImage(
    CompiledMarkdownElement element,
    TextStyle currentStyle,
  ) {
    final alt = element.attributes['alt'] ?? '';
    if (alt.isEmpty) return [];
    return [TextSpan(text: alt, style: currentStyle)];
  }

  List<InlineSpan> _renderChildren(
    CompiledMarkdownElement element,
    TextStyle currentStyle,
  ) {
    final children = element.children;
    if (children.isEmpty) {
      final text = element.textContent;
      if (text.isNotEmpty) {
        return _renderText(
          CompiledMarkdownText(
            text,
            containsLatexPlaceholders: latexPreprocessor.containsPlaceholder(
              text,
            ),
            containsCitations: CitationParser.hasCitations(text),
          ),
          currentStyle,
        );
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
  const _InlineCodeWidget({required this.code, required this.style});

  final String code;
  final ConduitMarkdownStyle style;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _copyToClipboard(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: style.codeSpanBackgroundColor,
          borderRadius: BorderRadius.circular(style.codeSpanRadius),
        ),
        child: Text(
          code,
          style: style.codeSpan.copyWith(color: style.codeSpanTextColor),
        ),
      ),
    );
  }

  void _copyToClipboard(BuildContext context) {
    Clipboard.setData(ClipboardData(text: code));
    if (!context.mounted) return;
    AdaptiveSnackBar.show(
      context,
      message: AppLocalizations.of(context)!.copiedToClipboard,
      type: AdaptiveSnackBarType.success,
      duration: const Duration(seconds: 2),
    );
  }
}
