import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/services/worker_manager.dart';
import 'compiled_markdown_document.dart';
import 'markdown_config.dart';
import 'markdown_compile_service.dart';
import 'markdown_document_controller.dart';
import 'renderer/block_renderer.dart';
import 'renderer/conduit_markdown_widget.dart';

const int _streamingSnapshotWorkerThreshold = 768;

Map<String, Object> _computeStreamingMarkdownSnapshot(String content) {
  return _buildMarkdownSnapshot(content, streaming: true).toMap();
}

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

  factory _MarkdownRenderSnapshot.fromMap(Map<String, Object?> map) {
    return _MarkdownRenderSnapshot(
      normalizedContent: (map['normalizedContent'] ?? '') as String,
    );
  }

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

  @override
  ConsumerState<StreamingMarkdownWidget> createState() =>
      _StreamingMarkdownWidgetState();
}

class _StreamingMarkdownWidgetState
    extends ConsumerState<StreamingMarkdownWidget> {
  static const _streamingRenderInterval = Duration(milliseconds: 120);

  late final MarkdownDocumentController _documentController;
  _MarkdownRenderSnapshot _snapshot = const _MarkdownRenderSnapshot.empty();
  Timer? _renderTimer;
  bool _snapshotInFlight = false;
  String? _queuedContent;
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

    if (_isWidgetTest ||
        widget.content.length < _streamingSnapshotWorkerThreshold) {
      _invalidatePendingAsyncSnapshot();
      _applySnapshot(_buildMarkdownSnapshot(widget.content, streaming: true));
      return;
    }

    if (_snapshotInFlight) {
      _queueLatestStreamingContent(widget.content);
      return;
    }

    _scheduleStreamingRefresh();
  }

  bool get _isWidgetTest =>
      widget.debugTreatAsWidgetTest ??
      WidgetsBinding.instance.runtimeType.toString().contains('Test');

  @override
  void dispose() {
    _renderTimer?.cancel();
    _documentController.dispose();
    super.dispose();
  }

  void _scheduleStreamingRefresh({bool immediate = false}) {
    if (_renderTimer != null) {
      return;
    }
    final interval = immediate || _isWidgetTest
        ? Duration.zero
        : widget.debugRenderInterval ?? _streamingRenderInterval;
    _renderTimer = Timer(interval, () {
      _renderTimer = null;
      if (!mounted) {
        return;
      }
      unawaited(_refreshStreamingSnapshot(widget.content));
    });
  }

  void _invalidatePendingAsyncSnapshot() {
    _renderTimer?.cancel();
    _renderTimer = null;
    _queuedContent = null;
    _snapshotGeneration += 1;
    _documentController.invalidatePending();
  }

  void _queueLatestStreamingContent(String content) {
    if (_queuedContent == content) {
      return;
    }
    _queuedContent = content;
    _snapshotGeneration += 1;
  }

  Future<void> _refreshStreamingSnapshot(String content) async {
    if (_snapshotInFlight) {
      _queueLatestStreamingContent(content);
      return;
    }

    _snapshotInFlight = true;
    final generation = ++_snapshotGeneration;
    try {
      final worker = ref.read(workerManagerProvider);
      final rawSnapshot = await worker.schedule<String, Map<String, Object>>(
        _computeStreamingMarkdownSnapshot,
        content,
        debugLabel: 'markdown_stream_snapshot',
      );
      if (!mounted || generation != _snapshotGeneration) {
        return;
      }
      _applySnapshot(_MarkdownRenderSnapshot.fromMap(rawSnapshot));
    } catch (_) {
      if (!mounted || generation != _snapshotGeneration) {
        return;
      }
      _applySnapshot(_buildMarkdownSnapshot(content, streaming: true));
    } finally {
      _snapshotInFlight = false;
      final queuedContent = _queuedContent;
      _queuedContent = null;
      if (queuedContent != null && queuedContent != content && mounted) {
        _scheduleStreamingRefresh(immediate: true);
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
    if (compiledDocument == null) {
      return const SizedBox.shrink();
    }
    if (!widget.isStreaming &&
        _compiledPreparedContent != snapshot.normalizedContent) {
      return const SizedBox.shrink();
    }

    final result = _buildMarkdownWithCitations(compiledDocument);

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
          : MarkdownHeavyBlockPolicy.smart,
    );
  }

  void _resolveCompiledDocument(_MarkdownRenderSnapshot snapshot) {
    _documentController.resolvePrepared(snapshot.normalizedContent);
  }

  void _applyCompiledDocumentState(
    String compiledPreparedContent,
    CompiledMarkdownDocument? document,
  ) {
    if (!mounted) {
      return;
    }
    setState(() {});
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
