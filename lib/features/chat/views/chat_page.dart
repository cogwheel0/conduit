import 'package:flutter/material.dart';
import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:conduit/l10n/app_localizations.dart';
import '../../../core/widgets/error_boundary.dart';
import '../../../shared/theme/conduit_input_styles.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/platform_scroll_physics.dart';
import 'package:flutter/services.dart';
import 'package:conduit/core/services/haptic_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent, ScrollDirection;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:super_sliver_list/super_sliver_list.dart';
import 'dart:io' show Platform;
import 'dart:math' as math;

import '../../../shared/widgets/responsive_drawer_layout.dart';
import 'dart:async';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/native_sheet_bridge.dart';
import '../../../core/services/native_sheet_hydration_service.dart';
import '../../../core/services/performance_profiler.dart';
import '../../../core/services/api_service.dart';
import '../../../core/services/connectivity_service.dart';
import '../../../core/services/settings_service.dart';
import '../../../core/database/database_provider.dart';
import '../../auth/providers/unified_auth_providers.dart';
import '../providers/chat_providers.dart';
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
import '../services/file_attachment_service.dart';
import '../services/chat_transport_dispatch.dart';
import '../services/historical_message_regeneration.dart';
import '../voice_mode/chat_voice_mode_controller.dart';
import '../voice_mode/chat_voice_mode_overlay.dart';
import '../voice_call/presentation/voice_call_launcher.dart';
import '../../../core/services/media_upload_controller.dart';
import '../../tools/providers/tools_providers.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/conversation.dart';
import '../../../core/models/folder.dart';
import '../../../core/models/model.dart';
import '../providers/context_attachments_provider.dart';
import '../../../shared/utils/adaptive_glass.dart';
import '../../../shared/widgets/conduit_loading.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../shared/widgets/themed_sheets.dart';
import '../../../shared/widgets/measure_size.dart';
import '../../../shared/widgets/adaptive_toolbar_components.dart';
import '../../../shared/widgets/chrome_gradient_fade.dart';
import '../../../shared/widgets/markdown/markdown_loading_skeleton.dart';
import '../../../shared/utils/conversation_context_menu.dart';

enum _PendingChatScrollActionKind { none, restore, initialBottom }

class _PendingChatScrollAction {
  const _PendingChatScrollAction._(this.kind, {this.restoreOffset = 0});

  const _PendingChatScrollAction.none()
    : this._(_PendingChatScrollActionKind.none);

  const _PendingChatScrollAction.restore(double restoreOffset)
    : this._(
        _PendingChatScrollActionKind.restore,
        restoreOffset: restoreOffset,
      );

  const _PendingChatScrollAction.initialBottom()
    : this._(_PendingChatScrollActionKind.initialBottom);

  final _PendingChatScrollActionKind kind;
  final double restoreOffset;

  bool get isNone => kind == _PendingChatScrollActionKind.none;
}

class _PinToTopState {
  const _PinToTopState._({
    required this.isActive,
    this.userMessageId,
    this.streamingMessageId,
  });

  const _PinToTopState.inactive() : this._(isActive: false);

  const _PinToTopState.active({
    required String userMessageId,
    required String streamingMessageId,
  }) : this._(
         isActive: true,
         userMessageId: userMessageId,
         streamingMessageId: streamingMessageId,
       );

  final bool isActive;
  final String? userMessageId;
  final String? streamingMessageId;

  _PinToTopState dismiss({bool preserveStreamingId = false}) {
    if (!preserveStreamingId) {
      return const _PinToTopState.inactive();
    }
    return _PinToTopState._(
      isActive: false,
      userMessageId: userMessageId,
      streamingMessageId: streamingMessageId,
    );
  }
}

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key});

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  static const double _scrollButtonShowThreshold = 300.0;
  static const double _scrollButtonHideThreshold = 150.0;
  static const int _initialBottomSettleMaxAttempts = 8;
  static const double _scrollCorrectionEpsilon = 1.0;

  final ScrollController _scrollController = ScrollController();
  final ListController _messageListController = ListController();
  bool _showScrollToBottom = false;
  Timer? _scrollDebounceTimer;
  bool _isDeactivated = false;
  double _inputHeight = 0;
  bool _didStartupFocus = false; // one-time auto-focus on startup
  String? _lastConversationId;
  final Map<String, double> _savedScrollOffsets = {};
  Timer? _markdownPrewarmTimer;
  int _markdownPrewarmGeneration = 0;
  String? _lastMarkdownPrewarmSignature;
  _PendingChatScrollAction _pendingScrollAction =
      const _PendingChatScrollAction.none();
  bool _isUserInteractingWithScroll = false;
  bool _isAnchoredToBottom = true;
  double? _lastBottomInset;
  String? _activeScrollProfileTaskKey;
  // Pin-to-top: scroll user message to top of viewport when sending
  _PinToTopState _pinToTopState = const _PinToTopState.inactive();
  GlobalKey _pinnedUserMessageKey = GlobalKey();
  _ChatListStableLayoutMetadata? _stableLayoutMetadata;
  _ChatListStableLayoutSignature? _stableLayoutMetadataSignature;
  List<Model>? _stableLayoutMetadataModels;
  ApiService? _stableLayoutMetadataApiService;
  double? _stableLayoutMetadataWidth;
  _ChatListStableLayoutMetadata? _lastExtentCacheInvalidationMetadata;
  String? _cachedGreetingName;
  bool _greetingReady = false;
  ProviderSubscription<String?>? _screenContextSub;
  ProviderSubscription<bool>? _reviewerModeSub;
  ProviderSubscription<String?>? _conversationIdSub;
  int _initialBottomSettleGeneration = 0;
  int _extentCacheInvalidationGeneration = 0;
  final Set<String> _pendingRowExtentInvalidationMessageIds = <String>{};
  bool _rowExtentInvalidationScheduled = false;

  bool get _wantsPinToTop => _pinToTopState.isActive;
  String? get _pinnedUserMessageId => _pinToTopState.userMessageId;
  String? get _pinnedStreamingId => _pinToTopState.streamingMessageId;

  String _formatModelDisplayName(String name) {
    return _formatChatModelDisplayName(name);
  }

  double _chatListCrossAxisExtent() {
    final viewportWidth = MediaQuery.of(context).size.width;
    return (viewportWidth - (Spacing.inputPadding * 2)).clamp(280.0, 960.0);
  }

  void _invalidateChatListStableLayoutMetadata() {
    _stableLayoutMetadata = null;
    _stableLayoutMetadataSignature = null;
    _stableLayoutMetadataModels = null;
    _stableLayoutMetadataApiService = null;
    _stableLayoutMetadataWidth = null;
    _lastExtentCacheInvalidationMetadata = null;
  }

  _ChatListStableLayoutMetadata _resolveChatListStableLayoutMetadata({
    required List<ChatMessage> messages,
    required List<Model>? models,
    required ApiService? apiService,
  }) {
    final crossAxisExtent = _chatListCrossAxisExtent();
    final signature = _buildChatListStableLayoutSignature(messages);
    final cached = _stableLayoutMetadata;
    if (cached != null &&
        _stableLayoutMetadataSignature == signature &&
        identical(_stableLayoutMetadataModels, models) &&
        identical(_stableLayoutMetadataApiService, apiService) &&
        _stableLayoutMetadataWidth == crossAxisExtent) {
      return cached;
    }

    final metadata = _buildChatListStableLayoutMetadata(
      messages: messages,
      models: models,
      apiService: apiService,
      crossAxisExtent: crossAxisExtent,
    );
    _stableLayoutMetadata = metadata;
    _stableLayoutMetadataSignature = signature;
    _stableLayoutMetadataModels = models;
    _stableLayoutMetadataApiService = apiService;
    _stableLayoutMetadataWidth = crossAxisExtent;
    return metadata;
  }

  int? _findMessageIndexForKey(
    Key key,
    _ChatListStableLayoutMetadata metadata,
  ) {
    if (key is! ValueKey<String>) {
      return null;
    }
    return metadata.indexByMessageKey[key.value];
  }

  bool validateFileSize(int fileSize, int maxSizeMB) {
    return fileSize <= (maxSizeMB * 1024 * 1024);
  }

  void startNewChat() {
    // Clear current conversation
    ref.read(chatMessagesProvider.notifier).clearMessages();
    ref.read(activeConversationProvider.notifier).clear();

    // Clear context attachments (web pages, YouTube, knowledge base docs)
    ref.read(contextAttachmentsProvider.notifier).clear();

    // Clear any pending folder selection
    ref.read(pendingFolderIdProvider.notifier).clear();

    // Reset to default model for new conversations (fixes #296)
    restoreDefaultModel(ref);

    // Save outgoing conversation's scroll position before resetting
    if (_lastConversationId != null && _scrollController.hasClients) {
      _savedScrollOffsets[_lastConversationId!] =
          _scrollController.position.pixels;
    }

    // Scroll to top
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }

    _pendingScrollAction = const _PendingChatScrollAction.none();
    _cancelPendingInitialBottomSettle();
    _pinToTopState = const _PinToTopState.inactive();
    _invalidateChatListStableLayoutMetadata();
    _endPinToTopInFlight = false;
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
    if (ref.read(isChatStreamingProvider)) return;
    _isSavingTemporary = true;
    try {
      final messages = ref.read(chatMessagesProvider);
      if (messages.isEmpty) return;

      final api = ref.read(apiServiceProvider);
      if (api == null) return;
      final activeConversation = ref.read(activeConversationProvider);
      if (activeConversation == null) return;

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
      final serverConversation = await api.createConversation(
        title: title,
        messages: messages,
        model: selectedModel?.id ?? '',
        systemPrompt: activeConversation.systemPrompt,
        folderId: activeConversation.folderId,
      );

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
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context)!.chatSaveFailed)),
        );
      }
    } finally {
      _isSavingTemporary = false;
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

    // Listen to scroll events to show/hide scroll to bottom button
    _scrollController.addListener(_onScroll);
    _screenContextSub = ref.listenManual(screenContextProvider, (_, next) {
      if (next == null || next.isEmpty) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(screenContextProvider.notifier).setContext(null);
        _handleMessageSend(
          'Here is the content of my screen:\n\n$next\n\nCan you summarize this?',
        );
      });
    });
    _reviewerModeSub = ref.listenManual(reviewerModeProvider, (_, next) {
      if (!next || ref.read(selectedModelProvider) != null) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _checkAndAutoSelectModel();
        }
      });
    });
    _conversationIdSub = ref.listenManual(
      activeConversationProvider.select((conv) => conv?.id),
      (_, next) => _handleConversationChanged(next),
      fireImmediately: true,
    );

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
    _reviewerModeSub?.close();
    _conversationIdSub?.close();
    _markdownPrewarmTimer?.cancel();
    _pendingRowExtentInvalidationMessageIds.clear();
    _endScrollProfile(reason: 'disposed');
    _messageListController.dispose();
    _scrollController.dispose();
    _scrollDebounceTimer?.cancel();
    super.dispose();
  }

  @override
  void deactivate() {
    _isDeactivated = true;
    _scrollDebounceTimer?.cancel();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _isDeactivated = false;
  }

  void _handleMessageSend(String text) async {
    if (ref.read(isLoadingConversationProvider)) {
      return;
    }

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
        return;
      }
      if (selectedModel == null) return;
    }

    try {
      // Get attached files and collect uploaded file IDs (including data URLs for images)
      final attachedFiles = ref.read(attachedFilesProvider);
      final uploadedFileIds = attachedFiles
          .where(
            (file) =>
                file.status == FileUploadStatus.completed &&
                file.fileId != null,
          )
          .map((file) => file.fileId!)
          .toList();

      // Get selected tools
      final toolIds = ref.read(selectedToolIdsProvider);
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
      );

      // Clear attachments after successful send
      ref.read(attachedFilesProvider.notifier).clearAll();

      if (wasOffline && hasDurableOutbox && mounted) {
        AdaptiveSnackBar.show(
          context,
          message: AppLocalizations.of(context)!.chatQueuedSnackBar,
          type: AdaptiveSnackBarType.info,
          duration: const Duration(seconds: 3),
        );
      }

      // Pin-to-top: the detection in _buildActualMessagesList will handle
      // scrolling to the user message once the streaming placeholder appears.
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
      ref.read(chatMessagesProvider.notifier).failLastStreamingAssistant(e);
    }
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
      final attachments = await fileService.pickFiles();
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
  Future<void> _handlePastedAttachments(
    List<LocalAttachment> attachments,
  ) async {
    if (attachments.isEmpty) return;

    DebugLogger.log(
      'Processing ${attachments.length} pasted attachment(s)',
      scope: 'chat/page',
    );

    // Add attachments to the list
    ref.read(attachedFilesProvider.notifier).addFiles(attachments);

    // Drive uploads via the shared media-upload controller for unified
    // retry/progress.
    for (final attachment in attachments) {
      try {
        final fileSize = await attachment.file.length();
        DebugLogger.log(
          'Pasted file: ${attachment.displayName}, size: $fileSize bytes',
          scope: 'chat/page',
        );
        unawaited(
          ref
              .read(mediaUploadControllerProvider)
              .upload(
                filePath: attachment.file.path,
                fileName: attachment.displayName,
                fileSize: fileSize,
              )
              .catchError((Object e) {
                DebugLogger.log('Pasted upload failed: $e', scope: 'chat/page');
              }),
        );
      } catch (e) {
        DebugLogger.log('Pasted upload prep failed: $e', scope: 'chat/page');
      }
    }

    DebugLogger.log(
      'Added ${attachments.length} pasted attachment(s)',
      scope: 'chat/page',
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
    _scheduleInitialScrollToBottom();
  }

  void _handleComposerHeightChange(double nextInputHeight) {
    if ((nextInputHeight - _inputHeight).abs() < _scrollCorrectionEpsilon) {
      return;
    }

    final shouldKeepBottomAnchored =
        _shouldKeepConversationBottomAnchoredOnComposerHeightChange(
          previousComposerHeight: _inputHeight,
          nextComposerHeight: nextInputHeight,
          isAnchoredToBottom: _isAnchoredToBottom,
          isUserInteractingWithScroll: _isUserInteractingWithScroll,
          wantsPinToTop: _wantsPinToTop,
        );

    setState(() => _inputHeight = nextInputHeight);

    if (!shouldKeepBottomAnchored) {
      return;
    }
    _scheduleInitialScrollToBottom();
  }

  void _handleMessageRowSizeChange(String messageId) {
    if (!mounted || _isDeactivated) {
      return;
    }

    _pendingRowExtentInvalidationMessageIds.add(messageId);
    _scheduleRowExtentInvalidation();
  }

  void _updateBottomAnchorTracking() {
    if (!_scrollController.hasClients) {
      _isAnchoredToBottom = true;
      return;
    }

    final hasScrollableContent = _hasScrollableContentForBottomButton();
    final distanceFromBottom = _distanceFromBottom();
    _isAnchoredToBottom =
        !hasScrollableContent ||
        distanceFromBottom <= _scrollButtonHideThreshold;
  }

  Future<void> _refreshActiveConversation() async {
    final api = ref.read(apiServiceProvider);
    final active = ref.read(activeConversationProvider);
    if (api != null && active != null) {
      try {
        final full = await api.getConversation(active.id);
        ref.read(activeConversationProvider.notifier).set(full);
      } catch (e) {
        DebugLogger.log(
          'Failed to refresh conversation: $e',
          scope: 'chat/page',
        );
      }
    }

    try {
      refreshConversationsCache(ref);
      await ref.read(conversationsProvider.future);
    } catch (_) {}

    await Future.delayed(const Duration(milliseconds: 300));
  }

  void _handleVoiceCall() {
    unawaited(
      ref.read(voiceCallLauncherProvider).launch(startNewConversation: false),
    );
  }

  // Replaced bottom-sheet chat list with left drawer (see ChatsDrawer)

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    _updateBottomAnchorTracking();

    // Debounce scroll handling to reduce rebuilds
    if (_scrollDebounceTimer?.isActive == true) return;

    _scrollDebounceTimer = Timer(const Duration(milliseconds: 80), () {
      _updateScrollToBottomVisibility();
    });
  }

  void _updateScrollToBottomVisibility() {
    if (!mounted || _isDeactivated || !_scrollController.hasClients) return;

    final distanceFromBottom = _distanceFromBottom();
    final bool farFromBottom = distanceFromBottom > _scrollButtonShowThreshold;
    final bool nearBottom = distanceFromBottom <= _scrollButtonHideThreshold;
    final bool hasScrollableContent = _hasScrollableContentForBottomButton();
    _isAnchoredToBottom = !hasScrollableContent || nearBottom;

    final showButton = _showScrollToBottom
        ? !nearBottom && hasScrollableContent
        : farFromBottom && hasScrollableContent;

    if (showButton != _showScrollToBottom) {
      setState(() {
        _showScrollToBottom = showButton;
      });
    }

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

  bool _hasScrollableContentForBottomButton() {
    if (!_scrollController.hasClients) {
      return false;
    }
    final position = _scrollController.position;
    if (!position.hasContentDimensions) {
      return false;
    }
    final maxScroll = position.maxScrollExtent;
    if (!maxScroll.isFinite) {
      return false;
    }

    // The message list includes bottom padding equal to the overlaid composer
    // height so the final message is not hidden behind it. Do not show a
    // scroll button when the only scrollable extent is that spacer or the
    // temporary pin-to-top phantom sliver.
    final bottomSpacer =
        _messageListBottomPadding() + _pinToTopPhantomScrollExtent();
    final contentScrollExtent = maxScroll - bottomSpacer;
    return contentScrollExtent > _scrollButtonShowThreshold;
  }

  double _messageListBottomPadding() {
    final voice = ref.read(chatVoiceModeControllerProvider);
    final voiceOverlayHeight = voice.isActive
        ? (voice.isCollapsed ? 72.0 : 180.0)
        : 0.0;
    return Spacing.lg + _inputHeight + voiceOverlayHeight;
  }

  double _pinToTopPhantomScrollExtent() {
    if (!_wantsPinToTop) {
      return 0.0;
    }
    return MediaQuery.of(context).size.height;
  }

  double _bottomScrollOffset() {
    if (!_scrollController.hasClients) {
      return 0.0;
    }
    final maxScroll = _scrollController.position.maxScrollExtent;
    if (!maxScroll.isFinite || maxScroll <= 0) {
      return 0.0;
    }
    return (maxScroll - _pinToTopPhantomScrollExtent()).clamp(0.0, maxScroll);
  }

  double _distanceFromBottom() {
    if (!_scrollController.hasClients) {
      return double.infinity;
    }
    final position = _scrollController.position;
    final bottomOffset = _bottomScrollOffset();
    if (!bottomOffset.isFinite) {
      return double.infinity;
    }
    final distance = bottomOffset - position.pixels;
    return distance >= 0 ? distance : 0.0;
  }

  /// User-initiated scroll to bottom (e.g. button tap).
  void _userScrollToBottom() {
    _isUserInteractingWithScroll = false;
    if (_wantsPinToTop) {
      _endPinToTop(instant: true, preserveStreamingId: true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToBottom(smooth: true);
      });
      return;
    }

    _scrollToBottom(smooth: true);
  }

  void _scrollToBottom({bool smooth = true}) {
    if (_isUserInteractingWithScroll || !_scrollController.hasClients) return;
    final maxScroll = _bottomScrollOffset();
    if (!maxScroll.isFinite || maxScroll <= 0) return;

    PerformanceProfiler.instance.instant(
      'chat_auto_scroll',
      scope: 'chat',
      data: {'smooth': smooth, 'targetOffset': maxScroll.toStringAsFixed(1)},
    );

    if (smooth) {
      _scrollController.animateTo(
        maxScroll,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
      );
    } else {
      _scrollController.jumpTo(maxScroll);
      _updateScrollToBottomVisibility();
    }
  }

  void _beginScrollProfile(String interaction) {
    if (_activeScrollProfileTaskKey != null) {
      return;
    }
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
    PerformanceProfiler.instance.finishTask(
      taskKey,
      data: {
        'reason': reason,
        'offset': _scrollController.hasClients
            ? _scrollController.offset.toStringAsFixed(1)
            : 'detached',
      },
    );
  }

  void _handleConversationChanged(String? conversationId) {
    if (conversationId == _lastConversationId) return;

    final outgoingId = _lastConversationId;
    if (isActiveConversationInPlaceRemap(ref, outgoingId, conversationId)) {
      if (outgoingId != null &&
          conversationId != null &&
          _savedScrollOffsets.containsKey(outgoingId)) {
        _savedScrollOffsets[conversationId] = _savedScrollOffsets.remove(
          outgoingId,
        )!;
      }
      _lastConversationId = conversationId;
      markConversationRead(ref, conversationId);
      return;
    }

    markConversationRead(ref, outgoingId);
    markConversationRead(ref, conversationId);
    if (outgoingId != null && _scrollController.hasClients) {
      _savedScrollOffsets[outgoingId] = _scrollController.position.pixels;
    }

    final currentStreamingId = _activeStreamingAssistantId(
      ref.read(chatMessagesProvider),
    );
    final preserveStreamingPin =
        currentStreamingId != null && currentStreamingId == _pinnedStreamingId;

    _lastConversationId = conversationId;
    _cancelPendingInitialBottomSettle();
    _markdownPrewarmTimer?.cancel();
    _markdownPrewarmTimer = null;
    _markdownPrewarmGeneration++;
    _lastMarkdownPrewarmSignature = null;
    _pendingRowExtentInvalidationMessageIds.clear();
    if (!preserveStreamingPin) {
      _pinToTopState = const _PinToTopState.inactive();
      _invalidateChatListStableLayoutMetadata();
      _endPinToTopInFlight = false;
    }
    if (conversationId == null) {
      _pendingScrollAction = const _PendingChatScrollAction.none();
    } else if (_savedScrollOffsets.containsKey(conversationId)) {
      _pendingScrollAction = _PendingChatScrollAction.restore(
        _savedScrollOffsets[conversationId]!,
      );
    } else {
      _pendingScrollAction = const _PendingChatScrollAction.initialBottom();
    }
  }

  void _scheduleAfterScrollAttachment(VoidCallback action, {int attempt = 0}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_scrollController.hasClients) {
        if (attempt < 2) {
          _scheduleAfterScrollAttachment(action, attempt: attempt + 1);
        }
        return;
      }
      action();
    });
  }

  void _cancelPendingInitialBottomSettle() {
    _initialBottomSettleGeneration += 1;
  }

  void _scheduleInitialScrollToBottom({
    int attempt = 0,
    int? generation,
    bool allowDuringStreaming = false,
  }) {
    final settleGeneration =
        generation ?? (_initialBottomSettleGeneration += 1);
    _scheduleAfterScrollAttachment(() {
      if (!mounted || _initialBottomSettleGeneration != settleGeneration) {
        return;
      }
      if (!allowDuringStreaming &&
          _hasActiveStreamingAssistant(ref.read(chatMessagesProvider))) {
        return;
      }
      if (_isUserInteractingWithScroll) {
        return;
      }
      _scrollToBottom(smooth: false);
      _updateScrollToBottomVisibility();

      if (attempt >= _initialBottomSettleMaxAttempts) {
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            _initialBottomSettleGeneration != settleGeneration ||
            !_scrollController.hasClients ||
            _isUserInteractingWithScroll ||
            (!allowDuringStreaming &&
                _hasActiveStreamingAssistant(ref.read(chatMessagesProvider)))) {
          return;
        }
        if (_distanceFromBottom() > _scrollCorrectionEpsilon) {
          _scheduleInitialScrollToBottom(
            attempt: attempt + 1,
            generation: settleGeneration,
            allowDuringStreaming: allowDuringStreaming,
          );
        }
      });
    });
  }

  void _scheduleScrollRestore(double targetOffset) {
    _cancelPendingInitialBottomSettle();
    _scheduleAfterScrollAttachment(() {
      final clampedTargetOffset = targetOffset
          .clamp(0.0, _scrollController.position.maxScrollExtent)
          .toDouble();
      if ((_scrollController.offset - clampedTargetOffset).abs() < 1.0) {
        return;
      }

      _scrollController.jumpTo(clampedTargetOffset);
      _updateScrollToBottomVisibility();
    });
  }

  String? _activeStreamingAssistantId(List<ChatMessage> messages) {
    if (messages.isEmpty) {
      return null;
    }
    final lastMessage = messages.last;
    if (lastMessage.role == 'assistant' && lastMessage.isStreaming) {
      return lastMessage.id;
    }
    return null;
  }

  bool _hasActiveStreamingAssistant(List<ChatMessage> messages) {
    return _activeStreamingAssistantId(messages) != null;
  }

  /// Scrolls the pending user message near the top of the viewport.
  ///
  /// Uses an estimated offset first so built-in slivers can build the target
  /// item, then snaps to the exact row once its context exists.
  void _scrollToUserMessage({int attempt = 0}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) {
        return;
      }

      final messages = ref.read(chatMessagesProvider);
      final targetId = _pinnedUserMessageId;
      final targetIndex = targetId == null
          ? -1
          : messages.indexWhere((message) => message.id == targetId);
      if (targetIndex < 0 || targetIndex >= messages.length) {
        return;
      }

      final topPadding =
          MediaQuery.of(context).padding.top + kTextTabBarHeight + Spacing.md;
      final ctx = _pinnedUserMessageKey.currentContext;
      if (ctx == null) {
        _jumpNearMessageIndex(messages, targetIndex);
        if (attempt < 3) {
          _scrollToUserMessage(attempt: attempt + 1);
        }
        return;
      }

      _animatePinnedMessageToTop(ctx, topPadding);
    });
  }

  void _animatePinnedMessageToTop(BuildContext targetContext, double topInset) {
    final renderObject = targetContext.findRenderObject();
    if (renderObject is! RenderBox || !_scrollController.hasClients) {
      return;
    }

    final targetTop = renderObject.localToGlobal(Offset.zero).dy;
    final currentOffset = _scrollController.offset;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final targetOffset = (currentOffset + targetTop - topInset).clamp(
      0.0,
      maxScroll,
    );

    if ((targetOffset - currentOffset).abs() < 1.0) {
      return;
    }

    _scrollController.animateTo(
      targetOffset,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  void _jumpNearMessageIndex(List<ChatMessage> messages, int targetIndex) {
    if (!_scrollController.hasClients || targetIndex <= 0) {
      return;
    }

    if (_messageListController.isAttached) {
      _messageListController.jumpToItem(
        index: targetIndex,
        scrollController: _scrollController,
        alignment: 0,
      );
      return;
    }

    final modelsAsync = ref.read(modelsProvider);
    final models = modelsAsync.hasValue ? modelsAsync.value : null;
    final metadata = _resolveChatListStableLayoutMetadata(
      messages: messages,
      models: models,
      apiService: ref.read(apiServiceProvider),
    );

    final maxScroll = _scrollController.position.maxScrollExtent;
    final targetOffset = metadata
        .estimatedOffsetBefore(targetIndex)
        .clamp(0.0, maxScroll);
    _scrollController.jumpTo(targetOffset);
  }

  void _scheduleExtentCacheInvalidation({int attempt = 0, int? generation}) {
    final invalidationGeneration =
        generation ?? (_extentCacheInvalidationGeneration += 1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _extentCacheInvalidationGeneration != invalidationGeneration) {
        return;
      }
      if (!_messageListController.isAttached ||
          _messageListController.isLocked) {
        if (attempt < 2) {
          _scheduleExtentCacheInvalidation(
            attempt: attempt + 1,
            generation: invalidationGeneration,
          );
        }
        return;
      }
      _messageListController.invalidateAllExtents();
    });
  }

  void _scheduleRowExtentInvalidation({int attempt = 0}) {
    if (_rowExtentInvalidationScheduled) {
      return;
    }
    _rowExtentInvalidationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _rowExtentInvalidationScheduled = false;
      if (!mounted || _isDeactivated) {
        _pendingRowExtentInvalidationMessageIds.clear();
        return;
      }
      if (_pendingRowExtentInvalidationMessageIds.isEmpty) {
        return;
      }
      if (!_messageListController.isAttached ||
          _messageListController.isLocked) {
        if (attempt < 2) {
          _scheduleRowExtentInvalidation(attempt: attempt + 1);
        } else {
          _pendingRowExtentInvalidationMessageIds.clear();
        }
        return;
      }

      final changedIndices = _messageRowIndicesForIds(
        ref.read(chatMessagesProvider),
        _pendingRowExtentInvalidationMessageIds,
      );
      _pendingRowExtentInvalidationMessageIds.clear();
      if (changedIndices.isEmpty) {
        return;
      }
      for (final index in changedIndices) {
        _messageListController.invalidateExtent(index);
      }

      final shouldKeepBottomAnchored =
          _shouldKeepConversationBottomAnchoredOnContentSizeChange(
            isAnchoredToBottom: _isAnchoredToBottom,
            isUserInteractingWithScroll: _isUserInteractingWithScroll,
            wantsPinToTop: _wantsPinToTop,
          );

      if (shouldKeepBottomAnchored) {
        _scheduleInitialScrollToBottom(allowDuringStreaming: true);
        return;
      }

      _updateScrollToBottomVisibility();
    });
  }

  double _estimateMessageListExtent(
    _ChatListStableLayoutMetadata layoutMetadata,
    int? index,
    double crossAxisExtent,
  ) {
    return _estimateMessageListExtentForIndex(
      layoutMetadata,
      index,
      crossAxisExtent,
    );
  }

  bool _endPinToTopInFlight = false;

  void _dismissPinToTop({bool preserveStreamingId = false}) {
    if (!_wantsPinToTop || !mounted) {
      return;
    }
    setState(() {
      _pinToTopState = _pinToTopState.dismiss(
        preserveStreamingId: preserveStreamingId,
      );
    });
  }

  /// Transitions out of pin-to-top mode.
  ///
  /// When [instant] is true, uses jumpTo to avoid competing with streaming
  /// row-size corrections.
  void _endPinToTop({bool instant = false, bool preserveStreamingId = false}) {
    if (!_wantsPinToTop || !mounted || _endPinToTopInFlight) return;
    if (_isUserInteractingWithScroll) {
      _dismissPinToTop(preserveStreamingId: preserveStreamingId);
      return;
    }
    if (!_scrollController.hasClients) {
      setState(() {
        _pinToTopState = _pinToTopState.dismiss(
          preserveStreamingId: preserveStreamingId,
        );
      });
      return;
    }
    // Calculate what maxScrollExtent would be without the extra padding.
    // The extra sliver adds exactly screen height of padding.
    final extraHeight = MediaQuery.of(context).size.height;
    final currentOffset = _scrollController.offset;
    final newMaxExtent =
        _scrollController.position.maxScrollExtent - extraHeight;
    final targetOffset = currentOffset.clamp(
      0.0,
      newMaxExtent.clamp(0.0, double.infinity),
    );

    if (instant || (currentOffset - targetOffset).abs() < 1.0) {
      // Jump instantly and remove padding
      if ((currentOffset - targetOffset).abs() >= 1.0) {
        _scrollController.jumpTo(targetOffset);
      }
      setState(() {
        _pinToTopState = _pinToTopState.dismiss(
          preserveStreamingId: preserveStreamingId,
        );
      });
    } else {
      // Animate to valid position, then remove padding
      _endPinToTopInFlight = true;
      _scrollController
          .animateTo(
            targetOffset,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
          )
          .whenComplete(() {
            _endPinToTopInFlight = false;
            if (mounted) {
              setState(() {
                _pinToTopState = _pinToTopState.dismiss(
                  preserveStreamingId: preserveStreamingId,
                );
              });
            }
          });
    }
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
    watchRef.watch(isChatStreamingProvider);
    final messages = watchRef.read(chatMessagesProvider);
    final isLoadingConversation = watchRef.watch(isLoadingConversationProvider);
    final showLoadingSkeleton = isLoadingConversation && messages.isEmpty;
    if (showLoadingSkeleton) {
      return _buildLoadingMessagesList();
    }
    return _buildActualMessagesList(messages, watchRef);
  }

  Widget _buildLoadingMessagesList() {
    // Use slivers to align with the actual messages view.
    // Do not attach the primary scroll controller here; the actual message
    // list owns it.
    // Add top padding for the floating app bar and bottom padding for the
    // overlaid composer section.
    final topPadding =
        MediaQuery.of(context).padding.top + kTextTabBarHeight + Spacing.md;
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
          maxWidth: MediaQuery.of(context).size.width * 0.82,
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
    WidgetRef watchRef,
  ) {
    if (messages.isEmpty) {
      return _buildEmptyState(Theme.of(context));
    }

    final apiService = watchRef.watch(apiServiceProvider);

    final pendingScrollAction = _pendingScrollAction;
    if (!pendingScrollAction.isNone) {
      _pendingScrollAction = const _PendingChatScrollAction.none();
      switch (pendingScrollAction.kind) {
        case _PendingChatScrollActionKind.restore:
          _scheduleScrollRestore(pendingScrollAction.restoreOffset);
          break;
        case _PendingChatScrollActionKind.initialBottom:
          _scheduleInitialScrollToBottom();
          break;
        case _PendingChatScrollActionKind.none:
          break;
      }
    }

    // Add top padding for the floating app bar and bottom padding for the
    // overlaid composer section.
    final topPadding =
        MediaQuery.of(context).padding.top + kTextTabBarHeight + Spacing.md;
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
    if (!identical(_lastExtentCacheInvalidationMetadata, layoutMetadata)) {
      _lastExtentCacheInvalidationMetadata = layoutMetadata;
      _scheduleExtentCacheInvalidation();
    }
    _scheduleMarkdownPrewarm(messages, layoutMetadata: layoutMetadata);
    final hasStreamingMessage = _hasActiveStreamingAssistant(messages);

    // Pin-to-top: detect new streaming response and scroll user message to top
    if (hasStreamingMessage && messages.length >= 2) {
      final lastMsg = messages.last;
      final parentUserId = lastMsg.role == 'assistant' && lastMsg.isStreaming
          ? _resolveStreamingParentUserId(messages)
          : null;
      if (parentUserId != null && _pinnedStreamingId != lastMsg.id) {
        // New streaming response detected
        _pinToTopState = _PinToTopState.active(
          userMessageId: parentUserId,
          streamingMessageId: lastMsg.id,
        );
        _pinnedUserMessageKey = GlobalKey();
        _scrollToUserMessage();
      }
    }
    if (!hasStreamingMessage && !_wantsPinToTop && _pinnedStreamingId != null) {
      // Streaming finished but pin-to-top is no longer active: clear the stale
      // pinned streaming id. When pin-to-top IS still active we deliberately
      // keep the phantom spacer so the prompt stays near the top until the user
      // scrolls, sends, or switches chats — avoids a viewport jump mid-read.
      _pinToTopState = const _PinToTopState.inactive();
    }

    final pinnedUserMessageIndex =
        _wantsPinToTop && _pinnedUserMessageId != null
        ? layoutMetadata.indexByMessageId[_pinnedUserMessageId!] ?? -1
        : -1;

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        final isTouchDragStart =
            notification is ScrollStartNotification &&
            notification.dragDetails != null;
        final isTouchDragUpdate =
            notification is ScrollUpdateNotification &&
            notification.dragDetails != null;
        final isUserDirectionalScroll =
            notification is UserScrollNotification &&
            notification.direction != ScrollDirection.idle;
        final isUserScrollIdle =
            notification is UserScrollNotification &&
            notification.direction == ScrollDirection.idle;

        // User scrolling dismisses pin-to-top once the user takes control.
        if (isTouchDragStart || isTouchDragUpdate || isUserDirectionalScroll) {
          if (!_isUserInteractingWithScroll) {
            _cancelPendingInitialBottomSettle();
            _beginScrollProfile('user_drag');
          }
          _isUserInteractingWithScroll = true;
          // Dismiss native platform keyboard on drag (mirrors
          // keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag
          // which only affects Flutter's text input system).
          try {
            ref.read(composerAutofocusEnabledProvider.notifier).set(false);
          } catch (_) {}
          if (_wantsPinToTop) {
            _dismissPinToTop(preserveStreamingId: true);
          }
        }
        if (notification is ScrollEndNotification || isUserScrollIdle) {
          _endScrollProfile(reason: 'idle');
          _isUserInteractingWithScroll = false;
        }
        return false; // Allow notification to continue bubbling
      },
      child: CustomScrollView(
        key: const ValueKey('actual_messages'),
        controller: _scrollController,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        physics: SuperRangeMaintainingScrollPhysics(
          parent: platformAlwaysScrollablePhysics(context),
        ),
        scrollCacheExtent: const ScrollCacheExtent.pixels(600),
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              Spacing.inputPadding,
              topPadding,
              Spacing.inputPadding,
              bottomPadding,
            ),
            sliver: SuperSliverList(
              listController: _messageListController,
              extentEstimation: (index, crossAxisExtent) =>
                  _estimateMessageListExtent(
                    layoutMetadata,
                    index,
                    crossAxisExtent,
                  ),
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final message = messages[index];
                  final messageId = message.id;
                  final rowMetadata = layoutMetadata.rows[index];
                  final isUser = message.role == 'user';

                  if (rowMetadata.isArchivedVariant) {
                    return const SizedBox.shrink();
                  }

                  if (isUser) {
                    final isPinTarget = index == pinnedUserMessageIndex;
                    return _buildMeasuredMessageRow(
                      messageId: messageId,
                      rowKey: isPinTarget
                          ? _pinnedUserMessageKey
                          : ValueKey<String>('message-$messageId'),
                      child: Consumer(
                        builder: (context, rowRef, _) {
                          final latestMessage = rowRef.watch(
                            chatMessageByIdProvider(messageId),
                          );
                          if (latestMessage == null) {
                            return const SizedBox.shrink();
                          }
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
                                _copyMessage(currentMessage.content);
                              }
                            },
                            onDelete: () {
                              final currentMessage = rowRef.read(
                                chatMessageByIdProvider(messageId),
                              );
                              if (currentMessage != null) {
                                _deleteMessage(currentMessage);
                              }
                            },
                            onRegenerate: () => _regenerateMessage(messageId),
                          );
                        },
                      ),
                    );
                  }

                  return _buildMeasuredMessageRow(
                    messageId: messageId,
                    rowKey: ValueKey<String>('message-$messageId'),
                    child: Consumer(
                      builder: (context, rowRef, _) {
                        final latestMessage = rowRef.watch(
                          chatMessageByIdProvider(messageId),
                        );
                        if (latestMessage == null) {
                          return const SizedBox.shrink();
                        }
                        return assistant.AssistantMessageWidget(
                          message: latestMessage,
                          isStreaming: latestMessage.isStreaming,
                          showFollowUps: rowMetadata.showFollowUps,
                          animateOnMount:
                              !rowMetadata.replacesArchivedAssistant,
                          modelName: rowMetadata.displayModelName,
                          modelIconUrl: rowMetadata.modelIconUrl,
                          versionModelNames: rowMetadata.versionModelNames,
                          versionModelIconUrls:
                              rowMetadata.versionModelIconUrls,
                          suppressStreamingHaptics:
                              suppressAssistantStreamingHaptics,
                          onCopy: () {
                            final currentMessage = rowRef.read(
                              chatMessageByIdProvider(messageId),
                            );
                            if (currentMessage != null) {
                              _copyMessage(currentMessage.content);
                            }
                          },
                          onRegenerate: () => _regenerateMessage(messageId),
                          onDelete: () {
                            final currentMessage = rowRef.read(
                              chatMessageByIdProvider(messageId),
                            );
                            if (currentMessage != null) {
                              _deleteMessage(currentMessage);
                            }
                          },
                        );
                      },
                    ),
                  );
                },
                childCount: messages.length,
                findChildIndexCallback: (key) =>
                    _findMessageIndexForKey(key, layoutMetadata),
              ),
            ),
          ),
          // Extra bottom space when pin-to-top is active so the user
          // message can be scrolled to the top of the viewport.
          if (_wantsPinToTop)
            SliverToBoxAdapter(
              child: SizedBox(height: MediaQuery.of(context).size.height),
            ),
        ],
      ),
    );
  }

  Widget _buildMeasuredMessageRow({
    required String messageId,
    required Key rowKey,
    required Widget child,
  }) {
    return KeyedSubtree(
      key: rowKey,
      child: MeasureSize(
        onChange: (_) => _handleMessageRowSizeChange(messageId),
        child: child,
      ),
    );
  }

  void _scheduleMarkdownPrewarm(
    List<ChatMessage> messages, {
    required _ChatListStableLayoutMetadata layoutMetadata,
  }) {
    final candidateIndices = _selectMarkdownPrewarmCandidateIndices(
      messages: messages,
      layoutMetadata: layoutMetadata,
      viewportTop: _scrollController.hasClients
          ? _scrollController.offset
          : null,
      viewportHeight: _scrollController.hasClients
          ? _scrollController.position.viewportDimension
          : null,
      maxCount: 6,
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
      _markdownPrewarmTimer?.cancel();
      _markdownPrewarmTimer = null;
      _lastMarkdownPrewarmSignature = null;
      return;
    }

    final signature = signatureParts.join('|');
    if (signature == _lastMarkdownPrewarmSignature) {
      return;
    }

    final preparedContents = filteredCandidateIndices
        .map(
          (index) => prepareMarkdownContent(
            messages[index].content.trim(),
            streaming: false,
          ),
        )
        .toList(growable: false);
    _lastMarkdownPrewarmSignature = signature;
    _markdownPrewarmGeneration += 1;
    final generation = _markdownPrewarmGeneration;
    _markdownPrewarmTimer?.cancel();
    _markdownPrewarmTimer = Timer(const Duration(milliseconds: 220), () {
      if (!mounted || generation != _markdownPrewarmGeneration) {
        return;
      }
      ref
          .read(markdownCompileServiceProvider)
          .prewarmPrepared(preparedContents);
    });
  }

  String? _resolveStreamingParentUserId(List<ChatMessage> messages) {
    final assistantIndex = messages.length - 1;
    final parentId = message_tree.assistantParentUserMessageId(
      messages: messages,
      assistantIndex: assistantIndex,
    );
    if (parentId == null) {
      return null;
    }
    final parentMessage = messages
        .where((message) => message.id == parentId)
        .firstOrNull;
    return parentMessage?.role == 'user' ? parentId : null;
  }

  void _copyMessage(String content) {
    // Strip reasoning blocks and annotations from copied content
    final cleanedContent = ConduitMarkdownPreprocessor.sanitize(content);
    Clipboard.setData(ClipboardData(text: cleanedContent));
  }

  Future<void> _deleteMessage(ChatMessage message) async {
    final l10n = AppLocalizations.of(context)!;
    final currentMessages = ref.read(chatMessagesProvider);
    final initialRemovedIds = _messageIdsToDelete(currentMessages, message.id);
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
    final removedIds = _messageIdsToDelete(latestMessages, message.id);
    final updatedMessages = latestMessages
        .where((candidate) => !removedIds.contains(candidate.id))
        .toList(growable: false);

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
      final updatedConversation = activeConversation.copyWith(
        messages: updatedMessages,
        updatedAt: DateTime.now(),
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
          await api.deleteConversationMessage(
            updatedConversation.id,
            message.id,
          );
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
  ) => message_tree.chatMessageDescendantIds(messages, messageId);

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
    final hasGreeting = greetingName != null && greetingName.isNotEmpty;
    if (hasGreeting && !_greetingReady) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _greetingReady = true;
        });
      });
    } else if (!hasGreeting && _greetingReady) {
      _greetingReady = false;
    }
    final baseGreetingStyle = AppTypography.usesAppleRamp
        ? theme.textTheme.displaySmall ?? AppTypography.displaySmallStyle
        : theme.textTheme.headlineSmall ?? AppTypography.headlineSmallStyle;
    final greetingStyle = baseGreetingStyle.copyWith(
      fontWeight: FontWeight.w600,
      color: context.conduitTheme.textPrimary,
    );
    final textScaler = MediaQuery.textScalerOf(context);
    final greetingHeight =
        textScaler.scale(greetingStyle.fontSize ?? 24) *
        (greetingStyle.height ?? 1.1);
    final String? resolvedGreetingName = hasGreeting ? greetingName : null;
    final greetingText = resolvedGreetingName != null
        ? l10n.greetingTitle(resolvedGreetingName)
        : null;
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
        MediaQuery.of(context).padding.top + kTextTabBarHeight + Spacing.md;
    final bottomPadding = _messageListBottomPadding();
    return LayoutBuilder(
      builder: (context, constraints) {
        final greetingDisplay = greetingText ?? '';
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
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                Spacing.lg,
                topPadding,
                Spacing.lg,
                bottomPadding,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                mainAxisSize: MainAxisSize.max,
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
                        duration: const Duration(milliseconds: 260),
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
                    if (isTemporary) ...[
                      const SizedBox(height: Spacing.md),
                      temporaryChatNotice,
                    ],
                  ],
                ],
              ),
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
          minimum: const EdgeInsets.only(bottom: Spacing.sm),
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
                    enabled: !isLoadingConversation,
                    bottomPadding: 0,
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
    final formattedModelName = selectedModel != null
        ? _formatModelDisplayName(selectedModel.name)
        : null;
    final modelLabel = formattedModelName ?? l10n.chooseModel;
    final overlayStyle = theme.appBarTheme.systemOverlayStyle;

    // Keyboard visibility - use viewInsetsOf for more efficient partial subscription
    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    // Whether the messages list can actually scroll (avoids showing button when not needed)
    final canScroll = _hasScrollableContentForBottomButton();

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
        if (hasNativeFocus || (currentFocus != null && currentFocus.hasFocus)) {
          _dismissComposerFocus();
          return;
        }

        // Auto-handle leaving without confirmation
        final messages = ref.read(chatMessagesProvider);
        final isStreaming = messages.any((msg) => msg.isStreaming);
        if (isStreaming) {
          ref.read(chatMessagesProvider.notifier).finishStreaming();
        }

        // Do not push conversation state back to server on exit.
        // Server already maintains chat state from message sends.
        // Keep any local persistence only.

        if (context.mounted) {
          final navigator = Navigator.of(context);
          if (navigator.canPop()) {
            navigator.pop();
          } else {
            final shouldExit = await ThemedDialogs.confirm(
              context,
              title: l10n.appTitle,
              message: l10n.endYourSession,
              confirmText: l10n.confirm,
              cancelText: l10n.cancel,
              isDestructive: Platform.isAndroid,
            );

            if (!shouldExit || !context.mounted) return;

            if (Platform.isAndroid) {
              SystemNavigator.pop();
            }
          }
        }
      },
      child: AdaptiveScaffold(
        // Replace Scaffold drawer with a tunable slide drawer for gentler snap behavior.
        drawerEnableOpenDragGesture: false,
        extendBodyBehindAppBar: true,
        appBar: _buildAdaptiveChatAppBar(
          context: context,
          ref: ref,
          isLoadingConversation: isLoadingConversation,
          modelLabel: modelLabel,
        ),
        body: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: _dismissComposerFocus,
          child: Stack(
            children: [
              Positioned.fill(
                child: ConduitRefreshIndicator(
                  edgeOffset:
                      MediaQuery.of(context).padding.top + kTextTabBarHeight,
                  onRefresh: _refreshActiveConversation,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _dismissComposerFocus,
                    child: Consumer(
                      builder: (context, listRef, _) {
                        return RepaintBoundary(
                          child: _buildMessagesList(theme, listRef),
                        );
                      },
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: ConduitChromeGradientFade.top(
                  contentHeight:
                      MediaQuery.viewPaddingOf(context).top + kTextTabBarHeight,
                ),
              ),
              Positioned(
                bottom: (_inputHeight > 0)
                    ? math.max(0, _inputHeight - Spacing.xl + Spacing.md)
                    : (Spacing.xxl + Spacing.xxxl),
                left: 0,
                right: 0,
                child: AnimatedSwitcher(
                  duration: AnimationDuration.microInteraction,
                  switchInCurve: AnimationCurves.microInteraction,
                  switchOutCurve: AnimationCurves.microInteraction,
                  transitionBuilder: (child, animation) {
                    final slideAnimation = Tween<Offset>(
                      begin: const Offset(0, 0.15),
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
                  child: Consumer(
                    builder: (context, scrollButtonRef, _) {
                      final hasMessages = scrollButtonRef.watch(
                        hasChatMessagesProvider,
                      );
                      return (_showScrollToBottom &&
                              !keyboardVisible &&
                              canScroll &&
                              hasMessages)
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

    return ErrorBoundary(child: page);
  }

  void _toggleResponsiveDrawer(BuildContext context) {
    final layout = ResponsiveDrawerLayout.of(context);
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
  }) {
    final activeConversation = ref.watch(activeConversationProvider);
    final isTemporary = ref.watch(temporaryChatEnabledProvider);
    final hasMessages = ref.watch(hasChatMessagesProvider);
    final showNewChatAction = activeConversation != null || hasMessages;
    final tintColor = context.conduitTheme.textPrimary;
    const leadingGap = kConduitAdaptiveToolbarLeadingGap;
    final trailingActionCount = (showNewChatAction ? 1 : 0) + 1;
    final maxModelWidth = resolveConduitAdaptiveLeadingPillWidth(
      context,
      trailingActionCount: trailingActionCount,
      maxWidth: kConduitAdaptiveToolbarMaxPillWidth,
    );
    final leading = _buildNativeToolbarLeading(
      context: context,
      isLoadingConversation: isLoadingConversation,
      modelLabel: modelLabel,
      leadingGap: leadingGap,
      maxModelWidth: maxModelWidth,
    );
    final actions = _buildAdaptiveToolbarActionWidgets(
      context: context,
      activeConversation: activeConversation,
      isTemporary: isTemporary,
      hasMessages: hasMessages,
      showNewChatAction: showNewChatAction,
    );
    final leadingWidth = resolveConduitAdaptiveToolbarLeadingWidth(
      pillWidth: maxModelWidth,
      leadingGap: leadingGap,
    );
    final overlayStyle = Theme.of(context).appBarTheme.systemOverlayStyle;

    return AdaptiveAppBar(
      useNativeToolbar: false,
      tintColor: tintColor,
      cupertinoNavigationBar: CupertinoNavigationBar(
        automaticallyImplyLeading: false,
        border: null,
        backgroundColor: Colors.transparent,
        automaticBackgroundVisibility: false,
        brightness: Theme.of(context).brightness,
        enableBackgroundFilterBlur: false,
        leading: leading,
        trailing: Row(mainAxisSize: MainAxisSize.min, children: actions),
      ),
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: Elevation.none,
        scrolledUnderElevation: Elevation.none,
        toolbarHeight: kTextTabBarHeight,
        systemOverlayStyle: overlayStyle,
        centerTitle: false,
        titleSpacing: Spacing.sm,
        leadingWidth: leadingWidth,
        leading: leading,
        actions: actions,
      ),
    );
  }

  Widget _buildNativeToolbarLeading({
    required BuildContext context,
    required bool isLoadingConversation,
    required String modelLabel,
    required double leadingGap,
    required double maxModelWidth,
  }) {
    return buildConduitAdaptiveToolbarLeadingRow(
      children: [
        ConduitAdaptiveAppBarIconButton(
          key: const ValueKey('chat-sidebar-toggle'),
          icon: Platform.isIOS ? CupertinoIcons.line_horizontal_3 : Icons.menu,
          onPressed: () => _toggleResponsiveDrawer(context),
          iconColor: context.conduitTheme.textPrimary,
        ),
        SizedBox(width: leadingGap),
        ConduitAdaptiveAppBarModelSelector(
          label: modelLabel,
          maxWidth: maxModelWidth,
          isLoading: isLoadingConversation,
          onPressed: () => _openModelSelector(context),
        ),
      ],
    );
  }

  List<Widget> _buildAdaptiveToolbarActionWidgets({
    required BuildContext context,
    required Conversation? activeConversation,
    required bool isTemporary,
    required bool hasMessages,
    required bool showNewChatAction,
  }) {
    final actions = <Widget>[];
    final defaultTint = context.conduitTheme.textPrimary;

    final temporaryAction = _buildTemporaryChatToolbarAction(
      activeConversation: activeConversation,
      isTemporary: isTemporary,
      hasMessages: hasMessages,
      tintColor: defaultTint,
    );
    if (temporaryAction != null) {
      actions.add(temporaryAction);
    }

    if (showNewChatAction) {
      actions.add(
        ConduitAdaptiveAppBarIconButton(
          icon: Platform.isIOS ? CupertinoIcons.create : Icons.add_comment,
          iconColor: defaultTint,
          onPressed: _handleNewChat,
        ),
      );
    }

    final overflowButton = _buildChatToolbarOverflowButton(
      context: context,
      activeConversation: activeConversation,
      tintColor: defaultTint,
    );
    if (overflowButton != null) {
      actions.add(overflowButton);
    }

    return buildConduitAdaptiveToolbarActionWidgets(actions);
  }

  Widget? _buildTemporaryChatToolbarAction({
    required Conversation? activeConversation,
    required bool isTemporary,
    required bool hasMessages,
    required Color tintColor,
  }) {
    final showTemporaryAction =
        activeConversation == null || isTemporaryChat(activeConversation.id);
    if (!showTemporaryAction) {
      return null;
    }

    if (isTemporary && hasMessages && activeConversation != null) {
      return ConduitAdaptiveAppBarIconButton(
        icon: Platform.isIOS ? CupertinoIcons.arrow_down_doc : Icons.save_alt,
        iconColor: tintColor,
        onPressed: _saveTemporaryChat,
      );
    }

    return ConduitAdaptiveAppBarIconButton(
      icon: isTemporary
          ? (Platform.isIOS ? CupertinoIcons.eye_slash : Icons.visibility_off)
          : (Platform.isIOS ? CupertinoIcons.eye : Icons.visibility_outlined),
      iconColor: isTemporary ? Colors.blue : tintColor,
      onPressed: () {
        ConduitHaptics.selectionClick();
        final current = ref.read(temporaryChatEnabledProvider);
        ref.read(temporaryChatEnabledProvider.notifier).set(!current);
      },
    );
  }

  Widget? _buildChatToolbarOverflowButton({
    required BuildContext context,
    required Conversation? activeConversation,
    required Color tintColor,
  }) {
    final items = <AdaptivePopupMenuEntry>[];
    final callbacks = <Future<void> Function()>[];

    void addItem({
      required String label,
      required Object icon,
      required Future<void> Function() onSelected,
    }) {
      final index = callbacks.length;
      callbacks.add(onSelected);
      items.add(
        AdaptivePopupMenuItem<int>(value: index, label: label, icon: icon),
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
        onSelected: () async {
          action.onBeforeClose?.call();
          await action.onSelected();
        },
      );
    }

    if (items.isEmpty) {
      return null;
    }

    return ConduitAdaptiveToolbarOverflowButton<int>(
      tintColor: tintColor,
      materialIcon: Icons.more_vert,
      items: items,
      onSelected: (index) {
        if (index < 0 || index >= callbacks.length) {
          return;
        }
        unawaited(callbacks[index]());
      },
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

Map<String, Model>? _buildChatModelLookup(List<Model>? models) {
  if (models == null || models.isEmpty) return null;
  final lookup = <String, Model>{};
  for (final model in models) {
    lookup[model.id] = model;
    lookup[model.name] = model;
  }
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

@immutable
class _ChatRowLayoutMetadata {
  const _ChatRowLayoutMetadata({
    required this.displayModelName,
    required this.modelIconUrl,
    required this.versionModelNames,
    required this.versionModelIconUrls,
    required this.isArchivedVariant,
    required this.replacesArchivedAssistant,
    required this.showFollowUps,
    required this.estimatedExtent,
    required this.leadingOffset,
  });

  final String? displayModelName;
  final String? modelIconUrl;
  final List<String?> versionModelNames;
  final List<String?> versionModelIconUrls;
  final bool isArchivedVariant;
  final bool replacesArchivedAssistant;
  final bool showFollowUps;
  final double estimatedExtent;
  final double leadingOffset;
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
class _ChatListStableLayoutMetadata {
  const _ChatListStableLayoutMetadata({
    required this.rows,
    required this.indexByMessageId,
    required this.indexByMessageKey,
  });

  final List<_ChatRowLayoutMetadata> rows;
  final Map<String, int> indexByMessageId;
  final Map<String, int> indexByMessageKey;

  double estimatedOffsetBefore(int targetIndex) {
    if (targetIndex <= 0 || targetIndex >= rows.length) {
      return 0;
    }
    return rows[targetIndex].leadingOffset;
  }
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
  required double crossAxisExtent,
}) {
  final modelLookup = _buildChatModelLookup(models);
  final bubbleAdjacency = _buildChatBubbleAdjacency(messages);
  final rows = <_ChatRowLayoutMetadata>[];
  final indexByMessageId = <String, int>{};
  final indexByMessageKey = <String, int>{};
  var leadingOffset = 0.0;

  for (var index = 0; index < messages.length; index++) {
    final message = messages[index];
    final isUser = message.role == 'user';
    indexByMessageId[message.id] = index;
    indexByMessageKey['message-${message.id}'] = index;

    final modelPresentation = _resolveChatModelPresentation(
      rawModel: message.model,
      fallbackModelName: _messageModelNameFallback(message),
      models: models,
      modelLookup: modelLookup,
    );
    final versionModelNames = <String?>[];
    final versionModelIconUrls = <String?>[];
    for (final version in message.versions) {
      final versionPresentation = _resolveChatModelPresentation(
        rawModel: version.model,
        fallbackModelName: version.modelName,
        models: models,
        modelLookup: modelLookup,
      );
      versionModelNames.add(versionPresentation.displayName);
      versionModelIconUrls.add(
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
    final estimatedExtent = _estimateChatMessageExtent(
      message,
      crossAxisExtent,
    );

    rows.add(
      _ChatRowLayoutMetadata(
        displayModelName: modelPresentation.displayName,
        modelIconUrl: resolveModelIconUrlForModel(
          apiService,
          modelPresentation.matchedModel,
        ),
        versionModelNames: List<String?>.unmodifiable(versionModelNames),
        versionModelIconUrls: List<String?>.unmodifiable(versionModelIconUrls),
        isArchivedVariant: isArchivedVariant,
        replacesArchivedAssistant:
            !isUser &&
            index > 0 &&
            messages[index - 1].role == 'assistant' &&
            (messages[index - 1].metadata?['archivedVariant'] == true),
        showFollowUps: showFollowUps,
        estimatedExtent: estimatedExtent,
        leadingOffset: leadingOffset,
      ),
    );
    leadingOffset += estimatedExtent;
  }

  return _ChatListStableLayoutMetadata(
    rows: List<_ChatRowLayoutMetadata>.unmodifiable(rows),
    indexByMessageId: Map<String, int>.unmodifiable(indexByMessageId),
    indexByMessageKey: Map<String, int>.unmodifiable(indexByMessageKey),
  );
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

bool _shouldKeepConversationBottomAnchoredOnComposerHeightChange({
  required double previousComposerHeight,
  required double nextComposerHeight,
  required bool isAnchoredToBottom,
  required bool isUserInteractingWithScroll,
  required bool wantsPinToTop,
}) {
  const heightChangeEpsilon = 1.0;
  final composerHeightChanged =
      (nextComposerHeight - previousComposerHeight).abs() > heightChangeEpsilon;
  return composerHeightChanged &&
      isAnchoredToBottom &&
      !isUserInteractingWithScroll &&
      !wantsPinToTop;
}

bool _shouldKeepConversationBottomAnchoredOnContentSizeChange({
  required bool isAnchoredToBottom,
  required bool isUserInteractingWithScroll,
  required bool wantsPinToTop,
}) {
  return isAnchoredToBottom && !isUserInteractingWithScroll && !wantsPinToTop;
}

List<int> _messageRowIndicesForIds(
  List<ChatMessage> messages,
  Iterable<String> messageIds,
) {
  final pendingIds = messageIds.toSet();
  if (pendingIds.isEmpty || messages.isEmpty) {
    return const <int>[];
  }

  final indices = <int>[];
  for (var index = 0; index < messages.length; index += 1) {
    if (pendingIds.contains(messages[index].id)) {
      indices.add(index);
    }
  }
  return List<int>.unmodifiable(indices);
}

double _estimateMessageListExtentForIndex(
  _ChatListStableLayoutMetadata layoutMetadata,
  int? index,
  double crossAxisExtent,
) {
  if (index != null && index >= 0 && index < layoutMetadata.rows.length) {
    return layoutMetadata.rows[index].estimatedExtent;
  }

  // SuperSliverList treats a null index as a shared fallback estimate for all
  // unmeasured rows. Our chat rows vary substantially by message type/content,
  // so return 0 to force per-index estimates instead.
  return 0.0;
}

@visibleForTesting
String debugBuildChatListStableLayoutSignatureForTesting(
  List<ChatMessage> messages,
) {
  return _buildChatListStableLayoutSignature(messages).value;
}

@visibleForTesting
List<
  ({
    double leadingOffset,
    double estimatedExtent,
    bool isArchivedVariant,
    bool showFollowUps,
    String? displayModelName,
  })
>
debugBuildChatListLayoutSummaryForTesting(
  List<ChatMessage> messages, {
  double crossAxisExtent = 400,
}) {
  final metadata = _buildChatListStableLayoutMetadata(
    messages: messages,
    models: null,
    apiService: null,
    crossAxisExtent: crossAxisExtent,
  );
  return metadata.rows
      .map(
        (row) => (
          leadingOffset: row.leadingOffset,
          estimatedExtent: row.estimatedExtent,
          isArchivedVariant: row.isArchivedVariant,
          showFollowUps: row.showFollowUps,
          displayModelName: row.displayModelName,
        ),
      )
      .toList(growable: false);
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
bool debugShouldKeepConversationBottomAnchoredOnComposerHeightChangeForTesting({
  required double previousComposerHeight,
  required double nextComposerHeight,
  required bool isAnchoredToBottom,
  required bool isUserInteractingWithScroll,
  required bool wantsPinToTop,
}) {
  return _shouldKeepConversationBottomAnchoredOnComposerHeightChange(
    previousComposerHeight: previousComposerHeight,
    nextComposerHeight: nextComposerHeight,
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
  return _shouldKeepConversationBottomAnchoredOnContentSizeChange(
    isAnchoredToBottom: isAnchoredToBottom,
    isUserInteractingWithScroll: isUserInteractingWithScroll,
    wantsPinToTop: wantsPinToTop,
  );
}

@visibleForTesting
List<int> debugMessageRowIndicesForIdsForTesting(
  List<ChatMessage> messages,
  Iterable<String> messageIds,
) {
  return _messageRowIndicesForIds(messages, messageIds);
}

@visibleForTesting
double debugEstimateMessageListExtentForTesting(
  List<ChatMessage> messages, {
  required int? index,
  double crossAxisExtent = 400,
}) {
  final metadata = _buildChatListStableLayoutMetadata(
    messages: messages,
    models: null,
    apiService: null,
    crossAxisExtent: crossAxisExtent,
  );
  return _estimateMessageListExtentForIndex(metadata, index, crossAxisExtent);
}

@visibleForTesting
List<int> debugSelectMarkdownPrewarmCandidateIndicesForTesting(
  List<ChatMessage> messages, {
  double crossAxisExtent = 400,
  double viewportTop = 0,
  double viewportHeight = 700,
  int maxCount = 6,
}) {
  final metadata = _buildChatListStableLayoutMetadata(
    messages: messages,
    models: null,
    apiService: null,
    crossAxisExtent: crossAxisExtent,
  );
  return _selectMarkdownPrewarmCandidateIndices(
    messages: messages,
    layoutMetadata: metadata,
    viewportTop: viewportTop,
    viewportHeight: viewportHeight,
    maxCount: maxCount,
  );
}

List<int> _selectMarkdownPrewarmCandidateIndices({
  required List<ChatMessage> messages,
  required _ChatListStableLayoutMetadata layoutMetadata,
  required double? viewportTop,
  required double? viewportHeight,
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

  if (viewportTop == null || viewportHeight == null || viewportHeight <= 0) {
    return const <int>[];
  }

  final startOffset = viewportTop.clamp(0.0, double.infinity);
  final endOffset = viewportTop + viewportHeight;
  final startIndex = _rowIndexForEstimatedOffset(layoutMetadata, startOffset);
  final endIndex = _rowIndexForEstimatedOffset(layoutMetadata, endOffset);
  for (var index = endIndex; index >= startIndex; index -= 1) {
    addIndex(index);
    if (indices.length >= maxCount) {
      return List<int>.unmodifiable(indices);
    }
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

int _rowIndexForEstimatedOffset(
  _ChatListStableLayoutMetadata layoutMetadata,
  double targetOffset,
) {
  final rows = layoutMetadata.rows;
  if (rows.isEmpty) {
    return 0;
  }

  var low = 0;
  var high = rows.length - 1;
  var result = rows.length - 1;

  while (low <= high) {
    final mid = low + ((high - low) >> 1);
    final row = rows[mid];
    final rowStart = row.leadingOffset;
    final rowEnd = rowStart + row.estimatedExtent;
    if (targetOffset <= rowEnd) {
      result = mid;
      high = mid - 1;
    } else {
      low = mid + 1;
    }
  }

  return result.clamp(0, rows.length - 1);
}

double _estimateChatMessageExtent(
  ChatMessage? message,
  double crossAxisExtent, {
  bool countAsPagination = false,
}) {
  if (countAsPagination) {
    return 72;
  }

  if (message == null) {
    return 180;
  }

  final isArchivedAssistant =
      message.role == 'assistant' &&
      message.metadata?['archivedVariant'] == true;
  if (isArchivedAssistant) {
    return 0;
  }

  final width = crossAxisExtent.clamp(280.0, 960.0);
  final contentLength = message.content.trim().length;
  final charsPerLine = (width / (message.role == 'user' ? 7.8 : 7.0)).clamp(
    26.0,
    96.0,
  );
  final estimatedLineCount = math.max(1, (contentLength / charsPerLine).ceil());

  var estimate = message.role == 'user' ? 84.0 : 132.0;
  estimate += estimatedLineCount * 22.0;

  if (message.error != null) {
    estimate += 64.0;
  }
  if (message.files != null && message.files!.isNotEmpty) {
    estimate += 180.0;
  }
  if (message.sources.isNotEmpty) {
    estimate += 68.0;
  }
  if (message.followUps.isNotEmpty && message.role == 'assistant') {
    estimate += 92.0;
  }
  if (message.statusHistory.isNotEmpty) {
    estimate += math.min(message.statusHistory.length, 4) * 32.0;
  }
  if (message.codeExecutions.isNotEmpty) {
    estimate += math.min(message.codeExecutions.length, 2) * 180.0;
  }
  if (message.output != null && message.output!.isNotEmpty) {
    estimate += math.min(message.output!.length, 3) * 72.0;
  }

  return estimate.clamp(84.0, 2400.0);
}
