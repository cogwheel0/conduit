import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/chat_message.dart';
import '../../utils/ask_conduit_context_menu.dart';
import '../responsive_drawer_layout.dart';
import 'compiled_markdown_document.dart';
import 'markdown_config.dart';
import 'markdown_compile_service.dart';
import 'markdown_display_part.dart';
import 'markdown_document_controller.dart';
import 'markdown_loading_skeleton.dart';
import 'renderer/block_renderer.dart';
import 'renderer/conduit_markdown_widget.dart';

@visibleForTesting
Map<String, Object> buildStreamingMarkdownSnapshotForTesting(
  String content, {
  bool streaming = true,
}) {
  return _buildMarkdownSnapshot(content, streaming: streaming).toMap();
}

_MarkdownRenderSnapshot _buildMarkdownSnapshot(
  String content, {
  required bool streaming,
}) {
  return _MarkdownRenderSnapshot.full(
    prepareMarkdownContent(content, streaming: streaming),
  );
}

class _MarkdownRenderSnapshot {
  const _MarkdownRenderSnapshot({required this.normalizedContent});

  const _MarkdownRenderSnapshot.empty() : normalizedContent = '';

  const _MarkdownRenderSnapshot.full(this.normalizedContent);

  final String normalizedContent;

  Map<String, Object> toMap() => {'normalizedContent': normalizedContent};

  @override
  bool operator ==(Object other) {
    return other is _MarkdownRenderSnapshot &&
        other.normalizedContent == normalizedContent;
  }

  @override
  int get hashCode => normalizedContent.hashCode;
}

class StreamingMarkdownWidget extends ConsumerStatefulWidget {
  const StreamingMarkdownWidget({
    super.key,
    required this.content,
    required this.isStreaming,
    this.onTapLink,
    this.imageBuilderOverride,
    this.sources,
    this.onSourceTap,
    this.askConduitComposerTargetId,
    this.stateScopeId,
    this.enableStreamingTextFade = true,
    this.debugTreatAsWidgetTest,
    this.debugRenderInterval,
    this.debugOnCompiledViewMounted,
    this.debugOnCompiledViewDisposed,
    this.debugOnStreamingRefreshFrame,
    this.debugOnBaseRender,
  });

  final String content;
  final bool isStreaming;
  final MarkdownLinkTapCallback? onTapLink;
  final Widget Function(Uri uri, String? title, String? alt)?
  imageBuilderOverride;

  /// Sources for inline citation badge rendering.
  /// When provided, [1] patterns will be rendered as clickable badges.
  final List<ChatSourceReference>? sources;

  /// Callback when a source badge is tapped.
  final void Function(int sourceIndex)? onSourceTap;

  /// Composer target that should receive "Ask Conduit" insertions.
  ///
  /// When null, this markdown surface uses Flutter's default selection menu.
  final String? askConduitComposerTargetId;

  /// Optional scope used to preserve state for remounted markdown blocks.
  final String? stateScopeId;

  /// Controls fading newly appended visible text while streaming.
  ///
  /// This stays enabled by default for existing standalone callers. Live chat
  /// explicitly disables it so token updates remain immediate; low-frequency
  /// preview surfaces can retain the decorative reveal.
  final bool enableStreamingTextFade;

  @visibleForTesting
  final bool? debugTreatAsWidgetTest;

  @visibleForTesting
  final Duration? debugRenderInterval;

  @visibleForTesting
  final VoidCallback? debugOnCompiledViewMounted;

  @visibleForTesting
  final VoidCallback? debugOnCompiledViewDisposed;

  @visibleForTesting
  final VoidCallback? debugOnStreamingRefreshFrame;

  /// Invoked each time the compiled view rebuilds its cached base span tree
  /// (once per content change, never per fade frame).
  @visibleForTesting
  final VoidCallback? debugOnBaseRender;

  @override
  ConsumerState<StreamingMarkdownWidget> createState() =>
      _StreamingMarkdownWidgetState();
}

class _StreamingMarkdownWidgetState
    extends ConsumerState<StreamingMarkdownWidget>
    with WidgetsBindingObserver {
  late final MarkdownDocumentController _documentController;
  final GlobalKey _markdownContentKey = GlobalKey();
  final Map<String, CompiledMarkdownDocument> _displayPartDocumentCache =
      <String, CompiledMarkdownDocument>{};
  // Unique per-instance prefix used when no stateScopeId is supplied, so two
  // scope-less StreamingMarkdownWidgets on the same route don't share
  // PageStorage keys (markdown_compile_service reuses block ids across unrelated
  // documents, so a raw partId is not unique on its own).
  static int _scopelessInstanceCounter = 0;
  late final String _scopelessFallbackScopeId =
      'sm${_scopelessInstanceCounter++}';
  _MarkdownRenderSnapshot _snapshot = const _MarkdownRenderSnapshot.empty();
  Timer? _debugStreamingDelayTimer;
  bool _snapshotInFlight = false;
  bool _settledSnapshotInFlight = false;
  bool _settledPreparationPending = false;
  ({String content, int generation, bool clearStaleDocument})?
  _pendingSettledSnapshot;
  bool _streamingRefreshFrameScheduled = false;
  String? _pendingStreamingContent;
  String? _selectedText;
  int _snapshotGeneration = 0;
  bool _isAppForeground = true;
  bool _isRouteVisible = true;

  CompiledMarkdownDocument? get _compiledDocument =>
      _documentController.compiledDocument;

  String get _compiledPreparedContent =>
      _documentController.compiledPreparedContent;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _isAppForeground = _isLifecycleForeground(
      WidgetsBinding.instance.lifecycleState,
    );
    _documentController = MarkdownDocumentController(
      readCompiler: () => ref.read(markdownCompileServiceProvider),
      isWidgetTest: () => _isWidgetTest,
      onStateChanged: _applyCompiledDocumentState,
    );
    final compiler = ref.read(markdownCompileServiceProvider);
    if (compiler.shouldPrepareSynchronously(
      widget.content,
      widgetTest: _isWidgetTest,
    )) {
      _snapshot = _buildMarkdownSnapshot(
        widget.content,
        streaming: widget.isStreaming,
      );
      _resolveCompiledDocument(_snapshot);
    } else if (widget.content.trim().isNotEmpty) {
      // Long normalization performs several full-string passes. Keep it off
      // the first UI frame and let the existing generation checks reject stale
      // results if a stream advances before preparation completes.
      if (widget.isStreaming) {
        if (widget.content.length > markdownSynchronousPrepareThreshold) {
          // Route a long initial snapshot through the same coalescing window as
          // subsequent token updates. Starting it immediately would make the
          // seed snapshot consume a worker slot even when a newer stream value
          // arrives during the first frame.
          _markPendingStreamingContent(widget.content);
          _scheduleStreamingRefresh();
        } else {
          // Test doubles and platform-specific backends may still request the
          // async path for small inputs. Those are cheap and should remain
          // available on the initial frame.
          unawaited(_refreshStreamingSnapshot(widget.content));
        }
      } else {
        final generation = ++_snapshotGeneration;
        _queueSettledSnapshot(widget.content, generation: generation);
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateRouteVisibility();
  }

  @override
  void didUpdateWidget(covariant StreamingMarkdownWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    final scopeChanged = widget.stateScopeId != oldWidget.stateScopeId;
    if (!identical(widget.sources, oldWidget.sources) ||
        widget.onSourceTap != oldWidget.onSourceTap ||
        widget.onTapLink != oldWidget.onTapLink ||
        widget.imageBuilderOverride != oldWidget.imageBuilderOverride ||
        scopeChanged) {
      setState(() {});
    }
    if (widget.content == oldWidget.content &&
        widget.isStreaming == oldWidget.isStreaming) {
      return;
    }

    if (!widget.isStreaming) {
      _invalidatePendingAsyncSnapshot();
      final compiler = ref.read(markdownCompileServiceProvider);
      if (compiler.shouldPrepareSynchronously(
        widget.content,
        widgetTest: _isWidgetTest,
      )) {
        _settledPreparationPending = false;
        _applyPreparedSnapshotIfNeeded(
          prepareMarkdownContent(widget.content, streaming: false),
          // A scope change means a new message/version, not a continuation of
          // the current content. Clear stale content while the new body compiles.
          clearStaleDocument: scopeChanged,
        );
      } else {
        if (scopeChanged) {
          _documentController.clearDocument();
        }
        final generation = _snapshotGeneration;
        _queueSettledSnapshot(
          widget.content,
          generation: generation,
          clearStaleDocument: scopeChanged,
        );
      }
      return;
    }

    final compiler = ref.read(markdownCompileServiceProvider);
    if (_canActivelyRefreshStreamingMarkdown &&
        compiler.shouldPrepareSynchronously(
          widget.content,
          widgetTest: _isWidgetTest,
        )) {
      final preparedContent = prepareMarkdownContent(
        widget.content,
        streaming: true,
      );
      if (_needsPreparedSnapshotUpdate(preparedContent)) {
        widget.debugOnStreamingRefreshFrame?.call();
      }
      _invalidatePendingAsyncSnapshot();
      _applyPreparedSnapshotIfNeeded(
        preparedContent,
        clearStaleDocument: scopeChanged,
      );
      return;
    }

    // Deferred streaming path: the body needs an async compile, so the new
    // document won't be ready this frame. On a scope change, clear the previous
    // scope's document now — deferring the clear to the scheduled refresh would
    // let the old document paint for one frame under the new scope (#541). The
    // scheduled refresh below then compiles the new content. (The sync paths
    // above clear/replace the document synchronously and don't need this.)
    // A settled preparation may still be running from the previous widget
    // state. Its generation check prevents publication, while clearing its
    // queued successor and loading flag keeps streaming blank until its own
    // snapshot is ready (streaming must never show the settled skeleton).
    _pendingSettledSnapshot = null;
    _settledPreparationPending = false;
    if (scopeChanged) {
      _documentController.clearDocument();
    }
    _markPendingStreamingContent(widget.content);
    _scheduleStreamingRefresh();
  }

  bool get _isWidgetTest =>
      widget.debugTreatAsWidgetTest ??
      WidgetsBinding.instance.runtimeType.toString().contains('Test');

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debugStreamingDelayTimer?.cancel();
    _documentController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final nextIsForeground = _isLifecycleForeground(state);
    if (_isAppForeground == nextIsForeground) {
      return;
    }
    _isAppForeground = nextIsForeground;
    _handleStreamingRefreshVisibilityChanged();
  }

  void _scheduleStreamingRefresh() {
    if (!widget.isStreaming || !_canActivelyRefreshStreamingMarkdown) {
      _debugStreamingDelayTimer?.cancel();
      _debugStreamingDelayTimer = null;
      return;
    }
    if (_streamingRefreshFrameScheduled || _debugStreamingDelayTimer != null) {
      return;
    }
    final interval = _isWidgetTest ? Duration.zero : widget.debugRenderInterval;
    if (interval != null && interval > Duration.zero) {
      _debugStreamingDelayTimer = Timer(
        interval,
        _scheduleStreamingRefreshFrame,
      );
      return;
    }
    _scheduleStreamingRefreshFrame();
  }

  void _invalidatePendingAsyncSnapshot() {
    _debugStreamingDelayTimer?.cancel();
    _debugStreamingDelayTimer = null;
    _pendingStreamingContent = null;
    _pendingSettledSnapshot = null;
    _settledPreparationPending = false;
    _snapshotGeneration += 1;
    _documentController.invalidatePending();
  }

  void _markPendingStreamingContent(String content) {
    if (_pendingStreamingContent == content) {
      return;
    }
    _pendingStreamingContent = content;
    _snapshotGeneration += 1;
  }

  void _scheduleStreamingRefreshFrame() {
    _debugStreamingDelayTimer?.cancel();
    _debugStreamingDelayTimer = null;
    if (!widget.isStreaming ||
        !_canActivelyRefreshStreamingMarkdown ||
        _streamingRefreshFrameScheduled ||
        _snapshotInFlight) {
      return;
    }
    _streamingRefreshFrameScheduled = true;
    // Start preparation before the build phase. A post-frame callback would
    // consume a platform-view composition frame just to launch the work, then
    // require another frame to show the result. The native Liquid Glass chrome
    // stays mounted; only the mutable Markdown tail is refreshed.
    WidgetsBinding.instance.scheduleFrameCallback((_) {
      _streamingRefreshFrameScheduled = false;
      if (!mounted ||
          !widget.isStreaming ||
          !_canActivelyRefreshStreamingMarkdown) {
        return;
      }
      final pendingContent = _pendingStreamingContent;
      if (pendingContent == null) {
        return;
      }
      if (_snapshotInFlight) {
        return;
      }
      widget.debugOnStreamingRefreshFrame?.call();
      _pendingStreamingContent = null;
      unawaited(_refreshStreamingSnapshot(pendingContent));
    });
  }

  Future<void> _refreshStreamingSnapshot(String content) async {
    if (_snapshotInFlight) {
      _markPendingStreamingContent(content);
      return;
    }

    _snapshotInFlight = true;
    final generation = _snapshotGeneration;
    try {
      final compiler = ref.read(markdownCompileServiceProvider);
      if (compiler.shouldPrepareSynchronously(
        content,
        widgetTest: _isWidgetTest,
      )) {
        final synchronousPrepared = prepareMarkdownContent(
          content,
          streaming: true,
        );
        _applyPreparedSnapshotIfNeeded(synchronousPrepared);
        return;
      }
      final preparedContent = await compiler.prepareContent(
        content,
        streaming: true,
      );
      if (!mounted || generation != _snapshotGeneration) {
        return;
      }
      _applyPreparedSnapshotIfNeeded(preparedContent);
    } catch (_) {
      if (!mounted || generation != _snapshotGeneration) {
        return;
      }
      _applyPreparedSnapshotIfNeeded(
        prepareMarkdownContent(content, streaming: true),
      );
    } finally {
      _snapshotInFlight = false;
      if (_pendingStreamingContent != null &&
          (generation != _snapshotGeneration ||
              _pendingStreamingContent != content) &&
          mounted) {
        _scheduleStreamingRefresh();
      }
    }
  }

  Future<void> _refreshSettledSnapshot(
    String content, {
    required int generation,
    bool clearStaleDocument = false,
  }) async {
    String preparedContent;
    try {
      preparedContent = await ref
          .read(markdownCompileServiceProvider)
          .prepareContent(content, streaming: false);
    } catch (_) {
      // Preserve rendering if the long-lived worker is unavailable. The
      // service normally handles this fallback itself; this also protects test
      // doubles and unexpected disposal races.
      preparedContent = prepareMarkdownContent(content, streaming: false);
    }
    if (!mounted ||
        generation != _snapshotGeneration ||
        widget.isStreaming ||
        widget.content != content) {
      return;
    }

    final needsUpdate = _needsPreparedSnapshotUpdate(preparedContent);
    _settledPreparationPending = false;
    if (needsUpdate) {
      _applyPreparedSnapshotIfNeeded(
        preparedContent,
        clearStaleDocument: clearStaleDocument,
      );
    } else {
      setState(() {});
    }
  }

  void _queueSettledSnapshot(
    String content, {
    required int generation,
    bool clearStaleDocument = false,
  }) {
    final previous = _pendingSettledSnapshot;
    _pendingSettledSnapshot = (
      content: content,
      generation: generation,
      clearStaleDocument:
          clearStaleDocument || (previous?.clearStaleDocument ?? false),
    );
    _settledPreparationPending = true;
    if (!_settledSnapshotInFlight) {
      unawaited(_drainSettledSnapshots());
    }
  }

  Future<void> _drainSettledSnapshots() async {
    if (_settledSnapshotInFlight) return;
    _settledSnapshotInFlight = true;
    try {
      while (mounted) {
        final pending = _pendingSettledSnapshot;
        if (pending == null) break;
        _pendingSettledSnapshot = null;
        await _refreshSettledSnapshot(
          pending.content,
          generation: pending.generation,
          clearStaleDocument: pending.clearStaleDocument,
        );
      }
    } finally {
      _settledSnapshotInFlight = false;
      if (mounted && _pendingSettledSnapshot != null) {
        unawaited(_drainSettledSnapshots());
      }
    }
  }

  void _applySnapshot(
    _MarkdownRenderSnapshot nextSnapshot, {
    bool clearStaleDocument = false,
  }) {
    final changed = _snapshot != nextSnapshot;
    if (!changed) {
      if (_compiledDocument == null ||
          _compiledPreparedContent != nextSnapshot.normalizedContent) {
        _resolveCompiledDocument(
          nextSnapshot,
          clearStaleDocument: clearStaleDocument,
        );
      }
      return;
    }
    if (!mounted) {
      _snapshot = nextSnapshot;
      _resolveCompiledDocument(
        nextSnapshot,
        clearStaleDocument: clearStaleDocument,
      );
      return;
    }
    setState(() => _snapshot = nextSnapshot);
    _resolveCompiledDocument(
      nextSnapshot,
      clearStaleDocument: clearStaleDocument,
    );
  }

  /// Adapts the legacy [imageBuilderOverride] callback
  /// to the [ImageBuilder] signature used by the custom
  /// renderer.
  ImageBuilder? _adaptImageBuilder() {
    final override = widget.imageBuilderOverride;
    if (override == null) return null;
    return (String src, String? alt, String? title) {
      final uri = Uri.tryParse(src);
      if (uri == null) return const SizedBox.shrink();
      return override(uri, title, alt);
    };
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    if (snapshot.normalizedContent.trim().isEmpty) {
      if (_settledPreparationPending && widget.content.trim().isNotEmpty) {
        return MarkdownLoadingSkeleton(contentLength: widget.content.length);
      }
      return const SizedBox.shrink();
    }

    final compiledDocument = _compiledDocument;
    final hasFreshCompiledDocument =
        compiledDocument != null &&
        _compiledPreparedContent == snapshot.normalizedContent;
    if (_shouldShowLoadingSkeleton(
      snapshot: snapshot,
      compiledDocument: compiledDocument,
      hasFreshCompiledDocument: hasFreshCompiledDocument,
    )) {
      return MarkdownLoadingSkeleton(
        contentLength: snapshot.normalizedContent.length,
      );
    }
    if (compiledDocument == null) {
      return const SizedBox.shrink();
    }
    // Once a compiled document exists, always render it — even when it is stale
    // (a newer snapshot is still compiling). Replacing already-rendered content
    // with a placeholder/blank causes the streaming body to flash whenever the
    // turn phase flips to non-streaming mid-response (issue #540). The stale
    // document is valid markdown and is superseded by `_applyCompiledDocumentState`
    // within a frame once the fresh compile lands.

    final result = KeyedSubtree(
      key: _markdownContentKey,
      child: _buildMarkdownDisplayParts(compiledDocument),
    );

    // Only wrap in SelectionArea when not streaming, no settled normalization
    // is pending, AND the rendered document is fresh for the current content.
    // A stale/equivalent document shown during ongoing updates (the
    // responseDone-gap growing-content path that #540's fix now keeps on screen)
    // must not be made selectable: SelectionArea over rapidly-changing content
    // triggers concurrent-modification errors in Flutter's selection system.
    if (widget.isStreaming ||
        _settledPreparationPending ||
        !hasFreshCompiledDocument) {
      return result;
    }

    return DrawerOpenGestureExclusion(
      child: SelectionArea(
        contextMenuBuilder: (context, selectableRegionState) {
          return buildAskConduitSelectionAreaContextMenu(
            selectableRegionState: selectableRegionState,
            ref: ref,
            selectedText: _selectedText,
            composerTargetId: widget.askConduitComposerTargetId,
          );
        },
        onSelectionChanged: (content) {
          _selectedText = content?.plainText;
        },
        child: DrawerOpenGesturePriority(child: result),
      ),
    );
  }

  Widget _buildMarkdownDisplayParts(CompiledMarkdownDocument document) {
    final parts = buildMarkdownDisplayParts(
      document,
      isStreaming: widget.isStreaming,
    );
    if (parts.isEmpty) {
      _displayPartDocumentCache.clear();
      return _buildMarkdownWithCitations(
        document: document,
        stateScopeId: widget.stateScopeId,
        enableStreamingTextFade:
            widget.isStreaming && widget.enableStreamingTextFade,
        trimLastBlockBottomPadding: true,
      );
    }
    final stableParts = _reuseStableDisplayPartDocuments(parts);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (var index = 0; index < stableParts.length; index += 1)
          KeyedSubtree(
            key: ValueKey<String>(
              'markdown-display-part:${stableParts[index].partId}',
            ),
            child: _buildMarkdownWithCitations(
              document: stableParts[index].document,
              stateScopeId: _stateScopeIdForPart(stableParts[index]),
              enableStreamingTextFade:
                  widget.isStreaming &&
                  widget.enableStreamingTextFade &&
                  stableParts[index].isMutableTail,
              trimLastBlockBottomPadding: index == stableParts.length - 1,
            ),
          ),
      ],
    );
  }

  List<MarkdownDisplayPart> _reuseStableDisplayPartDocuments(
    List<MarkdownDisplayPart> parts,
  ) {
    final activePartIds = <String>{};
    final stableParts = <MarkdownDisplayPart>[];
    for (final part in parts) {
      activePartIds.add(part.partId);
      final previousDocument = _displayPartDocumentCache[part.partId];
      final stableDocument =
          previousDocument != null && previousDocument == part.document
          ? previousDocument
          : part.document;
      _displayPartDocumentCache[part.partId] = stableDocument;
      stableParts.add(part.copyWith(document: stableDocument));
    }
    _displayPartDocumentCache.removeWhere(
      (partId, _) => !activePartIds.contains(partId),
    );
    return stableParts;
  }

  /// Builds markdown with inline citation badges.
  ///
  /// Citations like [1], [2] are rendered as clickable
  /// badges inline with the text.
  Widget _buildMarkdownWithCitations({
    required CompiledMarkdownDocument document,
    required String? stateScopeId,
    required bool enableStreamingTextFade,
    required bool trimLastBlockBottomPadding,
  }) {
    return ConduitMarkdownWidget(
      compiledDocument: document,
      onLinkTap: widget.onTapLink,
      imageBuilder: _adaptImageBuilder(),
      sources: widget.sources,
      onSourceTap: widget.onSourceTap,
      stateScopeId: stateScopeId,
      enableStreamingTextFade: enableStreamingTextFade,
      heavyBlockPolicy: widget.isStreaming
          ? MarkdownHeavyBlockPolicy.defer
          : MarkdownHeavyBlockPolicy.eager,
      trimLastBlockBottomPadding: trimLastBlockBottomPadding,
      debugOnCompiledViewMounted: widget.debugOnCompiledViewMounted,
      debugOnCompiledViewDisposed: widget.debugOnCompiledViewDisposed,
      debugOnBaseRender: widget.debugOnBaseRender,
    );
  }

  String? _stateScopeIdForPart(MarkdownDisplayPart part) {
    final scope = widget.stateScopeId;
    if (scope == null || scope.isEmpty) {
      return '$_scopelessFallbackScopeId:${part.partId}';
    }
    return '$scope:${part.partId}';
  }

  void _resolveCompiledDocument(
    _MarkdownRenderSnapshot snapshot, {
    bool clearStaleDocument = false,
  }) {
    if (widget.isStreaming) {
      _documentController.resolveStreamingPrepared(
        snapshot.normalizedContent,
        clearDocumentWhenAsync: clearStaleDocument,
      );
      return;
    }
    _documentController.resolvePrepared(
      snapshot.normalizedContent,
      clearDocumentWhenAsync: clearStaleDocument,
    );
  }

  bool _needsPreparedSnapshotUpdate(String preparedContent) {
    if (preparedContent != _snapshot.normalizedContent) {
      return true;
    }
    return _compiledDocument == null ||
        _compiledPreparedContent != preparedContent;
  }

  void _applyPreparedSnapshotIfNeeded(
    String preparedContent, {
    bool clearStaleDocument = false,
  }) {
    if (!_needsPreparedSnapshotUpdate(preparedContent)) {
      return;
    }
    _applySnapshot(
      _MarkdownRenderSnapshot.full(preparedContent),
      clearStaleDocument: clearStaleDocument,
    );
  }

  bool get _canActivelyRefreshStreamingMarkdown =>
      _isAppForeground && _isRouteVisible;

  bool _isLifecycleForeground(AppLifecycleState? state) =>
      state == null ||
      state == AppLifecycleState.resumed ||
      state == AppLifecycleState.inactive;

  bool _computeRouteVisibility() {
    return TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true);
  }

  void _updateRouteVisibility() {
    final nextIsRouteVisible = _computeRouteVisibility();
    if (_isRouteVisible == nextIsRouteVisible) {
      return;
    }
    _isRouteVisible = nextIsRouteVisible;
    _handleStreamingRefreshVisibilityChanged();
  }

  void _handleStreamingRefreshVisibilityChanged() {
    if (!widget.isStreaming) {
      return;
    }
    if (!_canActivelyRefreshStreamingMarkdown) {
      _debugStreamingDelayTimer?.cancel();
      _debugStreamingDelayTimer = null;
      return;
    }
    if (_pendingStreamingContent != null) {
      _scheduleStreamingRefresh();
    }
  }

  bool _shouldShowLoadingSkeleton({
    required _MarkdownRenderSnapshot snapshot,
    required CompiledMarkdownDocument? compiledDocument,
    required bool hasFreshCompiledDocument,
  }) {
    if (widget.isStreaming || snapshot.normalizedContent.trim().isEmpty) {
      return false;
    }
    if (hasFreshCompiledDocument) {
      return false;
    }
    // The loading skeleton is strictly a first-paint state: it may only appear
    // when no compiled document exists yet. Once any valid document has been
    // rendered, a stale-but-valid document is kept on screen during async
    // recompiles instead of regressing to the skeleton (issue #540).
    if (compiledDocument != null) {
      return false;
    }
    return true;
  }

  void _applyCompiledDocumentState(
    String compiledPreparedContent,
    CompiledMarkdownDocument? document,
  ) {
    if (!mounted) {
      return;
    }
    // Rebuild so the freshly compiled document (or a cleared document) is
    // reflected. Any stale document already on screen is superseded here.
    setState(() {});
    scheduleEmbeddedPreviewEligibilityRecheck();
  }
}

extension StreamingMarkdownExtension on String {
  Widget toMarkdown({
    required BuildContext context,
    bool isStreaming = false,
    bool enableStreamingTextFade = true,
    MarkdownLinkTapCallback? onTapLink,
    List<ChatSourceReference>? sources,
    void Function(int sourceIndex)? onSourceTap,
    String? askConduitComposerTargetId,
    String? stateScopeId,
  }) {
    return StreamingMarkdownWidget(
      content: this,
      isStreaming: isStreaming,
      enableStreamingTextFade: enableStreamingTextFade,
      onTapLink: onTapLink,
      sources: sources,
      onSourceTap: onSourceTap,
      askConduitComposerTargetId: askConduitComposerTargetId,
      stateScopeId: stateScopeId,
    );
  }
}

class MarkdownWithLoading extends StatelessWidget {
  const MarkdownWithLoading({
    super.key,
    this.content,
    required this.isLoading,
    this.enableStreamingTextFade = true,
  });

  final String? content;
  final bool isLoading;
  final bool enableStreamingTextFade;

  @override
  Widget build(BuildContext context) {
    final value = content ?? '';
    if (isLoading && value.trim().isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    return StreamingMarkdownWidget(
      content: value,
      isStreaming: isLoading,
      enableStreamingTextFade: enableStreamingTextFade,
    );
  }
}
