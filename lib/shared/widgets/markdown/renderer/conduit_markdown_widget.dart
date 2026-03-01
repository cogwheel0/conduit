import 'package:flutter/material.dart';
import 'package:markdown/markdown.dart' as md;

import 'block_renderer.dart';
import 'inline_renderer.dart';
import 'latex_preprocessor.dart';
import 'markdown_style.dart';

/// A widget that renders markdown content using the
/// Conduit custom rendering pipeline.
///
/// The pipeline works in four stages:
/// 1. LaTeX expressions are extracted and replaced with
///    placeholder tokens.
/// 2. The sanitised markdown is parsed into an AST using
///    the `markdown` package with GitHub Web extensions.
/// 3. Block-level nodes are rendered as Flutter widgets.
/// 4. Inline nodes within blocks are rendered as
///    [InlineSpan] trees, restoring LaTeX placeholders
///    as widget spans.
///
/// The widget caches its parsed AST and only re-parses
/// when [data] changes, avoiding unnecessary
/// [TapGestureRecognizer] allocations during streaming.
///
/// ```dart
/// ConduitMarkdownWidget(
///   data: '# Hello\n\nSome **bold** text.',
///   onLinkTap: (url, title) => launchUrl(Uri.parse(url)),
/// )
/// ```
class ConduitMarkdownWidget extends StatefulWidget {
  /// Creates a markdown rendering widget.
  ///
  /// [data] is the raw markdown string. [onLinkTap] is
  /// called when the user taps a hyperlink. [imageBuilder]
  /// creates custom image widgets for block-level images.
  const ConduitMarkdownWidget({
    required this.data,
    this.onLinkTap,
    this.imageBuilder,
    super.key,
  });

  /// The raw markdown content to render.
  final String data;

  /// Callback invoked when a link is tapped.
  final LinkTapCallback? onLinkTap;

  /// Optional builder for block-level images.
  final ImageBuilder? imageBuilder;

  @override
  State<ConduitMarkdownWidget> createState() =>
      _ConduitMarkdownWidgetState();
}

class _ConduitMarkdownWidgetState
    extends State<ConduitMarkdownWidget> {
  LatexPreprocessor _latexPreprocessor = LatexPreprocessor();
  InlineRenderer? _inlineRenderer;
  List<md.Node> _nodes = [];
  String _cachedData = '';

  @override
  void dispose() {
    _inlineRenderer?.disposeRecognizers();
    super.dispose();
  }

  /// Parses the markdown [data] into an AST, caching the
  /// result. Only re-parses when [data] differs from the
  /// previously cached value.
  void _ensureParsed(String data) {
    if (data == _cachedData && _nodes.isNotEmpty) return;

    _inlineRenderer?.disposeRecognizers();
    _cachedData = data;

    _latexPreprocessor = LatexPreprocessor();
    final preprocessed = _latexPreprocessor.extract(data);

    final document = md.Document(
      extensionSet: md.ExtensionSet.gitHubWeb,
      encodeHtml: false,
    );
    _nodes = document.parse(preprocessed);
  }

  @override
  Widget build(BuildContext context) {
    final style =
        ConduitMarkdownStyle.fromTheme(context);

    _ensureParsed(widget.data);

    _inlineRenderer?.disposeRecognizers();
    _inlineRenderer = InlineRenderer(
      style,
      _latexPreprocessor,
      widget.onLinkTap,
    );

    final blockRenderer = BlockRenderer(
      context,
      style,
      _inlineRenderer!,
      _latexPreprocessor,
      widget.onLinkTap,
      widget.imageBuilder,
    );

    return blockRenderer.renderBlocks(_nodes);
  }
}
