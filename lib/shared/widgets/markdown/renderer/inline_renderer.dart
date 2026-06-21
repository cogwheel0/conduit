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
import 'pdf_inline_view.dart';

/// Callback invoked when a user taps a markdown link.
typedef LinkTapCallback = void Function(String url, String title);

@immutable
class InlineTextFadeSpec {
  const InlineTextFadeSpec({required this.startOffset, required this.opacity});

  final int startOffset;
  final double opacity;
}

/// Records the document-coordinate range covered by a single emitted leaf span.
///
/// Captured during the [InlineRenderer.renderWithRanges] walk so the streaming
/// suffix fade can be reapplied later (via [InlineRenderer.applyFadeOpacity])
/// without re-walking the document or recreating gesture recognizers.
@immutable
class FadableSpanRange {
  const FadableSpanRange({
    required this.start,
    required this.end,
    required this.isWidgetSpan,
  });

  /// Inclusive start offset in document-wide `textContent` coordinates.
  final int start;

  /// Exclusive end offset in document-wide `textContent` coordinates.
  final int end;

  /// Whether the emitted leaf is a [WidgetSpan] (faded via [Opacity]) rather
  /// than a [TextSpan] (faded via color alpha).
  final bool isWidgetSpan;
}

/// The result of a fade-agnostic inline render: the opacity-1 base span tree
/// plus the per-leaf document-coordinate ranges recorded during the walk.
///
/// The base tree is built once per content change. [InlineRenderer.applyFadeOpacity]
/// reapplies the streaming suffix alpha to only the in-range leaves of this
/// cached tree, so fade frames never rebuild the span tree or its recognizers.
///
/// [ranges] is keyed by emitted leaf-span identity rather than position so that
/// non-fadable leaves interleaved in the tree (e.g. hard line breaks, table or
/// heading spans built outside the fadable path) are simply absent from the map
/// and reused by reference during a fade.
@immutable
class RenderedInlineSpans {
  const RenderedInlineSpans({required this.span, required this.ranges});

  /// The opacity-1 base span tree (with link recognizers attached).
  final InlineSpan span;

  /// Recorded ranges keyed by the identity of the emitted leaf span.
  final Map<InlineSpan, FadableSpanRange> ranges;
}

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
    this.renderPdfPreviews = true,
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

  /// Whether PDF links should hydrate preview cards instead of plain links.
  final bool renderPdfPreviews;

  /// Per-leaf document-coordinate ranges recorded during the current walk,
  /// keyed by emitted leaf-span identity.
  ///
  /// Populated only while [renderWithRanges] is running so the streaming suffix
  /// fade can be reapplied to the cached base tree without re-walking. Reset at
  /// the start of every render entry point.
  Map<InlineSpan, FadableSpanRange>? _recordedRanges;

  /// Gesture recognizers created during rendering.
  ///
  /// Callers should dispose these when the widget is
  /// removed from the tree.
  final List<GestureRecognizer> _recognizers = [];

  /// All gesture recognizers created by this renderer.
  List<GestureRecognizer> get recognizers => List.unmodifiable(_recognizers);

  int _visibleTextOffset = 0;

  /// Advances the streaming-fade text offset by [length] without emitting any
  /// fadable span.
  ///
  /// The streaming-fade [startOffset] is computed against the document-wide
  /// `textContent` coordinate space. Block paths that emit text without routing
  /// it through [_renderFadableText] (e.g. code-block bodies in the `blocks`
  /// render tier) would otherwise leave [_visibleTextOffset] short of that
  /// coordinate space, mis-sizing the faded tail for any streaming text that
  /// follows. Callers advance the offset by the bypassed text length to keep
  /// it aligned with `document.nodes` textContent.
  void advanceVisibleTextOffset(int length) {
    if (length <= 0) return;
    _visibleTextOffset += length;
  }

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
    // Non-fadable call sites (tables, headings, cells) only need the base tree.
    // Skip range recording entirely; the [_visibleTextOffset] cursor still
    // advances as before so cross-block coordinates stay aligned.
    _recordedRanges = null;
    final base = parentStyle ?? style.body;
    final spans = <InlineSpan>[];
    for (final node in nodes) {
      spans.addAll(_renderNode(node, base));
    }
    if (spans.length == 1) return spans.first;
    return TextSpan(children: spans);
  }

  /// Renders [nodes] into the opacity-1 base span tree while recording, during
  /// the same [_visibleTextOffset] walk, the document-coordinate range of every
  /// emitted leaf span.
  ///
  /// The returned [RenderedInlineSpans] can be cached per content change and
  /// re-faded via [applyFadeOpacity] without re-walking the document or
  /// recreating gesture recognizers.
  RenderedInlineSpans renderWithRanges(
    List<CompiledMarkdownNode> nodes, {
    TextStyle? parentStyle,
  }) {
    final ranges = <InlineSpan, FadableSpanRange>{};
    _recordedRanges = ranges;
    try {
      final base = parentStyle ?? style.body;
      final spans = <InlineSpan>[];
      for (final node in nodes) {
        spans.addAll(_renderNode(node, base));
      }
      final span = spans.length == 1 ? spans.first : TextSpan(children: spans);
      return RenderedInlineSpans(span: span, ranges: ranges);
    } finally {
      _recordedRanges = null;
    }
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
    return _renderFadableText(node.textContent, currentStyle);
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
      // Keep the streaming-fade offset aligned with the document-wide
      // textContent coordinate space, which still contains the placeholder
      // token. The LaTeX WidgetSpan itself does not fade, so advance the
      // offset by the consumed placeholder token length.
      _visibleTextOffset += segment.placeholderLength;
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
          spans.addAll(_renderFadableText(segment.text, currentStyle));
        }
        continue;
      }
      if (segment is CompiledMarkdownCitationSegment) {
        if (!_canRenderCitationBadge(segment.sourceIds)) {
          spans.addAll(_renderFadableText(segment.rawText, currentStyle));
          continue;
        }
        spans.add(
          _buildFadableWidgetSpan(
            child: _buildCitationBadge(segment.sourceIds),
            textLength: segment.rawText.length,
          ),
        );
        continue;
      }
      if (segment is CompiledMarkdownLatexSegment) {
        // Advance the streaming-fade offset by the placeholder token length so
        // it stays aligned with the document-wide textContent coordinate space.
        _visibleTextOffset += segment.placeholderLength;
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
      return _renderFadableText(text, currentStyle);
    }
    return _renderCitations(text, currentStyle) ??
        _renderFadableText(text, currentStyle);
  }

  List<InlineSpan>? _renderCitations(String text, TextStyle currentStyle) {
    final segments = CitationParser.parse(text);
    if (segments == null || segments.isEmpty) {
      return null;
    }

    final spans = <InlineSpan>[];
    for (final segment in segments) {
      if (segment.isText && segment.text != null) {
        spans.addAll(_renderFadableText(segment.text!, currentStyle));
      } else if (segment.isCitation && segment.citation != null) {
        final citation = segment.citation!;
        if (!_canRenderCitationBadge(citation.sourceIds)) {
          spans.addAll(_renderFadableText(citation.raw, currentStyle));
          continue;
        }
        spans.add(
          _buildFadableWidgetSpan(
            child: _buildCitationBadge(citation.sourceIds),
            textLength: citation.raw.length,
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
    return _renderFadableText(
      element.textContent,
      currentStyle.copyWith(
        color: style.linkColor,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  List<InlineSpan> _renderStyled(
    CompiledMarkdownElement element,
    TextStyle styledText,
  ) {
    final children = element.children;
    if (children.isEmpty) {
      return _renderFadableText(element.textContent, styledText);
    }
    final spans = <InlineSpan>[];
    for (final child in children) {
      spans.addAll(_renderNode(child, styledText));
    }
    return spans;
  }

  WidgetSpan _buildInlineCode(String code) {
    return _buildFadableWidgetSpan(
      textLength: code.length,
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

    if (renderPdfPreviews && PdfInlineView.isPdfLink(href)) {
      return [
        _buildFadableWidgetSpan(
          textLength: element.textContent.length,
          child: PdfInlineView(url: href, label: element.textContent),
        ),
      ];
    }

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
      return _withRecognizer(
        _renderFadableText(element.textContent, linkStyle),
        recognizer,
      );
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
      final copy = TextSpan(
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
      // The fadable range was recorded against the pre-copy span identity; move
      // it to the recognizer-bearing copy so the streaming fade still finds it.
      final ranges = _recordedRanges;
      if (ranges != null) {
        final range = ranges.remove(span);
        if (range != null) {
          ranges[copy] = range;
        }
      }
      return copy;
    }
    return span;
  }

  List<InlineSpan> _renderImage(
    CompiledMarkdownElement element,
    TextStyle currentStyle,
  ) {
    final alt = element.attributes['alt'] ?? '';
    if (alt.isEmpty) return [];
    return _renderFadableText(alt, currentStyle);
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

  List<InlineSpan> _renderFadableText(String text, TextStyle currentStyle) {
    if (text.isEmpty) {
      return const <InlineSpan>[];
    }

    // Always emit a single opacity-1 base span. The streaming fade is reapplied
    // later by [applyFadeOpacity] using the recorded range, so the offset walk
    // here stays decoupled from any opacity decision while remaining
    // byte-identical in how it advances [_visibleTextOffset].
    final startOffset = _visibleTextOffset;
    final endOffset = startOffset + text.length;
    _visibleTextOffset = endOffset;
    final span = TextSpan(text: text, style: currentStyle);
    _recordedRanges?[span] = FadableSpanRange(
      start: startOffset,
      end: endOffset,
      isWidgetSpan: false,
    );
    return [span];
  }

  WidgetSpan _buildFadableWidgetSpan({
    required Widget child,
    required int textLength,
    PlaceholderAlignment alignment = PlaceholderAlignment.middle,
  }) {
    final span = WidgetSpan(alignment: alignment, child: child);
    _recordFadableWidgetRange(span, textLength);
    return span;
  }

  void _recordFadableWidgetRange(WidgetSpan span, int textLength) {
    if (textLength <= 0) {
      // Mirror the prior accounting: zero-length widget spans never advanced
      // [_visibleTextOffset] and recorded no fadable range.
      return;
    }
    final startOffset = _visibleTextOffset;
    final endOffset = startOffset + textLength;
    _visibleTextOffset = endOffset;
    _recordedRanges?[span] = FadableSpanRange(
      start: startOffset,
      end: endOffset,
      isWidgetSpan: true,
    );
  }

  /// Reapplies the streaming suffix [fade] to only the in-range leaves of a
  /// cached [base] render, returning a new span tree.
  ///
  /// This is a cheap, pure copy: leaves with no recorded range, or whose range
  /// is entirely before [InlineTextFadeSpec.startOffset], are reused by
  /// reference (recognizers included); leaves at/after the fade boundary have
  /// their color alpha (text) or [Opacity] (widget) reapplied; the single leaf
  /// straddling the boundary is split with the same `substring` logic as the
  /// original walk. No document node walk, recognizer creation, or LaTeX
  /// re-resolution occurs.
  static InlineSpan applyFadeOpacity(
    RenderedInlineSpans base,
    InlineTextFadeSpec? fade, {
    required ConduitMarkdownStyle style,
  }) {
    if (fade == null || fade.opacity >= 1) {
      return base.span;
    }
    return _applyFadeToSpan(base.span, base.ranges, fade, style);
  }

  static InlineSpan _applyFadeToSpan(
    InlineSpan span,
    Map<InlineSpan, FadableSpanRange> ranges,
    InlineTextFadeSpec fade,
    ConduitMarkdownStyle style,
  ) {
    if (span is TextSpan) {
      final children = span.children;
      if (children != null && children.isNotEmpty) {
        // Interior node: copy and recurse into children in order.
        final newChildren = children
            .map((child) => _applyFadeToSpan(child, ranges, fade, style))
            .toList(growable: false);
        return TextSpan(
          text: span.text,
          children: newChildren,
          style: span.style,
          recognizer: span.recognizer,
          mouseCursor: span.mouseCursor,
          onEnter: span.onEnter,
          onExit: span.onExit,
          semanticsLabel: span.semanticsLabel,
          locale: span.locale,
          spellOut: span.spellOut,
        );
      }
      return _fadeTextLeaf(span, ranges[span], fade, style);
    }
    if (span is WidgetSpan) {
      return _fadeWidgetLeaf(span, ranges[span], fade);
    }
    return span;
  }

  static InlineSpan _fadeTextLeaf(
    TextSpan span,
    FadableSpanRange? range,
    InlineTextFadeSpec fade,
    ConduitMarkdownStyle style,
  ) {
    final text = span.text;
    if (range == null || text == null || range.end <= fade.startOffset) {
      return span;
    }

    final fadeStyle = _styleWithFadeOpacityStatic(
      span.style,
      fade.opacity,
      style,
    );
    if (range.start >= fade.startOffset) {
      return TextSpan(
        text: text,
        style: fadeStyle,
        recognizer: span.recognizer,
        mouseCursor: span.mouseCursor,
        onEnter: span.onEnter,
        onExit: span.onExit,
        semanticsLabel: span.semanticsLabel,
        locale: span.locale,
        spellOut: span.spellOut,
      );
    }

    // Straddling leaf: split at the fade boundary using the same offset math as
    // the original walk. [fade.startOffset] is already surrogate-snapped.
    //
    // Mirror the original walk, which emitted two sibling spans and attached the
    // link recognizer to EACH of them: a TextSpan's recognizer only applies to
    // its own `text`, so the recognizer is carried onto both child halves (and
    // their per-span metadata) rather than a text-less parent wrapper.
    final splitIndex = fade.startOffset - range.start;
    return TextSpan(
      children: [
        TextSpan(
          text: text.substring(0, splitIndex),
          style: span.style,
          recognizer: span.recognizer,
          mouseCursor: span.mouseCursor,
          onEnter: span.onEnter,
          onExit: span.onExit,
          semanticsLabel: span.semanticsLabel,
          locale: span.locale,
          spellOut: span.spellOut,
        ),
        TextSpan(
          text: text.substring(splitIndex),
          style: fadeStyle,
          recognizer: span.recognizer,
          mouseCursor: span.mouseCursor,
          onEnter: span.onEnter,
          onExit: span.onExit,
          semanticsLabel: span.semanticsLabel,
          locale: span.locale,
          spellOut: span.spellOut,
        ),
      ],
    );
  }

  static InlineSpan _fadeWidgetLeaf(
    WidgetSpan span,
    FadableSpanRange? range,
    InlineTextFadeSpec fade,
  ) {
    // A widget span can't be split, so only fade it when it lies ENTIRELY in
    // the new suffix. A widget that straddles the boundary (already partly
    // visible) must stay opaque, or extending an adjacent span would flicker
    // already-shown content (e.g. inline code `abc` -> `abcd`, citations/PDFs).
    if (range == null || range.start < fade.startOffset) {
      return span;
    }
    final opacity = fade.opacity.clamp(0.0, 1.0).toDouble();
    return WidgetSpan(
      alignment: span.alignment,
      baseline: span.baseline,
      style: span.style,
      child: Opacity(opacity: opacity, child: span.child),
    );
  }

  static TextStyle _styleWithFadeOpacityStatic(
    TextStyle? currentStyle,
    double opacity,
    ConduitMarkdownStyle style,
  ) {
    final base = currentStyle ?? style.body;
    final baseColor = base.color ?? style.body.color;
    if (baseColor == null) {
      return base;
    }
    final clampedOpacity = opacity.clamp(0.0, 1.0).toDouble();
    return base.copyWith(
      color: baseColor.withValues(alpha: baseColor.a * clampedOpacity),
    );
  }
}

/// Read-only source of the current streaming suffix fade.
///
/// Exposes a [Listenable] (the fade animation) and the current
/// [InlineTextFadeSpec] so [FadableRichText] widgets can repaint their own
/// suffix opacity without forcing the whole markdown subtree to rebuild.
abstract class MarkdownStreamingFade {
  /// Drives per-frame repaints while the suffix fades.
  Listenable get listenable;

  /// The current fade spec, or `null` when nothing is fading.
  InlineTextFadeSpec? get spec;
}

/// Renders a cached [RenderedInlineSpans] base tree, reapplying the streaming
/// suffix fade per frame via [InlineRenderer.applyFadeOpacity] without
/// rebuilding the span tree or its recognizers.
///
/// When [fade] is `null` the base tree is rendered directly with no listener.
class FadableRichText extends StatelessWidget {
  const FadableRichText({
    required this.rendered,
    required this.style,
    this.fade,
    super.key,
  });

  /// The cached opacity-1 base span tree plus recorded leaf ranges.
  final RenderedInlineSpans rendered;

  /// Style used to resolve fade base colors.
  final ConduitMarkdownStyle style;

  /// Optional streaming fade source. When `null`, no fade is applied.
  final MarkdownStreamingFade? fade;

  @override
  Widget build(BuildContext context) {
    final fadeSource = fade;
    if (fadeSource == null) {
      return Text.rich(rendered.span);
    }
    return AnimatedBuilder(
      animation: fadeSource.listenable,
      builder: (context, _) {
        final span = InlineRenderer.applyFadeOpacity(
          rendered,
          fadeSource.spec,
          style: style,
        );
        return Text.rich(span);
      },
    );
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
