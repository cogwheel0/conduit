import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/models/chat_message.dart';
import '../compiled_markdown_document.dart';
import '../markdown_compile_service.dart';
import 'block_renderer.dart';
import 'inline_renderer.dart';
import 'latex_preprocessor.dart';
import 'markdown_style.dart';

@visibleForTesting
void debugResetParsedMarkdownCache() => debugResetCompiledMarkdownCache();

@visibleForTesting
int debugParsedMarkdownCacheSize() => debugCompiledMarkdownCacheSize();

@visibleForTesting
List<String> debugParsedMarkdownCacheKeys() => debugCompiledMarkdownCacheKeys();

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
class ConduitMarkdownWidget extends ConsumerStatefulWidget {
  /// Creates a markdown rendering widget.
  ///
  /// [data] is the raw markdown string. [onLinkTap] is
  /// called when the user taps a hyperlink. [imageBuilder]
  /// creates custom image widgets for block-level images.
  const ConduitMarkdownWidget({
    this.data,
    this.compiledDocument,
    this.dataIsPrepared = false,
    this.onLinkTap,
    this.imageBuilder,
    this.sources,
    this.onSourceTap,
    this.stateScopeId,
    this.heavyBlockPolicy = MarkdownHeavyBlockPolicy.eager,
    this.debugTreatAsWidgetTest,
    super.key,
  }) : assert(
         data != null || compiledDocument != null,
         'Either data or compiledDocument must be provided.',
       );

  /// The raw markdown content to render.
  final String? data;

  /// Optional compiled markdown document. When provided the widget skips
  /// async compilation and renders the document directly.
  final CompiledMarkdownDocument? compiledDocument;

  /// Whether [data] has already been normalized/prepared for markdown render.
  final bool dataIsPrepared;

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

  /// Controls how expensive preview-backed blocks should behave.
  final MarkdownHeavyBlockPolicy heavyBlockPolicy;

  @visibleForTesting
  final bool? debugTreatAsWidgetTest;

  @override
  ConsumerState<ConduitMarkdownWidget> createState() =>
      _ConduitMarkdownWidgetState();
}

class _ConduitMarkdownWidgetState extends ConsumerState<ConduitMarkdownWidget> {
  CompiledMarkdownDocument? _compiledDocument;
  String _preparedData = '';
  int _compileRequestId = 0;

  bool get _isWidgetTest =>
      widget.debugTreatAsWidgetTest ??
      WidgetsBinding.instance.runtimeType.toString().contains('Test');

  @override
  void initState() {
    super.initState();
    _primeDocument();
  }

  @override
  void didUpdateWidget(covariant ConduitMarkdownWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.compiledDocument != oldWidget.compiledDocument ||
        widget.data != oldWidget.data ||
        widget.dataIsPrepared != oldWidget.dataIsPrepared) {
      _primeDocument();
    }
  }

  @override
  Widget build(BuildContext context) {
    final prepared =
        widget.compiledDocument?.normalizedContent ?? _preparedData;
    if (prepared.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    final document = widget.compiledDocument ?? _compiledDocument;
    if (document == null) {
      return const SizedBox.shrink();
    }

    return _CompiledMarkdownView(
      document: document,
      onLinkTap: widget.onLinkTap,
      imageBuilder: widget.imageBuilder,
      sources: widget.sources,
      onSourceTap: widget.onSourceTap,
      stateScopeId: widget.stateScopeId,
      heavyBlockPolicy: widget.heavyBlockPolicy,
    );
  }

  void _primeDocument() {
    final directDocument = widget.compiledDocument;
    if (directDocument != null) {
      final nextPrepared = directDocument.normalizedContent;
      final changed =
          nextPrepared != _preparedData || _compiledDocument != directDocument;
      _preparedData = nextPrepared;
      _compileRequestId += 1;
      if (!changed) {
        return;
      }
      _setCompiledDocument(directDocument);
      return;
    }

    final raw = widget.data ?? '';
    final prepared = widget.dataIsPrepared
        ? raw
        : prepareMarkdownContent(raw, streaming: false);
    final preparedChanged = prepared != _preparedData;
    _preparedData = prepared;

    if (prepared.trim().isEmpty) {
      _compileRequestId += 1;
      _setCompiledDocument(const CompiledMarkdownDocument.empty());
      return;
    }

    final compiler = ref.read(markdownCompileServiceProvider);
    final cached = compiler.peekPrepared(prepared);
    if (cached != null) {
      _compileRequestId += 1;
      _setCompiledDocument(cached);
      return;
    }

    if (compiler.shouldCompileSynchronously(
      prepared,
      widgetTest: _isWidgetTest,
    )) {
      final syncDocument = compiler.compilePreparedSynchronously(prepared);
      _compileRequestId += 1;
      _setCompiledDocument(syncDocument);
      return;
    }

    final requestId = ++_compileRequestId;
    if (preparedChanged) {
      _setCompiledDocument(null);
    }
    unawaited(_loadPreparedDocument(prepared, requestId));
  }

  Future<void> _loadPreparedDocument(String prepared, int requestId) async {
    final compiler = ref.read(markdownCompileServiceProvider);
    final document = await compiler.compilePrepared(prepared);
    if (!mounted ||
        requestId != _compileRequestId ||
        prepared != _preparedData) {
      return;
    }
    _setCompiledDocument(document);
  }

  void _setCompiledDocument(CompiledMarkdownDocument? document) {
    if (!mounted) {
      _compiledDocument = document;
      return;
    }
    setState(() => _compiledDocument = document);
  }
}

class _CompiledMarkdownView extends StatefulWidget {
  const _CompiledMarkdownView({
    required this.document,
    this.onLinkTap,
    this.imageBuilder,
    this.sources,
    this.onSourceTap,
    this.stateScopeId,
    this.heavyBlockPolicy = MarkdownHeavyBlockPolicy.eager,
  });

  final CompiledMarkdownDocument document;
  final LinkTapCallback? onLinkTap;
  final ImageBuilder? imageBuilder;
  final List<ChatSourceReference>? sources;
  final void Function(int sourceIndex)? onSourceTap;
  final String? stateScopeId;
  final MarkdownHeavyBlockPolicy heavyBlockPolicy;

  @override
  State<_CompiledMarkdownView> createState() => _CompiledMarkdownViewState();
}

class _CompiledMarkdownViewState extends State<_CompiledMarkdownView> {
  InlineRenderer? _inlineRenderer;
  LatexPreprocessor _latexPreprocessor = LatexPreprocessor();

  @override
  void initState() {
    super.initState();
    _hydrateDocument(widget.document);
  }

  @override
  void didUpdateWidget(covariant _CompiledMarkdownView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.document != widget.document) {
      _hydrateDocument(widget.document);
    }
  }

  @override
  void dispose() {
    _inlineRenderer?.disposeRecognizers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.document.isEmpty) {
      return const SizedBox.shrink();
    }

    final style = ConduitMarkdownStyle.fromTheme(context);
    _inlineRenderer?.disposeRecognizers();
    _inlineRenderer = InlineRenderer(
      style,
      _latexPreprocessor,
      widget.onLinkTap,
      widget.sources,
      widget.onSourceTap,
    );

    final blockRenderer = BlockRenderer(
      context,
      style,
      _inlineRenderer!,
      _latexPreprocessor,
      widget.onLinkTap,
      widget.imageBuilder,
      widget.stateScopeId,
      null,
      widget.heavyBlockPolicy,
    );

    return switch (widget.document.renderTier) {
      MarkdownRenderTier.plainText => _buildPlainText(style),
      MarkdownRenderTier.richText => _buildRichText(style),
      MarkdownRenderTier.blocks => blockRenderer.renderCompiledBlocks(
        widget.document.blocks,
      ),
    };
  }

  void _hydrateDocument(CompiledMarkdownDocument document) {
    _latexPreprocessor = document.buildLatexPreprocessor();
  }

  Widget _buildPlainText(ConduitMarkdownStyle style) {
    final text = _plainTextContent(widget.document);
    if (text.trim().isEmpty) {
      return const SizedBox.shrink();
    }
    return Text(text, style: style.body);
  }

  Widget _buildRichText(ConduitMarkdownStyle style) {
    final inlineNodes = _richInlineNodes(widget.document);
    if (inlineNodes.isEmpty) {
      return _buildPlainText(style);
    }
    return Text.rich(_inlineRenderer!.render(inlineNodes));
  }
}

String _plainTextContent(CompiledMarkdownDocument document) {
  if (document.nodes.isEmpty) {
    return '';
  }

  final node = document.nodes.first;
  if (node is CompiledMarkdownText) {
    return node.text;
  }
  if (node is CompiledMarkdownElement &&
      node.tag == 'p' &&
      node.children.length == 1 &&
      node.children.first is CompiledMarkdownText) {
    return (node.children.first as CompiledMarkdownText).text;
  }
  return document.nodes.map((entry) => entry.textContent).join();
}

List<CompiledMarkdownNode> _richInlineNodes(CompiledMarkdownDocument document) {
  if (document.nodes.isEmpty) {
    return const <CompiledMarkdownNode>[];
  }

  final node = document.nodes.first;
  if (node is CompiledMarkdownElement && node.tag == 'p') {
    return node.children;
  }
  return <CompiledMarkdownNode>[node];
}
