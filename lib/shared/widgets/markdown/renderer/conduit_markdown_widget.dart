import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:markdown/markdown.dart' as md;

import '../../../../core/models/chat_message.dart';
import 'block_renderer.dart';
import 'details_block_syntax.dart';
import 'inline_renderer.dart';
import 'latex_preprocessor.dart';
import 'markdown_style.dart';
import 'mention_inline_syntax.dart';

final _parsedMarkdownCache = _ParsedMarkdownCache();

@visibleForTesting
void debugResetParsedMarkdownCache() => _parsedMarkdownCache.clear();

@visibleForTesting
int debugParsedMarkdownCacheSize() => _parsedMarkdownCache.length;

@visibleForTesting
List<String> debugParsedMarkdownCacheKeys() => _parsedMarkdownCache.keys;

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
    this.sources,
    this.onSourceTap,
    this.stateScopeId,
    super.key,
  });

  /// The raw markdown content to render.
  final String data;

  /// Callback invoked when a link is tapped.
  final LinkTapCallback? onLinkTap;

  /// Optional builder for block-level images.
  final ImageBuilder? imageBuilder;

  /// Optional source references for inline citation badges.
  final List<ChatSourceReference>? sources;

  /// Callback when an inline citation badge is tapped.
  final void Function(int sourceIndex)? onSourceTap;

  /// Optional scope used to preserve state for remounted markdown blocks.
  final String? stateScopeId;

  @override
  State<ConduitMarkdownWidget> createState() => _ConduitMarkdownWidgetState();
}

class _ConduitMarkdownWidgetState extends State<ConduitMarkdownWidget> {
  InlineRenderer? _inlineRenderer;
  _ParsedMarkdownDocument? _parsedDocument;
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
    if (data == _cachedData && _parsedDocument != null) {
      return;
    }

    _cachedData = data;
    _parsedDocument =
        _parsedMarkdownCache.read(data) ?? _parsedMarkdownCache.write(data);
  }

  @override
  Widget build(BuildContext context) {
    final style = ConduitMarkdownStyle.fromTheme(context);

    _ensureParsed(widget.data);
    final parsedDocument = _parsedDocument;
    if (parsedDocument == null) {
      return const SizedBox.shrink();
    }

    _inlineRenderer?.disposeRecognizers();
    _inlineRenderer = InlineRenderer(
      style,
      parsedDocument.latexPreprocessor,
      widget.onLinkTap,
      widget.sources,
      widget.onSourceTap,
    );

    final blockRenderer = BlockRenderer(
      context,
      style,
      _inlineRenderer!,
      parsedDocument.latexPreprocessor,
      widget.onLinkTap,
      widget.imageBuilder,
      widget.stateScopeId,
    );

    return blockRenderer.renderBlocks(parsedDocument.nodes);
  }
}

class _ParsedMarkdownDocument {
  _ParsedMarkdownDocument({
    required this.nodes,
    required this.latexPreprocessor,
  });

  final List<md.Node> nodes;
  final LatexPreprocessor latexPreprocessor;

  factory _ParsedMarkdownDocument.parse(String data) {
    final latexPreprocessor = LatexPreprocessor();
    final preprocessed = latexPreprocessor.extract(data);

    final document = md.Document(
      extensionSet: md.ExtensionSet.gitHubWeb,
      blockSyntaxes: const [DetailsBlockSyntax()],
      inlineSyntaxes: [MentionInlineSyntax()],
      encodeHtml: false,
    );
    return _ParsedMarkdownDocument(
      nodes: document.parse(preprocessed),
      latexPreprocessor: latexPreprocessor,
    );
  }
}

class _ParsedMarkdownCache {
  static const int _maxEntries = 32;

  final LinkedHashMap<String, _ParsedMarkdownDocument> _entries =
      LinkedHashMap<String, _ParsedMarkdownDocument>();

  _ParsedMarkdownDocument? read(String data) {
    final cached = _entries.remove(data);
    if (cached == null) {
      return null;
    }
    _entries[data] = cached;
    return cached;
  }

  _ParsedMarkdownDocument write(String data) {
    final parsed = _ParsedMarkdownDocument.parse(data);
    _entries.remove(data);
    _entries[data] = parsed;
    while (_entries.length > _maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    return parsed;
  }

  void clear() {
    _entries.clear();
  }

  int get length => _entries.length;

  List<String> get keys => List<String>.unmodifiable(_entries.keys);
}
