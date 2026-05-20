import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/chat_message.dart';
import 'compiled_markdown_document.dart';
import 'markdown_config.dart';
import 'markdown_compile_service.dart';
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
    this.stateScopeId,
    this.debugTreatAsWidgetTest,
    this.debugRenderInterval,
    this.debugOnCompiledViewMounted,
    this.debugOnCompiledViewDisposed,
    this.debugOnStreamingRefreshFrame,
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

  /// Optional scope used to preserve state for remounted markdown blocks.
  final String? stateScopeId;

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

  @override
  ConsumerState<StreamingMarkdownWidget> createState() =>
      _StreamingMarkdownWidgetState();
}

class _StreamingMarkdownWidgetState
    extends ConsumerState<StreamingMarkdownWidget> {
  late final MarkdownDocumentController _documentController;
  final GlobalKey _markdownContentKey = GlobalKey();
  _MarkdownRenderSnapshot _snapshot = const _MarkdownRenderSnapshot.empty();
  bool _preserveStaleCompiledDocumentUntilFreshFinal = false;
  Timer? _debugStreamingDelayTimer;
  bool _snapshotInFlight = false;
  bool _streamingRefreshFrameScheduled = false;
  String? _pendingStreamingContent;
  int _snapshotGeneration = 0;

  CompiledMarkdownDocument? get _compiledDocument =>
      _documentController.compiledDocument;

  String get _compiledPreparedContent =>
      _documentController.compiledPreparedContent;

  @override
  void initState() {
    super.initState();
    _documentController = MarkdownDocumentController(
      readCompiler: () => ref.read(markdownCompileServiceProvider),
      isWidgetTest: () => _isWidgetTest,
      onStateChanged: _applyCompiledDocumentState,
    );
    _snapshot = _buildMarkdownSnapshot(
      widget.content,
      streaming: widget.isStreaming,
    );
    _resolveCompiledDocument(_snapshot);
  }

  @override
  void didUpdateWidget(covariant StreamingMarkdownWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isStreaming && !widget.isStreaming) {
      _preserveStaleCompiledDocumentUntilFreshFinal = true;
    } else if (widget.isStreaming ||
        widget.stateScopeId != oldWidget.stateScopeId) {
      _preserveStaleCompiledDocumentUntilFreshFinal = false;
    }
    if (!identical(widget.sources, oldWidget.sources) ||
        widget.onSourceTap != oldWidget.onSourceTap ||
        widget.onTapLink != oldWidget.onTapLink ||
        widget.imageBuilderOverride != oldWidget.imageBuilderOverride ||
        widget.stateScopeId != oldWidget.stateScopeId) {
      setState(() {});
    }
    if (widget.content == oldWidget.content &&
        widget.isStreaming == oldWidget.isStreaming) {
      return;
    }

    if (!widget.isStreaming) {
      _invalidatePendingAsyncSnapshot();
      _applySnapshot(_buildMarkdownSnapshot(widget.content, streaming: false));
      return;
    }

    final compiler = ref.read(markdownCompileServiceProvider);
    if (compiler.shouldPrepareSynchronously(
      widget.content,
      widgetTest: _isWidgetTest,
    )) {
      _invalidatePendingAsyncSnapshot();
      _applySnapshot(_buildMarkdownSnapshot(widget.content, streaming: true));
      return;
    }

    _markPendingStreamingContent(widget.content);
    if (_snapshotInFlight) {
      return;
    }
    _scheduleStreamingRefresh();
  }

  bool get _isWidgetTest =>
      widget.debugTreatAsWidgetTest ??
      WidgetsBinding.instance.runtimeType.toString().contains('Test');

  @override
  void dispose() {
    _debugStreamingDelayTimer?.cancel();
    _documentController.dispose();
    super.dispose();
  }

  void _scheduleStreamingRefresh() {
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
    if (_streamingRefreshFrameScheduled || _snapshotInFlight) {
      return;
    }
    _streamingRefreshFrameScheduled = true;
    WidgetsBinding.instance.scheduleFrame();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _streamingRefreshFrameScheduled = false;
      if (!mounted) {
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
      final preparedContent = await compiler.prepareContent(
        content,
        streaming: true,
      );
      if (!mounted || generation != _snapshotGeneration) {
        return;
      }
      _applySnapshot(_MarkdownRenderSnapshot.full(preparedContent));
    } catch (_) {
      if (!mounted || generation != _snapshotGeneration) {
        return;
      }
      _applySnapshot(_buildMarkdownSnapshot(content, streaming: true));
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

  void _applySnapshot(_MarkdownRenderSnapshot nextSnapshot) {
    final changed = _snapshot != nextSnapshot;
    if (!changed) {
      if (_compiledDocument == null ||
          _compiledPreparedContent != nextSnapshot.normalizedContent) {
        _resolveCompiledDocument(nextSnapshot);
      }
      return;
    }
    if (!mounted) {
      _snapshot = nextSnapshot;
      _resolveCompiledDocument(nextSnapshot);
      return;
    }
    setState(() => _snapshot = nextSnapshot);
    _resolveCompiledDocument(nextSnapshot);
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
    if (!widget.isStreaming &&
        !hasFreshCompiledDocument &&
        !_preserveStaleCompiledDocumentUntilFreshFinal) {
      return const SizedBox.shrink();
    }

    final result = KeyedSubtree(
      key: _markdownContentKey,
      child: _buildMarkdownWithCitations(compiledDocument),
    );

    // Only wrap in SelectionArea when not streaming to
    // avoid concurrent modification errors in Flutter's
    // selection system during rapid updates.
    if (widget.isStreaming) {
      return result;
    }

    return SelectionArea(child: result);
  }

  /// Builds markdown with inline citation badges.
  ///
  /// Citations like [1], [2] are rendered as clickable
  /// badges inline with the text.
  Widget _buildMarkdownWithCitations(CompiledMarkdownDocument document) {
    return ConduitMarkdownWidget(
      compiledDocument: document,
      onLinkTap: widget.onTapLink,
      imageBuilder: _adaptImageBuilder(),
      sources: widget.sources,
      onSourceTap: widget.onSourceTap,
      stateScopeId: widget.stateScopeId,
      heavyBlockPolicy: widget.isStreaming
          ? MarkdownHeavyBlockPolicy.defer
          : MarkdownHeavyBlockPolicy.eager,
      debugOnCompiledViewMounted: widget.debugOnCompiledViewMounted,
      debugOnCompiledViewDisposed: widget.debugOnCompiledViewDisposed,
    );
  }

  void _resolveCompiledDocument(_MarkdownRenderSnapshot snapshot) {
    _documentController.resolvePrepared(snapshot.normalizedContent);
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
    if (_preserveStaleCompiledDocumentUntilFreshFinal &&
        compiledDocument != null) {
      return false;
    }
    return true;
  }

  void _applyCompiledDocumentState(
    String compiledPreparedContent,
    CompiledMarkdownDocument? document,
  ) {
    final hasFreshCompiledDocument =
        compiledPreparedContent == _snapshot.normalizedContent;
    if (!mounted) {
      if (hasFreshCompiledDocument) {
        _preserveStaleCompiledDocumentUntilFreshFinal = false;
      }
      return;
    }
    setState(() {
      if (hasFreshCompiledDocument) {
        _preserveStaleCompiledDocumentUntilFreshFinal = false;
      }
    });
  }
}

extension StreamingMarkdownExtension on String {
  Widget toMarkdown({
    required BuildContext context,
    bool isStreaming = false,
    MarkdownLinkTapCallback? onTapLink,
    List<ChatSourceReference>? sources,
    void Function(int sourceIndex)? onSourceTap,
    String? stateScopeId,
  }) {
    return StreamingMarkdownWidget(
      content: this,
      isStreaming: isStreaming,
      onTapLink: onTapLink,
      sources: sources,
      onSourceTap: onSourceTap,
      stateScopeId: stateScopeId,
    );
  }
}

class MarkdownWithLoading extends StatelessWidget {
  const MarkdownWithLoading({super.key, this.content, required this.isLoading});

  final String? content;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final value = content ?? '';
    if (isLoading && value.trim().isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    return StreamingMarkdownWidget(content: value, isStreaming: isLoading);
  }
}
