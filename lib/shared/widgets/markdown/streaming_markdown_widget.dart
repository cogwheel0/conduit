import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/services/worker_manager.dart';
import 'markdown_config.dart';
import 'markdown_preprocessor.dart';
import 'renderer/block_renderer.dart';
import 'renderer/conduit_markdown_widget.dart';

const int _streamingSnapshotWorkerThreshold = 768;
const int _streamingSnapshotLookback = 640;
const int _streamingSnapshotMinTailLength = 220;
final RegExp _streamingFenceRegex = RegExp(r'^\s*```', multiLine: true);
final RegExp _streamingCollapsedNewlines = RegExp(r'\n{3,}');

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
  final normalized = ConduitMarkdownPreprocessor.normalize(content);
  if (!streaming || normalized.trim().isEmpty) {
    return _MarkdownRenderSnapshot.full(normalized);
  }

  if (!_shouldUseCheapStreamingPath(normalized)) {
    return _MarkdownRenderSnapshot.full(normalized);
  }

  final splitIndex = _findStreamingSplitIndex(normalized);
  if (splitIndex <= 0 || splitIndex >= normalized.length) {
    return _MarkdownRenderSnapshot.full(normalized);
  }

  var stableContent = normalized.substring(0, splitIndex).trimRight();
  if (_streamingFenceRegex.allMatches(stableContent).length.isOdd) {
    final lastFenceIndex = stableContent.lastIndexOf('```');
    if (lastFenceIndex >= 0) {
      stableContent = stableContent.substring(0, lastFenceIndex).trimRight();
    }
  }

  final trailingContent = normalized.substring(stableContent.length).trimLeft();
  if (stableContent.isEmpty || trailingContent.isEmpty) {
    return _MarkdownRenderSnapshot.full(normalized);
  }

  return _MarkdownRenderSnapshot(
    normalizedContent: normalized,
    stableContent: stableContent,
    trailingContent: trailingContent,
    useCheapTail: true,
  );
}

bool _shouldUseCheapStreamingPath(String normalized) {
  if (normalized.length >= 1400) {
    return true;
  }

  return normalized.contains('```') ||
      normalized.contains('| ---') ||
      normalized.contains('\n|') ||
      normalized.contains('<details') ||
      normalized.contains('```mermaid') ||
      normalized.contains('```chart');
}

int _findStreamingSplitIndex(String normalized) {
  if (normalized.length <= _streamingSnapshotMinTailLength * 2) {
    return -1;
  }

  final minStableLength = math.min(
    normalized.length - _streamingSnapshotMinTailLength,
    400,
  );
  final latestAllowedStart =
      normalized.length - _streamingSnapshotMinTailLength;
  final searchStart = math.max(
    0,
    latestAllowedStart - _streamingSnapshotLookback,
  );

  const separators = <String>['\n\n', '\n', '. ', '! ', '? '];
  for (final separator in separators) {
    final index = normalized.lastIndexOf(separator, latestAllowedStart);
    if (index >= searchStart && index >= minStableLength) {
      return index + separator.length;
    }
  }

  return latestAllowedStart;
}

String _prepareStreamingTail(String trailingContent) {
  final collapsed = trailingContent
      .replaceAll(_streamingCollapsedNewlines, '\n\n')
      .trimLeft();
  return ConduitMarkdownPreprocessor.softenInlineCode(
    ConduitMarkdownPreprocessor.removeAllDetails(collapsed),
  ).trimRight();
}

class _MarkdownRenderSnapshot {
  const _MarkdownRenderSnapshot({
    required this.normalizedContent,
    required this.stableContent,
    required this.trailingContent,
    required this.useCheapTail,
  });

  const _MarkdownRenderSnapshot.empty()
    : normalizedContent = '',
      stableContent = '',
      trailingContent = '',
      useCheapTail = false;

  const _MarkdownRenderSnapshot.full(this.normalizedContent)
    : stableContent = normalizedContent,
      trailingContent = '',
      useCheapTail = false;

  final String normalizedContent;
  final String stableContent;
  final String trailingContent;
  final bool useCheapTail;

  Map<String, Object> toMap() {
    return {
      'normalizedContent': normalizedContent,
      'stableContent': stableContent,
      'trailingContent': trailingContent,
      'useCheapTail': useCheapTail,
    };
  }

  factory _MarkdownRenderSnapshot.fromMap(Map<String, Object?> map) {
    return _MarkdownRenderSnapshot(
      normalizedContent: (map['normalizedContent'] ?? '') as String,
      stableContent: (map['stableContent'] ?? '') as String,
      trailingContent: (map['trailingContent'] ?? '') as String,
      useCheapTail: (map['useCheapTail'] ?? false) as bool,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is _MarkdownRenderSnapshot &&
        other.normalizedContent == normalizedContent &&
        other.stableContent == stableContent &&
        other.trailingContent == trailingContent &&
        other.useCheapTail == useCheapTail;
  }

  @override
  int get hashCode => Object.hash(
    normalizedContent,
    stableContent,
    trailingContent,
    useCheapTail,
  );
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

  _MarkdownRenderSnapshot _snapshot = const _MarkdownRenderSnapshot.empty();
  Timer? _renderTimer;
  bool _snapshotInFlight = false;
  String? _queuedContent;
  int _snapshotGeneration = 0;

  @override
  void initState() {
    super.initState();
    _snapshot = _buildMarkdownSnapshot(
      widget.content,
      streaming: widget.isStreaming,
    );
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
    if (_snapshot == nextSnapshot) {
      return;
    }
    if (!mounted) {
      _snapshot = nextSnapshot;
      return;
    }
    setState(() => _snapshot = nextSnapshot);
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
    final snapshot = widget.isStreaming
        ? _snapshot
        : _buildMarkdownSnapshot(widget.content, streaming: false);
    if (snapshot.normalizedContent.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    final result = snapshot.useCheapTail
        ? _buildStreamingMarkdownResult(snapshot)
        : _buildMarkdownWithCitations(snapshot.normalizedContent);

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
  Widget _buildMarkdownWithCitations(String data) {
    return ConduitMarkdownWidget(
      data: data,
      onLinkTap: widget.onTapLink,
      imageBuilder: _adaptImageBuilder(),
      sources: widget.sources,
      onSourceTap: widget.onSourceTap,
      stateScopeId: widget.stateScopeId,
    );
  }

  Widget _buildStreamingMarkdownResult(_MarkdownRenderSnapshot snapshot) {
    final children = <Widget>[];
    if (snapshot.stableContent.trim().isNotEmpty) {
      children.add(_buildMarkdownWithCitations(snapshot.stableContent));
    }

    final trailingContent = _prepareStreamingTail(snapshot.trailingContent);
    if (trailingContent.trim().isNotEmpty) {
      if (children.isNotEmpty) {
        children.add(const SizedBox(height: 8));
      }
      children.add(_StreamingMarkdownTail(content: trailingContent));
    }

    if (children.isEmpty) {
      return _buildMarkdownWithCitations(snapshot.normalizedContent);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}

class _StreamingMarkdownTail extends StatelessWidget {
  const _StreamingMarkdownTail({required this.content});

  final String content;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final trimmed = content.trimLeft();
    final isFenceBlock = trimmed.startsWith('```');
    if (isFenceBlock) {
      final codeBody = trimmed.replaceFirst(RegExp(r'^```[^\n]*\n?'), '');
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          codeBody,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontFamily: 'monospace',
            height: 1.45,
          ),
        ),
      );
    }

    return Text(
      content,
      style: theme.textTheme.bodyLarge?.copyWith(height: 1.45),
    );
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
