import 'package:flutter/material.dart';
import 'package:markdown/markdown.dart' as md;

import '../../../theme/theme_extensions.dart';
import '../markdown_config.dart';
import 'details_block_widget.dart';
import 'inline_renderer.dart';
import 'latex_preprocessor.dart';
import 'markdown_style.dart';

/// Signature for a builder that creates image widgets.
typedef ImageBuilder = Widget Function(String src, String? alt, String? title);

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

  /// Renders a list of block [nodes] as a [Column].
  Widget renderBlocks(List<md.Node> nodes) {
    final widgets = <Widget>[];
    for (var index = 0; index < nodes.length; index++) {
      final widget = renderBlock(nodes[index], nodePath: _nodePathFor(index));
      if (widget != null) widgets.add(widget);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }

  /// Dispatches a single block [node] to its renderer.
  ///
  /// Returns `null` if the node produces no visual output.
  Widget? renderBlock(md.Node node, {required String nodePath}) {
    if (node is md.Text) {
      return _renderTextNode(node);
    }
    if (node is! md.Element) return null;
    return _renderElement(node, nodePath: nodePath);
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

  Widget? _renderTextNode(md.Text node) {
    final text = node.text.trim();
    if (text.isEmpty) return null;
    return Text.rich(inlineRenderer.render([node]));
  }

  Widget? _renderElement(md.Element element, {required String nodePath}) {
    return switch (element.tag) {
      'p' => _renderParagraph(element),
      'h1' => _renderHeading(element, 1),
      'h2' => _renderHeading(element, 2),
      'h3' => _renderHeading(element, 3),
      'h4' => _renderHeading(element, 4),
      'h5' => _renderHeading(element, 5),
      'h6' => _renderHeading(element, 6),
      'pre' => _renderCodeBlock(element),
      'blockquote' => _renderBlockquote(element, nodePath: nodePath),
      'ul' => _renderUnorderedList(element, nodePath: nodePath),
      'ol' => _renderOrderedList(element, nodePath: nodePath),
      'li' => _renderListItem(element, '', nodePath: nodePath),
      'table' => _renderTable(element),
      'hr' => _renderHorizontalRule(),
      'div' => _renderDiv(element, nodePath: nodePath),
      'section' => _renderSection(element, nodePath: nodePath),
      'details' => _renderDetails(element, nodePath: nodePath),
      'img' => _renderBlockImage(element),
      _ => _renderFallback(element),
    };
  }

  // -- Paragraph --

  Widget _renderParagraph(md.Element element) {
    final singleImage = _extractSingleImage(element);
    if (singleImage != null) {
      return Padding(
        padding: EdgeInsets.only(bottom: style.paragraphSpacing),
        child: _renderBlockImage(singleImage),
      );
    }

    final children = element.children;
    if (children == null || children.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: EdgeInsets.only(bottom: style.paragraphSpacing),
      child: Text.rich(inlineRenderer.render(children)),
    );
  }

  /// Returns the single `img` child if the paragraph
  /// contains exactly one child that is an `img` element.
  md.Element? _extractSingleImage(md.Element paragraph) {
    final children = paragraph.children;
    if (children == null || children.length != 1) {
      return null;
    }
    final child = children.first;
    if (child is md.Element && child.tag == 'img') {
      return child;
    }
    return null;
  }

  // -- Heading --

  Widget _renderHeading(md.Element element, int level) {
    final children = element.children;
    final span = (children != null && children.isNotEmpty)
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

  Widget _renderCodeBlock(md.Element element) {
    final codeElement = _extractCodeChild(element);
    final language = _extractLanguage(codeElement) ?? '';
    final code = (codeElement ?? element).textContent;

    if (language == 'mermaid') {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: style.codeBlockSpacing),
        child: ConduitMarkdown.buildMermaidBlock(context, code),
      );
    }

    if (language == 'html' && ConduitMarkdown.containsChartJs(code)) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: style.codeBlockSpacing),
        child: ConduitMarkdown.buildChartJsBlock(context, code),
      );
    }

    final conduitTheme = context.conduitTheme;
    final previewable = ConduitMarkdown.isPreviewableCodeBlock(language, code);
    final inlinePreview =
        previewable &&
        ConduitMarkdown.shouldInlinePreviewCodeBlock(language, code);

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

  /// Extracts the `<code>` child from a `<pre>` element.
  md.Element? _extractCodeChild(md.Element pre) {
    final children = pre.children;
    if (children == null) return null;
    for (final child in children) {
      if (child is md.Element && child.tag == 'code') {
        return child;
      }
    }
    return null;
  }

  /// Extracts the language from a code element's
  /// `class="language-xxx"` attribute.
  String? _extractLanguage(md.Element? code) {
    if (code == null) return null;
    final cls = code.attributes['class'] ?? '';
    if (!cls.startsWith('language-')) return null;
    return cls.substring('language-'.length);
  }

  // -- Blockquote --

  Widget _renderBlockquote(md.Element element, {required String nodePath}) {
    final children = element.children;
    if (children == null || children.isEmpty) {
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

  Widget _renderUnorderedList(md.Element element, {required String nodePath}) {
    final children = element.children ?? [];
    final items = <Widget>[];
    for (var index = 0; index < children.length; index++) {
      final child = children[index];
      if (child is md.Element && child.tag == 'li') {
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

  Widget _renderOrderedList(md.Element element, {required String nodePath}) {
    final startAttr = element.attributes['start'];
    final start = startAttr != null ? (int.tryParse(startAttr) ?? 1) : 1;

    final children = element.children ?? [];
    final items = <Widget>[];
    var index = start;
    for (var childIndex = 0; childIndex < children.length; childIndex++) {
      final child = children[childIndex];
      if (child is md.Element && child.tag == 'li') {
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
    md.Element element,
    String marker, {
    required String nodePath,
  }) {
    final children = element.children;
    final inlineNodes = <md.Node>[];
    final blockNodes = <md.Node>[];

    for (final child in children ?? const <md.Node>[]) {
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

  bool _appendInlineListChild(md.Node child, List<md.Node> inlineNodes) {
    if (child is md.Text) {
      _appendInlineChunkSeparator(inlineNodes);
      inlineNodes.add(child);
      return true;
    }

    if (child is! md.Element) {
      return false;
    }

    if (child.tag == 'p') {
      final singleImage = _extractSingleImage(child);
      final paragraphChildren = child.children;
      if (singleImage != null ||
          paragraphChildren == null ||
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

  void _appendInlineChunkSeparator(List<md.Node> inlineNodes) {
    if (inlineNodes.isEmpty) {
      return;
    }

    final lastNode = inlineNodes.last;
    if (lastNode is md.Text && RegExp(r'\s$').hasMatch(lastNode.text)) {
      return;
    }

    inlineNodes.add(md.Text(' '));
  }

  /// Returns `true` if [nodes] contain block-level
  /// elements like paragraphs, lists, or headings.
  bool _containsBlockElements(List<md.Node>? nodes) {
    if (nodes == null) return false;
    for (final node in nodes) {
      if (node is md.Element && _isBlockElementTag(node.tag)) {
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

  Widget _renderTable(md.Element element) {
    final columns = <DataColumn>[];
    final rows = <DataRow>[];

    for (final section in element.children ?? <md.Node>[]) {
      if (section is! md.Element) continue;
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

  void _parseTableHead(md.Element thead, List<DataColumn> columns) {
    for (final row in thead.children ?? <md.Node>[]) {
      if (row is! md.Element || row.tag != 'tr') continue;
      for (final cell in row.children ?? <md.Node>[]) {
        if (cell is! md.Element) continue;
        if (cell.tag != 'th' && cell.tag != 'td') continue;
        final children = cell.children;
        columns.add(
          DataColumn(
            label: (children != null && children.isNotEmpty)
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

  void _parseTableBody(md.Element tbody, List<DataRow> rows, int columnCount) {
    for (final row in tbody.children ?? <md.Node>[]) {
      if (row is! md.Element || row.tag != 'tr') continue;
      final cells = <DataCell>[];
      for (final cell in row.children ?? <md.Node>[]) {
        if (cell is! md.Element) continue;
        if (cell.tag != 'td' && cell.tag != 'th') continue;
        final children = cell.children;
        cells.add(
          DataCell(
            (children != null && children.isNotEmpty)
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

  Widget? _renderDiv(md.Element element, {required String nodePath}) {
    final cls = element.attributes['class'] ?? '';
    if (cls.contains('markdown-alert')) {
      return _renderAlert(element, cls, nodePath: nodePath);
    }
    return _renderFallback(element);
  }

  Widget _renderAlert(
    md.Element element,
    String cls, {
    required String nodePath,
  }) {
    final alertType = _parseAlertType(cls);
    final config = _alertConfig(alertType);

    final children = element.children ?? [];
    final contentNodes = <md.Node>[];
    String? titleText;

    // The first child is typically a <p> containing
    // the alert title marker.
    for (final child in children) {
      if (child is md.Element && child.tag == 'p' && titleText == null) {
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
    return switch (type) {
      'tip' => const _AlertConfig(
        color: Colors.green,
        icon: Icons.lightbulb_outline,
        label: 'Tip',
      ),
      'important' => const _AlertConfig(
        color: Colors.purple,
        icon: Icons.priority_high,
        label: 'Important',
      ),
      'warning' => const _AlertConfig(
        color: Colors.amber,
        icon: Icons.warning_amber,
        label: 'Warning',
      ),
      'caution' => const _AlertConfig(
        color: Colors.red,
        icon: Icons.error_outline,
        label: 'Caution',
      ),
      _ => const _AlertConfig(
        color: Colors.blue,
        icon: Icons.info_outline,
        label: 'Note',
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

  String? _extractAlertTitle(md.Element paragraph, String type) {
    final children = paragraph.children;
    if (children == null || children.isEmpty) return null;

    final firstChild = children.first;
    final text = firstChild is md.Text
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
  md.Element? _remainingAlertContent(md.Element paragraph) {
    final children = paragraph.children;
    if (children == null || children.isEmpty) return null;

    final firstChild = children.first;
    if (firstChild is! md.Text) return paragraph;

    final text = firstChild.text.trim();
    for (final marker in _alertMarkers) {
      if (text.startsWith(marker)) {
        final remaining = text.substring(marker.length).trim();
        final newChildren = <md.Node>[
          if (remaining.isNotEmpty) md.Text(remaining),
          ...children.skip(1),
        ];
        if (newChildren.isEmpty) return null;
        return md.Element('p', newChildren);
      }
    }
    // No marker found; return the whole paragraph.
    return paragraph;
  }

  // -- Section (footnotes) --

  Widget? _renderSection(md.Element element, {required String nodePath}) {
    final children = element.children;
    if (children == null || children.isEmpty) return null;
    final inner = BlockRenderer(
      context,
      style,
      inlineRenderer,
      latexPreprocessor,
      onLinkTap,
      imageBuilder,
      stateScopeId,
      nodePath,
    );
    return inner.renderBlocks(children);
  }

  // -- Details --

  Widget _renderDetails(md.Element element, {required String nodePath}) {
    final children = element.children ?? const <md.Node>[];
    String summaryText = '';
    var bodyStartIndex = 0;

    if (children.isNotEmpty) {
      final firstChild = children.first;
      if (firstChild is md.Element && firstChild.tag == 'summary') {
        summaryText = firstChild.textContent.trim();
        bodyStartIndex = 1;
      }
    }

    final bodyNodes = children.skip(bodyStartIndex).toList(growable: false);
    final hasBody = bodyNodes.any(_hasVisualContent);

    return MarkdownDetailsBlock(
      key: _detailsKey(element, summaryText, nodePath: nodePath),
      summaryText: summaryText,
      attributes: Map<String, String>.from(element.attributes),
      hasBody: hasBody,
      inlineExpansionStateId: _detailsStateId(
        element,
        summaryText,
        nodePath: nodePath,
      ),
      bodyBuilder: hasBody
          ? (context) {
              final inner = BlockRenderer(
                context,
                style,
                inlineRenderer,
                latexPreprocessor,
                onLinkTap,
                imageBuilder,
                stateScopeId,
                nodePath,
              );
              return inner.renderBlocks(bodyNodes);
            }
          : null,
    );
  }

  Key? _detailsKey(
    md.Element element,
    String summaryText, {
    required String nodePath,
  }) {
    final stateId = _detailsStateId(element, summaryText, nodePath: nodePath);
    if (stateId == null || stateId.isEmpty) {
      return null;
    }
    return ValueKey<String>(stateId);
  }

  String? _detailsStateId(
    md.Element element,
    String summaryText, {
    required String nodePath,
  }) {
    final detailType = element.attributes['type']?.trim();
    final usesInlineExpansion =
        detailType == 'reasoning' || detailType == 'code_interpreter';
    if (!usesInlineExpansion) {
      return null;
    }

    final toolName = element.attributes['name']?.trim();
    final normalizedSummary = summaryText.trim();

    if ((stateScopeId == null || stateScopeId!.isEmpty) &&
        (detailType == null || detailType.isEmpty) &&
        normalizedSummary.isEmpty &&
        (toolName == null || toolName.isEmpty)) {
      return null;
    }

    return [
      if (stateScopeId != null && stateScopeId!.isNotEmpty) stateScopeId,
      nodePath,
      if (detailType != null && detailType.isNotEmpty) detailType,
      if (toolName != null && toolName.isNotEmpty) toolName,
      if (normalizedSummary.isNotEmpty) normalizedSummary,
    ].join('|');
  }

  bool _hasVisualContent(md.Node node) {
    if (node is md.Text) {
      return node.text.trim().isNotEmpty;
    }
    if (node is! md.Element) {
      return false;
    }

    if (const {'img', 'hr'}.contains(node.tag)) {
      return true;
    }

    final children = node.children;
    if (children == null || children.isEmpty) {
      return node.textContent.trim().isNotEmpty;
    }

    for (final child in children) {
      if (_hasVisualContent(child)) {
        return true;
      }
    }
    return false;
  }

  // -- Block image --

  Widget? _renderBlockImage(md.Element element) {
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

  Widget? _renderFallback(md.Element element) {
    final children = element.children;
    if (children != null && children.isNotEmpty) {
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
