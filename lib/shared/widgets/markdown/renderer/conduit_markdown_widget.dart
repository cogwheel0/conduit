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
/// ```dart
/// ConduitMarkdownWidget(
///   data: '# Hello\n\nSome **bold** text.',
///   onLinkTap: (url, title) => launchUrl(Uri.parse(url)),
/// )
/// ```
class ConduitMarkdownWidget extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final style = ConduitMarkdownStyle.fromTheme(context);

    final latexPreprocessor = LatexPreprocessor();
    final preprocessed = latexPreprocessor.extract(data);

    final document = md.Document(
      extensionSet: md.ExtensionSet.gitHubWeb,
      encodeHtml: false,
    );
    final nodes = document.parse(preprocessed);

    final inlineRenderer = InlineRenderer(
      style,
      latexPreprocessor,
      onLinkTap,
    );

    final blockRenderer = BlockRenderer(
      context,
      style,
      inlineRenderer,
      latexPreprocessor,
      onLinkTap,
      imageBuilder,
    );

    return blockRenderer.renderBlocks(nodes);
  }
}
