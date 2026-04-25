import 'dart:async';
import 'dart:io' show Platform;

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/markdown/streaming_markdown_widget.dart';
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
import '../../../shared/widgets/web_content_embed.dart';
import 'package:url_launcher/url_launcher_string.dart';
import '../providers/chat_providers.dart'
    show
        isChatStreamingProvider,
        sendMessageWithContainer,
        streamingContentProvider;
import '../../../core/utils/debug_logger.dart';
import '../../../core/services/platform_service.dart';
import '../../../core/services/settings_service.dart';
import '../../../core/utils/embed_utils.dart';
import 'sources/openwebui_sources.dart';
import '../providers/assistant_response_builder_provider.dart';
import '../../../core/services/worker_manager.dart';
import 'streaming_status_widget.dart';
import '../utils/file_utils.dart';
import 'code_execution_display.dart';
import 'follow_up_suggestions.dart';
import 'usage_stats_modal.dart';

// Wrap only standalone base64 image lines so <details> attributes stay intact.
final _standaloneBase64ImagePattern = RegExp(
  r'(^|\n)([ \t]*)(data:image/[^;\s]+;base64,[A-Za-z0-9+/=]+)(?=(?:[ \t]*\n|$))',
  multiLine: true,
);
final _ttsDetailsPattern = RegExp(
  r'<details[^>]*>[\s\S]*?<\/details>',
  caseSensitive: false,
);
// Handle both URL formats: /api/v1/files/{id} and /api/v1/files/{id}/content
final _fileIdPattern = RegExp(r'/api/v1/files/([^/]+)(?:/content)?$');

class AssistantMessageWidget extends ConsumerStatefulWidget {
  final dynamic message;
  final bool isStreaming;
  final bool showFollowUps;
  final bool animateOnMount;
  final String? modelName;
  final String? modelIconUrl;
  final List<String?> versionModelNames;
  final List<String?> versionModelIconUrls;
  final VoidCallback? onCopy;
  final VoidCallback? onRegenerate;
  final VoidCallback? onLike;
  final VoidCallback? onDislike;

  const AssistantMessageWidget({
    super.key,
    required this.message,
    this.isStreaming = false,
    this.showFollowUps = true,
    this.animateOnMount = true,
    this.modelName,
    this.modelIconUrl,
    this.versionModelNames = const <String?>[],
    this.versionModelIconUrls = const <String?>[],
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
  String _displayedContent = '';
  Widget? _cachedAvatar;
  String? _cachedAvatarModelName;
  String? _cachedAvatarIconUrl;
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
  bool _disableAnimations = false;
  bool _hasAnimated = false;

  /// Guards the triple-haptic so it fires only once per streaming session.
  bool _hasTriggeredContentHaptic = false;
  ProviderSubscription<String?>? _streamingContentSub;

  bool get _shouldAnimateOnMount =>
      widget.animateOnMount && !_disableAnimations;

  // Streaming fade-in animation state
  late AnimationController _chunkFadeController;
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
    _disableAnimations = WidgetsBinding
        .instance
        .platformDispatcher
        .accessibilityFeatures
        .disableAnimations;
    final shouldAnimateOnMount = _shouldAnimateOnMount;
    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
      value: shouldAnimateOnMount ? 0.0 : 1.0,
    );
    _slideController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
      value: shouldAnimateOnMount ? 0.0 : 1.0,
    );
    _chunkFadeController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
      value: 1.0, // Start fully opaque for non-streaming messages
    );

    _hasAnimated = !shouldAnimateOnMount;
    _displayedContent = _resolvedMessageContent();
    _scheduleTtsPlainTextBuild(_displayedContent);
    _updateTypingIndicatorGate();
    _syncStreamingContentSubscription();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _disableAnimations =
        MediaQuery.maybeDisableAnimationsOf(context) ?? _disableAnimations;
    if (!_shouldAnimateOnMount && !_hasAnimated) {
      _fadeController.value = 1.0;
      _slideController.value = 1.0;
      _hasAnimated = true;
    }
    // Build cached avatar when theme context is available
    _buildCachedAvatar();
  }

  @override
  void didUpdateWidget(AssistantMessageWidget oldWidget) {
    super.didUpdateWidget(oldWidget);

    final messageChanged = oldWidget.message.id != widget.message.id;

    if (messageChanged) {
      _lastStreamingContent = null;
      _displayedContent = '';
      _cachedAvatar = null;
      _cachedAvatarModelName = null;
      _cachedAvatarIconUrl = null;
      _ttsPlainText = '';
      _ttsPlainTextRequestId++;
      _ttsPlainTextDebounce?.cancel();
      _pendingTtsPlainTextPayload = null;
      _pendingTtsPlainTextSource = null;
      _lastAppliedTtsPlainTextSource = null;
      _hasAnimated = !_shouldAnimateOnMount;
      _hasTriggeredContentHaptic = false;
      _fadeController.value = _shouldAnimateOnMount ? 0.0 : 1.0;
      _slideController.value = _shouldAnimateOnMount ? 0.0 : 1.0;
      _chunkFadeController.value = 1.0;
    }

    // Re-sync subscription when streaming state changes
    if (oldWidget.isStreaming != widget.isStreaming || messageChanged) {
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

    // Refresh rendered content when the active message changes.
    if (messageChanged || oldWidget.message.content != widget.message.content) {
      _refreshDisplayedContent();
    }

    // Update typing indicator gate when message properties that affect emptiness change
    if (oldWidget.message.statusHistory != widget.message.statusHistory ||
        oldWidget.message.files != widget.message.files ||
        oldWidget.message.embeds != widget.message.embeds ||
        oldWidget.message.attachmentIds != widget.message.attachmentIds ||
        oldWidget.message.followUps != widget.message.followUps ||
        oldWidget.message.codeExecutions != widget.message.codeExecutions) {
      _updateTypingIndicatorGate();
    }

    // Rebuild cached avatar if model name or icon changes
    if (messageChanged ||
        oldWidget.modelName != widget.modelName ||
        oldWidget.modelIconUrl != widget.modelIconUrl ||
        oldWidget.versionModelNames != widget.versionModelNames ||
        oldWidget.versionModelIconUrls != widget.versionModelIconUrls ||
        oldWidget.message.model != widget.message.model ||
        oldWidget.message.versions != widget.message.versions) {
      _buildCachedAvatar();
    }
  }

  String _resolvedMessageContent([String? overrideContent, int? versionIndex]) {
    final selectedVersionIndex = versionIndex ?? _activeVersionIndex;
    final raw0 = selectedVersionIndex >= 0
        ? (widget.message.versions[selectedVersionIndex].content as String?) ??
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
    return raw;
  }

  void _refreshDisplayedContent([String? overrideContent]) {
    final raw = _resolvedMessageContent(overrideContent);
    final previousLength = _displayedContent.length;
    final contentChanged = raw != _displayedContent;

    if (contentChanged) {
      if (mounted) {
        setState(() {
          _displayedContent = raw;
        });
      } else {
        _displayedContent = raw;
      }
      if (widget.isStreaming) {
        _onStreamingChunk(previousLength, raw.length);
      }
    }

    _scheduleTtsPlainTextBuild(raw);
    _updateTypingIndicatorGate();
  }

  void _setActiveVersionIndex(int nextIndex) {
    final raw = _resolvedMessageContent(null, nextIndex);
    setState(() {
      _activeVersionIndex = nextIndex;
      _displayedContent = raw;
    });
    _buildCachedAvatar();
    _scheduleTtsPlainTextBuild(raw);
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

  String _buildTtsPlainTextFallback(String raw) {
    return _buildTtsPlainTextFromRaw(raw);
  }

  void _scheduleTtsPlainTextBuild(String raw) {
    if (raw.trim().isEmpty) {
      _pendingTtsPlainTextPayload = null;
      _pendingTtsPlainTextSource = null;
      _lastAppliedTtsPlainTextSource = null;
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

    _pendingTtsPlainTextPayload = {'raw': raw};
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
    String speechText;
    try {
      final worker = ref.read(workerManagerProvider);
      speechText = await worker.schedule<Map<String, dynamic>, String>(
        _buildTtsPlainTextWorker,
        payload,
        debugLabel: 'tts_plain_text',
      );
    } catch (_) {
      speechText = _buildTtsPlainTextFallback(raw);
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

  Widget _buildMessageContent() {
    final children = <Widget>[];
    final trimmedContent = _displayedContent.trim();
    if (trimmedContent.isNotEmpty) {
      final markdownWidget = _buildEnhancedMarkdownContent(_displayedContent);
      children.add(
        widget.isStreaming
            ? RepaintBoundary(
                child: _StreamingFadeOverlay(
                  animation: _chunkFadeController,
                  child: markdownWidget,
                ),
              )
            : markdownWidget,
      );
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

    final baseStyle =
        Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(color: theme.textPrimary) ??
        AppTypography.bodyMediumStyle.copyWith(color: theme.textPrimary);
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
    final content = _displayedContent.trim();
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

    final hasEmbeds = (_resolveActiveEmbeds()?.isNotEmpty ?? false);
    if (hasEmbeds) {
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
    return true;
  }

  void _buildCachedAvatar() {
    final theme = context.conduitTheme;
    final modelName = _resolveActiveModelName();
    final iconUrl = _resolveActiveModelIconUrl();
    if (_cachedAvatar != null &&
        _cachedAvatarModelName == modelName &&
        _cachedAvatarIconUrl == iconUrl) {
      return;
    }
    final hasIcon = iconUrl != null && iconUrl.isNotEmpty;

    final Widget leading = hasIcon
        ? ModelAvatar(size: 20, imageUrl: iconUrl, label: modelName)
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
              modelName,
              style: AppTypography.bodySmallStyle.copyWith(
                color: theme.textSecondary,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.1,
              ),
            ),
          ),
        ],
      ),
    );
    _cachedAvatarModelName = modelName;
    _cachedAvatarIconUrl = iconUrl;
  }

  String _resolveActiveModelName() {
    if (_activeVersionIndex >= 0 &&
        _activeVersionIndex < widget.versionModelNames.length) {
      final versionModelName = widget.versionModelNames[_activeVersionIndex]
          ?.trim();
      if (versionModelName != null && versionModelName.isNotEmpty) {
        return versionModelName;
      }
    }

    if (_activeVersionIndex >= 0 &&
        _activeVersionIndex < widget.message.versions.length) {
      final rawVersionModel = widget.message.versions[_activeVersionIndex].model
          ?.trim();
      if (rawVersionModel != null && rawVersionModel.isNotEmpty) {
        return rawVersionModel;
      }
    }

    final currentModelName = widget.modelName?.trim();
    if (currentModelName != null && currentModelName.isNotEmpty) {
      return currentModelName;
    }

    final rawCurrentModel = widget.message.model?.trim();
    if (rawCurrentModel != null && rawCurrentModel.isNotEmpty) {
      return rawCurrentModel;
    }

    return 'Assistant';
  }

  String? _resolveActiveModelIconUrl() {
    if (_activeVersionIndex >= 0 &&
        _activeVersionIndex < widget.versionModelIconUrls.length) {
      final versionIconUrl = widget.versionModelIconUrls[_activeVersionIndex]
          ?.trim();
      if (versionIconUrl != null && versionIconUrl.isNotEmpty) {
        return versionIconUrl;
      }
      return null;
    }

    final currentIconUrl = widget.modelIconUrl?.trim();
    if (currentIconUrl != null && currentIconUrl.isNotEmpty) {
      return currentIconUrl;
    }
    return null;
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
    if (_disableAnimations) {
      _chunkFadeController.value = 1.0;
    } else {
      _chunkFadeController.forward(from: 0.0);
    }
  }

  /// Fires a single haptic impulse if streaming haptics are enabled.
  void _streamingHaptic(HapticType type) {
    final enabled = ref.read(streamingHapticsEnabledProvider);
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
    final enabled = ref.read(streamingHapticsEnabledProvider);
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
          _refreshDisplayedContent(next);
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
    final activeCodeExecutions = _resolveActiveCodeExecutions();
    final hasCodeExecutions = activeCodeExecutions.isNotEmpty;
    final activeFollowUps = _resolveActiveFollowUps();
    final hasFollowUps =
        widget.showFollowUps &&
        activeFollowUps.isNotEmpty &&
        !widget.isStreaming;
    final bool showingVersion = _activeVersionIndex >= 0;
    final activeFiles = showingVersion
        ? widget.message.versions[_activeVersionIndex].files
        : widget.message.files;
    final activeEmbeds = _resolveActiveEmbeds();
    final activeSources = _resolveActiveSources();
    final footer = _buildFooterBar(activeSources: activeSources);

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

                if (activeEmbeds != null && activeEmbeds.isNotEmpty) ...[
                  _buildEmbedsFromArray(activeEmbeds),
                  const SizedBox(height: Spacing.md),
                ],

                if (hasStatusTimeline) ...[
                  StreamingStatusWidget(
                    updates: visibleStatusHistory,
                    isStreaming: widget.isStreaming,
                  ),
                  const SizedBox(height: Spacing.xs),
                ],

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
                          child: _buildMessageContent(),
                        ),
                ),

                // Display error banner if message or active version has an error
                if (_getActiveError() != null) ...[
                  const SizedBox(height: Spacing.sm),
                  _buildErrorBanner(_getActiveError()!),
                ],

                if (hasCodeExecutions) ...[
                  const SizedBox(height: Spacing.md),
                  CodeExecutionListView(executions: activeCodeExecutions),
                ],

                // Version switcher moved inline with action buttons below
              ],
            ),
          ),

          // Action buttons below the message content (only after streaming completes)
          if (!widget.isStreaming) ...[
            ?footer,
            if (hasFollowUps) ...[
              const SizedBox(height: Spacing.md),
              _buildFollowUpSuggestions(activeFollowUps),
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

  Widget _buildEnhancedMarkdownContent(String content) {
    if (content.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    // Keep the raw markdown intact so the shared renderer can parse
    // Open WebUI-style <details> blocks directly.
    final processedContent = _processContentForImages(content);
    final activeSources = _resolveActiveSources();

    Widget buildDefault(BuildContext context) => StreamingMarkdownWidget(
      content: processedContent,
      isStreaming: widget.isStreaming,
      stateScopeId: _markdownStateScopeId(),
      onTapLink: (url, _) => _launchUri(url),
      sources: activeSources,
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

  String _markdownStateScopeId() {
    final selectedVersionIndex = _activeVersionIndex;
    if (selectedVersionIndex >= 0 &&
        selectedVersionIndex < widget.message.versions.length) {
      final versionId = widget.message.versions[selectedVersionIndex].id;
      return '${widget.message.id}|version:$versionId';
    }
    return '${widget.message.id}|current';
  }

  List<Map<String, dynamic>>? _resolveActiveEmbeds() {
    final rawEmbeds =
        _activeVersionIndex >= 0 &&
            _activeVersionIndex < widget.message.versions.length
        ? widget.message.versions[_activeVersionIndex].embeds
        : widget.message.embeds;
    final embeds = normalizeEmbedList(rawEmbeds);
    if (embeds.isEmpty) {
      return null;
    }
    return embeds;
  }

  List<ChatSourceReference> _resolveActiveSources() {
    if (_activeVersionIndex >= 0 &&
        _activeVersionIndex < widget.message.versions.length) {
      return widget.message.versions[_activeVersionIndex].sources;
    }
    return widget.message.sources;
  }

  List<String> _resolveActiveFollowUps() {
    if (_activeVersionIndex >= 0 &&
        _activeVersionIndex < widget.message.versions.length) {
      return widget.message.versions[_activeVersionIndex].followUps;
    }
    return widget.message.followUps;
  }

  List<ChatCodeExecution> _resolveActiveCodeExecutions() {
    if (_activeVersionIndex >= 0 &&
        _activeVersionIndex < widget.message.versions.length) {
      return widget.message.versions[_activeVersionIndex].codeExecutions;
    }
    return widget.message.codeExecutions;
  }

  Map<String, dynamic>? _resolveActiveUsage() {
    if (_activeVersionIndex >= 0 &&
        _activeVersionIndex < widget.message.versions.length) {
      return widget.message.versions[_activeVersionIndex].usage;
    }
    return widget.message.usage;
  }

  String _processContentForImages(String content) {
    if (!content.contains('data:image/')) {
      return content;
    }

    return content.replaceAllMapped(_standaloneBase64ImagePattern, (match) {
      final linePrefix = match.group(1) ?? '';
      final indentation = match.group(2) ?? '';
      final imageData = match.group(3)!;
      return '$linePrefix$indentation![Generated Image]($imageData)';
    });
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

  Widget _buildEmbedsFromArray(List<Map<String, dynamic>> embeds) {
    final children = embeds.indexed
        .map((entry) {
          final index = entry.$1;
          final embed = entry.$2;
          final source = extractEmbedSource(embed);
          if (source == null || source.isEmpty) {
            return null;
          }
          return KeyedSubtree(
            key: ValueKey('message-embed-$index-$source'),
            child: WebContentEmbed(source: source),
          );
        })
        .whereType<Widget>()
        .toList(growable: false);

    if (children.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var index = 0; index < children.length; index++) ...[
          if (index > 0) const SizedBox(height: Spacing.sm),
          children[index],
        ],
      ],
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

  Widget? _buildFooterBar({required List<ChatSourceReference> activeSources}) {
    const maxInlineActions = 3;
    final actions = _buildFooterActions();
    final visibleActions = actions
        .take(maxInlineActions)
        .toList(growable: false);
    final overflowActions = actions
        .skip(maxInlineActions)
        .toList(growable: false);
    final infoWidgets = <Widget>[
      if (activeSources.isNotEmpty)
        OpenWebUISourcesWidget(
          sources: activeSources,
          messageId: widget.message.id,
        ),
      if (widget.message.versions.isNotEmpty) _buildVersionChip(),
    ];

    if (infoWidgets.isEmpty &&
        visibleActions.isEmpty &&
        overflowActions.isEmpty) {
      return null;
    }

    final leftAlignedWidgets = <Widget>[
      for (final action in visibleActions)
        _buildActionButton(
          icon: action.icon,
          label: action.label,
          onTap: action.onTap,
          sfSymbol: action.sfSymbol,
        ),
      ...infoWidgets,
    ];
    final overflowButton = overflowActions.isNotEmpty
        ? _buildOverflowActionButton(overflowActions)
        : null;

    if (overflowButton == null) {
      return Wrap(
        spacing: Spacing.sm,
        runSpacing: Spacing.sm,
        children: leftAlignedWidgets,
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Wrap(
            spacing: Spacing.sm,
            runSpacing: Spacing.sm,
            children: leftAlignedWidgets,
          ),
        ),
        const SizedBox(width: Spacing.sm),
        overflowButton,
      ],
    );
  }

  List<_AssistantFooterAction> _buildFooterActions() {
    final l10n = AppLocalizations.of(context)!;
    final ttsState = ref.watch(textToSpeechControllerProvider);
    final isChatStreaming = ref.watch(isChatStreamingProvider);
    final activeUsage = _resolveActiveUsage();
    final messageId = _messageId;
    final hasSpeechText = _ttsPlainText.trim().isNotEmpty;
    final activeError = _getActiveError();
    final hasErrorField = activeError != null;
    final isErrorMessage =
        hasErrorField ||
        _displayedContent.contains('⚠️') ||
        _displayedContent.contains('Error') ||
        _displayedContent.contains('timeout') ||
        _displayedContent.contains('retry options');

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
    final bool canRegenerate = widget.onRegenerate != null && !isChatStreaming;
    final bool hasVersions = widget.message.versions.isNotEmpty;
    final bool canGoToPreviousVersion =
        hasVersions && (_activeVersionIndex < 0 || _activeVersionIndex > 0);
    final bool canGoToNextVersion = hasVersions && _activeVersionIndex >= 0;

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

    final actions = <_AssistantFooterAction>[
      _AssistantFooterAction(
        id: 'copy',
        icon: Platform.isIOS
            ? CupertinoIcons.doc_on_clipboard
            : Icons.content_copy,
        label: l10n.copy,
        onTap: widget.onCopy,
        sfSymbol: 'doc.on.clipboard',
      ),
      if (shouldShowTtsButton)
        _AssistantFooterAction(
          id: 'tts',
          icon: showStopState ? stopIcon : listenIcon,
          label: showStopState ? l10n.ttsStop : l10n.ttsListen,
          onTap: ttsOnTap,
          sfSymbol: showStopState ? 'stop.fill' : 'speaker.wave.2.fill',
        ),
      _AssistantFooterAction(
        id: isErrorMessage ? 'retry' : 'regenerate',
        icon: Platform.isIOS ? CupertinoIcons.refresh : Icons.refresh,
        label: isErrorMessage ? l10n.retry : l10n.regenerate,
        onTap: canRegenerate ? widget.onRegenerate : null,
        sfSymbol: 'arrow.clockwise',
      ),
      if (activeUsage != null && activeUsage.isNotEmpty)
        _AssistantFooterAction(
          id: 'usage',
          icon: Platform.isIOS ? CupertinoIcons.info : Icons.info_outline,
          label: l10n.usageInfo,
          onTap: () => UsageStatsModal.show(context, activeUsage),
          sfSymbol: 'info.circle',
        ),
      if (hasVersions)
        _AssistantFooterAction(
          id: 'previous_version',
          icon: Platform.isIOS
              ? CupertinoIcons.chevron_left
              : Icons.chevron_left,
          label: l10n.previousLabel,
          onTap: canGoToPreviousVersion
              ? () {
                  final nextIndex = _activeVersionIndex < 0
                      ? widget.message.versions.length - 1
                      : _activeVersionIndex - 1;
                  _setActiveVersionIndex(nextIndex);
                }
              : null,
          sfSymbol: 'chevron.left',
        ),
      if (hasVersions)
        _AssistantFooterAction(
          id: 'next_version',
          icon: Platform.isIOS
              ? CupertinoIcons.chevron_right
              : Icons.chevron_right,
          label: l10n.nextLabel,
          onTap: canGoToNextVersion
              ? () {
                  final nextIndex =
                      _activeVersionIndex < widget.message.versions.length - 1
                      ? _activeVersionIndex + 1
                      : -1;
                  _setActiveVersionIndex(nextIndex);
                }
              : null,
          sfSymbol: 'chevron.right',
        ),
    ];

    return actions;
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

  Widget _buildVersionChip() {
    final totalVersions = widget.message.versions.length + 1;
    final currentVersion = _activeVersionIndex < 0
        ? totalVersions
        : _activeVersionIndex + 1;

    return ConduitChip(
      label: '$currentVersion/$totalVersions',
      isCompact: true,
      isSelected: _activeVersionIndex >= 0,
    );
  }

  Widget _buildOverflowActionButton(
    List<_AssistantFooterAction> overflowActions,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;

    return AdaptivePopupMenuButton.widget<String>(
      items: overflowActions
          .map(
            (action) => AdaptivePopupMenuItem<String>(
              value: action.id,
              label: action.label,
              icon: Platform.isIOS ? action.sfSymbol : action.icon,
              enabled: action.onTap != null,
            ),
          )
          .toList(growable: false),
      onSelected: (_, entry) {
        final selectedId = entry.value;
        if (selectedId == null) {
          return;
        }
        for (final action in overflowActions) {
          if (action.id == selectedId) {
            action.onTap?.call();
            return;
          }
        }
      },
      buttonStyle: PopupButtonStyle.glass,
      child: AdaptiveTooltip(
        message: l10n.more,
        waitDuration: const Duration(milliseconds: 600),
        child: Semantics(
          button: true,
          label: l10n.more,
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: theme.textPrimary.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(AppBorderRadius.circular),
              border: Border.all(
                color: theme.textPrimary.withValues(alpha: 0.08),
                width: BorderWidth.regular,
              ),
            ),
            alignment: Alignment.center,
            child: Icon(
              Platform.isIOS
                  ? CupertinoIcons.ellipsis
                  : Icons.more_horiz_rounded,
              size: IconSize.sm,
              color: theme.textPrimary.withValues(alpha: 0.8),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFollowUpSuggestions(List<String> suggestions) {
    final shouldShow = widget.showFollowUps && suggestions.isNotEmpty;

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        return FadeTransition(
          opacity: animation,
          child: SizeTransition(
            sizeFactor: animation,
            axisAlignment: -1,
            child: child,
          ),
        );
      },
      child: shouldShow
          ? KeyedSubtree(
              key: ValueKey('follow-ups-${suggestions.join('|')}'),
              child: FollowUpSuggestionBar(
                suggestions: suggestions,
                onSelected: _handleFollowUpTap,
                isBusy: widget.isStreaming,
              ),
            )
          : const SizedBox.shrink(key: ValueKey('follow-ups-empty')),
    );
  }
}

class _AssistantFooterAction {
  const _AssistantFooterAction({
    required this.id,
    required this.icon,
    required this.label,
    required this.sfSymbol,
    this.onTap,
  });

  final String id;
  final IconData icon;
  final String label;
  final String sfSymbol;
  final VoidCallback? onTap;
}

String _buildTtsPlainTextWorker(Map<String, dynamic> payload) {
  final raw = payload['raw'] as String? ?? '';
  return _buildTtsPlainTextFromRaw(raw);
}

String _buildTtsPlainTextFromRaw(String raw) {
  if (raw.trim().isEmpty) {
    return '';
  }

  final sanitized = ConduitMarkdownPreprocessor.sanitize(raw);
  final withoutDetails = sanitized.replaceAll(_ttsDetailsPattern, '');
  return ConduitMarkdownPreprocessor.cleanText(withoutDetails).trim();
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
