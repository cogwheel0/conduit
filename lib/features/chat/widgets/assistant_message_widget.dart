import 'dart:async';
import 'dart:io' show Platform;

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/markdown/streaming_markdown_widget.dart';
import '../../../shared/widgets/markdown/renderer/markdown_style.dart';
import '../../../core/models/chat_message.dart';
import '../../../shared/widgets/markdown/markdown_preprocessor.dart';
import '../providers/text_to_speech_provider.dart';
import '../providers/queued_completion_provider.dart';
import 'enhanced_image_attachment.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'enhanced_attachment.dart';
import 'package:conduit/shared/widgets/chat_action_button.dart';
import '../../../shared/widgets/model_avatar.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/middle_ellipsis_text.dart';
import '../../../shared/widgets/web_content_embed.dart';
import '../providers/chat_providers.dart'
    show
        chatComposerTextInsertionTargetId,
        isChatStreamingProvider,
        sendMessageWithContainer,
        streamingContentProvider;
import '../../../shared/utils/external_link_launcher.dart';
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
import 'five_rotating_dots.dart';

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
  final bool suppressStreamingHaptics;
  final VoidCallback? onCopy;
  final VoidCallback? onRegenerate;
  final VoidCallback onDelete;
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
    this.suppressStreamingHaptics = false,
    this.onCopy,
    this.onRegenerate,
    required this.onDelete,
    this.onLike,
    this.onDislike,
  });

  @override
  ConsumerState<AssistantMessageWidget> createState() =>
      _AssistantMessageWidgetState();
}

class _AssistantMessageWidgetState extends ConsumerState<AssistantMessageWidget>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late AnimationController _fadeController;
  late AnimationController _streamingContentFadeController;
  late CurvedAnimation _streamingContentFade;
  String _displayedContent = '';
  Widget? _cachedAvatar;
  String? _cachedAvatarModelName;
  String? _cachedAvatarIconUrl;
  bool _allowTypingIndicator = false;
  Timer? _typingGateTimer;
  // Hysteresis for the action row: a message that has streamed in this widget's
  // lifetime must reach a settled completion before the action row replaces the
  // typing indicator, so a transient in-progress state can never flash the row
  // mid-stream. Settled on `responseDone` or on the streaming-end transition.
  // History messages never set `_hasStreamedThisMessage` and show their action
  // row immediately.
  bool _hasStreamedThisMessage = false;
  bool _actionRowSettled = false;
  String _ttsPlainText = '';
  String? _lastAppliedTtsPlainTextSource;
  int _ttsPlainTextRequestId = 0;
  bool _isPreparingTtsPlainText = false;
  // Active version index (-1 means current/live content)
  int _activeVersionIndex = -1;
  String? _lastStreamingContent;
  String? _pendingDisplayedContent;
  bool _displayedContentFrameScheduled = false;
  bool _disableAnimations = false;
  bool _hasAnimated = false;
  bool _isAppForeground = true;
  bool _isRouteVisible = true;
  String? _visibleFollowUpScopeId;
  List<String> _visibleFollowUps = const <String>[];

  /// Guards the triple-haptic so it fires only once per streaming session.
  bool _hasTriggeredContentHaptic = false;
  ProviderSubscription<String?>? _streamingContentSub;

  bool get _shouldAnimateOnMount =>
      widget.animateOnMount && !_disableAnimations;

  bool get _responseCompleted {
    if (_activeVersionIndex >= 0) {
      return true;
    }
    if (!widget.isStreaming) {
      return true;
    }
    return widget.message.metadata?['responseDone'] == true;
  }

  bool get _uiTreatsAsStreaming => widget.isStreaming && !_responseCompleted;

  // press state handled by shared ChatActionButton

  Future<void> _handleFollowUpTap(String suggestion) async {
    final trimmed = suggestion.trim();
    if (trimmed.isEmpty || _uiTreatsAsStreaming || !_responseCompleted) {
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
    WidgetsBinding.instance.addObserver(this);
    _isAppForeground = _isLifecycleForeground(
      WidgetsBinding.instance.lifecycleState,
    );
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
    _streamingContentFadeController = AnimationController(
      duration: const Duration(milliseconds: 260),
      vsync: this,
      value: 1.0,
    );
    _streamingContentFade = CurvedAnimation(
      parent: _streamingContentFadeController,
      curve: Curves.easeOutCubic,
    );
    _hasAnimated = !shouldAnimateOnMount;
    _displayedContent = _resolvedMessageContent();
    _primeInitialStreamingContentFade();
    _updateTypingIndicatorGate();
    _updateActionRowSettle();
    _syncStreamingContentSubscription();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _disableAnimations =
        MediaQuery.maybeDisableAnimationsOf(context) ?? _disableAnimations;
    _updateRouteVisibility();
    if (!_shouldAnimateOnMount && !_hasAnimated) {
      _fadeController.value = 1.0;
      _hasAnimated = true;
    }
    if (_disableAnimations && !_streamingContentFadeController.isCompleted) {
      _streamingContentFadeController.value = 1.0;
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
      _pendingDisplayedContent = null;
      _cachedAvatar = null;
      _cachedAvatarModelName = null;
      _cachedAvatarIconUrl = null;
      _clearVisibleFollowUps();
      _resetTtsPlainTextState();
      _hasAnimated = !_shouldAnimateOnMount;
      _hasTriggeredContentHaptic = false;
      _fadeController.value = _shouldAnimateOnMount ? 0.0 : 1.0;
      _streamingContentFadeController.value = 1.0;
    }

    if (!oldWidget.isStreaming && widget.isStreaming) {
      _clearVisibleFollowUps();
    }

    // Re-sync subscription when streaming state changes
    if (oldWidget.isStreaming != widget.isStreaming || messageChanged) {
      _syncStreamingContentSubscription();
    }

    // Reset fade controller when streaming ends for the same message
    if (oldWidget.isStreaming &&
        !widget.isStreaming &&
        oldWidget.message.id == widget.message.id) {
      _hasTriggeredContentHaptic = false;
      // Haptic: streaming finished
      _streamingHaptic(HapticType.medium);
      // Genuine streaming end: allow the action row to replace the indicator.
      _hasStreamedThisMessage = true;
      _actionRowSettled = true;
    }

    // Refresh rendered content when the active message changes.
    if (messageChanged || _didMessageContentChange(oldWidget)) {
      _queueDisplayedContentRefresh();
    }

    // Update typing indicator gate when message properties that affect emptiness change
    if (_didTypingIndicatorInputsChange(oldWidget) ||
        oldWidget.message.metadata?['responseDone'] !=
            widget.message.metadata?['responseDone']) {
      _updateTypingIndicatorGate();
      _updateActionRowSettle();
    }

    // Rebuild cached avatar if model name or icon changes
    if (messageChanged ||
        oldWidget.modelName != widget.modelName ||
        oldWidget.modelIconUrl != widget.modelIconUrl ||
        oldWidget.versionModelNames != widget.versionModelNames ||
        oldWidget.versionModelIconUrls != widget.versionModelIconUrls ||
        oldWidget.message.model != widget.message.model ||
        _didVersionMetadataChange(oldWidget)) {
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

  void _queueDisplayedContentRefresh([String? overrideContent]) {
    _queueDisplayedContent(_resolvedMessageContent(overrideContent));
  }

  void _queueDisplayedContent(String raw) {
    if (!mounted) {
      _applyDisplayedContent(raw);
      return;
    }

    _pendingDisplayedContent = raw;
    if (_displayedContentFrameScheduled) {
      return;
    }

    _displayedContentFrameScheduled = true;
    WidgetsBinding.instance.scheduleFrame();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _displayedContentFrameScheduled = false;
      if (!mounted) {
        return;
      }
      final pending = _pendingDisplayedContent;
      _pendingDisplayedContent = null;
      if (pending == null) {
        return;
      }
      _applyDisplayedContent(pending);
    });
  }

  void _applyDisplayedContent(String raw) {
    final shouldFadeStreamingContent = _shouldFadeInStreamingContent(raw);
    final previousLength = _displayedContent.length;
    final contentChanged = raw != _displayedContent;

    if (contentChanged) {
      if (shouldFadeStreamingContent) {
        _streamingContentFadeController.value = 0.0;
      }
      if (mounted) {
        setState(() {
          _displayedContent = raw;
        });
      } else {
        _displayedContent = raw;
      }
      if (shouldFadeStreamingContent) {
        _streamingContentFadeController.forward();
      }
      if (widget.isStreaming) {
        _onStreamingChunk(previousLength, raw.length);
      }
    }

    if (raw.trim().isEmpty ||
        raw != _lastAppliedTtsPlainTextSource ||
        _isPreparingTtsPlainText) {
      _resetTtsPlainTextState();
    }
    _updateTypingIndicatorGate();
  }

  void _primeInitialStreamingContentFade() {
    if (!_canFadeStreamingContent(_displayedContent)) {
      return;
    }
    _streamingContentFadeController.value = 0.0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _disableAnimations || !_uiTreatsAsStreaming) {
        return;
      }
      _streamingContentFadeController.forward();
    });
  }

  bool _shouldFadeInStreamingContent(String nextRaw) {
    return _canFadeStreamingContent(nextRaw) &&
        _displayedContent.trim().isEmpty;
  }

  bool _canFadeStreamingContent(String nextRaw) {
    if (_disableAnimations || !_uiTreatsAsStreaming) {
      return false;
    }
    return nextRaw.trim().isNotEmpty;
  }

  void _setActiveVersionIndex(int nextIndex) {
    final raw = _resolvedMessageContent(null, nextIndex);
    setState(() {
      _activeVersionIndex = nextIndex;
      _displayedContent = raw;
    });
    _resetTtsPlainTextState();
    _buildCachedAvatar();
    _updateTypingIndicatorGate();
  }

  void _updateTypingIndicatorGate() {
    _typingGateTimer?.cancel();
    if (_shouldShowStreamingIndicator) {
      if (_allowTypingIndicator) {
        return;
      }
      _typingGateTimer = Timer(const Duration(milliseconds: 150), () {
        if (!mounted || !_shouldShowStreamingIndicator) {
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

  /// Drives the action-row hysteresis. While the UI still treats the message as
  /// streaming, the row stays suppressed and `_actionRowSettled` is reset so a
  /// later resume can't show a stale row. `responseDone` is a settled UI state:
  /// it can show the final action row even before the transport flag flips.
  void _updateActionRowSettle() {
    if (_uiTreatsAsStreaming) {
      _hasStreamedThisMessage = true;
      _actionRowSettled = false;
      return;
    }
    if (widget.message.metadata?['responseDone'] == true) {
      _hasStreamedThisMessage = true;
      _actionRowSettled = true;
      return;
    }
    if (!_hasStreamedThisMessage) {
      // History message: action row shows immediately, no settle needed.
      return;
    }
  }

  /// Whether the streaming/typing indicator should currently occupy the footer
  /// slot. Gated by the 150ms anti-flash window.
  bool get _showStreamingIndicatorNow =>
      _allowTypingIndicator && _shouldShowStreamingIndicator;

  /// Whether the action row may replace the streaming indicator in the footer.
  bool get _showActionRowNow {
    if (_uiTreatsAsStreaming || !_responseCompleted) {
      return false;
    }
    if (!_hasStreamedThisMessage) {
      return true;
    }
    return _actionRowSettled;
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

  void _resetTtsPlainTextState() {
    final hadCachedText = _ttsPlainText.isNotEmpty;
    final wasPreparing = _isPreparingTtsPlainText;
    final hadAppliedSource = _lastAppliedTtsPlainTextSource != null;
    if (!hadCachedText && !wasPreparing && !hadAppliedSource) {
      return;
    }
    _ttsPlainTextRequestId++;
    _ttsPlainText = '';
    _isPreparingTtsPlainText = false;
    _lastAppliedTtsPlainTextSource = null;
  }

  Future<String> _buildTtsPlainTextOnDemand(String raw) async {
    if (raw == _lastAppliedTtsPlainTextSource) {
      return _ttsPlainText;
    }
    if (raw.trim().isEmpty) {
      _resetTtsPlainTextState();
      return '';
    }

    final requestId = ++_ttsPlainTextRequestId;
    if (mounted && !_isPreparingTtsPlainText) {
      setState(() {
        _isPreparingTtsPlainText = true;
      });
    } else {
      _isPreparingTtsPlainText = true;
    }

    final payload = <String, dynamic>{'raw': raw};
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

    if (requestId != _ttsPlainTextRequestId) {
      return '';
    }

    if (!mounted) {
      _lastAppliedTtsPlainTextSource = raw;
      _ttsPlainText = speechText;
      _isPreparingTtsPlainText = false;
      return speechText;
    }

    final shouldNotify =
        _ttsPlainText != speechText ||
        _isPreparingTtsPlainText ||
        _lastAppliedTtsPlainTextSource != raw;
    _lastAppliedTtsPlainTextSource = raw;
    if (shouldNotify) {
      setState(() {
        _ttsPlainText = speechText;
        _isPreparingTtsPlainText = false;
      });
    } else {
      _isPreparingTtsPlainText = false;
    }
    return speechText;
  }

  Future<void> _handleTtsToggle(String messageId) async {
    if (messageId.isEmpty || _isPreparingTtsPlainText) {
      return;
    }
    final controller = ref.read(textToSpeechControllerProvider.notifier);
    final ttsState = ref.read(textToSpeechControllerProvider);
    final isActiveMessage = ttsState.activeMessageId == messageId;
    final hasActivePlayback =
        isActiveMessage &&
        ttsState.status != TtsPlaybackStatus.idle &&
        ttsState.status != TtsPlaybackStatus.error;

    if (hasActivePlayback) {
      await controller.toggleForMessage(
        messageId: messageId,
        text: _ttsPlainText,
      );
      return;
    }

    final speechText = await _buildTtsPlainTextOnDemand(_displayedContent);
    if (!mounted || speechText.trim().isEmpty) {
      return;
    }
    await controller.toggleForMessage(messageId: messageId, text: speechText);
  }

  Widget _buildMessageContent() {
    final children = <Widget>[];
    final trimmedContent = _displayedContent.trim();
    if (trimmedContent.isNotEmpty) {
      final markdownWidget = _buildEnhancedMarkdownContent(_displayedContent);
      children.add(RepaintBoundary(child: markdownWidget));
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

  Widget _buildStreamingContentBody() {
    final body = _buildMessageContent();
    // Always wrap in a FadeTransition with a stable key/type so the widget at
    // this slot does not change runtimeType when streaming starts/completes.
    // Toggling between FadeTransition and the bare body would defeat element
    // reconciliation and tear down the markdown subtree at the streaming
    // boundary. When not actively fading we feed a fully-opaque constant
    // animation, which is visually identical to returning the bare body.
    final fade = _canFadeStreamingContent(_displayedContent)
        ? _streamingContentFade
        : const AlwaysStoppedAnimation<double>(1.0);
    return FadeTransition(
      key: const ValueKey('assistant-streaming-content-fade'),
      opacity: fade,
      child: body,
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
      child: RichText(
        text: buildSpans(),
        textScaler: MediaQuery.textScalerOf(context),
      ),
    );
  }

  bool get _hasPendingVisibleStatus => widget.message.statusHistory
      .where((status) => status.hidden != true)
      .any((status) => status.done != true);

  /// The streaming indicator lives in the footer slot and persists for the
  /// whole generation (text/tool-calls/status stream in above it), then is
  /// swapped for the action row once streaming completes. A pending visible
  /// status already renders its own shimmer, so suppress the indicator then
  /// (matches the behaviour the widget test asserts).
  bool get _shouldShowStreamingIndicator =>
      _uiTreatsAsStreaming && !_hasPendingVisibleStatus;

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
                letterSpacing: AppTypography.letterSpacingNormal,
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
      final rawVersionModelName = widget
          .message
          .versions[_activeVersionIndex]
          .modelName
          ?.trim();
      if (rawVersionModelName != null && rawVersionModelName.isNotEmpty) {
        return rawVersionModelName;
      }
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
  }

  /// Fires a single haptic impulse if streaming haptics are enabled.
  void _streamingHaptic(HapticType type) {
    final enabled = _streamingHapticsAllowed;
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
    if (!_streamingHapticsAllowed) return;
    PlatformService.hapticFeedback(type: HapticType.medium);
    Future.delayed(const Duration(milliseconds: 150), () {
      if (!mounted || !_streamingHapticsAllowed) return;
      PlatformService.hapticFeedback(type: HapticType.medium);
    });
    Future.delayed(const Duration(milliseconds: 300), () {
      if (!mounted || !_streamingHapticsAllowed) return;
      PlatformService.hapticFeedback(type: HapticType.medium);
    });
  }

  bool get _streamingHapticsAllowed =>
      ref.read(streamingHapticsEnabledProvider) &&
      !widget.suppressStreamingHaptics;

  /// Subscribes to [streamingContentProvider] only while this message is
  /// actively streaming. Uses [ref.listenManual] for explicit lifecycle
  /// control instead of calling [ref.listen] inside [build].
  void _syncStreamingContentSubscription() {
    _streamingContentSub?.close();
    _streamingContentSub = null;

    if (widget.isStreaming && _canListenToStreamingContent) {
      _streamingContentSub = ref.listenManual(streamingContentProvider, (
        prev,
        next,
      ) {
        if (next != null && next != _lastStreamingContent) {
          _lastStreamingContent = next;
          _queueDisplayedContentRefresh(next);
        }
      }, fireImmediately: true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _streamingContentSub?.close();
    _typingGateTimer?.cancel();
    _resetTtsPlainTextState();
    _fadeController.dispose();
    _streamingContentFade.dispose();
    _streamingContentFadeController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final nextIsForeground = _isLifecycleForeground(state);
    if (_isAppForeground == nextIsForeground) {
      return;
    }
    _isAppForeground = nextIsForeground;
    _syncStreamingContentSubscription();
  }

  bool get _canListenToStreamingContent => _isAppForeground && _isRouteVisible;

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
    _syncStreamingContentSubscription();
  }

  bool _didMessageContentChange(AssistantMessageWidget oldWidget) {
    if (oldWidget.message.content != widget.message.content) {
      return true;
    }
    return oldWidget.isStreaming != widget.isStreaming;
  }

  bool _didTypingIndicatorInputsChange(AssistantMessageWidget oldWidget) {
    return _statusSignature(oldWidget.message.statusHistory) !=
            _statusSignature(widget.message.statusHistory) ||
        _collectionLength(oldWidget.message.files) !=
            _collectionLength(widget.message.files) ||
        _collectionLength(oldWidget.message.embeds) !=
            _collectionLength(widget.message.embeds) ||
        _collectionLength(oldWidget.message.attachmentIds) !=
            _collectionLength(widget.message.attachmentIds) ||
        _collectionLength(oldWidget.message.followUps) !=
            _collectionLength(widget.message.followUps) ||
        _collectionLength(oldWidget.message.codeExecutions) !=
            _collectionLength(widget.message.codeExecutions) ||
        oldWidget.isStreaming != widget.isStreaming;
  }

  int _statusSignature(List<ChatStatusUpdate> statuses) {
    return Object.hashAll(
      statuses.map(
        (status) => Object.hash(
          status.action,
          status.description,
          status.done,
          status.hidden,
        ),
      ),
    );
  }

  int _collectionLength(Iterable<dynamic>? values) => values?.length ?? 0;

  void _clearVisibleFollowUps() {
    _visibleFollowUpScopeId = null;
    _visibleFollowUps = const <String>[];
  }

  bool _didVersionMetadataChange(AssistantMessageWidget oldWidget) {
    final oldVersions = oldWidget.message.versions;
    final newVersions = widget.message.versions;
    if (oldVersions.length != newVersions.length) {
      return true;
    }
    for (var index = 0; index < oldVersions.length; index += 1) {
      if (oldVersions[index].id != newVersions[index].id ||
          oldVersions[index].model != newVersions[index].model ||
          oldVersions[index].modelName != newVersions[index].modelName) {
        return true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return _buildDocumentationMessage();
  }

  Widget _buildDocumentationMessage() {
    final displayStatusHistory = filterVisibleStatusUpdates(
      widget.message.statusHistory,
      isStreaming: _uiTreatsAsStreaming,
    );
    final hasStatusTimeline = displayStatusHistory.isNotEmpty;
    final activeCodeExecutions = _resolveActiveCodeExecutions();
    final hasCodeExecutions = activeCodeExecutions.isNotEmpty;
    final bool showingVersion = _activeVersionIndex >= 0;
    final activeFiles = showingVersion
        ? widget.message.versions[_activeVersionIndex].files
        : widget.message.files;
    final activeEmbeds = _resolveActiveEmbeds();
    final queuedCompletionAsync = ref.watch(
      queuedCompletionInfoForMessageProvider(_messageId),
    );
    final queuedCompletion = queuedCompletionAsync.hasValue
        ? queuedCompletionAsync.value
        : null;
    final hasQueuedCompletion = queuedCompletion != null;
    final footerSwitchDuration =
        (_showStreamingIndicatorNow || _showActionRowNow)
        ? const Duration(milliseconds: 180)
        : Duration.zero;
    final showQueuedAsEmptyState =
        queuedCompletion != null &&
        _isAssistantResponseEmpty &&
        !queuedCompletion.isFailed;
    final suppressEmptyQueuedContent =
        queuedCompletion != null && _isAssistantResponseEmpty;
    final showQueuedRecoveryBanner =
        queuedCompletion != null && !showQueuedAsEmptyState;
    final shouldBuildActionFooter = _showActionRowNow && !hasQueuedCompletion;
    final activeFollowUps = shouldBuildActionFooter
        ? _resolveVisibleFollowUps()
        : const <String>[];
    final hasFollowUps =
        shouldBuildActionFooter &&
        widget.showFollowUps &&
        activeFollowUps.isNotEmpty &&
        _responseCompleted;
    final activeSources = shouldBuildActionFooter
        ? _resolveActiveSources()
        : const <ChatSourceReference>[];
    final footer = shouldBuildActionFooter
        ? _buildFooterBar(activeSources: activeSources)
        : null;

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
                    updates: displayStatusHistory,
                    isStreaming: _uiTreatsAsStreaming,
                  ),
                  const SizedBox(height: Spacing.xs),
                ],

                if (showQueuedAsEmptyState)
                  _buildQueuedCompletionBanner(queuedCompletion)
                else if (suppressEmptyQueuedContent)
                  const SizedBox.shrink()
                else
                  // Content streams in here; the typing indicator now lives in
                  // the footer slot below (and persists while text streams in
                  // above it). Empty content renders as SizedBox.shrink.
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
                    child: KeyedSubtree(
                      key: const ValueKey('content'),
                      child: _buildStreamingContentBody(),
                    ),
                  ),

                if (showQueuedRecoveryBanner) ...[
                  const SizedBox(height: Spacing.sm),
                  _buildQueuedCompletionBanner(queuedCompletion),
                ],

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

          // Footer slot: the typing indicator occupies the action-row position
          // while streaming (content streams above it) and crossfades to the
          // action row exactly once, when generation completes.
          if (!hasQueuedCompletion)
            AnimatedSwitcher(
              duration: footerSwitchDuration,
              reverseDuration: footerSwitchDuration,
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              layoutBuilder: (currentChild, previousChildren) {
                final children = <Widget>[
                  if (!_uiTreatsAsStreaming) ...previousChildren,
                  ?currentChild,
                ];
                if (children.isEmpty) {
                  return const SizedBox.shrink();
                }
                return Stack(
                  alignment: AlignmentDirectional.topStart,
                  children: children,
                );
              },
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
              child: _buildFooterSlot(
                footer: footer,
                hasFollowUps: hasFollowUps,
                activeFollowUps: activeFollowUps,
              ),
            ),
        ],
      ),
    );

    // Animate on first appearance only, not on every streaming rebuild
    if (!_hasAnimated) {
      _hasAnimated = true;
      _fadeController.forward();
    }

    return FadeTransition(opacity: _fadeController, child: content);
  }

  /// Builds the keyed child for the footer [AnimatedSwitcher]: the typing
  /// indicator while streaming, the action row + follow-ups once completed,
  /// or an empty slot during the gate / transient window.
  Widget _buildFooterSlot({
    required Widget? footer,
    required bool hasFollowUps,
    required List<String> activeFollowUps,
  }) {
    if (_showStreamingIndicatorNow) {
      return KeyedSubtree(
        key: const ValueKey('typing'),
        child: Padding(
          padding: EdgeInsets.only(
            top: ConduitMarkdownStyle.fromTheme(context).paragraphSpacing,
          ),
          child: _buildTypingIndicator(),
        ),
      );
    }

    if (_showActionRowNow) {
      final children = <Widget>[];
      if (footer != null) {
        children.add(
          Padding(
            padding: EdgeInsets.only(
              top: ConduitMarkdownStyle.fromTheme(context).paragraphSpacing,
            ),
            child: footer,
          ),
        );
      }
      if (hasFollowUps) {
        children.add(const SizedBox(height: Spacing.md));
        children.add(_buildFollowUpSuggestions(activeFollowUps));
      }
      if (children.isNotEmpty) {
        return KeyedSubtree(
          key: const ValueKey('actions'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        );
      }
    }

    return const SizedBox.shrink(key: ValueKey('footer-empty'));
  }

  Widget _buildQueuedCompletionBanner(QueuedCompletionInfo info) {
    final l10n = AppLocalizations.of(context)!;
    final conduitTheme = context.conduitTheme;
    final errorColor = Theme.of(context).colorScheme.error;
    final accentColor = info.isFailed ? errorColor : conduitTheme.buttonPrimary;
    final title = info.isFailed
        ? l10n.chatQueuedFailedTitle
        : info.isOffline
        ? l10n.chatQueuedOfflineTitle
        : l10n.chatQueuedPendingTitle;
    final message = info.isFailed
        ? l10n.chatQueuedFailedMessage
        : info.isOffline
        ? l10n.chatQueuedOfflineMessage
        : l10n.chatQueuedPendingMessage;
    final icon = info.isFailed
        ? (Platform.isIOS
              ? CupertinoIcons.exclamationmark_triangle
              : Icons.error_outline)
        : info.isOffline
        ? (Platform.isIOS ? CupertinoIcons.wifi_slash : Icons.wifi_off)
        : (Platform.isIOS ? CupertinoIcons.clock : Icons.schedule);

    return Container(
      constraints: const BoxConstraints(maxWidth: 560),
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: accentColor.withValues(alpha: 0.08),
        border: Border.all(color: accentColor.withValues(alpha: 0.22)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 20, color: accentColor),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: conduitTheme.textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      message,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: conduitTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          Wrap(
            spacing: Spacing.xs,
            runSpacing: Spacing.xs,
            children: [
              TextButton.icon(
                onPressed: () => _retryQueuedCompletion(info),
                icon: Icon(
                  Platform.isIOS ? CupertinoIcons.refresh : Icons.refresh,
                  size: 16,
                ),
                label: Text(l10n.retry),
                style: TextButton.styleFrom(
                  foregroundColor: accentColor,
                  minimumSize: const Size(0, 34),
                  padding: const EdgeInsets.symmetric(
                    horizontal: Spacing.sm,
                    vertical: 6,
                  ),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              TextButton.icon(
                onPressed: () => _cancelQueuedCompletion(info),
                icon: Icon(
                  Platform.isIOS ? CupertinoIcons.xmark : Icons.close,
                  size: 16,
                ),
                label: Text(l10n.cancel),
                style: TextButton.styleFrom(
                  foregroundColor: conduitTheme.textSecondary,
                  minimumSize: const Size(0, 34),
                  padding: const EdgeInsets.symmetric(
                    horizontal: Spacing.sm,
                    vertical: 6,
                  ),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _retryQueuedCompletion(QueuedCompletionInfo info) {
    unawaited(() async {
      try {
        await ref.read(queuedCompletionActionsProvider).retry(info);
      } catch (error, stackTrace) {
        _handleQueuedCompletionActionError(error, stackTrace);
      }
    }());
  }

  void _cancelQueuedCompletion(QueuedCompletionInfo info) {
    unawaited(() async {
      try {
        await ref.read(queuedCompletionActionsProvider).cancel(info);
      } catch (error, stackTrace) {
        _handleQueuedCompletionActionError(error, stackTrace);
      }
    }());
  }

  void _handleQueuedCompletionActionError(Object error, StackTrace stackTrace) {
    DebugLogger.error(
      'queued-completion-action-failed',
      scope: 'chat/assistant',
      error: error,
      stackTrace: stackTrace,
    );
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context)!.errorMessage)),
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
    final bodyTreatsAsStreaming = _uiTreatsAsStreaming;

    Widget buildDefault(BuildContext context) {
      return StreamingMarkdownWidget(
        content: processedContent,
        isStreaming: bodyTreatsAsStreaming,
        enableStreamingTextFade: bodyTreatsAsStreaming && !_disableAnimations,
        askConduitComposerTargetId: chatComposerTextInsertionTargetId,
        stateScopeId: _markdownStateScopeId(),
        onTapLink: (url, _) => launchExternalLink(url, scope: 'chat/assistant'),
        sources: activeSources,
        imageBuilderOverride: (uri, title, alt) {
          // Route markdown images through the enhanced image widget so they
          // get caching, auth headers, fullscreen viewer, and sharing.
          return RepaintBoundary(
            child: EnhancedImageAttachment(
              attachmentId: uri.toString(),
              isMarkdownFormat: true,
              constraints: const BoxConstraints(maxWidth: 500, maxHeight: 400),
              disableAnimation: bodyTreatsAsStreaming,
            ),
          );
        },
      );
    }

    final responseBuilder = ref.watch(assistantResponseBuilderProvider);
    if (responseBuilder != null) {
      final contextData = AssistantResponseContext(
        message: widget.message,
        markdown: processedContent,
        isStreaming: bodyTreatsAsStreaming,
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

  String _followUpStateScopeId() {
    final selectedVersionIndex = _activeVersionIndex;
    if (selectedVersionIndex >= 0 &&
        selectedVersionIndex < widget.message.versions.length) {
      final versionId = widget.message.versions[selectedVersionIndex].id;
      return 'follow-ups|${widget.message.id}|version:$versionId';
    }
    return 'follow-ups|${widget.message.id}|current';
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

  List<String> _resolveVisibleFollowUps() {
    final rawFollowUps = _resolveActiveFollowUps();
    if (!widget.showFollowUps || _uiTreatsAsStreaming || !_responseCompleted) {
      return rawFollowUps;
    }

    final scopeId = _followUpStateScopeId();
    if (rawFollowUps.isNotEmpty) {
      _visibleFollowUpScopeId = scopeId;
      _visibleFollowUps = List<String>.unmodifiable(rawFollowUps);
      return rawFollowUps;
    }

    if (_visibleFollowUpScopeId == scopeId && _visibleFollowUps.isNotEmpty) {
      return _visibleFollowUps;
    }

    return rawFollowUps;
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
                disableAnimation: _uiTreatsAsStreaming,
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
                  disableAnimation: _uiTreatsAsStreaming,
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
            child: RepaintBoundary(child: WebContentEmbed(source: source)),
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

                  return RepaintBoundary(
                    child: EnhancedImageAttachment(
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
                    ),
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

                return RepaintBoundary(
                  child: EnhancedImageAttachment(
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
                  ),
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
          disableAnimation: _uiTreatsAsStreaming,
        );
      }).toList(),
    );
  }

  Widget _buildTypingIndicator() {
    final theme = context.conduitTheme;
    final dotColor = theme.textSecondary.withValues(alpha: 0.75);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
      child: RepaintBoundary(
        child: FiveRotatingDots(
          size: 28,
          color: dotColor,
          animate: !_disableAnimations,
        ),
      ),
    );
  }

  Widget? _buildFooterBar({required List<ChatSourceReference> activeSources}) {
    const maxInlineActions = 3;
    final actions = _buildFooterActions();
    final forcedOverflowActions = actions
        .where((action) => action.id == 'delete')
        .toList(growable: false);
    final inlineCandidateActions = actions
        .where((action) => action.id != 'delete')
        .toList(growable: false);
    final visibleActions = actions
        .where((action) => action.id != 'delete')
        .take(maxInlineActions)
        .toList(growable: false);
    final overflowActions = [
      ...inlineCandidateActions.skip(maxInlineActions),
      ...forcedOverflowActions,
    ];
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
        crossAxisAlignment: WrapCrossAlignment.center,
        children: leftAlignedWidgets,
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Wrap(
            spacing: Spacing.sm,
            runSpacing: Spacing.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
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
    final ttsState = ref.read(textToSpeechControllerProvider);
    final isChatStreaming = ref.read(isChatStreamingProvider);
    final activeUsage = _resolveActiveUsage();
    final messageId = _messageId;
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
    final bool contentActionsBlockedByStreaming =
        _uiTreatsAsStreaming && !isActiveMessage;
    final bool ttsAvailable = !ttsState.initialized || ttsState.available;
    final bool showStopState =
        isActiveMessage && (isSpeaking || isPaused || isBusy);
    final bool showPreparingTtsState = _isPreparingTtsPlainText;
    final bool shouldShowTtsButton =
        (showStopState ||
            showPreparingTtsState ||
            _displayedContent.trim().isNotEmpty) &&
        messageId.isNotEmpty;
    final bool canStartTts =
        shouldShowTtsButton &&
        !contentActionsBlockedByStreaming &&
        ttsAvailable &&
        !showPreparingTtsState;
    final bool currentStreamingMessageCompleted =
        widget.isStreaming && _responseCompleted;
    final bool canRegenerate =
        widget.onRegenerate != null &&
        (!isChatStreaming || currentStreamingMessageCompleted);
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
        unawaited(_handleTtsToggle(messageId));
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
        onTap: _responseCompleted ? widget.onCopy : null,
        sfSymbol: 'doc.on.clipboard',
      ),
      if (shouldShowTtsButton)
        _AssistantFooterAction(
          id: 'tts',
          icon: (showStopState || showPreparingTtsState)
              ? stopIcon
              : listenIcon,
          label: (showStopState || showPreparingTtsState)
              ? l10n.ttsStop
              : l10n.ttsListen,
          onTap: ttsOnTap,
          sfSymbol: (showStopState || showPreparingTtsState)
              ? 'stop.fill'
              : 'speaker.wave.2.fill',
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
      _AssistantFooterAction(
        id: 'delete',
        icon: Platform.isIOS ? CupertinoIcons.delete : Icons.delete_outline,
        label: l10n.delete,
        onTap: widget.onDelete,
        sfSymbol: 'trash',
      ),
    ];

    return actions;
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    VoidCallback? onTap,
  }) {
    return ChatActionButton(icon: icon, label: label, onTap: onTap);
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
      buttonStyle: PopupButtonStyle.plain,
      child: AdaptiveTooltip(
        message: l10n.more,
        waitDuration: const Duration(milliseconds: 600),
        child: Semantics(
          button: true,
          label: l10n.more,
          child: SizedBox(
            width: 32,
            height: 32,
            child: Center(
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
          opacity: CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          ),
          child: child,
        );
      },
      child: shouldShow
          ? KeyedSubtree(
              key: ValueKey<String>(_followUpStateScopeId()),
              child: FollowUpSuggestionBar(
                suggestions: suggestions,
                onSelected: _handleFollowUpTap,
                isBusy: _uiTreatsAsStreaming,
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
