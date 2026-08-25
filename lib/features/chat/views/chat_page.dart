import 'package:material_ui/material_ui.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/l10n/app_localizations.dart';

import '../../../shared/theme/conduit_input_styles.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/platform_scroll_physics.dart';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:conduit/core/services/haptic_service.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dart:io' show Platform;
import 'dart:collection';
import 'dart:math' as math;

import '../../../shared/widgets/sidebar_layout_contract.dart';

import 'dart:async';

import '../../../core/providers/app_providers.dart';
import '../../../core/services/interaction_activity.dart';
import '../../../core/services/native_sheet_bridge.dart';
import '../../../core/services/native_sheet_hydration_service.dart';
import '../../../core/services/performance_profiler.dart';
import '../../../core/services/api_service.dart';
import '../../../core/services/connectivity_service.dart';
import '../../../core/services/settings_service.dart';
import '../../../core/database/database_provider.dart';
import '../../../core/database/app_database.dart';
import '../../../core/database/chat_database_repository.dart';
import '../../../core/database/models/chat_transcript_window.dart';
import '../../auth/providers/unified_auth_providers.dart';
import '../../direct_connections/providers/direct_connection_providers.dart';
import '../../direct_connections/services/direct_model_registry.dart';
import '../providers/chat_providers.dart';
import '../../hermes/models/hermes_model.dart';
import '../../hermes/models/hermes_bot.dart';
import '../../hermes/models/hermes_config.dart';
import '../../hermes/providers/hermes_providers.dart';
import '../../hermes/services/hermes_decision_projection.dart';
import '../../hermes/services/hermes_desktop_api_service.dart';
import '../../hermes/services/hermes_local_document_trust_store.dart';
import '../../hermes/services/hermes_message_mapper.dart';
import '../../hermes/services/hermes_pending_decision_store.dart';
import '../../hermes/services/hermes_session_provenance.dart';
import '../../hermes/widgets/hermes_bot_avatar.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../core/utils/message_tree_utils.dart' as message_tree;
import '../../../core/utils/user_display_name.dart';
import '../../../core/utils/model_icon_utils.dart';
import '../../../shared/widgets/markdown/markdown_compile_service.dart';
import '../../../shared/widgets/markdown/markdown_preprocessor.dart';
import '../../../core/utils/android_assistant_handler.dart';
import '../widgets/model_selector_sheet.dart';
import '../widgets/modern_chat_input.dart';
import '../widgets/user_message_bubble.dart';
import '../widgets/assistant_message_widget.dart' as assistant;
import '../widgets/file_attachment_widget.dart';
import '../widgets/context_attachment_widget.dart';
import '../widgets/server_file_picker_sheet.dart';
import '../services/clipboard_attachment_service.dart';
import '../services/file_attachment_service.dart';
import '../services/chat_transport_dispatch.dart';
import '../services/historical_message_regeneration.dart';
import '../voice_mode/chat_voice_mode_controller.dart';
import '../voice_mode/chat_voice_mode_overlay.dart';
import '../voice_call/presentation/voice_call_launcher.dart';
import '../../../core/services/media_upload_controller.dart';
import '../../tools/providers/tools_providers.dart';
import '../../release_notes/widgets/release_notes_banner.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/conversation.dart';
import '../../../core/models/folder.dart';
import '../../../core/models/model.dart';
import '../providers/context_attachments_provider.dart';
import '../../../shared/utils/adaptive_glass.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../shared/widgets/themed_sheets.dart';
import '../../../shared/widgets/measure_size.dart';
import '../../../shared/widgets/server_version_warning_card.dart';
import '../../../shared/widgets/adaptive_toolbar_components.dart';
import '../../../shared/widgets/chrome_gradient_fade.dart';
import '../../../shared/widgets/markdown/markdown_loading_skeleton.dart';
import '../../../shared/utils/conversation_context_menu.dart';
import 'chat_bottom_anchor_controller.dart';
import 'chat_timeline_render_model.dart';
import 'chat_turn_render_state.dart';
import '../widgets/streaming_turn_footer.dart';
import '../widgets/chat_timeline_viewport.dart';

/// Keeps the assistant row's element ancestry identical while it moves from
/// the live-tail slot into stable history. This matters for generated images:
/// remounting them briefly replaces the decoded image with its loading extent,
/// which fights the follow-up prompt's scroll anchor.
@visibleForTesting
Widget debugBuildAssistantTimelineSlotForTesting({
  required Widget assistantRow,
}) {
  return assistantRow;
}

Widget _buildArchivedAssistantPlaceholder({Key? key}) =>
    SizedBox.shrink(key: key);

@visibleForTesting
Widget debugBuildArchivedAssistantPlaceholderForTesting({Key? key}) =>
    _buildArchivedAssistantPlaceholder(key: key);

class _ChatToolbarActionDescriptor {
  const _ChatToolbarActionDescriptor({
    required this.widget,
    required this.nativeAction,
  });

  final Widget widget;
  final ConduitNativeToolbarAction nativeAction;
}

@visibleForTesting
Widget debugBuildChatEmptyStateViewportForTesting({
  required EdgeInsetsGeometry padding,
  required List<Widget> children,
}) => _ScrollableCenteredEmptyState(padding: padding, children: children);

class _ScrollableCenteredEmptyState extends StatelessWidget {
  const _ScrollableCenteredEmptyState({
    required this.padding,
    required this.children,
  });

  final EdgeInsetsGeometry padding;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final resolvedPadding = padding.resolve(Directionality.of(context));
        return SingleChildScrollView(
          key: const ValueKey('chat-empty-state-scroll-view'),
          padding: resolvedPadding,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: math.max(
                0,
                constraints.maxHeight - resolvedPadding.vertical,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: children,
            ),
          ),
        );
      },
    );
  }
}

// A 120 px streaming cache extent evicted rows almost immediately when
// scrolling up mid-stream; remounting a settled row runs a synchronous
// markdown compile, so the small extent bought hitches, not savings. Now that
// remounts resolve from the prepared/compiled/extent caches (O(1) for
// anything seen this session), a larger extent inflates rows further
// off-screen instead of inside the visible fling.
const double _chatMessageScrollCachePixels = 1200.0;

@visibleForTesting
bool shouldShowChatModelDropdown({
  required Model? selectedModel,
  required bool isHermesOnly,
  bool isHermesBot = false,
}) {
  return !isHermesBot &&
      (selectedModel == null || !isHermesModel(selectedModel) || !isHermesOnly);
}

@visibleForTesting
bool shouldShowTemporaryChatAction({
  required bool isHermes,
  required Conversation? activeConversation,
}) =>
    !isHermes &&
    (activeConversation == null || isTemporaryChat(activeConversation.id));

@visibleForTesting
String? chatHermesBotTitle(Conversation? conversation) {
  return chatHermesBotPresentation(conversation)?.title;
}

typedef HermesBotChatPresentation = ({
  String title,
  String? avatar,
  String shape,
  String color,
  String? imageKind,
});

@visibleForTesting
Widget debugBuildHermesBotToolbarTitleForTesting({
  required HermesBotChatPresentation bot,
  required double maxWidth,
  bool active = false,
}) => _HermesBotToolbarTitle(bot: bot, maxWidth: maxWidth, active: active);

@visibleForTesting
HermesBotChatPresentation? chatHermesBotPresentation(
  Conversation? conversation,
) {
  if (!isNativeHermesConversation(conversation)) return null;
  final title = conversation!.metadata[kHermesBotTitleMetadataKey];
  if (title is! String || title.trim().isEmpty) return null;
  final avatar = conversation.metadata[kHermesBotAvatarMetadataKey];
  final shape = conversation.metadata[kHermesBotShapeMetadataKey];
  final color = conversation.metadata[kHermesBotColorMetadataKey];
  final imageKind = conversation.metadata[kHermesBotImageKindMetadataKey];
  return (
    title: title.trim(),
    avatar: avatar is String && avatar.startsWith('data:image/')
        ? avatar
        : null,
    shape: shape is String ? shape : 'squircle',
    color: color is String ? color : '#8b5cf6',
    imageKind: imageKind is String ? imageKind : null,
  );
}

class _HermesBotToolbarTitle extends StatelessWidget {
  const _HermesBotToolbarTitle({
    required this.bot,
    required this.maxWidth,
    required this.active,
  });

  final HermesBotChatPresentation bot;
  final double maxWidth;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: bot.title,
      header: true,
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            HermesBotAvatar(
              key: const ValueKey('hermes-bot-toolbar-avatar'),
              size: 28,
              label: bot.title,
              imageUrl: bot.avatar,
              shape: bot.shape,
              color: bot.color,
              imageKind: bot.imageKind,
              active: active,
            ),
            const SizedBox(width: Spacing.sm),
            Flexible(
              child: Text(
                bot.title,
                key: const ValueKey('hermes-bot-toolbar-title'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: conduitAdaptiveToolbarLeadingTitleTextStyle(context)
                    .copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            if (active) ...[
              const SizedBox(width: Spacing.sm),
              const _HermesBotActivityDot(),
            ],
          ],
        ),
      ),
    );
  }
}

class _HermesBotActivityDot extends StatefulWidget {
  const _HermesBotActivityDot();

  @override
  State<_HermesBotActivityDot> createState() => _HermesBotActivityDotState();
}

class _HermesBotActivityDotState extends State<_HermesBotActivityDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AnimationDuration.slow,
  );
  late final Animation<double> _opacity = Tween<double>(begin: 1, end: 0.35)
      .animate(
        CurvedAnimation(parent: _controller, curve: AnimationCurves.easeInOut),
      );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (context.reduceMotion) {
      _controller
        ..stop()
        ..value = 0;
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: DecoratedBox(
        key: const ValueKey('hermes-bot-activity-dot'),
        decoration: BoxDecoration(
          color: context.conduitTheme.buttonPrimary,
          shape: BoxShape.circle,
        ),
        child: const SizedBox.square(dimension: 6),
      ),
    );
  }
}

@visibleForTesting
List<String>? chatLocalFilePickerExtensions(
  Model? selectedModel, {
  bool desktopHermes = false,
  bool hermesResponsesFiles = false,
}) => localFilePickerExtensionsForModel(
  selectedModel,
  desktopHermes: desktopHermes,
  hermesResponsesFiles: hermesResponsesFiles,
);

@visibleForTesting
Future<void> handleChatBackNavigation({
  required bool hasInputFocus,
  required VoidCallback dismissInputFocus,
  required bool Function() canNavigateBack,
  required VoidCallback navigateBack,
  required Future<bool> Function() confirmExit,
  required bool Function() isMounted,
  required bool isAndroid,
  required VoidCallback exitApplication,
}) async {
  if (hasInputFocus) {
    dismissInputFocus();
    return;
  }

  if (!isMounted()) return;
  if (canNavigateBack()) {
    navigateBack();
    return;
  }

  final shouldExit = await confirmExit();
  if (!shouldExit || !isMounted()) return;
  if (isAndroid) {
    exitApplication();
  }
}

/// Refreshes only an unchanged OpenWebUI-owned active conversation.
///
/// Native Hermes and direct-local shells can legally share a raw id with a
/// server row. They must never be replaced by a colliding OpenWebUI response.
@visibleForTesting
Future<void> refreshActiveOpenWebUiConversation(dynamic ref) async {
  final api = ref.read(apiServiceProvider) as ApiService?;
  final active = ref.read(activeConversationProvider) as Conversation?;
  if (api == null ||
      active == null ||
      !conversationUsesOpenWebUiStorage(active)) {
    return;
  }

  final full = await api.getConversation(active.id);
  final currentApi = ref.read(apiServiceProvider) as ApiService?;
  final current = ref.read(activeConversationProvider) as Conversation?;
  if (!identical(currentApi, api) ||
      !identical(current, active) ||
      current == null ||
      !conversationUsesOpenWebUiStorage(current) ||
      full.id != active.id) {
    return;
  }
  ref
      .read(activeConversationProvider.notifier)
      .set(withChatStorageProvenance(full, ChatStorageKind.openWebUi));
}

class _PinToTopState {
  const _PinToTopState._({
    required this.isActive,
    required this.isAutoFollowing,
    this.userMessageId,
    this.streamingMessageId,
  });

  const _PinToTopState.inactive()
    : this._(isActive: false, isAutoFollowing: false);

  const _PinToTopState.active({
    required String userMessageId,
    required String streamingMessageId,
  }) : this._(
         isActive: true,
         isAutoFollowing: true,
         userMessageId: userMessageId,
         streamingMessageId: streamingMessageId,
       );

  final bool isActive;
  final bool isAutoFollowing;
  final String? userMessageId;
  final String? streamingMessageId;

  _PinToTopState cancelAutomaticFollow() {
    if (!isActive || !isAutoFollowing) return this;
    return _PinToTopState._(
      isActive: true,
      isAutoFollowing: false,
      userMessageId: userMessageId,
      streamingMessageId: streamingMessageId,
    );
  }
}

enum _ChatTimelineScrollMode {
  anchoringNewTurn,
  followingLatest,
  freeScrolling,
}

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key});

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  static const double _scrollButtonShowThreshold = 48.0;
  static const double _scrollButtonHideThreshold = 12.0;
  static const int _pinScrollMaxAttempts = 12;
  static const double _scrollCorrectionEpsilon = 1.0;
  static const double _pinnedMeasurementEpsilon = 0.5;
  static const Duration _pinTransitionDuration = Duration(milliseconds: 220);

  final ChatTimelineViewportController _timelineViewportController =
      ChatTimelineViewportController();
  late final ChatBottomAnchorController _bottomAnchorController =
      ChatBottomAnchorController(
        showThreshold: _scrollButtonShowThreshold,
        hideThreshold: _scrollButtonHideThreshold,
      );
  bool _showScrollToBottom = false;
  bool _scrollToBottomVisibilitySyncScheduled = false;
  bool _scrollToBottomPrewarmPending = false;
  bool _hasUserScrolled = false;
  bool _isDeactivated = false;
  double _inputHeight = 0;
  bool _didStartupFocus = false; // one-time auto-focus on startup
  String? _lastConversationId;
  int _conversationOwnerGeneration = 0;
  int? _timelineHistoryIndexDesyncLogGeneration;
  int? _timelineTailMetadataDesyncLogGeneration;
  final LinkedHashMap<String, ChatScrollAnchor> _savedScrollAnchors =
      LinkedHashMap<String, ChatScrollAnchor>();
  final MarkdownPrewarmThrottle _markdownPrewarmThrottle =
      MarkdownPrewarmThrottle();
  String? _lastMarkdownPrewarmSignature;
  bool _hasPrewarmedAttachedViewport = false;
  Set<String> _lastVisibleMessageIds = const <String>{};
  double? _lastBottomInset;
  String? _activeScrollProfileTaskKey;
  // Pin-to-top: scroll user message to top of viewport when sending
  _PinToTopState _pinToTopState = const _PinToTopState.inactive();
  double _pinToTopEndSpaceExtent = 0;
  bool _pinGeometryReady = false;
  bool _pinShouldSettleImmediately = false;
  bool _pinToTopPositionSettled = false;
  bool _pinPrepositionAttempted = false;
  int? _pinLifecycleReconciliationGeneration;
  int _pinPositionGeneration = 0;
  _ChatTimelineScrollMode _timelineScrollMode =
      _ChatTimelineScrollMode.followingLatest;
  final _stableLayoutCache = _ChatListStableLayoutCache();
  // Identity-stable transcript window, render model, and rowBuilder. The shell
  // rebuilds far more often than the transcript changes (drag setState,
  // keyboard insets, pin transitions); keeping these identities stable lets
  // the viewport's sliver delegate skip rebuilding every mounted row, and lets
  // the stable-layout cache hit its identity fast path.
  List<ChatMessage>? _transcriptWindowSource;
  int _transcriptWindowCount = -1;
  List<ChatMessage> _transcriptWindowMemo = const <ChatMessage>[];
  List<ChatMessage>? _timelineModelSource;
  int _timelineModelGeneration = -1;
  ChatTimelineRenderModel? _timelineModelMemo;
  ChatTimelineRenderModel? _rowBuilderTimeline;
  _ChatListStableLayoutMetadata? _rowBuilderLayout;
  bool _rowBuilderSuppressHaptics = false;
  ChatTimelineRowBuilder? _rowBuilderMemo;
  List<Object?> _rowRebuildKeysMemo = const <Object?>[];
  String? _cachedGreetingName;
  bool _greetingReady = false;
  ProviderSubscription<String?>? _screenContextSub;
  ProviderSubscription<bool>? _conversationLoadingSub;
  ProviderSubscription<bool>? _reviewerModeSub;
  ProviderSubscription<String?>? _conversationIdSub;
  ProviderSubscription<Object>? _authEpochSub;
  ProviderSubscription<ApiService?>? _apiOwnerSub;
  ProviderSubscription<AppDatabase?>? _databaseOwnerSub;
  ProviderSubscription<AsyncValue<String>>? _hermesTranscriptSub;
  ProviderSubscription<bool>? _hermesStreamingSub;
  String? _pendingHermesTranscriptRefresh;
  int _hermesTranscriptRefreshGeneration = 0;
  bool _viewportOwnerChangeScheduled = false;
  bool? _lastProfiledMessageCacheStreamingState;
  bool _explicitLatestNavigationInFlight = false;
  int _explicitLatestNavigationGeneration = 0;
  ChatScrollAnchor? _initialScrollAnchor;
  final ChatMessageSendAdmissionGuard _messageSendAdmission =
      ChatMessageSendAdmissionGuard();
  bool _screenContextSubmissionScheduled = false;
  String? _screenContextInFlight;
  Timer? _screenContextRetryTimer;
  String? _screenContextRetryContext;
  int _screenContextRetryAttempts = 0;

  bool get _wantsPinToTop => _pinToTopState.isActive;
  bool get _shouldAutoFollowPinnedTurn =>
      _pinToTopState.isActive && _pinToTopState.isAutoFollowing;
  String? get _pinnedUserMessageId => _pinToTopState.userMessageId;

  bool get _isUserInteractingWithScroll =>
      _bottomAnchorController.isUserInteractingWithScroll;
  set _isUserInteractingWithScroll(bool value) {
    _bottomAnchorController.isUserInteractingWithScroll = value;
    _syncLayoutBottomAnchor();
  }

  bool get _isAnchoredToBottom => _bottomAnchorController.isAnchoredToBottom;
  set _isAnchoredToBottom(bool value) {
    _bottomAnchorController.isAnchoredToBottom = value;
    _syncLayoutBottomAnchor();
  }

  String _formatModelDisplayName(String name) {
    return _formatChatModelDisplayName(name);
  }

  void _invalidateChatListStableLayoutMetadata() {
    _stableLayoutCache.invalidate();
  }

  _ChatListStableLayoutMetadata _resolveChatListStableLayoutMetadata({
    required List<ChatMessage> messages,
    required List<Model>? models,
    required ApiService? apiService,
  }) {
    return _stableLayoutCache.resolve(
      messages: messages,
      models: models,
      apiService: apiService,
      directModelRegistry: ref.read(directModelRegistryProvider),
      hermesBot: chatHermesBotPresentation(
        ref.read(activeConversationProvider),
      ),
    );
  }

  void _syncLayoutBottomAnchor() {
    if (_shouldFollowStreamingGrowth) {
      _timelineViewportController.requestLayoutMaintenance();
    }
  }

  bool get _shouldFollowStreamingGrowth => debugShouldFollowStreamingForTesting(
    hasRunningTurn: _hasActiveStreamingAssistant(
      ref.read(chatMessagesProvider),
    ),
    isAnchoredToBottom: _isAnchoredToBottom,
    isUserInteracting: _isUserInteractingWithScroll,
    isExplicitNavigationInFlight: _explicitLatestNavigationInFlight,
    wantsPinToTop: _wantsPinToTop,
    followLatestRequested:
        _timelineScrollMode == _ChatTimelineScrollMode.followingLatest,
    pinnedEndSpaceExhausted:
        _pinToTopEndSpaceExtent <= _pinnedMeasurementEpsilon,
  );

  void _handleViewportMetricsChanged(ChatTimelineViewportMetrics metrics) {
    if (!mounted || _isDeactivated) return;
    if (_isUserInteractingWithScroll &&
        metrics.distanceFromLatest > _scrollButtonHideThreshold) {
      _bottomAnchorController.detachByUser();
    }
    final visibleMessageIds = metrics.visibleMessageIds.toSet();
    final shouldPrewarm =
        visibleMessageIds.isNotEmpty &&
        (!_hasPrewarmedAttachedViewport ||
            _visibleMessageIdsGained(
              previous: _lastVisibleMessageIds,
              current: visibleMessageIds,
            ));
    _lastVisibleMessageIds = visibleMessageIds;
    if (shouldPrewarm) _hasPrewarmedAttachedViewport = true;
    _scheduleScrollToBottomVisibilitySync(prewarm: shouldPrewarm);
  }

  void _maybeLoadOlderMessages() {
    final paging = ref.read(chatTranscriptPagingProvider);
    if (!debugShouldLoadOlderPageForTesting(
      hasUserScrolled: _hasUserScrolled,
      hasOlder: paging.hasOlder,
      isLoadingOlder: paging.isLoadingOlder,
      anyOldestLoadedRowVisible: _timelineViewportController
          .anyOldestLoadedRowVisible(),
    )) {
      return;
    }
    final completeMessages = ref.read(chatMessagesProvider);
    unawaited(
      ref
          .read(chatTranscriptPagingProvider.notifier)
          .fetchOlder(totalMessages: completeMessages.length),
    );
  }

  void _cancelExplicitLatestNavigation() {
    _explicitLatestNavigationGeneration += 1;
    _explicitLatestNavigationInFlight = false;
  }

  bool validateFileSize(int fileSize, int maxSizeMB) {
    return fileSize <= (maxSizeMB * 1024 * 1024);
  }

  void startNewChat() {
    resetHermesForNewChat(ref);
    clearSelectedFiltersForConversationBoundary(ref);

    _saveCurrentScrollAnchor();

    // Clear current conversation
    ref.read(chatMessagesProvider.notifier).clearMessages();
    ref.read(activeConversationProvider.notifier).clear();

    // Clear context attachments (web pages, YouTube, knowledge base docs)
    ref.read(contextAttachmentsProvider.notifier).clear();

    // Clear any pending folder selection
    ref.read(pendingFolderIdProvider.notifier).clear();

    // Reset to default model for new conversations (fixes #296)
    restoreDefaultModel(ref);

    if (_timelineViewportController.hasClients) {
      _timelineViewportController.jumpToLatest();
    }
    ref.read(chatTranscriptPagingProvider.notifier).reset(totalMessages: 0);
    _cancelPendingViewportNavigation();
    _clearPinToTopAnchor();
    _invalidateChatListStableLayoutMetadata();
    _isAnchoredToBottom = true;

    // Reset temporary chat state based on user preference
    final settings = ref.read(appSettingsProvider);
    ref
        .read(temporaryChatEnabledProvider.notifier)
        .set(settings.temporaryChatByDefault);
  }

  bool _isSavingTemporary = false;

  /// Persists a temporary chat to the server, transitioning it
  /// into a permanent conversation.
  Future<void> _saveTemporaryChat() async {
    if (_isSavingTemporary) return;
    if (_messageSendAdmission.isHeld || ref.read(isChatStreamingProvider)) {
      return;
    }
    final sourceConversation = ref.read(activeConversationProvider);
    final sourceApi = ref.read(apiServiceProvider);
    if (sourceConversation == null || sourceApi == null) return;
    final sourceConversationId = conversationScopedId(sourceConversation);
    final sourceConversationGeneration = _conversationOwnerGeneration;
    final sourceAuthSessionEpoch = ref.read(openWebUiAuthSessionEpochProvider);
    setState(() {
      _isSavingTemporary = true;
    });
    try {
      final messages = (await readCompleteActiveChatHistory(ref)).messages;
      if (messages.isEmpty) return;
      if (!_ownsDeferredConversationMutation(
        api: sourceApi,
        authSessionEpoch: sourceAuthSessionEpoch,
        conversationId: sourceConversationId,
        conversationGeneration: sourceConversationGeneration,
      )) {
        return;
      }

      // Generate title from first user message
      final firstUserMsg = messages.firstWhere(
        (m) => m.role == 'user',
        orElse: () => messages.first,
      );
      final title = firstUserMsg.content.length > 50
          ? '${firstUserMsg.content.substring(0, 50)}...'
          : firstUserMsg.content.isEmpty
          ? 'New Chat'
          : firstUserMsg.content;

      final selectedModel = ref.read(selectedModelProvider);
      final serverConversation = await sourceApi.createConversation(
        title: title,
        messages: messages,
        model: selectedModel?.id ?? '',
        systemPrompt: sourceConversation.systemPrompt,
        folderId: sourceConversation.folderId,
      );
      if (!_ownsDeferredConversationMutation(
        api: sourceApi,
        authSessionEpoch: sourceAuthSessionEpoch,
        conversationId: sourceConversationId,
        conversationGeneration: sourceConversationGeneration,
      )) {
        return;
      }

      // Transition to permanent chat
      final updatedConversation = serverConversation.copyWith(
        messages: messages,
      );
      ref.read(activeConversationProvider.notifier).set(updatedConversation);
      ref
          .read(conversationsProvider.notifier)
          .upsertConversation(
            updatedConversation.copyWith(
              messages: const [],
              updatedAt: DateTime.now(),
            ),
            trustFolderConversation:
                updatedConversation.folderId != null &&
                updatedConversation.folderId!.isNotEmpty,
          );
      ref.read(temporaryChatEnabledProvider.notifier).set(false);
      refreshConversationsCache(ref);

      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context)!.chatSaved)),
        );
      }
    } catch (e, stackTrace) {
      if (mounted &&
          _ownsDeferredConversationMutation(
            api: sourceApi,
            authSessionEpoch: sourceAuthSessionEpoch,
            conversationId: sourceConversationId,
            conversationGeneration: sourceConversationGeneration,
          )) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context)!.chatSaveFailed)),
        );
      }
      DebugLogger.error(
        'temporary-chat-save-failed',
        scope: 'chat/page',
        error: e,
        stackTrace: stackTrace,
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSavingTemporary = false;
        });
        _scheduleScreenContextSubmission();
      } else {
        _isSavingTemporary = false;
      }
    }
  }

  bool _ownsDeferredConversationMutation({
    required ApiService api,
    required Object authSessionEpoch,
    required String conversationId,
    required int conversationGeneration,
  }) {
    if (!mounted) return false;
    final activeConversation = ref.read(activeConversationProvider);
    return debugShouldApplyDeferredConversationMutationForTesting(
          isMounted: true,
          scheduledConversationId: conversationId,
          activeConversationId: activeConversation == null
              ? null
              : conversationScopedId(activeConversation),
          scheduledGeneration: conversationGeneration,
          activeGeneration: _conversationOwnerGeneration,
        ) &&
        identical(ref.read(apiServiceProvider), api) &&
        identical(
          ref.read(openWebUiAuthSessionEpochProvider),
          authSessionEpoch,
        );
  }

  Future<void> _checkAndAutoSelectModel() async {
    // Check if a model is already selected
    final selectedModel = ref.read(selectedModelProvider);
    if (selectedModel != null) {
      DebugLogger.log(
        'selected',
        scope: 'chat/model',
        data: {'name': selectedModel.name},
      );
      return;
    }

    // Use shared restore logic which handles settings priority and fallbacks
    await restoreDefaultModel(ref);
  }

  Future<void> _checkAndLoadDemoConversation() async {
    if (!context.mounted) return;
    final isReviewerMode = ref.read(reviewerModeProvider);
    if (!isReviewerMode) return;

    // Check if there's already an active conversation
    if (!context.mounted) return;
    final activeConversation = ref.read(activeConversationProvider);
    if (activeConversation != null) {
      DebugLogger.log(
        'active',
        scope: 'chat/demo',
        data: {'title': activeConversation.title},
      );
      return;
    }

    // Force refresh conversations provider to ensure we get the demo conversations
    if (!mounted) return;
    refreshConversationsCache(ref);

    // Try to load demo conversation
    for (int i = 0; i < 10; i++) {
      if (!mounted) return;
      final conversationsAsync = ref.read(conversationsProvider);

      if (conversationsAsync.hasValue && conversationsAsync.value!.isNotEmpty) {
        // Find and load the welcome conversation
        final welcomeConv = conversationsAsync.value!.firstWhere(
          (conv) => conv.id == 'demo-conv-1',
          orElse: () => conversationsAsync.value!.first,
        );

        if (!mounted) return;
        ref.read(activeConversationProvider.notifier).set(welcomeConv);
        DebugLogger.log('Auto-loaded demo conversation', scope: 'chat/page');
        return;
      }

      // If conversations are still loading, wait a bit and retry
      if (conversationsAsync.isLoading || i == 0) {
        await Future.delayed(const Duration(milliseconds: 200));
        if (!mounted) return;
        continue;
      }

      // If there was an error or no conversations, break
      break;
    }

    DebugLogger.log(
      'Failed to auto-load demo conversation',
      scope: 'chat/page',
    );
  }

  @override
  void initState() {
    super.initState();

    _screenContextSub = ref.listenManual(screenContextProvider, (_, next) {
      if (next == null || next.isEmpty) {
        _resetScreenContextRetry();
        return;
      }
      if (next != _screenContextRetryContext) {
        _resetScreenContextRetry(context: next);
      }
      _scheduleScreenContextSubmission();
    });
    _conversationLoadingSub = ref.listenManual(isLoadingConversationProvider, (
      _,
      isLoading,
    ) {
      if (!isLoading) _scheduleScreenContextSubmission();
    });
    _reviewerModeSub = ref.listenManual(reviewerModeProvider, (_, next) {
      if (!next || ref.read(selectedModelProvider) != null) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _checkAndAutoSelectModel();
        }
      });
    });
    final conversationIdListenable = activeConversationProvider.select(
      (conversation) =>
          conversation == null ? null : conversationScopedId(conversation),
    );
    _conversationIdSub = ref.listenManual(
      conversationIdListenable,
      (_, next) => _handleConversationChanged(next),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _handleConversationChanged(ref.read(conversationIdListenable));
      }
    });
    _authEpochSub = ref.listenManual(openWebUiAuthSessionEpochProvider, (
      previous,
      next,
    ) {
      if (!identical(previous, next)) {
        _scheduleViewportOwnerChanged();
      }
    });
    _apiOwnerSub = ref.listenManual(apiServiceProvider, (previous, next) {
      if (!identical(previous, next)) {
        _scheduleViewportOwnerChanged();
      }
    });
    _databaseOwnerSub = ref.listenManual(appDatabaseProvider, (previous, next) {
      if (!identical(previous, next)) {
        _scheduleViewportOwnerChanged();
      }
    });
    _hermesTranscriptSub = ref.listenManual(
      hermesDesktopTranscriptChangesProvider,
      (_, next) => next.whenData(
        (storedId) => unawaited(_refreshDesktopHermesTranscript(storedId)),
      ),
    );
    _hermesStreamingSub = ref.listenManual(isChatStreamingProvider, (
      wasStreaming,
      isStreaming,
    ) {
      if (isStreaming || wasStreaming != true) return;
      final storedId = _pendingHermesTranscriptRefresh;
      _pendingHermesTranscriptRefresh = null;
      if (storedId != null) {
        unawaited(_refreshDesktopHermesTranscript(storedId));
      }
    });

    // Initialize chat page components
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;

      // Initialize Android Assistant Handler
      ref.read(androidAssistantProvider);

      // First, ensure a model is selected
      await _checkAndAutoSelectModel();
      if (!mounted) return;

      // Then check for demo conversation in reviewer mode
      await _checkAndLoadDemoConversation();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _handleBottomInsetChange(MediaQuery.viewInsetsOf(context).bottom);
  }

  @override
  void dispose() {
    markConversationRead(ref, _lastConversationId);
    _screenContextSub?.close();
    _conversationLoadingSub?.close();
    _reviewerModeSub?.close();
    _conversationIdSub?.close();
    _authEpochSub?.close();
    _apiOwnerSub?.close();
    _databaseOwnerSub?.close();
    _hermesTranscriptSub?.close();
    _hermesStreamingSub?.close();
    _hermesTranscriptRefreshGeneration++;
    _markdownPrewarmThrottle.cancel();
    _screenContextRetryTimer?.cancel();
    _cancelExplicitLatestNavigation();
    _cancelPendingViewportNavigation();
    _endScrollProfile(reason: 'disposed');
    // A drag interrupted by page disposal never delivers onUserDragEnd;
    // release the interaction hold so background work isn't deferred until
    // the maxDeferral timeout.
    if (_isUserInteractingWithScroll) {
      InteractionActivity.instance.endInteraction();
    }
    _timelineViewportController.dispose();
    super.dispose();
  }

  @override
  void deactivate() {
    _isDeactivated = true;
    _cancelExplicitLatestNavigation();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _isDeactivated = false;
    _timelineViewportController.requestLayoutMaintenance();
  }

  Future<void> _handleMessageSend(String text) async {
    await _sendMessage(text, includeComposerContext: true);
  }

  Future<void> _refreshDesktopHermesTranscript(String storedId) async {
    final active = ref.read(activeConversationProvider);
    if (active == null ||
        !isNativeHermesConversation(active) ||
        active.metadata['hermesSessionId'] != storedId) {
      return;
    }
    if (ref.read(isChatStreamingProvider)) {
      _pendingHermesTranscriptRefresh = storedId;
      return;
    }
    final service = ref.read(hermesApiServiceProvider);
    if (service is! HermesDesktopApiService) return;
    final generation = ++_hermesTranscriptRefreshGeneration;
    try {
      final raw = await service.getSessionMessages(storedId);
      List<HermesPendingDesktopDecision> pending;
      try {
        pending = await service.pendingDecisionsForSession(storedId);
      } catch (error) {
        DebugLogger.warning(
          'pending-decisions-refresh-failed',
          scope: 'hermes/transcript',
          data: {'errorType': error.runtimeType.toString()},
        );
        pending = const [];
      }
      if (!mounted ||
          generation != _hermesTranscriptRefreshGeneration ||
          !identical(ref.read(hermesApiServiceProvider), service) ||
          ref.read(activeConversationProvider)?.id != active.id) {
        return;
      }
      final selected = ref.read(selectedModelProvider);
      final model = selected != null && isHermesModel(selected)
          ? selected
          : hermesSyntheticModel();
      final endpoint = HermesConfigController.connectionEndpoint(
        service.config.baseUrl,
      );
      final principal = ref
          .read(hermesConfigProvider.notifier)
          .documentTrustPrincipalId();
      final connectionIdentity = endpoint == null
          ? null
          : HermesLocalDocumentTrustStore.connectionIdentity(
              endpointIdentity: endpoint,
              principalId: principal,
            );
      final trustedKeys = connectionIdentity == null
          ? const <String>{}
          : HermesLocalDocumentTrustStore.trustedDocumentKeys(
              connectionIdentity: connectionIdentity,
              sessionId: storedId,
            );
      final messages =
          hermesMessagesToChatMessages(
            raw,
            modelId: model.id,
            trustedLocalDocumentKeys: trustedKeys,
          )..addAll(
            hermesPendingDesktopDecisionMessages(pending, modelId: model.id),
          );
      final currentMessages = ref.read(chatMessagesProvider);
      final currentAuthoritativeCount = currentMessages
          .where(
            (message) => message.metadata?['restoredDesktopDecision'] != true,
          )
          .length;
      final candidateAuthoritativeCount = messages
          .where(
            (message) => message.metadata?['restoredDesktopDecision'] != true,
          )
          .length;
      if (currentAuthoritativeCount > 0 &&
          candidateAuthoritativeCount < currentAuthoritativeCount) {
        return;
      }
      ref.read(chatMessagesProvider.notifier).setMessages(messages);
      ref
          .read(activeConversationProvider.notifier)
          .set(
            inheritNativeHermesConversationProvenance(
              active,
              active.copyWith(messages: messages, updatedAt: DateTime.now()),
            ),
          );
    } catch (error) {
      DebugLogger.warning(
        'desktop-transcript-refresh-failed',
        scope: 'hermes/recovery',
        data: {'errorType': error.runtimeType.toString()},
      );
    }
  }

  Future<void> _handleFollowUpSend(String text) async {
    await _sendMessage(text, includeComposerContext: false);
  }

  void _scheduleScreenContextSubmission() {
    if (_screenContextSubmissionScheduled || _screenContextInFlight != null) {
      return;
    }
    _screenContextSubmissionScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _screenContextSubmissionScheduled = false;
      if (!mounted || _screenContextInFlight != null) return;
      final screenContext = ref.read(screenContextProvider);
      if (screenContext == null || screenContext.isEmpty) return;

      _screenContextInFlight = screenContext;
      final result = await _sendMessage(
        'Here is the content of my screen:\n\n$screenContext\n\n'
        'Can you summarize this?',
        includeComposerContext: true,
      );
      if (!mounted) return;

      final currentContext = ref.read(screenContextProvider);
      _screenContextInFlight = null;
      if (debugShouldConsumeScreenContextForTesting(
        sendDispatched: result.dispatched,
        submittedContext: screenContext,
        currentContext: currentContext,
      )) {
        _resetScreenContextRetry();
        ref.read(screenContextProvider.notifier).setContext(null);
        return;
      }
      if (debugShouldRetryScreenContextForTesting(
        sendDispatched: result.dispatched,
        submittedContext: screenContext,
        currentContext: currentContext,
        sendAdmissionHeld: _messageSendAdmission.isHeld,
        isSavingTemporary: _isSavingTemporary,
        isLoadingConversation: ref.read(isLoadingConversationProvider),
      )) {
        if (currentContext != screenContext) {
          if (currentContext != null && currentContext.isNotEmpty) {
            _scheduleScreenContextSubmission();
          }
        } else if (!result.dispatched) {
          _scheduleScreenContextRetry(screenContext);
        }
      }
    });
  }

  void _resetScreenContextRetry({String? context}) {
    _screenContextRetryTimer?.cancel();
    _screenContextRetryTimer = null;
    _screenContextRetryContext = context;
    _screenContextRetryAttempts = 0;
  }

  void _scheduleScreenContextRetry(String screenContext) {
    if (_screenContextRetryContext != screenContext) {
      _resetScreenContextRetry(context: screenContext);
    }
    if (_screenContextRetryTimer != null) return;
    final delay = debugScreenContextRetryDelayForTesting(
      completedRetries: _screenContextRetryAttempts,
    );
    if (delay == null) return;
    _screenContextRetryAttempts += 1;
    _screenContextRetryTimer = Timer(delay, () {
      _screenContextRetryTimer = null;
      if (!mounted || ref.read(screenContextProvider) != screenContext) return;
      _scheduleScreenContextSubmission();
    });
  }

  void _activatePinToTopAnchor(
    ChatSendPlaceholderHandle handle, {
    required bool settleImmediately,
  }) {
    final userMessageId = handle.userMessageId;
    if (!mounted || userMessageId == null) return;

    _cancelExplicitLatestNavigation();
    _cancelPendingViewportNavigation();
    _bottomAnchorController.requestBottomAnchor();
    final generation = ++_pinPositionGeneration;
    final topInset =
        MediaQuery.paddingOf(context).top +
        conduitAdaptiveToolbarHeightOf(context) +
        Spacing.md;
    _pinToTopEndSpaceExtent = math.max(
      0,
      MediaQuery.sizeOf(context).height - topInset,
    );
    _pinGeometryReady = false;
    _pinShouldSettleImmediately = settleImmediately;
    _pinToTopPositionSettled = false;
    _pinPrepositionAttempted = false;
    _pinLifecycleReconciliationGeneration = null;
    _timelineScrollMode = _ChatTimelineScrollMode.anchoringNewTurn;
    setState(() {
      _pinToTopState = _PinToTopState.active(
        userMessageId: userMessageId,
        streamingMessageId: handle.assistantMessageId,
      );
    });
    _syncLayoutBottomAnchor();
    _scrollToUserMessage(generation: generation);
  }

  void _cancelPinnedTurnAutomaticFollow() {
    _cancelExplicitLatestNavigation();
    final cancelPinPositioning = _shouldAutoFollowPinnedTurn;
    if (!cancelPinPositioning &&
        _timelineScrollMode == _ChatTimelineScrollMode.freeScrolling) {
      return;
    }
    setState(() {
      _timelineScrollMode = _ChatTimelineScrollMode.freeScrolling;
      if (cancelPinPositioning) {
        _pinPositionGeneration += 1;
        _pinToTopState = _pinToTopState.cancelAutomaticFollow();
        _pinShouldSettleImmediately = false;
      }
    });
    _syncLayoutBottomAnchor();
  }

  Future<({bool admitted, bool dispatched})> _sendMessage(
    String text, {
    required bool includeComposerContext,
  }) async {
    if (!debugCanSubmitChatMessageForTesting(
      isLoadingConversation: ref.read(isLoadingConversationProvider),
      isSavingTemporary: _isSavingTemporary,
      isPreparingMessageSend: _messageSendAdmission.isHeld,
    )) {
      return (admitted: false, dispatched: false);
    }
    final sendOwner = _messageSendAdmission.tryAcquire();
    if (sendOwner == null) return (admitted: false, dispatched: false);
    if (mounted) setState(() {});
    late final bool dispatched;
    try {
      dispatched = await _sendMessageAfterAdmission(
        text,
        includeComposerContext: includeComposerContext,
        sendOwner: sendOwner,
      );
    } finally {
      _releaseMessageSendAdmission(sendOwner);
    }
    return (admitted: true, dispatched: dispatched);
  }

  Future<bool> _sendMessageAfterAdmission(
    String text, {
    required bool includeComposerContext,
    required Object sendOwner,
  }) async {
    final settlePinImmediately = debugShouldSettlePinImmediatelyForTesting(
      transcriptWasEmpty: ref.read(chatMessagesProvider).isEmpty,
    );
    dynamic selectedModel = ref.read(selectedModelProvider);

    // Resolve model on-demand if none selected yet
    if (selectedModel == null) {
      try {
        // Prefer already-loaded models
        List<Model> models;
        final modelsAsync = ref.read(modelsProvider);
        if (modelsAsync.hasValue) {
          models = modelsAsync.value!;
        } else {
          models = await ref.read(modelsProvider.future);
        }
        if (models.isNotEmpty) {
          selectedModel = models.first;
          ref.read(selectedModelProvider.notifier).set(selectedModel);
        }
      } catch (_) {
        // If models cannot be resolved, bail out without sending
        return false;
      }
      if (selectedModel == null) return false;
    }

    ChatSendPlaceholderHandle? pendingSend;
    var didDispatch = false;
    try {
      // Get attached files and collect uploaded file IDs (including data URLs for images)
      final attachedFiles = includeComposerContext
          ? ref.read(attachedFilesProvider)
          : const <FileUploadState>[];
      final mediaUploadController = ref.read(mediaUploadControllerProvider);
      final sentAttachmentOwnership = mediaUploadController
          .captureAttachmentOwnership();
      final uploadedFileIds = attachedFiles
          .where(
            (file) =>
                file.status == FileUploadStatus.completed &&
                file.fileId != null,
          )
          .map((file) => file.fileId!)
          .toList();

      // Get selected tools
      final toolIds = includeComposerContext
          ? ref.read(selectedToolIdsProvider)
          : const <String>[];
      final wasOffline = !ref.read(isOnlineProvider);
      final hasDurableOutbox =
          ref.read(appDatabaseProvider) != null &&
          !ref.read(reviewerModeProvider) &&
          !ref.read(temporaryChatEnabledProvider) &&
          !isTemporaryChat(ref.read(activeConversationProvider)?.id);

      // Durable send: persists rows + outbox op in one tx (survives a
      // force-quit) and drives streaming via the requestCompletion op.
      await durableSend(
        ref,
        text,
        uploadedFileIds.isNotEmpty ? uploadedFileIds : null,
        toolIds: toolIds.isNotEmpty ? toolIds : null,
        onAssistantPlaceholderCreated: (handle) {
          didDispatch = true;
          _releaseMessageSendAdmission(sendOwner);
          pendingSend = handle;
          _activatePinToTopAnchor(
            handle,
            settleImmediately: settlePinImmediately,
          );
        },
      );
      didDispatch = true;

      // Clear only after durableSend has transferred every attachment needed
      // by the message/outbox. Retire only the exact identities/generations
      // captured for this send: a paste or picker result published while the
      // durable transaction awaited still belongs to the next composer turn.
      if (includeComposerContext) {
        unawaited(
          mediaUploadController
              .retireAttachmentOwnership(sentAttachmentOwnership)
              .catchError((Object error, StackTrace stackTrace) {
                DebugLogger.error(
                  'sent-attachment-cleanup-failed',
                  scope: 'chat/attachment',
                  error: error,
                  stackTrace: stackTrace,
                );
              }),
        );
      }

      if (wasOffline && hasDurableOutbox && mounted) {
        AdaptiveSnackBar.show(
          context,
          message: AppLocalizations.of(context)!.chatQueuedSnackBar,
          type: AdaptiveSnackBarType.info,
          duration: const Duration(seconds: 3),
        );
      }
    } catch (e, stackTrace) {
      // durableSend persists rows + drains synchronously; on failure (DB error,
      // lock failure, …) recover the UI by finishing the streaming placeholder
      // so it does not hang in `isStreaming: true` forever.
      DebugLogger.error(
        'durable-send-failed',
        scope: 'chat/page',
        error: e,
        stackTrace: stackTrace,
      );
      recoverFailedChatSend(ref, e, pendingSend);
    }
    return didDispatch;
  }

  void _releaseMessageSendAdmission(Object sendOwner) {
    if (!_messageSendAdmission.release(sendOwner)) return;
    if (mounted) setState(() {});
    _scheduleScreenContextSubmission();
  }

  // Inline voice input now handled directly inside ModernChatInput.

  void _handleFileAttachment() async {
    // Check if selected model supports file upload
    final fileUploadCapableModels = ref.read(fileUploadCapableModelsProvider);
    if (fileUploadCapableModels.isEmpty) {
      if (!mounted) return;
      return;
    }

    final fileService = ref.read(fileAttachmentServiceProvider);
    if (fileService == null) {
      return;
    }

    try {
      final attachments = await fileService.pickFiles(
        allowedExtensions: chatLocalFilePickerExtensions(
          ref.read(selectedModelProvider),
          desktopHermes:
              ref.read(hermesConfigProvider).mode ==
              HermesBackendMode.desktopGateway,
          hermesResponsesFiles:
              ref.read(hermesCapabilitiesProvider).asData?.value.inputFiles ==
              true,
        ),
      );
      if (attachments.isEmpty) return;

      // Keep the 20 MB guardrail for images; non-image uploads can be larger.
      for (final attachment in attachments) {
        final fileSize = await attachment.file.length();
        if (attachment.isImage && !validateFileSize(fileSize, 20)) {
          if (!mounted) return;
          return;
        }
      }

      // Add files to the attachment list
      ref.read(attachedFilesProvider.notifier).addFiles(attachments);

      // Drive uploads via the shared media-upload controller (fold-out, not an
      // outbox op) for unified retry/progress.
      for (final attachment in attachments) {
        unawaited(
          ref
              .read(mediaUploadControllerProvider)
              .upload(
                filePath: attachment.file.path,
                fileName: attachment.displayName,
                fileSize: await attachment.file.length(),
              )
              .catchError((Object e) {
                DebugLogger.log('Upload failed: $e', scope: 'chat/page');
              }),
        );
      }
    } catch (e) {
      if (!mounted) return;
      DebugLogger.log('File selection failed: $e', scope: 'chat/page');
    }
  }

  void _handleServerFileAttachment() {
    final fileUploadCapableModels = ref.read(fileUploadCapableModelsProvider);
    if (fileUploadCapableModels.isEmpty || !mounted) {
      return;
    }

    if (Platform.isIOS) {
      unawaited(() async {
        final files = await ref.read(userFilesProvider.future);
        if (!mounted || files.isEmpty) {
          return;
        }
        try {
          final selectedId = await NativeSheetBridge.instance
              .presentOptionsSelector(
                title: AppLocalizations.of(context)!.files,
                options: [
                  for (final file in files)
                    NativeSheetOptionConfig(
                      id: file.id,
                      label: file.displayName,
                      subtitle: file.filename,
                      sfSymbol: 'doc',
                    ),
                ],
                rethrowErrors: true,
              );
          if (selectedId == null || !mounted) {
            return;
          }
          for (final file in files) {
            if (file.id == selectedId) {
              ref.read(attachedFilesProvider.notifier).addRemoteFile(file);
              break;
            }
          }
          return;
        } catch (_) {
          if (!mounted) {
            return;
          }
        }
        ThemedSheets.showCustom<void>(
          context: context,
          isScrollControlled: true,
          builder: (_) => ServerFilePickerSheet(
            onSelected: (file) {
              ref.read(attachedFilesProvider.notifier).addRemoteFile(file);
            },
          ),
        );
      }());
      return;
    }

    ThemedSheets.showCustom<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ServerFilePickerSheet(
        onSelected: (file) {
          ref.read(attachedFilesProvider.notifier).addRemoteFile(file);
        },
      ),
    );
  }

  void _handleImageAttachment({bool fromCamera = false}) async {
    DebugLogger.log(
      'Starting image attachment process - fromCamera: $fromCamera',
      scope: 'chat/page',
    );

    // Check if selected model supports vision
    final visionCapableModels = ref.read(visionCapableModelsProvider);
    if (visionCapableModels.isEmpty) {
      if (!mounted) return;
      return;
    }

    final fileService = ref.read(fileAttachmentServiceProvider);
    if (fileService == null) {
      DebugLogger.log(
        'File service is null - cannot proceed',
        scope: 'chat/page',
      );
      return;
    }

    try {
      DebugLogger.log('Picking image...', scope: 'chat/page');
      final List<LocalAttachment> attachments;
      if (fromCamera) {
        final attachment = await fileService.takePhoto() as LocalAttachment?;
        if (attachment == null) {
          DebugLogger.log('No image selected', scope: 'chat/page');
          return;
        }
        attachments = [attachment];
      } else {
        attachments = List<LocalAttachment>.from(
          await fileService.pickImages(),
        );
      }

      if (attachments.isEmpty) {
        DebugLogger.log('No images selected', scope: 'chat/page');
        return;
      }

      final imageSizes = <LocalAttachment, int>{};
      for (final attachment in attachments) {
        DebugLogger.log(
          'Image selected: ${attachment.file.path}',
          scope: 'chat/page',
        );
        DebugLogger.log(
          'Image display name: ${attachment.displayName}',
          scope: 'chat/page',
        );
        final imageSize = await attachment.file.length();
        imageSizes[attachment] = imageSize;
        DebugLogger.log('Image size: $imageSize bytes', scope: 'chat/page');

        // Validate file size (default 20MB limit like OpenWebUI)
        if (!validateFileSize(imageSize, 20)) {
          if (!mounted) return;
          return;
        }
      }

      // Add images to the attachment list
      ref.read(attachedFilesProvider.notifier).addFiles(attachments);
      DebugLogger.log(
        'Images added to attachment list: ${attachments.length}',
        scope: 'chat/page',
      );

      // Drive uploads via the shared media-upload controller for unified
      // retry/progress.
      DebugLogger.log('Uploading image(s)...', scope: 'chat/page');
      for (final attachment in attachments) {
        unawaited(
          ref
              .read(mediaUploadControllerProvider)
              .upload(
                filePath: attachment.file.path,
                fileName: attachment.displayName,
                fileSize:
                    imageSizes[attachment] ?? await attachment.file.length(),
              )
              .catchError((Object e) {
                DebugLogger.log('Image upload failed: $e', scope: 'chat/page');
              }),
        );
      }
    } catch (e) {
      DebugLogger.log('Image attachment error: $e', scope: 'chat/page');
      if (!mounted) return;
    }
  }

  /// Handles images/files pasted from clipboard into the chat input.
  Future<void> _handlePastedAttachments(List<LocalAttachment> attachments) {
    if (attachments.isEmpty) return Future<void>.value();

    DebugLogger.log(
      'Processing ${attachments.length} pasted attachment(s)',
      scope: 'chat/page',
    );

    final mediaUpload = ref.read(mediaUploadControllerProvider);
    // Keep this callback non-async. The native paste lease commits only if
    // [addFiles] returns synchronously; an `async` wrapper would turn a
    // notifier exception into a later Future error and falsely acknowledge the
    // native payload.
    final preparation = acceptPastedAttachments(
      attachments: attachments,
      addFiles: ref.read(attachedFilesProvider.notifier).addFiles,
      upload: (attachment, fileSize) => mediaUpload.enqueueUpload(
        filePath: attachment.file.path,
        fileName: attachment.displayName,
        fileSize: fileSize,
      ),
      rollback: (attachment) async {
        await mediaUpload.removeAttachment(attachment.file.path);
      },
      logScope: 'chat/page',
    );
    return preparation.then<void>(
      (_) => DebugLogger.log(
        'Added ${attachments.length} pasted attachment(s)',
        scope: 'chat/page',
      ),
      onError: (Object _, StackTrace _) {
        // The helper logs preparation and rollback failures. Composer
        // ownership has already been restored.
      },
    );
  }

  /// Checks if a URL is a YouTube URL.
  bool _isYoutubeUrl(String url) {
    return url.startsWith('https://www.youtube.com') ||
        url.startsWith('https://youtu.be') ||
        url.startsWith('https://youtube.com') ||
        url.startsWith('https://m.youtube.com');
  }

  Future<void> _promptAttachWebpage() async {
    final api = ref.read(apiServiceProvider);
    if (api == null) return;
    final l10n = AppLocalizations.of(context)!;
    String url = '';
    bool submitting = false;
    await ThemedDialogs.showCustom<void>(
      context: context,
      builder: (dialogContext) {
        String? errorText;
        return StatefulBuilder(
          builder: (innerContext, setState) {
            void setError(String? msg) {
              setState(() {
                errorText = msg;
              });
            }

            return ThemedDialogs.buildBase(
              context: innerContext,
              title: l10n.webPage,
              content: SizedBox(
                width: 400,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.attachWebpageDescription,
                      style: Theme.of(innerContext).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    AdaptiveTextField(
                      placeholder: 'https://example.com/article',
                      decoration: innerContext.conduitInputStyles
                          .standard(
                            hint: 'https://example.com/article',
                            error: errorText,
                          )
                          .copyWith(labelText: l10n.webpageUrlLabel),
                      onChanged: (value) {
                        url = value;
                        if (errorText != null) setError(null);
                      },
                      autofocus: true,
                      keyboardType: TextInputType.url,
                    ),
                  ],
                ),
              ),
              actions: [
                AdaptiveButton(
                  onPressed: submitting
                      ? null
                      : () {
                          Navigator.of(dialogContext).pop();
                        },
                  label: l10n.cancel,
                  style: AdaptiveButtonStyle.plain,
                ),
                AdaptiveButton.child(
                  style: AdaptiveButtonStyle.filled,
                  onPressed: submitting
                      ? null
                      : () async {
                          final parsed = Uri.tryParse(url.trim());
                          if (parsed == null ||
                              !(parsed.isScheme('http') ||
                                  parsed.isScheme('https'))) {
                            setError(l10n.invalidHttpUrl);
                            return;
                          }
                          setState(() {
                            submitting = true;
                            errorText = null;
                          });
                          try {
                            final trimmedUrl = url.trim();
                            final isYoutube = _isYoutubeUrl(trimmedUrl);

                            // Use appropriate API based on URL type
                            final result = isYoutube
                                ? await api.processYoutube(url: trimmedUrl)
                                : await api.processWebpage(url: trimmedUrl);

                            final file = (result?['file'] as Map?)
                                ?.cast<String, dynamic>();
                            final fileData = (file?['data'] as Map?)
                                ?.cast<String, dynamic>();
                            final content =
                                fileData?['content']?.toString() ?? '';
                            if (content.isEmpty) {
                              setError(
                                isYoutube
                                    ? l10n.youtubeTranscriptFetchFailed
                                    : l10n.webpageNoReadableContent,
                              );
                              return;
                            }
                            final meta = (file?['meta'] as Map?)
                                ?.cast<String, dynamic>();
                            final name =
                                meta?['name']?.toString() ?? parsed.host;
                            final collectionName = result?['collection_name']
                                ?.toString();

                            // Add as appropriate type
                            final notifier = ref.read(
                              contextAttachmentsProvider.notifier,
                            );
                            if (isYoutube) {
                              notifier.addYoutube(
                                displayName: name,
                                content: content,
                                url: trimmedUrl,
                                collectionName: collectionName,
                              );
                            } else {
                              notifier.addWeb(
                                displayName: name,
                                content: content,
                                url: trimmedUrl,
                                collectionName: collectionName,
                              );
                            }

                            if (!mounted || !dialogContext.mounted) {
                              return;
                            }
                            Navigator.of(dialogContext).pop();
                          } catch (_) {
                            setError(l10n.failedToAttachContent);
                          } finally {
                            if (mounted) {
                              setState(() => submitting = false);
                            }
                          }
                        },
                  child: submitting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(l10n.attach),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _handleNewChat() {
    // Start a new chat using the existing function
    startNewChat();

    // Hide scroll-to-bottom button for a fresh chat
    if (mounted) {
      setState(() {
        _showScrollToBottom = false;
      });
    }
  }

  void _dismissComposerFocus() {
    try {
      ref.read(composerAutofocusEnabledProvider.notifier).set(false);
    } catch (_) {}
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      SystemChannels.textInput.invokeMethod('TextInput.hide');
    } catch (_) {}
  }

  void _handleBottomInsetChange(double nextBottomInset) {
    final previousBottomInset = _lastBottomInset;
    _lastBottomInset = nextBottomInset;
    if (previousBottomInset == null) {
      return;
    }
    if (!_shouldKeepConversationBottomAnchoredOnInsetChange(
      previousBottomInset: previousBottomInset,
      nextBottomInset: nextBottomInset,
      isAnchoredToBottom: _isAnchoredToBottom,
      isUserInteractingWithScroll: _isUserInteractingWithScroll,
      wantsPinToTop: _wantsPinToTop,
    )) {
      return;
    }
    _timelineViewportController.requestLayoutMaintenance();
  }

  void _handleComposerHeightChange(double nextInputHeight) {
    if ((nextInputHeight - _inputHeight).abs() < _scrollCorrectionEpsilon) {
      return;
    }
    setState(() {
      _inputHeight = nextInputHeight;
    });
    _timelineViewportController.requestLayoutMaintenance();
  }

  void _scheduleScrollToBottomVisibilitySync({bool prewarm = false}) {
    _scrollToBottomPrewarmPending |= prewarm;
    if (_scrollToBottomVisibilitySyncScheduled) return;
    _scrollToBottomVisibilitySyncScheduled = true;
    final binding = WidgetsBinding.instance;
    binding.addPostFrameCallback((_) {
      _scrollToBottomVisibilitySyncScheduled = false;
      final shouldPrewarm = _scrollToBottomPrewarmPending;
      _scrollToBottomPrewarmPending = false;
      if (!mounted) return;
      _updateScrollToBottomButtonVisibility();
      if (shouldPrewarm) _prewarmVisibleMarkdownRows();
    });
    binding.scheduleFrame();
  }

  void _handlePinEndSpaceChanged(double extent) {
    if (!mounted || !_wantsPinToTop) return;
    _pinGeometryReady = true;
    final exhausted = extent <= _pinnedMeasurementEpsilon;
    final wasExhausted = _pinToTopEndSpaceExtent <= _pinnedMeasurementEpsilon;
    final changed =
        (extent - _pinToTopEndSpaceExtent).abs() > _pinnedMeasurementEpsilon;
    _pinToTopEndSpaceExtent = extent;
    if (changed || exhausted != wasExhausted) {
      _scheduleScrollToBottomVisibilitySync();
      _syncLayoutBottomAnchor();
    }
  }

  ({bool hasScrollableContent, double distanceFromBottom})
  _recomputeBottomAnchorState() {
    final hasScrollableContent = _hasScrollableTranscriptContent();
    final distanceFromBottom = _latestPresentationDistance();
    final wasAnchored = _bottomAnchorController.isAnchoredToBottom;
    _bottomAnchorController.updateAnchor(
      hasScrollableContent: hasScrollableContent,
      distanceFromBottom: distanceFromBottom,
    );
    // Only re-arm layout maintenance when the anchored state actually
    // transitions. This runs on every metrics tick; while streaming and
    // anchored, an unconditional sync scheduled a full measurement pass
    // (row-rect snapshot + pin geometry) every frame of a downward scroll.
    if (_bottomAnchorController.isAnchoredToBottom != wasAnchored) {
      _syncLayoutBottomAnchor();
    }
    return (
      hasScrollableContent: hasScrollableContent,
      distanceFromBottom: distanceFromBottom,
    );
  }

  double _latestPresentationDistance() {
    final pinnedDistance = _pinnedPresentationDistance();
    return debugResolveLatestPresentationDistanceForTesting(
      pinnedTurnActive: _wantsPinToTop,
      userDetached: _bottomAnchorController.isUserDetachedFromBottom,
      pinnedDistance: pinnedDistance,
      physicalLatestDistance: _timelineViewportController.distanceFromLatest,
    );
  }

  double? _pinnedPresentationDistance() {
    final pinnedMessageId = _wantsPinToTop ? _pinnedUserMessageId : null;
    return pinnedMessageId == null
        ? null
        : _timelineViewportController.distanceFromMessageTop(pinnedMessageId);
  }

  void _updateBottomAnchorTracking() {
    _recomputeBottomAnchorState();
  }

  Future<void> _refreshActiveConversation() async {
    try {
      await refreshActiveOpenWebUiConversation(ref);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'active-conversation-refresh-failed',
        scope: 'chat/page',
        error: error,
        stackTrace: stackTrace,
      );
    }

    try {
      refreshConversationsCache(ref);
      await ref.read(conversationsProvider.future);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'conversation-list-refresh-failed',
        scope: 'chat/page',
        error: error,
        stackTrace: stackTrace,
      );
    }

    await Future.delayed(const Duration(milliseconds: 300));
  }

  Future<void> _handleVoiceCall() async {
    try {
      await ref
          .read(voiceCallLauncherProvider)
          .launch(startNewConversation: false);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'launch-failed',
        scope: 'chat/voice_call',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      final message = error is StateError
          ? error.message.toString()
          : AppLocalizations.of(context)!.errorMessage;
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  void _prewarmVisibleMarkdownRows() {
    if (!mounted || _isDeactivated) return;

    final completeMessages = ref.read(chatMessagesProvider);
    final paging = ref.read(chatTranscriptPagingProvider);
    final messages = _renderedTranscriptWindow(completeMessages, paging);
    if (messages.isEmpty) {
      return;
    }
    final modelsAsync = ref.read(modelsProvider);
    final models = modelsAsync.hasValue ? modelsAsync.value : null;
    final layoutMetadata = _resolveChatListStableLayoutMetadata(
      messages: messages,
      models: models,
      apiService: ref.read(apiServiceProvider),
    );
    _scheduleMarkdownPrewarm(messages, layoutMetadata: layoutMetadata);
  }

  void _updateScrollToBottomButtonVisibility() {
    if (!mounted || _isDeactivated) return;

    final anchorState = _recomputeBottomAnchorState();
    final showButton = _shouldExposeScrollToBottomButton(
      hasScrollableContent: anchorState.hasScrollableContent,
      distanceFromLatest: anchorState.distanceFromBottom,
    );

    if (showButton != _showScrollToBottom) {
      setState(() {
        _showScrollToBottom = showButton;
      });
    }
  }

  bool _shouldExposeScrollToBottomButton({
    required bool hasScrollableContent,
    required double distanceFromLatest,
  }) {
    if (!_timelineViewportController.hasClients) return false;
    return debugShouldExposeScrollToLatestForTesting(
      hasScrollableContent: hasScrollableContent,
      pinAutoFollowing: _shouldAutoFollowPinnedTurn,
      freeScrolling:
          _timelineScrollMode == _ChatTimelineScrollMode.freeScrolling,
      bottomAnchorDetached: _bottomAnchorController.isUserDetachedFromBottom,
      currentlyShowing: _showScrollToBottom,
      distanceFromLatest: distanceFromLatest,
      showThreshold: _scrollButtonShowThreshold,
      hideThreshold: _scrollButtonHideThreshold,
    );
  }

  int _renderedTranscriptCount(
    List<ChatMessage> completeMessages,
    ChatTranscriptPagingState paging,
  ) {
    return paging.loadedCount == 0 && completeMessages.isNotEmpty
        ? math.min(kChatTranscriptPageSize, completeMessages.length)
        : math.min(paging.loadedCount, completeMessages.length);
  }

  List<ChatMessage> _renderedTranscriptWindow(
    List<ChatMessage> completeMessages,
    ChatTranscriptPagingState paging,
  ) {
    final count = _renderedTranscriptCount(completeMessages, paging);
    if (!identical(_transcriptWindowSource, completeMessages) ||
        count != _transcriptWindowCount) {
      _transcriptWindowSource = completeMessages;
      _transcriptWindowCount = count;
      _transcriptWindowMemo = latestTranscriptWindow(completeMessages, count);
    }
    return _transcriptWindowMemo;
  }

  bool _hasScrollableTranscriptContent() {
    return _timelineViewportController.hasRealContentOverflow;
  }

  double _messageListBottomPadding() {
    final voice = ref.read(chatVoiceModeControllerProvider);
    final voiceOverlayHeight = voice.isActive
        ? (voice.isCollapsed ? 72.0 : 180.0)
        : 0.0;
    return Spacing.lg + _inputHeight + voiceOverlayHeight;
  }

  /// User-initiated scroll to bottom (e.g. button tap).
  void _userScrollToBottom() {
    ConduitHaptics.lightImpact();
    if (debugShouldReleasePinnedTurnForManualNavigationForTesting(
      pinActive: _wantsPinToTop,
      userDragStarted: false,
      latestRequested: true,
    )) {
      _releasePinToRealLatest(smooth: true, explicitNavigation: true);
      return;
    }
    _resumeLatestPresentation();
    _scrollToBottom(smooth: true, explicitNavigation: true);
  }

  Future<void> _handleNativeScrollToTop() async {
    if (!mounted || !_timelineViewportController.hasClients) return;
    final ownerGeneration = _conversationOwnerGeneration;
    _hasUserScrolled = true;

    // A status-bar tap is a direct user navigation command. Transfer scroll
    // ownership before moving so pin/latest maintenance cannot pull the
    // viewport back toward the streaming tail.
    _releasePinForUserDrag();
    _cancelPendingViewportNavigation();
    _bottomAnchorController.detachByUser();

    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || ownerGeneration != _conversationOwnerGeneration) return;

    if (context.reduceMotion) {
      await _timelineViewportController.jumpToOldest();
    } else {
      await _timelineViewportController.animateToOldest(
        duration: const Duration(milliseconds: 500),
        curve: Curves.linearToEaseOut,
      );
    }
    if (!mounted || ownerGeneration != _conversationOwnerGeneration) return;
    _scheduleScrollToBottomVisibilitySync(prewarm: true);
  }

  void _releasePinToRealLatest({
    required bool smooth,
    required bool explicitNavigation,
  }) {
    if (!_wantsPinToTop) {
      _resumeLatestPresentation();
      _scrollToBottom(smooth: smooth, explicitNavigation: explicitNavigation);
      return;
    }
    _bottomAnchorController.requestBottomAnchor();
    setState(() {
      // Keep both automatic engines off for the support-removal frame. The
      // single real-footer navigation below becomes the only scroll owner.
      _clearPinToTopAnchor(nextMode: _ChatTimelineScrollMode.anchoringNewTurn);
    });
    final releaseGeneration = _pinPositionGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !debugShouldContinuePinReleaseForTesting(
            pinActive: _wantsPinToTop,
            isUserInteracting: _isUserInteractingWithScroll,
            releaseGeneration: releaseGeneration,
            currentGeneration: _pinPositionGeneration,
          )) {
        return;
      }
      _scrollToBottom(
        smooth: smooth,
        explicitNavigation: explicitNavigation,
        onSettled: () {
          if (!mounted ||
              !debugShouldContinuePinReleaseForTesting(
                pinActive: _wantsPinToTop,
                isUserInteracting: _isUserInteractingWithScroll,
                releaseGeneration: releaseGeneration,
                currentGeneration: _pinPositionGeneration,
              )) {
            return;
          }
          setState(
            () => _timelineScrollMode = _ChatTimelineScrollMode.followingLatest,
          );
          _bottomAnchorController.requestBottomAnchor();
          _syncLayoutBottomAnchor();
        },
      );
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _scrollToBottom({
    bool smooth = true,
    Duration duration = const Duration(milliseconds: 220),
    bool explicitNavigation = false,
    VoidCallback? onSettled,
  }) {
    if (_isUserInteractingWithScroll ||
        !_timelineViewportController.hasClients) {
      onSettled?.call();
      return;
    }
    _bottomAnchorController.requestBottomAnchor();
    final shouldAnimate = smooth && !context.reduceMotion;

    PerformanceProfiler.instance.instant(
      'chat_auto_scroll',
      scope: 'chat',
      data: {'smooth': shouldAnimate, 'target': 'latest'},
    );

    if (shouldAnimate) {
      final navigationGeneration = explicitNavigation
          ? ++_explicitLatestNavigationGeneration
          : null;
      if (navigationGeneration != null) {
        _explicitLatestNavigationInFlight = true;
      }
      unawaited(
        _timelineViewportController
            .animateToLatest(duration: duration, curve: Curves.easeOutCubic)
            .whenComplete(() {
              if (!mounted) return;
              if (navigationGeneration != null &&
                  !debugCompletionOwnsExplicitLatestNavigationForTesting(
                    completedGeneration: navigationGeneration,
                    currentGeneration: _explicitLatestNavigationGeneration,
                  )) {
                return;
              }
              if (debugCompletionOwnsExplicitLatestNavigationForTesting(
                completedGeneration: navigationGeneration,
                currentGeneration: _explicitLatestNavigationGeneration,
              )) {
                _explicitLatestNavigationInFlight = false;
              }
              _scheduleScrollToBottomVisibilitySync(prewarm: true);
              _syncLayoutBottomAnchor();
              onSettled?.call();
            }),
      );
    } else {
      _cancelExplicitLatestNavigation();
      _timelineViewportController.jumpToLatest();
      _scheduleScrollToBottomVisibilitySync(prewarm: true);
      _syncLayoutBottomAnchor();
      onSettled?.call();
    }
  }

  void _resumeLatestPresentation() {
    if (_wantsPinToTop) {
      _releasePinToRealLatest(smooth: false, explicitNavigation: false);
      return;
    }
    if (_timelineScrollMode != _ChatTimelineScrollMode.followingLatest) {
      setState(
        () => _timelineScrollMode = _ChatTimelineScrollMode.followingLatest,
      );
    }
    _bottomAnchorController.requestBottomAnchor();
    _syncLayoutBottomAnchor();
  }

  void _beginScrollProfile(String interaction) {
    if (_activeScrollProfileTaskKey != null) {
      return;
    }
    PerformanceProfiler.instance.startFrameCadence();
    _activeScrollProfileTaskKey = PerformanceProfiler.instance.startTask(
      'chat_scroll',
      scope: 'chat',
      key: 'chat-scroll:${identityHashCode(this)}',
      data: {
        'interaction': interaction,
        'conversationId': _lastConversationId ?? 'none',
      },
    );
  }

  void _endScrollProfile({required String reason}) {
    final taskKey = _activeScrollProfileTaskKey;
    if (taskKey == null) {
      return;
    }
    _activeScrollProfileTaskKey = null;
    PerformanceProfiler.instance.stopFrameCadence(reason: reason);
    PerformanceProfiler.instance.finishTask(
      taskKey,
      data: {
        'reason': reason,
        'visibleItems': _timelineViewportController.visibleMessageIds.length
            .toString(),
      },
    );
  }

  void _handleConversationChanged(String? conversationId) {
    if (conversationId == _lastConversationId) return;

    final outgoingId = _lastConversationId;
    if (debugShouldPreservePinnedFirstTurnForConversationBindingForTesting(
      pinActive: _wantsPinToTop,
      previousConversationId: outgoingId,
      nextConversationId: conversationId,
    )) {
      _lastConversationId = conversationId;
      markConversationRead(ref, conversationId);
      return;
    }
    if (isActiveConversationInPlaceRemap(ref, outgoingId, conversationId)) {
      if (outgoingId != null &&
          conversationId != null &&
          _savedScrollAnchors.containsKey(outgoingId)) {
        _savedScrollAnchors[conversationId] = _savedScrollAnchors.remove(
          outgoingId,
        )!;
      }
      _lastConversationId = conversationId;
      markConversationRead(ref, conversationId);
      return;
    }

    _conversationOwnerGeneration += 1;
    markConversationRead(ref, outgoingId);
    markConversationRead(ref, conversationId);
    _saveCurrentScrollAnchor(conversationId: outgoingId);

    _lastConversationId = conversationId;
    _cancelPendingViewportNavigation();
    _markdownPrewarmThrottle.cancel();
    _lastMarkdownPrewarmSignature = null;
    _hasPrewarmedAttachedViewport = false;
    _lastVisibleMessageIds = const <String>{};
    _clearPinToTopAnchor();
    _invalidateChatListStableLayoutMetadata();
    _hasUserScrolled = false;
    final totalMessages = ref.read(chatMessagesProvider).length;
    final anchor = conversationId == null
        ? null
        : _savedScrollAnchors[conversationId];
    if (anchor != null) {
      _bottomAnchorController.detachByUser();
      _timelineScrollMode = _ChatTimelineScrollMode.freeScrolling;
      _initialScrollAnchor = anchor;
      ref
          .read(chatTranscriptPagingProvider.notifier)
          .restoreLoadedCount(
            totalMessages: totalMessages,
            loadedCount: anchor.loadedCount,
          );
    } else {
      _timelineScrollMode = _ChatTimelineScrollMode.followingLatest;
      _initialScrollAnchor = null;
      ref
          .read(chatTranscriptPagingProvider.notifier)
          .reset(totalMessages: totalMessages);
      if (conversationId != null) {
        _bottomAnchorController.resetForDetachedScroll();
      }
    }
  }

  void _handleViewportOwnerChanged() {
    if (!mounted) return;
    _savedScrollAnchors.clear();
    _initialScrollAnchor = null;
    _hasPrewarmedAttachedViewport = false;
    _lastVisibleMessageIds = const <String>{};
    _conversationOwnerGeneration += 1;
    _cancelExplicitLatestNavigation();
    _cancelPendingViewportNavigation();
    setState(() {
      _clearPinToTopAnchor();
      _timelineScrollMode = _ChatTimelineScrollMode.followingLatest;
      _showScrollToBottom = false;
      _hasUserScrolled = false;
    });
  }

  void _scheduleViewportOwnerChanged() {
    if (_viewportOwnerChangeScheduled) return;
    _viewportOwnerChangeScheduled = true;
    final binding = WidgetsBinding.instance;
    binding.addPostFrameCallback((_) {
      _viewportOwnerChangeScheduled = false;
      if (!mounted) return;
      _handleViewportOwnerChanged();
    });
    binding.scheduleFrame();
  }

  void _saveCurrentScrollAnchor({String? conversationId}) {
    final id = conversationId ?? _lastConversationId;
    if (id == null) return;
    final messages = ref.read(chatMessagesProvider);
    final paging = ref.read(chatTranscriptPagingProvider);
    final visible = _renderedTranscriptWindow(messages, paging);
    final visibleCount = visible.length;
    if (visibleCount == 0) return;
    final anchor = _timelineViewportController.captureTopVisibleAnchor(
      loadedCount: visibleCount,
    );
    if (anchor == null) return;
    _savedScrollAnchors.remove(id);
    _savedScrollAnchors[id] = anchor;
    while (_savedScrollAnchors.length > 20) {
      _savedScrollAnchors.remove(_savedScrollAnchors.keys.first);
    }
  }

  void _cancelPendingViewportNavigation() {
    _timelineViewportController.cancelProgrammaticNavigation();
  }

  String? _activeStreamingAssistantId(List<ChatMessage> messages) {
    if (messages.isEmpty) {
      return null;
    }
    final lastMessage = messages.last;
    // Use the same phase rule as the timeline's hasRunningTurn so the
    // scroll-keepalive agrees with the footer/pin logic across the responseDone
    // gap (isStreaming still set, responseDone already true => settled).
    if (chatTurnPhaseForMessage(lastMessage) == ChatTurnPhase.running) {
      return lastMessage.id;
    }
    return null;
  }

  bool _hasActiveStreamingAssistant(List<ChatMessage> messages) {
    return _activeStreamingAssistantId(messages) != null;
  }

  void _schedulePinnedTurnLifecycleReconciliation(
    ChatTurnPhase? assistantPhase,
  ) {
    if (!_shouldAutoFollowPinnedTurn) return;
    final assistantMessageId = _pinToTopState.streamingMessageId;
    if (assistantMessageId == null) return;
    if (!debugShouldSettlePinnedTurnForLifecycleForTesting(
      pinActive: true,
      assistantPhase: assistantPhase,
    )) {
      return;
    }

    final scheduledGeneration = _pinPositionGeneration;
    if (_pinLifecycleReconciliationGeneration == scheduledGeneration) return;
    _pinLifecycleReconciliationGeneration = scheduledGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pinLifecycleReconciliationGeneration == scheduledGeneration) {
        _pinLifecycleReconciliationGeneration = null;
      }
      if (!mounted ||
          scheduledGeneration != _pinPositionGeneration ||
          _pinToTopState.streamingMessageId != assistantMessageId) {
        return;
      }
      ChatMessage? currentAssistant;
      for (final message in ref.read(chatMessagesProvider)) {
        if (message.id == assistantMessageId) {
          currentAssistant = message;
          break;
        }
      }
      final currentPhase = currentAssistant == null
          ? null
          : chatTurnPhaseForMessage(currentAssistant);
      if (!debugShouldSettlePinnedTurnForLifecycleForTesting(
        pinActive: _shouldAutoFollowPinnedTurn,
        assistantPhase: currentPhase,
      )) {
        return;
      }

      // Keep the synthetic support that holds short turns at the prompt;
      // manual navigation or the next turn releases or replaces the pin.
      _bottomAnchorController.detachByUser();
      _cancelPinnedTurnAutomaticFollow();
      _scheduleScrollToBottomVisibilitySync(prewarm: true);
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _releasePinForUserDrag() {
    _cancelExplicitLatestNavigation();
    final shouldReleasePin =
        debugShouldReleasePinnedTurnForManualNavigationForTesting(
          pinActive: _wantsPinToTop,
          userDragStarted: true,
          latestRequested: false,
        );
    if (!shouldReleasePin) {
      if (_timelineScrollMode != _ChatTimelineScrollMode.freeScrolling) {
        setState(
          () => _timelineScrollMode = _ChatTimelineScrollMode.freeScrolling,
        );
      }
      return;
    }
    setState(() {
      _clearPinToTopAnchor(nextMode: _ChatTimelineScrollMode.freeScrolling);
    });
  }

  void _scrollToUserMessage({required int generation, int attempt = 0}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != _pinPositionGeneration ||
          !_shouldAutoFollowPinnedTurn) {
        return;
      }

      final targetId = _pinnedUserMessageId;
      if (targetId == null) {
        _cancelFailedPinToTopSettlement(
          generation: generation,
          reason: 'target-missing',
        );
        return;
      }
      final targetRowMounted =
          _timelineViewportController.rowRect(targetId) != null;
      final geometryReady = _pinGeometryReady && targetRowMounted;
      if ((!_timelineViewportController.hasClients || !geometryReady) &&
          attempt < _pinScrollMaxAttempts) {
        if (debugShouldPrepositionPinnedTurnForTesting(
          hasClients: _timelineViewportController.hasClients,
          targetRowMounted: targetRowMounted,
          prepositionAttempted: _pinPrepositionAttempted,
        )) {
          // A send from deep history can append the target outside the lazy
          // build range. Pre-position once at the trailing viewport so the
          // exact row and end sentinel exist before the single pin animation.
          _pinPrepositionAttempted = true;
          _timelineViewportController.prepositionOneViewportFromLatest();
        }
        _scrollToUserMessage(generation: generation, attempt: attempt + 1);
        WidgetsBinding.instance.scheduleFrame();
        return;
      }
      if (!_timelineViewportController.hasClients) {
        _cancelFailedPinToTopSettlement(
          generation: generation,
          reason: 'controller-not-attached',
        );
        return;
      }
      if (!geometryReady) {
        DebugLogger.log(
          'pin-measurement-timeout',
          scope: 'chat/scroll',
          data: {'attempts': attempt},
        );
        _cancelFailedPinToTopSettlement(
          generation: generation,
          reason: 'measurements-unavailable',
        );
        return;
      }

      if (context.reduceMotion || _pinShouldSettleImmediately) {
        unawaited(
          _timelineViewportController
              .jumpMessageToTop(targetId)
              .then(
                (moved) {
                  if (moved) {
                    _markPinToTopPositionSettled(generation);
                  } else {
                    _cancelFailedPinToTopSettlement(
                      generation: generation,
                      reason: 'target-not-visible',
                    );
                  }
                },
                onError: (Object error, StackTrace stackTrace) {
                  DebugLogger.error(
                    'pin-jump-failed',
                    scope: 'chat/scroll',
                    error: error,
                    stackTrace: stackTrace,
                  );
                  _cancelFailedPinToTopSettlement(
                    generation: generation,
                    reason: 'jump-failed',
                  );
                },
              ),
        );
        return;
      }
      unawaited(
        _timelineViewportController
            .animateMessageToTop(
              targetId,
              duration: _pinTransitionDuration,
              curve: Curves.easeOutCubic,
            )
            .then(
              (moved) {
                if (moved) {
                  _markPinToTopPositionSettled(generation);
                } else {
                  _cancelFailedPinToTopSettlement(
                    generation: generation,
                    reason: 'target-not-visible',
                  );
                }
              },
              onError: (Object error, StackTrace stackTrace) {
                DebugLogger.error(
                  'pin-animation-failed',
                  scope: 'chat/scroll',
                  error: error,
                  stackTrace: stackTrace,
                );
                _cancelFailedPinToTopSettlement(
                  generation: generation,
                  reason: 'animation-failed',
                );
              },
            ),
      );
    });
  }

  void _cancelFailedPinToTopSettlement({
    required int generation,
    required String reason,
  }) {
    if (!mounted || generation != _pinPositionGeneration) return;
    DebugLogger.log(
      'pin-settlement-cancelled',
      scope: 'chat/scroll',
      data: {'reason': reason},
    );
    setState(_clearPinToTopAnchor);
  }

  void _markPinToTopPositionSettled(int generation) {
    if (!mounted ||
        generation != _pinPositionGeneration ||
        !_shouldAutoFollowPinnedTurn ||
        _pinToTopPositionSettled) {
      return;
    }
    setState(() => _pinToTopPositionSettled = true);
  }

  void _clearPinToTopAnchor({
    _ChatTimelineScrollMode nextMode = _ChatTimelineScrollMode.followingLatest,
  }) {
    _cancelExplicitLatestNavigation();
    _pinPositionGeneration += 1;
    _pinToTopState = const _PinToTopState.inactive();
    _pinToTopEndSpaceExtent = 0;
    _pinGeometryReady = false;
    _pinShouldSettleImmediately = false;
    _pinToTopPositionSettled = false;
    _pinPrepositionAttempted = false;
    _pinLifecycleReconciliationGeneration = null;
    _timelineScrollMode = nextMode;
    _syncLayoutBottomAnchor();
  }

  /// Builds a styled container with high-contrast background for app bar
  /// widgets, matching the floating chat input styling.
  Widget _buildScrollToBottomButton(BuildContext context) {
    final icon = Platform.isIOS
        ? CupertinoIcons.chevron_down
        : Icons.keyboard_arrow_down;
    const buttonSize = 40.0;
    const iconSize = IconSize.medium;
    final theme = context.conduitTheme;
    final usesOpaqueFallback = conduitUsesOpaqueGlassFallback();
    final style = usesOpaqueFallback
        ? AdaptiveButtonStyle.filled
        : AdaptiveButtonStyle.glass;

    if (conduitSupportsNativeGlass()) {
      return NativeGlassIconButton(
        onPressed: _userScrollToBottom,
        symbol: SFSymbol(
          'chevron.down',
          size: iconSize,
          color: theme.textPrimary,
        ),
        dimension: buttonSize,
      );
    }

    return AdaptiveButton.child(
      onPressed: _userScrollToBottom,
      style: style,
      color: usesOpaqueFallback
          ? theme.surfaceContainerHighest.withValues(alpha: 0.95)
          : null,
      size: AdaptiveButtonSize.medium,
      minSize: const Size.square(buttonSize),
      padding: EdgeInsets.zero,
      borderRadius: BorderRadius.circular(buttonSize),
      useSmoothRectangleBorder: false,
      child: Icon(icon, size: iconSize, color: theme.textPrimary),
    );
  }

  Widget _buildMessagesList(ThemeData theme, WidgetRef watchRef) {
    watchRef.watch(chatMessageStructureSignatureProvider);
    // Rebuild the list shell only when streaming starts or ends so pin-to-top
    // cleanup runs on completion without rebuilding on every streamed chunk.
    final isStreaming = watchRef.watch(isChatStreamingProvider);
    final completeMessages = watchRef.read(chatMessagesProvider);
    final paging = watchRef.watch(chatTranscriptPagingProvider);
    final requestedCount = _renderedTranscriptCount(completeMessages, paging);
    final messages = _renderedTranscriptWindow(completeMessages, paging);
    final pinnedAssistantId = _pinToTopState.streamingMessageId;
    final pinnedAssistantPhase = pinnedAssistantId == null
        ? null
        : watchRef.watch(
            chatMessageByIdProvider(pinnedAssistantId).select(
              (message) =>
                  message == null ? null : chatTurnPhaseForMessage(message),
            ),
          );
    _schedulePinnedTurnLifecycleReconciliation(pinnedAssistantPhase);
    if (paging.loadedCount != requestedCount ||
        paging.hasOlder != (requestedCount < completeMessages.length)) {
      final scheduledConversation = watchRef.read(activeConversationProvider);
      final scheduledConversationId = scheduledConversation == null
          ? null
          : conversationScopedId(scheduledConversation);
      final scheduledConversationGeneration = _conversationOwnerGeneration;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final activeConversation = ref.read(activeConversationProvider);
        if (!debugShouldApplyDeferredConversationMutationForTesting(
          isMounted: true,
          scheduledConversationId: scheduledConversationId,
          activeConversationId: activeConversation == null
              ? null
              : conversationScopedId(activeConversation),
          scheduledGeneration: scheduledConversationGeneration,
          activeGeneration: _conversationOwnerGeneration,
        )) {
          return;
        }
        final currentMessageCount = ref.read(chatMessagesProvider).length;
        ref
            .read(chatTranscriptPagingProvider.notifier)
            .ensureTotal(currentMessageCount);
      });
    }
    final isLoadingConversation = watchRef.watch(isLoadingConversationProvider);
    final showLoadingSkeleton =
        isLoadingConversation && completeMessages.isEmpty;
    if (showLoadingSkeleton) {
      return _buildLoadingMessagesList();
    }
    return _buildActualMessagesList(
      messages,
      watchRef,
      isStreaming: isStreaming,
    );
  }

  Widget _buildLoadingMessagesList() {
    // Use slivers to align with the actual messages view.
    // Do not attach the primary scroll controller here; the actual message
    // list owns it.
    // Add padding for the floating app bar and overlaid composer skeleton.
    final topPadding =
        MediaQuery.paddingOf(context).top +
        conduitAdaptiveToolbarHeightOf(context) +
        Spacing.md;
    final bottomPadding = _messageListBottomPadding();
    return CustomScrollView(
      key: const ValueKey('loading_messages'),
      controller: null,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      physics: platformAlwaysScrollablePhysics(context),
      scrollCacheExtent: const ScrollCacheExtent.pixels(300),
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            Spacing.inputPadding,
            topPadding,
            Spacing.inputPadding,
            bottomPadding,
          ),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate((context, index) {
              final isUser = index.isOdd;
              return _buildLoadingMessagePlaceholder(
                index: index,
                isUser: isUser,
              );
            }, childCount: 6),
          ),
        ),
      ],
    );
  }

  Widget _buildLoadingMessagePlaceholder({
    required int index,
    required bool isUser,
  }) {
    final lineCount = isUser
        ? (index % 3 == 0 ? 2 : 3)
        : (index % 3 == 0 ? 3 : 4);
    final widthFactors = isUser
        ? const <double>[0.68, 0.9, 0.46, 0.78]
        : const <double>[0.88, 0.95, 0.73, 0.58];
    final visualWeight = isUser
        ? 1200 + (index % 2) * 400
        : 2400 + (index % 3) * 800;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: Spacing.md),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.82,
        ),
        padding: const EdgeInsets.all(Spacing.md),
        decoration: BoxDecoration(
          color: isUser
              ? context.conduitTheme.buttonPrimary.withValues(alpha: 0.15)
              : context.conduitTheme.cardBackground,
          borderRadius: BorderRadius.circular(AppBorderRadius.messageBubble),
          border: Border.all(
            color: context.conduitTheme.cardBorder,
            width: BorderWidth.regular,
          ),
          boxShadow: ConduitShadows.messageBubble(context),
        ),
        child: MarkdownLoadingSkeleton(
          contentLength: visualWeight,
          lineCount: lineCount,
          widthFactors: widthFactors,
        ),
      ),
    );
  }

  Widget _buildActualMessagesList(
    List<ChatMessage> messages,
    WidgetRef watchRef, {
    required bool isStreaming,
  }) {
    if (messages.isEmpty) {
      return _buildEmptyState(Theme.of(context));
    }

    final apiService = watchRef.watch(apiServiceProvider);
    final paging = watchRef.watch(chatTranscriptPagingProvider);

    final topPadding =
        MediaQuery.paddingOf(context).top +
        conduitAdaptiveToolbarHeightOf(context) +
        Spacing.md;
    final bottomPadding = _messageListBottomPadding();

    // Watch models once here instead of per-message in the item builder.
    final modelsAsync = watchRef.watch(modelsProvider);
    final models = modelsAsync.hasValue ? modelsAsync.value : null;
    final suppressAssistantStreamingHaptics = watchRef.watch(
      chatVoiceModeControllerProvider.select((voice) => voice.isActive),
    );
    final layoutMetadata = _resolveChatListStableLayoutMetadata(
      messages: messages,
      models: models,
      apiService: apiService,
    );
    final timeline = _resolveTimelineRenderModel(messages);
    _scheduleMarkdownPrewarm(messages, layoutMetadata: layoutMetadata);
    _syncLayoutBottomAnchor();

    if (_lastProfiledMessageCacheStreamingState != isStreaming) {
      _lastProfiledMessageCacheStreamingState = isStreaming;
      PerformanceProfiler.instance.instant(
        'sliver_message_window',
        scope: 'platform_views',
        data: <String, Object?>{
          'streaming': isStreaming,
          'loadedCount': messages.length,
        },
      );
    }

    final messageIds = timeline.messageIds;
    final rowBuilder = _resolveTimelineRowBuilder(
      timeline: timeline,
      layoutMetadata: layoutMetadata,
      suppressStreamingHaptics: suppressAssistantStreamingHaptics,
    );
    final hideForInitialPin = debugShouldHideTranscriptForInitialPinForTesting(
      settleImmediately: _pinShouldSettleImmediately,
      positionSettled: _pinToTopPositionSettled,
    );

    return ChatTimelineViewport(
      controller: _timelineViewportController,
      ownerGeneration: _conversationOwnerGeneration,
      messageIds: messageIds,
      rowRebuildKeys: _rowRebuildKeysMemo,
      initialAnchor: _initialScrollAnchor,
      pinnedUserMessageId: _wantsPinToTop ? _pinnedUserMessageId : null,
      liveFooter: timeline.runningFooterHost == null
          ? null
          : Consumer(
              builder: (context, rowRef, _) {
                final latestMessage = rowRef.watch(
                  chatMessageByIdProvider(
                    timeline.runningFooterHost!.messageId,
                  ),
                );
                if (latestMessage == null) return const SizedBox.shrink();
                return StreamingTurnFooter(
                  message: latestMessage,
                  suppressStreamingHaptics: suppressAssistantStreamingHaptics,
                );
              },
            ),
      trailingContent: const ServerVersionWarningCard(),
      topContentInset: topPadding,
      bottomPadding: bottomPadding,
      horizontalPadding: Spacing.inputPadding,
      cacheExtent: _chatMessageScrollCachePixels,
      physics: platformAlwaysScrollablePhysics(context),
      isLoadingOlder: paging.isLoadingOlder,
      maintainVisibleAnchor:
          _timelineScrollMode == _ChatTimelineScrollMode.freeScrolling,
      followLatest:
          _timelineScrollMode == _ChatTimelineScrollMode.followingLatest,
      pinAutomatic: _shouldAutoFollowPinnedTurn,
      hideUntilSettled: hideForInitialPin,
      onPointerDown: () {
        // Ramp the ProMotion panel before the drag even clears touch slop;
        // waiting for drag-start leaves the fling's first stretch at 40 Hz.
        InteractionActivity.instance.notifyTouchDown();
        if (_explicitLatestNavigationInFlight ||
            _timelineScrollMode == _ChatTimelineScrollMode.anchoringNewTurn ||
            _shouldAutoFollowPinnedTurn) {
          _cancelPinnedTurnAutomaticFollow();
        }
      },
      onUserDragStart: () {
        InteractionActivity.instance.beginInteraction();
        final pinnedTurnWasActive = _wantsPinToTop;
        _hasUserScrolled = true;
        if (!_isUserInteractingWithScroll) {
          _releasePinForUserDrag();
          _cancelPendingViewportNavigation();
          _beginScrollProfile('user_drag');
        }
        _isUserInteractingWithScroll = true;
        _bottomAnchorController.detachByUser();
        if (debugShouldExposePinnedLatestOnDragForTesting(
              pinnedTurnActive: pinnedTurnWasActive,
              hasScrollableContent: _hasScrollableTranscriptContent(),
            ) &&
            !_showScrollToBottom) {
          setState(() => _showScrollToBottom = true);
        }
        try {
          ref.read(composerAutofocusEnabledProvider.notifier).set(false);
        } catch (_) {}
      },
      onUserDragEnd: () {
        InteractionActivity.instance.endInteraction();
        _endScrollProfile(reason: 'idle');
        _isUserInteractingWithScroll = false;
        _updateBottomAnchorTracking();
        _scheduleScrollToBottomVisibilitySync(prewarm: true);
        final naturallyReturnedToLatest = _wantsPinToTop
            ? (_pinnedPresentationDistance() ?? double.infinity) <=
                  _scrollButtonHideThreshold
            : _timelineViewportController.distanceFromLatest <=
                  _scrollButtonHideThreshold;
        if (naturallyReturnedToLatest) {
          _resumeLatestPresentation();
        }
        _maybeLoadOlderMessages();
      },
      onMetricsChanged: _handleViewportMetricsChanged,
      onPinEndSpaceChanged: _handlePinEndSpaceChanged,
      onOldestThresholdReached: _maybeLoadOlderMessages,
      onTrailingRefresh: _refreshActiveConversation,
      onNativeScrollToTop: _handleNativeScrollToTop,
      rowBuilder: rowBuilder,
    );
  }

  ChatTimelineRenderModel _resolveTimelineRenderModel(
    List<ChatMessage> messages,
  ) {
    final memo = _timelineModelMemo;
    if (memo != null &&
        identical(_timelineModelSource, messages) &&
        _timelineModelGeneration == _conversationOwnerGeneration) {
      return memo;
    }
    _timelineModelSource = messages;
    _timelineModelGeneration = _conversationOwnerGeneration;
    return _timelineModelMemo = ChatTimelineRenderModel.fromMessages(
      messages,
      duplicateReportScope:
          '${identityHashCode(this)}:$_conversationOwnerGeneration',
    );
  }

  /// Returns an identity-stable rowBuilder for unchanged inputs so the
  /// viewport's sliver delegate can skip rebuilding mounted rows on
  /// shell-only rebuilds. Rows read live message state through their own
  /// Consumers, so the closure only needs to change when the timeline
  /// structure or stable layout metadata does.
  ChatTimelineRowBuilder _resolveTimelineRowBuilder({
    required ChatTimelineRenderModel timeline,
    required _ChatListStableLayoutMetadata layoutMetadata,
    required bool suppressStreamingHaptics,
  }) {
    final memo = _rowBuilderMemo;
    if (memo != null &&
        identical(_rowBuilderTimeline, timeline) &&
        identical(_rowBuilderLayout, layoutMetadata) &&
        _rowBuilderSuppressHaptics == suppressStreamingHaptics) {
      return memo;
    }
    final messageIds = timeline.messageIds;
    // Reversed iteration plus map overwrite preserves the first source row for
    // malformed duplicate IDs while keeping the indexed fast path allocation-free.
    late final historyMessagesById = <String, ChatMessage>{
      for (final message in timeline.historyMessages.reversed)
        message.id: message,
    };
    late final layoutRowsByMessageId = <String, _ChatRowLayoutMetadata>{
      for (final row in layoutMetadata.rows.reversed) row.messageId: row,
    };
    ChatMessage? historyMessageById(String messageId) =>
        historyMessagesById[messageId];
    _ChatRowLayoutMetadata? layoutRowByMessageId(String messageId) =>
        layoutRowsByMessageId[messageId];
    Widget rowBuilder(BuildContext context, int renderIndex) {
      final sourceIndex = timeline.sourceIndexAtRenderIndex(renderIndex);
      if (sourceIndex == null || renderIndex >= messageIds.length) {
        return const SizedBox.shrink();
      }
      final renderedMessageId = messageIds[renderIndex];
      final tailRenderIndex = timeline.tailAssistantRenderIndex;
      if (tailRenderIndex != null && renderIndex == tailRenderIndex) {
        return _buildTailAssistantRow(
          timeline: timeline,
          layoutMetadata: layoutMetadata,
          sourceIndex: sourceIndex,
          layoutRowByMessageId: layoutRowByMessageId,
          suppressStreamingHaptics: suppressStreamingHaptics,
        );
      }
      return _buildHistoryRow(
        timeline: timeline,
        layoutMetadata: layoutMetadata,
        requestedMessageId: renderedMessageId,
        sourceIndex: sourceIndex,
        historyMessageById: historyMessageById,
        layoutRowByMessageId: layoutRowByMessageId,
        suppressStreamingHaptics: suppressStreamingHaptics,
      );
    }

    _rowBuilderTimeline = timeline;
    _rowBuilderLayout = layoutMetadata;
    _rowBuilderSuppressHaptics = suppressStreamingHaptics;
    _rowRebuildKeysMemo = List<Object?>.unmodifiable([
      for (var renderIndex = 0; renderIndex < messageIds.length; renderIndex++)
        if (timeline.sourceIndexAtRenderIndex(renderIndex) case final index?)
          (
            layout: index < layoutMetadata.rows.length
                ? layoutMetadata.rows[index]
                : null,
            isTail: timeline.tailAssistantRenderIndex == renderIndex,
            suppressStreamingHaptics: suppressStreamingHaptics,
          )
        else
          null,
    ]);
    return _rowBuilderMemo = rowBuilder;
  }

  Widget _buildTailAssistantRow({
    required ChatTimelineRenderModel timeline,
    required _ChatListStableLayoutMetadata layoutMetadata,
    required int sourceIndex,
    required _ChatRowLayoutMetadata? Function(String) layoutRowByMessageId,
    required bool suppressStreamingHaptics,
  }) {
    final tailAssistant = timeline.tailAssistant;
    final liveSourceIndex = timeline.tailAssistantSourceIndex;
    if (tailAssistant == null || liveSourceIndex == null) {
      return const SizedBox.shrink();
    }
    final indexedTailRowMetadata =
        liveSourceIndex >= 0 && liveSourceIndex < layoutMetadata.rows.length
        ? layoutMetadata.rows[liveSourceIndex]
        : null;
    if (indexedTailRowMetadata == null &&
        _timelineTailMetadataDesyncLogGeneration !=
            _conversationOwnerGeneration) {
      _timelineTailMetadataDesyncLogGeneration = _conversationOwnerGeneration;
      DebugLogger.log(
        'timeline-tail-source-index-invalid',
        scope: 'chat/layout',
        data: {
          'sourceIndex': sourceIndex,
          'liveSourceIndex': liveSourceIndex,
          'rowCount': layoutMetadata.rows.length,
          'messageId': tailAssistant.id,
        },
      );
    } else if (indexedTailRowMetadata != null &&
        indexedTailRowMetadata.messageId != tailAssistant.id &&
        _timelineTailMetadataDesyncLogGeneration !=
            _conversationOwnerGeneration) {
      _timelineTailMetadataDesyncLogGeneration = _conversationOwnerGeneration;
      DebugLogger.log(
        'timeline-tail-metadata-mismatch',
        scope: 'chat/layout',
        data: {
          'liveSourceIndex': liveSourceIndex,
          'expectedMessageId': tailAssistant.id,
          'actualMessageId': indexedTailRowMetadata.messageId,
        },
      );
    }
    final tailRowMetadata =
        indexedTailRowMetadata?.messageId == tailAssistant.id
        ? indexedTailRowMetadata
        : layoutRowByMessageId(tailAssistant.id);
    if (tailRowMetadata == null) return const SizedBox.shrink();
    assert(
      tailRowMetadata.messageId == tailAssistant.id,
      'stable-layout tail metadata must resolve to the rendered message',
    );
    return debugBuildAssistantTimelineSlotForTesting(
      assistantRow: Consumer(
        builder: (context, rowRef, _) {
          final liveMessage = rowRef.watch(
            chatMessageByIdProvider(tailAssistant.id),
          );
          if (liveMessage == null) return const SizedBox.shrink();
          return _buildAssistantMessageRowContent(
            rowRef: rowRef,
            messageId: tailAssistant.id,
            latestMessage: liveMessage,
            rowMetadata: tailRowMetadata,
            suppressStreamingHaptics: suppressStreamingHaptics,
          );
        },
      ),
    );
  }

  Widget _buildHistoryRow({
    required ChatTimelineRenderModel timeline,
    required _ChatListStableLayoutMetadata layoutMetadata,
    required String requestedMessageId,
    required int sourceIndex,
    required ChatMessage? Function(String) historyMessageById,
    required _ChatRowLayoutMetadata? Function(String) layoutRowByMessageId,
    required bool suppressStreamingHaptics,
  }) {
    final indexedMessage =
        sourceIndex >= 0 && sourceIndex < timeline.historyMessages.length
        ? timeline.historyMessages[sourceIndex]
        : null;
    final indexedRowMetadata =
        sourceIndex >= 0 && sourceIndex < layoutMetadata.rows.length
        ? layoutMetadata.rows[sourceIndex]
        : null;
    final indexedPairMatches =
        indexedMessage?.id == requestedMessageId &&
        indexedRowMetadata?.messageId == requestedMessageId;
    if (!indexedPairMatches &&
        _timelineHistoryIndexDesyncLogGeneration !=
            _conversationOwnerGeneration) {
      _timelineHistoryIndexDesyncLogGeneration = _conversationOwnerGeneration;
      DebugLogger.log(
        'timeline-history-index-desynced',
        scope: 'chat/layout',
        data: {
          'sourceIndex': sourceIndex,
          'historyCount': timeline.historyMessages.length,
          'rowCount': layoutMetadata.rows.length,
          'requestedMessageId': requestedMessageId,
          'indexedMessageId': indexedMessage?.id,
          'indexedMetadataId': indexedRowMetadata?.messageId,
        },
      );
    }
    final message = indexedPairMatches
        ? indexedMessage
        : historyMessageById(requestedMessageId);
    final rowMetadata = indexedPairMatches
        ? indexedRowMetadata
        : layoutRowByMessageId(requestedMessageId);
    if (message == null || rowMetadata == null) {
      return const SizedBox.shrink();
    }
    final messageId = message.id;
    assert(
      rowMetadata.messageId == messageId,
      'stable-layout row metadata must resolve to the rendered message',
    );
    if (rowMetadata.isArchivedVariant) {
      return _buildArchivedAssistantPlaceholder();
    }

    if (message.role == 'user') {
      return Consumer(
        builder: (context, rowRef, _) {
          final latestMessage = rowRef.watch(
            chatMessageByIdProvider(messageId),
          );
          if (latestMessage == null) return const SizedBox.shrink();
          return UserMessageBubble(
            message: latestMessage,
            isUser: true,
            isStreaming: latestMessage.isStreaming,
            modelName: rowMetadata.displayModelName,
            onCopy: () {
              final currentMessage = rowRef.read(
                chatMessageByIdProvider(messageId),
              );
              if (currentMessage != null) {
                // User content is stored raw (never presentation-escaped) and
                // owns its markup; copy it verbatim — the assistant clipboard
                // sanitizer would decode entities the user actually typed.
                Clipboard.setData(ClipboardData(text: currentMessage.content));
              }
            },
            onDelete: () => _deleteMessageGroup(<String>[messageId]),
            onRegenerate: () => _regenerateMessage(messageId),
          );
        },
      );
    }

    return debugBuildAssistantTimelineSlotForTesting(
      assistantRow: Consumer(
        builder: (context, rowRef, _) {
          final latestMessage = rowRef.watch(
            chatMessageByIdProvider(messageId),
          );
          if (latestMessage == null) return const SizedBox.shrink();
          return _buildAssistantMessageRowContent(
            rowRef: rowRef,
            messageId: messageId,
            latestMessage: latestMessage,
            rowMetadata: rowMetadata,
            suppressStreamingHaptics: suppressStreamingHaptics,
          );
        },
      ),
    );
  }

  /// Shared assistant-row body for both stable history and the live-tail slot.
  /// Each call site keeps its own Consumer / null-check so their
  /// rebuild scoping stays distinct; only the widget wiring is shared.
  Widget _buildAssistantMessageRowContent({
    required WidgetRef rowRef,
    required String messageId,
    required ChatMessage latestMessage,
    required _ChatRowLayoutMetadata rowMetadata,
    required bool suppressStreamingHaptics,
  }) {
    final groupIds = rowMetadata.groupMessageIds;
    final displayedMessage = groupIds.length > 1
        ? _messageWithGroupedHermesToolStatuses(rowRef, latestMessage, groupIds)
        : latestMessage;
    if (displayedMessage.statusHistory.length <
            latestMessage.statusHistory.length &&
        debugCanCollapseGroupedAssistantRowForTesting(
          displayedMessage,
          showModelHeader: rowMetadata.showModelHeader,
          showActionBar: rowMetadata.showActionBar,
        )) {
      return const SizedBox.shrink();
    }
    return assistant.AssistantMessageWidget(
      message: displayedMessage,
      isStreaming: latestMessage.isStreaming,
      showFollowUps: rowMetadata.showFollowUps,
      // Suppress the mount fade for a settled (completed or failed) assistant so
      // it doesn't re-animate when its widget remounts — either as the live tail
      // on first load, or when it migrates into the history sliver as a
      // follow-up turn begins. Genuinely running turns still animate.
      animateOnMount:
          !rowMetadata.replacesArchivedAssistant &&
          !chatTurnPhaseShowsCompletedFooter(
            chatTurnPhaseForMessage(latestMessage),
          ),
      modelName: rowMetadata.displayModelName,
      modelIconUrl: rowMetadata.modelIconUrl,
      showModelHeader: rowMetadata.showModelHeader,
      showActionBar: rowMetadata.showActionBar,
      versionModelNames: rowMetadata.versionModelNames,
      versionModelIconUrls: rowMetadata.versionModelIconUrls,
      suppressStreamingHaptics: suppressStreamingHaptics,
      onFollowUpSelected: _handleFollowUpSend,
      // The bar owner acts on the whole grouped response: a Hermes turn is one
      // answer split across rows, so copying or reading back only this row's
      // share would hand over a fragment.
      resolveGroupedResponseText: groupIds.length > 1
          ? () => _joinGroupedResponseText(rowRef, groupIds)
          : null,
      onCopy: () {
        if (groupIds.length > 1) {
          _copyMessage(_joinGroupedResponseText(rowRef, groupIds));
          return;
        }
        final currentMessage = rowRef.read(chatMessageByIdProvider(messageId));
        if (currentMessage != null) {
          _copyMessage(currentMessage.content);
        }
      },
      // Replaying from the first row of the group regenerates the whole turn;
      // targeting the last would leave its earlier rows stranded above the
      // replacement.
      onRegenerate: () =>
          _regenerateMessage(groupIds.isEmpty ? messageId : groupIds.first),
      onDelete: () => _deleteMessageGroup(
        groupIds.isEmpty ? <String>[messageId] : groupIds,
      ),
    );
  }

  ChatMessage _messageWithGroupedHermesToolStatuses(
    WidgetRef rowRef,
    ChatMessage message,
    List<String> groupIds,
  ) {
    final histories = <List<ChatStatusUpdate>>[];
    for (final id in groupIds) {
      histories.add(
        rowRef.watch(chatMessageByIdProvider(id))?.statusHistory ??
            const <ChatStatusUpdate>[],
      );
    }
    final grouped = debugGroupHermesToolStatusesForTesting(histories);
    final index = groupIds.indexOf(message.id);
    if (index < 0 || identical(grouped[index], message.statusHistory)) {
      return message;
    }
    return message.copyWith(statusHistory: grouped[index]);
  }

  /// Current text of every row in a grouped response, in display order.
  ///
  /// Read at tap time rather than cached with the layout metadata, whose
  /// signature deliberately ignores message content.
  String _joinGroupedResponseText(WidgetRef rowRef, List<String> groupIds) {
    final parts = <String>[];
    for (final id in groupIds) {
      final content = rowRef.read(chatMessageByIdProvider(id))?.content.trim();
      if (content != null && content.isNotEmpty) {
        parts.add(content);
      }
    }
    return parts.join('\n\n');
  }

  void _scheduleMarkdownPrewarm(
    List<ChatMessage> messages, {
    required _ChatListStableLayoutMetadata layoutMetadata,
  }) {
    // Twelve rows is roughly the visible window plus one fling of history in
    // each direction. Prewarm work runs on worker isolates in bounded
    // batches, so the wider net costs background time, not frames.
    final candidateIndices = _selectMarkdownPrewarmCandidatesFromVisibleIds(
      messages: messages,
      layoutMetadata: layoutMetadata,
      visibleMessageIds: _timelineViewportController.visibleMessageIds,
      maxCount: 12,
    );
    final filteredCandidateIndices = <int>[];
    final signatureParts = <String>[];

    for (final index in candidateIndices) {
      final message = messages[index];
      final content = message.content.trim();
      if (message.isStreaming ||
          content.isEmpty ||
          content.contains('data:image/')) {
        continue;
      }
      filteredCandidateIndices.add(index);
      signatureParts.add(
        '$index:${message.id}:${_cheapMarkdownPrewarmContentSignature(content)}',
      );
    }

    if (filteredCandidateIndices.isEmpty) {
      _markdownPrewarmThrottle.cancel();
      _lastMarkdownPrewarmSignature = null;
      return;
    }

    final signature = signatureParts.join('|');
    if (signature == _lastMarkdownPrewarmSignature) {
      return;
    }

    final rawContents = filteredCandidateIndices
        .map((index) => messages[index].content.trim())
        .toList(growable: false);
    _lastMarkdownPrewarmSignature = signature;
    _markdownPrewarmThrottle.schedule(rawContents, (pendingContents) {
      if (!mounted) return;
      unawaited(
        ref
            .read(markdownCompileServiceProvider)
            .prewarmContents(pendingContents, streaming: false),
      );
    });
  }

  void _copyMessage(String content) {
    final cleanedContent = ConduitMarkdownPreprocessor.sanitizeForClipboard(
      content,
    );
    Clipboard.setData(ClipboardData(text: cleanedContent));
  }

  /// Deletes every row of one grouped assistant response.
  ///
  /// The action bar of a grouped response speaks for the whole answer, so a
  /// single-row delete would leave the rest of the same turn behind. Ids are
  /// applied bottom-up so each removal only ever reparents rows already
  /// visited.
  Future<void> _deleteMessageGroup(List<String> messageIds) async {
    if (messageIds.isEmpty) return;
    final l10n = AppLocalizations.of(context)!;
    final currentMessages = ref.read(chatMessagesProvider);
    final initialRemovedIds = <String>{
      for (final id in messageIds) ..._messageIdsToDelete(currentMessages, id),
    };
    if (initialRemovedIds.isEmpty) return;
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.deleteMessagesTitle,
      message: l10n.deleteMessagesMessage(initialRemovedIds.length),
      confirmText: l10n.delete,
      cancelText: l10n.cancel,
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;

    final latestMessages = ref.read(chatMessagesProvider);
    final orderedIds = messageIds.reversed.toList(growable: false);
    final removedIds = <String>{};
    var updatedMessages = latestMessages;
    for (final id in orderedIds) {
      removedIds.addAll(_messageIdsToDelete(updatedMessages, id));
      updatedMessages = message_tree.deleteOpenWebUiMessageFromChatMessages(
        updatedMessages,
        id,
      );
    }

    final removedStreamingMessage = latestMessages
        .where((candidate) => removedIds.contains(candidate.id))
        .where((candidate) => candidate.isStreaming)
        .firstOrNull;
    if (removedStreamingMessage != null) {
      stopActiveTransport(
        removedStreamingMessage,
        ref.read(apiServiceProvider),
      );
      ref.read(chatMessagesProvider.notifier).cancelActiveMessageStream();
    }
    ref.read(chatMessagesProvider.notifier).setMessages(updatedMessages);

    final activeConversation = ref.read(activeConversationProvider);
    if (activeConversation != null) {
      final updatedConversation = inheritNativeHermesConversationProvenance(
        activeConversation,
        activeConversation.copyWith(
          messages: updatedMessages,
          updatedAt: DateTime.now(),
        ),
      );
      ref.read(activeConversationProvider.notifier).set(updatedConversation);
      ref
          .read(conversationsProvider.notifier)
          .updateConversation(
            updatedConversation.id,
            (_) => updatedConversation,
          );

      final api = ref.read(apiServiceProvider);
      if (api != null && !isTemporaryChat(updatedConversation.id)) {
        try {
          for (final id in orderedIds) {
            await api.deleteConversationMessage(updatedConversation.id, id);
          }
          ref
              .read(conversationsProvider.notifier)
              .trustConversation(updatedConversation.id);
        } catch (error, stackTrace) {
          DebugLogger.error(
            'delete-message-persist-failed',
            scope: 'chat/page',
            error: error,
            stackTrace: stackTrace,
          );
          if (!mounted) return;
          ref.read(chatMessagesProvider.notifier).setMessages(currentMessages);
          ref.read(activeConversationProvider.notifier).set(activeConversation);
          ref
              .read(conversationsProvider.notifier)
              .updateConversation(
                activeConversation.id,
                (_) => activeConversation,
              );
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppLocalizations.of(context)!.errorMessage)),
          );
        }
      }
    }
  }

  Set<String> _messageIdsToDelete(
    List<ChatMessage> messages,
    String messageId,
  ) => message_tree.openWebUiDeletedMessageIds(messages, messageId);

  void _regenerateMessage(String assistantMessageId) async {
    try {
      await regenerateHistoricalMessageById(ref, assistantMessageId);
    } catch (e) {
      DebugLogger.log('Regenerate failed: $e', scope: 'chat/page');
    }
  }

  // Inline editing handled by UserMessageBubble. Dialog flow removed.

  Widget _buildEmptyState(ThemeData theme) {
    final l10n = AppLocalizations.of(context)!;
    final authUser = ref.watch(currentUserProvider2);
    final asyncUser = ref.watch(currentUserProvider);
    final user = asyncUser.maybeWhen(
      data: (value) => value ?? authUser,
      orElse: () => authUser,
    );
    String? greetingName;
    if (user != null) {
      final derived = deriveUserDisplayName(user, fallback: '').trim();
      if (derived.isNotEmpty) {
        greetingName = derived;
        _cachedGreetingName = derived;
      }
    }
    greetingName ??= _cachedGreetingName;
    final hasGreetingName = greetingName != null && greetingName.isNotEmpty;
    if (!_greetingReady) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _greetingReady = true;
        });
      });
    }
    final baseGreetingStyle =
        theme.textTheme.displaySmall ?? AppTypography.displaySmallStyle;
    final greetingStyle = baseGreetingStyle.copyWith(
      fontWeight: FontWeight.w600,
      color: context.conduitTheme.textPrimary,
    );
    final textScaler = MediaQuery.textScalerOf(context);
    final greetingHeight =
        textScaler.scale(greetingStyle.fontSize ?? 24) *
        (greetingStyle.height ?? 1.1);
    final String? resolvedGreetingName = hasGreetingName ? greetingName : null;
    final greetingText = resolvedGreetingName != null
        ? l10n.greetingTitle(resolvedGreetingName)
        : l10n.finishDirectSetup;
    final isTemporary = ref.watch(temporaryChatEnabledProvider);

    // Check if there's a pending folder for the new chat
    final pendingFolderId = ref.watch(pendingFolderIdProvider);
    final folders = ref
        .watch(foldersProvider)
        .maybeWhen(data: (list) => list, orElse: () => <Folder>[]);
    final pendingFolder = pendingFolderId != null
        ? folders.where((f) => f.id == pendingFolderId).firstOrNull
        : null;

    // Add top padding for the floating app bar and bottom padding for the
    // overlaid composer section.
    final topPadding =
        MediaQuery.paddingOf(context).top +
        conduitAdaptiveToolbarHeightOf(context) +
        Spacing.md;
    final bottomPadding = _messageListBottomPadding();
    return LayoutBuilder(
      builder: (context, constraints) {
        final greetingDisplay = greetingText;
        final temporaryChatNotice = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.temporaryChat,
              style: AppTypography.labelStyle.copyWith(
                fontWeight: FontWeight.w600,
                color: context.conduitTheme.textPrimary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              l10n.temporaryChatTooltip,
              style: AppTypography.bodyMediumStyle.copyWith(
                color: context.conduitTheme.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        );

        return MediaQuery.removeViewInsets(
          context: context,
          removeBottom: true,
          child: SizedBox(
            width: double.infinity,
            height: constraints.maxHeight,
            child: _ScrollableCenteredEmptyState(
              padding: EdgeInsets.fromLTRB(
                Spacing.lg,
                topPadding,
                Spacing.lg,
                bottomPadding,
              ),
              children: [
                if (pendingFolder != null) ...[
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        l10n.newChat,
                        style: greetingStyle,
                        textAlign: TextAlign.center,
                      ),
                      if (isTemporary) ...[
                        const SizedBox(height: Spacing.md),
                        temporaryChatNotice,
                      ],
                      const SizedBox(height: Spacing.sm),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Platform.isIOS
                                ? CupertinoIcons.folder_fill
                                : Icons.folder_rounded,
                            size: 14,
                            color: context.conduitTheme.textSecondary,
                          ),
                          const SizedBox(width: Spacing.xs),
                          Text(
                            pendingFolder.name,
                            style: AppTypography.small.copyWith(
                              color: context.conduitTheme.textSecondary,
                            ),
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ],
                  ),
                ] else ...[
                  ConstrainedBox(
                    constraints: BoxConstraints(minHeight: greetingHeight),
                    child: AnimatedOpacity(
                      duration: context.motionDuration(
                        const Duration(milliseconds: 260),
                      ),
                      curve: Curves.easeOutCubic,
                      opacity: _greetingReady ? 1 : 0,
                      child: Align(
                        alignment: Alignment.center,
                        child: Text(
                          _greetingReady ? greetingDisplay : '',
                          style: greetingStyle,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ),
                  const ReleaseNotesBanner(),
                  if (isTemporary) ...[
                    const SizedBox(height: Spacing.md),
                    temporaryChatNotice,
                  ],
                ],
                const ServerVersionWarningCard(),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildComposerSection(BuildContext context) {
    final hasAttachments =
        ref.watch(attachedFilesProvider.select((files) => files.isNotEmpty)) ||
        ref.watch(
          contextAttachmentsProvider.select(
            (attachments) => attachments.isNotEmpty,
          ),
        );

    return RepaintBoundary(
      child: MeasureSize(
        onChange: (size) {
          if (!mounted) return;
          _handleComposerHeightChange(size.height);
        },
        child: SafeArea(
          top: false,
          left: false,
          right: false,
          bottom: !Platform.isAndroid,
          minimum: Platform.isAndroid
              ? EdgeInsets.zero
              : const EdgeInsets.only(bottom: Spacing.sm),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: Spacing.xl),
              const FileAttachmentWidget(),
              const ContextAttachmentWidget(),
              if (hasAttachments) const SizedBox(height: Spacing.sm),
              Consumer(
                builder: (context, composerRef, _) {
                  final isLoadingConversation = composerRef.watch(
                    isLoadingConversationProvider,
                  );
                  return ModernChatInput(
                    onSendMessage: _handleMessageSend,
                    enabled: debugCanSubmitChatMessageForTesting(
                      isLoadingConversation: isLoadingConversation,
                      isSavingTemporary: _isSavingTemporary,
                      isPreparingMessageSend: _messageSendAdmission.isHeld,
                    ),
                    bottomPadding: 0,
                    managesSystemKeyboardInset: Platform.isAndroid,
                    composerTextInsertionTargetId:
                        chatComposerTextInsertionTargetId,
                    onVoiceInput: null,
                    onVoiceCall: _handleVoiceCall,
                    onFileAttachment: _handleFileAttachment,
                    onServerFileAttachment: _handleServerFileAttachment,
                    onImageAttachment: _handleImageAttachment,
                    onCameraCapture: () =>
                        _handleImageAttachment(fromCamera: true),
                    onWebAttachment: _promptAttachWebpage,
                    onPastedAttachments: _handlePastedAttachments,
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final selectedModel = ref.watch(
      selectedModelProvider.select((model) => model),
    );
    ref.watch(
      chatVoiceModeControllerProvider.select(
        (voice) => (voice.isActive, voice.isCollapsed),
      ),
    );
    final isLoadingConversation = ref.watch(isLoadingConversationProvider);
    final activeConversation = ref.watch(activeConversationProvider);
    final hermesBot = chatHermesBotPresentation(activeConversation);
    final formattedModelName = selectedModel != null
        ? _formatModelDisplayName(selectedModel.name)
        : null;
    final modelLabel =
        hermesBot?.title ?? formattedModelName ?? l10n.chooseModel;
    final overlayStyle = theme.appBarTheme.systemOverlayStyle;

    // Whether the messages list can actually scroll (avoids showing button when not needed)
    final canScroll = _hasScrollableTranscriptContent();

    // Focus composer on app startup once (minimal delay for layout to settle)
    if (!_didStartupFocus) {
      _didStartupFocus = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(inputFocusTriggerProvider.notifier).increment();
      });
    }

    Widget page = PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) async {
        if (didPop) return;

        // First, if any input has focus, clear focus and consume back press.
        // Also covers native platform inputs which don't participate in
        // Flutter's focus tree (composerHasFocusProvider tracks them).
        final hasNativeFocus = ref.read(composerHasFocusProvider);
        final currentFocus = FocusManager.instance.primaryFocus;
        await handleChatBackNavigation(
          hasInputFocus:
              hasNativeFocus || (currentFocus != null && currentFocus.hasFocus),
          dismissInputFocus: _dismissComposerFocus,
          canNavigateBack: () => Navigator.of(context).canPop(),
          navigateBack: () => Navigator.of(context).pop(),
          confirmExit: () => ThemedDialogs.confirm(
            context,
            title: l10n.appTitle,
            message: l10n.endYourSession,
            confirmText: l10n.confirm,
            cancelText: l10n.cancel,
            isDestructive: Platform.isAndroid,
          ),
          isMounted: () => context.mounted,
          isAndroid: Platform.isAndroid,
          exitApplication: SystemNavigator.pop,
        );
      },
      child: AdaptiveScaffold(
        resizeToAvoidBottomInset: Platform.isAndroid ? false : null,
        // Replace Scaffold drawer with a tunable slide drawer for gentler snap behavior.
        drawerEnableOpenDragGesture: false,
        extendBodyBehindAppBar: true,
        appBar: _buildAdaptiveChatAppBar(
          context: context,
          ref: ref,
          isLoadingConversation: isLoadingConversation,
          modelLabel: modelLabel,
          hermesBot: hermesBot,
        ),
        body: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: _dismissComposerFocus,
          child: Stack(
            children: [
              Positioned.fill(
                child: Consumer(
                  builder: (context, listRef, _) {
                    return RepaintBoundary(
                      child: _buildMessagesList(theme, listRef),
                    );
                  },
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: ConduitChromeGradientFade.top(
                  contentHeight:
                      MediaQuery.viewPaddingOf(context).top +
                      conduitAdaptiveToolbarHeightOf(context),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: ConduitChromeGradientFade.bottom(
                  contentHeight: math.max(
                    0,
                    math.max(
                      _inputHeight - Spacing.xl,
                      MediaQuery.viewPaddingOf(context).bottom + Spacing.xxl,
                    ),
                  ),
                  fadeHeight: Spacing.md,
                ),
              ),
              Positioned(
                bottom: (_inputHeight > 0)
                    ? math.max(0, _inputHeight - Spacing.xl + Spacing.md)
                    : (Spacing.xxl + Spacing.xxxl),
                left: 0,
                right: 0,
                child: AnimatedSwitcher(
                  duration: context.motionDuration(
                    AnimationDuration.microInteraction,
                  ),
                  switchInCurve: AnimationCurves.microInteraction,
                  switchOutCurve: AnimationCurves.microInteraction,
                  transitionBuilder: (child, animation) {
                    final slideAnimation = Tween<Offset>(
                      begin: context.reduceMotion
                          ? Offset.zero
                          : const Offset(0, 0.15),
                      end: Offset.zero,
                    ).animate(animation);
                    return FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: slideAnimation,
                        child: child,
                      ),
                    );
                  },
                  child: ThemedSheets.hideNativeChromeWhileCovered(
                    child: Consumer(
                      builder: (context, scrollButtonRef, _) {
                        final hasMessages = scrollButtonRef.watch(
                          hasChatMessagesProvider,
                        );
                        return debugShouldRenderScrollToLatestForTesting(
                              requested: _showScrollToBottom,
                              hasScrollableContent: canScroll,
                              hasMessages: hasMessages,
                            )
                            ? Center(
                                key: const ValueKey('scroll_to_bottom_visible'),
                                child: AdaptiveTooltip(
                                  message: l10n.scrollToBottom,
                                  child: _buildScrollToBottomButton(context),
                                ),
                              )
                            : const SizedBox.shrink(
                                key: ValueKey('scroll_to_bottom_hidden'),
                              );
                      },
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _buildComposerSection(context),
              ),
              ChatVoiceModeOverlay(bottomOffset: _inputHeight),
            ],
          ),
        ),
      ),
    );
    if (overlayStyle != null) {
      page = AnnotatedRegion<SystemUiOverlayStyle>(
        value: overlayStyle,
        child: page,
      );
    }

    return page;
  }

  void _toggleResponsiveDrawer(BuildContext context) {
    final layout = SidebarDrawerControllerScope.maybeOf(context);
    if (layout == null) return;

    final isDrawerOpen = layout.isOpen;
    if (!isDrawerOpen) {
      _dismissComposerFocus();
    }
    layout.toggle();
  }

  Future<void> _openModelSelector(BuildContext context) async {
    try {
      final models = await ref
          .read(nativeSheetHydrationServiceProvider)
          .loadModels();
      if (!mounted || !context.mounted) return;
      await _showModelDropdown(context, ref, models);
    } catch (e) {
      DebugLogger.error(
        'model-load-failed',
        scope: 'chat/model-selector',
        error: e,
      );
    }
  }

  AdaptiveAppBar _buildAdaptiveChatAppBar({
    required BuildContext context,
    required WidgetRef ref,
    required bool isLoadingConversation,
    required String modelLabel,
    required HermesBotChatPresentation? hermesBot,
  }) {
    final activeConversation = ref.watch(activeConversationProvider);
    final isTemporary = ref.watch(temporaryChatEnabledProvider);
    final hasMessages = ref.watch(hasChatMessagesProvider);
    final showNewChatAction = activeConversation != null || hasMessages;
    final tintColor = context.conduitTheme.textPrimary;
    final trailingActionCount = (showNewChatAction ? 1 : 0) + 1;
    final maxModelWidth = resolveConduitAdaptiveLeadingPillWidth(
      context,
      trailingActionCount: trailingActionCount,
      maxWidth: kConduitAdaptiveToolbarMaxModelSelectorWidth,
    );
    // Hide the picker only for a true single-agent Hermes-only install. Mixed
    // setups must retain a way to switch back to an OpenWebUI model.
    final selectedModel = ref.watch(selectedModelProvider);
    final showModelDropdown = shouldShowChatModelDropdown(
      selectedModel: selectedModel,
      isHermesOnly: ref.watch(hermesOnlyModeProvider),
      isHermesBot: hermesBot != null,
    );
    final title = _buildChatToolbarTitle(
      context: context,
      isLoadingConversation: isLoadingConversation,
      modelLabel: modelLabel,
      maxModelWidth: maxModelWidth,
      showModelDropdown: showModelDropdown,
      hermesBot: hermesBot,
      hermesBotActive: hermesBot != null && ref.watch(isChatStreamingProvider),
    );
    final actionDescriptors = _buildAdaptiveToolbarActions(
      context: context,
      activeConversation: activeConversation,
      isHermes:
          (selectedModel != null && isHermesModel(selectedModel)) ||
          isNativeHermesConversation(activeConversation),
      isTemporary: isTemporary,
      hasMessages: hasMessages,
      showNewChatAction: showNewChatAction,
    );
    final actionWidgets = buildConduitAdaptiveToolbarActionWidgets([
      for (final action in actionDescriptors) action.widget,
    ]);
    final useNativeActionGroup =
        Platform.isIOS &&
        conduitSupportsNativeGlass() &&
        actionDescriptors.isNotEmpty &&
        actionDescriptors.length <= 3;
    final cupertinoTrailing = useNativeActionGroup
        ? ConduitNativeToolbarActionGroup(
            actions: [
              for (final action in actionDescriptors) action.nativeAction,
            ],
          )
        : Row(mainAxisSize: MainAxisSize.min, children: actionWidgets);
    return buildConduitCenteredAdaptiveAppBar(
      context: context,
      tintColor: tintColor,
      leading: ConduitAdaptiveAppBarIconButton(
        key: const ValueKey('chat-sidebar-toggle'),
        icon: Platform.isIOS ? CupertinoIcons.line_horizontal_3 : Icons.menu,
        iosSymbol: 'line.3.horizontal',
        onPressed: () => _toggleResponsiveDrawer(context),
        iconColor: tintColor,
      ),
      title: title,
      actions: actionWidgets,
      cupertinoTrailing: cupertinoTrailing,
      centerTitle: false,
    );
  }

  Widget _buildChatToolbarTitle({
    required BuildContext context,
    required bool isLoadingConversation,
    required String modelLabel,
    required double maxModelWidth,
    required bool showModelDropdown,
    required HermesBotChatPresentation? hermesBot,
    required bool hermesBotActive,
  }) {
    if (hermesBot != null) {
      return _HermesBotToolbarTitle(
        bot: hermesBot,
        maxWidth: maxModelWidth,
        active: hermesBotActive,
      );
    }
    return ConduitAdaptiveAppBarModelSelector(
      label: modelLabel,
      maxWidth: maxModelWidth,
      isLoading: isLoadingConversation,
      showChevron: showModelDropdown,
      onPressed: () => _openModelSelector(context),
    );
  }

  List<_ChatToolbarActionDescriptor> _buildAdaptiveToolbarActions({
    required BuildContext context,
    required Conversation? activeConversation,
    required bool isHermes,
    required bool isTemporary,
    required bool hasMessages,
    required bool showNewChatAction,
  }) {
    final actions = <_ChatToolbarActionDescriptor>[];
    final defaultTint = context.conduitTheme.textPrimary;

    final temporaryAction = _buildTemporaryChatToolbarAction(
      context: context,
      activeConversation: activeConversation,
      isHermes: isHermes,
      isTemporary: isTemporary,
      hasMessages: hasMessages,
      tintColor: defaultTint,
    );
    if (temporaryAction != null) {
      actions.add(temporaryAction);
    }

    if (showNewChatAction) {
      actions.add(
        _buildChatToolbarIconAction(
          icon: Platform.isIOS ? CupertinoIcons.create : Icons.add_comment,
          accessibilityLabel: AppLocalizations.of(context)!.newChat,
          tintColor: defaultTint,
          onPressed: _handleNewChat,
        ),
      );
    }

    final overflowButton = _buildChatToolbarOverflowAction(
      context: context,
      activeConversation: activeConversation,
      tintColor: defaultTint,
    );
    if (overflowButton != null) {
      actions.add(overflowButton);
    }

    return actions;
  }

  _ChatToolbarActionDescriptor _buildChatToolbarIconAction({
    required IconData icon,
    required String accessibilityLabel,
    required Color tintColor,
    required VoidCallback? onPressed,
  }) {
    final iosSymbol = conduitToolbarSfSymbolForIcon(icon);
    assert(iosSymbol != null);
    return _ChatToolbarActionDescriptor(
      widget: ConduitAdaptiveAppBarIconButton(
        icon: icon,
        iosSymbol: iosSymbol,
        iconColor: tintColor,
        onPressed: onPressed,
      ),
      nativeAction: ConduitNativeToolbarAction(
        iosSymbol: iosSymbol!,
        accessibilityLabel: accessibilityLabel,
        tintColor: tintColor,
        enabled: onPressed != null,
        onPressed: onPressed,
      ),
    );
  }

  _ChatToolbarActionDescriptor? _buildTemporaryChatToolbarAction({
    required BuildContext context,
    required Conversation? activeConversation,
    required bool isHermes,
    required bool isTemporary,
    required bool hasMessages,
    required Color tintColor,
  }) {
    final showTemporaryAction = shouldShowTemporaryChatAction(
      isHermes: isHermes,
      activeConversation: activeConversation,
    );
    if (!showTemporaryAction) {
      return null;
    }

    if (isTemporary && hasMessages && activeConversation != null) {
      return _buildChatToolbarIconAction(
        icon: Platform.isIOS ? CupertinoIcons.arrow_down_doc : Icons.save_alt,
        accessibilityLabel: AppLocalizations.of(context)!.saveChat,
        tintColor: tintColor,
        onPressed: _isSavingTemporary ? null : _saveTemporaryChat,
      );
    }

    return _buildChatToolbarIconAction(
      icon: isTemporary
          ? (Platform.isIOS ? CupertinoIcons.eye_slash : Icons.visibility_off)
          : (Platform.isIOS ? CupertinoIcons.eye : Icons.visibility_outlined),
      accessibilityLabel: AppLocalizations.of(context)!.temporaryChat,
      tintColor: isTemporary ? Colors.blue : tintColor,
      onPressed: () {
        ConduitHaptics.selectionClick();
        final current = ref.read(temporaryChatEnabledProvider);
        ref.read(temporaryChatEnabledProvider.notifier).set(!current);
      },
    );
  }

  _ChatToolbarActionDescriptor? _buildChatToolbarOverflowAction({
    required BuildContext context,
    required Conversation? activeConversation,
    required Color tintColor,
  }) {
    final items = <AdaptivePopupMenuEntry>[];
    final callbacks = <Future<void> Function()>[];
    final nativeItems = <ConduitNativeToolbarMenuItem>[];

    void addItem({
      required String label,
      required Object icon,
      String? iosSymbol,
      bool isDestructive = false,
      required Future<void> Function() onSelected,
    }) {
      final index = callbacks.length;
      callbacks.add(onSelected);
      items.add(
        AdaptivePopupMenuItem<int>(
          value: index,
          label: label,
          icon: icon,
          isDestructive: isDestructive,
        ),
      );
      nativeItems.add(
        ConduitNativeToolbarMenuItem(
          label: label,
          iosSymbol: iosSymbol,
          isDestructive: isDestructive,
          onSelected: () => unawaited(onSelected()),
        ),
      );
    }

    final conversationActions =
        activeConversation != null && !isTemporaryChat(activeConversation.id)
        ? buildConversationActions(
            context: context,
            ref: ref,
            conversation: activeConversation,
          )
        : const <ConduitContextMenuAction>[];
    for (final action in conversationActions) {
      addItem(
        label: action.label,
        icon: _chatToolbarConversationActionIcon(action),
        iosSymbol: action.sfSymbol,
        isDestructive: action.destructive,
        onSelected: () async {
          action.onBeforeClose?.call();
          await action.onSelected();
        },
      );
    }

    if (items.isEmpty) {
      return null;
    }

    return _ChatToolbarActionDescriptor(
      widget: ConduitAdaptiveToolbarOverflowButton<int>(
        tintColor: tintColor,
        materialIcon: Icons.more_vert,
        items: items,
        onSelected: (index) {
          if (index < 0 || index >= callbacks.length) {
            return;
          }
          unawaited(callbacks[index]());
        },
      ),
      nativeAction: ConduitNativeToolbarAction(
        iosSymbol: 'ellipsis',
        accessibilityLabel: AppLocalizations.of(context)!.more,
        tintColor: tintColor,
        menuItems: nativeItems,
      ),
    );
  }

  Object _chatToolbarConversationActionIcon(ConduitContextMenuAction action) {
    final sfSymbol = action.sfSymbol;
    if (sfSymbol != null) {
      return conduitAdaptivePopupMenuIcon(
        iosSymbol: sfSymbol,
        materialIcon: action.materialIcon,
      );
    }
    return Platform.isIOS ? action.cupertinoIcon : action.materialIcon;
  }

  // Removed legacy save-before-leave hook; server manages chat state via background pipeline.

  Future<void> _showModelDropdown(
    BuildContext context,
    WidgetRef ref,
    List<Model> models,
  ) async {
    // Ensure keyboard is closed before presenting modal
    final hadFocus = ref.read(composerHasFocusProvider);
    _dismissComposerFocus();

    Future<void> restoreFocusIfNeeded() async {
      if (!mounted) return;
      if (hadFocus) {
        // Re-enable autofocus and bump trigger to restore composer focus + IME
        try {
          ref.read(composerAutofocusEnabledProvider.notifier).set(true);
        } catch (_) {}
        final cur = ref.read(inputFocusTriggerProvider);
        ref.read(inputFocusTriggerProvider.notifier).set(cur + 1);
      }
    }

    if (Platform.isIOS) {
      try {
        final selectedId = await ref
            .read(nativeSheetHydrationServiceProvider)
            .presentModelSelector(
              context,
              title: AppLocalizations.of(context)!.chooseModel,
              selectedModelId: ref.read(selectedModelProvider)?.id,
              models: models,
              allowsPinning: true,
              rethrowErrors: true,
            );
        if (!mounted) return;
        if (selectedId != null) {
          Model? selected;
          for (final model in models) {
            if (model.id == selectedId) {
              selected = model;
              break;
            }
          }
          ref.read(selectedModelProvider.notifier).set(selected);
        }
        await restoreFocusIfNeeded();
        return;
      } catch (_) {
        if (!mounted) {
          return;
        }
      }
    }

    if (!context.mounted) return;

    await ThemedSheets.showCustom<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => ModelSelectorSheet(models: models),
    );
    await restoreFocusIfNeeded();
  }
}

String _formatChatModelDisplayName(String name) {
  return name.trim();
}

({String? displayName, Model? matchedModel}) _resolveChatModelPresentation({
  required String? rawModel,
  String? fallbackModelName,
  required List<Model>? models,
  Map<String, Model>? modelLookup,
}) {
  final trimmedModel = rawModel?.trim();
  final trimmedFallback = fallbackModelName?.trim();
  final fallback = trimmedFallback == null || trimmedFallback.isEmpty
      ? null
      : trimmedFallback;
  if (trimmedModel == null || trimmedModel.isEmpty) {
    return (
      displayName: fallback == null
          ? null
          : _formatChatModelDisplayName(fallback),
      matchedModel: null,
    );
  }

  final matched = modelLookup?[trimmedModel];
  if (matched != null) {
    return (
      displayName: _formatChatModelDisplayName(matched.name),
      matchedModel: matched,
    );
  }

  if (models != null && modelLookup == null) {
    for (final model in models) {
      if (model.id == trimmedModel || model.name == trimmedModel) {
        return (
          displayName: _formatChatModelDisplayName(model.name),
          matchedModel: model,
        );
      }
    }
  }

  return (
    displayName: _formatChatModelDisplayName(fallback ?? trimmedModel),
    matchedModel: null,
  );
}

String? _messageModelNameFallback(ChatMessage message) {
  final raw = message.metadata?['modelName'] ?? message.metadata?['model_name'];
  final value = raw?.toString().trim();
  return value == null || value.isEmpty ? null : value;
}

Map<String, Model>? _buildChatModelLookup(
  List<Model>? models, {
  DirectModelRegistry? directModelRegistry,
}) {
  if (models == null || models.isEmpty) return null;
  final lookup = <String, Model>{};
  final trustedOpenWebUiWireModels = <String, Model>{};
  for (final model in models) {
    lookup[model.id] = model;
    lookup[model.name] = model;
    final binding = directModelRegistry?.resolve(model);
    final wireModelId = binding?.source == DirectModelSource.openWebUi
        ? binding?.openWebUiModelId
        : null;
    if (wireModelId != null && wireModelId.isNotEmpty) {
      trustedOpenWebUiWireModels[wireModelId] = model;
    }
  }
  // Apply trusted wire aliases after ordinary ids/names so a later untrusted
  // same-id server model cannot replace the current direct binding.
  lookup.addAll(trustedOpenWebUiWireModels);
  return lookup;
}

List<({bool hasUserBelow, bool hasAssistantBelow})> _buildChatBubbleAdjacency(
  List<ChatMessage> messages,
) {
  final result = List.filled(messages.length, (
    hasUserBelow: false,
    hasAssistantBelow: false,
  ));

  String? nextRelevantRole;
  for (var i = messages.length - 1; i >= 0; i--) {
    result[i] = (
      hasUserBelow: nextRelevantRole == 'user',
      hasAssistantBelow: nextRelevantRole == 'assistant',
    );

    final role = messages[i].role;
    if (role == 'user' || role == 'assistant') {
      nextRelevantRole = role;
    }
  }

  return result;
}

/// Whether an assistant row continues the response above it and so must not
/// repeat the avatar + model name.
///
/// [openGroupModelName] is the display model of the response currently being
/// grouped, or null when the row above was a user turn (or nothing). A
/// null/blank model name never groups — unknown identity is not evidence of a
/// shared speaker.
@visibleForTesting
bool debugAssistantRowContinuesGroupForTesting({
  required String? openGroupModelName,
  required String? displayModelName,
}) {
  final name = displayModelName?.trim();
  final open = openGroupModelName?.trim();
  if (name == null || name.isEmpty || open == null || open.isEmpty) {
    return false;
  }
  return name == open;
}

/// One row's contribution to the grouped-response pass.
typedef ChatGroupingRow = ({
  bool isUser,
  bool isSkipped,
  bool hasVersions,
  String? displayModelName,
});

/// Where a row sits in its grouped response: whether it paints the identity
/// header, whether it owns the completion action bar, and which rows the bar
/// acts on.
typedef ChatGroupingPlacement = ({
  bool showModelHeader,
  bool showActionBar,
  List<int> groupIndices,
});

/// Assigns every row to a grouped response and picks which member paints the
/// header and which owns the action bar.
///
/// A single Hermes turn lands as several assistant messages. Repeating the
/// avatar + model name and the copy/listen/regenerate bar for each one reads as
/// several answers rather than one, so the first member carries the header and
/// the last carries the bar.
///
/// [rows] is the transcript in display order. A row is `isSkipped` when it
/// renders no response of its own — archived variants (zero-size placeholders)
/// and restored Hermes decision cards. Skipped rows neither break a group nor
/// own its bar; treating them as breaks would re-show a header mid-response.
///
/// A `hasVersions` row keeps its own bar so its version switcher stays
/// reachable, and so acts as its own one-row action group. That does not
/// affect the header pass: header suppression is decided by the model name
/// alone, exactly as before grouped bars existed.
@visibleForTesting
List<ChatGroupingPlacement> debugResolveAssistantGroupingForTesting(
  List<ChatGroupingRow> rows,
) {
  // Display model of the response currently being grouped; null once a user
  // turn closes it. Drives header suppression only.
  String? openGroupModelName;
  // Members of the action group being accumulated. It tracks the header group
  // except that a versioned row is always alone in its own.
  var openActionGroup = <int>[];
  final groupByIndex = List<List<int>>.filled(rows.length, const <int>[]);
  final showModelHeader = List<bool>.filled(rows.length, false);
  final ownsActionBar = List<bool>.filled(rows.length, false);

  void closeActionGroup() {
    if (openActionGroup.isEmpty) return;
    final members = List<int>.unmodifiable(openActionGroup);
    for (final index in members) {
      groupByIndex[index] = members;
    }
    // The bar belongs at the bottom of the complete answer.
    ownsActionBar[members.last] = true;
    openActionGroup = <int>[];
  }

  for (var index = 0; index < rows.length; index++) {
    final row = rows[index];
    if (row.isUser) {
      closeActionGroup();
      openGroupModelName = null;
      continue;
    }
    if (row.isSkipped) {
      continue;
    }

    final continuesGroup = debugAssistantRowContinuesGroupForTesting(
      openGroupModelName: openGroupModelName,
      displayModelName: row.displayModelName,
    );
    showModelHeader[index] = !continuesGroup;
    openGroupModelName = row.displayModelName;

    if (!continuesGroup || row.hasVersions) {
      closeActionGroup();
    }
    openActionGroup.add(index);
    if (row.hasVersions) {
      closeActionGroup();
    }
  }
  closeActionGroup();

  return List<ChatGroupingPlacement>.unmodifiable([
    for (var index = 0; index < rows.length; index++)
      (
        showModelHeader: showModelHeader[index],
        showActionBar: ownsActionBar[index],
        groupIndices: groupByIndex[index],
      ),
  ]);
}

/// Moves Hermes tool statuses from a grouped response onto its first tool row.
/// Non-tool statuses stay on their original rows.
@visibleForTesting
List<List<ChatStatusUpdate>> debugGroupHermesToolStatusesForTesting(
  List<List<ChatStatusUpdate>> histories,
) {
  final tools = <ChatStatusUpdate>[];
  var owner = -1;
  for (var index = 0; index < histories.length; index++) {
    final rowTools = histories[index].where(_isHermesToolStatus).toList();
    if (owner < 0 && rowTools.isNotEmpty) owner = index;
    tools.addAll(rowTools);
  }
  if (tools.length < 2 || owner < 0) return histories;

  return List<List<ChatStatusUpdate>>.unmodifiable([
    for (var index = 0; index < histories.length; index++)
      if (index != owner)
        List<ChatStatusUpdate>.unmodifiable(
          histories[index].where((status) => !_isHermesToolStatus(status)),
        )
      else
        List<ChatStatusUpdate>.unmodifiable([
          for (final status in histories[index])
            if (!_isHermesToolStatus(status)) status,
          ...tools,
        ]),
  ]);
}

bool _isHermesToolStatus(ChatStatusUpdate status) =>
    status.action?.startsWith('hermes_tool_') ?? false;

@visibleForTesting
bool debugCanCollapseGroupedAssistantRowForTesting(
  ChatMessage message, {
  required bool showModelHeader,
  required bool showActionBar,
}) {
  final metadata = message.metadata;
  return !showModelHeader &&
      !showActionBar &&
      message.content.trim().isEmpty &&
      (message.attachmentIds?.isEmpty ?? true) &&
      (message.files?.isEmpty ?? true) &&
      (message.output?.isEmpty ?? true) &&
      (message.embeds?.isEmpty ?? true) &&
      message.statusHistory.isEmpty &&
      message.followUps.isEmpty &&
      message.codeExecutions.isEmpty &&
      message.sources.isEmpty &&
      message.error == null &&
      metadata?['hermesApproval'] == null &&
      metadata?['hermesDecision'] == null;
}

@immutable
class _ChatRowLayoutMetadata {
  const _ChatRowLayoutMetadata({
    required this.messageId,
    required this.displayModelName,
    required this.modelIconUrl,
    required this.versionModelNames,
    required this.versionModelIconUrls,
    required this.isArchivedVariant,
    required this.replacesArchivedAssistant,
    required this.showFollowUps,
    required this.showModelHeader,
    required this.showActionBar,
    required this.groupMessageIds,
  });

  final String messageId;
  final String? displayModelName;
  final String? modelIconUrl;
  final List<String?> versionModelNames;
  final List<String?> versionModelIconUrls;
  final bool isArchivedVariant;
  final bool replacesArchivedAssistant;
  final bool showFollowUps;

  /// Whether this assistant row paints its own avatar + model name.
  ///
  /// A single Hermes turn lands as several assistant messages, which would
  /// otherwise repeat the same identity header down the transcript. Runs of
  /// consecutive assistant rows sharing one model present as one grouped
  /// response, with only the first row carrying the header.
  final bool showModelHeader;

  /// Whether this assistant row paints the completion action bar.
  ///
  /// The counterpart to [showModelHeader]: the header sits on the first row of
  /// a grouped response and the bar on the last, so one answer shows one of
  /// each. Its actions apply to every row in [groupMessageIds].
  final bool showActionBar;

  /// Every assistant row in this row's grouped response, in display order.
  ///
  /// A single-element list for an ungrouped row, and empty for a row that owns
  /// no response of its own (user turns, archived variants, decision cards).
  final List<String> groupMessageIds;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _ChatRowLayoutMetadata &&
          messageId == other.messageId &&
          displayModelName == other.displayModelName &&
          modelIconUrl == other.modelIconUrl &&
          listEquals(versionModelNames, other.versionModelNames) &&
          listEquals(versionModelIconUrls, other.versionModelIconUrls) &&
          isArchivedVariant == other.isArchivedVariant &&
          replacesArchivedAssistant == other.replacesArchivedAssistant &&
          showFollowUps == other.showFollowUps &&
          showModelHeader == other.showModelHeader &&
          showActionBar == other.showActionBar &&
          listEquals(groupMessageIds, other.groupMessageIds);

  @override
  int get hashCode => Object.hash(
    messageId,
    displayModelName,
    modelIconUrl,
    Object.hashAll(versionModelNames),
    Object.hashAll(versionModelIconUrls),
    isArchivedVariant,
    replacesArchivedAssistant,
    showFollowUps,
    showModelHeader,
    showActionBar,
    Object.hashAll(groupMessageIds),
  );
}

@immutable
class _ChatListStableLayoutSignature {
  const _ChatListStableLayoutSignature(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _ChatListStableLayoutSignature && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

@immutable
class _ChatListStableLayoutCacheKey {
  const _ChatListStableLayoutCacheKey({
    required this.signature,
    required this.models,
    required this.apiService,
    required this.directModelRegistryRevision,
    required this.hermesBot,
  });

  final _ChatListStableLayoutSignature signature;
  final List<Model>? models;
  final ApiService? apiService;
  final int directModelRegistryRevision;
  final HermesBotChatPresentation? hermesBot;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _ChatListStableLayoutCacheKey &&
          signature == other.signature &&
          identical(models, other.models) &&
          identical(apiService, other.apiService) &&
          directModelRegistryRevision == other.directModelRegistryRevision &&
          hermesBot == other.hermesBot;

  @override
  int get hashCode => Object.hash(
    signature,
    identityHashCode(models),
    identityHashCode(apiService),
    directModelRegistryRevision,
    hermesBot,
  );
}

final class _ChatListStableLayoutCache {
  _ChatListStableLayoutMetadata? _metadata;
  _ChatListStableLayoutCacheKey? _key;
  List<ChatMessage>? _messages;
  List<Model>? _models;
  ApiService? _apiService;
  int? _directModelRegistryRevision;
  HermesBotChatPresentation? _hermesBot;
  int _signatureBuildCount = 0;

  void invalidate() {
    _metadata = null;
    _key = null;
    _messages = null;
    _models = null;
    _apiService = null;
    _directModelRegistryRevision = null;
    _hermesBot = null;
  }

  _ChatListStableLayoutMetadata resolve({
    required List<ChatMessage> messages,
    required List<Model>? models,
    required ApiService? apiService,
    required DirectModelRegistry directModelRegistry,
    HermesBotChatPresentation? hermesBot,
  }) {
    final cached = _metadata;
    final registryRevision = directModelRegistry.revision;
    // Scroll callbacks and other chrome-only rebuilds reuse the immutable
    // Riverpod message list. Return before constructing the O(messages ×
    // versions) structural signature in that overwhelmingly common path.
    if (cached != null &&
        identical(_messages, messages) &&
        identical(_models, models) &&
        identical(_apiService, apiService) &&
        _directModelRegistryRevision == registryRevision &&
        _hermesBot == hermesBot) {
      return cached;
    }

    _signatureBuildCount += 1;
    final nextKey = _ChatListStableLayoutCacheKey(
      signature: _buildChatListStableLayoutSignature(messages),
      models: models,
      apiService: apiService,
      directModelRegistryRevision: registryRevision,
      hermesBot: hermesBot,
    );
    _messages = messages;
    _models = models;
    _apiService = apiService;
    _directModelRegistryRevision = registryRevision;
    _hermesBot = hermesBot;
    if (cached != null && _key == nextKey) return cached;

    final next = _buildChatListStableLayoutMetadata(
      messages: messages,
      models: models,
      apiService: apiService,
      directModelRegistry: directModelRegistry,
      hermesBot: hermesBot,
    );
    _metadata = next;
    _key = nextKey;
    return next;
  }

  int get debugSignatureBuildCount => _signatureBuildCount;
}

@immutable
class _ChatListStableLayoutMetadata {
  const _ChatListStableLayoutMetadata({
    required this.rows,
    required this.indexByMessageId,
  });

  final List<_ChatRowLayoutMetadata> rows;
  final Map<String, int> indexByMessageId;
}

_ChatListStableLayoutSignature _buildChatListStableLayoutSignature(
  List<ChatMessage> messages,
) {
  final buffer = StringBuffer();
  for (final message in messages) {
    buffer
      ..write(message.id)
      ..write('\u0000')
      ..write(message.role)
      ..write('\u0000')
      ..write(message.model ?? '')
      ..write('\u0000')
      ..write(_messageModelNameFallback(message) ?? '')
      ..write('\u0000')
      ..write(message.attachmentIds?.length ?? 0)
      ..write('\u0000')
      ..write(message.files?.length ?? 0)
      ..write('\u0000')
      ..write(message.embeds?.length ?? 0)
      ..write('\u0000')
      ..write(message.output?.length ?? 0)
      ..write('\u0000')
      ..write(message.statusHistory.length)
      ..write('\u0000')
      ..write(message.followUps.length)
      ..write('\u0000')
      ..write(message.sources.length)
      ..write('\u0000')
      ..write(message.codeExecutions.length)
      ..write('\u0000')
      ..write(message.error == null ? 0 : 1)
      ..write('\u0000')
      ..write(message.metadata?['archivedVariant'] == true ? 1 : 0)
      ..write('\u0000')
      // Decision cards are skipped by the grouped-response pass, so the flag
      // is layout input just like `archivedVariant`.
      ..write(message.metadata?['restoredDesktopDecision'] == true ? 1 : 0)
      ..write('\u0000')
      ..write(message.versions.length);
    for (final version in message.versions) {
      buffer
        ..write('\u0000')
        ..write(version.model ?? '')
        ..write('\u0000')
        ..write(version.modelName ?? '');
    }
    buffer.writeln();
  }
  return _ChatListStableLayoutSignature(buffer.toString());
}

_ChatListStableLayoutMetadata _buildChatListStableLayoutMetadata({
  required List<ChatMessage> messages,
  required List<Model>? models,
  required ApiService? apiService,
  DirectModelRegistry? directModelRegistry,
  HermesBotChatPresentation? hermesBot,
}) {
  final modelLookup = _buildChatModelLookup(
    models,
    directModelRegistry: directModelRegistry,
  );
  final bubbleAdjacency = _buildChatBubbleAdjacency(messages);
  final rows = <_ChatRowLayoutMetadata>[];
  final indexByMessageId = <String, int>{};
  final presentations = <({String? displayName, Model? matchedModel})>[];
  final groupingRows = <ChatGroupingRow>[];

  for (var index = 0; index < messages.length; index++) {
    final message = messages[index];
    final isUser = message.role == 'user';
    final modelPresentation = !isUser && hermesBot != null
        ? (displayName: hermesBot.title, matchedModel: null)
        : _resolveChatModelPresentation(
            rawModel: message.model,
            fallbackModelName: _messageModelNameFallback(message),
            models: models,
            modelLookup: modelLookup,
          );
    presentations.add(modelPresentation);
    groupingRows.add((
      isUser: isUser,
      // Archived variants render as zero-size placeholders, and restored
      // decision cards carry no response text of their own, so neither breaks
      // a grouped response nor is a candidate to host its action bar.
      isSkipped:
          !isUser &&
          (message.metadata?['archivedVariant'] == true ||
              message.metadata?['restoredDesktopDecision'] == true),
      hasVersions: !isUser && message.versions.isNotEmpty,
      displayModelName: modelPresentation.displayName,
    ));
  }

  final grouping = debugResolveAssistantGroupingForTesting(groupingRows);

  for (var index = 0; index < messages.length; index++) {
    final message = messages[index];
    final isUser = message.role == 'user';
    indexByMessageId[message.id] = index;

    final modelPresentation = presentations[index];
    final versionModelNames = <String?>[];
    final versionModelIconUrls = <String?>[];
    for (final version in message.versions) {
      final versionPresentation = _resolveChatModelPresentation(
        rawModel: version.model,
        fallbackModelName: version.modelName,
        models: models,
        modelLookup: modelLookup,
      );
      versionModelNames.add(
        hermesBot?.title ?? versionPresentation.displayName,
      );
      versionModelIconUrls.add(
        hermesBot?.avatar ??
            resolveModelIconUrlForModel(
              apiService,
              versionPresentation.matchedModel,
            ),
      );
    }

    final adjacency = bubbleAdjacency[index];
    final isArchivedVariant =
        !isUser && (message.metadata?['archivedVariant'] == true);
    final showFollowUps =
        !isUser && !adjacency.hasUserBelow && !adjacency.hasAssistantBelow;
    final placement = grouping[index];

    rows.add(
      _ChatRowLayoutMetadata(
        messageId: message.id,
        displayModelName: modelPresentation.displayName,
        modelIconUrl:
            hermesBot?.avatar ??
            resolveModelIconUrlForModel(
              apiService,
              modelPresentation.matchedModel,
            ),
        versionModelNames: List<String?>.unmodifiable(versionModelNames),
        versionModelIconUrls: List<String?>.unmodifiable(versionModelIconUrls),
        isArchivedVariant: isArchivedVariant,
        showModelHeader: placement.showModelHeader,
        showActionBar: placement.showActionBar,
        groupMessageIds: List<String>.unmodifiable([
          for (final member in placement.groupIndices) messages[member].id,
        ]),
        replacesArchivedAssistant:
            !isUser &&
            index > 0 &&
            messages[index - 1].role == 'assistant' &&
            (messages[index - 1].metadata?['archivedVariant'] == true),
        showFollowUps: showFollowUps,
      ),
    );
  }

  return _ChatListStableLayoutMetadata(
    rows: List<_ChatRowLayoutMetadata>.unmodifiable(rows),
    indexByMessageId: Map<String, int>.unmodifiable(indexByMessageId),
  );
}

@visibleForTesting
bool debugShouldExposeScrollToLatestForTesting({
  required bool hasScrollableContent,
  required bool pinAutoFollowing,
  required bool freeScrolling,
  required bool bottomAnchorDetached,
  required bool currentlyShowing,
  required double distanceFromLatest,
  double showThreshold = 48,
  double hideThreshold = 12,
}) {
  // Scroll mode is the ownership source. The bottom-anchor flag is a derived
  // metric hint and can briefly clear against stale pin-support dimensions.
  final hasDetachedPresentation = freeScrolling;
  if (!hasScrollableContent || pinAutoFollowing || !hasDetachedPresentation) {
    return false;
  }
  return currentlyShowing
      ? distanceFromLatest > hideThreshold
      : distanceFromLatest > showThreshold;
}

@visibleForTesting
bool debugShouldRenderScrollToLatestForTesting({
  required bool requested,
  required bool hasScrollableContent,
  required bool hasMessages,
}) => requested && hasScrollableContent && hasMessages;

@visibleForTesting
bool debugShouldSettlePinImmediatelyForTesting({
  required bool transcriptWasEmpty,
}) => transcriptWasEmpty;

@visibleForTesting
bool debugShouldPrepositionPinnedTurnForTesting({
  required bool hasClients,
  required bool targetRowMounted,
  required bool prepositionAttempted,
}) => hasClients && !targetRowMounted && !prepositionAttempted;

@visibleForTesting
bool debugShouldHideTranscriptForInitialPinForTesting({
  required bool settleImmediately,
  required bool positionSettled,
}) => settleImmediately && !positionSettled;

@visibleForTesting
bool debugShouldApplyDeferredConversationMutationForTesting({
  required bool isMounted,
  required String? scheduledConversationId,
  required String? activeConversationId,
  required int scheduledGeneration,
  required int activeGeneration,
}) {
  return isMounted &&
      scheduledConversationId != null &&
      scheduledConversationId == activeConversationId &&
      scheduledGeneration == activeGeneration;
}

@visibleForTesting
bool debugShouldLoadOlderPageForTesting({
  required bool hasUserScrolled,
  required bool hasOlder,
  required bool isLoadingOlder,
  required bool anyOldestLoadedRowVisible,
}) =>
    hasUserScrolled && hasOlder && !isLoadingOlder && anyOldestLoadedRowVisible;

@visibleForTesting
bool debugCanSubmitChatMessageForTesting({
  required bool isLoadingConversation,
  required bool isSavingTemporary,
  required bool isPreparingMessageSend,
}) {
  return !isLoadingConversation &&
      !isSavingTemporary &&
      !isPreparingMessageSend;
}

@visibleForTesting
bool debugShouldConsumeScreenContextForTesting({
  required bool sendDispatched,
  required String submittedContext,
  required String? currentContext,
}) {
  return sendDispatched && currentContext == submittedContext;
}

@visibleForTesting
bool debugShouldRetryScreenContextForTesting({
  required bool sendDispatched,
  required String submittedContext,
  required String? currentContext,
  required bool sendAdmissionHeld,
  required bool isSavingTemporary,
  required bool isLoadingConversation,
}) {
  return !debugShouldConsumeScreenContextForTesting(
        sendDispatched: sendDispatched,
        submittedContext: submittedContext,
        currentContext: currentContext,
      ) &&
      !sendAdmissionHeld &&
      !isSavingTemporary &&
      !isLoadingConversation;
}

@visibleForTesting
Duration? debugScreenContextRetryDelayForTesting({
  required int completedRetries,
}) {
  return switch (completedRetries) {
    0 => const Duration(milliseconds: 250),
    1 => const Duration(milliseconds: 500),
    2 => const Duration(seconds: 1),
    _ => null,
  };
}

/// Owns the short admission window before a durable send has captured its
/// composer attachments. Releases are identity-fenced so completion of an
/// older send cannot unlock a newer send's admission window.
@visibleForTesting
final class ChatMessageSendAdmissionGuard {
  Object? _owner;

  bool get isHeld => _owner != null;

  Object? tryAcquire() {
    if (_owner != null) return null;
    final owner = Object();
    _owner = owner;
    return owner;
  }

  bool release(Object owner) {
    if (!identical(_owner, owner)) return false;
    _owner = null;
    return true;
  }
}

@visibleForTesting
bool debugShouldFollowStreamingForTesting({
  required bool hasRunningTurn,
  required bool isAnchoredToBottom,
  required bool isUserInteracting,
  required bool isExplicitNavigationInFlight,
  required bool wantsPinToTop,
  required bool followLatestRequested,
  required bool pinnedEndSpaceExhausted,
}) {
  if (!hasRunningTurn ||
      isUserInteracting ||
      isExplicitNavigationInFlight ||
      !followLatestRequested) {
    return false;
  }
  // A live pin is the scroll owner for its full lifetime. Even after the
  // measured end space reaches zero, following the physical footer would
  // advance the viewport on every streamed layout and recreate upward creep.
  if (wantsPinToTop) return false;
  return isAnchoredToBottom;
}

@visibleForTesting
bool debugShouldReleasePinnedTurnForManualNavigationForTesting({
  required bool pinActive,
  required bool userDragStarted,
  required bool latestRequested,
}) {
  if (!pinActive) return false;
  return userDragStarted || latestRequested;
}

@visibleForTesting
bool debugShouldPreservePinnedFirstTurnForConversationBindingForTesting({
  required bool pinActive,
  required String? previousConversationId,
  required String? nextConversationId,
}) {
  return pinActive &&
      previousConversationId == null &&
      nextConversationId != null;
}

@visibleForTesting
bool debugShouldSettlePinnedTurnForLifecycleForTesting({
  required bool pinActive,
  required ChatTurnPhase? assistantPhase,
}) {
  return pinActive && assistantPhase != ChatTurnPhase.running;
}

@visibleForTesting
bool debugShouldContinuePinReleaseForTesting({
  required bool pinActive,
  required bool isUserInteracting,
  required int releaseGeneration,
  required int currentGeneration,
}) {
  return !pinActive &&
      !isUserInteracting &&
      releaseGeneration == currentGeneration;
}

@visibleForTesting
double debugResolveLatestPresentationDistanceForTesting({
  required bool pinnedTurnActive,
  required bool userDetached,
  required double? pinnedDistance,
  required double physicalLatestDistance,
}) {
  if (pinnedDistance != null) return pinnedDistance;
  // A lazily unmounted pinned row is still the semantic latest target. Never
  // reinterpret the physical footer as latest and silently clear a real user
  // detachment while that target is temporarily unmeasurable.
  if (pinnedTurnActive && userDetached) return double.infinity;
  return physicalLatestDistance;
}

@visibleForTesting
bool debugShouldExposePinnedLatestOnDragForTesting({
  required bool pinnedTurnActive,
  required bool hasScrollableContent,
}) => pinnedTurnActive && hasScrollableContent;

@visibleForTesting
bool debugCompletionOwnsExplicitLatestNavigationForTesting({
  required int? completedGeneration,
  required int currentGeneration,
}) {
  return completedGeneration != null &&
      completedGeneration == currentGeneration;
}

@visibleForTesting
double resolveChatAnchoredEndSpaceExtent({
  required double availableExtent,
  required double contentExtentFromAnchor,
}) {
  if (!availableExtent.isFinite || !contentExtentFromAnchor.isFinite) {
    return 0;
  }
  return math.max(0, availableExtent - contentExtentFromAnchor);
}

bool _shouldKeepConversationBottomAnchoredOnInsetChange({
  required double previousBottomInset,
  required double nextBottomInset,
  required bool isAnchoredToBottom,
  required bool isUserInteractingWithScroll,
  required bool wantsPinToTop,
}) {
  const insetChangeEpsilon = 1.0;
  final insetChanged =
      (nextBottomInset - previousBottomInset).abs() > insetChangeEpsilon;
  return insetChanged &&
      isAnchoredToBottom &&
      !isUserInteractingWithScroll &&
      !wantsPinToTop;
}

@visibleForTesting
String debugBuildChatListStableLayoutSignatureForTesting(
  List<ChatMessage> messages,
) {
  return _buildChatListStableLayoutSignature(messages).value;
}

@visibleForTesting
Object debugCreateChatListStableLayoutCacheForTesting() =>
    _ChatListStableLayoutCache();

@visibleForTesting
int debugChatListStableLayoutSignatureBuildCountForTesting(Object cache) =>
    (cache as _ChatListStableLayoutCache).debugSignatureBuildCount;

/// One row of the cached layout metadata, as the layout tests read it.
typedef ChatListLayoutRowSummary = ({
  bool isArchivedVariant,
  bool showFollowUps,
  String? displayModelName,
  String? modelIconUrl,
  bool showModelHeader,
  bool showActionBar,
  List<String> groupMessageIds,
});

ChatListLayoutRowSummary _chatListLayoutRowSummary(
  _ChatRowLayoutMetadata row,
) => (
  isArchivedVariant: row.isArchivedVariant,
  showFollowUps: row.showFollowUps,
  displayModelName: row.displayModelName,
  modelIconUrl: row.modelIconUrl,
  showModelHeader: row.showModelHeader,
  showActionBar: row.showActionBar,
  groupMessageIds: row.groupMessageIds,
);

@visibleForTesting
List<ChatListLayoutRowSummary> debugResolveChatListStableLayoutCacheForTesting(
  Object cache,
  List<ChatMessage> messages, {
  required List<Model>? models,
  required DirectModelRegistry directModelRegistry,
}) {
  final metadata = (cache as _ChatListStableLayoutCache).resolve(
    messages: messages,
    models: models,
    apiService: null,
    directModelRegistry: directModelRegistry,
  );
  return metadata.rows.map(_chatListLayoutRowSummary).toList(growable: false);
}

@visibleForTesting
List<ChatListLayoutRowSummary> debugBuildChatListLayoutSummaryForTesting(
  List<ChatMessage> messages, {
  List<Model>? models,
  DirectModelRegistry? directModelRegistry,
  HermesBotChatPresentation? hermesBot,
}) {
  final metadata = _buildChatListStableLayoutMetadata(
    messages: messages,
    models: models,
    apiService: null,
    directModelRegistry: directModelRegistry,
    hermesBot: hermesBot,
  );
  return metadata.rows.map(_chatListLayoutRowSummary).toList(growable: false);
}

@visibleForTesting
({bool anchorActive, bool autoFollowing, String? userMessageId})
debugPinStateAfterManualNavigationForTesting() {
  const active = _PinToTopState.active(
    userMessageId: 'user-message',
    streamingMessageId: 'assistant-message',
  );
  final manual = active.cancelAutomaticFollow();
  return (
    anchorActive: manual.isActive,
    autoFollowing: manual.isAutoFollowing,
    userMessageId: manual.userMessageId,
  );
}

@visibleForTesting
bool debugShouldKeepConversationBottomAnchoredOnInsetChangeForTesting({
  required double previousBottomInset,
  required double nextBottomInset,
  required bool isAnchoredToBottom,
  required bool isUserInteractingWithScroll,
  required bool wantsPinToTop,
}) {
  return _shouldKeepConversationBottomAnchoredOnInsetChange(
    previousBottomInset: previousBottomInset,
    nextBottomInset: nextBottomInset,
    isAnchoredToBottom: isAnchoredToBottom,
    isUserInteractingWithScroll: isUserInteractingWithScroll,
    wantsPinToTop: wantsPinToTop,
  );
}

@visibleForTesting
bool debugShouldKeepConversationBottomAnchoredOnContentSizeChangeForTesting({
  required bool isAnchoredToBottom,
  required bool isUserInteractingWithScroll,
  required bool wantsPinToTop,
}) {
  return shouldKeepConversationBottomAnchoredOnContentSizeChange(
    isAnchoredToBottom: isAnchoredToBottom,
    isUserInteractingWithScroll: isUserInteractingWithScroll,
    wantsPinToTop: wantsPinToTop,
  );
}

@visibleForTesting
bool debugVisibleMessageIdsGainedForTesting({
  required Iterable<String> previous,
  required Iterable<String> current,
}) => _visibleMessageIdsGained(previous: previous, current: current);

bool _visibleMessageIdsGained({
  required Iterable<String> previous,
  required Iterable<String> current,
}) {
  final previousSet = previous is Set<String> ? previous : previous.toSet();
  return current.any((id) => !previousSet.contains(id));
}

@visibleForTesting
class MarkdownPrewarmThrottle {
  MarkdownPrewarmThrottle({this.delay = const Duration(milliseconds: 220)});

  final Duration delay;
  Timer? _timer;
  List<String> _pendingContents = const <String>[];

  void schedule(List<String> contents, ValueChanged<List<String>> onReady) {
    _pendingContents = contents;
    if (_timer?.isActive ?? false) return;
    _timer = Timer(delay, () {
      _timer = null;
      final pendingContents = _pendingContents;
      _pendingContents = const <String>[];
      if (pendingContents.isNotEmpty) onReady(pendingContents);
    });
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    _pendingContents = const <String>[];
  }
}

@visibleForTesting
List<int> debugSelectMarkdownPrewarmCandidateIndicesForTesting(
  List<ChatMessage> messages, {
  required Iterable<String> visibleMessageIds,
  int maxCount = 6,
}) {
  final metadata = _buildChatListStableLayoutMetadata(
    messages: messages,
    models: null,
    apiService: null,
  );
  return _selectMarkdownPrewarmCandidatesFromVisibleIds(
    messages: messages,
    layoutMetadata: metadata,
    visibleMessageIds: visibleMessageIds,
    maxCount: maxCount,
  );
}

List<int> _selectMarkdownPrewarmCandidatesFromVisibleIds({
  required List<ChatMessage> messages,
  required _ChatListStableLayoutMetadata layoutMetadata,
  required Iterable<String> visibleMessageIds,
  int maxCount = 6,
}) {
  if (messages.isEmpty || maxCount <= 0) {
    return const <int>[];
  }

  final indices = <int>[];
  final seen = <int>{};

  void addIndex(int index) {
    if (index < 0 ||
        index >= messages.length ||
        seen.contains(index) ||
        layoutMetadata.rows[index].isArchivedVariant) {
      return;
    }
    final message = messages[index];
    if (message.role != 'assistant') {
      return;
    }
    if (message.isStreaming) {
      return;
    }
    final content = message.content.trim();
    if (content.isEmpty || content.contains('data:image/')) {
      return;
    }
    seen.add(index);
    indices.add(index);
  }

  final visibleIndices =
      visibleMessageIds
          .map((id) => layoutMetadata.indexByMessageId[id])
          .whereType<int>()
          .toSet()
          .toList()
        ..sort();
  if (visibleIndices.isEmpty) {
    return const <int>[];
  }

  // Visible completed rows are the highest priority. Walk newest-to-oldest so
  // the live reading edge prewarms before nearby history.
  for (final index in visibleIndices.reversed) {
    addIndex(index);
    if (indices.length >= maxCount) {
      return List<int>.unmodifiable(indices);
    }
  }

  var before = visibleIndices.first - 1;
  var after = visibleIndices.last + 1;
  while (indices.length < maxCount &&
      (before >= 0 || after < messages.length)) {
    if (after < messages.length) addIndex(after++);
    if (indices.length >= maxCount) break;
    if (before >= 0) addIndex(before--);
  }

  return List<int>.unmodifiable(indices);
}

String _cheapMarkdownPrewarmContentSignature(String content) {
  if (content.isEmpty) {
    return '0:0:0:0:0';
  }
  final lastIndex = content.length - 1;
  final quarterIndex = content.length >> 2;
  final midIndex = content.length >> 1;
  final threeQuarterIndex = (content.length * 3) >> 2;
  return [
    content.length,
    content.codeUnitAt(0),
    content.codeUnitAt(quarterIndex),
    content.codeUnitAt(midIndex),
    content.codeUnitAt(threeQuarterIndex.clamp(0, lastIndex).toInt()),
    content.codeUnitAt(lastIndex),
  ].join(':');
}
