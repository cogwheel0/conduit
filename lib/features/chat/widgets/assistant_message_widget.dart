import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:io' show Platform;
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/markdown/streaming_markdown_widget.dart';
import '../../../core/utils/reasoning_parser.dart';
import '../../../core/utils/message_segments.dart';
import '../../../core/utils/tool_calls_parser.dart';
import '../../../core/models/chat_message.dart';
import '../../../shared/widgets/markdown/markdown_preprocessor.dart';
import '../providers/text_to_speech_provider.dart';
import 'enhanced_image_attachment.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'enhanced_attachment.dart';
import 'package:conduit/shared/widgets/chat_action_button.dart';
import '../../../shared/widgets/model_avatar.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/middle_ellipsis_text.dart';
import 'package:url_launcher/url_launcher_string.dart';
import '../providers/chat_providers.dart' show sendMessageWithContainer;
import '../../../core/utils/debug_logger.dart';
import 'sources/openwebui_sources.dart';
import '../providers/assistant_response_builder_provider.dart';
import '../../../core/services/worker_manager.dart';
import 'streaming_status_widget.dart';

// Pre-compiled regex patterns for image processing (performance optimization)
final _base64ImagePattern = RegExp(r'data:image/[^;]+;base64,[A-Za-z0-9+/]+=*');
// Handle both URL formats: /api/v1/files/{id} and /api/v1/files/{id}/content
final _fileIdPattern = RegExp(r'/api/v1/files/([^/]+)(?:/content)?$');

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
  final Set<String> _expandedToolIds = {};
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
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _slideController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    // Parse reasoning and tool-calls sections
    unawaited(_reparseSections());
    _updateTypingIndicatorGate();
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

  Future<void> _reparseSections() async {
    final raw0 = _activeVersionIndex >= 0
        ? (widget.message.versions[_activeVersionIndex].content as String?) ??
              ''
        : widget.message.content ?? '';
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

    if (!mounted) return;
    setState(() {
      _segments = segments;
    });
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
      return ConduitMarkdownPreprocessor.toPlainText(fallback);
    }

    final buffer = StringBuffer();
    for (final segment in segments) {
      final sanitized = ConduitMarkdownPreprocessor.toPlainText(segment);
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
      return ConduitMarkdownPreprocessor.toPlainText(fallback);
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

  // Tool call tile - minimal design inspired by OpenWebUI
  Widget _buildToolCallTile(ToolCallEntry tc) {
    final isExpanded = _expandedToolIds.contains(tc.id);
    final theme = context.conduitTheme;
    // Show shimmer when streaming and tool call is not done
    final showShimmer = widget.isStreaming && !tc.done;

    String pretty(dynamic v, {int max = 1200}) {
      try {
        final formatted = const JsonEncoder.withIndent('  ').convert(v);
        return formatted.length > max
            ? '${formatted.substring(0, max)}\n…'
            : formatted;
      } catch (_) {
        final s = v?.toString() ?? '';
        return s.length > max ? '${s.substring(0, max)}…' : s;
      }
    }

    Widget buildHeader() {
      final headerWidget = Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            isExpanded
                ? Icons.keyboard_arrow_up_rounded
                : Icons.keyboard_arrow_down_rounded,
            size: 14,
            color: theme.textPrimary.withValues(alpha: 0.8),
          ),
          const SizedBox(width: 2),
          Flexible(
            child: Text(
              tc.done ? 'Used ${tc.name}' : 'Running ${tc.name}…',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppTypography.bodySmall,
                color: theme.textPrimary.withValues(alpha: 0.8),
                height: 1.3,
              ),
            ),
          ),
        ],
      );

      if (showShimmer) {
        return headerWidget
            .animate(onPlay: (controller) => controller.repeat())
            .shimmer(
              duration: 1500.ms,
              color: theme.shimmerHighlight.withValues(alpha: 0.6),
            );
      }
      return headerWidget;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.xs),
      child: GestureDetector(
        onTap: () {
          setState(() {
            if (isExpanded) {
              _expandedToolIds.remove(tc.id);
            } else {
              _expandedToolIds.add(tc.id);
            }
          });
        },
        behavior: HitTestBehavior.opaque,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Minimal header - just text with chevron
            buildHeader(),

            // Expanded content with left border accent
            AnimatedCrossFade(
              firstChild: const SizedBox.shrink(),
              secondChild: Container(
                margin: const EdgeInsets.only(top: Spacing.xs, left: 16),
                padding: const EdgeInsets.symmetric(
                  horizontal: Spacing.sm,
                  vertical: Spacing.xs,
                ),
                decoration: BoxDecoration(
                  color: theme.surfaceContainer.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(4),
                  border: Border(
                    left: BorderSide(
                      color: theme.dividerColor.withValues(alpha: 0.4),
                      width: 2,
                    ),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (tc.arguments != null) ...[
                      Text(
                        'Arguments',
                        style: TextStyle(
                          fontSize: AppTypography.labelSmall,
                          color: theme.textSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      SelectableText(
                        pretty(tc.arguments),
                        style: TextStyle(
                          fontSize: AppTypography.bodySmall,
                          color: theme.textSecondary,
                          fontFamily: AppTypography.monospaceFontFamily,
                          height: 1.35,
                        ),
                      ),
                      if (tc.result != null) const SizedBox(height: Spacing.xs),
                    ],

                    if (tc.result != null) ...[
                      Text(
                        'Result',
                        style: TextStyle(
                          fontSize: AppTypography.labelSmall,
                          color: theme.textSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      SelectableText(
                        pretty(tc.result),
                        style: TextStyle(
                          fontSize: AppTypography.bodySmall,
                          color: theme.textSecondary,
                          fontFamily: AppTypography.monospaceFontFamily,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              crossFadeState: isExpanded
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              duration: const Duration(milliseconds: 200),
            ),

            // Render file images when tool call is done
            // Mirrors Open WebUI's Collapsible.svelte file rendering
            if (tc.done && tc.files != null) ...[
              _buildToolCallFiles(tc.files!),
            ],
          ],
        ),
      ),
    );
  }

  /// Builds image widgets from tool call files array.
  /// Mirrors Open WebUI's Collapsible.svelte file rendering logic:
  /// - String starting with 'data:image/' -> base64 image
  /// - Object with type='image' and url -> network image
  Widget _buildToolCallFiles(List<dynamic> files) {
    final imageUrls = <String>[];

    for (final file in files) {
      if (file is String) {
        // Base64 image data URL
        if (file.startsWith('data:image/')) {
          imageUrls.add(file);
        }
      } else if (file is Map) {
        // Object with type and url
        final type = file['type']?.toString();
        final url = file['url']?.toString();
        if (type == 'image' && url != null && url.isNotEmpty) {
          imageUrls.add(url);
        }
      }
    }

    if (imageUrls.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(top: Spacing.sm),
      child: Wrap(
        spacing: Spacing.sm,
        runSpacing: Spacing.sm,
        children: imageUrls.map((url) {
          return EnhancedImageAttachment(
            attachmentId: url,
            isMarkdownFormat: true,
            constraints: BoxConstraints(
              maxWidth: imageUrls.length == 1 ? 400 : 200,
              maxHeight: imageUrls.length == 1 ? 300 : 150,
            ),
            disableAnimation: false,
          );
        }).toList(),
      ),
    );
  }

  Widget _buildSegmentedContent() {
    final children = <Widget>[];
    bool firstToolSpacerAdded = false;
    bool hasNonTextSegment = false;
    int idx = 0;
    for (final seg in _segments) {
      if (seg.isTool && seg.toolCall != null) {
        // Add top spacing before the first tool block for clarity
        if (!firstToolSpacerAdded) {
          children.add(const SizedBox(height: Spacing.sm));
          firstToolSpacerAdded = true;
        }
        children.add(_buildToolCallTile(seg.toolCall!));
        hasNonTextSegment = true;
      } else if (seg.isReasoning && seg.reasoning != null) {
        children.add(_buildReasoningTile(seg.reasoning!, idx));
        hasNonTextSegment = true;
      } else if ((seg.text ?? '').trim().isNotEmpty) {
        // Add spacing before text content if it follows non-text segments
        if (hasNonTextSegment) {
          children.add(const SizedBox(height: Spacing.sm));
          hasNonTextSegment = false;
        }
        children.add(_buildEnhancedMarkdownContent(seg.text!));
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
    final theme = context.conduitTheme;
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

    return ConduitCard(
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

    final hasVisibleStatus = widget.message.statusHistory
        .where((status) => status.hidden != true)
        .isNotEmpty;
    if (hasVisibleStatus) {
      return false;
    }

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
    final theme = context.conduitTheme;
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

  @override
  void dispose() {
    _typingGateTimer?.cancel();
    _ttsPlainTextDebounce?.cancel();
    _pendingTtsPlainTextPayload = null;
    _pendingTtsPlainTextSource = null;
    _fadeController.dispose();
    _slideController.dispose();
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

    return Container(
          width: double.infinity,
          margin: const EdgeInsets.only(
            bottom: 16,
            left: Spacing.xs,
            right: Spacing.xs,
          ),
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
                        final fade = CurvedAnimation(
                          parent: anim,
                          curve: Curves.easeOutCubic,
                          reverseCurve: Curves.easeInCubic,
                        );
                        final size = CurvedAnimation(
                          parent: anim,
                          curve: Curves.easeOutCubic,
                          reverseCurve: Curves.easeInCubic,
                        );
                        return FadeTransition(
                          opacity: fade,
                          child: SizeTransition(
                            sizeFactor: size,
                            axisAlignment: -1.0, // collapse/expand from top
                            child: child,
                          ),
                        );
                      },
                      child:
                          (_allowTypingIndicator && _shouldShowTypingIndicator)
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
        )
        .animate()
        .fadeIn(duration: const Duration(milliseconds: 300))
        .slideY(
          begin: 0.1,
          end: 0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        );
  }

  /// Get the error for the currently active message or version.
  ChatMessageError? _getActiveError() {
    if (widget.message is! ChatMessage) return null;
    final msg = widget.message as ChatMessage;

    // If viewing a version, return the version's error
    if (_activeVersionIndex >= 0 &&
        _activeVersionIndex < msg.versions.length) {
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
          Icon(
            Icons.info_outline,
            size: 20,
            color: errorColor,
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              displayText,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: errorColor,
              ),
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
    final imageFiles = allFiles
        .where((file) => file['type'] == 'image')
        .toList();
    final nonImageFiles = allFiles
        .where((file) => file['type'] != 'image')
        .toList();

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
                  final imageUrl = imageFiles[0]['url'] as String?;
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
                final imageUrl = file['url'] as String?;
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
        final fileUrl = file['url'] as String?;

        if (fileUrl == null) return const SizedBox.shrink();

        // Extract file ID from URL - handle both formats:
        // /api/v1/files/{id} and /api/v1/files/{id}/content
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
    final theme = context.conduitTheme;
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
    final isErrorMessage = hasErrorField ||
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

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (shouldShowTtsButton)
          _buildActionButton(icon: ttsIcon, label: ttsLabel, onTap: ttsOnTap),
        _buildActionButton(
          icon: Platform.isIOS
              ? CupertinoIcons.doc_on_clipboard
              : Icons.content_copy,
          label: l10n.copy,
          onTap: widget.onCopy,
        ),
        if (widget.message.versions.isNotEmpty && !widget.isStreaming) ...[
          // Inline version toggle: Prev [1/n] Next
          ChatActionButton(
            icon: Icons.chevron_left,
            label: l10n.previousLabel,
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
          ConduitChip(
            label:
                '${_activeVersionIndex < 0 ? (widget.message.versions.length + 1) : (_activeVersionIndex + 1)}/${widget.message.versions.length + 1}',
            isCompact: true,
          ),
          ChatActionButton(
            icon: Icons.chevron_right,
            label: l10n.nextLabel,
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
            onTap: () => _showUsageInfoSheet(context, widget.message.usage!),
          ),
        ],
        if (isErrorMessage) ...[
          _buildActionButton(
            icon: Platform.isIOS
                ? CupertinoIcons.arrow_clockwise
                : Icons.refresh,
            label: l10n.retry,
            onTap: widget.onRegenerate,
          ),
        ] else ...[
          _buildActionButton(
            icon: Platform.isIOS ? CupertinoIcons.refresh : Icons.refresh,
            label: l10n.regenerate,
            onTap: widget.onRegenerate,
          ),
        ],
      ],
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    VoidCallback? onTap,
  }) {
    return ChatActionButton(icon: icon, label: label, onTap: onTap);
  }

  /// Shows a bottom sheet with usage/performance statistics for the response.
  /// Matches Open WebUI's info button behavior but adapted for mobile UX.
  void _showUsageInfoSheet(BuildContext context, Map<String, dynamic> usage) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: theme.surfaceBackground,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppBorderRadius.dialog),
        ),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(Spacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title
                Row(
                  children: [
                    Icon(
                      Icons.analytics_outlined,
                      size: IconSize.md,
                      color: theme.textPrimary,
                    ),
                    const SizedBox(width: Spacing.sm),
                    Text(
                      l10n.usageInfoTitle,
                      style: TextStyle(
                        fontSize: AppTypography.bodyLarge,
                        fontWeight: FontWeight.w600,
                        color: theme.textPrimary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Spacing.lg),

                // Stats grid
                ..._buildUsageStats(ctx, usage, l10n, theme),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Builds the list of usage stat widgets from the usage map.
  List<Widget> _buildUsageStats(
    BuildContext context,
    Map<String, dynamic> usage,
    AppLocalizations l10n,
    ConduitThemeExtension theme,
  ) {
    final stats = <Widget>[];

    // Parse all possible fields
    final evalCount = _parseNum(usage['eval_count']);
    final evalDuration = _parseNum(usage['eval_duration']);
    final promptEvalCount = _parseNum(usage['prompt_eval_count']);
    final promptEvalDuration = _parseNum(usage['prompt_eval_duration']);
    final completionTokens = _parseNum(usage['completion_tokens']);
    final promptTokens = _parseNum(usage['prompt_tokens']);
    final totalTokens = _parseNum(usage['total_tokens']);
    // Time fields in seconds (Groq/OpenAI extended format)
    final completionTime = _parseNum(usage['completion_time']);
    final promptTime = _parseNum(usage['prompt_time']);
    final totalTime = _parseNum(usage['total_time']);
    final queueTime = _parseNum(usage['queue_time']);
    // Time fields in nanoseconds (Ollama/llama.cpp format)
    final totalDuration = _parseNum(usage['total_duration']);
    final loadDuration = _parseNum(usage['load_duration']);
    // Reasoning tokens (OpenAI o1/o3 models, Groq)
    final completionDetails = usage['completion_tokens_details'];
    final reasoningTokens = completionDetails is Map
        ? _parseNum(completionDetails['reasoning_tokens'])
        : null;

    // llama.cpp server format: pre-calculated tokens/second values
    final predictedPerSecond = _parseNum(usage['predicted_per_second']);
    final promptPerSecond = _parseNum(usage['prompt_per_second']);
    final predictedN = _parseNum(usage['predicted_n']);
    final promptN = _parseNum(usage['prompt_n']);

    // --- Token Generation Speed ---
    // Priority: llama.cpp direct > Ollama calculated > Groq/OpenAI > count only
    if (predictedPerSecond != null && predictedPerSecond > 0) {
      // llama.cpp server: pre-calculated tokens/second
      stats.add(
        _UsageStatRow(
          label: l10n.usageTokenGeneration,
          value: l10n.usageTokensPerSecond(predictedPerSecond.toStringAsFixed(1)),
          detail: predictedN != null ? l10n.usageTokenCount(predictedN.toInt()) : null,
          theme: theme,
        ),
      );
    } else if (evalCount != null && evalDuration != null && evalDuration > 0) {
      // Ollama: duration in nanoseconds
      final tgSpeed = evalCount / (evalDuration / 1e9);
      stats.add(
        _UsageStatRow(
          label: l10n.usageTokenGeneration,
          value: l10n.usageTokensPerSecond(tgSpeed.toStringAsFixed(1)),
          detail: l10n.usageTokenCount(evalCount.toInt()),
          theme: theme,
        ),
      );
    } else if (completionTokens != null &&
        completionTime != null &&
        completionTime > 0) {
      // Groq/OpenAI extended: time in seconds
      final tgSpeed = completionTokens / completionTime;
      stats.add(
        _UsageStatRow(
          label: l10n.usageTokenGeneration,
          value: l10n.usageTokensPerSecond(tgSpeed.toStringAsFixed(1)),
          detail: l10n.usageTokenCount(completionTokens.toInt()),
          theme: theme,
        ),
      );
    } else if (completionTokens != null) {
      // Basic OpenAI: token count only
      stats.add(
        _UsageStatRow(
          label: l10n.usageTokenGeneration,
          value: l10n.usageTokenCount(completionTokens.toInt()),
          theme: theme,
        ),
      );
    }

    // --- Prompt Processing Speed ---
    // Priority: llama.cpp direct > Ollama calculated > Groq/OpenAI > count only
    if (promptPerSecond != null && promptPerSecond > 0) {
      // llama.cpp server: pre-calculated tokens/second
      stats.add(
        _UsageStatRow(
          label: l10n.usagePromptEval,
          value: l10n.usageTokensPerSecond(promptPerSecond.toStringAsFixed(1)),
          detail: promptN != null ? l10n.usageTokenCount(promptN.toInt()) : null,
          theme: theme,
        ),
      );
    } else if (promptEvalCount != null &&
        promptEvalDuration != null &&
        promptEvalDuration > 0) {
      // Ollama: duration in nanoseconds
      final ppSpeed = promptEvalCount / (promptEvalDuration / 1e9);
      stats.add(
        _UsageStatRow(
          label: l10n.usagePromptEval,
          value: l10n.usageTokensPerSecond(ppSpeed.toStringAsFixed(1)),
          detail: l10n.usageTokenCount(promptEvalCount.toInt()),
          theme: theme,
        ),
      );
    } else if (promptTokens != null && promptTime != null && promptTime > 0) {
      // Groq/OpenAI extended: time in seconds
      final ppSpeed = promptTokens / promptTime;
      stats.add(
        _UsageStatRow(
          label: l10n.usagePromptEval,
          value: l10n.usageTokensPerSecond(ppSpeed.toStringAsFixed(1)),
          detail: l10n.usageTokenCount(promptTokens.toInt()),
          theme: theme,
        ),
      );
    } else if (promptTokens != null) {
      // Basic OpenAI: token count only
      stats.add(
        _UsageStatRow(
          label: l10n.usagePromptEval,
          value: l10n.usageTokenCount(promptTokens.toInt()),
          theme: theme,
        ),
      );
    }

    // --- Reasoning Tokens (for o1/o3 models) ---
    if (reasoningTokens != null && reasoningTokens > 0) {
      stats.add(
        _UsageStatRow(
          label: l10n.usageReasoningTokens,
          value: l10n.usageTokenCount(reasoningTokens.toInt()),
          theme: theme,
        ),
      );
    }

    // --- Total Tokens (if not already shown via completion + prompt) ---
    if (totalTokens != null &&
        (completionTokens == null || promptTokens == null)) {
      stats.add(
        _UsageStatRow(
          label: l10n.usageTotalTokens,
          value: l10n.usageTokenCount(totalTokens.toInt()),
          theme: theme,
        ),
      );
    }

    // --- Total Duration ---
    if (totalDuration != null && totalDuration > 0) {
      // Ollama/llama.cpp: nanoseconds
      final totalSec = totalDuration / 1e9;
      stats.add(
        _UsageStatRow(
          label: l10n.usageTotalDuration,
          value: l10n.usageSecondsFormat(totalSec.toStringAsFixed(2)),
          theme: theme,
        ),
      );
    } else if (totalTime != null && totalTime > 0) {
      // Groq/OpenAI extended: seconds
      stats.add(
        _UsageStatRow(
          label: l10n.usageTotalDuration,
          value: l10n.usageSecondsFormat(totalTime.toStringAsFixed(2)),
          theme: theme,
        ),
      );
    }

    // --- Queue Time (Groq) ---
    if (queueTime != null && queueTime > 0) {
      stats.add(
        _UsageStatRow(
          label: l10n.usageQueueTime,
          value: l10n.usageSecondsFormat(queueTime.toStringAsFixed(3)),
          theme: theme,
        ),
      );
    }

    // --- Model Load Time (Ollama) ---
    if (loadDuration != null && loadDuration > 0) {
      final loadSec = loadDuration / 1e9;
      stats.add(
        _UsageStatRow(
          label: l10n.usageLoadDuration,
          value: l10n.usageSecondsFormat(loadSec.toStringAsFixed(2)),
          theme: theme,
        ),
      );
    }

    return stats;
  }

  /// Safely parse a number from dynamic value.
  num? _parseNum(dynamic value) {
    if (value == null) return null;
    if (value is num) return value;
    if (value is String) return num.tryParse(value);
    return null;
  }

  // Reasoning tile rendered inline - minimal design inspired by OpenWebUI
  Widget _buildReasoningTile(ReasoningEntry rc, int index) {
    final isExpanded = _expandedReasoning.contains(index);
    final theme = context.conduitTheme;
    // Show shimmer when reasoning is not done (mirrors OpenWebUI's done !== 'true')
    final showShimmer = !rc.isDone;

    String headerText() {
      final l10n = AppLocalizations.of(context)!;
      final hasSummary = rc.summary.isNotEmpty;
      final summaryLower = rc.summary.trim().toLowerCase();

      // Mirror Open WebUI's Collapsible.svelte logic for different block types
      if (rc.isCodeInterpreter) {
        // Code interpreter: "Analyzing..." -> "Analyzed"
        if (!rc.isDone) {
          return l10n.analyzing;
        }
        return l10n.analyzed;
      }

      // Reasoning block
      final isThinkingSummary =
          summaryLower == 'thinking…' ||
          summaryLower == 'thinking...' ||
          summaryLower.startsWith('thinking');

      // Check if summary contains server-formatted duration (e.g., "(0s)", "for 0 secs")
      final hasDurationInSummary = RegExp(
        r'\(\d+s\)|\bfor \d+ secs?\b',
        caseSensitive: false,
      ).hasMatch(rc.summary);

      // - If not done (streaming): show "Thinking..."
      // - If done: show humanized "Thought for X" (uses our formatDuration)
      // - If done without duration and has custom summary: show summary
      if (!rc.isDone) {
        // Still thinking - use summary if available, else default
        return hasSummary && !isThinkingSummary ? rc.summary : l10n.thinking;
      }

      // Done thinking - always use humanized duration format
      // This ensures "less than a second" instead of "0 secs" from server
      if (rc.duration >= 0 && (rc.duration > 0 || hasDurationInSummary || isThinkingSummary)) {
        return l10n.thoughtForDuration(rc.formattedDuration);
      }

      // Has custom summary that's not a duration - show it
      if (hasSummary && !isThinkingSummary) {
        return rc.summary;
      }

      return l10n.thoughts;
    }

    Widget buildHeader() {
      final headerWidget = Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            isExpanded
                ? Icons.keyboard_arrow_up_rounded
                : Icons.keyboard_arrow_down_rounded,
            size: 14,
            color: theme.textPrimary.withValues(alpha: 0.8),
          ),
          const SizedBox(width: 2),
          Flexible(
            child: Text(
              headerText(),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppTypography.bodySmall,
                color: theme.textPrimary.withValues(alpha: 0.8),
                height: 1.3,
              ),
            ),
          ),
        ],
      );

      if (showShimmer) {
        return headerWidget
            .animate(onPlay: (controller) => controller.repeat())
            .shimmer(
              duration: 1500.ms,
              color: theme.shimmerHighlight.withValues(alpha: 0.6),
            );
      }
      return headerWidget;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.xs),
      child: GestureDetector(
        onTap: () {
          setState(() {
            if (isExpanded) {
              _expandedReasoning.remove(index);
            } else {
              _expandedReasoning.add(index);
            }
          });
        },
        behavior: HitTestBehavior.opaque,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Minimal header - just text with chevron
            buildHeader(),

            // Expanded content - subtle background only when shown
            AnimatedCrossFade(
              firstChild: const SizedBox.shrink(),
              secondChild: Container(
                margin: const EdgeInsets.only(top: Spacing.xs, left: 16),
                padding: const EdgeInsets.symmetric(
                  horizontal: Spacing.sm,
                  vertical: Spacing.xs,
                ),
                decoration: BoxDecoration(
                  color: theme.surfaceContainer.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(4),
                  border: Border(
                    left: BorderSide(
                      color: theme.dividerColor.withValues(alpha: 0.4),
                      width: 2,
                    ),
                  ),
                ),
                child: SelectableText(
                  rc.cleanedReasoning,
                  style: TextStyle(
                    fontSize: AppTypography.bodySmall,
                    color: theme.textSecondary,
                    fontFamily: AppTypography.monospaceFontFamily,
                    height: 1.4,
                  ),
                ),
              ),
              crossFadeState: isExpanded
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              duration: const Duration(milliseconds: 200),
            ),
          ],
        ),
      ),
    );
  }
}

String _buildTtsPlainTextWorker(Map<String, dynamic> payload) {
  final rawSegments = payload['segments'];
  final fallback = payload['fallback'] as String? ?? '';
  final segments = rawSegments is List ? rawSegments.cast<dynamic>() : const [];

  if (segments.isEmpty) {
    return ConduitMarkdownPreprocessor.toPlainText(fallback);
  }

  final buffer = StringBuffer();
  for (final segment in segments) {
    if (segment is! String || segment.isEmpty) continue;
    final sanitized = ConduitMarkdownPreprocessor.toPlainText(segment);
    if (sanitized.isEmpty) continue;
    if (buffer.isNotEmpty) {
      buffer.writeln();
      buffer.writeln();
    }
    buffer.write(sanitized);
  }

  final result = buffer.toString().trim();
  if (result.isEmpty) {
    return ConduitMarkdownPreprocessor.toPlainText(fallback);
  }
  return result;
}

class CodeExecutionListView extends StatelessWidget {
  const CodeExecutionListView({super.key, required this.executions});

  final List<ChatCodeExecution> executions;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    if (executions.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Code executions',
          style: TextStyle(
            color: theme.textPrimary,
            fontWeight: FontWeight.w600,
            fontSize: AppTypography.bodyLarge,
          ),
        ),
        const SizedBox(height: Spacing.xs),
        Wrap(
          spacing: Spacing.xs,
          runSpacing: Spacing.xs,
          children: executions.map((execution) {
            final hasError = execution.result?.error != null;
            final hasOutput = execution.result?.output != null;
            IconData icon;
            Color iconColor;
            if (hasError) {
              icon = Icons.error_outline;
              iconColor = theme.error;
            } else if (hasOutput) {
              icon = Icons.check_circle_outline;
              iconColor = theme.success;
            } else {
              icon = Icons.sync;
              iconColor = theme.textSecondary;
            }
            final label = execution.name?.isNotEmpty == true
                ? execution.name!
                : 'Execution';
            return ActionChip(
              avatar: Icon(icon, size: 16, color: iconColor),
              label: Text(label),
              onPressed: () => _showCodeExecutionDetails(context, execution),
            );
          }).toList(),
        ),
      ],
    );
  }

  Future<void> _showCodeExecutionDetails(
    BuildContext context,
    ChatCodeExecution execution,
  ) async {
    final theme = context.conduitTheme;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: theme.surfaceBackground,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppBorderRadius.dialog),
        ),
      ),
      builder: (ctx) {
        final result = execution.result;
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          maxChildSize: 0.95,
          expand: false,
          builder: (_, controller) {
            return Padding(
              padding: const EdgeInsets.all(Spacing.lg),
              child: ListView(
                controller: controller,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          execution.name ?? 'Code execution',
                          style: TextStyle(
                            fontSize: AppTypography.bodyLarge,
                            fontWeight: FontWeight.w600,
                            color: theme.textPrimary,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                  const SizedBox(height: Spacing.sm),
                  if (execution.language != null)
                    Text(
                      'Language: ${execution.language}',
                      style: TextStyle(color: theme.textSecondary),
                    ),
                  const SizedBox(height: Spacing.sm),
                  if (execution.code != null && execution.code!.isNotEmpty) ...[
                    Text(
                      'Code',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: theme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: Spacing.xs),
                    Container(
                      padding: const EdgeInsets.all(Spacing.sm),
                      decoration: BoxDecoration(
                        color: theme.surfaceContainer,
                        borderRadius: BorderRadius.circular(AppBorderRadius.md),
                      ),
                      child: SelectableText(
                        execution.code!,
                        style: const TextStyle(
                          fontFamily: AppTypography.monospaceFontFamily,
                          height: 1.4,
                        ),
                      ),
                    ),
                    const SizedBox(height: Spacing.md),
                  ],
                  if (result?.error != null) ...[
                    Text(
                      'Error',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: theme.error,
                      ),
                    ),
                    const SizedBox(height: Spacing.xs),
                    SelectableText(result!.error!),
                    const SizedBox(height: Spacing.md),
                  ],
                  if (result?.output != null) ...[
                    Text(
                      'Output',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: theme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: Spacing.xs),
                    SelectableText(result!.output!),
                    const SizedBox(height: Spacing.md),
                  ],
                  if (result?.files.isNotEmpty == true) ...[
                    Text(
                      'Files',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: theme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: Spacing.xs),
                    ...result!.files.map((file) {
                      final name = file.name ?? file.url ?? 'Download';
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.insert_drive_file_outlined),
                        title: Text(name),
                        onTap: file.url != null
                            ? () => _launchUri(file.url!)
                            : null,
                        trailing: file.url != null
                            ? const Icon(Icons.open_in_new)
                            : null,
                      );
                    }),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class FollowUpSuggestionBar extends StatelessWidget {
  const FollowUpSuggestionBar({
    super.key,
    required this.suggestions,
    required this.onSelected,
    required this.isBusy,
  });

  final List<String> suggestions;
  final ValueChanged<String> onSelected;
  final bool isBusy;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final trimmedSuggestions = suggestions
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);

    if (trimmedSuggestions.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Subtle header
        Row(
          children: [
            Icon(
              Icons.lightbulb_outline,
              size: 12,
              color: theme.textSecondary.withValues(alpha: 0.7),
            ),
            const SizedBox(width: Spacing.xxs),
            Text(
              'Continue with',
              style: TextStyle(
                fontSize: AppTypography.labelSmall,
                color: theme.textSecondary.withValues(alpha: 0.7),
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        const SizedBox(height: Spacing.xs),
        Wrap(
          spacing: Spacing.xs,
          runSpacing: Spacing.xs,
          children: [
            for (final suggestion in trimmedSuggestions)
              _MinimalFollowUpButton(
                label: suggestion,
                onPressed: isBusy ? null : () => onSelected(suggestion),
                enabled: !isBusy,
              ),
          ],
        ),
      ],
    );
  }
}

class _MinimalFollowUpButton extends StatelessWidget {
  const _MinimalFollowUpButton({
    required this.label,
    this.onPressed,
    this.enabled = true,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    return InkWell(
      onTap: enabled ? onPressed : null,
      borderRadius: BorderRadius.circular(AppBorderRadius.small),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.sm,
          vertical: Spacing.xs,
        ),
        decoration: BoxDecoration(
          color: enabled
              ? theme.surfaceContainer.withValues(alpha: 0.2)
              : theme.surfaceContainer.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(AppBorderRadius.small),
          border: Border.all(
            color: enabled
                ? theme.buttonPrimary.withValues(alpha: 0.15)
                : theme.dividerColor.withValues(alpha: 0.2),
            width: BorderWidth.thin,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.arrow_forward,
              size: 11,
              color: enabled
                  ? theme.buttonPrimary.withValues(alpha: 0.7)
                  : theme.textSecondary.withValues(alpha: 0.4),
            ),
            const SizedBox(width: Spacing.xxs),
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  color: enabled
                      ? theme.buttonPrimary.withValues(alpha: 0.9)
                      : theme.textSecondary.withValues(alpha: 0.5),
                  fontSize: AppTypography.bodySmall,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _launchUri(String url) async {
  if (url.isEmpty) return;
  try {
    await launchUrlString(url, mode: LaunchMode.externalApplication);
  } catch (err) {
    DebugLogger.log('Unable to open url $url: $err', scope: 'chat/assistant');
  }
}

/// Row widget for displaying a single usage statistic.
class _UsageStatRow extends StatelessWidget {
  const _UsageStatRow({
    required this.label,
    required this.value,
    this.detail,
    required this.theme,
  });

  final String label;
  final String value;
  final String? detail;
  final ConduitThemeExtension theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: AppTypography.bodyMedium,
              color: theme.textSecondary,
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                value,
                style: TextStyle(
                  fontSize: AppTypography.bodyMedium,
                  fontWeight: FontWeight.w600,
                  fontFamily: AppTypography.monospaceFontFamily,
                  color: theme.textPrimary,
                ),
              ),
              if (detail != null)
                Text(
                  detail!,
                  style: TextStyle(
                    fontSize: AppTypography.labelSmall,
                    color: theme.textTertiary,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
