import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/material.dart';

import '../../conduit_loading.dart';
import '../../../theme/theme_extensions.dart';
import '../compiled_markdown_document.dart';
import '../markdown_config.dart';
import '../streaming_markdown_widget.dart';
import 'details_block_widget.dart';
import 'details_group_widget.dart';
import 'inline_renderer.dart';
import 'latex_preprocessor.dart';
import 'markdown_style.dart';

/// Signature for a builder that creates image widgets.
typedef ImageBuilder = Widget Function(String src, String? alt, String? title);

enum MarkdownHeavyBlockPolicy {
  /// Hydrate heavy previews immediately.
  eager,

  /// Avoid hydrating heavy previews and render lightweight code fallback only.
  defer,
}

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

  /// Renders a list of block [nodes] as a [Column].
  Widget renderBlocks(List<CompiledMarkdownNode> nodes) =>
      renderCompiledBlocks(_compiledBlocksFromNodes(nodes));

  /// Renders a list of precompiled root blocks as a [Column].
  Widget renderCompiledBlocks(List<CompiledMarkdownBlock> blocks) {
    final widgets = <Widget>[];
    for (final block in blocks) {
      final widget = _renderCompiledBlock(block);
      if (widget != null) {
        widgets.add(widget);
      }
    }
    if (widgets.isNotEmpty) {
      widgets[widgets.length - 1] = _withoutBottomPadding(widgets.last);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
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
    return Text.rich(inlineRenderer.render([node]));
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

    final children = element.children;
    if (children.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: EdgeInsets.only(bottom: style.paragraphSpacing),
      child: Text.rich(inlineRenderer.render(children)),
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
      child: Text.rich(span),
    );
  }

  // -- Code block --

  Widget _renderCodeBlock(CompiledMarkdownElement element) {
    final codeElement = _extractCodeChild(element);
    final language = element.language;
    final code = (codeElement ?? element).textContent;
    final blockKind = element.blockKind;
    final previewable = blockKind == CompiledMarkdownBlockKind.previewableCode;
    final inlinePreview = previewable && element.inlinePreview;

    final conduitTheme = context.conduitTheme;

    if (element.isHeavyBlock) {
      if (heavyBlockPolicy == MarkdownHeavyBlockPolicy.defer) {
        return _renderDeferredHeavyBlockPlaceholder(blockKind);
      }
      return _buildHeavyPreview(blockKind, code);
    }

    final codeBlock = Padding(
      padding: EdgeInsets.symmetric(vertical: style.codeBlockSpacing),
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
        codeBlock,
      ],
    );
  }

  Widget _buildHeavyPreview(CompiledMarkdownBlockKind blockKind, String code) {
    return switch (blockKind) {
      CompiledMarkdownBlockKind.mermaid => Padding(
        padding: EdgeInsets.symmetric(vertical: style.codeBlockSpacing),
        child: ConduitMarkdown.buildMermaidBlock(context, code),
      ),
      CompiledMarkdownBlockKind.chartJs => Padding(
        padding: EdgeInsets.symmetric(vertical: style.codeBlockSpacing),
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
      padding: EdgeInsets.symmetric(vertical: style.codeBlockSpacing),
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

    final inner = BlockRenderer(
      context,
      style,
      inlineRenderer,
      latexPreprocessor,
      onLinkTap,
      imageBuilder,
      stateScopeId,
      nodePath,
      heavyBlockPolicy,
    );

    return Padding(
      padding: EdgeInsets.symmetric(vertical: style.blockquoteSpacing),
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: style.blockquoteBorderColor, width: 2),
          ),
        ),
        padding: const EdgeInsets.only(left: 12),
        child: DefaultTextStyle.merge(
          style: style.blockquoteText,
          child: inner.renderBlocks(children),
        ),
      ),
    );
  }

  // -- Unordered list --

  Widget _renderUnorderedList(
    CompiledMarkdownElement element, {
    required String nodePath,
  }) {
    final children = element.children;
    final items = <Widget>[];
    for (var index = 0; index < children.length; index++) {
      final child = children[index];
      if (child is CompiledMarkdownElement && child.tag == 'li') {
        items.add(
          _renderListItem(
            child,
            '\u2022',
            nodePath: _childNodePath(nodePath, index),
          ),
        );
      }
    }
    return Padding(
      padding: EdgeInsets.only(bottom: style.paragraphSpacing),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: items,
      ),
    );
  }

  // -- Ordered list --

  Widget _renderOrderedList(
    CompiledMarkdownElement element, {
    required String nodePath,
  }) {
    final startAttr = element.attributes['start'];
    final start = startAttr != null ? (int.tryParse(startAttr) ?? 1) : 1;

    final children = element.children;
    final items = <Widget>[];
    var index = start;
    for (var childIndex = 0; childIndex < children.length; childIndex++) {
      final child = children[childIndex];
      if (child is CompiledMarkdownElement && child.tag == 'li') {
        items.add(
          _renderListItem(
            child,
            '$index.',
            nodePath: _childNodePath(nodePath, childIndex),
          ),
        );
        index++;
      }
    }
    return Padding(
      padding: EdgeInsets.only(bottom: style.paragraphSpacing),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: items,
      ),
    );
  }

  // -- List item --

  Widget _renderListItem(
    CompiledMarkdownElement element,
    String marker, {
    required String nodePath,
  }) {
    final children = element.children;
    final inlineNodes = <CompiledMarkdownNode>[];
    final blockNodes = <CompiledMarkdownNode>[];

    for (final child in children) {
      if (_appendInlineListChild(child, inlineNodes)) {
        continue;
      }
      blockNodes.add(child);
    }

    Widget content;
    if (inlineNodes.isNotEmpty && blockNodes.isEmpty) {
      content = Text.rich(inlineRenderer.render(inlineNodes));
    } else if (blockNodes.isNotEmpty) {
      final inner = BlockRenderer(
        context,
        style,
        inlineRenderer,
        latexPreprocessor,
        onLinkTap,
        imageBuilder,
        stateScopeId,
        nodePath,
        heavyBlockPolicy,
      );
      final blockContent = inner.renderBlocks(blockNodes);

      if (inlineNodes.isEmpty) {
        content = blockContent;
      } else {
        content = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text.rich(inlineRenderer.render(inlineNodes)),
            const SizedBox(height: Spacing.xs),
            blockContent,
          ],
        );
      }
    } else {
      content = Text(element.textContent, style: style.body);
    }

    return Padding(
      padding: EdgeInsets.only(bottom: style.listItemSpacing),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 24,
            child: Text(marker, style: style.body, textAlign: TextAlign.center),
          ),
          Expanded(child: content),
        ],
      ),
    );
  }

  bool _appendInlineListChild(
    CompiledMarkdownNode child,
    List<CompiledMarkdownNode> inlineNodes,
  ) {
    if (child is CompiledMarkdownText) {
      _appendInlineChunkSeparator(inlineNodes);
      inlineNodes.add(child);
      return true;
    }

    if (child is! CompiledMarkdownElement) {
      return false;
    }

    if (child.tag == 'p') {
      final singleImage = _extractSingleImage(child);
      final paragraphChildren = child.children;
      if (singleImage != null ||
          paragraphChildren.isEmpty ||
          _containsBlockElements(paragraphChildren)) {
        return false;
      }

      _appendInlineChunkSeparator(inlineNodes);
      inlineNodes.addAll(paragraphChildren);
      return true;
    }

    if (_isBlockElementTag(child.tag)) {
      return false;
    }

    _appendInlineChunkSeparator(inlineNodes);
    inlineNodes.add(child);
    return true;
  }

  void _appendInlineChunkSeparator(List<CompiledMarkdownNode> inlineNodes) {
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
    final columns = <DataColumn>[];
    final rows = <DataRow>[];

    for (final section in element.children) {
      if (section is! CompiledMarkdownElement) continue;
      if (section.tag == 'thead') {
        _parseTableHead(section, columns);
      } else if (section.tag == 'tbody') {
        _parseTableBody(section, rows, columns.length);
      }
    }

    if (columns.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: EdgeInsets.symmetric(vertical: style.tableSpacing),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingRowColor: WidgetStatePropertyAll(style.tableHeaderBackground),
          border: TableBorder.all(
            color: style.tableBorderColor,
            borderRadius: BorderRadius.circular(style.tableRadius),
          ),
          columns: columns,
          rows: rows,
        ),
      ),
    );
  }

  void _parseTableHead(
    CompiledMarkdownElement thead,
    List<DataColumn> columns,
  ) {
    for (final row in thead.children) {
      if (row is! CompiledMarkdownElement || row.tag != 'tr') continue;
      for (final cell in row.children) {
        if (cell is! CompiledMarkdownElement) continue;
        if (cell.tag != 'th' && cell.tag != 'td') continue;
        final children = cell.children;
        columns.add(
          DataColumn(
            label: children.isNotEmpty
                ? Text.rich(
                    inlineRenderer.render(
                      children,
                      parentStyle: style.tableHeader,
                    ),
                  )
                : Text(cell.textContent, style: style.tableHeader),
          ),
        );
      }
    }
  }

  void _parseTableBody(
    CompiledMarkdownElement tbody,
    List<DataRow> rows,
    int columnCount,
  ) {
    for (final row in tbody.children) {
      if (row is! CompiledMarkdownElement || row.tag != 'tr') continue;
      final cells = <DataCell>[];
      for (final cell in row.children) {
        if (cell is! CompiledMarkdownElement) continue;
        if (cell.tag != 'td' && cell.tag != 'th') continue;
        final children = cell.children;
        cells.add(
          DataCell(
            children.isNotEmpty
                ? Text.rich(
                    inlineRenderer.render(
                      children,
                      parentStyle: style.tableCell,
                    ),
                  )
                : Text(cell.textContent, style: style.tableCell),
          ),
        );
      }
      // Truncate extra cells if row is longer than
      // header to avoid DataTable assertion errors.
      if (cells.length > columnCount) {
        cells.removeRange(columnCount, cells.length);
      }
      // Pad with empty cells if row is shorter than
      // header.
      while (cells.length < columnCount) {
        cells.add(const DataCell(SizedBox.shrink()));
      }
      rows.add(DataRow(cells: cells));
    }
  }

  // -- Horizontal rule --

  Widget _renderHorizontalRule() {
    return Divider(color: style.dividerColor);
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

    final inner = BlockRenderer(
      context,
      style,
      inlineRenderer,
      latexPreprocessor,
      onLinkTap,
      imageBuilder,
      stateScopeId,
      nodePath,
      heavyBlockPolicy,
    );

    return Padding(
      padding: EdgeInsets.symmetric(vertical: style.blockquoteSpacing),
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
    final inner = BlockRenderer(
      context,
      style,
      inlineRenderer,
      latexPreprocessor,
      onLinkTap,
      imageBuilder,
      stateScopeId,
      nodePath,
      heavyBlockPolicy,
    );
    return inner.renderBlocks(children);
  }

  // -- Details --

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
          ? (context) {
              return StreamingMarkdownWidget(
                content: block.bodyMarkdown,
                isStreaming:
                    block.isPending ||
                    heavyBlockPolicy == MarkdownHeavyBlockPolicy.defer,
                stateScopeId: nestedStateScopeId,
                onTapLink: onLinkTap,
                sources: inlineRenderer.sources,
                onSourceTap: inlineRenderer.onSourceTap,
                imageBuilderOverride: imageBuilder == null
                    ? null
                    : (uri, title, alt) =>
                          imageBuilder!(uri.toString(), alt, title),
              );
            }
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
              child: _renderCompiledDetailsBlock(item),
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
    return Text.rich(inlineRenderer.render([element]));
  }
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
