import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/markdown/streaming_markdown_widget.dart';
import '../../../core/utils/reasoning_parser.dart';
import '../../../core/utils/message_segments.dart';
import '../../../core/utils/tool_calls_parser.dart';
import '../../../core/models/chat_message.dart';
import '../../../shared/widgets/markdown/markdown_preprocessor.dart';
import '../providers/text_to_speech_provider.dart';
import 'enhanced_image_attachment.dart';
import 'package:qonduit/l10n/app_localizations.dart';
import 'enhanced_attachment.dart';
import 'package:qonduit/shared/widgets/chat_action_button.dart';
import '../../../shared/widgets/model_avatar.dart';
import '../../../shared/widgets/qonduit_components.dart';
import '../../../shared/widgets/middle_ellipsis_text.dart';
import 'package:url_launcher/url_launcher_string.dart';
import '../providers/chat_providers.dart'
    show sendMessageWithContainer, streamingContentProvider;
import '../../../core/utils/debug_logger.dart';
import '../../../core/services/platform_service.dart';
import '../../../core/services/settings_service.dart';
import 'sources/openwebui_sources.dart';
import '../providers/assistant_response_builder_provider.dart';
import '../../../core/services/worker_manager.dart';
import 'streaming_status_widget.dart';
import '../utils/file_utils.dart';
import 'code_execution_display.dart';
import 'follow_up_suggestions.dart';
import 'usage_stats_modal.dart';
import 'tool_call_tile.dart';
import 'reasoning_tile.dart';

// Pre-compiled regex patterns for image processing (performance optimization)
final _base64ImagePattern = RegExp(r'data:image/[^;]+;base64,[A-Za-z0-9+/]+=*');
// Handle both URL formats: /api/v1/files/{id} and /api/v1/files/{id}/content
final _fileIdPattern = RegExp(r'/api/v1/files/([^/]+)(?:/content)?$');

class _CodeEditArtifactInfo {
  final String name;
  final String savedPath;

  const _CodeEditArtifactInfo({required this.name, required this.savedPath});
}

class AssistantMessageWidget extends ConsumerStatefulWidget {
  final dynamic message;
  final bool isStreaming;
  final bool showFollowUps;
  final String? modelName;
  final String? modelIconUrl;
  final VoidCallback? onCopy;
  final VoidCallback? onRegenerate;
  final VoidCallback? onLike;
  final VoidCallback? onDislike;

  const AssistantMessageWidget({
    super.key,
    required this.message,
    this.isStreaming = false,
    this.showFollowUps = true,
    this.modelName,
    this.modelIconUrl,
    this.onCopy,
    this.onRegenerate,
    this.onLike,
    this.onDislike,
  });

  @override
  ConsumerState<AssistantMessageWidget> createState() =>
      _AssistantMessageWidgetState();
}

class _AssistantMessageWidgetState extends ConsumerState<AssistantMessageWidget>
    with TickerProviderStateMixin {
  late AnimationController _fadeController;
  late AnimationController _slideController;
  // Unified content segments (text, tool-calls, reasoning)
  List<MessageSegment> _segments = const [];
  final Set<int> _expandedReasoning = {};
  Widget? _cachedAvatar;
  bool _allowTypingIndicator = false;
  Timer? _typingGateTimer;
  String _ttsPlainText = '';
  Timer? _ttsPlainTextDebounce;
  Map<String, dynamic>? _pendingTtsPlainTextPayload;
  String? _pendingTtsPlainTextSource;
  String? _lastAppliedTtsPlainTextSource;
  int _ttsPlainTextRequestId = 0;
  // Active version index (-1 means current/live content)
  int _activeVersionIndex = -1;
  String? _lastStreamingContent;
  bool _hasAnimated = false;

  /// Guards the triple-haptic so it fires only once per streaming session.
  bool _hasTriggeredContentHaptic = false;
  ProviderSubscription<String?>? _streamingContentSub;

  // Streaming fade-in animation state
  late AnimationController _chunkFadeController;

  /// Cache the last raw content that was fully parsed, so we can detect
  /// when only the tail has changed and skip re-parsing earlier segments.
  String _lastFullyParsedContent = '';
  // press state handled by shared ChatActionButton

  Future<void> _handleFollowUpTap(String suggestion) async {
    final trimmed = suggestion.trim();
    if (trimmed.isEmpty || widget.isStreaming) {
      return;
    }
    try {
      final container = ProviderScope.containerOf(context, listen: false);
      await sendMessageWithContainer(container, trimmed, null);
    } catch (err, stack) {
      DebugLogger.log(
        'Failed to send follow-up: $err',
        scope: 'chat/assistant',
      );
      debugPrintStack(stackTrace: stack);
    }
  }

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _slideController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _chunkFadeController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
      value: 1.0, // Start fully opaque for non-streaming messages
    );

    // Parse reasoning and tool-calls sections
    unawaited(_reparseSections());
    _updateTypingIndicatorGate();
    _syncStreamingContentSubscription();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Build cached avatar when theme context is available
    _buildCachedAvatar();
  }

  @override
  void didUpdateWidget(AssistantMessageWidget oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.message.id != widget.message.id) {
      _lastStreamingContent = null;
      _lastFullyParsedContent = '';
      _hasAnimated = false;
      _hasTriggeredContentHaptic = false;
      _fadeController.reset();
      _slideController.reset();
      _chunkFadeController.value = 1.0;
    }

    // Re-sync subscription when streaming state changes
    if (oldWidget.isStreaming != widget.isStreaming ||
        oldWidget.message.id != widget.message.id) {
      _syncStreamingContentSubscription();
    }

    // Reset fade controller when streaming ends for the same message
    if (oldWidget.isStreaming &&
        !widget.isStreaming &&
        oldWidget.message.id == widget.message.id) {
      _chunkFadeController.value = 1.0;
      _hasTriggeredContentHaptic = false;
      // Haptic: streaming finished
      _streamingHaptic(HapticType.medium);
    }

    // Re-parse sections when message content changes
    if (oldWidget.message.content != widget.message.content) {
      unawaited(_reparseSections());
      _updateTypingIndicatorGate();
    }

    // Update typing indicator gate when message properties that affect emptiness change
    if (oldWidget.message.statusHistory != widget.message.statusHistory ||
        oldWidget.message.files != widget.message.files ||
        oldWidget.message.attachmentIds != widget.message.attachmentIds ||
        oldWidget.message.followUps != widget.message.followUps ||
        oldWidget.message.codeExecutions != widget.message.codeExecutions) {
      _updateTypingIndicatorGate();
    }

    // Rebuild cached avatar if model name or icon changes
    if (oldWidget.modelName != widget.modelName ||
        oldWidget.modelIconUrl != widget.modelIconUrl) {
      _buildCachedAvatar();
    }
  }

  Future<void> _reparseSections([String? overrideContent]) async {
    final raw0 = _activeVersionIndex >= 0
        ? (widget.message.versions[_activeVersionIndex].content as String?) ??
        ''
        : (overrideContent ?? widget.message.content ?? '');
    // Strip any leftover placeholders from content before parsing
    const ti = '[TYPING_INDICATOR]';
    const searchBanner = '🔍 Searching the web...';
    String raw = raw0;
    if (raw.startsWith(ti)) {
      raw = raw.substring(ti.length);
    }
    if (raw.startsWith(searchBanner)) {
      raw = raw.substring(searchBanner.length);
    }

    // Optimization: during streaming, if content only grew at the end and
    // there's no new reasoning/tool block, just update the last text segment.
    if (widget.isStreaming &&
        _segments.isNotEmpty &&
        raw.startsWith(_lastFullyParsedContent) &&
        _lastFullyParsedContent.isNotEmpty) {
      final newTail = raw.substring(_lastFullyParsedContent.length);
      // Quick check: if the new tail doesn't contain reasoning or tool
      // markers, we can just extend the last text segment.
      if (!newTail.contains('<details') &&
          !newTail.contains('</details') &&
          !newTail.contains('<think') &&
          !newTail.contains('</think')) {
        final lastSeg = _segments.last;
        if (lastSeg.isText) {
          final previousLength = _lastFullyParsedContent.length;
          final updatedSegments = [
            ..._segments.sublist(0, _segments.length - 1),
            MessageSegment.text((lastSeg.text ?? '') + newTail),
          ];
          _lastFullyParsedContent = raw;
          if (!mounted) return;
          setState(() {
            _segments = updatedSegments;
          });
          if (widget.isStreaming) {
            _onStreamingChunk(previousLength, raw.length);
          }
          _scheduleTtsPlainTextBuild(
            updatedSegments
                .where((s) => s.isText)
                .map((s) => s.text!)
                .toList(growable: false),
            raw,
          );
          _updateTypingIndicatorGate();
          return;
        }
      }
    }

    // Note: Link reference definitions (including OpenAI annotations like
    // [openai_responses:v2:reasoning:ID]: #) are stripped by the markdown
    // preprocessor using the `markdown` package for proper CommonMark handling.

    // Do not truncate content during streaming; segmented parser skips
    // incomplete details blocks and tiles will render once complete.
    final rSegs = ReasoningParser.segments(raw);

    final out = <MessageSegment>[];
    final textSegments = <String>[];
    if (rSegs == null || rSegs.isEmpty) {
      final tSegs = ToolCallsParser.segments(raw);
      if (tSegs == null || tSegs.isEmpty) {
        out.add(MessageSegment.text(raw));
        textSegments.add(raw);
      } else {
        for (final s in tSegs) {
          if (s.isToolCall && s.entry != null) {
            out.add(MessageSegment.tool(s.entry!));
          } else if ((s.text ?? '').isNotEmpty) {
            out.add(MessageSegment.text(s.text!));
            textSegments.add(s.text!);
          }
        }
      }
    } else {
      for (final rs in rSegs) {
        if (rs.isReasoning && rs.entry != null) {
          out.add(MessageSegment.reason(rs.entry!));
        } else if ((rs.text ?? '').isNotEmpty) {
          final t = rs.text!;
          final tSegs = ToolCallsParser.segments(t);
          if (tSegs == null || tSegs.isEmpty) {
            out.add(MessageSegment.text(t));
            textSegments.add(t);
          } else {
            for (final s in tSegs) {
              if (s.isToolCall && s.entry != null) {
                out.add(MessageSegment.tool(s.entry!));
              } else if ((s.text ?? '').isNotEmpty) {
                out.add(MessageSegment.text(s.text!));
                textSegments.add(s.text!);
              }
            }
          }
        }
      }
    }

    final segments = out.isEmpty ? [MessageSegment.text(raw)] : out;

    final previousLength = _lastFullyParsedContent.length;
    _lastFullyParsedContent = raw;
    if (!mounted) return;
    setState(() {
      _segments = segments;
    });
    if (widget.isStreaming) {
      _onStreamingChunk(previousLength, raw.length);
    }
    _scheduleTtsPlainTextBuild(
      List<String>.from(textSegments, growable: false),
      raw,
    );
    _updateTypingIndicatorGate();
  }

  void _updateTypingIndicatorGate() {
    _typingGateTimer?.cancel();
    if (_shouldShowTypingIndicator) {
      if (_allowTypingIndicator) {
        return;
      }
      _typingGateTimer = Timer(const Duration(milliseconds: 150), () {
        if (!mounted || !_shouldShowTypingIndicator) {
          return;
        }
        setState(() {
          _allowTypingIndicator = true;
        });
        // Haptic: typing indicator appeared
        _streamingHaptic(HapticType.light);
      });
    } else if (_allowTypingIndicator) {
      if (mounted) {
        setState(() {
          _allowTypingIndicator = false;
        });
      } else {
        _allowTypingIndicator = false;
      }
    }
  }

  String get _messageId {
    try {
      final dynamic idValue = widget.message.id;
      if (idValue == null) {
        return '';
      }
      return idValue.toString();
    } catch (_) {
      return '';
    }
  }

  String _buildTtsPlainTextFallback(List<String> segments, String fallback) {
    if (segments.isEmpty) {
      return QonduitMarkdownPreprocessor.toPlainText(fallback);
    }

    final buffer = StringBuffer();
    for (final segment in segments) {
      final sanitized = QonduitMarkdownPreprocessor.toPlainText(segment);
      if (sanitized.isEmpty) {
        continue;
      }
      if (buffer.isNotEmpty) {
        buffer.writeln();
        buffer.writeln();
      }
      buffer.write(sanitized);
    }

    final result = buffer.toString().trim();
    if (result.isEmpty) {
      return QonduitMarkdownPreprocessor.toPlainText(fallback);
    }
    return result;
  }

  void _scheduleTtsPlainTextBuild(List<String> segments, String raw) {
    final hasContent =
        segments.any((segment) => segment.trim().isNotEmpty) ||
            raw.trim().isNotEmpty;
    if (!hasContent) {
      _pendingTtsPlainTextPayload = null;
      _pendingTtsPlainTextSource = null;
      _lastAppliedTtsPlainTextSource = '';
      if (_ttsPlainText.isNotEmpty && mounted) {
        setState(() {
          _ttsPlainText = '';
        });
      }
      return;
    }

    if (_pendingTtsPlainTextPayload == null &&
        raw == _lastAppliedTtsPlainTextSource) {
      return;
    }
    if (raw == _pendingTtsPlainTextSource &&
        _pendingTtsPlainTextPayload != null) {
      return;
    }

    final pendingSegments = List<String>.from(segments, growable: false);
    _pendingTtsPlainTextPayload = {
      'segments': pendingSegments,
      'fallback': raw,
    };
    _pendingTtsPlainTextSource = raw;

    final delay = widget.isStreaming
        ? const Duration(milliseconds: 250)
        : Duration.zero;

    _ttsPlainTextDebounce?.cancel();
    if (delay == Duration.zero) {
      _runPendingTtsPlainTextBuild();
    } else {
      _ttsPlainTextDebounce = Timer(delay, _runPendingTtsPlainTextBuild);
    }
  }

  void _runPendingTtsPlainTextBuild() {
    _ttsPlainTextDebounce?.cancel();
    _ttsPlainTextDebounce = null;

    final payload = _pendingTtsPlainTextPayload;
    final source = _pendingTtsPlainTextSource;
    if (payload == null || source == null) {
      return;
    }

    _pendingTtsPlainTextPayload = null;
    _pendingTtsPlainTextSource = null;
    final requestId = ++_ttsPlainTextRequestId;
    unawaited(_executeTtsPlainTextBuild(payload, source, requestId));
  }

  Future<void> _executeTtsPlainTextBuild(
      Map<String, dynamic> payload,
      String raw,
      int requestId,
      ) async {
    final segments = (payload['segments'] as List).cast<String>();
    String speechText;
    try {
      final worker = ref.read(workerManagerProvider);
      speechText = await worker.schedule<Map<String, dynamic>, String>(
        _buildTtsPlainTextWorker,
        payload,
        debugLabel: 'tts_plain_text',
      );
    } catch (_) {
      speechText = _buildTtsPlainTextFallback(segments, raw);
    }

    if (!mounted || requestId != _ttsPlainTextRequestId) {
      return;
    }

    _lastAppliedTtsPlainTextSource = raw;
    if (_ttsPlainText != speechText) {
      setState(() {
        _ttsPlainText = speechText;
      });
    }
  }

  // No streaming-specific markdown fixes needed here; handled by Markdown widget

  Widget _buildSegmentedContent() {
    final children = <Widget>[];
    bool firstToolSpacerAdded = false;
    int idx = 0;
    for (final seg in _segments) {
      if (seg.isTool && seg.toolCall != null) {
        // Add top spacing before the first tool block for clarity
        if (!firstToolSpacerAdded) {
          children.add(const SizedBox(height: Spacing.sm));
          firstToolSpacerAdded = true;
        }
        children.add(
          ToolCallTile(
            toolCall: seg.toolCall!,
            isStreaming: widget.isStreaming,
          ),
        );
      } else if (seg.isReasoning && seg.reasoning != null) {
        children.add(
          ReasoningTile(
            reasoning: seg.reasoning!,
            index: idx,
            onExpand: (i) => setState(() => _expandedReasoning.add(i)),
            onCollapse: (i) {
              if (mounted) {
                setState(() => _expandedReasoning.remove(i));
              }
            },
          ),
        );
      } else if ((seg.text ?? '').trim().isNotEmpty) {
        // No extra spacing needed - reasoning/tool tiles have bottom padding
        final markdownWidget = _buildEnhancedMarkdownContent(seg.text!);
        // Wrap the last text segment with fade-in overlay during streaming
        final isLastTextSeg =
            widget.isStreaming &&
                _segments.skip(idx + 1).every((s) => !s.isText);
        children.add(
          isLastTextSeg
              ? RepaintBoundary(
            child: _StreamingFadeOverlay(
              animation: _chunkFadeController,
              child: markdownWidget,
            ),
          )
              : markdownWidget,
        );
      }
      idx++;
    }

    if (children.isEmpty) return const SizedBox.shrink();
    // Append TTS karaoke bar if this is the active message
    final ttsState = ref.watch(textToSpeechControllerProvider);
    final isActive =
        ttsState.activeMessageId == _messageId &&
            (ttsState.status == TtsPlaybackStatus.speaking ||
                ttsState.status == TtsPlaybackStatus.paused ||
                ttsState.status == TtsPlaybackStatus.loading);
    if (isActive && ttsState.activeSentenceIndex >= 0) {
      children.add(const SizedBox(height: Spacing.sm));
      children.add(_buildKaraokeBar(ttsState));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _buildKaraokeBar(TextToSpeechState ttsState) {
    final theme = context.qonduitTheme;
    final idx = ttsState.activeSentenceIndex;
    if (idx < 0 || idx >= ttsState.sentences.length) {
      return const SizedBox.shrink();
    }
    final sentence = ttsState.sentences[idx];
    final ws = ttsState.wordStartInSentence;
    final we = ttsState.wordEndInSentence;

    final baseStyle = TextStyle(
      color: theme.textPrimary,
      height: 1.2,
      fontSize: 14,
    );
    final highlightStyle = baseStyle.copyWith(
      backgroundColor: theme.buttonPrimary.withValues(alpha: 0.25),
      color: theme.textPrimary,
      fontWeight: FontWeight.w600,
    );

    InlineSpan buildSpans() {
      if (ws == null ||
          we == null ||
          ws < 0 ||
          we <= ws ||
          ws >= sentence.length) {
        return TextSpan(text: sentence, style: baseStyle);
      }
      final safeEnd = we.clamp(0, sentence.length);
      final before = sentence.substring(0, ws);
      final word = sentence.substring(ws, safeEnd);
      final after = sentence.substring(safeEnd);
      return TextSpan(
        children: [
          if (before.isNotEmpty) TextSpan(text: before, style: baseStyle),
          TextSpan(text: word, style: highlightStyle),
          if (after.isNotEmpty) TextSpan(text: after, style: baseStyle),
        ],
      );
    }

    return QonduitCard(
      padding: const EdgeInsets.all(Spacing.sm),
      child: RichText(text: buildSpans()),
    );
  }

  bool get _shouldShowTypingIndicator =>
      widget.isStreaming && _isAssistantResponseEmpty;

  bool get _isAssistantResponseEmpty {
    final content = widget.message.content.trim();
    if (content.isNotEmpty) {
      return false;
    }

    final hasFiles = widget.message.files?.isNotEmpty ?? false;
    if (hasFiles) {
      return false;
    }

    final hasAttachments = widget.message.attachmentIds?.isNotEmpty ?? false;
    if (hasAttachments) {
      return false;
    }

    // Check if there's a pending (not done) visible status - those have shimmer
    // so we don't need the typing indicator. But if all visible statuses are
    // done (e.g., "Retrieved 1 source"), show typing indicator to indicate
    // the model is still working on generating a response.
    final visibleStatuses = widget.message.statusHistory
        .where((status) => status.hidden != true)
        .toList();
    final hasPendingStatus = visibleStatuses.any(
          (status) => status.done != true,
    );
    if (hasPendingStatus) {
      // Pending status has shimmer effect, no need for typing indicator
      return false;
    }
    // If all statuses are done but no content yet, show typing indicator

    final hasFollowUps = widget.message.followUps.isNotEmpty;
    if (hasFollowUps) {
      return false;
    }

    final hasCodeExecutions = widget.message.codeExecutions.isNotEmpty;
    if (hasCodeExecutions) {
      return false;
    }

    // Check for tool calls in the content using ToolCallsParser
    final hasToolCalls =
        ToolCallsParser.segments(
          content,
        )?.any((segment) => segment.isToolCall) ??
            false;
    return !hasToolCalls;
  }

  void _buildCachedAvatar() {
    final theme = context.qonduitTheme;
    final iconUrl = widget.modelIconUrl?.trim();
    final hasIcon = iconUrl != null && iconUrl.isNotEmpty;

    final Widget leading = hasIcon
        ? ModelAvatar(size: 20, imageUrl: iconUrl, label: widget.modelName)
        : Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        color: theme.buttonPrimary,
        borderRadius: BorderRadius.circular(AppBorderRadius.small),
      ),
      child: Icon(
        Icons.auto_awesome,
        color: theme.buttonPrimaryText,
        size: 12,
      ),
    );

    _cachedAvatar = Padding(
      padding: const EdgeInsets.only(bottom: Spacing.md),
      child: Row(
        children: [
          leading,
          const SizedBox(width: Spacing.xs),
          Flexible(
            child: MiddleEllipsisText(
              widget.modelName ?? 'Assistant',
              style: TextStyle(
                color: theme.textSecondary,
                fontSize: AppTypography.bodySmall,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.1,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Called on each streaming chunk to drive the fade-in animation
  /// and trigger haptic feedback.
  void _onStreamingChunk(int previousLength, int newLength) {
    if (newLength <= previousLength) return;

    // Haptic: triple-tap when main content first arrives
    if (previousLength == 0 && !_hasTriggeredContentHaptic) {
      _hasTriggeredContentHaptic = true;
      _tripleHaptic();
    }

    // Respect reduced motion preference
    if (MediaQuery.of(context).disableAnimations) {
      _chunkFadeController.value = 1.0;
    } else {
      _chunkFadeController.forward(from: 0.0);
    }
  }

  /// Fires a single haptic impulse if the user has haptics enabled.
  void _streamingHaptic(HapticType type) {
    final enabled = ref.read(hapticEnabledProvider);
    PlatformService.hapticFeedbackWithSettings(
      type: type,
      hapticEnabled: enabled,
    );
  }

  /// Fires three distinct haptic taps to signal content arrival.
  ///
  /// Each tap is spaced 150ms apart so the user perceives three
  /// separate impulses rather than a single buzz.
  void _tripleHaptic() {
    final enabled = ref.read(hapticEnabledProvider);
    if (!enabled) return;
    PlatformService.hapticFeedback(type: HapticType.medium);
    Future.delayed(const Duration(milliseconds: 150), () {
      if (!mounted) return;
      PlatformService.hapticFeedback(type: HapticType.medium);
    });
    Future.delayed(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      PlatformService.hapticFeedback(type: HapticType.medium);
    });
  }

  /// Subscribes to [streamingContentProvider] only while this message is
  /// actively streaming. Uses [ref.listenManual] for explicit lifecycle
  /// control instead of calling [ref.listen] inside [build].
  void _syncStreamingContentSubscription() {
    _streamingContentSub?.close();
    _streamingContentSub = null;

    if (widget.isStreaming) {
      _streamingContentSub = ref.listenManual(streamingContentProvider, (
          prev,
          next,
          ) {
        if (next != null && next != _lastStreamingContent) {
          _lastStreamingContent = next;
          unawaited(_reparseSections(next));
        }
      }, fireImmediately: true);
    }
  }

  @override
  void dispose() {
    _streamingContentSub?.close();
    _typingGateTimer?.cancel();
    _ttsPlainTextDebounce?.cancel();
    _pendingTtsPlainTextPayload = null;
    _pendingTtsPlainTextSource = null;
    _fadeController.dispose();
    _slideController.dispose();
    _chunkFadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _buildDocumentationMessage();
  }

  Widget _buildDocumentationMessage() {
    final visibleStatusHistory = widget.message.statusHistory
        .where((status) => status.hidden != true)
        .toList(growable: false);
    final hasStatusTimeline = visibleStatusHistory.isNotEmpty;
    final hasCodeExecutions = widget.message.codeExecutions.isNotEmpty;
    final hasFollowUps =
        widget.showFollowUps &&
            widget.message.followUps.isNotEmpty &&
            !widget.isStreaming;
    final bool showingVersion = _activeVersionIndex >= 0;
    final activeFiles = showingVersion
        ? widget.message.versions[_activeVersionIndex].files
        : widget.message.files;
    final hasSources = widget.message.sources.isNotEmpty;
    final codeEditArtifact = _extractCodeEditArtifactInfo(
      ((_activeVersionIndex >= 0
          ? widget.message.versions[_activeVersionIndex].content
          : widget.message.content) ?? '')
          .toString(),
    );

    final content = Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16, right: Spacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Cached AI Name and Avatar to prevent flashing
          _cachedAvatar ?? const SizedBox.shrink(),

          // Reasoning blocks are now rendered inline where they appear

          // Documentation-style content without heavy bubble; premium markdown
          SizedBox(
            width: double.infinity,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Display attachments - prioritize files array over attachmentIds to avoid duplication
                if (activeFiles != null && activeFiles.isNotEmpty) ...[
                  _buildFilesFromArray(),
                  const SizedBox(height: Spacing.md),
                ] else if (widget.message.attachmentIds != null &&
                    widget.message.attachmentIds!.isNotEmpty) ...[
                  _buildAttachmentItems(),
                  const SizedBox(height: Spacing.md),
                ],

                if (hasStatusTimeline) ...[
                  StreamingStatusWidget(
                    updates: visibleStatusHistory,
                    isStreaming: widget.isStreaming,
                  ),
                  const SizedBox(height: Spacing.xs),
                ],

                // Tool calls are rendered inline via segmented content
                // Smoothly crossfade between typing indicator and content
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, anim) {
                    return FadeTransition(
                      opacity: CurvedAnimation(
                        parent: anim,
                        curve: Curves.easeOutCubic,
                        reverseCurve: Curves.easeInCubic,
                      ),
                      child: child,
                    );
                  },
                  child: (_allowTypingIndicator && _shouldShowTypingIndicator)
                      ? KeyedSubtree(
                    key: const ValueKey('typing'),
                    child: _buildTypingIndicator(),
                  )
                      : KeyedSubtree(
                    key: const ValueKey('content'),
                    child: _buildSegmentedContent(),
                  ),
                ),

                // Display error banner if message or active version has an error
                if (_getActiveError() != null) ...[
                  const SizedBox(height: Spacing.sm),
                  _buildErrorBanner(_getActiveError()!),
                ],

                if (hasCodeExecutions) ...[
                  const SizedBox(height: Spacing.md),
                  CodeExecutionListView(
                    executions: widget.message.codeExecutions,
                  ),
                ],

                if (hasSources) ...[
                  const SizedBox(height: Spacing.xs),
                  OpenWebUISourcesWidget(
                    sources: widget.message.sources,
                    messageId: widget.message.id,
                  ),
                ],

                if (codeEditArtifact != null) ...[
                  const SizedBox(height: Spacing.md),
                  _buildCodeEditArtifactCard(codeEditArtifact),
                ],

                // Version switcher moved inline with action buttons below
              ],
            ),
          ),

          // Action buttons below the message content (only after streaming completes)
          if (!widget.isStreaming) ...[
            const SizedBox(height: Spacing.sm),
            _buildActionButtons(),
            if (hasFollowUps) ...[
              const SizedBox(height: Spacing.md),
              FollowUpSuggestionBar(
                suggestions: widget.message.followUps,
                onSelected: _handleFollowUpTap,
                isBusy: widget.isStreaming,
              ),
            ],
          ],
        ],
      ),
    );

    // Animate on first appearance only, not on every streaming rebuild
    if (!_hasAnimated) {
      _hasAnimated = true;
      _fadeController.forward();
      _slideController.forward();
    }

    return FadeTransition(
      opacity: _fadeController,
      child: SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, 0.1), end: Offset.zero)
            .animate(
          CurvedAnimation(
            parent: _slideController,
            curve: Curves.easeOutCubic,
          ),
        ),
        child: content,
      ),
    );
  }

  /// Get the error for the currently active message or version.
  ChatMessageError? _getActiveError() {
    if (widget.message is! ChatMessage) return null;
    final msg = widget.message as ChatMessage;

    // If viewing a version, return the version's error
    if (_activeVersionIndex >= 0 && _activeVersionIndex < msg.versions.length) {
      return msg.versions[_activeVersionIndex].error;
    }

    // Otherwise return the main message's error
    return msg.error;
  }

  /// Build an error banner matching OpenWebUI's error display style.
  /// Shows error content in a red-tinted container with an info icon.
  Widget _buildErrorBanner(ChatMessageError error) {
    final theme = Theme.of(context);
    final errorColor = theme.colorScheme.error;
    final errorContent = error.content;

    // If no content, show a generic error message
    final displayText = (errorContent != null && errorContent.isNotEmpty)
        ? errorContent
        : 'An error occurred while generating this response.';

    return Container(
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: errorColor.withValues(alpha: 0.1),
        border: Border.all(color: errorColor.withValues(alpha: 0.2)),
        borderRadius: BorderRadius.circular(Spacing.sm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 20, color: errorColor),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              displayText,
              style: theme.textTheme.bodyMedium?.copyWith(color: errorColor),
            ),
          ),
        ],
      ),
    );
  }

  _CodeEditArtifactInfo? _extractCodeEditArtifactInfo(String content) {
    final preparedMatch = RegExp(
      r'Prepared File:\s*(.+)',
      multiLine: true,
    ).firstMatch(content);
    final pathMatch = RegExp(
      r'Saved Path:\s*(.+)',
      multiLine: true,
    ).firstMatch(content);

    if (preparedMatch == null || pathMatch == null) {
      return null;
    }

    final name = preparedMatch.group(1)?.trim() ?? '';
    final savedPath = pathMatch.group(1)?.trim() ?? '';
    if (name.isEmpty || savedPath.isEmpty) {
      return null;
    }

    return _CodeEditArtifactInfo(name: name, savedPath: savedPath);
  }

  Widget _buildCodeEditArtifactCard(_CodeEditArtifactInfo artifact) {
    final theme = Theme.of(context);
    final border = context.qonduitTheme.cardBorder;
    final bg = context.qonduitTheme.cardBackground;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppBorderRadius.card),
        border: Border.all(color: border, width: BorderWidth.thin),
        boxShadow: QonduitShadows.messageBubble(context),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Platform.isIOS ? CupertinoIcons.doc_text : Icons.description_outlined,
                size: 18,
                color: context.qonduitTheme.textPrimary,
              ),
              const SizedBox(width: Spacing.xs),
              Expanded(
                child: Text(
                  artifact.name,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: context.qonduitTheme.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          Text(
            'Modified file saved by Qonduit',
            style: theme.textTheme.bodySmall?.copyWith(
              color: context.qonduitTheme.textSecondary,
            ),
          ),
          const SizedBox(height: Spacing.xs),
          SelectableText(
            artifact.savedPath,
            style: theme.textTheme.bodySmall?.copyWith(
              color: context.qonduitTheme.textSecondary,
            ),
          ),
          const SizedBox(height: Spacing.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: ChatActionButton(
              icon: Platform.isIOS ? CupertinoIcons.doc_on_doc : Icons.copy_outlined,
              label: 'Copy path',
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: artifact.savedPath));
                if (!mounted) return;
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                  const SnackBar(content: Text('Saved path copied')),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEnhancedMarkdownContent(String content) {
    if (content.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    // Note: The reasoning/tool-calls parsers now handle all tag formats including
    // raw tags like <think>, <thinking>, <reasoning>, etc. They are extracted
    // and rendered as collapsible tiles, so we don't need to strip them here.
    // The markdown widget will receive only the text segments.

    // Process images in the remaining text
    final processedContent = _processContentForImages(content);

    Widget buildDefault(BuildContext context) => StreamingMarkdownWidget(
      content: processedContent,
      isStreaming: widget.isStreaming,
      onTapLink: (url, _) => _launchUri(url),
      sources: widget.message.sources,
      imageBuilderOverride: (uri, title, alt) {
        // Route markdown images through the enhanced image widget so they
        // get caching, auth headers, fullscreen viewer, and sharing.
        return EnhancedImageAttachment(
          attachmentId: uri.toString(),
          isMarkdownFormat: true,
          constraints: const BoxConstraints(maxWidth: 500, maxHeight: 400),
          disableAnimation: widget.isStreaming,
        );
      },
    );

    final responseBuilder = ref.watch(assistantResponseBuilderProvider);
    if (responseBuilder != null) {
      final contextData = AssistantResponseContext(
        message: widget.message,
        markdown: processedContent,
        isStreaming: widget.isStreaming,
        buildDefault: buildDefault,
      );
      return responseBuilder(context, contextData);
    }

    return buildDefault(context);
  }

  String _processContentForImages(String content) {
    // Check if content contains image markdown or base64 data URLs
    // This ensures images generated by AI are properly formatted

    // Quick check: only process if we have base64 images and no markdown
    if (!content.contains('data:image/') || content.contains('![')) {
      return content;
    }

    // If we find base64 images not wrapped in markdown, wrap them
    if (_base64ImagePattern.hasMatch(content)) {
      content = content.replaceAllMapped(_base64ImagePattern, (match) {
        final imageData = match.group(0)!;
        // Check if this image is already in markdown format (simple string check)
        if (!content.contains('![$imageData)')) {
          return '\n![Generated Image]($imageData)\n';
        }
        return imageData;
      });
    }

    return content;
  }

  Widget _buildAttachmentItems() {
    if (widget.message.attachmentIds == null ||
        widget.message.attachmentIds!.isEmpty) {
      return const SizedBox.shrink();
    }

    final imageCount = widget.message.attachmentIds!.length;

    // Display images in a clean, modern layout for assistant messages
    // Use AnimatedSwitcher for smooth transitions when loading
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      switchInCurve: Curves.easeInOut,
      child: imageCount == 1
          ? Container(
        key: ValueKey('single_item_${widget.message.attachmentIds![0]}'),
        child: EnhancedAttachment(
          attachmentId: widget.message.attachmentIds![0],
          isMarkdownFormat: true,
          constraints: const BoxConstraints(
            maxWidth: 500,
            maxHeight: 400,
          ),
          disableAnimation: widget.isStreaming,
        ),
      )
          : Wrap(
        key: ValueKey(
          'multi_items_${widget.message.attachmentIds!.join('_')}',
        ),
        spacing: Spacing.sm,
        runSpacing: Spacing.sm,
        children: widget.message.attachmentIds!.map<Widget>((
            attachmentId,
            ) {
          return EnhancedAttachment(
            key: ValueKey('attachment_$attachmentId'),
            attachmentId: attachmentId,
            isMarkdownFormat: true,
            constraints: BoxConstraints(
              maxWidth: imageCount == 2 ? 245 : 160,
              maxHeight: imageCount == 2 ? 245 : 160,
            ),
            disableAnimation: widget.isStreaming,
          );
        }).toList(),
      ),
    );
  }

  Widget _buildFilesFromArray() {
    final filesArray = _activeVersionIndex >= 0
        ? widget.message.versions[_activeVersionIndex].files
        : widget.message.files;
    if (filesArray == null || filesArray.isEmpty) {
      return const SizedBox.shrink();
    }

    final allFiles = filesArray;

    // Separate images and non-image files
    // Match OpenWebUI: type === 'image' OR content_type starts with 'image/'
    final imageFiles = allFiles.where(isImageFile).toList();
    final nonImageFiles = allFiles.where((file) => !isImageFile(file)).toList();

    final widgets = <Widget>[];

    // Add images first
    if (imageFiles.isNotEmpty) {
      widgets.add(_buildImagesFromFiles(imageFiles));
    }

    // Add non-image files
    if (nonImageFiles.isNotEmpty) {
      if (widgets.isNotEmpty) {
        widgets.add(const SizedBox(height: Spacing.sm));
      }
      widgets.add(_buildNonImageFiles(nonImageFiles));
    }

    if (widgets.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }

  Widget _buildImagesFromFiles(List<dynamic> imageFiles) {
    final imageCount = imageFiles.length;

    // Display images using EnhancedImageAttachment for consistency
    // Use AnimatedSwitcher for smooth transitions
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      switchInCurve: Curves.easeInOut,
      child: imageCount == 1
          ? Container(
        key: ValueKey('file_single_${imageFiles[0]['url']}'),
        child: Builder(
          builder: (context) {
            final imageUrl = getFileUrl(imageFiles[0]);
            if (imageUrl == null) return const SizedBox.shrink();

            return EnhancedImageAttachment(
              attachmentId:
              imageUrl, // Pass URL directly as it handles URLs
              isMarkdownFormat: true,
              constraints: const BoxConstraints(
                maxWidth: 500,
                maxHeight: 400,
              ),
              disableAnimation:
              false, // Keep animations enabled to prevent black display
              httpHeaders: _headersForFile(imageFiles[0]),
            );
          },
        ),
      )
          : Wrap(
        key: ValueKey(
          'file_multi_${imageFiles.map((f) => f['url']).join('_')}',
        ),
        spacing: Spacing.sm,
        runSpacing: Spacing.sm,
        children: imageFiles.map<Widget>((file) {
          final imageUrl = getFileUrl(file);
          if (imageUrl == null) return const SizedBox.shrink();

          return EnhancedImageAttachment(
            key: ValueKey('gen_attachment_$imageUrl'),
            attachmentId: imageUrl, // Pass URL directly
            isMarkdownFormat: true,
            constraints: BoxConstraints(
              maxWidth: imageCount == 2 ? 245 : 160,
              maxHeight: imageCount == 2 ? 245 : 160,
            ),
            disableAnimation:
            false, // Keep animations enabled to prevent black display
            httpHeaders: _headersForFile(file),
          );
        }).toList(),
      ),
    );
  }

  Map<String, String>? _headersForFile(dynamic file) {
    if (file is! Map) return null;
    final rawHeaders = file['headers'];
    if (rawHeaders is! Map) return null;
    final result = <String, String>{};
    rawHeaders.forEach((key, value) {
      final keyString = key?.toString();
      final valueString = value?.toString();
      if (keyString != null &&
          keyString.isNotEmpty &&
          valueString != null &&
          valueString.isNotEmpty) {
        result[keyString] = valueString;
      }
    });
    return result.isEmpty ? null : result;
  }

  Widget _buildNonImageFiles(List<dynamic> nonImageFiles) {
    return Wrap(
      spacing: Spacing.sm,
      runSpacing: Spacing.sm,
      children: nonImageFiles.map<Widget>((file) {
        final fileUrl = getFileUrl(file);
        if (fileUrl == null) return const SizedBox.shrink();

        // Extract file ID from URL - handle formats:
        // - Bare file ID (new OpenWebUI format): "abc-123-def"
        // - /api/v1/files/{id} (legacy format)
        // - /api/v1/files/{id}/content (legacy format)
        String attachmentId = fileUrl;
        if (fileUrl.contains('/api/v1/files/')) {
          final fileIdMatch = _fileIdPattern.firstMatch(fileUrl);
          if (fileIdMatch != null) {
            attachmentId = fileIdMatch.group(1)!;
          }
        }

        return EnhancedAttachment(
          key: ValueKey('file_attachment_$attachmentId'),
          attachmentId: attachmentId,
          isMarkdownFormat: true,
          constraints: const BoxConstraints(maxWidth: 300, maxHeight: 100),
          disableAnimation: widget.isStreaming,
        );
      }).toList(),
    );
  }

  Widget _buildTypingIndicator() {
    final theme = context.qonduitTheme;
    final dotColor = theme.textSecondary.withValues(alpha: 0.75);

    const double dotSize = 8.0;
    const double dotSpacing = 6.0;
    const int numberOfDots = 3;

    // Create three dots with staggered animations
    final dots = List.generate(numberOfDots, (index) {
      final delay = Duration(milliseconds: 150 * index);

      return Container(
        width: dotSize,
        height: dotSize,
        decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
      )
          .animate(onPlay: (controller) => controller.repeat())
          .then(delay: delay)
          .fadeIn(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      )
          .scale(
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeInOut,
        begin: const Offset(0.4, 0.4),
        end: const Offset(1, 1),
      )
          .then()
          .scale(
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeInOut,
        begin: const Offset(1.2, 1.2),
        end: const Offset(0.5, 0.5),
      );
    });

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Add left padding to prevent clipping when dots scale up
          const SizedBox(width: dotSize * 0.2),
          for (int i = 0; i < numberOfDots; i++) ...[
            dots[i],
            if (i < numberOfDots - 1) const SizedBox(width: dotSpacing),
          ],
          // Add right padding to prevent clipping when dots scale up
          const SizedBox(width: dotSize * 0.2),
        ],
      ),
    );
  }

  Widget _buildActionButtons() {
    final l10n = AppLocalizations.of(context)!;
    final ttsState = ref.watch(textToSpeechControllerProvider);
    final messageId = _messageId;
    final hasSpeechText = _ttsPlainText.trim().isNotEmpty;
    // Check for error using the error field (preferred) or legacy content detection
    // Also check the active version's error if viewing a version
    final activeError = _getActiveError();
    final hasErrorField = activeError != null;
    final isErrorMessage =
        hasErrorField ||
            widget.message.content.contains('⚠️') ||
            widget.message.content.contains('Error') ||
            widget.message.content.contains('timeout') ||
            widget.message.content.contains('retry options');

    final isActiveMessage = ttsState.activeMessageId == messageId;
    final isSpeaking =
        isActiveMessage && ttsState.status == TtsPlaybackStatus.speaking;
    final isPaused =
        isActiveMessage && ttsState.status == TtsPlaybackStatus.paused;
    final isBusy =
        isActiveMessage &&
            (ttsState.status == TtsPlaybackStatus.loading ||
                ttsState.status == TtsPlaybackStatus.initializing);
    final bool disableDueToStreaming = widget.isStreaming && !isActiveMessage;
    final bool ttsAvailable = !ttsState.initialized || ttsState.available;
    final bool showStopState =
        isActiveMessage && (isSpeaking || isPaused || isBusy);
    final bool shouldShowTtsButton = hasSpeechText && messageId.isNotEmpty;
    final bool canStartTts =
        shouldShowTtsButton && !disableDueToStreaming && ttsAvailable;

    VoidCallback? ttsOnTap;
    if (showStopState || canStartTts) {
      ttsOnTap = () {
        if (messageId.isEmpty) {
          return;
        }
        ref
            .read(textToSpeechControllerProvider.notifier)
            .toggleForMessage(messageId: messageId, text: _ttsPlainText);
      };
    }

    final IconData listenIcon = Platform.isIOS
        ? CupertinoIcons.speaker_2_fill
        : Icons.volume_up;
    final IconData stopIcon = Platform.isIOS
        ? CupertinoIcons.stop_fill
        : Icons.stop;
    final IconData ttsIcon = showStopState ? stopIcon : listenIcon;
    final String ttsLabel = showStopState ? l10n.ttsStop : l10n.ttsListen;
    final String ttsSfSymbol = showStopState
        ? 'stop.fill'
        : 'speaker.wave.2.fill';

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (shouldShowTtsButton)
          _buildActionButton(
            icon: ttsIcon,
            label: ttsLabel,
            onTap: ttsOnTap,
            sfSymbol: ttsSfSymbol,
          ),
        _buildActionButton(
          icon: Platform.isIOS
              ? CupertinoIcons.doc_on_clipboard
              : Icons.content_copy,
          label: l10n.copy,
          onTap: widget.onCopy,
          sfSymbol: 'doc.on.clipboard',
        ),
        if (widget.message.versions.isNotEmpty && !widget.isStreaming) ...[
          // Inline version toggle: Prev [1/n] Next
          ChatActionButton(
            icon: Platform.isIOS
                ? CupertinoIcons.chevron_left
                : Icons.chevron_left,
            label: l10n.previousLabel,
            sfSymbol: 'chevron.left',
            onTap: () {
              setState(() {
                if (_activeVersionIndex < 0) {
                  _activeVersionIndex = widget.message.versions.length - 1;
                } else if (_activeVersionIndex > 0) {
                  _activeVersionIndex -= 1;
                }
                unawaited(_reparseSections());
              });
            },
          ),
          QonduitChip(
            label:
            '${_activeVersionIndex < 0 ? (widget.message.versions.length + 1) : (_activeVersionIndex + 1)}/${widget.message.versions.length + 1}',
            isCompact: true,
          ),
          ChatActionButton(
            icon: Platform.isIOS
                ? CupertinoIcons.chevron_right
                : Icons.chevron_right,
            label: l10n.nextLabel,
            sfSymbol: 'chevron.right',
            onTap: () {
              setState(() {
                if (_activeVersionIndex < 0) return; // already live
                if (_activeVersionIndex < widget.message.versions.length - 1) {
                  _activeVersionIndex += 1;
                } else {
                  _activeVersionIndex = -1; // move to live
                }
                unawaited(_reparseSections());
              });
            },
          ),
        ],
        // Usage info button (like Open WebUI)
        if (widget.message.usage != null &&
            widget.message.usage!.isNotEmpty) ...[
          _buildActionButton(
            icon: Platform.isIOS ? CupertinoIcons.info : Icons.info_outline,
            label: l10n.usageInfo,
            onTap: () => UsageStatsModal.show(context, widget.message.usage!),
            sfSymbol: 'info.circle',
          ),
        ],
        if (isErrorMessage) ...[
          _buildActionButton(
            icon: Platform.isIOS
                ? CupertinoIcons.arrow_clockwise
                : Icons.refresh,
            label: l10n.retry,
            onTap: widget.onRegenerate,
            sfSymbol: 'arrow.clockwise',
          ),
        ] else ...[
          _buildActionButton(
            icon: Platform.isIOS ? CupertinoIcons.refresh : Icons.refresh,
            label: l10n.regenerate,
            onTap: widget.onRegenerate,
            sfSymbol: 'arrow.clockwise',
          ),
        ],
      ],
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    VoidCallback? onTap,
    String? sfSymbol,
  }) {
    return ChatActionButton(
      icon: icon,
      label: label,
      onTap: onTap,
      sfSymbol: sfSymbol,
    );
  }
}

String _buildTtsPlainTextWorker(Map<String, dynamic> payload) {
  final rawSegments = payload['segments'];
  final fallback = payload['fallback'] as String? ?? '';
  final segments = rawSegments is List ? rawSegments.cast<dynamic>() : const [];

  if (segments.isEmpty) {
    return QonduitMarkdownPreprocessor.toPlainText(fallback);
  }

  final buffer = StringBuffer();
  for (final segment in segments) {
    if (segment is! String || segment.isEmpty) continue;
    final sanitized = QonduitMarkdownPreprocessor.toPlainText(segment);
    if (sanitized.isEmpty) continue;
    if (buffer.isNotEmpty) {
      buffer.writeln();
      buffer.writeln();
    }
    buffer.write(sanitized);
  }

  final result = buffer.toString().trim();
  if (result.isEmpty) {
    return QonduitMarkdownPreprocessor.toPlainText(fallback);
  }
  return result;
}

Future<void> _launchUri(String url) async {
  if (url.isEmpty) return;
  try {
    await launchUrlString(url, mode: LaunchMode.externalApplication);
  } catch (err) {
    DebugLogger.log('Unable to open url $url: $err', scope: 'chat/assistant');
  }
}

/// Overlays a vertical gradient [ShaderMask] on the child widget to
/// fade in the trailing portion of newly-arrived streaming text.
///
/// Uses a fixed pixel height for the fade region so the effect
/// remains visible regardless of total content length. The bottom
/// [_fadeHeightPx] pixels animate from semi-transparent to fully
/// opaque over the [animation] duration.
class _StreamingFadeOverlay extends AnimatedWidget {
  const _StreamingFadeOverlay({
    required Animation<double> animation,
    required this.child,
  }) : super(listenable: animation);

  final Widget child;

  /// Fixed height in logical pixels for the fade region.
  /// Covers roughly 2-3 lines of text.
  static const double _fadeHeightPx = 36.0;

  @override
  Widget build(BuildContext context) {
    final t = (listenable as Animation<double>).value;

    // Once fully animated, skip the ShaderMask entirely.
    if (t >= 1.0) return child;

    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) {
        // Compute fade start as a fraction of total height.
        // For short content (< _fadeHeightPx), fade the entire widget.
        final fadeStartFrac = bounds.height > _fadeHeightPx
            ? (bounds.height - _fadeHeightPx) / bounds.height
            : 0.0;

        return LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: [fadeStartFrac, 1.0],
          colors: [
            const Color(0xFFFFFFFF),
            Color.fromRGBO(255, 255, 255, t.clamp(0.3, 1.0)),
          ],
        ).createShader(bounds);
      },
      child: child,
    );
  }
}