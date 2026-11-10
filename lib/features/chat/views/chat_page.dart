import 'package:material_ui/material_ui.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/l10n/app_localizations.dart';

import '../../../shared/theme/conduit_input_styles.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/platform_scroll_physics.dart';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show listEquals, visibleForTesting;
import 'package:conduit/core/services/haptic_service.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/semantics.dart' show SemanticsService;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dart:io' show Platform;
import 'dart:collection';
import 'dart:math' as math;

import '../../../shared/widgets/sidebar_layout_contract.dart';

import 'dart:async';

import 'package:conduit_core/features/chat/providers/chat_model_choice.dart';
import 'package:conduit_core/features/chat/models/model_selector_layout.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/primary_account_providers.dart';

import 'package:conduit_core/services/interaction_activity.dart';

import '../../../core/services/native_sheet_bridge.dart';
import '../../../core/services/native_sheet_hydration_service.dart';

import 'package:conduit_core/services/performance_profiler.dart';

import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/connectivity_service.dart';

import 'package:conduit_core/database/database_provider.dart';

import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/models/chat_transcript_window.dart';

import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/direct_connections/services/direct_chat_bridge.dart';
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/features/terminal/models/terminal_agent_model.dart'
    show isTerminalAgentModelId, terminalAgentDisplayName;
import 'package:conduit_core/features/terminal/providers/computer_providers.dart';

import '../../direct_connections/widgets/direct_mcp_message_interactions.dart';
import '../../terminal/widgets/computer_page.dart';

import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/chat/composer/openwebui_prompt_answers.dart';
import 'package:conduit_core/features/chat/providers/openwebui_chat_prompt_provider.dart';
import 'package:conduit_core/features/chat/providers/openwebui_prompt_resolution.dart';
import 'package:conduit_core/features/chat/providers/temporary_chat_save.dart';

import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/providers/hermes_background_work_providers.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/providers/hermes_todo_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_bot_chat.dart';
import 'package:conduit_core/features/hermes/services/hermes_decision_projection.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_local_document_trust_store.dart';
import 'package:conduit_core/features/hermes/services/hermes_message_mapper.dart';
import 'package:conduit_core/features/hermes/services/hermes_pending_decision_store.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit_core/features/librechat/models/librechat_model.dart'
    show isLibreChatModel;

import '../../hermes/widgets/hermes_background_work_chip.dart';
import '../../hermes/widgets/hermes_bot_avatar.dart';
import '../../hermes/widgets/hermes_context_usage_sheet.dart';
import '../../hermes/widgets/hermes_message_interactions.dart';
import '../../hermes/widgets/hermes_read_only_session_notice.dart';
import '../../hermes/widgets/hermes_todo_card.dart';
import '../widgets/live_connection_button.dart';
import '../../librechat/widgets/librechat_prompt_overlay.dart';
import '../../navigation/providers/chat_back_provider.dart';
import '../../navigation/utils/chat_list_back.dart';

import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_core/features/direct_connections/services/model_logo_catalog.dart'
    show installedModelLogoCatalog;
import 'package:conduit_core/utils/model_display_name.dart';
import 'package:conduit_core/utils/user_display_name.dart'
    show deriveGreetingName;

import '../../../core/utils/model_icon_utils.dart';
import '../../../shared/widgets/markdown/markdown_compile_service.dart';

import 'package:conduit_markdown/conduit_markdown.dart';

import '../../../platform/android_assistant_handler.dart';
import '../widgets/chat_branch_actions.dart';
import '../widgets/chat_export_sheet.dart';
import '../widgets/chat_comparison_widgets.dart';
import '../widgets/model_selector_sheet.dart';
import '../widgets/openwebui_chat_settings_sheet.dart';
import '../widgets/modern_chat_input.dart';
import '../widgets/user_message_bubble.dart';
import '../widgets/assistant_message_widget.dart' as assistant;
import '../widgets/file_attachment_widget.dart';
import '../widgets/context_attachment_widget.dart';
import '../widgets/server_file_picker_sheet.dart';
import '../services/clipboard_attachment_service.dart';
import '../services/file_attachment_service.dart';

import 'package:conduit_core/features/chat/services/chat_message_actions.dart';
import 'package:conduit_core/features/chat/services/historical_message_regeneration.dart';

import '../voice_mode/chat_voice_mode_controller.dart';
import '../voice_mode/chat_voice_mode_overlay.dart';
import '../voice_mode/voice_mode_error_text.dart';
import '../voice_call/presentation/voice_call_launcher.dart';
import '../../../core/services/media_upload_controller.dart';

import 'package:conduit_core/features/tools/providers/tools_providers.dart';

import '../../release_notes/widgets/release_notes_banner.dart';

import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/openwebui_chat_prompt.dart';

import 'package:conduit_core/features/chat/providers/context_attachments_provider.dart';

import '../../../shared/utils/adaptive_glass.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../shared/widgets/themed_sheets.dart';
import '../../../shared/widgets/measure_size.dart';
import '../../../shared/widgets/server_version_warning_card.dart';
import '../../../shared/widgets/adaptive_toolbar_components.dart';
import '../../../shared/widgets/chrome_gradient_fade.dart';
import '../../../shared/widgets/markdown/markdown_loading_skeleton.dart';
import '../../../shared/utils/conversation_context_menu.dart';

import 'package:conduit_core/features/chat/views/chat_bottom_anchor_controller.dart';
import 'package:conduit_core/features/chat/views/chat_timeline_render_model.dart';
import 'package:conduit_core/features/chat/views/chat_turn_render_state.dart';

import '../widgets/streaming_turn_footer.dart';
import '../widgets/openwebui_prompt_overlay.dart';
import '../widgets/openwebui_task_list.dart';
import '../widgets/chat_timeline_viewport.dart';
import '../widgets/chat_scroll_to_latest_button.dart';
import '../../../platform/frame_profiler.dart';

@visibleForTesting
bool? chatResizeToAvoidBottomInset({
  required bool isAndroid,
  required bool isIOSAppOnMac,
}) => isAndroid || isIOSAppOnMac ? false : null;

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
    required this.id,
    required this.widget,
    required this.nativeAction,
    this.icon,
  });

  /// Stable identity of the action, so the bar's grouped actions fade only
  /// the ones that change.
  final String id;
  final Widget widget;
  final ConduitNativeToolbarAction nativeAction;
  final IconData? icon;

  ConduitToolbarClusterItem get clusterItem => ConduitToolbarClusterItem(
    id: id,
    action: nativeAction,
    fallbackIcon: icon,
  );
}

/// How long a new chat's bar actions wait, after its first send, for the
/// conversation to exist before showing a chat's actions anyway.
const Duration kChatHeaderNewChatActionsHold = Duration(milliseconds: 1200);

/// Whether the header keeps a new chat's actions (the Temporary Chat toggle)
/// for now: the first message is on its way but the conversation it creates
/// does not exist yet, or exists only as the local placeholder the server's
/// chat will replace.
///
/// Its bar actions depend on that conversation (More needs it), so without
/// the hold the trailing glass stepped through every state in between:
/// toggle, toggle and New Chat, New Chat alone, then New Chat and More.
/// Holding lets them change once, to their final set. [holdExpired] ends the
/// hold should the conversation take unusually long (offline, say).
@visibleForTesting
bool chatHeaderHoldsNewChatActions({
  required bool hasMessages,
  required bool hasSettledConversation,
  required bool holdExpired,
}) => hasMessages && !hasSettledConversation && !holdExpired;

/// Whether [conversation] is the chat's own: a server chat, or a local one
/// the user chose to keep temporary. A local placeholder for a chat that is
/// being saved is not settled yet.
@visibleForTesting
bool chatHeaderConversationSettled({
  required Conversation? conversation,
  required bool temporaryChatEnabled,
}) =>
    conversation != null &&
    (temporaryChatEnabled || !isTemporaryChat(conversation.id));

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

const double _kScrollToLatestButtonSize = 40.0;

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
  bool temporaryChatEnforced = false,
  bool isLibreChat = false,
  bool isTemporary = false,
}) {
  if (isHermes) return false;
  // Temporary chats are Open WebUI's; a LibreChat chat is always saved. A
  // new chat still set to temporary offers the switch only to turn it off,
  // since LibreChat will not send it as it is.
  if (isLibreChat) return isTemporary && activeConversation == null;
  // The server keeps the chat temporary, and would refuse to save it.
  return !temporaryChatEnforced &&
      (activeConversation == null || isTemporaryChat(activeConversation.id));
}

@visibleForTesting
String? chatHermesBotTitle(Conversation? conversation) {
  return chatHermesBotPresentation(conversation)?.title;
}

@visibleForTesting
Widget debugBuildHermesBotToolbarTitleForTesting({
  required HermesBotChatPresentation bot,
  required double maxWidth,
  bool active = false,
}) => _HermesBotToolbarTitle(bot: bot, maxWidth: maxWidth, active: active);

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

/// What a Desktop chat's transcript refresh does with the read it made.
enum HermesTranscriptRefreshStep {
  /// Show the read.
  apply,

  /// Keep the chat as it is.
  keep,

  /// Read again now.
  retry,

  /// Read again once the reply running now ends.
  afterReply,
}

/// The step for a transcript read, given whether the chat on screen
/// changed while it was read ([shownChanged]), whether a reply streams now,
/// whether this read is already a retry, the authoritative message counts
/// on screen and in the read, and [shortened], which uses up the allowance
/// a change that shortened the chat gave (an undo) and says whether there
/// was one. It is asked only for a read that is compared.
@visibleForTesting
HermesTranscriptRefreshStep hermesTranscriptRefreshStep({
  required bool shownChanged,
  required bool streaming,
  required bool retried,
  required int shownCount,
  required int readCount,
  required bool Function() shortened,
}) {
  // A message sent, or a reply streamed, while the transcript was read is
  // not in it: replacing the chat now would drop it.
  if (shownChanged) {
    if (streaming) return HermesTranscriptRefreshStep.afterReply;
    return retried
        ? HermesTranscriptRefreshStep.keep
        : HermesTranscriptRefreshStep.retry;
  }
  final allowed = shortened();
  // A shorter read is taken only after a change that shortened the chat;
  // otherwise it is an incomplete one.
  if (shownCount > 0 && readCount < shownCount && !allowed) {
    return HermesTranscriptRefreshStep.keep;
  }
  return HermesTranscriptRefreshStep.apply;
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

  /// Whether the transcript has scrolled under the header, so the header
  /// names the chat above its model.
  final ValueNotifier<bool> _headerShowsTitle = ValueNotifier<bool>(false);

  /// Ends the hold that keeps a new chat's bar actions while its first send
  /// creates the conversation (see [chatHeaderHoldsNewChatActions]).
  Timer? _newChatActionsHoldTimer;
  bool _newChatActionsHoldExpired = false;

  bool _scrollToBottomVisibilitySyncScheduled = false;
  bool _scrollToBottomPrewarmPending = false;
  bool _isDeactivated = false;
  double _inputHeight = 0;
  final _voiceOverlayKey = GlobalKey();
  bool _didStartupFocus = false; // one-time auto-focus on startup
  String? _lastConversationId;
  int _conversationOwnerGeneration = 0;
  // The conversation a transcript drag started in.
  int _dragOwnerGeneration = 0;
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
  // Identity-stable render model and rowBuilder. The shell
  // rebuilds far more often than the transcript changes (drag setState,
  // keyboard insets, pin transitions); keeping these identities stable lets
  // the viewport's sliver delegate skip rebuilding every mounted row, and lets
  // the stable-layout cache hit its identity fast path.
  List<ChatMessage>? _timelineModelSource;
  int _timelineModelGeneration = -1;
  ChatTimelineRenderModel? _timelineModelMemo;
  ChatTimelineRenderModel? _rowBuilderTimeline;
  _ChatListStableLayoutMetadata? _rowBuilderLayout;
  bool _rowBuilderSuppressHaptics = false;
  ChatTimelineRowBuilder? _rowBuilderMemo;
  List<Object?> _rowRebuildKeysMemo = const <Object?>[];
  String? _cachedGreetingName;
  // Whose name [_cachedGreetingName] is: it never greets another account.
  PrimaryAccountRef? _greetingAccount;
  bool _greetingReady = false;
  ProviderSubscription<String?>? _screenContextSub;
  ProviderSubscription<bool>? _conversationLoadingSub;
  ProviderSubscription<bool>? _reviewerModeSub;
  ProviderSubscription<String?>? _conversationIdSub;
  ProviderSubscription<Object>? _authEpochSub;
  ProviderSubscription<ApiService?>? _apiOwnerSub;
  ProviderSubscription<AppDatabase?>? _databaseOwnerSub;
  ProviderSubscription<AsyncValue<HermesTranscriptChange>>?
  _hermesTranscriptSub;
  ProviderSubscription<bool>? _hermesStreamingSub;
  late final OpenWebUiLivePromptNotifier _livePromptNotifier;
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
  // A page summary waits until the page has chosen its first model, or it
  // would be sent on whichever model happens to be listed first.
  bool _initialModelChosen = false;
  String? _screenContextInFlight;
  Timer? _screenContextRetryTimer;
  String? _screenContextRetryContext;
  int _screenContextRetryAttempts = 0;

  bool get _wantsPinToTop => _pinToTopState.isActive;
  bool get _shouldAutoFollowPinnedTurn =>
      _pinToTopState.isActive && _pinToTopState.isAutoFollowing;
  String? get _pinnedUserMessageId =>
      _currentMessageId(_pinToTopState.userMessageId);

  /// The pinned reply, by the id it has now: a LibreChat turn swaps the ids
  /// minted here for the server's while it runs.
  String? get _pinnedStreamingMessageId =>
      _currentMessageId(_pinToTopState.streamingMessageId);

  String? _currentMessageId(String? id) => id == null
      ? null
      : ref.read(chatMessagesProvider.notifier).currentMessageId(id);

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
    _headerShowsTitle.value = chatHeaderShowsTitle(
      scrolledFromTop: metrics.pixels - metrics.minScrollExtent,
      currentlyShowing: _headerShowsTitle.value,
      contentOverflowsViewport: metrics.hasRealContentOverflow,
    );
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

    // A new chat starts without settings picked for the previous draft.
    ref.read(pendingOpenWebUiChatSettingsProvider.notifier).replace(const {});

    // Reset to default model for new conversations (fixes #296)
    restoreDefaultModel(ref);

    if (_timelineViewportController.hasClients) {
      _timelineViewportController.jumpToLatest();
    }
    _cancelPendingViewportNavigation();
    _clearPinToTopAnchor();
    _invalidateChatListStableLayoutMetadata();
    _isAnchoredToBottom = true;

    // Reset temporary chat state based on user preference
    ref.read(temporaryChatEnabledProvider.notifier).startNewChat();
  }

  bool _isSavingTemporary = false;

  /// Persists a temporary chat to the server, transitioning it
  /// into a permanent conversation (conduit_core's saveTemporaryChat).
  Future<void> _saveTemporaryChat() async {
    if (_isSavingTemporary) return;
    if (_messageSendAdmission.isHeld || ref.read(isChatStreamingProvider)) {
      return;
    }
    if (ref.read(activeConversationProvider) == null ||
        ref.read(apiServiceProvider) == null) {
      return;
    }
    final sourceConversationGeneration = _conversationOwnerGeneration;
    setState(() {
      _isSavingTemporary = true;
    });
    try {
      final outcome = await saveTemporaryChat(
        ref,
        isCurrentOwner: () =>
            mounted &&
            _conversationOwnerGeneration == sourceConversationGeneration,
      );
      if (!mounted) return;
      switch (outcome) {
        case TemporaryChatSaveOutcome.saved:
          AdaptiveSnackBar.show(
            context,
            message: AppLocalizations.of(context)!.chatSaved,
            type: AdaptiveSnackBarType.success,
          );
        case TemporaryChatSaveOutcome.failed:
          AdaptiveSnackBar.show(
            context,
            message: AppLocalizations.of(context)!.chatSaveFailed,
            type: AdaptiveSnackBarType.error,
          );
        case TemporaryChatSaveOutcome.skipped:
          break;
      }
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
    _livePromptNotifier = ref.read(openWebUiLivePromptProvider.notifier);

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
        _livePromptNotifier.cancel();
        _scheduleViewportOwnerChanged();
      }
    });
    _apiOwnerSub = ref.listenManual(apiServiceProvider, (previous, next) {
      if (!identical(previous, next)) {
        _livePromptNotifier.cancel();
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
        (change) =>
            unawaited(_refreshDesktopHermesTranscript(change.storedId)),
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

      // First, ensure a model is selected
      try {
        await _checkAndAutoSelectModel();
      } finally {
        _initialModelChosen = true;
      }
      if (!mounted) return;

      // The assistant can store a page to summarize before this page exists,
      // on a cold start, or while it chose its model. Send it now.
      final waitingContext = ref.read(screenContextProvider);
      if (waitingContext != null && waitingContext.isNotEmpty) {
        _resetScreenContextRetry(context: waitingContext);
        _scheduleScreenContextSubmission();
      }

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
    _livePromptNotifier.cancel();
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
    _headerShowsTitle.dispose();
    _newChatActionsHoldTimer?.cancel();
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

  Future<ChatSendPlaceholderHandle?> _handleDraftSend(
    String text,
    void Function(ChatSendPlaceholderHandle) onPrepared,
  ) {
    final committed = Completer<ChatSendPlaceholderHandle?>();
    unawaited(
      _sendMessage(
        text,
        includeComposerContext: true,
        onSendPrepared: onPrepared,
        onDraftCommitted: (handle) {
          if (!committed.isCompleted) committed.complete(handle);
        },
      ).then(
        (_) {
          if (!committed.isCompleted) committed.complete(null);
        },
        onError: (Object error, StackTrace stack) {
          if (!committed.isCompleted) committed.completeError(error, stack);
        },
      ),
    );
    return committed.future;
  }

  /// Sends the composer's message to the chosen models as one comparison turn.
  /// The result names the committed turn, so the composer can tell whether it
  /// still shows that chat. It is null when the turn was refused or not
  /// written, so the composer keeps the draft.
  Future<ChatSendPlaceholderHandle?> _handleCompareSend(
    String text,
    List<Model> models,
    void Function(ChatSendPlaceholderHandle) onPrepared,
  ) async {
    ChatSendPlaceholderHandle? committed;
    final result = await _sendMessage(
      text,
      includeComposerContext: true,
      compareModels: models,
      onSendPrepared: onPrepared,
      onComparisonCommitted: (handle) => committed = handle,
    );
    return result.dispatched ? committed : null;
  }

  Future<void> _refreshDesktopHermesTranscript(
    String storedId, {
    bool retried = false,
  }) async {
    final active = ref.read(activeConversationProvider);
    if (active == null ||
        !isNativeHermesConversation(active) ||
        active.metadata['hermesSessionId'] != storedId) {
      return;
    }
    final visibleTail = ref.read(chatMessagesProvider).lastOrNull;
    if (ref.read(isChatStreamingProvider) &&
        !isRestoredHermesDesktopRunningMessage(visibleTail)) {
      _pendingHermesTranscriptRefresh = storedId;
      return;
    }
    final service = ref.read(hermesApiServiceProvider);
    if (service is! HermesDesktopApiService) return;
    final generation = ++_hermesTranscriptRefreshGeneration;
    final shownBefore = ref.read(chatMessagesProvider);
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
          : hermesSyntheticModel(name: service.config.name);
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
      var messages =
          hermesMessagesToChatMessages(
            raw,
            modelId: model.id,
            trustedLocalDocumentKeys: trustedKeys,
            sensitiveValues: service.config.sensitiveValues,
          )..addAll(
            hermesPendingDesktopDecisionMessages(pending, modelId: model.id),
          );
      messages = restoreHermesDesktopRunningMessage(
        messages,
        sessionId: storedId,
        modelId: model.id,
        isRunning:
            service.turnStateFor(storedId) == HermesDesktopTurnState.running,
      );
      final currentMessages = ref.read(chatMessagesProvider);
      final shownChanged = !identical(currentMessages, shownBefore);
      final currentAuthoritativeCount = currentMessages
          .where(
            (message) =>
                message.metadata?['restoredDesktopDecision'] != true &&
                !isRestoredHermesDesktopRunningPlaceholder(message),
          )
          .length;
      final candidateAuthoritativeCount = messages
          .where(
            (message) =>
                message.metadata?['restoredDesktopDecision'] != true &&
                !isRestoredHermesDesktopRunningPlaceholder(message),
          )
          .length;
      final step = hermesTranscriptRefreshStep(
        shownChanged: shownChanged,
        streaming: ref.read(isChatStreamingProvider),
        retried: retried,
        shownCount: currentAuthoritativeCount,
        readCount: candidateAuthoritativeCount,
        // A change the user made may have shortened the chat: a compaction
        // (a Bot Chat's history leaves compacted rows out), or an undo it
        // did not see. Both marks are used up by the read that is compared,
        // longer or not: left for a later incomplete read, they would let
        // that one shorten the chat.
        shortened: () => [
          service.takeShortenedTranscript(storedId),
          service.takeCompactedTranscript(storedId),
        ].any((taken) => taken),
      );
      switch (step) {
        case HermesTranscriptRefreshStep.keep:
          return;
        case HermesTranscriptRefreshStep.afterReply:
          _pendingHermesTranscriptRefresh = storedId;
          return;
        case HermesTranscriptRefreshStep.retry:
          unawaited(_refreshDesktopHermesTranscript(storedId, retried: true));
          return;
        case HermesTranscriptRefreshStep.apply:
          break;
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
    if (!_initialModelChosen ||
        _screenContextSubmissionScheduled ||
        _screenContextInFlight != null) {
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
    List<Model>? compareModels,
    void Function(ChatSendPlaceholderHandle committed)? onComparisonCommitted,
    void Function(ChatSendPlaceholderHandle)? onSendPrepared,
    void Function(ChatSendPlaceholderHandle)? onDraftCommitted,
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
        compareModels: compareModels,
        onComparisonCommitted: onComparisonCommitted,
        onSendPrepared: onSendPrepared,
        onDraftCommitted: onDraftCommitted,
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
    List<Model>? compareModels,
    void Function(ChatSendPlaceholderHandle committed)? onComparisonCommitted,
    void Function(ChatSendPlaceholderHandle)? onSendPrepared,
    void Function(ChatSendPlaceholderHandle)? onDraftCommitted,
  }) async {
    final settlePinImmediately = debugShouldSettlePinImmediatelyForTesting(
      transcriptWasEmpty: ref.read(chatMessagesProvider).isEmpty,
    );
    dynamic selectedModel = ref.read(selectedModelProvider);

    // Resolve model on-demand if none selected yet
    if (selectedModel == null) {
      Model? fallback;
      var failed = false;
      try {
        fallback = await modelForUnpickedSend(ref.read);
      } catch (_) {
        failed = true;
      }
      if (!mounted) return false;
      // A model picked while that waited is the user's choice; the fallback
      // only stands in for none.
      selectedModel = ref.read(selectedModelProvider) ?? fallback;
      if (selectedModel == null) {
        // The draft stays in the composer: say why it was not sent.
        final l10n = AppLocalizations.of(context)!;
        AdaptiveSnackBar.show(
          context,
          message: failed ? l10n.failedToLoadModels : l10n.noModelsAvailable,
          type: AdaptiveSnackBarType.error,
        );
        return false;
      }
      ref.read(selectedModelProvider.notifier).set(selectedModel);
    }

    ChatSendPlaceholderHandle? pendingSend;
    var pendingSends = const <ChatSendPlaceholderHandle>[];
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
      if (compareModels != null) {
        // One admission for every model: the answers are siblings of the same
        // user message, so the first one anchors the turn's position.
        final handles = await durableCompareSend(
          ref,
          text,
          uploadedFileIds.isNotEmpty ? uploadedFileIds : null,
          models: compareModels,
          onAssistantPlaceholderCreated: onSendPrepared,
          toolIds: toolIds.isNotEmpty ? toolIds : null,
        );
        pendingSends = handles;
        onComparisonCommitted?.call(handles.first);
        _releaseMessageSendAdmission(sendOwner);
        _activatePinToTopAnchor(
          handles.first,
          settleImmediately: settlePinImmediately,
        );
      } else {
        var admissionConfirmed = false;
        final directBinding = ref
            .read(directModelRegistryProvider)
            .resolve(selectedModel);
        // A Hermes or device Direct turn says when it goes to its run; an
        // Open WebUI Direct one, sent through the server, does not.
        final signalsTurnStart =
            isHermesModel(selectedModel) ||
            directBinding?.source == DirectModelSource.device;
        // Every Direct binding is sent inline, with no outbox receipt.
        final usesOutbox =
            hasDurableOutbox &&
            !isHermesModel(selectedModel) &&
            directBinding == null;
        await durableSend(
          ref,
          text,
          uploadedFileIds.isNotEmpty ? uploadedFileIds : null,
          toolIds: toolIds.isNotEmpty ? toolIds : null,
          onAssistantPlaceholderCreated: (handle) {
            didDispatch = true;
            _releaseMessageSendAdmission(sendOwner);
            pendingSend = handle;
            onSendPrepared?.call(handle);
            _activatePinToTopAnchor(
              handle,
              settleImmediately: settlePinImmediately,
            );
          },
          onAdmissionCommitted: usesOutbox && onDraftCommitted != null
              ? (_) {
                  admissionConfirmed = true;
                  onDraftCommitted(pendingSend!);
                }
              : null,
          // A Hermes or Direct send lasts the whole turn: its words leave
          // the composer once the turn is handed to its run, not when an
          // approval or question that holds the turn open is answered.
          onTurnStarted: () {
            if (admissionConfirmed || pendingSend == null) return;
            admissionConfirmed = true;
            onDraftCommitted?.call(pendingSend!);
          },
        );
        // Inline backends have no outbox receipt. Keep their draft until
        // the existing send path has accepted it successfully. A Hermes or
        // device Direct turn that never went to its run (a new session that
        // could not be made) keeps it too.
        if (!admissionConfirmed && pendingSend != null && !signalsTurnStart) {
          onDraftCommitted?.call(pendingSend!);
        }
      }
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
    } on ComparisonAdmissionException catch (error) {
      // Refused before anything was written; the composer text is still there
      // for the user to adjust and try again.
      if (mounted) {
        AdaptiveSnackBar.show(
          context,
          message: comparisonAdmissionMessage(
            AppLocalizations.of(context)!,
            error,
            models: ref.read(modelsProvider).asData?.value,
          ),
          type: AdaptiveSnackBarType.error,
        );
      }
      return false;
    } on LibreChatTemporaryChatException {
      // Refused before anything was sent; the draft stays for once temporary
      // chat is off.
      if (mounted) {
        AdaptiveSnackBar.show(
          context,
          message: AppLocalizations.of(context)!.libreChatTemporaryChatOff,
          type: AdaptiveSnackBarType.error,
        );
      }
      return false;
    } on LibreChatReplyRunningException {
      // Refused before anything was written; the draft stays for once the
      // reply is done or stopped.
      if (mounted) {
        AdaptiveSnackBar.show(
          context,
          message: AppLocalizations.of(
            context,
          )!.chatDataControlsResponseRunning,
          type: AdaptiveSnackBarType.error,
        );
      }
      return false;
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
      for (final handle in pendingSends) {
        recoverFailedChatSend(ref, e, handle);
      }
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
                          child: AdaptiveProgressIndicator(strokeWidth: 2),
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
      final l10n = AppLocalizations.of(context)!;
      final message = error is VoiceCallStartException
          ? voiceModeErrorText(l10n, kind: error.kind, message: error.message)!
          : error is StateError
          ? error.message.toString()
          : l10n.errorMessage;
      AdaptiveSnackBar.show(
        context,
        message: message,
        type: AdaptiveSnackBarType.error,
      );
    }
  }

  void _prewarmVisibleMarkdownRows() {
    if (!mounted || _isDeactivated) return;

    final messages = ref.read(chatMessagesProvider);
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
      pinnedTurnPlaced: _pinnedTurnPlaced,
      contentBelowPinnedTurn:
          _timelineViewportController.liveDistanceFromLatest,
      showThreshold: _scrollButtonShowThreshold,
      hideThreshold: _scrollButtonHideThreshold,
    );
  }

  /// A pinned turn that has reached its place at the top (or stopped
  /// following, e.g. the user touched the transcript mid-move). Before that
  /// the transcript is still moving to it, and what lies below is not yet
  /// meaningful.
  bool get _pinnedTurnPlaced =>
      _wantsPinToTop &&
      (_pinToTopPositionSettled || !_shouldAutoFollowPinnedTurn);

  /// While a turn is pinned, the live distance to the end of the transcript
  /// can change with no scroll (a reply streaming on under the composer), so
  /// the button is re-decided whenever it moves; this is a single comparison
  /// until the decision actually flips.
  void _handleLatestDistanceChanged(double distance) {
    if (!mounted || _isDeactivated || !_pinnedTurnPlaced) return;
    final threshold = _showScrollToBottom
        ? _scrollButtonHideThreshold
        : _scrollButtonShowThreshold;
    if ((distance > threshold) == _showScrollToBottom) return;
    _scheduleScrollToBottomVisibilitySync();
  }

  bool _hasScrollableTranscriptContent() {
    return _timelineViewportController.hasRealContentOverflow;
  }

  double _messageListBottomPadding() {
    final voice = ref.read(chatVoiceModeControllerProvider);
    final voiceOverlayHeight = voice.isActive
        ? (voice.isCollapsed ? 72.0 : 180.0)
        : 0.0;
    // The measured composer includes transparent headroom for the scroll fade.
    // The last message already has its own bottom margin.
    return voice.isActive
        ? Spacing.lg + _inputHeight + voiceOverlayHeight
        : math.max(0, _inputHeight - Spacing.xl);
  }

  /// Distance from the bottom of the page body to the composer's top edge.
  ///
  /// The measured composer section includes [Spacing.xl] of transparent
  /// headroom above the composer itself. Before it is measured, assume a
  /// one-line composer above the home indicator.
  double _composerTopInset(BuildContext context) => _inputHeight > 0
      ? math.max(0, _inputHeight - Spacing.xl)
      : MediaQuery.viewPaddingOf(context).bottom + Spacing.xxl;

  /// The soft edge under the header: the transcript stays in view as it
  /// passes under the floating glass, easing into the page background behind
  /// the status bar.
  Widget _buildHeaderScrollEdge(BuildContext context) {
    return ConduitChromeGradientFade.top(
      contentHeight:
          MediaQuery.viewPaddingOf(context).top +
          conduitAdaptiveToolbarHeightOf(context),
    );
  }

  /// The same soft edge behind the floating composer.
  Widget _buildComposerScrollEdge(BuildContext context) {
    return ConduitChromeGradientFade.bottom(
      contentHeight: math.max(
        _composerTopInset(context),
        MediaQuery.viewPaddingOf(context).bottom + Spacing.xxl,
      ),
      fadeHeight: Spacing.md,
    );
  }

  /// User-initiated scroll to bottom (e.g. button tap).
  void _userScrollToBottom() {
    ConduitHaptics.selectionClick();
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
    FrameProfiler.instance.startFrameCadence();
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
    FrameProfiler.instance.stopFrameCadence(reason: reason);
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

    ref
        .read(openWebUiLivePromptProvider.notifier)
        .cancelForConversation(outgoingId);

    _conversationOwnerGeneration += 1;
    // Another chat: its own scroll decides whether the bar names it.
    _headerShowsTitle.value = false;
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
    final anchor = conversationId == null
        ? null
        : _savedScrollAnchors[conversationId];
    if (anchor != null) {
      _bottomAnchorController.detachByUser();
      _timelineScrollMode = _ChatTimelineScrollMode.freeScrolling;
      _initialScrollAnchor = anchor;
    } else {
      _timelineScrollMode = _ChatTimelineScrollMode.followingLatest;
      _initialScrollAnchor = null;
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
    _headerShowsTitle.value = false;
    _cancelExplicitLatestNavigation();
    _cancelPendingViewportNavigation();
    setState(() {
      _clearPinToTopAnchor();
      _timelineScrollMode = _ChatTimelineScrollMode.followingLatest;
      _showScrollToBottom = false;
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
    if (ref.read(chatMessagesProvider).isEmpty) return;
    final anchor = _timelineViewportController.captureTopVisibleAnchor();
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
    final assistantMessageId = _pinnedStreamingMessageId;
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
          _pinnedStreamingMessageId != assistantMessageId) {
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
    // A reply already longer than the screen now runs on under the composer.
    _scheduleScrollToBottomVisibilitySync();
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
    const buttonSize = _kScrollToLatestButtonSize;
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
    // History is already in memory. Let the sliver lazily build the full list
    // so revealing earlier messages cannot change the scrollbar's range.
    final messages = watchRef.read(chatMessagesProvider);
    final pinnedAssistantId = _pinnedStreamingMessageId;
    final pinnedAssistantPhase = pinnedAssistantId == null
        ? null
        : watchRef.watch(
            chatMessageByIdProvider(pinnedAssistantId).select(
              (message) =>
                  message == null ? null : chatTurnPhaseForMessage(message),
            ),
          );
    _schedulePinnedTurnLifecycleReconciliation(pinnedAssistantPhase);
    final isLoadingConversation = watchRef.watch(isLoadingConversationProvider);
    final showLoadingSkeleton = isLoadingConversation && messages.isEmpty;
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

    final viewportWidth = MediaQuery.sizeOf(context).width;
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final extentMemory = ChatRowExtentMemory.instance;
    ChatMessage? historyMessageAtRenderIndex(int renderIndex) {
      final sourceIndex = timeline.sourceIndexAtRenderIndex(renderIndex);
      if (sourceIndex == null ||
          sourceIndex < 0 ||
          sourceIndex >= timeline.historyMessages.length) {
        return null;
      }
      return timeline.historyMessages[sourceIndex];
    }

    bool? layoutRowIsArchived(String messageId) {
      final row = layoutMetadata.indexByMessageId[messageId];
      return row == null ? null : layoutMetadata.rows[row].isArchivedVariant;
    }

    String extentKeyFor(ChatMessage message) => ChatRowExtentMemory.keyFor(
      messageId: message.id,
      layoutSignature: Object.hash(
        message.content,
        message.isStreaming,
        message.statusHistory.length,
        message.followUps.length,
        message.attachmentIds?.length,
        message.files?.length,
        message.codeExecutions.length,
        message.sources.length,
        message.versions.length,
        layoutRowIsArchived(message.id),
      ),
      viewportWidth: viewportWidth,
      textScale: textScale,
    );
    double? estimateRowExtent(int renderIndex) {
      final message = historyMessageAtRenderIndex(renderIndex);
      if (message == null) return null;
      return extentMemory.lookup(extentKeyFor(message)) ??
          estimateChatRowExtent(
            text: message.content,
            viewportWidth: viewportWidth,
            textScale: textScale,
            isUser: message.role == 'user',
            attachmentCount: message.attachmentIds?.length ?? 0,
            imageCount: message.files?.length ?? 0,
            followUpCount: message.followUps.length,
          );
    }

    void rememberRowExtent(int renderIndex, double extent) {
      final message = historyMessageAtRenderIndex(renderIndex);
      if (message == null || message.isStreaming) return;
      extentMemory.record(extentKeyFor(message), extent);
    }

    return ChatTimelineViewport(
      controller: _timelineViewportController,
      ownerGeneration: _conversationOwnerGeneration,
      messageIds: messageIds,
      rowRebuildKeys: _rowRebuildKeysMemo,
      estimateRowExtent: estimateRowExtent,
      onRowExtentMeasured: rememberRowExtent,
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
      topContentInset: topPadding,
      bottomPadding: bottomPadding,
      horizontalPadding: Spacing.inputPadding,
      cacheExtent: _chatMessageScrollCachePixels,
      physics: platformAlwaysScrollablePhysics(context),
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
        _dragOwnerGeneration = _conversationOwnerGeneration;
        InteractionActivity.instance.beginInteraction();
        final pinnedTurnWasActive = _wantsPinToTop;
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
        // A viewport removed mid-drag ends it after the frame, possibly
        // after this page has gone or already released the hold.
        if (!mounted || !_isUserInteractingWithScroll) return;
        InteractionActivity.instance.endInteraction();
        _endScrollProfile(reason: 'idle');
        _isUserInteractingWithScroll = false;
        // A drag cut short by switching chats says nothing about where the
        // new chat should rest.
        if (_dragOwnerGeneration != _conversationOwnerGeneration) return;
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
      },
      onMetricsChanged: _handleViewportMetricsChanged,
      onLatestDistanceChanged: _handleLatestDistanceChanged,
      onPinEndSpaceChanged: _handlePinEndSpaceChanged,
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
          final bubble = UserMessageBubble(
            message: latestMessage,
            isUser: true,
            readOnly:
                rowRef.watch(activeConversationReadOnlyProvider) ||
                rowRef.watch(activeHermesSessionReadOnlyProvider),
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
            // LibreChat keeps its messages on its server, which a delete
            // here would not reach: the next sync would bring them back,
            // and a reply still running would put its turn back at once.
            onDelete: _messagesDeletable(rowRef)
                ? () => _deleteMessageGroup(<String>[messageId])
                : null,
            onRegenerate: () => _regenerateMessage(messageId),
            allowsEdit: !rowRef.watch(activeChatUsesTerminalAgentProvider),
          );
          // An edited message keeps each version as a sibling in the stored
          // graph. The branch controls offer a way to continue from another
          // one; the row is left exactly as it was when there is nothing to
          // choose between.
          if (!userMessageMayHaveVersions(latestMessage) ||
              !rowRef.watch(chatBranchControlsProvider)) {
            return bubble;
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              bubble,
              ChatBranchSwitcher(messageId: messageId),
            ],
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
    // A shared chat of another user's, or a Hermes session another Hermes
    // app owns: its messages are read here, never changed.
    final readOnly =
        rowRef.watch(activeConversationReadOnlyProvider) ||
        rowRef.watch(activeHermesSessionReadOnlyProvider);
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
      readOnly: readOnly,
      onFollowUpSelected: readOnly ? null : _handleFollowUpSend,
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
      allowsRegenerate:
          !rowRef.watch(activeChatUsesTerminalAgentProvider) &&
          !isTerminalAgentModelId(latestMessage.model),
      onDelete: _messagesDeletable(rowRef)
          ? () => _deleteMessageGroup(
              groupIds.isEmpty ? <String>[messageId] : groupIds,
            )
          : null,
    );
  }

  /// Whether the open chat's messages can be deleted here: not a LibreChat
  /// chat's, which a delete here would not take off its server.
  bool _messagesDeletable(WidgetRef rowRef) => !rowRef.watch(
    activeConversationProvider.select(isLibreChatConversation),
  );

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
  /// Read on demand rather than cached with the layout metadata, whose
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
    // Prewarm at most twelve nearby rows in bounded worker batches.
    final candidateIndices = _selectMarkdownPrewarmCandidatesFromVisibleIds(
      messages: messages,
      layoutMetadata: layoutMetadata,
      visibleMessageIds: _timelineViewportController.visibleMessageIds,
      maxCount: 12,
    );
    final rawContents = <String>[];
    final signatureParts = <String>[];

    for (final index in candidateIndices) {
      final message = messages[index];
      final content = message.content.trim();
      rawContents.add(content);
      signatureParts.add(
        '$index:${message.id}:${_cheapMarkdownPrewarmContentSignature(content)}',
      );
    }

    if (rawContents.isEmpty) {
      _markdownPrewarmThrottle.cancel();
      _lastMarkdownPrewarmSignature = null;
      return;
    }

    final signature = signatureParts.join('|');
    if (signature == _lastMarkdownPrewarmSignature) {
      return;
    }

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
    final removedCount = chatMessageIdsRemovedByDelete(
      ref.read(chatMessagesProvider),
      messageIds,
    ).length;
    if (removedCount == 0) return;
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.deleteMessagesTitle,
      message: l10n.deleteMessagesMessage(removedCount),
      confirmText: l10n.delete,
      cancelText: l10n.cancel,
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;

    final outcome = await deleteChatMessageGroup(
      ref,
      messageIds,
      isStillCurrent: () => mounted,
    );
    if (outcome != ChatMessageDeleteOutcome.persistFailed || !mounted) return;
    AdaptiveSnackBar.show(
      context,
      message: AppLocalizations.of(context)!.errorMessage,
    );
  }

  void _regenerateMessage(String assistantMessageId) async {
    try {
      await regenerateHistoricalMessageById(ref, assistantMessageId);
    } catch (e) {
      DebugLogger.log('Regenerate failed: $e', scope: 'chat/page');
    }
  }

  // Inline editing handled by UserMessageBubble. Dialog flow removed.

  /// How much of the empty state's height the composer is taken to cover.
  ///
  /// The greeting centres above a single-line composer however long the
  /// draft grows, so typing never nudges it; only the keyboard moves it,
  /// which it does continuously because the area shrinks with the keyboard
  /// frame by frame (and the safe-area gap below the composer shrinks with
  /// it). The measured composer height arrives a frame late and in steps,
  /// so it is used only once a long draft would otherwise reach the
  /// greeting.
  double _emptyStateBottomReserve(BuildContext context) {
    final measured = _messageListBottomPadding();
    if (ref.read(chatVoiceModeControllerProvider).isActive) return measured;
    final singleLine =
        math.max(MediaQuery.paddingOf(context).bottom, Spacing.sm) +
        MediaQuery.textScalerOf(context)
            .scale(_emptyStateSingleLineComposerHeight);
    return math.max(singleLine, measured - _emptyStateComposerGrowthAllowance);
  }

  /// A one-line composer pill, unscaled.
  static const double _emptyStateSingleLineComposerHeight = 48;

  /// The new-chat greeting: Title 1 size and tracking, bold, as the large
  /// titles are.
  static const double _emptyStateGreetingFontSize = 28;
  static const double _emptyStateGreetingLineHeight = 34;
  static const double _emptyStateGreetingTracking = 0.38;

  /// How far the composer may grow past one line before the greeting makes
  /// room for it.
  static const double _emptyStateComposerGrowthAllowance = 120;

  Widget _buildEmptyState(ThemeData theme) {
    final l10n = AppLocalizations.of(context)!;
    // Whoever owns the Chats tab: an Open WebUI or a LibreChat user.
    final account = ref.watch(primaryAccountProvider);
    if (account != _greetingAccount) {
      _greetingAccount = account;
      _cachedGreetingName = null;
    }
    final user = ref.watch(primaryUserProvider);
    String? greetingName;
    if (user != null) {
      // "Hello, Robin", not a form letter's full name; the whole name when
      // it has no clear first name.
      final derived = deriveGreetingName(user.displayName);
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
    // A title, not a caption: 28 pt bold with Title 1 tracking, the weight
    // of the app's large titles, so the one line on an empty screen reads as
    // deliberate. The theme's display style keeps the display cut of the
    // system font at this size.
    final greetingStyle =
        (theme.textTheme.displaySmall ?? AppTypography.displaySmallStyle)
            .copyWith(
              fontSize: _emptyStateGreetingFontSize,
              height:
                  _emptyStateGreetingLineHeight / _emptyStateGreetingFontSize,
              letterSpacing: _emptyStateGreetingTracking,
              fontWeight: FontWeight.w700,
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
    final bottomPadding = _emptyStateBottomReserve(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // Sit at the optical centre between the header and the composer, a
        // little above the geometric one.
        final opticalLift = debugChatEmptyStateOpticalLiftForTesting(
          availableHeight: constraints.maxHeight - topPadding - bottomPadding,
        );
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
                bottomPadding + 2 * opticalLift,
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
          bottom: !PlatformUiCapabilities.isAndroid,
          minimum: PlatformUiCapabilities.isAndroid
              ? EdgeInsets.zero
              : const EdgeInsets.only(bottom: Spacing.sm),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: Spacing.xl),
              OpenWebUiTaskList(
                keyboardVisible: MediaQuery.viewInsetsOf(context).bottom > 0,
              ),
              const FileAttachmentWidget(),
              const ContextAttachmentWidget(),
              if (hasAttachments) const SizedBox(height: Spacing.sm),
              Consumer(
                builder: (context, composerRef, _) {
                  final isLoadingConversation = composerRef.watch(
                    isLoadingConversationProvider,
                  );
                  final activeConversation = composerRef.watch(
                    activeConversationProvider,
                  );
                  final activeConversationId = activeConversation?.id;
                  final pendingPromptIdentity = composerRef.watch(
                    chatMessagesProvider.select(
                      (messages) =>
                          findPendingOpenWebUiToolPrompt(messages)
                              ?.prompt
                              .identity,
                    ),
                  );
                  final persistedPrompt =
                      pendingPromptIdentity != null &&
                          debugCanUsePersistedOpenWebUiPromptForTesting(
                            isLoadingConversation: isLoadingConversation,
                            ownerConversationId: activeConversationId,
                            activeConversationId: activeConversationId,
                          ) &&
                          conversationUsesOpenWebUiStorage(
                            activeConversation,
                          ) &&
                          !isTemporaryChat(activeConversation?.id)
                      ? findPendingOpenWebUiToolPrompt(
                          composerRef.read(chatMessagesProvider),
                        )
                      : null;
                  final livePrompt = composerRef.watch(
                    openWebUiLivePromptProvider,
                  );
                  final matchingLivePrompt =
                      livePrompt != null &&
                          livePrompt.conversationId == activeConversationId
                      ? livePrompt
                      : null;
                  final pendingHermesPrompt = composerRef.watch(
                    chatMessagesProvider.select(
                      findPendingHermesComposerPrompt,
                    ),
                  );
                  final hermesPlan = composerRef
                      .watch(hermesActiveTodoProvider)
                      .asData
                      ?.value;
                  // Running subagents and processes; only their counts
                  // rebuild the composer. Listed only while this chat is
                  // in sight: the router keeps a hidden destination's page
                  // mounted with its tickers muted. The work sheet watches
                  // the list itself.
                  final hermesWork =
                      TickerMode.valuesOf(context).enabled
                      ? composerRef.watch(
                          hermesBackgroundWorkProvider.select(
                            (work) => (
                              agents: work?.runningSubagents ?? 0,
                              processes: work?.runningProcesses ?? 0,
                            ),
                          ),
                        )
                      : (agents: 0, processes: 0);
                  final pendingDirectMcpMetadata = composerRef.watch(
                    chatMessagesProvider.select(
                      findPendingDirectMcpComposerPrompt,
                    ),
                  );
                  composerRef.watch(directMcpApprovalRevisionProvider);
                  final pendingDirectMcpPrompt =
                      pendingDirectMcpMetadata == null
                      ? null
                      : findPendingDirectMcpComposerPrompt(
                          composerRef.read(chatMessagesProvider),
                          isLive: composerRef
                              .read(directRunRegistryProvider)
                              .hasLiveMcpApproval,
                        );
                  final pendingLibreChatPrompt = composerRef.watch(
                    chatMessagesProvider.select(
                      findPendingLibreChatComposerPrompt,
                    ),
                  );
                  // Only a run live in this app can be answered.
                  final pendingLibreChatAction = pendingLibreChatPrompt == null
                      ? null
                      : libreChatPendingActionFor(
                          composerRef,
                          pendingLibreChatPrompt.id,
                        );
                  final Widget? attachedOverlay;
                  if (persistedPrompt != null) {
                    attachedOverlay = OpenWebUiPromptOverlay(
                      key: ValueKey(persistedPrompt.prompt.identity),
                      prompt: persistedPrompt.prompt,
                      onAnswer: (answers) => _resolvePersistedOpenWebUiPrompt(
                        activeConversationId!,
                        persistedPrompt,
                        OpenWebUiToolCallAction.answer,
                        answers: answers,
                      ),
                      onDecision: (approved) =>
                          _resolvePersistedOpenWebUiPrompt(
                            activeConversationId!,
                            persistedPrompt,
                            openWebUiDecisionAction(
                              persistedPrompt.prompt,
                              approved,
                            ),
                          ),
                    );
                  } else if (matchingLivePrompt != null) {
                    attachedOverlay = OpenWebUiPromptOverlay(
                      key: ValueKey(matchingLivePrompt.prompt.identity),
                      prompt: matchingLivePrompt.prompt,
                      onAnswer: (answers) {
                        composerRef
                            .read(openWebUiLivePromptProvider.notifier)
                            .answer(
                              matchingLivePrompt.prompt.identity,
                              answers,
                            );
                      },
                      onDecision: (approved) {
                        final notifier = composerRef.read(
                          openWebUiLivePromptProvider.notifier,
                        );
                        if (matchingLivePrompt.prompt.kind ==
                            OpenWebUiComposerPromptKind.confirmation) {
                          notifier.decide(
                            matchingLivePrompt.prompt.identity,
                            approved,
                          );
                        } else {
                          notifier.cancel();
                        }
                      },
                    );
                  } else if (pendingHermesPrompt != null) {
                    attachedOverlay = HermesComposerPromptOverlay(
                      key: ValueKey(pendingHermesPrompt.id),
                      message: pendingHermesPrompt,
                    );
                  } else if (pendingDirectMcpPrompt != null) {
                    final approval =
                        pendingDirectMcpPrompt
                                .metadata![kDirectMcpApprovalMetadataKey]
                            as Map;
                    attachedOverlay = DirectMcpComposerPromptOverlay(
                      key: ValueKey(approval['id']),
                      message: pendingDirectMcpPrompt,
                    );
                  } else if (pendingLibreChatAction != null) {
                    final messageId = pendingLibreChatPrompt!.id;
                    attachedOverlay = LibreChatComposerPromptOverlay(
                      key: ValueKey(
                        '$messageId\u0000${pendingLibreChatAction.actionId}',
                      ),
                      action: pendingLibreChatAction,
                      onResolve: ({decisions, answers}) =>
                          resolveLibreChatPendingAction(
                            composerRef,
                            messageId,
                            decisions: decisions,
                            answers: answers,
                          ),
                    );
                  } else {
                    attachedOverlay = null;
                  }
                  if (isReadOnlySharedConversation(
                    activeConversation,
                    composerRef.watch(
                      currentUserProvider2.select((user) => user?.id),
                    ),
                  )) {
                    return _buildReadOnlyNotice(context);
                  }
                  final readOnlyHermesSource = watchHermesReadOnlySessionSource(
                    composerRef,
                    activeConversation,
                  );
                  if (readOnlyHermesSource != null) {
                    return HermesReadOnlySessionNotice(
                      source: readOnlyHermesSource,
                    );
                  }
                  return ModernChatInput(
                    onSendMessage: _handleMessageSend,
                    onSendDraft: _handleDraftSend,
                    onCompareSend: _handleCompareSend,
                    enabled: debugCanSubmitChatMessageForTesting(
                      isLoadingConversation: isLoadingConversation,
                      isSavingTemporary: _isSavingTemporary,
                      isPreparingMessageSend: _messageSendAdmission.isHeld,
                    ),
                    bottomPadding: 0,
                    managesSystemKeyboardInset:
                        PlatformUiCapabilities.isAndroid,
                    composerTextInsertionTargetId:
                        chatComposerTextInsertionTargetId,
                    // The agent's plan sits above any prompt card, and
                    // its background work above both.
                    attachedOverlay: withHermesBackgroundWork(
                      withHermesPlan(
                        attachedOverlay,
                        plan: hermesPlan,
                        chatKey: activeConversationId,
                      ),
                      agents: hermesWork.agents,
                      processes: hermesWork.processes,
                    ),
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

  /// Replaces the composer while viewing another user's chat from a shared
  /// folder; the server rejects every write, so no input is offered.
  Widget _buildReadOnlyNotice(BuildContext context) {
    final theme = context.conduitTheme;
    return Container(
      key: const ValueKey<String>('chat-read-only-notice'),
      margin: const EdgeInsets.symmetric(horizontal: Spacing.md),
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.sm,
      ),
      decoration: BoxDecoration(
        color: theme.surfaceContainer,
        borderRadius: BorderRadius.circular(AppBorderRadius.card),
        border: Border.all(color: theme.cardBorder, width: BorderWidth.thin),
      ),
      child: Row(
        children: [
          Icon(
            context.usesCupertinoChrome
                ? CupertinoIcons.eye
                : Icons.visibility_outlined,
            size: IconSize.sm,
            color: theme.iconSecondary,
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              AppLocalizations.of(context)!.readOnlySharedChat,
              style: AppTypography.bodySmallStyle.copyWith(
                color: theme.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _resolvePersistedOpenWebUiPrompt(
    String ownerConversationId,
    OpenWebUiPendingToolPrompt pending,
    OpenWebUiToolCallAction action, {
    Map<String, dynamic>? answers,
  }) => resolvePersistedOpenWebUiPrompt(
    ref,
    ownerConversationId: ownerConversationId,
    pending: pending,
    action: action,
    answers: answers,
    isMounted: () => mounted,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final selectedModel = ref.watch(
      selectedModelProvider.select((model) => model),
    );
    final voiceOverlay = ref.watch(
      chatVoiceModeControllerProvider.select(
        (voice) => (
          visible: voice.isActive || voice.phase == ChatVoiceModePhase.error,
          collapsed: voice.isCollapsed,
        ),
      ),
    );
    final isLoadingConversation = ref.watch(isLoadingConversationProvider);
    final activeConversation = ref.watch(activeConversationProvider);
    final hermesBot = chatHermesBotPresentation(activeConversation);
    final formattedModelName = selectedModel != null
        ? displayNameForModel(selectedModel)
        : null;
    final modelLabel =
        hermesBot?.title ?? formattedModelName ?? l10n.chooseModel;
    final overlayStyle = theme.appBarTheme.systemOverlayStyle;

    // Whether the messages list can actually scroll (avoids showing button when not needed)
    // A pinned reply that runs on under the composer is scrollable content
    // even before the next full measurement says so.
    final canScroll =
        _hasScrollableTranscriptContent() ||
        (_pinnedTurnPlaced &&
            _timelineViewportController.liveDistanceFromLatest >
                _scrollButtonHideThreshold);

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
        await handleChatBackNavigation(
          hasInputFocus: backClearsInputFocus(
            composerHasFocus: ref.read(composerHasFocusProvider),
          ),
          dismissInputFocus: _dismissComposerFocus,
          canNavigateBack: () => Navigator.of(context).canPop(),
          navigateBack: () => Navigator.of(context).pop(),
          openChatList: () =>
              ref.read(chatBackOpensListProvider) &&
              openChatListForBack(context),
          confirmExit: () => confirmAppExit(context),
          isMounted: () => context.mounted,
          isAndroid: chatBackIsAndroid,
          exitApplication: SystemNavigator.pop,
        );
      },
      child: AdaptiveScaffold(
        resizeToAvoidBottomInset: chatResizeToAvoidBottomInset(
          isAndroid: PlatformUiCapabilities.isAndroid,
          isIOSAppOnMac: PlatformInfo.isIOSAppOnMac,
        ),
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
                child: NativeContextMenuViewport(
                  bottomOverlay: voiceOverlay.visible ? _voiceOverlayKey : null,
                  padding: EdgeInsets.only(
                    top:
                        MediaQuery.viewPaddingOf(context).top +
                        conduitAdaptiveToolbarHeightOf(context),
                    bottom: math.max(0, _inputHeight - Spacing.xl),
                  ),
                  child: Consumer(
                    builder: (context, listRef, _) {
                      return RepaintBoundary(
                        child: _buildMessagesList(theme, listRef),
                      );
                    },
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: _buildHeaderScrollEdge(context),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _buildComposerScrollEdge(context),
              ),
              Positioned(
                bottom: _composerTopInset(context),
                left: 0,
                right: 0,
                child: ThemedSheets.hideNativeChromeWhileCovered(
                  child: Consumer(
                    builder: (context, scrollButtonRef, _) {
                      final hasMessages = scrollButtonRef.watch(
                        hasChatMessagesProvider,
                      );
                      final visible = debugShouldRenderScrollToLatestForTesting(
                        requested: _showScrollToBottom,
                        hasScrollableContent: canScroll,
                        hasMessages: hasMessages,
                      );
                      return ChatScrollToLatestButton(
                        key: const ValueKey('scroll_to_bottom'),
                        visible: visible,
                        // Sending: gone in a blink, before the message
                        // rises past it.
                        quickExit: _wantsPinToTop && !_pinnedTurnPlaced,
                        dimension: _kScrollToLatestButtonSize,
                        child: AdaptiveTooltip(
                          message: l10n.scrollToBottom,
                          child: _buildScrollToBottomButton(context),
                        ),
                      );
                    },
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _buildComposerSection(context),
              ),
              ChatVoiceModeOverlay(
                key: _voiceOverlayKey,
                bottomOffset: _inputHeight,
              ),
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

  bool _isOpeningModelSelector = false;

  /// Whether the pinned-model menu is up. The pill it hangs from keeps its
  /// label meanwhile, so this, not [_isOpeningModelSelector], rejects a
  /// second opening.
  bool _isModelMenuOpen = false;

  /// Opens the model picker. With [menuAnchor], the pill that was tapped, the
  /// account's pinned models come first as a native menu under it on iOS 26;
  /// its last item, or a tap with nothing pinned, opens the full list.
  Future<void> _openModelSelector(
    BuildContext context, {
    BuildContext? menuAnchor,
  }) async {
    // Model loading can take a moment on a cold cache. Show that on the
    // selector itself and reject overlapping taps instead of letting the
    // control look dead (#692).
    if (_isOpeningModelSelector ||
        _isModelMenuOpen ||
        ref.read(isLoadingConversationProvider)) {
      return;
    }
    setState(() => _isOpeningModelSelector = true);
    try {
      final loaded = await ref
          .read(nativeSheetHydrationServiceProvider)
          .loadModels();
      if (!mounted || !context.mounted) return;
      // A saved chat goes on only with its own backend: a LibreChat chat
      // takes only LibreChat's models, and no other chat takes them.
      final active = ref.read(activeConversationProvider);
      // The selected terminal's coding agents follow the account's models;
      // none are offered where an agent cannot answer.
      final agents = await readTerminalAgentModelsForPicker(ref);
      if (!mounted || !context.mounted) return;
      final models = [
        ...active == null
            ? loaded
            : [
                for (final model in loaded)
                  if (isLibreChatModel(model) ==
                      isLibreChatConversation(active))
                    model,
              ],
        ...agents,
      ];
      if (models.isEmpty) {
        // The native picker opens on nothing: say why there is no list.
        AdaptiveSnackBar.show(
          context,
          message: AppLocalizations.of(context)!.noModelsAvailable,
          type: AdaptiveSnackBarType.warning,
        );
        return;
      }
      if (menuAnchor != null && menuAnchor.mounted) {
        final openFullList = await _showPinnedModelMenu(menuAnchor, models);
        if (!openFullList || !mounted || !context.mounted) return;
      }
      // Loaded: the pill shows its model again while the list is up, which a
      // short list's sheet leaves in view.
      setState(() => _isOpeningModelSelector = false);
      await _showModelDropdown(context, ref, models);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'model-load-failed',
        scope: 'chat/model-selector',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted || !context.mounted) return;
      AdaptiveSnackBar.show(
        context,
        message: AppLocalizations.of(context)!.failedToLoadModels,
        type: AdaptiveSnackBarType.error,
      );
    } finally {
      if (mounted) {
        setState(() => _isOpeningModelSelector = false);
      }
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
    final hasSettledConversation = chatHeaderConversationSettled(
      conversation: activeConversation,
      temporaryChatEnabled: isTemporary,
    );
    // Through a first send the bar keeps the new chat's actions until the
    // conversation exists, then changes once to the chat's own.
    final holdsNewChatActions = _syncNewChatActionsHold(
      hasMessages: hasMessages,
      hasSettledConversation: hasSettledConversation,
    );
    // While held, the actions are a new chat's: no conversation, no messages.
    final actionsConversation = holdsNewChatActions ? null : activeConversation;
    final actionsSeeMessages = hasMessages && !holdsNewChatActions;
    final showNewChatAction = actionsConversation != null || actionsSeeMessages;
    final tintColor = context.conduitTheme.textPrimary;
    final controlExtent = conduitScaledControlExtent(context);
    final selectedModel = ref.watch(selectedModelProvider);
    final isHermes =
        (selectedModel != null && isHermesModel(selectedModel)) ||
        isNativeHermesConversation(activeConversation);
    final showConnectionIssue =
        !isHermes &&
        ref.watch(liveConnectionDisconnectedProvider).value == true;
    ({String label, bool enabled})? overflowModel;
    List<_ChatToolbarActionDescriptor> buildActions({bool compact = false}) =>
        _buildAdaptiveToolbarActions(
          context: context,
          activeConversation: actionsConversation,
          isHermes: isHermes,
          isTemporary: isTemporary,
          hasMessages: actionsSeeMessages,
          showNewChatAction: showNewChatAction,
          // The send has read the setting already, so the toggle stays
          // inert until its chat exists, however long that takes, even
          // after the bar's hold has ended.
          temporaryToggleLocked: hasMessages && !hasSettledConversation,
          newChatActionsHeld: holdsNewChatActions,
          compact: compact,
          overflowModel: overflowModel,
        );
    var actionDescriptors = buildActions();
    // On iOS 26 the trailing actions share one glass capsule, as the
    // sidebar's do.
    bool groupsActions() =>
        conduitSupportsNativeGlass() &&
        actionDescriptors.isNotEmpty &&
        actionDescriptors.length <= 3;
    double trailingWidth() {
      final count = actionDescriptors.length;
      final actionsWidth = count == 0
          ? 0.0
          : groupsActions()
          ? conduitToolbarClusterWidth(context, count)
          : count * controlExtent + (count - 1) * Spacing.sm;
      final connectionWidth = showConnectionIssue
          ? controlExtent + (count > 0 ? Spacing.sm : 0)
          : 0.0;
      return actionsWidth + connectionWidth;
    }

    // The pill sits at the leading edge, right after the sidebar button, so
    // a chat's title has all the room up to the trailing actions rather
    // than twice the room from the centre line to the nearer control. On
    // iOS it keeps the bar's least gap from the controls on either side;
    // Material sizes it from the number of actions.
    double modelWidth() {
      if (PlatformInfo.isIOS) {
        final room =
            MediaQuery.sizeOf(context).width -
            2 * Spacing.inputPadding -
            controlExtent -
            trailingWidth() -
            2 * kConduitBarTitleGap;
        return room
            .clamp(0.0, kConduitAdaptiveToolbarMaxModelSelectorWidth)
            .toDouble();
      }
      return resolveConduitAdaptiveLeadingPillWidth(
        context,
        trailingActionCount:
            actionDescriptors.length + (showConnectionIssue ? 1 : 0),
        maxWidth: kConduitAdaptiveToolbarMaxModelSelectorWidth,
      );
    }

    var maxModelWidth = modelWidth();
    // Keep the model picker while preserving secondary actions in More.
    if (maxModelWidth < controlExtent) {
      actionDescriptors = buildActions(compact: true);
      maxModelWidth = modelWidth();
    }
    // Hide the picker only for a true single-agent Hermes-only install. Mixed
    // setups must retain a way to switch back to an OpenWebUI model.
    final showModelDropdown = shouldShowChatModelDropdown(
      selectedModel: selectedModel,
      isHermesOnly: ref.watch(hermesOnlyModeProvider),
      isHermesBot: hermesBot != null,
    );
    if (showModelDropdown && maxModelWidth < TouchTarget.minimum) {
      overflowModel = (
        label: modelLabel,
        enabled: !isLoadingConversation && !_isOpeningModelSelector,
      );
      actionDescriptors = buildActions(compact: true);
      maxModelWidth = 0;
    }
    final title = _buildChatToolbarTitle(
      context: context,
      isLoadingConversation: isLoadingConversation,
      modelLabel: modelLabel,
      maxModelWidth: maxModelWidth,
      showModelDropdown: showModelDropdown,
      hermesBot: hermesBot,
      hermesBotActive: hermesBot != null && ref.watch(isChatStreamingProvider),
    );
    final actionWidgets = buildConduitAdaptiveToolbarActionWidgets([
      if (showConnectionIssue) const LiveConnectionButton(),
      for (final action in actionDescriptors) action.widget,
    ]);
    final cupertinoTrailing = groupsActions()
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showConnectionIssue) ...[
                const LiveConnectionButton(),
                const SizedBox(width: Spacing.sm),
              ],
              ConduitToolbarActionCluster(
                key: const ValueKey('chat-toolbar-actions'),
                items: [
                  for (final action in actionDescriptors) action.clusterItem,
                ],
              ),
            ],
          )
        : Row(mainAxisSize: MainAxisSize.min, children: actionWidgets);
    return buildConduitCenteredAdaptiveAppBar(
      context: context,
      tintColor: tintColor,
      leading: ConduitAdaptiveAppBarIconButton(
        key: const ValueKey('chat-sidebar-toggle'),
        // iOS shows a sidebar with "sidebar.left"; three lines read as a
        // web menu. Material keeps its own menu glyph.
        icon: Platform.isIOS ? CupertinoIcons.sidebar_left : Icons.menu,
        iosSymbol: 'sidebar.left',
        semanticLabel: AppLocalizations.of(context)!.sidebarButtonLabel,
        onPressed: () => _toggleResponsiveDrawer(context),
        iconColor: tintColor,
      ),
      title: title,
      actions: actionWidgets,
      cupertinoTrailing: cupertinoTrailing,
      // The pill starts beside the sidebar button, leaving the title room.
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
    return Builder(
      builder: (pillContext) => ConduitAdaptiveAppBarModelSelector(
        label: modelLabel,
        maxWidth: maxModelWidth,
        isLoading: isLoadingConversation || _isOpeningModelSelector,
        showChevron: showModelDropdown,
        title: chatHeaderTitle(ref.watch(activeConversationProvider)?.title),
        showsTitle: _headerShowsTitle,
        onPressed: () => _openModelSelector(context, menuAnchor: pillContext),
      ),
    );
  }

  /// Shows the account's pinned models as a native menu under [anchor], the
  /// model pill, with the chat's model checked and "All models…" last.
  /// Returns whether the full model list should open instead: when that item
  /// is chosen, or when there is no menu to show (no pinned model that is
  /// offered now, or no native menu on this platform).
  Future<bool> _showPinnedModelMenu(
    BuildContext anchor,
    List<Model> models,
  ) async {
    final pinned = availablePinnedModels(
      models: models,
      pinnedModelIds: ref.read(effectivePinnedModelIdsProvider),
    );
    if (pinned.isEmpty || !AdaptiveAnchoredMenu.canShow(anchor)) return true;

    const allModelsId = '\u0000all-models';
    final selectedId = ref.read(selectedModelProvider)?.id;
    // The chat and account the menu opens for: a pick is only for them.
    final pickTarget = captureChatModelPickTarget(ref);
    final allModelsLabel = AppLocalizations.of(context)!.modelMenuAllModels;
    String labelOf(Model model) {
      final name = displayNameForModel(model);
      return name.isEmpty ? model.id : name;
    }

    // The menu hangs from the pill, which keeps its label while it is up.
    setState(() {
      _isOpeningModelSelector = false;
      _isModelMenuOpen = true;
    });
    final String? choice;
    try {
      choice = await AdaptiveAnchoredMenu.show(
        anchorContext: anchor,
        items: [
          for (final model in pinned)
            AdaptiveAnchoredMenuItem(
              id: model.id,
              label: labelOf(model),
              checked: model.id == selectedId,
            ),
          AdaptiveAnchoredMenuItem(
            id: allModelsId,
            label: allModelsLabel,
            sfSymbol: 'square.stack.3d.up',
            startsSection: true,
          ),
        ],
      );
    } finally {
      _isModelMenuOpen = false;
    }
    if (!mounted) return false;
    if (choice == allModelsId) {
      setState(() => _isOpeningModelSelector = true);
      return true;
    }
    for (final model in pinned) {
      if (model.id != choice) continue;
      // As a pick in the full list: an explicit choice, which a late default
      // or New Chat must not replace.
      if (applyChatModelPick(ref, model, target: pickTarget)) {
        ref.read(isManualModelSelectionProvider.notifier).set(true);
      }
      break;
    }
    return false;
  }

  /// Whether the bar keeps a new chat's actions through its first send, and
  /// starts or ends the hold's deadline to match. Called from build.
  bool _syncNewChatActionsHold({
    required bool hasMessages,
    required bool hasSettledConversation,
  }) {
    if (!hasMessages || hasSettledConversation) {
      _newChatActionsHoldTimer?.cancel();
      _newChatActionsHoldTimer = null;
      _newChatActionsHoldExpired = false;
      return false;
    }
    _newChatActionsHoldTimer ??= Timer(kChatHeaderNewChatActionsHold, () {
      if (!mounted) return;
      setState(() => _newChatActionsHoldExpired = true);
    });
    return chatHeaderHoldsNewChatActions(
      hasMessages: hasMessages,
      hasSettledConversation: hasSettledConversation,
      holdExpired: _newChatActionsHoldExpired,
    );
  }

  List<_ChatToolbarActionDescriptor> _buildAdaptiveToolbarActions({
    required BuildContext context,
    required Conversation? activeConversation,
    required bool isHermes,
    required bool isTemporary,
    required bool hasMessages,
    required bool showNewChatAction,
    bool temporaryToggleLocked = false,
    bool newChatActionsHeld = false,
    bool compact = false,
    ({String label, bool enabled})? overflowModel,
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
      locked: temporaryToggleLocked,
      held: newChatActionsHeld,
    );
    if (temporaryAction != null) {
      actions.add(temporaryAction);
    }

    final computerAction = _buildComputerToolbarAction(
      context: context,
      isHermes: isHermes,
      tintColor: defaultTint,
    );
    if (computerAction != null) {
      actions.add(computerAction);
    }

    if (showNewChatAction) {
      actions.add(
        _buildChatToolbarIconAction(
          id: 'new-chat',
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
      collapsedActions: compact ? List.of(actions) : const [],
      overflowModel: overflowModel,
    );
    if (compact) actions.clear();
    if (overflowButton != null) {
      actions.add(overflowButton);
    }

    return actions;
  }

  _ChatToolbarActionDescriptor _buildChatToolbarIconAction({
    required String id,
    required IconData icon,
    required String accessibilityLabel,
    required Color tintColor,
    required VoidCallback? onPressed,
    String? iosSymbol,
    Key? key,
    bool labelFlutterButton = false,
  }) {
    final symbol = conduitToolbarSfSymbolForIcon(icon, iosSymbol: iosSymbol);
    assert(symbol != null);
    return _ChatToolbarActionDescriptor(
      id: id,
      icon: icon,
      widget: ConduitAdaptiveAppBarIconButton(
        key: key,
        icon: icon,
        iosSymbol: symbol,
        iconColor: tintColor,
        semanticLabel: labelFlutterButton ? accessibilityLabel : null,
        onPressed: onPressed,
      ),
      nativeAction: ConduitNativeToolbarAction(
        iosSymbol: symbol!,
        accessibilityLabel: accessibilityLabel,
        tintColor: tintColor,
        enabled: onPressed != null,
        onPressed: onPressed,
      ),
    );
  }

  /// Opens the live Desktop or Browser of the chat's terminal. Shown whenever
  /// the selected terminal offers one; discovering that never starts it.
  _ChatToolbarActionDescriptor? _buildComputerToolbarAction({
    required BuildContext context,
    required bool isHermes,
    required Color tintColor,
  }) {
    final selectedModel = ref.watch(selectedModelProvider);
    if (isHermes ||
        (selectedModel != null &&
            (isLibreChatModel(selectedModel) ||
                hasReservedDirectIdentity(selectedModel))) ||
        !ref.watch(computerAvailableProvider)) {
      return null;
    }
    return _buildChatToolbarIconAction(
      id: 'computer',
      key: const ValueKey('chat-computer-button'),
      icon: Platform.isIOS
          ? CupertinoIcons.desktopcomputer
          : Icons.desktop_windows_outlined,
      // The outline display, in the header glyphs' one outline family; the
      // filled desktopcomputer screen read heavier than its neighbours.
      iosSymbol: 'display',
      accessibilityLabel: AppLocalizations.of(context)!.computerTitle,
      labelFlutterButton: true,
      tintColor: tintColor,
      onPressed: () {
        _dismissComposerFocus();
        unawaited(openComputerWorkspace(context, ref));
      },
    );
  }

  _ChatToolbarActionDescriptor? _buildTemporaryChatToolbarAction({
    required BuildContext context,
    required Conversation? activeConversation,
    required bool isHermes,
    required bool isTemporary,
    required bool hasMessages,
    required Color tintColor,
    bool locked = false,
    bool held = false,
  }) {
    final selectedModel = ref.watch(selectedModelProvider);
    final showTemporaryAction = shouldShowTemporaryChatAction(
      isHermes: isHermes,
      activeConversation: activeConversation,
      temporaryChatEnforced: ref.watch(temporaryChatEnforcedProvider),
      isLibreChat:
          (selectedModel != null && isLibreChatModel(selectedModel)) ||
          isLibreChatConversation(activeConversation),
      isTemporary: isTemporary,
    );
    if (!showTemporaryAction) {
      return null;
    }

    if (isTemporary && hasMessages && activeConversation != null) {
      return _buildChatToolbarIconAction(
        id: 'save-chat',
        icon: Platform.isIOS ? CupertinoIcons.arrow_down_doc : Icons.save_alt,
        accessibilityLabel: AppLocalizations.of(context)!.saveChat,
        tintColor: tintColor,
        onPressed: _isSavingTemporary ? null : _saveTemporaryChat,
      );
    }

    final l10n = AppLocalizations.of(context)!;
    void setTemporary(bool value) {
      final current = ref.read(temporaryChatEnabledProvider);
      if (value == current) return;
      ConduitHaptics.selectionClick();
      ref.read(temporaryChatEnabledProvider.notifier).set(value);
      if (value) {
        // The empty state explains it on screen; say it aloud too.
        SemanticsService.sendAnnouncement(
          View.of(context),
          l10n.temporaryChatTooltip,
          Directionality.of(context),
        );
      }
    }

    return _buildChatToolbarIconAction(
      id: 'temporary-chat',
      icon: isTemporary
          ? (Platform.isIOS ? CupertinoIcons.eye_slash : Icons.visibility_off)
          : (Platform.isIOS ? CupertinoIcons.eye : Icons.visibility_outlined),
      // A dashed circle reads as "not kept", and fills while it is on. It
      // matches the regular weight of the other bar glyphs, where the eye
      // was heavier and read as "show/hide".
      iosSymbol: temporaryChatToolbarSymbol(isTemporary: isTemporary),
      accessibilityLabel: isTemporary
          ? '${l10n.temporaryChat}, ${l10n.enabled}'
          : l10n.temporaryChat,
      tintColor: tintColor,
      // A tap turns it on or off at once. Until the first message's chat
      // exists the toggle no longer changes the chat, whose send has already
      // read it. Through the bar's hold it keeps looking enabled, so the bar
      // does not flicker before it changes to the chat's actions; past the
      // hold, while the chat is still on its way, it shows as disabled.
      onPressed: !locked
          ? () => setTemporary(!ref.read(temporaryChatEnabledProvider))
          : held
          ? () {}
          : null,
    );
  }

  _ChatToolbarActionDescriptor? _buildChatToolbarOverflowAction({
    required BuildContext context,
    required Conversation? activeConversation,
    required Color tintColor,
    List<_ChatToolbarActionDescriptor> collapsedActions = const [],
    ({String label, bool enabled})? overflowModel,
  }) {
    final items = <AdaptivePopupMenuEntry>[];
    final callbacks = <Future<void> Function()>[];
    final nativeItems = <ConduitNativeToolbarMenuItem>[];

    void addItem({
      required String label,
      required Object icon,
      String? iosSymbol,
      bool isDestructive = false,
      bool enabled = true,
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
          enabled: enabled,
        ),
      );
      nativeItems.add(
        ConduitNativeToolbarMenuItem(
          label: label,
          iosSymbol: iosSymbol,
          isDestructive: isDestructive,
          enabled: enabled,
          onSelected: () => unawaited(onSelected()),
        ),
      );
    }

    if (overflowModel case final model?) {
      addItem(
        label: '${AppLocalizations.of(context)!.chooseModel}: ${model.label}',
        icon: conduitAdaptivePopupMenuIcon(
          iosSymbol: 'square.stack.3d.up',
          materialIcon: Icons.smart_toy_outlined,
        ),
        iosSymbol: 'square.stack.3d.up',
        enabled: model.enabled,
        onSelected: () => _openModelSelector(context),
      );
    }
    for (final descriptor in collapsedActions) {
      final action = descriptor.nativeAction;
      addItem(
        label: action.accessibilityLabel,
        icon: conduitAdaptivePopupMenuIcon(
          iosSymbol: action.iosSymbol,
          materialIcon: descriptor.icon!,
        ),
        iosSymbol: action.iosSymbol,
        enabled: action.enabled,
        onSelected: () async => action.onPressed?.call(),
      );
    }

    final conversationActions =
        activeConversation != null &&
            !isTemporaryChat(activeConversation.id) &&
            // Pin/rename/move/delete all fail server-side on another user's
            // chat (shared folder).
            !isReadOnlySharedConversation(
              activeConversation,
              ref.read(currentUserProvider2)?.id,
            )
        ? buildConversationActions(
            context: context,
            ref: ref,
            conversation: activeConversation,
          )
        : const <ConduitContextMenuAction>[];
    void addConversationAction(ConduitContextMenuAction action) {
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

    // Everything else comes first; destructive actions (Delete) end the menu.
    for (final action in conversationActions) {
      if (!action.destructive) addConversationAction(action);
    }

    // Per-chat Open WebUI settings: the editor behind Advanced, or a read-only
    // note when saved settings apply but cannot be edited from here.
    final settingsEntry = ref.watch(openWebUiChatSettingsMenuEntryProvider);
    if (settingsEntry != OpenWebUiChatSettingsMenuEntry.none) {
      final l10n = AppLocalizations.of(context)!;
      addItem(
        label: settingsEntry == OpenWebUiChatSettingsMenuEntry.editor
            ? l10n.chatSettingsTitle
            : l10n.chatSettingsApplied,
        icon: conduitAdaptivePopupMenuIcon(
          iosSymbol: 'slider.horizontal.3',
          materialIcon: Icons.tune,
        ),
        iosSymbol: 'slider.horizontal.3',
        onSelected: () async {
          if (!mounted) return;
          await showOpenWebUiChatSettings(context, ref);
        },
      );
    }

    // A Hermes chat's context window, token totals and plan usage, with
    // Compact now.
    final hermesSessionId = isNativeHermesConversation(activeConversation)
        ? activeConversation?.metadata['hermesSessionId']?.toString()
        : null;
    if (hermesSessionId != null &&
        hermesSessionId.isNotEmpty &&
        ref.watch(hermesApiServiceProvider) != null) {
      addItem(
        label: AppLocalizations.of(context)!.hermesContextUsage,
        icon: conduitAdaptivePopupMenuIcon(
          iosSymbol: 'gauge.with.dots.needle.33percent',
          materialIcon: Icons.data_usage_rounded,
        ),
        iosSymbol: 'gauge.with.dots.needle.33percent',
        onSelected: () async {
          if (!mounted) return;
          await showHermesContextUsageSheet(
            context,
            sessionId: hermesSessionId,
          );
        },
      );
    }

    // Export is an everyday action on the chat being read, so it does not
    // wait for Advanced; the account's own `chat.export` permission decides.
    final exportConversation = activeConversation;
    if (exportConversation != null && ref.watch(chatExportAvailableProvider)) {
      addItem(
        label: AppLocalizations.of(context)!.chatExportAction,
        icon: conduitAdaptivePopupMenuIcon(
          iosSymbol: 'arrow.down.doc',
          materialIcon: Icons.file_download_outlined,
        ),
        iosSymbol: 'arrow.down.doc',
        onSelected: () async {
          if (!mounted) return;
          await showChatExportSheet(context, ref, exportConversation);
        },
      );
    }

    for (final action in conversationActions) {
      if (action.destructive) addConversationAction(action);
    }

    if (items.isEmpty) {
      return null;
    }

    return _ChatToolbarActionDescriptor(
      id: 'more',
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
      // The native picker stays up while another chat can open under it.
      final pickTarget = captureChatModelPickTarget(ref);
      try {
        final selectedId = await ref
            .read(nativeSheetHydrationServiceProvider)
            .presentModelSelector(
              context,
              title: AppLocalizations.of(context)!.chooseModel,
              selectedModelId: ref.read(selectedModelProvider)?.id,
              models: models,
              allowsPinning: true,
              includeModelControls: true,
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
          if (selected != null) {
            // An explicit choice, which a late default or New Chat must not
            // replace.
            if (applyChatModelPick(ref, selected, target: pickTarget)) {
              ref.read(isManualModelSelectionProvider.notifier).set(true);
            }
          }
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

/// A model name as shown above replies: a name someone chose as written, a
/// raw id as its models.dev name or without its provider prefix.
String _formatChatModelDisplayName(String name) =>
    modelDisplayName(name: name, id: name, catalog: installedModelLogoCatalog);

/// The SF Symbol for the Temporary Chat toggle in the chat header.
@visibleForTesting
String temporaryChatToolbarSymbol({required bool isTemporary}) =>
    isTemporary ? 'circle.dashed.inset.filled' : 'circle.dashed';

/// The chat title the header shows once the transcript scrolls under it,
/// or `null` while the chat has no real title yet.
@visibleForTesting
String? chatHeaderTitle(String? title) {
  final trimmed = title?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  // The placeholder a chat carries until the server names it.
  if (trimmed.toLowerCase() == 'new chat') return null;
  return trimmed;
}

/// Whether the header should name the chat: once the first message has
/// slipped under the bar, or older messages wait above. Hysteresis keeps a
/// resting scroll from flickering the title in and out.
///
/// A transcript that fits on one screen never brings the title in: nothing
/// can be under the bar, and a first turn that is still settling into place
/// (its pinned end space reports a scroll offset) must not flash the title.
///
/// Once shown, only a scroll back to the top takes it away. While a sent
/// turn settles under the bar the transcript can read as fitting for a
/// while (the viewport grows as the keyboard leaves, and its scroll extent
/// catches up later), and the title must not blink out and back meanwhile.
/// The page clears [currentlyShowing] whenever it changes chats.
@visibleForTesting
bool chatHeaderShowsTitle({
  required double scrolledFromTop,
  required bool currentlyShowing,
  bool contentOverflowsViewport = true,
}) {
  if (currentlyShowing) return scrolledFromTop > 8.0;
  if (!contentOverflowsViewport) return false;
  return scrolledFromTop > 20.0;
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
    return (displayName: displayNameForModel(matched), matchedModel: matched);
  }

  if (models != null && modelLookup == null) {
    for (final model in models) {
      if (model.id == trimmedModel || model.name == trimmedModel) {
        return (displayName: displayNameForModel(model), matchedModel: model);
      }
    }
  }

  return (
    // A coding agent's reply names the agent, as the picker does.
    displayName:
        terminalAgentDisplayName(trimmedModel) ??
        _formatChatModelDisplayName(fallback ?? trimmedModel),
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
/// the last carries the bar. Across turns the header is shown only when the
/// responding model differs from the last announced one.
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
  // Model most recently announced by a header. Unlike [openGroupModelName] it
  // survives user turns, so consecutive answers from the same model stay
  // unlabeled and a header appears only when the responding model changes.
  String? lastAnnouncedModelName;
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
    showModelHeader[index] =
        !continuesGroup &&
        !debugAssistantRowContinuesGroupForTesting(
          openGroupModelName: lastAnnouncedModelName,
          displayModelName: row.displayModelName,
        );
    if (showModelHeader[index]) {
      lastAnnouncedModelName = row.displayModelName;
    }
    // A versioned row can display a historical version from another model,
    // which this pass cannot see, so the next answer must announce itself.
    if (row.hasVersions) lastAnnouncedModelName = null;
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
      message.error == null;
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
  bool pinnedTurnPlaced = false,
  double contentBelowPinnedTurn = 0,
  double showThreshold = 48,
  double hideThreshold = 12,
}) {
  bool beyond(double distance) =>
      currentlyShowing ? distance > hideThreshold : distance > showThreshold;
  // A turn pinned to the top is its own "latest" presentation, but a reply
  // longer than the screen runs on under the composer: whenever text lies
  // below, offer the way down to it, streaming or finished. The pinned
  // turn's text only grows, so the distance only grows and the button never
  // flickers while it streams.
  if (pinnedTurnPlaced) {
    return contentBelowPinnedTurn > 0 && beyond(contentBelowPinnedTurn);
  }
  // Scroll mode is the ownership source. The bottom-anchor flag is a derived
  // metric hint and can briefly clear against stale pin-support dimensions.
  final hasDetachedPresentation = freeScrolling;
  if (!hasScrollableContent || pinAutoFollowing || !hasDetachedPresentation) {
    return false;
  }
  return beyond(distanceFromLatest);
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

/// How far the empty chat's greeting sits above the geometric centre of
/// [availableHeight] (between the header and the composer): 4 %, the usual
/// optical-centre correction, so it does not read as sagging.
@visibleForTesting
double debugChatEmptyStateOpticalLiftForTesting({
  required double availableHeight,
}) => availableHeight <= 0 ? 0 : availableHeight * 0.04;

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
bool debugCanUsePersistedOpenWebUiPromptForTesting({
  required bool isLoadingConversation,
  required String? ownerConversationId,
  required String? activeConversationId,
}) => canUsePersistedOpenWebUiPrompt(
  isLoadingConversation: isLoadingConversation,
  ownerConversationId: ownerConversationId,
  activeConversationId: activeConversationId,
);

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

final _markdownPrewarmEligibilityCache = MarkdownPrewarmEligibilityCache();

class MarkdownPrewarmEligibilityCache {
  // Weak identity keys avoid rescanning immutable messages without retaining
  // trimmed copies that can double a loaded transcript's text heap.
  final _eligible = Expando<bool>();

  bool isEligible(ChatMessage message) =>
      _eligible[message] ??=
          message.role == 'assistant' &&
          !message.isStreaming &&
          message.content.trim().isNotEmpty &&
          !message.content.contains('data:image/');
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
    if (!_markdownPrewarmEligibilityCache.isEligible(messages[index])) {
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
  // Sparse eligible rows must not turn each scroll update into a history scan.
  for (
    var distance = 0;
    distance < maxCount &&
        indices.length < maxCount &&
        (before >= 0 || after < messages.length);
    distance += 1
  ) {
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
