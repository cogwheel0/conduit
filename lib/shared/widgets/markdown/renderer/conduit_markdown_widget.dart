import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/performance_profiler.dart';
import '../../../../core/models/chat_message.dart';
import '../compiled_markdown_document.dart';
import '../markdown_compile_service.dart';
import '../markdown_document_controller.dart';
import '../markdown_loading_skeleton.dart';
import 'block_renderer.dart';
import 'inline_renderer.dart';
import 'latex_preprocessor.dart';
import 'latex_rendering_server.dart';
import 'markdown_style.dart';

@visibleForTesting
const int debugMaxLatexStartupRetryCount = 5;

const int _maxLatexStartupRetryCount = debugMaxLatexStartupRetryCount;

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
    this.debugOnCompiledViewMounted,
    this.debugOnCompiledViewDisposed,
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

  @visibleForTesting
  final VoidCallback? debugOnCompiledViewMounted;

  @visibleForTesting
  final VoidCallback? debugOnCompiledViewDisposed;

  @override
  ConsumerState<ConduitMarkdownWidget> createState() =>
      _ConduitMarkdownWidgetState();
}

class _ConduitMarkdownWidgetState extends ConsumerState<ConduitMarkdownWidget> {
  late final MarkdownDocumentController _documentController;
  CompiledMarkdownDocument? _compiledDocument;
  String _preparedData = '';

  bool get _isWidgetTest =>
      widget.debugTreatAsWidgetTest ??
      WidgetsBinding.instance.runtimeType.toString().contains('Test');

  @override
  void initState() {
    super.initState();
    _documentController = MarkdownDocumentController(
      readCompiler: () => ref.read(markdownCompileServiceProvider),
      isWidgetTest: () => _isWidgetTest,
      onStateChanged: _applyCompiledDocumentState,
    );
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
      return MarkdownLoadingSkeleton(contentLength: prepared.length);
    }

    return _CompiledMarkdownView(
      document: document,
      onLinkTap: widget.onLinkTap,
      imageBuilder: widget.imageBuilder,
      sources: widget.sources,
      onSourceTap: widget.onSourceTap,
      stateScopeId: widget.stateScopeId,
      heavyBlockPolicy: widget.heavyBlockPolicy,
      debugOnMounted: widget.debugOnCompiledViewMounted,
      debugOnDisposed: widget.debugOnCompiledViewDisposed,
    );
  }

  @override
  void dispose() {
    _documentController.dispose();
    super.dispose();
  }

  void _primeDocument() {
    final directDocument = widget.compiledDocument;
    if (directDocument != null) {
      final nextPrepared = directDocument.normalizedContent;
      final changed =
          nextPrepared != _preparedData || _compiledDocument != directDocument;
      _preparedData = nextPrepared;
      if (!changed) {
        return;
      }
      _documentController.applyDirectDocument(directDocument);
      return;
    }

    final raw = widget.data ?? '';
    final prepared = widget.dataIsPrepared
        ? raw
        : prepareMarkdownContent(raw, streaming: false);
    _preparedData = prepared;
    _documentController.resolvePrepared(prepared, clearDocumentWhenAsync: true);
  }

  void _applyCompiledDocumentState(
    String compiledPreparedContent,
    CompiledMarkdownDocument? document,
  ) {
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
    this.debugOnMounted,
    this.debugOnDisposed,
  });

  final CompiledMarkdownDocument document;
  final LinkTapCallback? onLinkTap;
  final ImageBuilder? imageBuilder;
  final List<ChatSourceReference>? sources;
  final void Function(int sourceIndex)? onSourceTap;
  final String? stateScopeId;
  final MarkdownHeavyBlockPolicy heavyBlockPolicy;
  final VoidCallback? debugOnMounted;
  final VoidCallback? debugOnDisposed;

  @override
  State<_CompiledMarkdownView> createState() => _CompiledMarkdownViewState();
}

class _CompiledMarkdownViewState extends State<_CompiledMarkdownView> {
  InlineRenderer? _inlineRenderer;
  LatexPreprocessor _latexPreprocessor = LatexPreprocessor();
  Future<void>? _latexStartupFuture;
  Timer? _latexStartupRetryTimer;
  int _latexStartupRetryCount = 0;

  @override
  void initState() {
    super.initState();
    widget.debugOnMounted?.call();
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
    _cancelLatexStartupRetry();
    widget.debugOnDisposed?.call();
    _inlineRenderer?.disposeRecognizers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final taskKey = PerformanceProfiler.instance.startTask(
      'markdown_build',
      scope: 'markdown',
      data: {
        'length': widget.document.normalizedContent.length,
        'tier': widget.document.renderTier,
        'heavyBlocks': widget.document.heavyBlockCount,
      },
    );
    if (widget.document.isEmpty) {
      PerformanceProfiler.instance.finishTask(
        taskKey,
        data: const {'status': 'empty'},
      );
      return const SizedBox.shrink();
    }

    try {
      final style = ConduitMarkdownStyle.fromTheme(context);
      _inlineRenderer?.disposeRecognizers();
      _inlineRenderer = InlineRenderer(
        style,
        _latexPreprocessor,
        widget.onLinkTap,
        widget.sources,
        widget.onSourceTap,
        _latexStartupFuture,
        widget.heavyBlockPolicy == MarkdownHeavyBlockPolicy.eager,
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
    } finally {
      PerformanceProfiler.instance.finishTask(
        taskKey,
        data: {
          'tier': widget.document.renderTier,
          'nodeCount': widget.document.nodes.length,
          'blockCount': widget.document.blocks.length,
        },
      );
    }
  }

  void _hydrateDocument(CompiledMarkdownDocument document) {
    _cancelLatexStartupRetry();
    _latexStartupRetryCount = 0;
    _latexPreprocessor = document.buildLatexPreprocessor();
    if (!document.hasLatex) {
      _latexStartupFuture = null;
      return;
    }
    _startLatexStartup();
  }

  void _startLatexStartup({bool notify = false}) {
    final startupFuture = LatexRenderingServer.ensureStarted();
    if (notify && mounted) {
      setState(() {
        _latexStartupFuture = startupFuture;
      });
    } else {
      _latexStartupFuture = startupFuture;
    }

    unawaited(
      startupFuture.then<void>(
        (_) {
          if (!mounted || !identical(_latexStartupFuture, startupFuture)) {
            return;
          }
          _latexStartupRetryCount = 0;
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!mounted ||
              !identical(_latexStartupFuture, startupFuture) ||
              !widget.document.hasLatex ||
              LatexRenderingServer.isStarted) {
            return;
          }
          _scheduleLatexStartupRetry();
        },
      ),
    );
  }

  void _scheduleLatexStartupRetry() {
    if (_latexStartupRetryTimer != null) {
      return;
    }
    if (_latexStartupRetryCount >= _maxLatexStartupRetryCount) {
      return;
    }

    final delay = _latexStartupRetryDelay(_latexStartupRetryCount);
    _latexStartupRetryCount += 1;
    _latexStartupRetryTimer = Timer(delay, () {
      _latexStartupRetryTimer = null;
      if (!mounted ||
          !widget.document.hasLatex ||
          LatexRenderingServer.isStarted) {
        return;
      }
      _startLatexStartup(notify: true);
    });
  }

  void _cancelLatexStartupRetry() {
    _latexStartupRetryTimer?.cancel();
    _latexStartupRetryTimer = null;
  }

  Duration _latexStartupRetryDelay(int retryCount) {
    final clampedRetryCount = retryCount.clamp(0, 3);
    return Duration(milliseconds: 200 * (1 << clampedRetryCount));
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
