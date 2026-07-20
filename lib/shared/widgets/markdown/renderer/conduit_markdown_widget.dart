import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/performance_profiler.dart';
import '../../../../core/models/chat_message.dart';
import '../compiled_markdown_document.dart';
import '../markdown_compile_service.dart';
import '../markdown_document_controller.dart';
import '../markdown_loading_skeleton.dart';
import '../../../theme/theme_extensions.dart';
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
    this.enableStreamingTextFade = false,
    this.heavyBlockPolicy = MarkdownHeavyBlockPolicy.eager,
    this.trimLastBlockBottomPadding = true,
    this.debugTreatAsWidgetTest,
    this.debugOnCompiledViewMounted,
    this.debugOnCompiledViewDisposed,
    this.debugOnBaseRender,
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

  /// Whether newly appended visible text should fade while streaming.
  final bool enableStreamingTextFade;

  /// Controls how expensive preview-backed blocks should behave.
  final MarkdownHeavyBlockPolicy heavyBlockPolicy;

  /// Whether the final rendered root block should drop trailing paragraph
  /// spacing. Multi-part streaming renders keep spacing on non-final parts.
  final bool trimLastBlockBottomPadding;

  @visibleForTesting
  final bool? debugTreatAsWidgetTest;

  @visibleForTesting
  final VoidCallback? debugOnCompiledViewMounted;

  @visibleForTesting
  final VoidCallback? debugOnCompiledViewDisposed;

  @visibleForTesting
  final VoidCallback? debugOnBaseRender;

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
    final directDocument = widget.compiledDocument;
    if (directDocument?.isEmpty ?? _preparedData.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    final document = directDocument ?? _compiledDocument;
    if (document == null) {
      return MarkdownLoadingSkeleton(contentLength: _preparedData.length);
    }

    return _CompiledMarkdownView(
      document: document,
      onLinkTap: widget.onLinkTap,
      imageBuilder: widget.imageBuilder,
      sources: widget.sources,
      onSourceTap: widget.onSourceTap,
      stateScopeId: widget.stateScopeId,
      enableStreamingTextFade: widget.enableStreamingTextFade,
      heavyBlockPolicy: widget.heavyBlockPolicy,
      trimLastBlockBottomPadding: widget.trimLastBlockBottomPadding,
      debugOnMounted: widget.debugOnCompiledViewMounted,
      debugOnDisposed: widget.debugOnCompiledViewDisposed,
      debugOnBaseRender: widget.debugOnBaseRender,
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
      if (identical(_compiledDocument, directDocument) &&
          identical(_documentController.compiledDocument, directDocument)) {
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

  void _applyCompiledDocumentState(CompiledMarkdownDocument? document) {
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
    this.enableStreamingTextFade = false,
    this.heavyBlockPolicy = MarkdownHeavyBlockPolicy.eager,
    this.trimLastBlockBottomPadding = true,
    this.debugOnMounted,
    this.debugOnDisposed,
    this.debugOnBaseRender,
  });

  final CompiledMarkdownDocument document;
  final LinkTapCallback? onLinkTap;
  final ImageBuilder? imageBuilder;
  final List<ChatSourceReference>? sources;
  final void Function(int sourceIndex)? onSourceTap;
  final String? stateScopeId;
  final bool enableStreamingTextFade;
  final MarkdownHeavyBlockPolicy heavyBlockPolicy;
  final bool trimLastBlockBottomPadding;
  final VoidCallback? debugOnMounted;
  final VoidCallback? debugOnDisposed;
  final VoidCallback? debugOnBaseRender;

  @override
  State<_CompiledMarkdownView> createState() => _CompiledMarkdownViewState();
}

class _CompiledMarkdownViewState extends State<_CompiledMarkdownView>
    with SingleTickerProviderStateMixin
    implements MarkdownStreamingFade {
  InlineRenderer? _inlineRenderer;
  LatexPreprocessor _latexPreprocessor = LatexPreprocessor();
  late final AnimationController _streamingTextFadeController;
  late final CurvedAnimation _streamingTextFade;
  Future<void>? _latexStartupFuture;
  Timer? _latexStartupRetryTimer;
  int _latexStartupRetryCount = 0;
  int? _streamingTextFadeStartOffset;

  /// Cached base render, rebuilt only when the document identity (or a render
  /// input such as the resolved style / LaTeX startup future) changes — never
  /// per fade frame. Recognizer churn happens here, not in [build].
  CompiledMarkdownDocument? _renderedDocument;
  // Identity-stable theme inputs the derived style depends on. The style object
  // itself is freshly derived every build, so caching on it would never reuse;
  // these inputs only change when the theme/scaling actually changes.
  Object? _renderedThemeKey;
  TextTheme? _renderedTextTheme;
  TextScaler? _renderedTextScaler;
  Future<void>? _renderedLatexStartupFuture;
  MarkdownRenderTier? _renderedTier;
  // Widget-config inputs forwarded to the renderers. Any change must rebuild
  // the base tree (e.g. heavy-block policy flips defer->eager when streaming
  // ends and must re-hydrate previews).
  MarkdownHeavyBlockPolicy? _renderedHeavyBlockPolicy;
  bool? _renderedEnableStreamingTextFade;
  bool? _renderedTrimLastBlockBottomPadding;
  LinkTapCallback? _renderedOnLinkTap;
  List<ChatSourceReference>? _renderedSources;
  void Function(int sourceIndex)? _renderedOnSourceTap;
  ImageBuilder? _renderedImageBuilder;
  String? _renderedStateScopeId;
  Widget? _cachedView;

  @override
  Listenable get listenable => _streamingTextFade;

  @override
  InlineTextFadeSpec? get spec => _buildStreamingTextFadeSpec();

  @override
  void initState() {
    super.initState();
    widget.debugOnMounted?.call();
    _streamingTextFadeController = AnimationController(
      duration: const Duration(milliseconds: 320),
      vsync: this,
      value: 1,
    )..addListener(_handleStreamingTextFadeTick);
    _streamingTextFade = CurvedAnimation(
      parent: _streamingTextFadeController,
      curve: Curves.easeOutCubic,
    );
    _hydrateDocument(widget.document);
  }

  @override
  void didUpdateWidget(covariant _CompiledMarkdownView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.document != widget.document) {
      _primeStreamingTextFade(oldWidget.document, widget.document);
      _hydrateDocument(widget.document);
    } else if (!widget.enableStreamingTextFade &&
        oldWidget.enableStreamingTextFade) {
      _clearStreamingTextFade();
    }
  }

  @override
  void dispose() {
    _cancelLatexStartupRetry();
    widget.debugOnDisposed?.call();
    _inlineRenderer?.disposeRecognizers();
    _streamingTextFade.dispose();
    _streamingTextFadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final taskKey = PerformanceProfiler.instance.startTask(
      'markdown_build',
      scope: 'markdown',
      data: {
        'length': widget.document.normalizedContentLength,
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
      final themeKey = context.conduitTheme;
      final textTheme = Theme.of(context).textTheme;
      final textScaler = MediaQuery.textScalerOf(context);
      if (!_canReuseBaseRender(
        themeKey: themeKey,
        textTheme: textTheme,
        textScaler: textScaler,
      )) {
        final style = ConduitMarkdownStyle.fromTheme(context);
        _rebuildBaseRender(
          style,
          themeKey: themeKey,
          textTheme: textTheme,
          textScaler: textScaler,
        );
      }
      return _cachedView!;
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

  InlineTextFadeSpec? _buildStreamingTextFadeSpec() {
    final startOffset = _streamingTextFadeStartOffset;
    if (!widget.enableStreamingTextFade || startOffset == null) {
      return null;
    }
    final opacity = _streamingTextFade.value;
    if (opacity >= 1) {
      return null;
    }
    return InlineTextFadeSpec(startOffset: startOffset, opacity: opacity);
  }

  /// The streaming fade source for this view, or `null` when fading is disabled.
  ///
  /// When disabled the cached base render is shown directly with no animation
  /// listener, preserving the plain non-streaming render.
  MarkdownStreamingFade? _fadeSourceOrNull() {
    return widget.enableStreamingTextFade ? this : null;
  }

  bool _canReuseBaseRender({
    required Object themeKey,
    required TextTheme textTheme,
    required TextScaler textScaler,
  }) {
    return _cachedView != null &&
        identical(_renderedDocument, widget.document) &&
        identical(_renderedThemeKey, themeKey) &&
        _renderedTextTheme == textTheme &&
        _renderedTextScaler == textScaler &&
        identical(_renderedLatexStartupFuture, _latexStartupFuture) &&
        _renderedTier == widget.document.renderTier &&
        _renderedHeavyBlockPolicy == widget.heavyBlockPolicy &&
        _renderedEnableStreamingTextFade == widget.enableStreamingTextFade &&
        _renderedTrimLastBlockBottomPadding ==
            widget.trimLastBlockBottomPadding &&
        identical(_renderedOnLinkTap, widget.onLinkTap) &&
        identical(_renderedSources, widget.sources) &&
        identical(_renderedOnSourceTap, widget.onSourceTap) &&
        identical(_renderedImageBuilder, widget.imageBuilder) &&
        _renderedStateScopeId == widget.stateScopeId;
  }

  /// Rebuilds the opacity-1 base render after its cheap cache keys change.
  ///
  /// The span tree and gesture recognizers are produced once per content change
  /// (or when a render input such as the resolved [style] or LaTeX startup
  /// future changes). Fade frames reuse this cache, so they never rebuild the
  /// span tree or recreate [TapGestureRecognizer]s.
  void _rebuildBaseRender(
    ConduitMarkdownStyle style, {
    required Object themeKey,
    required TextTheme textTheme,
    required TextScaler textScaler,
  }) {
    widget.debugOnBaseRender?.call();

    // Recognizer churn happens here — once per content change — not per frame.
    _inlineRenderer?.disposeRecognizers();
    final inlineRenderer = InlineRenderer(
      style,
      _latexPreprocessor,
      widget.onLinkTap,
      widget.sources,
      widget.onSourceTap,
      _latexStartupFuture,
      widget.heavyBlockPolicy == MarkdownHeavyBlockPolicy.eager,
    );
    _inlineRenderer = inlineRenderer;

    _cachedView = switch (widget.document.renderTier) {
      MarkdownRenderTier.plainText => _buildPlainText(inlineRenderer, style),
      MarkdownRenderTier.richText => _buildRichText(inlineRenderer, style),
      MarkdownRenderTier.blocks =>
        BlockRenderer(
          context,
          style,
          inlineRenderer,
          _latexPreprocessor,
          widget.onLinkTap,
          widget.imageBuilder,
          widget.stateScopeId,
          null,
          widget.heavyBlockPolicy,
          _fadeSourceOrNull(),
        ).renderCompiledBlocks(
          widget.document.blocks,
          trimLastBlockBottomPadding: widget.trimLastBlockBottomPadding,
        ),
    };

    _renderedDocument = widget.document;
    _renderedThemeKey = themeKey;
    _renderedTextTheme = textTheme;
    _renderedTextScaler = textScaler;
    _renderedLatexStartupFuture = _latexStartupFuture;
    _renderedTier = widget.document.renderTier;
    _renderedHeavyBlockPolicy = widget.heavyBlockPolicy;
    _renderedEnableStreamingTextFade = widget.enableStreamingTextFade;
    _renderedTrimLastBlockBottomPadding = widget.trimLastBlockBottomPadding;
    _renderedOnLinkTap = widget.onLinkTap;
    _renderedSources = widget.sources;
    _renderedOnSourceTap = widget.onSourceTap;
    _renderedImageBuilder = widget.imageBuilder;
    _renderedStateScopeId = widget.stateScopeId;
  }

  void _invalidateBaseRender() {
    _renderedDocument = null;
    _renderedThemeKey = null;
    _renderedTextTheme = null;
    _renderedTextScaler = null;
    _renderedLatexStartupFuture = null;
    _renderedTier = null;
    _renderedHeavyBlockPolicy = null;
    _renderedEnableStreamingTextFade = null;
    _renderedTrimLastBlockBottomPadding = null;
    _renderedOnLinkTap = null;
    _renderedSources = null;
    _renderedOnSourceTap = null;
    _renderedImageBuilder = null;
    _renderedStateScopeId = null;
    _cachedView = null;
  }

  void _primeStreamingTextFade(
    CompiledMarkdownDocument previous,
    CompiledMarkdownDocument next,
  ) {
    if (!widget.enableStreamingTextFade) {
      _clearStreamingTextFade();
      return;
    }

    final previousText = _visibleTextContent(previous);
    final nextText = _visibleTextContent(next);
    if (previousText.isEmpty || nextText.length <= previousText.length) {
      _clearStreamingTextFade();
      return;
    }

    final commonPrefixLength = _commonPrefixLength(previousText, nextText);
    if (commonPrefixLength >= nextText.length) {
      _clearStreamingTextFade();
      return;
    }

    // Only fade when `next` is a true append of `previous`. Streaming markdown
    // is not strictly append-only: as content grows the compiler can
    // re-segment earlier text (e.g. a lone `*` becoming part of `**bold**`).
    // If the common prefix diverges before the end of `previousText`, fading
    // from that point would re-fade already-visible, stable text and flicker.
    if (commonPrefixLength < previousText.length) {
      _clearStreamingTextFade();
      return;
    }

    _streamingTextFadeStartOffset = commonPrefixLength;
    _streamingTextFadeController.value = 0;
    _streamingTextFadeController.forward();
  }

  void _clearStreamingTextFade() {
    _streamingTextFadeStartOffset = null;
    _streamingTextFadeController.value = 1;
  }

  void _handleStreamingTextFadeTick() {
    // Intermediate frames repaint via the [FadableRichText] AnimatedBuilders
    // that listen to [_streamingTextFade] directly, so the document subtree is
    // never rebuilt per frame. This listener only needs to settle the terminal
    // state: once the suffix reaches full opacity, drop the start offset so the
    // fade spec returns null and a later unrelated rebuild shows no stale fade.
    if (_streamingTextFadeStartOffset == null) {
      return;
    }
    if (_streamingTextFade.value >= 1) {
      _streamingTextFadeStartOffset = null;
    }
  }

  void _hydrateDocument(CompiledMarkdownDocument document) {
    // The document changed: the cached base span tree / block widgets and their
    // recognizers no longer match. Invalidate so the next build rebuilds them
    // once (recognizer churn happens here, not per fade frame).
    _invalidateBaseRender();
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

  Widget _buildPlainText(
    InlineRenderer inlineRenderer,
    ConduitMarkdownStyle style,
  ) {
    final text = _plainTextContent(widget.document);
    if (text.trim().isEmpty) {
      return const SizedBox.shrink();
    }
    final rendered = inlineRenderer.renderWithRanges([
      CompiledMarkdownText(text),
    ]);
    return FadableRichText(
      rendered: rendered,
      style: style,
      fade: _fadeSourceOrNull(),
    );
  }

  Widget _buildRichText(
    InlineRenderer inlineRenderer,
    ConduitMarkdownStyle style,
  ) {
    final inlineNodes = _richInlineNodes(widget.document);
    if (inlineNodes.isEmpty) {
      return _buildPlainText(inlineRenderer, style);
    }
    final rendered = inlineRenderer.renderWithRanges(inlineNodes);
    return FadableRichText(
      rendered: rendered,
      style: style,
      fade: _fadeSourceOrNull(),
    );
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

String _visibleTextContent(CompiledMarkdownDocument document) {
  return document.nodes.map((node) => node.textContent).join();
}

int _commonPrefixLength(String previous, String next) {
  final maxLength = previous.length < next.length
      ? previous.length
      : next.length;
  var index = 0;
  while (index < maxLength &&
      previous.codeUnitAt(index) == next.codeUnitAt(index)) {
    index += 1;
  }
  // The split offset is later used to slice TextSpans. Snap it off any
  // surrogate-pair boundary so the fade never splits a non-BMP character
  // (e.g. emoji) into lone surrogate halves, which would render as tofu/
  // replacement glyphs during the fade animation.
  if (index > 0 && index < next.length) {
    final highSurrogate = next.codeUnitAt(index - 1);
    final lowSurrogate = next.codeUnitAt(index);
    if (highSurrogate >= 0xD800 &&
        highSurrogate <= 0xDBFF &&
        lowSurrogate >= 0xDC00 &&
        lowSurrogate <= 0xDFFF) {
      index -= 1;
    }
  }
  return index;
}
