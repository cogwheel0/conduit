import 'dart:async';
import 'dart:io' show Platform;

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/markdown/streaming_markdown_widget.dart';
import '../../../shared/widgets/markdown/renderer/markdown_style.dart';

import 'package:conduit_core/models/chat_comparison.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/message_voice.dart';
import 'package:conduit_core/features/web_search/services/direct_web_search_mode.dart';
import 'package:conduit_markdown/conduit_markdown.dart';

import '../providers/text_to_speech_provider.dart';

import 'package:conduit_core/features/chat/providers/queued_completion_provider.dart';
import 'package:conduit_core/features/chat/providers/streaming_haptic_memory.dart';

import 'enhanced_image_attachment.dart';
import 'image_gallery_scope.dart';

import 'package:conduit/l10n/app_localizations.dart';

import 'enhanced_attachment.dart';

import 'package:conduit/shared/widgets/chat_action_button.dart';

import '../../../shared/widgets/model_avatar.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/middle_ellipsis_text.dart';
import '../../../shared/widgets/web_content_embed.dart';

import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show
        ChatForkAvailability,
        ComparisonAnswerStop,
        ComparisonMergeException,
        ComparisonMergeFailure,
        chatBranchSiblingsProvider,
        comparisonMergeCommandAvailableProvider,
        comparisonMergeProvider,
        stopComparisonAnswerProvider,
        chatComposerTextInsertionTargetId,
        chatForkAvailabilityProvider,
        comparisonAnswerStopPermittedProvider,
        isChatStreamingProvider,
        sendMessageWithContainer,
        streamingContentProvider,
        chatMessagesProvider;
import 'package:conduit_core/providers/app_providers.dart'
    show activeConversationProvider;

import '../../../shared/utils/external_link_launcher.dart';

import 'package:conduit_core/utils/debug_logger.dart';

import '../../../core/services/haptic_service.dart';

import 'package:conduit_core/services/settings_service.dart';

import 'sources/openwebui_sources.dart';
import '../providers/assistant_response_builder_provider.dart';

import 'package:conduit_core/features/chat/views/chat_turn_render_state.dart';

import 'package:conduit_core/services/worker_manager.dart';

import 'streaming_status_widget.dart';

import 'package:conduit_core/features/chat/utils/file_utils.dart';

import 'chat_branch_actions.dart';
import 'chat_comparison_widgets.dart';
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

  /// Another user's chat (shared folder): only copy/listen/version browsing.
  final bool readOnly;
  final bool animateOnMount;
  final String? modelName;
  final String? modelIconUrl;

  /// Whether to paint the avatar + model name above this response.
  ///
  /// False for a row that continues the response above it (a Hermes turn can
  /// emit several assistant messages), so one logical answer shows one header.
  final bool showModelHeader;

  /// Whether to paint the completion action bar below this response.
  ///
  /// The counterpart to [showModelHeader]: within one grouped response the
  /// header sits on the first row and the bar on the last, so a single answer
  /// shows one of each. Sources and the version chip still render on their own
  /// row when this is false — only the buttons move.
  final bool showActionBar;

  /// Supplies the full text of the grouped response for read-aloud.
  ///
  /// Called at tap time, not during build, so a row never has to observe its
  /// siblings. Null means this row speaks its own content.
  final String Function()? resolveGroupedResponseText;
  final List<String?> versionModelNames;
  final List<String?> versionModelIconUrls;
  final bool suppressStreamingHaptics;
  final VoidCallback? onCopy;
  final VoidCallback? onRegenerate;
  final VoidCallback onDelete;
  final VoidCallback? onLike;
  final VoidCallback? onDislike;
  final FutureOr<void> Function(String suggestion)? onFollowUpSelected;

  @visibleForTesting
  final VoidCallback? debugOnShellBuild;

  @visibleForTesting
  final VoidCallback? debugOnStreamingContentBuild;

  const AssistantMessageWidget({
    super.key,
    required this.message,
    this.isStreaming = false,
    this.showFollowUps = true,
    this.readOnly = false,
    this.animateOnMount = true,
    this.modelName,
    this.modelIconUrl,
    this.showModelHeader = true,
    this.showActionBar = true,
    this.resolveGroupedResponseText,
    this.versionModelNames = const <String?>[],
    this.versionModelIconUrls = const <String?>[],
    this.suppressStreamingHaptics = false,
    this.onCopy,
    this.onRegenerate,
    required this.onDelete,
    this.onLike,
    this.onDislike,
    this.onFollowUpSelected,
    this.debugOnShellBuild,
    this.debugOnStreamingContentBuild,
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
  late final ValueNotifier<String> _displayedContentListenable;
  Widget? _cachedAvatar;
  String? _cachedAvatarModelName;
  String? _cachedAvatarIconUrl;
  bool _cachedAvatarVoiceReply = false;
  // Hysteresis for the action row: a message that has streamed in this widget's
  // lifetime must reach a settled completion before the action row appears, so
  // a transient in-progress state can never flash the row mid-stream. Settled
  // on `responseDone` or on the streaming-end transition. History messages
  // never set `_hasStreamedThisMessage` and show their action row immediately.
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
  late final void Function(String url, String title) _markdownLinkTapCallback;
  late final Widget Function(Uri uri, String? title, String? alt)
  _markdownImageBuilder;

  ProviderSubscription<String?>? _streamingContentSub;

  /// Remount-proof per-message guards for the streaming haptics; a recreated
  /// State must never replay the content-arrival or completion pulses.
  StreamingHapticMemory get _hapticMemory =>
      ref.read(streamingHapticMemoryProvider);

  bool get _shouldAnimateOnMount =>
      widget.animateOnMount && !_disableAnimations;

  ChatMessage? get _chatMessage =>
      widget.message is ChatMessage ? widget.message as ChatMessage : null;

  /// A reply a realtime call's voice gave by itself, stored under the voice
  /// model. There is no chat model answer to run again.
  bool get _isVoiceReply => _spokenOnly(widget.message);

  static bool _spokenOnly(Object? message) =>
      message is ChatMessage && voiceReplayFor(message).spokenOnly;

  ChatTurnPhase get _turnPhase =>
      chatTurnPhaseForMessage(_chatMessage, isStreaming: widget.isStreaming);

  // Phase derivation routes through chatTurnPhaseForMessage, which returns
  // ChatTurnPhase.none for a null/non-ChatMessage. Every production call site
  // and test supplies a ChatMessage, so the helper path is the only reachable
  // one; deriving from the shared phase rule keeps a single source of truth.
  bool get _responseCompleted {
    if (_activeVersionIndex >= 0) {
      return true;
    }
    return chatTurnPhaseShowsCompletedFooter(_turnPhase);
  }

  bool get _uiTreatsAsStreaming =>
      _activeVersionIndex < 0 && _turnPhase == ChatTurnPhase.running;

  // press state handled by shared ChatActionButton

  Future<void> _handleFollowUpTap(String suggestion) async {
    final trimmed = suggestion.trim();
    if (trimmed.isEmpty ||
        widget.readOnly ||
        _uiTreatsAsStreaming ||
        !_responseCompleted) {
      return;
    }
    try {
      final onFollowUpSelected = widget.onFollowUpSelected;
      if (onFollowUpSelected != null) {
        await onFollowUpSelected(trimmed);
        return;
      }
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
    _markdownLinkTapCallback = _handleMarkdownLinkTap;
    _markdownImageBuilder = _buildMarkdownImage;
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
    _displayedContentListenable = ValueNotifier<String>(_displayedContent);
    _primeInitialStreamingContentFade();
    _updateActionRowSettle();
    _syncStreamingContentSubscription();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _disableAnimations = context.reduceMotion;
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
      _displayedContentListenable.value = '';
      _pendingDisplayedContent = null;
      _cachedAvatar = null;
      _cachedAvatarModelName = null;
      _cachedAvatarIconUrl = null;
      _clearVisibleFollowUps();
      _resetTtsPlainTextState();
      _hasAnimated = !_shouldAnimateOnMount;
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

    // A transport flag can flap while ownership moves between optimistic,
    // durable, and server-echo rows. Completion haptics therefore follow the
    // durable responseDone transition, not raw isStreaming changes.
    final responseCompleted =
        oldWidget.message.metadata?['responseDone'] != true &&
        widget.message.metadata?['responseDone'] == true;
    if (responseCompleted &&
        oldWidget.message.id == widget.message.id &&
        _hapticMemory.markFired(
          widget.message.id,
          StreamingHapticEvent.turnCompleted,
        )) {
      _streamingHaptic(HapticType.medium);
    }

    // Genuine streaming end: allow the action row to replace the indicator.
    if (oldWidget.isStreaming &&
        !widget.isStreaming &&
        oldWidget.message.id == widget.message.id) {
      _hasStreamedThisMessage = true;
      _actionRowSettled = true;
    }

    // Refresh rendered content when the active message changes.
    if (messageChanged || _didMessageContentChange(oldWidget)) {
      _queueDisplayedContentRefresh();
    }

    if (oldWidget.isStreaming != widget.isStreaming ||
        oldWidget.message.metadata?['responseDone'] !=
            widget.message.metadata?['responseDone'] ||
        // An error can appear in place (failing the turn) while isStreaming
        // stays true, flipping the phase to failed without an isStreaming or
        // responseDone change; re-settle so the action row surfaces.
        oldWidget.message.error != widget.message.error) {
      _updateActionRowSettle();
    }

    // Rebuild cached avatar if model name or icon changes
    if (messageChanged ||
        oldWidget.showModelHeader != widget.showModelHeader ||
        oldWidget.modelName != widget.modelName ||
        oldWidget.modelIconUrl != widget.modelIconUrl ||
        oldWidget.versionModelNames != widget.versionModelNames ||
        oldWidget.versionModelIconUrls != widget.versionModelIconUrls ||
        oldWidget.message.model != widget.message.model ||
        // A call's transcript can arrive after the message did.
        _spokenOnly(oldWidget.message) != _isVoiceReply ||
        _didVersionMetadataChange(oldWidget)) {
      _buildCachedAvatar();
    }
  }

  String _resolvedMessageContent([String? overrideContent, int? versionIndex]) {
    final selectedVersionIndex = versionIndex ?? _activeVersionIndex;
    // The canonical message and the visible-stream provider publish on
    // different schedules. A row rebuild can otherwise overwrite a newer
    // tool projection with the older canonical text in the same frame.
    // Read their shared owner so either publication order uses the current
    // buffer, including when a virtualized row remounts between flushes.
    final streamingContent =
        selectedVersionIndex < 0 &&
            widget.isStreaming &&
            ref.exists(chatMessagesProvider)
        ? ref
              .read(chatMessagesProvider.notifier)
              .contentForStreamingMessage(widget.message.id)
        : null;
    final raw0 = selectedVersionIndex >= 0
        ? (widget.message.versions[selectedVersionIndex].content as String?) ??
              ''
        : (streamingContent ?? overrideContent ?? widget.message.content ?? '');

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
    // Apply the latest streamed text before build so this requested frame can
    // render it immediately. Deferring until after the frame creates a second
    // frame and makes iOS composite the persistent native glass twice for one
    // visible content update.
    WidgetsBinding.instance.scheduleFrameCallback((_) {
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
      final shellPresentationChanged =
          _displayedContent.trim().isEmpty != raw.trim().isEmpty;
      if (shouldFadeStreamingContent) {
        _streamingContentFadeController.value = 0.0;
      }
      if (mounted && shellPresentationChanged) {
        // The shell only needs the empty/non-empty boundary so queued and empty
        // states can hand off to the live body. Later token batches remain
        // isolated to the ValueListenableBuilder below.
        setState(() {
          _displayedContent = raw;
        });
      } else {
        _displayedContent = raw;
      }
      _displayedContentListenable.value = raw;
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

  Object? _comparisonGroupMessage;
  ChatComparisonGroup? _comparisonGroupCache;

  /// The model slots this message's stored alternatives form, or null when the
  /// message has no alternatives. A group of one slot is a plain regeneration
  /// history and keeps the ordinary version pager.
  ChatComparisonGroup? get _comparisonGroup {
    if (widget.message.versions.isEmpty) return null;
    if (!identical(_comparisonGroupMessage, widget.message)) {
      _comparisonGroupMessage = widget.message;
      _comparisonGroupCache = ChatComparisonGroup.fromMessage(
        widget.message as ChatMessage,
      );
    }
    return _comparisonGroupCache;
  }

  /// Whether this is an answer of a comparison that is still being written and
  /// whose server task is known: the only state a per-answer stop can act on.
  /// Before the task is bound only the whole-turn stop applies.
  bool get _isStoppableComparisonAnswer {
    if (widget.readOnly || _activeVersionIndex >= 0) return false;
    if (!ref.watch(comparisonAnswerStopPermittedProvider)) return false;
    final message = widget.message as ChatMessage;
    if (!message.isStreaming) return false;
    final metadata = message.metadata;
    return metadata?[kMessageModelIdxMetadataKey] is int &&
        (metadata?['taskId']?.toString().isNotEmpty ?? false);
  }

  String get _activeAnswerId =>
      _activeVersionIndex >= 0 &&
          _activeVersionIndex < widget.message.versions.length
      ? widget.message.versions[_activeVersionIndex].id
      : widget.message.id;

  /// The answers the pager steps through, as indexes into `versions` with -1
  /// for the displayed message, oldest first. In a comparison that is the
  /// shown slot's own runs only: the other slots are reached by their tabs.
  List<int> _pagerIndices() {
    final group = _comparisonGroup;
    if (group == null) return const <int>[];
    if (group.isComparison) {
      final activeId = _activeAnswerId;
      final slot = group.slots.firstWhere(
        (candidate) => candidate.answers.any((a) => a.messageId == activeId),
      );
      return [for (final answer in slot.answers) answer.versionIndex ?? -1];
    }
    return [for (var i = 0; i < widget.message.versions.length; i += 1) i, -1];
  }

  ChatMergedResponse? get _activeMergedResponse =>
      _activeVersionIndex >= 0 &&
          _activeVersionIndex < widget.message.versions.length
      ? ChatMergedResponse.tryFrom(
          widget.message.versions[_activeVersionIndex].merged,
        )
      : (widget.message as ChatMessage).mergedResponse;

  void _setActiveVersionIndex(int nextIndex) {
    final raw = _resolvedMessageContent(null, nextIndex);
    setState(() {
      _activeVersionIndex = nextIndex;
      _displayedContent = raw;
    });
    _displayedContentListenable.value = raw;
    _resetTtsPlainTextState();
    _buildCachedAvatar();
  }

  /// The answer being shown, when it is one of this comparison's.
  ChatComparisonAnswer? _shownAnswer(ChatComparisonGroup group) {
    final activeId = _activeAnswerId;
    return [for (final slot in group.slots) ...slot.answers]
        .where((a) => a.messageId == activeId)
        .firstOrNull;
  }

  /// The finished answers of this turn a merge may read, one per slot in slot
  /// order: the shown answer for its own slot, otherwise the slot's current
  /// one. An answer still being written, failed, or without text is left out,
  /// so one unfinished slot never blocks merging the others.
  List<ChatComparisonAnswer> _mergeableAnswers(ChatComparisonGroup group) {
    final shown = _shownAnswer(group);
    return [
      for (final slot in group.slots)
        if (_isMergeable(
          shown != null && slot.index == shown.slot ? shown : slot.current,
        ))
          shown != null && slot.index == shown.slot ? shown : slot.current,
    ];
  }

  static bool _isMergeable(ChatComparisonAnswer answer) =>
      !answer.isStreaming &&
      answer.error == null &&
      answer.sourceText.trim().isNotEmpty;

  /// Merges answers of this comparison into one response, saved on the answer
  /// being shown. With two finished answers that is all there is to choose;
  /// with more, the user picks at least two. Only the chosen answers' own
  /// texts are sent, and every original stays as it is.
  Future<void> _mergeResponses(ChatComparisonGroup group) async {
    final parentId = group.parentId;
    final target = _shownAnswer(group);
    if (parentId == null || target == null) return;
    var chosen = _mergeableAnswers(group);
    if (chosen.length > 2) {
      final picked = await showMergeSourcesSheet(
        context,
        group: group,
        candidates: chosen,
      );
      if (picked == null || !mounted) return;
      chosen = picked;
    }
    if (chosen.length < 2) return;
    final l10n = AppLocalizations.of(context)!;
    try {
      await ref
          .read(comparisonMergeProvider.notifier)
          .merge(
            targetMessageId: target.messageId,
            displayedMessageId: widget.message.id as String,
            parentMessageId: parentId,
            model: target.model ?? (widget.message.model as String?) ?? '',
            responses: [for (final answer in chosen) answer.sourceText],
          );
    } on ComparisonMergeException catch (error) {
      if (!mounted) return;
      AdaptiveSnackBar.show(
        context,
        message: switch (error.reason) {
          ComparisonMergeFailure.unavailable => l10n.chatMergeErrorUnavailable,
          ComparisonMergeFailure.notMergeable =>
            l10n.chatMergeErrorNotMergeable,
          ComparisonMergeFailure.ownerChanged =>
            l10n.chatMergeErrorOwnerChanged,
          ComparisonMergeFailure.busy => l10n.chatMergeErrorNotMergeable,
          ComparisonMergeFailure.failed => l10n.chatMergeErrorFailed,
        },
        type: AdaptiveSnackBarType.error,
      );
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
    if (widget.message.metadata?['responseDone'] == true ||
        _turnPhase == ChatTurnPhase.failed) {
      _hasStreamedThisMessage = true;
      _actionRowSettled = true;
      return;
    }
    if (!_hasStreamedThisMessage) {
      // History message: action row shows immediately, no settle needed.
      return;
    }
  }

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

    // A grouped response is one answer, so read it whole rather than stopping
    // at this row's share of it.
    final rawText =
        widget.resolveGroupedResponseText?.call() ?? _displayedContent;
    final speechText = await _buildTtsPlainTextOnDemand(rawText);
    if (!mounted || speechText.trim().isEmpty) {
      return;
    }
    await controller.toggleForMessage(messageId: messageId, text: speechText);
  }

  Widget _buildMessageContent(
    String displayedContent, {
    required AssistantResponseBuilder? responseBuilder,
    required List<ChatSourceReference> activeSources,
  }) {
    final children = <Widget>[];
    final trimmedContent = displayedContent.trim();
    if (trimmedContent.isNotEmpty) {
      final markdownWidget = _buildEnhancedMarkdownContent(
        displayedContent,
        responseBuilder: responseBuilder,
        activeSources: activeSources,
      );
      children.add(RepaintBoundary(child: markdownWidget));
    }

    if (children.isEmpty) return const SizedBox.shrink();
    // Keep playback progress local to the content subtree too. Watching this
    // provider from the assistant shell would make every word-progress event
    // rebuild attachments, status rows, tools, sources, and footer actions.
    children.add(
      Consumer(
        builder: (context, childRef, _) {
          final ttsState = childRef.watch(textToSpeechControllerProvider);
          final isActive =
              ttsState.activeMessageId == _messageId &&
              (ttsState.status == TtsPlaybackStatus.speaking ||
                  ttsState.status == TtsPlaybackStatus.paused ||
                  ttsState.status == TtsPlaybackStatus.loading);
          if (!isActive || ttsState.activeSentenceIndex < 0) {
            return const SizedBox.shrink();
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: Spacing.sm),
              _buildKaraokeBar(ttsState),
            ],
          );
        },
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _buildStreamingContentBody({
    required AssistantResponseBuilder? responseBuilder,
    required List<ChatSourceReference> activeSources,
  }) {
    return ValueListenableBuilder<String>(
      valueListenable: _displayedContentListenable,
      builder: (context, displayedContent, _) {
        widget.debugOnStreamingContentBuild?.call();
        final body = _buildMessageContent(
          displayedContent,
          responseBuilder: responseBuilder,
          activeSources: activeSources,
        );
        // Always wrap in a FadeTransition with a stable key/type so the widget
        // at this slot survives the streaming/completed boundary.
        final fade = _canFadeStreamingContent(displayedContent)
            ? _streamingContentFade
            : const AlwaysStoppedAnimation<double>(1.0);
        return FadeTransition(
          key: const ValueKey('assistant-streaming-content-fade'),
          opacity: fade,
          child: body,
        );
      },
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
        Theme.of(context).textTheme.bodyMedium
            ?.copyWith(color: theme.textPrimary) ??
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

    final visibleStatuses = widget.message.statusHistory
        .where((status) => status.hidden != true)
        .toList();
    final hasPendingStatus = visibleStatuses.any(
      (status) => status.done != true,
    );
    if (hasPendingStatus) {
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
    return true;
  }

  void _buildCachedAvatar() {
    final theme = context.conduitTheme;
    final modelName = _resolveActiveModelName();
    final iconUrl = _resolveActiveModelIconUrl();
    // Grouped continuation: the response above already named this model. A
    // selected historical version can carry a DIFFERENT model, though, and
    // that identity was never shown above — so only stay silent while the
    // active identity still matches the one the group header announced.
    final isVoiceReply = _isVoiceReply;
    if (!widget.showModelHeader &&
        !isVoiceReply &&
        modelName == widget.modelName?.trim() &&
        iconUrl == widget.modelIconUrl) {
      _cachedAvatar = null;
      _cachedAvatarModelName = modelName;
      _cachedAvatarIconUrl = iconUrl;
      _cachedAvatarVoiceReply = isVoiceReply;
      return;
    }
    if (_cachedAvatar != null &&
        _cachedAvatarModelName == modelName &&
        _cachedAvatarIconUrl == iconUrl &&
        _cachedAvatarVoiceReply == isVoiceReply) {
      return;
    }
    final hasIcon = iconUrl != null && iconUrl.isNotEmpty;

    // A quiet speaker label, like a group-chat sender name: it names a model
    // change without competing with the answer below it.
    final Widget leading = hasIcon && !isVoiceReply
        ? ModelAvatar(size: 16, imageUrl: iconUrl, label: modelName)
        : Icon(
            isVoiceReply
                ? (Platform.isIOS ? CupertinoIcons.waveform : Icons.graphic_eq)
                : Icons.auto_awesome,
            color: theme.textTertiary,
            size: IconSize.sm - 2,
          );

    _cachedAvatar = Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: Row(
        children: [
          leading,
          const SizedBox(width: Spacing.xs + Spacing.xxs),
          Flexible(
            child: MiddleEllipsisText(
              isVoiceReply
                  ? AppLocalizations.of(
                      context,
                    )!.voiceReplySpokenLabel(modelName)
                  : modelName,
              style: AppTypography.bodySmallStyle.copyWith(
                color: theme.textTertiary,
                fontWeight: FontWeight.w400,
                letterSpacing: AppTypography.letterSpacingNormal,
              ),
            ),
          ),
        ],
      ),
    );
    _cachedAvatarModelName = modelName;
    _cachedAvatarIconUrl = iconUrl;
    _cachedAvatarVoiceReply = isVoiceReply;
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

    // The streamed value is replayed immediately when a virtualized row
    // remounts. Keep this guard outside widget State so that replay cannot
    // synthesize another 0→N "first chunk" and replay the pulse.
    if (previousLength == 0 &&
        _hapticMemory.markFired(
          widget.message.id,
          StreamingHapticEvent.contentArrival,
        )) {
      // One acknowledgement is enough; the previous three pulses at
      // 0/150/300ms felt like an unintended rapid vibration after every send.
      _streamingHaptic(HapticType.medium);
    }
  }

  /// Fires a single haptic impulse if streaming haptics are enabled.
  void _streamingHaptic(HapticType type) {
    if (_streamingHapticsAllowed) ConduitHaptics.trigger(type);
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
    _resetTtsPlainTextState();
    _fadeController.dispose();
    _streamingContentFade.dispose();
    _streamingContentFadeController.dispose();
    _displayedContentListenable.dispose();
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
    widget.debugOnShellBuild?.call();
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
    final showQueuedAsEmptyState =
        queuedCompletion != null &&
        _isAssistantResponseEmpty &&
        !queuedCompletion.isFailed;
    final suppressEmptyQueuedContent =
        queuedCompletion != null && _isAssistantResponseEmpty;
    final showQueuedRecoveryBanner =
        queuedCompletion != null && !showQueuedAsEmptyState;
    final shouldBuildActionFooter = _showActionRowNow && !hasQueuedCompletion;
    final contentSources = _resolveActiveSources();
    final responseBuilder = ref.watch(assistantResponseBuilderProvider);
    final activeFollowUps = shouldBuildActionFooter
        ? _resolveVisibleFollowUps()
        : const <String>[];
    final hasFollowUps =
        shouldBuildActionFooter &&
        widget.showFollowUps &&
        activeFollowUps.isNotEmpty &&
        _responseCompleted;
    final activeSources = shouldBuildActionFooter
        ? contentSources
        : const <ChatSourceReference>[];
    final footer = shouldBuildActionFooter
        ? _buildFooterBar(
            activeSources: activeSources,
            includeActions: widget.showActionBar,
          )
        : null;

    final content = Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16, right: Spacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Cached AI Name and Avatar to prevent flashing
          _cachedAvatar ?? const SizedBox.shrink(),

          // Every saved answer of a multi-model turn stays reachable, whether
          // or not Advanced is on: only comparison setup depends on it.
          if (_comparisonGroup case final group? when group.isComparison) ...[
            ChatComparisonTabs(
              group: group,
              activeMessageId: _activeAnswerId,
              onSelected: (answer) =>
                  _setActiveVersionIndex(answer.versionIndex ?? -1),
            ),
            const SizedBox(height: Spacing.sm),
          ],

          // One answer of a running comparison can be stopped on its own, with
          // Advanced on or off: the siblings keep going.
          if (_isStoppableComparisonAnswer) ...[
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: ChatComparisonAnswerStopButton(
                onStop: _stopComparisonAnswer,
              ),
            ),
            const SizedBox(height: Spacing.sm),
          ],

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
                  // Content streams in here. Empty content renders as
                  // SizedBox.shrink, and the footer indicator covers that
                  // waiting state until visible content arrives. Keep this
                  // subtree direct: a stable-key AnimatedSwitcher never
                  // switched and only obscured the one-shot content fade.
                  _buildStreamingContentBody(
                    responseBuilder: responseBuilder,
                    activeSources: contentSources,
                  ),

                if (showQueuedRecoveryBanner) ...[
                  const SizedBox(height: Spacing.sm),
                  _buildQueuedCompletionBanner(queuedCompletion),
                ],

                if (_activeMergedResponse case final merged?
                    when merged.content.trim().isNotEmpty) ...[
                  const SizedBox(height: Spacing.md),
                  ChatMergedResponsePanel(
                    child: _buildEnhancedMarkdownContent(
                      merged.content,
                      responseBuilder: null,
                      activeSources: const <ChatSourceReference>[],
                    ),
                  ),
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

          // Footer slot: keep completion actions inside the message while the
          // running turn indicator is owned by the timeline. The plain action
          // row is extent-matched to the timeline's typing indicator (16+32
          // vs 16+28+4) so the settle swap does not shift the
          // bottom-anchored viewport; see settle_height_test.dart.
          if (!hasQueuedCompletion)
            AnimatedSwitcher(
              // The running indicator is owned by the timeline footer now, so
              // this switch only swaps in the completed action row instantly.
              duration: Duration.zero,
              reverseDuration: Duration.zero,
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

  /// Builds the keyed child for the footer [AnimatedSwitcher]: the action row
  /// + follow-ups once completed, or an empty slot while streaming.
  Widget _buildFooterSlot({
    required Widget? footer,
    required bool hasFollowUps,
    required List<String> activeFollowUps,
  }) {
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
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: conduitTheme.textSecondary),
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
              ConduitButton(
                onPressed: () => _retryQueuedCompletion(info),
                text: l10n.retry,
                icon: Platform.isIOS ? CupertinoIcons.refresh : Icons.refresh,
                isCompact: true,
              ),
              ConduitButton(
                onPressed: () => _cancelQueuedCompletion(info),
                text: l10n.cancel,
                icon: Platform.isIOS ? CupertinoIcons.xmark : Icons.close,
                isCompact: true,
                isSecondary: true,
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

  /// Stops this answer's task. The answer keeps running when the server refuses,
  /// and the refusal is said once, on the screen that asked.
  Future<void> _stopComparisonAnswer() async {
    final outcome = await ref.read(stopComparisonAnswerProvider)(_messageId);
    if (outcome != ComparisonAnswerStop.refused || !mounted) return;
    AdaptiveSnackBar.show(
      context,
      message: AppLocalizations.of(context)!.chatStopResponseFailed,
      type: AdaptiveSnackBarType.error,
    );
  }

  void _handleQueuedCompletionActionError(Object error, StackTrace stackTrace) {
    DebugLogger.error(
      'queued-completion-action-failed',
      scope: 'chat/assistant',
      error: error,
      stackTrace: stackTrace,
    );
    if (!mounted) return;
    AdaptiveSnackBar.show(
      context,
      message: AppLocalizations.of(context)!.errorMessage,
      type: AdaptiveSnackBarType.error,
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

    // A model that can't call tools rejects web search's tool definitions;
    // say what to do instead of echoing the provider's wording.
    final displayText = isDirectToolsUnsupportedError(errorContent)
        ? AppLocalizations.of(context)!.directModelToolsUnsupported
        : (errorContent != null && errorContent.isNotEmpty)
        ? errorContent
        // If no content, show a generic error message
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

  void _handleMarkdownLinkTap(String url, String _) {
    launchExternalLink(url, scope: 'chat/assistant');
  }

  Widget _buildMarkdownImage(Uri uri, String? title, String? alt) {
    return RepaintBoundary(
      child: EnhancedImageAttachment(
        attachmentId: uri.toString(),
        isMarkdownFormat: true,
        constraints: const BoxConstraints(maxWidth: 500, maxHeight: 400),
        disableAnimation: _uiTreatsAsStreaming,
      ),
    );
  }

  Widget _buildEnhancedMarkdownContent(
    String content, {
    required AssistantResponseBuilder? responseBuilder,
    required List<ChatSourceReference> activeSources,
  }) {
    if (content.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    // Keep the raw markdown intact so the shared renderer can parse
    // Open WebUI-style <details> blocks directly.
    final processedContent = _processContentForImages(content);
    final bodyTreatsAsStreaming = _uiTreatsAsStreaming;

    Widget buildDefault(BuildContext context) {
      return StreamingMarkdownWidget(
        content: processedContent,
        isStreaming: bodyTreatsAsStreaming,
        // Tokens should appear on the frame they arrive. The surrounding body
        // already owns the single first-content reveal; re-fading every suffix
        // makes streaming trail the model.
        enableStreamingTextFade: false,
        askConduitComposerTargetId: chatComposerTextInsertionTargetId,
        stateScopeId: _markdownStateScopeId(),
        onTapLink: _markdownLinkTapCallback,
        sources: activeSources,
        imageBuilderOverride: _markdownImageBuilder,
      );
    }

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
    if (!widget.showFollowUps ||
        widget.readOnly ||
        _uiTreatsAsStreaming ||
        !_responseCompleted) {
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

    // Preserve stable attachments when another item arrives. Crossfading the
    // whole grid made already-loaded images disappear and re-enter.
    if (imageCount == 1) {
      return Container(
        key: ValueKey('single_item_${widget.message.attachmentIds![0]}'),
        child: EnhancedAttachment(
          attachmentId: widget.message.attachmentIds![0],
          isMarkdownFormat: true,
          constraints: const BoxConstraints(maxWidth: 500, maxHeight: 400),
          disableAnimation: _uiTreatsAsStreaming,
        ),
      );
    }

    return Wrap(
      key: const ValueKey('assistant-attachment-grid'),
      spacing: Spacing.sm,
      runSpacing: Spacing.sm,
      children: widget.message.attachmentIds!.map<Widget>((attachmentId) {
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
      widgets.add(
        ImageGalleryScope(
          items: _imageViewerItems(imageFiles),
          child: _buildImagesFromFiles(imageFiles),
        ),
      );
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

  /// Lets the full-screen viewer page through this message's images.
  List<ImageViewerItem> _imageViewerItems(List<dynamic> imageFiles) => [
    for (final file in imageFiles)
      if (getFileUrl(file) case final url?)
        ImageViewerItem(attachmentId: url, httpHeaders: _headersForFile(file)),
  ];

  Widget _buildImagesFromFiles(List<dynamic> imageFiles) {
    final imageCount = imageFiles.length;

    // Preserve stable image children instead of crossfading the full grid.
    if (imageCount == 1) {
      final imageUrl = getFileUrl(imageFiles.first);
      if (imageUrl == null) return const SizedBox.shrink();

      return Container(
        key: ValueKey('file_single_$imageUrl'),
        child: RepaintBoundary(
          child: EnhancedImageAttachment(
            attachmentId: imageUrl,
            isMarkdownFormat: true,
            constraints: const BoxConstraints(maxWidth: 500, maxHeight: 400),
            // Keep the opacity-only image reveal under Reduce Motion. It is
            // functional feedback and avoids a placeholder-to-image black
            // frame without introducing spatial movement.
            disableAnimation: false,
            httpHeaders: _headersForFile(imageFiles.first),
          ),
        ),
      );
    }

    return Wrap(
      key: const ValueKey('assistant-file-image-grid'),
      spacing: Spacing.sm,
      runSpacing: Spacing.sm,
      children: imageFiles.map<Widget>((file) {
        final imageUrl = getFileUrl(file);
        if (imageUrl == null) return const SizedBox.shrink();

        return RepaintBoundary(
          child: EnhancedImageAttachment(
            key: ValueKey('gen_attachment_$imageUrl'),
            attachmentId: imageUrl,
            isMarkdownFormat: true,
            constraints: BoxConstraints(
              maxWidth: imageCount == 2 ? 245 : 160,
              maxHeight: imageCount == 2 ? 245 : 160,
            ),
            disableAnimation: false,
            httpHeaders: _headersForFile(file),
          ),
        );
      }).toList(),
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

  Widget? _buildFooterBar({
    required List<ChatSourceReference> activeSources,
    required bool includeActions,
  }) {
    const maxInlineActions = 3;
    // A row that does not own its grouped response's bar still shows its own
    // sources and version chip; only the buttons collapse onto the last row.
    final actions = includeActions
        ? _buildFooterActions()
        : const <_AssistantFooterAction>[];
    final forcedOverflowActions = actions
        .where((action) => action.id == 'delete')
        .toList(growable: false);
    final inlineCandidateActions = actions
        .where((action) => action.id != 'delete')
        .toList(growable: false);
    final visibleActions = inlineCandidateActions
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
    ];
    final pagerIndices = _pagerIndices();
    final versionPager = pagerIndices.length > 1
        ? _buildVersionPager(pagerIndices)
        : null;
    // While an alternative is previewed (a regeneration through the pager, or
    // another model's response of a comparison through its tabs), continuing
    // from it is the point, so it leads the row as a labelled pill right after
    // the pager, and the usual buttons keep their places.
    final continueFromId = _continueFromVersionId();
    final pagerGroup = continueFromId == null
        ? versionPager
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (versionPager != null) ...[
                versionPager,
                const SizedBox(width: Spacing.xs),
              ],
              _buildContinueFromHerePill(continueFromId),
            ],
          );

    if (pagerGroup == null &&
        infoWidgets.isEmpty &&
        visibleActions.isEmpty &&
        overflowActions.isEmpty) {
      return null;
    }

    final overflowButton = overflowActions.isNotEmpty
        ? _buildOverflowActionButton(overflowActions)
        : null;
    // Like Open WebUI, the version pager leads the row; the icon buttons sit
    // edge to edge with the overflow trailing them inline, and informational
    // chips follow the buttons. With the continue pill the pager is a group of
    // its own, so a narrow row wraps between it and the buttons.
    final actionButtons = <Widget>[
      if (continueFromId == null) ?versionPager,
      for (final action in visibleActions)
        _buildActionButton(
          icon: action.icon,
          label: action.label,
          onTap: action.onTap,
        ),
      ?overflowButton,
    ];

    return Wrap(
      spacing: Spacing.sm,
      runSpacing: Spacing.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (continueFromId != null) pagerGroup!,
        if (actionButtons.isNotEmpty)
          Row(mainAxisSize: MainAxisSize.min, children: actionButtons),
        ...infoWidgets,
      ],
    );
  }

  /// The id of the alternative response being previewed, when the chat can
  /// continue from it: it must be a stored same-role sibling of this response,
  /// so a version without a reliable id stays preview-only.
  ///
  /// The providers read here are what make branch actions exclusive to the
  /// user's own durable chat, so no other gate is added. Siblings are read as
  /// soon as there is a version to preview, so the action is ready the moment
  /// one is shown.
  String? _continueFromVersionId() {
    final messageId = _messageId;
    final branchChatId = ref.watch(
      activeConversationProvider.select((c) => c?.id),
    );
    if (messageId.isEmpty ||
        branchChatId == null ||
        widget.message.versions.isEmpty) {
      return null;
    }
    final siblings = ref
        .watch(
          chatBranchSiblingsProvider((
            chatId: branchChatId,
            messageId: messageId,
          )),
        )
        .asData
        ?.value;
    if (_activeVersionIndex < 0 ||
        _activeVersionIndex >= widget.message.versions.length) {
      return null;
    }
    final previewedId =
        widget.message.versions[_activeVersionIndex].id as String?;
    return previewedId != null && (siblings?.contains(previewedId) ?? false)
        ? previewedId
        : null;
  }

  /// "Continue from here": the quiet active pill of the composer, compact to
  /// sit in the footer row, with the row's full height to tap.
  Widget _buildContinueFromHerePill(String alternativeId) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final label = l10n.chatBranchContinueFromResponse;
    void onTap() {
      ConduitHaptics.selectionClick();
      unawaited(
        continueFromChatBranch(
          context,
          displayedMessageId: _messageId,
          alternativeId: alternativeId,
        ),
      );
    }

    // The node stands in for the gesture detector below, whose own tap
    // action excludeSemantics drops, so it carries the tap itself.
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        key: const ValueKey<String>('assistant-continue-from-here'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: TouchTarget.chip),
          child: Center(
            widthFactor: 1,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.sm,
                vertical: Spacing.xs + 1,
              ),
              decoration: BoxDecoration(
                color: theme.buttonPrimary.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(AppBorderRadius.round),
                border: Border.all(
                  color: theme.buttonPrimary.withValues(alpha: 0.4),
                  width: BorderWidth.thin,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Platform.isIOS
                        ? CupertinoIcons.arrow_turn_down_right
                        : Icons.subdirectory_arrow_right,
                    size: IconSize.chip,
                    color: theme.buttonPrimary,
                  ),
                  const SizedBox(width: Spacing.xs),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.labelMediumStyle.copyWith(
                        color: theme.textPrimary,
                        fontWeight: FontWeight.w600,
                        letterSpacing: AppTypography.letterSpacingNormal,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // The error heuristics are four full-content scans; the footer rebuilds far
  // more often than the content changes, so memoize by string identity.
  String? _errorScanContent;
  bool _errorScanResult = false;

  bool get _displayedContentLooksLikeError {
    final content = _displayedContent;
    if (!identical(_errorScanContent, content)) {
      _errorScanContent = content;
      _errorScanResult =
          content.contains('⚠️') ||
          content.contains('Error') ||
          content.contains('timeout') ||
          content.contains('retry options');
    }
    return _errorScanResult;
  }

  List<_AssistantFooterAction> _buildFooterActions() {
    final l10n = AppLocalizations.of(context)!;
    // Watch only the playback fields the footer renders so Listen/Stop stays
    // current without rebuilding on every spoken word (#709).
    final ttsState = ref.watch(
      textToSpeechControllerProvider.select(
        (state) => (
          activeMessageId: state.activeMessageId,
          status: state.status,
          initialized: state.initialized,
          available: state.available,
        ),
      ),
    );
    final isChatStreaming = ref.read(isChatStreamingProvider);
    final activeUsage = _resolveActiveUsage();
    final messageId = _messageId;
    final activeError = _getActiveError();
    final hasErrorField = activeError != null;
    final isErrorMessage = hasErrorField || _displayedContentLooksLikeError;

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

    // Branch actions need a real message id. The providers below are what make
    // them exclusive to the user's own durable chat, so the widget adds no
    // gate of its own. A version being previewed is continued from by the pill
    // beside the pager, and can be branched into a new chat only when its id
    // is a stored same-role alternative of this response: a version without a
    // reliable id is not a message to branch at.
    final branchChatId = ref.watch(
      activeConversationProvider.select((c) => c?.id),
    );
    final branchControls = messageId.isNotEmpty && branchChatId != null;
    final previewingVersion = _activeVersionIndex >= 0;
    final continueFromId = _continueFromVersionId();
    final bool canFork =
        branchControls &&
        (!previewingVersion || continueFromId != null) &&
        ref.watch(chatForkAvailabilityProvider) != ChatForkAvailability.hidden;

    VoidCallback? ttsOnTap;
    if (showStopState || canStartTts) {
      ttsOnTap = () {
        if (messageId.isEmpty) {
          return;
        }
        unawaited(_handleTtsToggle(messageId));
      };
    }

    // "Merge responses" is an Advanced addition: it needs two or more finished
    // answers with text, and no other merge running. A merge already saved on an
    // answer is shown whatever Advanced is; only starting one depends on it.
    final comparisonGroup = _comparisonGroup;
    final mergeIsRunningHere =
        comparisonGroup != null &&
        ref.watch(comparisonMergeProvider) == _activeAnswerId;
    // The merge lands on the shown answer, so that one must be finished; a
    // sibling that failed or is still responding is simply not a source.
    final shownAnswer = comparisonGroup == null
        ? null
        : _shownAnswer(comparisonGroup);
    final canMerge =
        !widget.readOnly &&
        comparisonGroup != null &&
        comparisonGroup.isComparison &&
        ref.watch(comparisonMergeCommandAvailableProvider) &&
        shownAnswer != null &&
        _isMergeable(shownAnswer) &&
        _mergeableAnswers(comparisonGroup).length >= 2;

    final IconData listenIcon = Platform.isIOS
        ? CupertinoIcons.speaker_2
        : Icons.volume_up_outlined;
    final IconData stopIcon = Platform.isIOS
        ? CupertinoIcons.stop_fill
        : Icons.stop;

    final actions = <_AssistantFooterAction>[
      _AssistantFooterAction(
        id: 'copy',
        icon: Platform.isIOS
            ? CupertinoIcons.doc_on_doc
            : Icons.content_copy_outlined,
        label: l10n.copy,
        onTap: _responseCompleted ? widget.onCopy : null,
        sfSymbol: 'doc.on.doc',
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
              : 'speaker.wave.2',
        ),
      if (!widget.readOnly && !_isVoiceReply)
        _AssistantFooterAction(
          id: isErrorMessage ? 'retry' : 'regenerate',
          icon: Platform.isIOS ? CupertinoIcons.refresh : Icons.refresh,
          label: isErrorMessage ? l10n.retry : l10n.regenerate,
          onTap: canRegenerate ? widget.onRegenerate : null,
          sfSymbol: 'arrow.clockwise',
        ),
      if (mergeIsRunningHere)
        _AssistantFooterAction(
          id: 'stop-merge',
          icon: Platform.isIOS ? CupertinoIcons.stop_fill : Icons.stop,
          label: l10n.chatMergeStopAction,
          onTap: () =>
              unawaited(ref.read(comparisonMergeProvider.notifier).cancel()),
          sfSymbol: 'stop.fill',
        )
      else if (canMerge)
        _AssistantFooterAction(
          id: 'merge',
          icon: Platform.isIOS ? CupertinoIcons.arrow_merge : Icons.merge_type,
          label: l10n.chatMergeResponsesAction,
          onTap: () => unawaited(_mergeResponses(comparisonGroup)),
          sfSymbol: 'arrow.triangle.merge',
        ),
      if (activeUsage != null && activeUsage.isNotEmpty)
        _AssistantFooterAction(
          id: 'usage',
          icon: Platform.isIOS ? CupertinoIcons.info : Icons.info_outline,
          label: l10n.usageInfo,
          onTap: () => UsageStatsModal.show(context, activeUsage),
          sfSymbol: 'info.circle',
        ),
      if (canFork)
        _AssistantFooterAction(
          id: 'fork',
          icon: Platform.isIOS ? CupertinoIcons.arrow_branch : Icons.call_split,
          label: l10n.chatBranchForkChat,
          onTap: () => unawaited(
            forkChatFromMessage(
              context,
              messageId: continueFromId ?? messageId,
            ),
          ),
          sfSymbol: 'arrow.triangle.branch',
        ),
      if (!widget.readOnly)
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

  /// `‹ 2/3 ›`: steps through this response's regenerations in place.
  /// [indices] are the answers it covers, oldest first, as indexes into
  /// `versions` with -1 for the live response, which is last.
  Widget _buildVersionPager(List<int> indices) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final position = indices.indexOf(_activeVersionIndex);
    final current = position < 0 ? indices.length - 1 : position;

    return Row(
      key: const ValueKey<String>('assistant-version-pager'),
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildActionButton(
          icon: Platform.isIOS
              ? CupertinoIcons.chevron_left
              : Icons.chevron_left,
          label: l10n.previousLabel,
          onTap: current > 0
              ? () => _setActiveVersionIndex(indices[current - 1])
              : null,
        ),
        Text(
          '${current + 1}/${indices.length}',
          style: AppTypography.small.copyWith(
            color: theme.textPrimary.withValues(alpha: 0.8),
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        _buildActionButton(
          icon: Platform.isIOS
              ? CupertinoIcons.chevron_right
              : Icons.chevron_right,
          label: l10n.nextLabel,
          onTap: current < indices.length - 1
              ? () => _setActiveVersionIndex(indices[current + 1])
              : null,
        ),
      ],
    );
  }

  Widget _buildOverflowActionButton(
    List<_AssistantFooterAction> overflowActions,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;

    return AdaptiveTooltip(
      message: l10n.more,
      waitDuration: const Duration(milliseconds: 600),
      child: Semantics(
        button: true,
        label: l10n.more,
        child: AdaptivePopupMenuButton.icon<String>(
          key: const ValueKey<String>('assistant-response-overflow-button'),
          icon: PlatformUiCapabilities.isIOS
              ? 'ellipsis'
              : Icons.more_horiz_rounded,
          items: overflowActions
              .map(
                (action) => AdaptivePopupMenuItem<String>(
                  value: action.id,
                  label: action.label,
                  icon: PlatformUiCapabilities.isIOS
                      ? action.sfSymbol
                      : action.icon,
                  enabled: action.onTap != null,
                  isDestructive: action.id == 'delete',
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
          tint: theme.textPrimary.withValues(alpha: 0.8),
          size: 32,
          iconSize: IconSize.sm,
          buttonStyle: PopupButtonStyle.plain,
        ),
      ),
    );
  }

  Widget _buildFollowUpSuggestions(List<String> suggestions) {
    // A follow-up is a send; another user's chat offers none.
    final shouldShow =
        widget.showFollowUps && !widget.readOnly && suggestions.isNotEmpty;

    if (!shouldShow) {
      return const SizedBox.shrink(key: ValueKey('follow-ups-empty'));
    }

    return KeyedSubtree(
      key: ValueKey<String>(_followUpStateScopeId()),
      child: FollowUpSuggestionBar(
        suggestions: suggestions,
        onSelected: _handleFollowUpTap,
        isBusy: _uiTreatsAsStreaming,
      ),
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
