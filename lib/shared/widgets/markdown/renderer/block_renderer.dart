import 'package:conduit/l10n/app_localizations.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../../conduit_loading.dart';
import '../../../theme/theme_extensions.dart';
import '../compiled_markdown_document.dart';
import '../markdown_compile_service.dart';
import '../markdown_config.dart';
import '../streaming_markdown_widget.dart';
import 'conduit_markdown_widget.dart';
import 'details_block_widget.dart';
import 'details_group_widget.dart';
import 'inline_renderer.dart';
import 'latex_preprocessor.dart';
import 'markdown_style.dart';
import 'markdown_table_frame.dart';
import 'markdown_text.dart';
import 'pdf_inline_view.dart';

export 'markdown_table_frame.dart' show MarkdownTableFrame;

/// Signature for a builder that creates image widgets.
typedef ImageBuilder = Widget Function(String src, String? alt, String? title);

enum MarkdownHeavyBlockPolicy {
  /// Hydrate heavy previews immediately.
  eager,

  /// Avoid hydrating heavy previews and render lightweight code fallback only.
  defer,
}

final RegExp _leadingSoftBreakPattern = RegExp(r'^[ \t]*\n[ \t]*');
final RegExp _trailingSoftBreakPattern = RegExp(r'[ \t]*\n[ \t]*$');

/// Renders markdown AST block-level nodes as Flutter
/// widgets.
///
/// Each block element (paragraph, heading, code block,
/// list, table, etc.) is mapped to a corresponding Flutter
/// widget tree. Inline content within blocks is delegated
/// to [InlineRenderer].
class BlockRenderer {
  /// Creates a block renderer.
  ///
  /// [context] is the current [BuildContext] used to
  /// resolve theme data. [style] provides all styling
  /// tokens. [inlineRenderer] handles inline node
  /// rendering. [latexPreprocessor] restores LaTeX
  /// placeholders. [onLinkTap] is forwarded to inline
  /// links. [imageBuilder] builds block-level images.
  BlockRenderer(
    this.context,
    this.style,
    this.inlineRenderer,
    this.latexPreprocessor, [
    this.onLinkTap,
    this.imageBuilder,
    this.stateScopeId,
    this.nodePathPrefix,
    this.heavyBlockPolicy = MarkdownHeavyBlockPolicy.eager,
    this.streamingFade,
    this.listDepth = 0,
  ]);

  /// The active build context.
  final BuildContext context;

  /// Style configuration for all markdown elements.
  final ConduitMarkdownStyle style;

  /// Renderer for inline-level nodes.
  final InlineRenderer inlineRenderer;

  /// Preprocessor for LaTeX placeholder restoration.
  final LatexPreprocessor latexPreprocessor;

  /// Optional callback for link taps.
  final LinkTapCallback? onLinkTap;

  /// Optional builder for block-level images.
  final ImageBuilder? imageBuilder;

  /// Optional scope used to preserve state for remounted markdown blocks.
  final String? stateScopeId;

  /// Optional AST path prefix used to keep sibling block identities unique.
  final String? nodePathPrefix;

  /// Controls how expensive block previews should behave.
  final MarkdownHeavyBlockPolicy heavyBlockPolicy;

  /// Optional streaming suffix fade source. When non-null, paragraph/text/flow
  /// inline runs that can fall in the streaming tail are rendered via
  /// [FadableRichText] so the trailing block fades per frame without rebuilding
  /// the span tree or its recognizers.
  final MarkdownStreamingFade? streamingFade;

  /// How many lists enclose the blocks this renderer draws. Nested lists use
  /// it to pick their bullet glyph.
  final int listDepth;

  /// A renderer for blocks nested inside this one (quotes, list items,
  /// alerts, sections), sharing every setting except the node path and list
  /// depth.
  BlockRenderer _nested(String nodePath, {int? listDepth}) => BlockRenderer(
    context,
    style,
    inlineRenderer,
    latexPreprocessor,
    onLinkTap,
    imageBuilder,
    stateScopeId,
    nodePath,
    heavyBlockPolicy,
    streamingFade,
    listDepth ?? this.listDepth,
  );

  /// Builds a rich-text widget for an inline [nodes] run.
  ///
  /// When a [streamingFade] source is present the run is rendered through
  /// [FadableRichText] (recording per-leaf ranges so the suffix can re-fade per
  /// frame); otherwise it falls back to a plain [Text.rich] of the base tree.
  Widget _buildInlineRichText(
    List<CompiledMarkdownNode> nodes, {
    TextStyle? parentStyle,
  }) {
    final fade = streamingFade;
    if (fade == null) {
      return MarkdownText(
        inlineRenderer.render(nodes, parentStyle: parentStyle),
      );
    }
    final rendered = inlineRenderer.renderWithRanges(
      nodes,
      parentStyle: parentStyle,
    );
    return FadableRichText(rendered: rendered, style: style, fade: fade);
  }

  /// Renders a list of block [nodes] as a [Column].
  Widget renderBlocks(List<CompiledMarkdownNode> nodes) =>
      renderCompiledBlocks(_compiledBlocksFromNodes(nodes));

  /// Renders a list of precompiled root blocks as a [Column].
  Widget renderCompiledBlocks(
    List<CompiledMarkdownBlock> blocks, {
    bool trimLastBlockBottomPadding = true,
    bool trimFirstBlockTopPadding = true,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: renderCompiledBlockWidgets(
        blocks,
        trimLastBlockBottomPadding: trimLastBlockBottomPadding,
        trimFirstBlockTopPadding: trimFirstBlockTopPadding,
      ),
    );
  }

  /// The keyed per-block widgets behind [renderCompiledBlocks], for callers
  /// that own the enclosing column (e.g. chunked inflation of very large
  /// documents).
  List<Widget> renderCompiledBlockWidgets(
    List<CompiledMarkdownBlock> blocks, {
    bool trimLastBlockBottomPadding = true,
    bool trimFirstBlockTopPadding = true,
  }) {
    final renderedBlocks = <(String blockId, Widget widget)>[];
    for (final block in blocks) {
      final widget = _renderCompiledBlock(block);
      if (widget != null) {
        renderedBlocks.add((block.blockId, widget));
      }
    }
    if (trimFirstBlockTopPadding && renderedBlocks.isNotEmpty) {
      final firstBlock = renderedBlocks.first;
      renderedBlocks[0] = (firstBlock.$1, _withoutTopPadding(firstBlock.$2));
    }
    if (trimLastBlockBottomPadding && renderedBlocks.isNotEmpty) {
      final lastBlock = renderedBlocks.last;
      renderedBlocks[renderedBlocks.length - 1] = (
        lastBlock.$1,
        _withoutBottomPadding(lastBlock.$2),
      );
    }
    return renderedBlocks
        .map((entry) => _withStableBlockKey(entry.$1, entry.$2))
        .toList(growable: false);
  }

  Widget _withStableBlockKey(String blockId, Widget widget) {
    if (blockId.isEmpty) {
      return widget;
    }
    return KeyedSubtree(
      key: ValueKey<String>('markdown-block:$blockId'),
      child: widget,
    );
  }

  Widget _withoutBottomPadding(Widget widget) {
    if (widget is! Padding) return widget;

    final padding = widget.padding;
    if (padding is! EdgeInsets || padding.bottom == 0) {
      return widget;
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(padding.left, padding.top, padding.right, 0),
      child: widget.child,
    );
  }

  /// Drops a leading heading's extra top space when it opens the message, so
  /// the reply starts flush under its header.
  Widget _withoutTopPadding(Widget widget) {
    if (widget is! Padding) return widget;

    final padding = widget.padding;
    if (padding is! EdgeInsets || padding.top == 0) {
      return widget;
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(
        padding.left,
        0,
        padding.right,
        padding.bottom,
      ),
      child: widget.child,
    );
  }

  Widget? _renderCompiledBlock(CompiledMarkdownBlock block) {
    if (block is CompiledMarkdownNodeBlock) {
      return _renderCompiledNodeBlock(block);
    }
    if (block is CompiledMarkdownDetailsBlock) {
      return _renderCompiledDetailsBlock(block);
    }
    if (block is CompiledMarkdownDetailsGroup) {
      return _renderCompiledDetailsGroup(block);
    }
    return null;
  }

  List<CompiledMarkdownBlock> _compiledBlocksFromNodes(
    List<CompiledMarkdownNode> nodes,
  ) {
    final blocks = <CompiledMarkdownBlock>[];
    var index = 0;
    while (index < nodes.length) {
      final node = nodes[index];
      final nodePath = _nodePathFor(index);
      final detailsBlock = _compiledDetailsBlockFromNode(
        node,
        fallbackBlockId: nodePath,
      );
      if (detailsBlock == null) {
        blocks.add(
          CompiledMarkdownNodeBlock.fromNode(
            blockId: node.nodeId.isEmpty ? nodePath : node.nodeId,
            node: node,
          ),
        );
        index += 1;
        continue;
      }

      final shouldGroup = detailsBlock.type == 'tool_calls';
      if (!shouldGroup) {
        blocks.add(detailsBlock);
        index += 1;
        continue;
      }

      final groupedItems = <CompiledMarkdownDetailsBlock>[detailsBlock];
      var lookahead = index + 1;
      while (lookahead < nodes.length) {
        final nextDetailsBlock = _compiledDetailsBlockFromNode(
          nodes[lookahead],
          fallbackBlockId: _nodePathFor(lookahead),
        );
        if (nextDetailsBlock == null ||
            nextDetailsBlock.type != detailsBlock.type) {
          break;
        }
        groupedItems.add(nextDetailsBlock);
        lookahead += 1;
      }

      if (groupedItems.length == 1) {
        blocks.add(detailsBlock);
      } else {
        blocks.add(
          CompiledMarkdownDetailsGroup(
            blockId:
                'group:${groupedItems.first.blockId}:${groupedItems.first.type}',
            items: groupedItems,
          ),
        );
      }
      index = lookahead;
    }
    return List<CompiledMarkdownBlock>.unmodifiable(blocks);
  }

  String _nodePathFor(int index) {
    final prefix = nodePathPrefix;
    if (prefix == null || prefix.isEmpty) {
      return '$index';
    }
    return '$prefix.$index';
  }

  String _childNodePath(String parentNodePath, int childIndex) =>
      '$parentNodePath.$childIndex';

  Widget? _renderTextNode(CompiledMarkdownText node) {
    final text = node.text.trim();
    if (text.isEmpty) return null;
    return _buildInlineRichText([node]);
  }

  Widget? _renderCompiledNodeBlock(CompiledMarkdownNodeBlock block) {
    final nodePath = block.node.nodeId.isEmpty
        ? block.blockId
        : block.node.nodeId;
    final node = block.node;
    return switch (block.kind) {
      CompiledMarkdownNodeBlockKind.text =>
        node is CompiledMarkdownText ? _renderTextNode(node) : null,
      CompiledMarkdownNodeBlockKind.paragraph =>
        node is CompiledMarkdownElement ? _renderParagraph(node) : null,
      CompiledMarkdownNodeBlockKind.heading1 =>
        node is CompiledMarkdownElement ? _renderHeading(node, 1) : null,
      CompiledMarkdownNodeBlockKind.heading2 =>
        node is CompiledMarkdownElement ? _renderHeading(node, 2) : null,
      CompiledMarkdownNodeBlockKind.heading3 =>
        node is CompiledMarkdownElement ? _renderHeading(node, 3) : null,
      CompiledMarkdownNodeBlockKind.heading4 =>
        node is CompiledMarkdownElement ? _renderHeading(node, 4) : null,
      CompiledMarkdownNodeBlockKind.heading5 =>
        node is CompiledMarkdownElement ? _renderHeading(node, 5) : null,
      CompiledMarkdownNodeBlockKind.heading6 =>
        node is CompiledMarkdownElement ? _renderHeading(node, 6) : null,
      CompiledMarkdownNodeBlockKind.codeBlock =>
        node is CompiledMarkdownElement ? _renderCodeBlock(node) : null,
      CompiledMarkdownNodeBlockKind.blockquote =>
        node is CompiledMarkdownElement
            ? _renderBlockquote(node, nodePath: nodePath)
            : null,
      CompiledMarkdownNodeBlockKind.unorderedList =>
        node is CompiledMarkdownElement
            ? _renderUnorderedList(node, nodePath: nodePath)
            : null,
      CompiledMarkdownNodeBlockKind.orderedList =>
        node is CompiledMarkdownElement
            ? _renderOrderedList(node, nodePath: nodePath)
            : null,
      CompiledMarkdownNodeBlockKind.listItem =>
        node is CompiledMarkdownElement
            ? _renderListItem(node, '', nodePath: nodePath)
            : null,
      CompiledMarkdownNodeBlockKind.table =>
        node is CompiledMarkdownElement ? _renderTable(node) : null,
      CompiledMarkdownNodeBlockKind.horizontalRule => _renderHorizontalRule(),
      CompiledMarkdownNodeBlockKind.div =>
        node is CompiledMarkdownElement
            ? _renderDiv(node, nodePath: nodePath)
            : null,
      CompiledMarkdownNodeBlockKind.section =>
        node is CompiledMarkdownElement
            ? _renderSection(node, nodePath: nodePath)
            : null,
      CompiledMarkdownNodeBlockKind.details =>
        node is CompiledMarkdownElement
            ? _renderCompiledDetailsBlock(
                _compiledDetailsBlockFromElement(
                  node,
                  fallbackBlockId: nodePath,
                ),
              )
            : null,
      CompiledMarkdownNodeBlockKind.image =>
        node is CompiledMarkdownElement ? _renderBlockImage(node) : null,
      CompiledMarkdownNodeBlockKind.fallback =>
        node is CompiledMarkdownElement ? _renderFallback(node) : null,
    };
  }

  // -- Paragraph --

  Widget _renderParagraph(CompiledMarkdownElement element) {
    final singleImage = _extractSingleImage(element);
    if (singleImage != null) {
      return Padding(
        padding: EdgeInsets.only(bottom: style.paragraphSpacing),
        child: _renderBlockImage(singleImage),
      );
    }

    final singlePdfLink = _extractSinglePdfLink(element);
    if (singlePdfLink != null &&
        heavyBlockPolicy == MarkdownHeavyBlockPolicy.eager) {
      return Padding(
        padding: EdgeInsets.only(bottom: style.paragraphSpacing),
        child: _renderPdfLink(singlePdfLink),
      );
    }

    final children = element.children;
    if (children.isEmpty) {
      return const SizedBox.shrink();
    }

    final mixedImageParagraph = _renderParagraphWithStandaloneImages(element);
    if (mixedImageParagraph != null) {
      return Padding(
        padding: EdgeInsets.only(bottom: style.paragraphSpacing),
        child: mixedImageParagraph,
      );
    }

    return Padding(
      padding: EdgeInsets.only(bottom: style.paragraphSpacing),
      child: _buildInlineRichText(children),
    );
  }

  /// Returns the single `img` child if the paragraph
  /// contains exactly one child that is an `img` element.
  CompiledMarkdownElement? _extractSingleImage(
    CompiledMarkdownElement paragraph,
  ) {
    final children = paragraph.children;
    if (children.length != 1) {
      return null;
    }
    final child = children.first;
    if (child is CompiledMarkdownElement && child.tag == 'img') {
      return child;
    }
    return null;
  }

  CompiledMarkdownElement? _extractSinglePdfLink(
    CompiledMarkdownElement paragraph,
  ) {
    final children = paragraph.children;
    if (children.length != 1) {
      return null;
    }
    final child = children.first;
    if (child is CompiledMarkdownElement &&
        child.tag == 'a' &&
        PdfInlineView.isPdfLink(child.attributes['href'] ?? '')) {
      return child;
    }
    return null;
  }

  Widget _renderPdfLink(CompiledMarkdownElement element) {
    return PdfInlineView(
      url: element.attributes['href'] ?? '',
      label: element.textContent,
    );
  }

  Widget? _renderParagraphWithStandaloneImages(
    CompiledMarkdownElement paragraph,
  ) {
    final children = paragraph.children;
    if (!_hasStandaloneImageChild(children)) {
      return null;
    }

    final flowWidgets = <Widget>[];
    final inlineRun = <CompiledMarkdownNode>[];
    var trimLeadingSoftBreak = false;

    void flushInlineRun({required bool trimTrailingSoftBreak}) {
      if (inlineRun.isEmpty) {
        return;
      }

      final renderRun = trimTrailingSoftBreak
          ? _trimInlineRunTrailingSoftBreak(inlineRun)
          : List<CompiledMarkdownNode>.of(inlineRun);
      inlineRun.clear();
      if (renderRun.isEmpty) {
        return;
      }

      flowWidgets.add(_buildInlineRichText(renderRun));
    }

    for (var index = 0; index < children.length; index += 1) {
      final child = children[index];
      if (_isStandaloneImageChild(children, index)) {
        flushInlineRun(trimTrailingSoftBreak: true);
        final image = _renderBlockImage(child as CompiledMarkdownElement);
        if (image != null) {
          flowWidgets.add(image);
        }
        trimLeadingSoftBreak = true;
        continue;
      }

      var inlineChild = child;
      if (trimLeadingSoftBreak) {
        if (_isLineBreakNode(child)) {
          continue;
        }
        final trimmedChild = _trimInlineNodeLeadingSoftBreak(child);
        if (trimmedChild == null) {
          continue;
        }
        trimLeadingSoftBreak = false;
        inlineChild = trimmedChild;
      }
      inlineRun.add(inlineChild);
    }

    flushInlineRun(trimTrailingSoftBreak: false);
    if (flowWidgets.isEmpty) {
      return null;
    }
    if (flowWidgets.length == 1) {
      return flowWidgets.single;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: _withParagraphFlowSpacing(flowWidgets),
    );
  }

  bool _hasStandaloneImageChild(List<CompiledMarkdownNode> children) {
    for (var index = 0; index < children.length; index += 1) {
      if (_isStandaloneImageChild(children, index)) {
        return true;
      }
    }
    return false;
  }

  bool _isStandaloneImageChild(List<CompiledMarkdownNode> children, int index) {
    final child = children[index];
    return child is CompiledMarkdownElement &&
        child.tag == 'img' &&
        _hasSoftLineBoundaryBefore(children, index) &&
        _hasSoftLineBoundaryAfter(children, index);
  }

  bool _hasSoftLineBoundaryBefore(
    List<CompiledMarkdownNode> children,
    int index,
  ) {
    for (var childIndex = index - 1; childIndex >= 0; childIndex -= 1) {
      final child = children[childIndex];
      if (_isLineBreakNode(child)) {
        return true;
      }
      if (child is! CompiledMarkdownText) {
        return false;
      }
      final text = child.text;
      if (text.isEmpty) {
        continue;
      }
      if (text.trim().isEmpty) {
        if (text.contains('\n')) {
          return true;
        }
        continue;
      }
      return _trailingSoftBreakPattern.hasMatch(text);
    }
    return true;
  }

  bool _hasSoftLineBoundaryAfter(
    List<CompiledMarkdownNode> children,
    int index,
  ) {
    for (
      var childIndex = index + 1;
      childIndex < children.length;
      childIndex += 1
    ) {
      final child = children[childIndex];
      if (_isLineBreakNode(child)) {
        return true;
      }
      if (child is! CompiledMarkdownText) {
        return false;
      }
      final text = child.text;
      if (text.isEmpty) {
        continue;
      }
      if (text.trim().isEmpty) {
        if (text.contains('\n')) {
          return true;
        }
        continue;
      }
      return _leadingSoftBreakPattern.hasMatch(text);
    }
    return true;
  }

  List<CompiledMarkdownNode> _trimInlineRunTrailingSoftBreak(
    List<CompiledMarkdownNode> nodes,
  ) {
    final trimmed = List<CompiledMarkdownNode>.of(nodes);
    while (trimmed.isNotEmpty) {
      final last = trimmed.last;
      if (_isLineBreakNode(last)) {
        trimmed.removeLast();
        continue;
      }
      if (last is! CompiledMarkdownText) {
        return trimmed;
      }
      final trimmedLast = _trimTextNodeTrailingSoftBreak(last);
      if (trimmedLast == null) {
        trimmed.removeLast();
        continue;
      }
      if (trimmedLast.text.trim().isEmpty) {
        trimmed.removeLast();
        continue;
      }
      trimmed[trimmed.length - 1] = trimmedLast;
      return trimmed;
    }
    return const <CompiledMarkdownNode>[];
  }

  CompiledMarkdownNode? _trimInlineNodeLeadingSoftBreak(
    CompiledMarkdownNode node,
  ) {
    if (_isLineBreakNode(node)) {
      return null;
    }
    if (node is! CompiledMarkdownText) {
      return node;
    }
    final text = node.text.replaceFirst(_leadingSoftBreakPattern, '');
    if (text.trim().isEmpty) {
      return null;
    }
    if (text == node.text) {
      return node;
    }
    return _copyTextNodeWithText(node, text);
  }

  CompiledMarkdownText? _trimTextNodeTrailingSoftBreak(
    CompiledMarkdownText node,
  ) {
    final text = node.text.replaceFirst(_trailingSoftBreakPattern, '');
    if (text.isEmpty) {
      return null;
    }
    if (text == node.text) {
      return node;
    }
    return _copyTextNodeWithText(node, text);
  }

  CompiledMarkdownText _copyTextNodeWithText(
    CompiledMarkdownText node,
    String text,
  ) {
    return CompiledMarkdownText(
      text,
      nodeId: node.nodeId,
      containsLatexPlaceholders: latexPreprocessor.containsPlaceholder(text),
      containsCitations: node.containsCitations,
    );
  }

  bool _isLineBreakNode(CompiledMarkdownNode node) =>
      node is CompiledMarkdownElement && node.tag == 'br';

  List<Widget> _withParagraphFlowSpacing(List<Widget> widgets) {
    if (widgets.length < 2) {
      return widgets;
    }

    final spaced = <Widget>[];
    for (var index = 0; index < widgets.length; index += 1) {
      if (index > 0) {
        spaced.add(SizedBox(height: style.paragraphSpacing));
      }
      spaced.add(widgets[index]);
    }
    return spaced;
  }

  // -- Heading --

  Widget _renderHeading(CompiledMarkdownElement element, int level) {
    final children = element.children;
    final span = children.isNotEmpty
        ? inlineRenderer.render(
            children,
            parentStyle: style.headingStyle(level),
          )
        : TextSpan(text: element.textContent, style: style.headingStyle(level));

    return Padding(
      padding: EdgeInsets.only(
        top: style.headingTopSpacing,
        bottom: style.headingBottomSpacing,
      ),
      child: MarkdownText(span),
    );
  }

  // -- Code block --

  Widget _renderCodeBlock(CompiledMarkdownElement element) {
    final codeElement = _extractCodeChild(element);
    final language = element.language;
    final rawCode = (codeElement ?? element).textContent;
    // The code body is rendered outside the inline renderer, but it is still
    // part of the document-wide textContent that the streaming-fade offset is
    // measured against. Advance the offset so a streaming tail after this code
    // block fades the correct character range.
    inlineRenderer.advanceVisibleTextOffset(rawCode.length);
    // A fenced block's text ends with the newline before the closing fence;
    // drawing it would add an empty last line below the code.
    final code = rawCode.endsWith('\n')
        ? rawCode.substring(0, rawCode.length - 1)
        : rawCode;
    final blockKind = element.blockKind;
    final previewable = blockKind == CompiledMarkdownBlockKind.previewableCode;
    final inlinePreview =
        previewable &&
        element.inlinePreview &&
        heavyBlockPolicy == MarkdownHeavyBlockPolicy.eager;

    final conduitTheme = context.conduitTheme;

    if (element.isHeavyBlock) {
      if (heavyBlockPolicy == MarkdownHeavyBlockPolicy.defer) {
        return _renderDeferredHeavyBlockPlaceholder(blockKind);
      }
      return _buildHeavyPreview(blockKind, code);
    }

    final codeBlock = Padding(
      padding: EdgeInsets.only(bottom: style.codeBlockSpacing),
      child: ConduitMarkdown.buildCodeBlock(
        context: context,
        code: code,
        language: language,
        theme: conduitTheme,
        onPreview: previewable
            ? () => ConduitMarkdown.showCodePreviewSheet(
                context,
                code: code,
                language: language,
              )
            : null,
        stateId: _scopedCodeBlockStateId(element.nodeId),
      ),
    );

    if (!inlinePreview) {
      return codeBlock;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ConduitMarkdown.buildInlineCodePreview(
          context,
          code: code,
          language: language,
        ),
        SizedBox(height: style.paragraphSpacing),
        codeBlock,
      ],
    );
  }

  Widget _buildHeavyPreview(CompiledMarkdownBlockKind blockKind, String code) {
    return switch (blockKind) {
      CompiledMarkdownBlockKind.mermaid => Padding(
        padding: EdgeInsets.only(bottom: style.codeBlockSpacing),
        child: ConduitMarkdown.buildMermaidBlock(context, code),
      ),
      CompiledMarkdownBlockKind.chartJs => Padding(
        padding: EdgeInsets.only(bottom: style.codeBlockSpacing),
        child: ConduitMarkdown.buildChartJsBlock(context, code),
      ),
      _ => const SizedBox.shrink(),
    };
  }

  Widget _renderDeferredHeavyBlockPlaceholder(
    CompiledMarkdownBlockKind blockKind,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    return Padding(
      padding: EdgeInsets.only(bottom: style.codeBlockSpacing),
      child: Container(
        width: double.infinity,
        height: _deferredHeavyPreviewHeight(blockKind),
        decoration: BoxDecoration(
          color: theme.surfaceContainer.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(AppBorderRadius.sm),
          border: Border.all(
            color: theme.cardBorder.withValues(alpha: 0.4),
            width: BorderWidth.micro,
          ),
        ),
        child: Center(
          child: ConduitLoading.inline(
            context: context,
            message: l10n.previewDeferredLargeContent,
          ),
        ),
      ),
    );
  }

  double _deferredHeavyPreviewHeight(CompiledMarkdownBlockKind blockKind) {
    return switch (blockKind) {
      CompiledMarkdownBlockKind.mermaid => 360,
      CompiledMarkdownBlockKind.chartJs => 320,
      _ => 240,
    };
  }

  /// Extracts the `<code>` child from a `<pre>` element.
  CompiledMarkdownElement? _extractCodeChild(CompiledMarkdownElement pre) {
    final children = pre.children;
    for (final child in children) {
      if (child is CompiledMarkdownElement && child.tag == 'code') {
        return child;
      }
    }
    return null;
  }

  // -- Blockquote --

  Widget _renderBlockquote(
    CompiledMarkdownElement element, {
    required String nodePath,
  }) {
    final children = element.children;
    if (children.isEmpty) {
      return const SizedBox.shrink();
    }

    final inner = _nested(nodePath);

    return Padding(
      padding: EdgeInsets.only(bottom: style.blockquoteSpacing),
      child: CustomPaint(
        painter: _QuoteBarPainter(color: style.blockquoteBorderColor),
        child: Padding(
          padding: const EdgeInsets.only(
            left: _QuoteBarPainter.barWidth + Spacing.md - Spacing.xxs,
          ),
          child: DefaultTextStyle.merge(
            style: style.blockquoteText,
            child: inner.renderBlocks(children),
          ),
        ),
      ),
    );
  }

  // -- Lists --

  static const _bulletGlyphs = ['•', '◦', '▪'];

  Widget _renderUnorderedList(
    CompiledMarkdownElement element, {
    required String nodePath,
  }) {
    final marker = _bulletGlyphs[listDepth.clamp(0, _bulletGlyphs.length - 1)];
    final items = <(CompiledMarkdownElement, String, String)>[];
    final children = element.children;
    for (var index = 0; index < children.length; index++) {
      final child = children[index];
      if (child is CompiledMarkdownElement && child.tag == 'li') {
        items.add((child, marker, _childNodePath(nodePath, index)));
      }
    }
    return _renderList(items, ordered: false);
  }

  Widget _renderOrderedList(
    CompiledMarkdownElement element, {
    required String nodePath,
  }) {
    final startAttr = element.attributes['start'];
    final start = startAttr != null ? (int.tryParse(startAttr) ?? 1) : 1;

    final items = <(CompiledMarkdownElement, String, String)>[];
    final children = element.children;
    var number = start;
    for (var childIndex = 0; childIndex < children.length; childIndex++) {
      final child = children[childIndex];
      if (child is CompiledMarkdownElement && child.tag == 'li') {
        items.add((child, '$number.', _childNodePath(nodePath, childIndex)));
        number++;
      }
    }
    return _renderList(items, ordered: true);
  }

  /// Lays out list items with one marker column for the whole list, so text
  /// lines up across items and a nested list starts at its parent's text.
  Widget _renderList(
    List<(CompiledMarkdownElement, String, String)> items, {
    required bool ordered,
  }) {
    if (items.isEmpty) return const SizedBox.shrink();
    final markerWidth = _listMarkerColumnWidth(
      ordered ? items.map((item) => item.$2) : const <String>[],
    );
    // Loose lists (items separated by blank lines in the source) get a
    // little more air between items; tight lists stay tight.
    final loose = items.any(
      (item) => item.$1.children.any(
        (child) => child is CompiledMarkdownElement && child.tag == 'p',
      ),
    );
    final itemGap = loose ? style.looseListItemSpacing : style.listItemSpacing;
    final rows = <Widget>[];
    for (var index = 0; index < items.length; index++) {
      if (index > 0) rows.add(SizedBox(height: itemGap));
      final (item, marker, path) = items[index];
      rows.add(
        _renderListItem(
          item,
          marker,
          nodePath: path,
          markerWidth: markerWidth,
          ordered: ordered,
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.only(bottom: style.paragraphSpacing),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows,
      ),
    );
  }

  /// Width of the marker column: about 1.2em for bullets, and wide enough for
  /// the longest number (plus a gap) for ordered lists. Scales with Dynamic
  /// Type like the text it sits beside.
  double _listMarkerColumnWidth(Iterable<String> orderedMarkers) {
    final scaler = MediaQuery.textScalerOf(context);
    final em = scaler.scale(style.body.fontSize ?? 17);
    final minimum = em * _bulletColumnEm;
    var widest = '';
    for (final marker in orderedMarkers) {
      if (marker.length > widest.length) widest = marker;
    }
    if (widest.isEmpty) return minimum;
    final painter = TextPainter(
      text: TextSpan(text: widest, style: _orderedMarkerStyle),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final width = painter.width + em * _orderedMarkerGapEm;
    painter.dispose();
    return width > minimum ? width.ceilToDouble() : minimum;
  }

  TextStyle get _orderedMarkerStyle =>
      style.body.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);

  static const double _bulletColumnEm = 20 / 17;
  static const double _orderedMarkerGapEm = 0.4;

  // -- List item --

  Widget _renderListItem(
    CompiledMarkdownElement element,
    String marker, {
    required String nodePath,
    double? markerWidth,
    bool ordered = false,
  }) {
    final task = _splitTaskCheckbox(element.children);
    final children = task.children;
    final inlineNodes = <CompiledMarkdownNode>[];
    final blockNodes = <CompiledMarkdownNode>[];
    var lastChunkWasParagraph = false;

    for (final child in children) {
      if (blockNodes.isEmpty) {
        final appended = _appendInlineListChild(
          child,
          inlineNodes,
          afterParagraph: lastChunkWasParagraph,
        );
        if (appended != null) {
          lastChunkWasParagraph = appended;
          continue;
        }
      }
      blockNodes.add(child);
    }

    Widget content;
    if (inlineNodes.isNotEmpty && blockNodes.isEmpty) {
      content = _buildInlineRichText(inlineNodes);
    } else if (blockNodes.isNotEmpty) {
      final inner = _nested(nodePath, listDepth: listDepth + 1);
      final blockContent = inner.renderBlocks(blockNodes);

      if (inlineNodes.isEmpty) {
        content = blockContent;
      } else {
        final first = blockNodes.first;
        final startsWithList =
            first is CompiledMarkdownElement &&
            (first.tag == 'ul' || first.tag == 'ol');
        content = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildInlineRichText(inlineNodes),
            SizedBox(
              height: startsWithList
                  ? style.listItemSpacing
                  : style.looseListItemSpacing,
            ),
            blockContent,
          ],
        );
      }
    } else {
      content = Text(element.textContent, style: style.body);
    }

    final columnWidth = markerWidth ?? _listMarkerColumnWidth(const []);
    final markerGap = ordered
        ? MediaQuery.textScalerOf(context).scale(style.body.fontSize ?? 17) *
              _orderedMarkerGapEm
        : 0.0;
    // Baseline alignment puts the marker on the first line's baseline
    // whatever the content's strut or line height, instead of a fixed
    // nudge that left bullets and numbers sitting low.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        SizedBox(
          width: columnWidth,
          child: switch (task.checked) {
            final checked? => _taskCheckbox(checked),
            null => Padding(
              padding: EdgeInsetsDirectional.only(end: markerGap),
              child: Text(
                marker,
                style: ordered ? _orderedMarkerStyle : style.body,
                textAlign: ordered ? TextAlign.end : TextAlign.center,
                maxLines: 1,
                softWrap: false,
              ),
            ),
          },
        ),
        Expanded(child: content),
      ],
    );
  }

  /// A GitHub task-list item leads with `<input type="checkbox">`, directly
  /// or inside its first paragraph. Returns the item's children without it,
  /// and its state, so the box can replace the bullet.
  ({bool? checked, List<CompiledMarkdownNode> children}) _splitTaskCheckbox(
    List<CompiledMarkdownNode> children,
  ) {
    bool? checkboxState(CompiledMarkdownNode node) =>
        node is CompiledMarkdownElement &&
            node.tag == 'input' &&
            node.attributes['type'] == 'checkbox'
        ? node.attributes['checked'] == 'true'
        : null;

    // The source's `[ ] text` leaves a space after the box.
    List<CompiledMarkdownNode> withoutLeadingSpace(
      Iterable<CompiledMarkdownNode> nodes,
    ) {
      final list = nodes.toList();
      final first = list.isEmpty ? null : list.first;
      if (first is CompiledMarkdownText &&
          !first.hasInlineSegments &&
          !first.containsLatexPlaceholders &&
          !first.containsCitations) {
        list[0] = CompiledMarkdownText(
          first.text.trimLeft(),
          nodeId: first.nodeId,
        );
      }
      return list;
    }

    if (children.isEmpty) return (checked: null, children: children);
    final first = children.first;
    final direct = checkboxState(first);
    if (direct != null) {
      return (checked: direct, children: withoutLeadingSpace(children.skip(1)));
    }
    if (first is CompiledMarkdownElement &&
        first.tag == 'p' &&
        first.children.isNotEmpty) {
      final nested = checkboxState(first.children.first);
      if (nested != null) {
        return (
          checked: nested,
          children: [
            CompiledMarkdownElement(
              nodeId: first.nodeId,
              tag: first.tag,
              blockKind: first.blockKind,
              attributes: first.attributes,
              children: withoutLeadingSpace(first.children.skip(1)),
            ),
            ...children.skip(1),
          ],
        );
      }
    }
    return (checked: null, children: children);
  }

  /// A task-list box, set in a text span so it sits on the item's baseline
  /// like a bullet does.
  Widget _taskCheckbox(bool checked) {
    final cupertino = context.usesCupertinoChrome;
    final color = style.body.color;
    final l10n = AppLocalizations.of(context);
    return Text.rich(
      TextSpan(
        style: style.body,
        children: [
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Icon(
              checked
                  ? (cupertino
                        ? CupertinoIcons.checkmark_square_fill
                        : Icons.check_box)
                  : (cupertino
                        ? CupertinoIcons.square
                        : Icons.check_box_outline_blank),
              size: (style.body.fontSize ?? 16) * 1.1,
              color: checked ? color : color?.withValues(alpha: 0.55),
              semanticLabel: checked
                  ? l10n?.chatTaskCompleted
                  : l10n?.chatTaskPending,
            ),
          ),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }

  /// Appends [child] to the item's leading inline run when it is inline
  /// content (or a plain paragraph). Returns whether the appended chunk was a
  /// paragraph, or `null` when [child] is block content.
  ///
  /// Inline siblings (text, bold, code, links) already carry their own
  /// whitespace, so they join directly; adding a space between them doubled
  /// the gap after `**bold**` or `code`. Only separate paragraphs of a loose
  /// item are joined with a space, matching the web renderer.
  bool? _appendInlineListChild(
    CompiledMarkdownNode child,
    List<CompiledMarkdownNode> inlineNodes, {
    required bool afterParagraph,
  }) {
    if (child is CompiledMarkdownText) {
      if (afterParagraph) _appendParagraphSeparator(inlineNodes);
      inlineNodes.add(child);
      return false;
    }

    if (child is! CompiledMarkdownElement) {
      return null;
    }

    if (child.tag == 'p') {
      final singleImage = _extractSingleImage(child);
      final paragraphChildren = child.children;
      if (singleImage != null ||
          paragraphChildren.isEmpty ||
          _containsBlockElements(paragraphChildren)) {
        return null;
      }

      _appendParagraphSeparator(inlineNodes);
      inlineNodes.addAll(paragraphChildren);
      return true;
    }

    if (_isBlockElementTag(child.tag)) {
      return null;
    }

    if (afterParagraph) _appendParagraphSeparator(inlineNodes);
    inlineNodes.add(child);
    return false;
  }

  void _appendParagraphSeparator(List<CompiledMarkdownNode> inlineNodes) {
    if (inlineNodes.isEmpty) {
      return;
    }

    final lastNode = inlineNodes.last;
    if (lastNode is CompiledMarkdownText &&
        RegExp(r'\s$').hasMatch(lastNode.text)) {
      return;
    }

    inlineNodes.add(CompiledMarkdownText(' '));
  }

  /// Returns `true` if [nodes] contain block-level
  /// elements like paragraphs, lists, or headings.
  bool _containsBlockElements(List<CompiledMarkdownNode> nodes) {
    for (final node in nodes) {
      if (node is CompiledMarkdownElement && _isBlockElementTag(node.tag)) {
        return true;
      }
    }
    return false;
  }

  bool _isBlockElementTag(String tag) {
    const blockTags = {
      'p',
      'h1',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
      'ul',
      'ol',
      'pre',
      'blockquote',
      'table',
      'hr',
      'details',
      'div',
      'section',
    };
    return blockTags.contains(tag);
  }

  // -- Table --

  Widget _renderTable(CompiledMarkdownElement element) {
    final header = <Widget>[];
    final rows = <CompiledMarkdownElement>[];

    for (final section in element.children) {
      if (section is! CompiledMarkdownElement) continue;
      if (section.tag == 'thead') {
        for (final row in section.children) {
          if (row is! CompiledMarkdownElement || row.tag != 'tr') continue;
          for (final cell in row.children) {
            if (cell is! CompiledMarkdownElement) continue;
            if (cell.tag != 'th' && cell.tag != 'td') continue;
            header.add(_buildTableCell(cell, isHeader: true));
          }
        }
      } else if (section.tag == 'tbody') {
        rows.addAll(
          section.children.whereType<CompiledMarkdownElement>().where(
            (row) => row.tag == 'tr',
          ),
        );
      }
    }

    if (header.isEmpty) return const SizedBox.shrink();
    final previewRows = rows
        .take(_ExpandableMarkdownTable.previewRowCount)
        .map((row) => _buildTableRow(row, header.length))
        .toList(growable: false);
    final remainingRows = rows
        .skip(_ExpandableMarkdownTable.previewRowCount)
        .toList(growable: false);
    for (final row in remainingRows) {
      inlineRenderer.advanceVisibleTextOffset(row.textContent.length);
    }

    return Padding(
      padding: EdgeInsets.only(bottom: style.tableSpacing),
      child: _ExpandableMarkdownTable(
        header: header,
        previewRows: previewRows,
        remainingRows: remainingRows,
        rowBuilder: (row) => _buildTableRow(row, header.length),
        style: style,
      ),
    );
  }

  Widget _buildTableCell(
    CompiledMarkdownElement cell, {
    required bool isHeader,
  }) {
    final cellStyle = isHeader ? style.tableHeader : style.tableCell;
    final children = cell.children;
    final text = children.isNotEmpty
        ? MarkdownText(inlineRenderer.render(children, parentStyle: cellStyle))
        : Text(cell.textContent, style: cellStyle);
    final alignment = switch (cell.attributes['align']) {
      'center' => AlignmentDirectional.topCenter,
      'right' => AlignmentDirectional.topEnd,
      _ => null,
    };
    return alignment == null ? text : Align(alignment: alignment, child: text);
  }

  List<Widget> _buildTableRow(CompiledMarkdownElement row, int columnCount) {
    final cells = <Widget>[];
    for (final cell in row.children) {
      if (cell is! CompiledMarkdownElement) continue;
      if (cell.tag != 'td' && cell.tag != 'th') continue;
      cells.add(_buildTableCell(cell, isHeader: false));
    }
    // Keep malformed rows compatible with the table's fixed column count.
    if (cells.length > columnCount) {
      cells.removeRange(columnCount, cells.length);
    }
    while (cells.length < columnCount) {
      cells.add(const SizedBox.shrink());
    }
    return cells;
  }

  // -- Horizontal rule --

  Widget _renderHorizontalRule() {
    // Equal space above and below the rule: the previous block's bottom gap
    // plus a little, mirrored underneath.
    return Padding(
      padding: EdgeInsets.only(
        top: Spacing.xs,
        bottom: style.paragraphSpacing + Spacing.xs,
      ),
      child: Container(height: BorderWidth.thin, color: style.dividerColor),
    );
  }

  // -- Div (GitHub alerts) --

  Widget? _renderDiv(
    CompiledMarkdownElement element, {
    required String nodePath,
  }) {
    final cls = element.attributes['class'] ?? '';
    if (cls.contains('markdown-alert')) {
      return _renderAlert(element, cls, nodePath: nodePath);
    }
    return _renderFallback(element);
  }

  Widget _renderAlert(
    CompiledMarkdownElement element,
    String cls, {
    required String nodePath,
  }) {
    final alertType = _parseAlertType(cls);
    final config = _alertConfig(alertType);

    final children = element.children;
    final contentNodes = <CompiledMarkdownNode>[];
    String? titleText;

    // The first child is typically a <p> containing
    // the alert title marker.
    for (final child in children) {
      if (child is CompiledMarkdownElement &&
          child.tag == 'p' &&
          titleText == null) {
        titleText = _extractAlertTitle(child, alertType);
        // Remaining paragraph content after the title
        // marker is part of the body.
        final remaining = _remainingAlertContent(child);
        if (remaining != null) contentNodes.add(remaining);
      } else {
        contentNodes.add(child);
      }
    }

    final inner = _nested(nodePath);

    return Padding(
      padding: EdgeInsets.only(bottom: style.blockquoteSpacing),
      child: Container(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: config.color, width: 3)),
        ),
        padding: const EdgeInsets.only(left: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(config.icon, color: config.color, size: 18),
                const SizedBox(width: 6),
                Text(
                  titleText ?? config.label,
                  style: style.body.copyWith(
                    fontWeight: FontWeight.w600,
                    color: config.color,
                  ),
                ),
              ],
            ),
            if (contentNodes.isNotEmpty) inner.renderBlocks(contentNodes),
          ],
        ),
      ),
    );
  }

  String _parseAlertType(String cls) {
    const types = ['note', 'tip', 'important', 'warning', 'caution'];
    for (final type in types) {
      if (cls.contains('markdown-alert-$type')) {
        return type;
      }
    }
    return 'note';
  }

  _AlertConfig _alertConfig(String type) {
    final l10n = AppLocalizations.of(context)!;
    return switch (type) {
      'tip' => _AlertConfig(
        color: Colors.green,
        icon: Icons.lightbulb_outline,
        label: l10n.alertTip,
      ),
      'important' => _AlertConfig(
        color: Colors.purple,
        icon: Icons.priority_high,
        label: l10n.alertImportant,
      ),
      'warning' => _AlertConfig(
        color: Colors.amber,
        icon: Icons.warning_amber,
        label: l10n.alertWarning,
      ),
      'caution' => _AlertConfig(
        color: Colors.red,
        icon: Icons.error_outline,
        label: l10n.alertCaution,
      ),
      _ => _AlertConfig(
        color: Colors.blue,
        icon: Icons.info_outline,
        label: l10n.alertNote,
      ),
    };
  }

  /// Known alert marker strings used in GitHub-style
  /// blockquote alerts.
  static const _alertMarkers = [
    '[!NOTE]',
    '[!TIP]',
    '[!IMPORTANT]',
    '[!WARNING]',
    '[!CAUTION]',
  ];

  String? _extractAlertTitle(CompiledMarkdownElement paragraph, String type) {
    final children = paragraph.children;
    if (children.isEmpty) return null;

    final firstChild = children.first;
    final text = firstChild is CompiledMarkdownText
        ? firstChild.text.trim()
        : paragraph.textContent.trim();

    for (final marker in _alertMarkers) {
      if (text.startsWith(marker)) {
        return marker.replaceAll('[!', '').replaceAll(']', '');
      }
    }
    return null;
  }

  /// Strips the alert marker from the first text node of
  /// [paragraph] and returns the remaining content as a
  /// new paragraph element, preserving inline formatting
  /// (bold, italic, links) in subsequent child nodes.
  CompiledMarkdownElement? _remainingAlertContent(
    CompiledMarkdownElement paragraph,
  ) {
    final children = paragraph.children;
    if (children.isEmpty) return null;

    final firstChild = children.first;
    if (firstChild is! CompiledMarkdownText) return paragraph;

    final text = firstChild.text.trim();
    for (final marker in _alertMarkers) {
      if (text.startsWith(marker)) {
        final remaining = text.substring(marker.length).trim();
        final newChildren = <CompiledMarkdownNode>[
          if (remaining.isNotEmpty) CompiledMarkdownText(remaining),
          ...children.skip(1),
        ];
        if (newChildren.isEmpty) return null;
        return CompiledMarkdownElement(
          tag: 'p',
          attributes: const <String, String>{},
          children: newChildren,
        );
      }
    }
    // No marker found; return the whole paragraph.
    return paragraph;
  }

  // -- Section (footnotes) --

  Widget? _renderSection(
    CompiledMarkdownElement element, {
    required String nodePath,
  }) {
    final children = element.children;
    if (children.isEmpty) return null;
    final inner = _nested(nodePath);
    return inner.renderBlocks(children);
  }

  // -- Details --

  Widget _buildDetailsBody({
    required CompiledMarkdownDetailsData data,
    required String? nestedStateScopeId,
  }) {
    final imageBuilder = this.imageBuilder;
    final usesStreamingBody =
        data.isPending || heavyBlockPolicy == MarkdownHeavyBlockPolicy.defer;

    if (usesStreamingBody) {
      return StreamingMarkdownWidget(
        content: data.bodyMarkdown,
        isStreaming: true,
        // Nested pending details inherit the parent renderer's decision rather
        // than silently re-enabling a per-update fade.
        enableStreamingTextFade: streamingFade != null,
        stateScopeId: nestedStateScopeId,
        onTapLink: onLinkTap,
        sources: inlineRenderer.sources,
        onSourceTap: inlineRenderer.onSourceTap,
        imageBuilderOverride: imageBuilder == null
            ? null
            : (uri, title, alt) => imageBuilder(uri.toString(), alt, title),
      );
    }

    final preparedBody = data.bodyMarkdown.trim();
    if (preparedBody.isEmpty) {
      return const SizedBox.shrink();
    }

    final document = compilePreparedMarkdownSync(preparedBody);
    if (document.isEmpty) {
      return const SizedBox.shrink();
    }

    return ConduitMarkdownWidget(
      compiledDocument: document,
      stateScopeId: nestedStateScopeId,
      onLinkTap: onLinkTap,
      sources: inlineRenderer.sources,
      onSourceTap: inlineRenderer.onSourceTap,
      imageBuilder: imageBuilder,
      heavyBlockPolicy: heavyBlockPolicy,
    );
  }

  Widget _renderCompiledDetailsBlock(CompiledMarkdownDetailsBlock block) {
    final inlineExpansionStateId = _scopedDetailsInlineExpansionStateId(
      block.blockId,
      block.supportsInlineExpansion,
    );
    final nestedStateScopeId = _scopedDetailsBodyStateId(block.blockId);
    return MarkdownDetailsBlock(
      key: _detailsKeyFromStateId(inlineExpansionStateId),
      detailsData: block.detailsData,
      deferHeavyContent: heavyBlockPolicy == MarkdownHeavyBlockPolicy.defer,
      inlineExpansionStateId: inlineExpansionStateId,
      bodyBuilder: block.hasBody
          ? (_, data) => _buildDetailsBody(
              data: data,
              nestedStateScopeId: nestedStateScopeId,
            )
          : null,
    );
  }

  Widget _renderCompiledDetailsGroup(CompiledMarkdownDetailsGroup group) {
    final stateId = _scopedDetailsGroupStateId(group.blockId);
    return MarkdownDetailsGroup(
      key: ValueKey<String>(stateId),
      stateId: stateId,
      items: group.items
          .map(
            (item) => MarkdownDetailsGroupItem(
              type: item.type,
              name: item.name,
              isDone: item.isDone,
              childBuilder: (_) => _renderCompiledDetailsBlock(item),
            ),
          )
          .toList(growable: false),
    );
  }

  CompiledMarkdownDetailsBlock? _compiledDetailsBlockFromNode(
    CompiledMarkdownNode node, {
    required String fallbackBlockId,
  }) {
    if (node is! CompiledMarkdownElement || node.tag != 'details') {
      return null;
    }
    return _compiledDetailsBlockFromElement(
      node,
      fallbackBlockId: fallbackBlockId,
    );
  }

  CompiledMarkdownDetailsBlock _compiledDetailsBlockFromElement(
    CompiledMarkdownElement element, {
    required String fallbackBlockId,
  }) {
    assert(
      element.detailsData != null,
      'Expected details elements to carry compiled details metadata.',
    );
    return CompiledMarkdownDetailsBlock(
      blockId: element.nodeId.isEmpty ? fallbackBlockId : element.nodeId,
      detailsData: element.detailsData!,
    );
  }

  Key? _detailsKeyFromStateId(String? stateId) {
    if (stateId == null || stateId.isEmpty) {
      return null;
    }
    return ValueKey<String>(stateId);
  }

  String? _scopedDetailsInlineExpansionStateId(
    String stableId,
    bool usesInlineExpansion,
  ) {
    if (!usesInlineExpansion) {
      return null;
    }
    if ((stateScopeId == null || stateScopeId!.isEmpty) && stableId.isEmpty) {
      return null;
    }
    return [
      if (stateScopeId != null && stateScopeId!.isNotEmpty) stateScopeId,
      stableId,
    ].join('|');
  }

  String? _scopedDetailsBodyStateId(String stableId) {
    if ((stateScopeId == null || stateScopeId!.isEmpty) && stableId.isEmpty) {
      return null;
    }
    return [
      if (stateScopeId != null && stateScopeId!.isNotEmpty) stateScopeId,
      stableId,
      'body',
    ].join('|');
  }

  /// Where a code block keeps its wrap choice on the page, or null when the
  /// block has no stable identity there.
  String? _scopedCodeBlockStateId(String stableId) {
    if (stateScopeId == null || stateScopeId!.isEmpty || stableId.isEmpty) {
      return null;
    }
    return [stateScopeId!, stableId, 'code-wrap'].join('|');
  }

  String _scopedDetailsGroupStateId(String stableId) {
    return [
      if (stateScopeId != null && stateScopeId!.isNotEmpty) stateScopeId!,
      'detail-group',
      stableId,
    ].join('|');
  }

  // -- Block image --

  Widget? _renderBlockImage(CompiledMarkdownElement element) {
    final src = element.attributes['src'] ?? '';
    if (src.isEmpty) return null;
    final alt = element.attributes['alt'];
    final title = element.attributes['title'];

    if (imageBuilder != null) {
      return imageBuilder!(src, alt, title);
    }

    final uri = Uri.tryParse(src);
    if (uri == null) {
      return ConduitMarkdown.buildImageError(context, context.conduitTheme);
    }

    return ConduitMarkdown.buildImage(context, uri, context.conduitTheme);
  }

  // -- Fallback --

  Widget? _renderFallback(CompiledMarkdownElement element) {
    final children = element.children;
    if (children.isNotEmpty) {
      return renderBlocks(children);
    }
    final text = element.textContent.trim();
    if (text.isEmpty) return null;
    return MarkdownText(inlineRenderer.render([element]));
  }
}

class _ExpandableMarkdownTable extends StatefulWidget {
  const _ExpandableMarkdownTable({
    required this.header,
    required this.previewRows,
    required this.remainingRows,
    required this.rowBuilder,
    required this.style,
  });

  static const previewRowCount = 20;

  final List<Widget> header;
  final List<List<Widget>> previewRows;
  final List<CompiledMarkdownElement> remainingRows;
  final List<Widget> Function(CompiledMarkdownElement row) rowBuilder;
  final ConduitMarkdownStyle style;

  @override
  State<_ExpandableMarkdownTable> createState() =>
      _ExpandableMarkdownTableState();
}

class _ExpandableMarkdownTableState extends State<_ExpandableMarkdownTable> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final collapsible = widget.remainingRows.isNotEmpty;
    final visibleRows = _expanded
        ? <List<Widget>>[
            ...widget.previewRows,
            ...widget.remainingRows.map(widget.rowBuilder),
          ]
        : widget.previewRows;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MarkdownTableFrame(
          header: widget.header,
          rows: visibleRows,
          style: widget.style,
        ),
        if (collapsible)
          TextButton.icon(
            onPressed: () => setState(() => _expanded = !_expanded),
            icon: Icon(
              _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
            ),
            label: Text(
              _expanded
                  ? AppLocalizations.of(context)!.markdownShowLess
                  : AppLocalizations.of(context)!
                        .markdownShowMoreLines(widget.remainingRows.length),
            ),
          ),
      ],
    );
  }
}

/// Paints a blockquote's leading bar as a slim capsule the full height of the
/// quote: visible, but quieter than the text beside it.
class _QuoteBarPainter extends CustomPainter {
  const _QuoteBarPainter({required this.color});

  static const double barWidth = 3;

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.height <= 0) return;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, barWidth, size.height),
        const Radius.circular(barWidth / 2),
      ),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_QuoteBarPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// Configuration for a GitHub-style alert.
class _AlertConfig {
  const _AlertConfig({
    required this.color,
    required this.icon,
    required this.label,
  });

  final Color color;
  final IconData icon;
  final String label;
}
