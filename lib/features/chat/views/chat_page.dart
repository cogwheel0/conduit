import 'package:flutter/material.dart';
import 'package:conduit/l10n/app_localizations.dart';
import '../../../core/widgets/error_boundary.dart';
import '../../../shared/widgets/optimized_list.dart';
import '../../../shared/theme/theme_extensions.dart';
import 'package:flutter/services.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'dart:io' show Platform;
import '../../../shared/widgets/responsive_drawer_layout.dart';
import '../../navigation/widgets/chats_drawer.dart';
import 'dart:async';
import '../../../core/providers/app_providers.dart';
import '../providers/chat_providers.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../core/utils/user_display_name.dart';
import '../../../core/utils/model_icon_utils.dart';
import '../../auth/providers/unified_auth_providers.dart';

import '../widgets/modern_chat_input.dart';
import '../widgets/user_message_bubble.dart';
import '../widgets/assistant_message_widget.dart' as assistant;
import '../widgets/streaming_title_text.dart';
import '../widgets/file_attachment_widget.dart';
import '../services/voice_input_service.dart';
import '../services/file_attachment_service.dart';
import 'voice_call_page.dart';
import '../../../shared/services/tasks/task_queue.dart';
import '../../tools/providers/tools_providers.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/model.dart';
import '../../../shared/widgets/loading_states.dart';
import 'chat_page_helpers.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../onboarding/views/onboarding_sheet.dart';
import '../../../shared/widgets/sheet_handle.dart';
import '../../../shared/widgets/measure_size.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/middle_ellipsis_text.dart';
import '../../../shared/widgets/modal_safe_area.dart';
import '../../../core/services/settings_service.dart';
import '../../../shared/utils/conversation_context_menu.dart';
import '../../../shared/widgets/model_avatar.dart';
import '../../../core/services/platform_service.dart' as ps;
import 'package:flutter/gestures.dart' show DragStartBehavior;

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key});

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final ScrollController _scrollController = ScrollController();
  bool _showScrollToBottom = false;
  bool _isSelectionMode = false;
  final Set<String> _selectedMessageIds = <String>{};
  Timer? _scrollDebounceTimer;
  bool _isDeactivated = false;
  double _inputHeight = 0; // dynamic input height to position scroll button
  bool _lastKeyboardVisible = false; // track keyboard visibility transitions
  bool _didStartupFocus = false; // one-time auto-focus on startup
  String? _lastConversationId;
  bool _shouldAutoScrollToBottom = true;
  bool _autoScrollCallbackScheduled = false;
  bool _pendingConversationScrollReset = false;
  bool _suppressKeepPinnedOnce = false; // skip keep-pinned bottom after reset
  String? _cachedGreetingName;
  bool _greetingReady = false;

  String _formatModelDisplayName(String name) {
    return name.trim();
  }

  bool validateFileCount(int currentCount, int newCount, int maxCount) {
    return (currentCount + newCount) <= maxCount;
  }

  bool validateFileSize(int fileSize, int maxSizeMB) {
    return fileSize <= (maxSizeMB * 1024 * 1024);
  }

  void startNewChat() {
    // Clear current conversation
    ref.read(chatMessagesProvider.notifier).clearMessages();
    ref.read(activeConversationProvider.notifier).clear();

    // Scroll to top
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }

    _shouldAutoScrollToBottom = true;
    _pendingConversationScrollReset = false;
    _scheduleAutoScrollToBottom();
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

    DebugLogger.log('auto-select-start', scope: 'chat/model');

    try {
      // First ensure models are loaded
      final modelsAsync = ref.read(modelsProvider);
      List<Model> models;

      if (modelsAsync.hasValue) {
        models = modelsAsync.value!;
      } else {
        DebugLogger.log('models-fetch', scope: 'chat/model');
        models = await ref.read(modelsProvider.future);
      }

      DebugLogger.log(
        'models-count',
        scope: 'chat/model',
        data: {'count': models.length},
      );

      if (models.isEmpty) {
        DebugLogger.warning('models-empty', scope: 'chat/model');
        return;
      }

      // Try to use the default model provider
      try {
        final Model? model = await ref.read(defaultModelProvider.future);
        if (model != null) {
          DebugLogger.log(
            'auto-select',
            scope: 'chat/model',
            data: {'name': model.name},
          );
        }
      } catch (e) {
        DebugLogger.warning('provider-fallback', scope: 'chat/model');
        // Fallback: select the first available model
        ref.read(selectedModelProvider.notifier).set(models.first);
        DebugLogger.log(
          'fallback',
          scope: 'chat/model',
          data: {'name': models.first.name},
        );
      }
    } catch (e) {
      DebugLogger.error('auto-select-failed', scope: 'chat/model', error: e);
    }
  }

  Future<void> _checkAndShowOnboarding() async {
    try {
      // Check if onboarding has been seen
      final storage = ref.read(optimizedStorageServiceProvider);
      final seen = await storage.getOnboardingSeen();
      DebugLogger.log(
        'onboarding-status',
        scope: 'chat/onboarding',
        data: {'seen': seen},
      );

      if (!seen && mounted) {
        // Small delay to ensure navigation has settled
        await Future.delayed(const Duration(milliseconds: 500));
        if (!mounted) return;

        DebugLogger.log('onboarding-show', scope: 'chat/onboarding');
        _showOnboarding();
        await storage.setOnboardingSeen(true);
        DebugLogger.log('onboarding-marked', scope: 'chat/onboarding');
      }
    } catch (e) {
      DebugLogger.error(
        'onboarding-status-failed',
        scope: 'chat/onboarding',
        error: e,
      );
    }
  }

  void _showOnboarding() {
    try {
      ref.read(composerAutofocusEnabledProvider.notifier).set(false);
    } catch (_) {}
    try {
      FocusManager.instance.primaryFocus?.unfocus();
      SystemChannels.textInput.invokeMethod('TextInput.hide');
    } catch (_) {}

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: context.conduitTheme.surfaceBackground,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppBorderRadius.modal),
          ),
          boxShadow: ConduitShadows.modal(context),
        ),
        child: const OnboardingSheet(),
      ),
    ).whenComplete(() {
      if (!mounted) return;
      try {
        ref.read(composerAutofocusEnabledProvider.notifier).set(true);
      } catch (_) {}
    });
  }

  Future<void> _checkAndLoadDemoConversation() async {
    if (!mounted) return;
    final isReviewerMode = ref.read(reviewerModeProvider);
    if (!isReviewerMode) return;

    // Check if there's already an active conversation
    if (!mounted) return;
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

    _scheduleAutoScrollToBottom();

    // Initialize chat page components
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // First, ensure a model is selected
      await _checkAndAutoSelectModel();
      if (!mounted) return;

      // Then check for demo conversation in reviewer mode
      await _checkAndLoadDemoConversation();
      if (!mounted) return;

      // Finally, show onboarding if needed
      await _checkAndShowOnboarding();
    });
  }

  @override
  void dispose() {
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

  void _handleMessageSend(String text, dynamic selectedModel) async {
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

      // Enqueue task-based send to unify flow across text, images, and tools
      final activeConv = ref.read(activeConversationProvider);
      await ref
          .read(taskQueueProvider.notifier)
          .enqueueSendText(
            conversationId: activeConv?.id,
            text: text,
            attachments: uploadedFileIds.isNotEmpty ? uploadedFileIds : null,
            toolIds: toolIds.isNotEmpty ? toolIds : null,
          );

      // Clear attachments after successful send
      ref.read(attachedFilesProvider.notifier).clearAll();

      // Scroll to bottom after enqueuing (only if user was near bottom)
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // Only auto-scroll if user was already near the bottom (within 300 px)
        final distanceFromBottom = _distanceFromBottom();
        if (distanceFromBottom <= 300) {
          _scrollToBottom();
        }
      });
    } catch (e) {
      // Message send failed - error already handled by sendMessage
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

      // Validate file count
      final currentFiles = ref.read(attachedFilesProvider);
      if (!validateFileCount(currentFiles.length, attachments.length, 10)) {
        if (!mounted) return;
        return;
      }

      // Validate file sizes
      for (final attachment in attachments) {
        final fileSize = await attachment.file.length();
        if (!validateFileSize(fileSize, 20)) {
          if (!mounted) return;
          return;
        }
      }

      // Add files to the attachment list
      ref.read(attachedFilesProvider.notifier).addFiles(attachments);

      // Enqueue uploads via task queue for unified retry/progress
      final activeConv = ref.read(activeConversationProvider);
      for (final attachment in attachments) {
        try {
          await ref
              .read(taskQueueProvider.notifier)
              .enqueueUploadMedia(
                conversationId: activeConv?.id,
                filePath: attachment.file.path,
                fileName: attachment.displayName,
                fileSize: await attachment.file.length(),
              );
        } catch (e) {
          if (!mounted) return;
          DebugLogger.log('Enqueue upload failed: $e', scope: 'chat/page');
        }
      }
    } catch (e) {
      if (!mounted) return;
      DebugLogger.log('File selection failed: $e', scope: 'chat/page');
    }
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
      final attachment = fromCamera
          ? await fileService.takePhoto()
          : await fileService.pickImage();
      if (attachment == null) {
        DebugLogger.log('No image selected', scope: 'chat/page');
        return;
      }

      DebugLogger.log(
        'Image selected: ${attachment.file.path}',
        scope: 'chat/page',
      );
      DebugLogger.log(
        'Image display name: ${attachment.displayName}',
        scope: 'chat/page',
      );
      final imageSize = await attachment.file.length();
      DebugLogger.log('Image size: $imageSize bytes', scope: 'chat/page');

      // Validate file size (default 20MB limit like OpenWebUI)
      if (!validateFileSize(imageSize, 20)) {
        if (!mounted) return;
        return;
      }

      // Validate file count (default 10 files limit like OpenWebUI)
      final currentFiles = ref.read(attachedFilesProvider);
      if (!validateFileCount(currentFiles.length, 1, 10)) {
        if (!mounted) return;
        return;
      }

      // Add image to the attachment list
      ref.read(attachedFilesProvider.notifier).addFiles([attachment]);
      DebugLogger.log('Image added to attachment list', scope: 'chat/page');

      // Enqueue upload via task queue for unified retry/progress
      DebugLogger.log('Enqueueing image upload...', scope: 'chat/page');
      final activeConv = ref.read(activeConversationProvider);
      try {
        await ref
            .read(taskQueueProvider.notifier)
            .enqueueUploadMedia(
              conversationId: activeConv?.id,
              filePath: attachment.file.path,
              fileName: attachment.displayName,
              fileSize: imageSize,
            );
      } catch (e) {
        DebugLogger.log('Enqueue image upload failed: $e', scope: 'chat/page');
      }
    } catch (e) {
      DebugLogger.log('Image attachment error: $e', scope: 'chat/page');
      if (!mounted) return;
    }
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

  void _handleVoiceCall() {
    // Navigate to voice call page
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => const VoiceCallPage(),
        fullscreenDialog: true,
      ),
    );
  }

  // Replaced bottom-sheet chat list with left drawer (see ChatsDrawer)

  void _onScroll() {
    if (!_scrollController.hasClients) return;

    // Debounce scroll handling to reduce rebuilds
    if (_scrollDebounceTimer?.isActive == true) return;

    _scrollDebounceTimer = Timer(const Duration(milliseconds: 80), () {
      if (!mounted || _isDeactivated || !_scrollController.hasClients) return;

      final maxScroll = _scrollController.position.maxScrollExtent;
      final distanceFromBottom = _distanceFromBottom();

      const double showThreshold = 300.0;
      const double hideThreshold = 150.0;

      final bool farFromBottom = distanceFromBottom > showThreshold;
      final bool nearBottom = distanceFromBottom <= hideThreshold;
      final bool hasScrollableContent =
          maxScroll.isFinite && maxScroll > showThreshold;

      final bool showButton = _showScrollToBottom
          ? !nearBottom && hasScrollableContent
          : farFromBottom && hasScrollableContent;

      if (showButton != _showScrollToBottom && mounted && !_isDeactivated) {
        setState(() {
          _showScrollToBottom = showButton;
        });
      }
    });
  }

  double _distanceFromBottom() {
    if (!_scrollController.hasClients) {
      return double.infinity;
    }
    final position = _scrollController.position;
    final maxScroll = position.maxScrollExtent;
    if (!maxScroll.isFinite) {
      return double.infinity;
    }
    final distance = maxScroll - position.pixels;
    return distance >= 0 ? distance : 0.0;
  }

  void _scheduleAutoScrollToBottom() {
    if (_autoScrollCallbackScheduled) return;
    _autoScrollCallbackScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoScrollCallbackScheduled = false;
      if (!mounted || !_shouldAutoScrollToBottom) return;
      if (!_scrollController.hasClients) {
        _scheduleAutoScrollToBottom();
        return;
      }
      _scrollToBottom(smooth: false);
      _shouldAutoScrollToBottom = false;
    });
  }

  void _resetScrollToTop() {
    if (!_scrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) {
          return;
        }
        _scrollController.jumpTo(0);
      });
      return;
    }

    if (_scrollController.position.pixels != 0) {
      _scrollController.jumpTo(0);
    }
  }

  void _scrollToBottom({bool smooth = true}) {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final maxScroll = position.maxScrollExtent;
    final target = maxScroll.isFinite ? maxScroll : 0.0;
    if (smooth) {
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
      );
    } else {
      _scrollController.jumpTo(target);
    }
  }

  void _toggleSelectionMode() {
    setState(() {
      _isSelectionMode = !_isSelectionMode;
      if (!_isSelectionMode) {
        _selectedMessageIds.clear();
      }
    });
  }

  void _toggleMessageSelection(String messageId) {
    setState(() {
      if (_selectedMessageIds.contains(messageId)) {
        _selectedMessageIds.remove(messageId);
        if (_selectedMessageIds.isEmpty) {
          _isSelectionMode = false;
        }
      } else {
        _selectedMessageIds.add(messageId);
      }
    });
  }

  void _clearSelection() {
    setState(() {
      _selectedMessageIds.clear();
      _isSelectionMode = false;
    });
  }

  List<ChatMessage> _getSelectedMessages() {
    final messages = ref.read(chatMessagesProvider);
    return messages.where((m) => _selectedMessageIds.contains(m.id)).toList();
  }

  Widget _buildMessagesList(ThemeData theme) {
    // Use select to watch only the messages list to reduce rebuilds
    final messages = ref.watch(
      chatMessagesProvider.select((messages) => messages),
    );
    final isLoadingConversation = ref.watch(isLoadingConversationProvider);

    // Use AnimatedSwitcher for smooth transition between loading and loaded states
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 400),
      switchInCurve: Curves.easeInOut,
      switchOutCurve: Curves.easeInOut,
      layoutBuilder: (currentChild, previousChildren) {
        return Stack(
          alignment: Alignment.topCenter,
          children: <Widget>[
            ...previousChildren,
            if (currentChild != null) currentChild,
          ],
        );
      },
      child: isLoadingConversation && messages.isEmpty
          ? _buildLoadingMessagesList()
          : _buildActualMessagesList(messages),
    );
  }

  Widget _buildLoadingMessagesList() {
    // Use slivers to align with the actual messages view.
    // Do not attach the primary scroll controller here to avoid
    // AnimatedSwitcher attaching the same controller twice.
    return CustomScrollView(
      key: const ValueKey('loading_messages'),
      controller: null,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      physics: const AlwaysScrollableScrollPhysics(),
      cacheExtent: 300,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.lg,
            Spacing.md,
            Spacing.lg,
            Spacing.lg,
          ),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate((context, index) {
              final isUser = index.isOdd;
              return Align(
                alignment: isUser
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.only(bottom: Spacing.md),
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.82,
                  ),
                  padding: const EdgeInsets.all(Spacing.md),
                  decoration: BoxDecoration(
                    color: isUser
                        ? context.conduitTheme.buttonPrimary.withValues(
                            alpha: 0.15,
                          )
                        : context.conduitTheme.cardBackground,
                    borderRadius: BorderRadius.circular(
                      AppBorderRadius.messageBubble,
                    ),
                    border: Border.all(
                      color: context.conduitTheme.cardBorder,
                      width: BorderWidth.regular,
                    ),
                    boxShadow: ConduitShadows.messageBubble(context),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        height: 14,
                        width: index % 3 == 0 ? 140 : 220,
                        decoration: BoxDecoration(
                          color: context.conduitTheme.shimmerBase,
                          borderRadius: BorderRadius.circular(
                            AppBorderRadius.xs,
                          ),
                        ),
                      ).animate().shimmer(duration: AnimationDuration.slow),
                      const SizedBox(height: Spacing.xs),
                      Container(
                        height: 14,
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: context.conduitTheme.shimmerBase,
                          borderRadius: BorderRadius.circular(
                            AppBorderRadius.xs,
                          ),
                        ),
                      ).animate().shimmer(duration: AnimationDuration.slow),
                      if (index % 3 != 0) ...[
                        const SizedBox(height: Spacing.xs),
                        Container(
                          height: 14,
                          width: index % 2 == 0 ? 180 : 120,
                          decoration: BoxDecoration(
                            color: context.conduitTheme.shimmerBase,
                            borderRadius: BorderRadius.circular(
                              AppBorderRadius.xs,
                            ),
                          ),
                        ).animate().shimmer(duration: AnimationDuration.slow),
                      ],
                    ],
                  ),
                ),
              );
            }, childCount: 6),
          ),
        ),
      ],
    );
  }

  Widget _buildActualMessagesList(List<ChatMessage> messages) {
    if (messages.isEmpty) {
      return _buildEmptyState(Theme.of(context));
    }

    final apiService = ref.watch(apiServiceProvider);

    if (_pendingConversationScrollReset) {
      _pendingConversationScrollReset = false;
      if (messages.length <= 1) {
        _shouldAutoScrollToBottom = true;
      } else {
        // When opening an existing conversation, start reading from the top
        _shouldAutoScrollToBottom = false;
        _resetScrollToTop();
        _suppressKeepPinnedOnce = true;
      }
    }

    if (_shouldAutoScrollToBottom) {
      _scheduleAutoScrollToBottom();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_suppressKeepPinnedOnce) {
          // Skip the one-time keep-pinned-to-bottom adjustment right after
          // a conversation switch so we remain at the top.
          _suppressKeepPinnedOnce = false;
          return;
        }
        const double keepPinnedThreshold = 60.0;
        final distanceFromBottom = _distanceFromBottom();
        if (distanceFromBottom > 0 &&
            distanceFromBottom <= keepPinnedThreshold) {
          _scrollToBottom(smooth: false);
        }
      });
    }

    return CustomScrollView(
      key: const ValueKey('actual_messages'),
      controller: _scrollController,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      physics: const AlwaysScrollableScrollPhysics(),
      cacheExtent: 600,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.lg,
            Spacing.md,
            Spacing.lg,
            Spacing.lg,
          ),
          sliver: OptimizedSliverList<ChatMessage>(
            items: messages,
            itemBuilder: (context, message, index) {
              final isUser = message.role == 'user';
              final isStreaming = message.isStreaming;

              final isSelected = _selectedMessageIds.contains(message.id);

              // Resolve a friendly model display name for message headers
              String? displayModelName;
              Model? matchedModel;
              final rawModel = message.model;
              if (rawModel != null && rawModel.isNotEmpty) {
                final modelsAsync = ref.watch(modelsProvider);
                if (modelsAsync.hasValue) {
                  final models = modelsAsync.value!;
                  try {
                    // Prefer exact ID match; fall back to exact name match
                    final match = models.firstWhere(
                      (m) => m.id == rawModel || m.name == rawModel,
                    );
                    matchedModel = match;
                    displayModelName = _formatModelDisplayName(match.name);
                  } catch (_) {
                    // As a fallback, format the raw value to be more readable
                    displayModelName = _formatModelDisplayName(rawModel);
                  }
                } else {
                  // Models not loaded yet; format raw value for readability
                  displayModelName = _formatModelDisplayName(rawModel);
                }
              }

              final modelIconUrl = resolveModelIconUrlForModel(
                apiService,
                matchedModel,
              );

              var hasUserBubbleBelow = false;
              var hasAssistantBubbleBelow = false;
              for (var i = index + 1; i < messages.length; i++) {
                final role = messages[i].role;
                if (role == 'user') {
                  hasUserBubbleBelow = true;
                  break;
                }
                if (role == 'assistant') {
                  hasAssistantBubbleBelow = true;
                  break;
                }
              }

              // Hide archived assistant variants in the linear view
              final isArchivedVariant =
                  !isUser && (message.metadata?['archivedVariant'] == true);
              if (isArchivedVariant) {
                return const SizedBox.shrink();
              }

              final showFollowUps =
                  !isUser && !hasUserBubbleBelow && !hasAssistantBubbleBelow;

              // Wrap message in selection container if in selection mode
              Widget messageWidget;

              // Use documentation style for assistant messages, bubble for user messages
              if (isUser) {
                messageWidget = UserMessageBubble(
                  key: ValueKey('user-${message.id}'),
                  message: message,
                  isUser: isUser,
                  isStreaming: isStreaming,
                  modelName: displayModelName,
                  onCopy: () => _copyMessage(message.content),
                  onRegenerate: () => _regenerateMessage(message),
                );
              } else {
                messageWidget = assistant.AssistantMessageWidget(
                  key: ValueKey('assistant-${message.id}'),
                  message: message,
                  isStreaming: isStreaming,
                  showFollowUps: showFollowUps,
                  modelName: displayModelName,
                  modelIconUrl: modelIconUrl,
                  onCopy: () => _copyMessage(message.content),
                  onRegenerate: () => _regenerateMessage(message),
                );
              }

              // Add selection functionality if in selection mode
              if (_isSelectionMode) {
                return _SelectableMessageWrapper(
                  isSelected: isSelected,
                  onTap: () => _toggleMessageSelection(message.id),
                  onLongPress: () {
                    if (!_isSelectionMode) {
                      _toggleSelectionMode();
                      _toggleMessageSelection(message.id);
                    }
                  },
                  child: messageWidget,
                );
              } else {
                return GestureDetector(
                  onLongPress: () {
                    _toggleSelectionMode();
                    _toggleMessageSelection(message.id);
                  },
                  child: messageWidget,
                );
              }
            },
          ),
        ),
      ],
    );
  }

  void _copyMessage(String content) {
    // Strip reasoning details from the copied content
    String cleanedContent = content;

    // Remove <details type="reasoning"> blocks
    cleanedContent = cleanedContent.replaceAll(
      RegExp(
        r'<details\s+type="reasoning"[^>]*>[\s\S]*?<\/details>',
        multiLine: true,
        dotAll: true,
      ),
      '',
    );

    // Remove raw reasoning tags
    cleanedContent = cleanedContent.replaceAll(
      RegExp(r'<think>[\s\S]*?<\/think>', multiLine: true, dotAll: true),
      '',
    );
    cleanedContent = cleanedContent.replaceAll(
      RegExp(
        r'<reasoning>[\s\S]*?<\/reasoning>',
        multiLine: true,
        dotAll: true,
      ),
      '',
    );

    // Clean up any extra whitespace
    cleanedContent = cleanedContent.trim();

    Clipboard.setData(ClipboardData(text: cleanedContent));
  }

  void _regenerateMessage(dynamic message) async {
    final selectedModel = ref.read(selectedModelProvider);
    if (selectedModel == null) {
      return;
    }

    // Find the user message that prompted this assistant response
    final messages = ref.read(chatMessagesProvider);
    final messageIndex = messages.indexOf(message);

    if (messageIndex <= 0 || messages[messageIndex - 1].role != 'user') {
      return;
    }

    try {
      // If assistant message has generated images and it's the last message,
      // use image-only regenerate flow instead of text SSE regeneration
      if (message.role == 'assistant' &&
          (message.files?.any((f) => f['type'] == 'image') == true) &&
          messageIndex == messages.length - 1) {
        final regenerateImages = ref.read(regenerateLastMessageProvider);
        await regenerateImages();
        return;
      }

      // Mark previous assistant as archived for UI; keep it for server history
      ref.read(chatMessagesProvider.notifier).updateLastMessageWithFunction((
        m,
      ) {
        final meta = Map<String, dynamic>.from(m.metadata ?? const {});
        meta['archivedVariant'] = true;
        return m.copyWith(metadata: meta, isStreaming: false);
      });

      // Regenerate response for the previous user message (without duplicating it)
      final userMessage = messages[messageIndex - 1];
      await regenerateMessage(
        ref,
        userMessage.content,
        userMessage.attachmentIds,
      );
    } catch (e) {
      DebugLogger.log('Regenerate failed: $e', scope: 'chat/page');
    }
  }

  // Inline editing handled by UserMessageBubble. Dialog flow removed.

  Widget _buildEmptyState(ThemeData theme) {
    final l10n = AppLocalizations.of(context)!;
    final currentUserAsync = ref.watch(currentUserProvider);
    final userFromProfile = currentUserAsync.maybeWhen(
      data: (user) => user,
      orElse: () => null,
    );
    final authUser = ref.watch(currentUserProvider2);
    final user = userFromProfile ?? authUser;
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
    final greetingStyle = theme.textTheme.headlineSmall?.copyWith(
      fontWeight: FontWeight.w600,
      color: context.conduitTheme.textPrimary,
    );
    final greetingHeight =
        (greetingStyle?.fontSize ?? 24) * (greetingStyle?.height ?? 1.1);
    final String? resolvedGreetingName = hasGreeting ? greetingName : null;
    final greetingText = resolvedGreetingName != null
        ? l10n.onboardStartTitle(resolvedGreetingName)
        : null;
    return LayoutBuilder(
      builder: (context, constraints) {
        final greetingDisplay = greetingText ?? '';

        return MediaQuery.removeViewInsets(
          context: context,
          removeBottom: true,
          child: SizedBox(
            width: double.infinity,
            height: constraints.maxHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                mainAxisSize: MainAxisSize.max,
                children: [
                  SizedBox(
                    height: greetingHeight,
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
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // Removed detailed help items from chat page; guidance now lives in Onboarding

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    // Use select to watch only the selected model to reduce rebuilds
    final selectedModel = ref.watch(
      selectedModelProvider.select((model) => model),
    );

    // Watch reviewer mode and auto-select model if needed
    final isReviewerMode = ref.watch(reviewerModeProvider);

    final conversationId = ref.watch(
      activeConversationProvider.select((conv) => conv?.id),
    );
    if (conversationId != _lastConversationId) {
      _lastConversationId = conversationId;
      if (conversationId == null) {
        _shouldAutoScrollToBottom = true;
        _pendingConversationScrollReset = false;
        _scheduleAutoScrollToBottom();
      } else {
        _pendingConversationScrollReset = true;
        _shouldAutoScrollToBottom = false;
      }
    }
    final conversationTitle = ref.watch(
      activeConversationProvider.select((conv) => conv?.title),
    );
    final trimmedConversationTitle = conversationTitle?.trim();
    final displayConversationTitle =
        (trimmedConversationTitle != null &&
            trimmedConversationTitle.isNotEmpty)
        ? trimmedConversationTitle
        : null;
    final formattedModelName = selectedModel != null
        ? _formatModelDisplayName(selectedModel.name)
        : null;
    final modelLabel = formattedModelName ?? l10n.chooseModel;
    final hasConversationTitle = displayConversationTitle != null;
    final TextStyle modelTextStyle = hasConversationTitle
        ? AppTypography.small.copyWith(
            color: context.conduitTheme.textSecondary,
            fontWeight: FontWeight.w600,
            height: 1.2,
          )
        : AppTypography.headlineSmallStyle.copyWith(
            color: context.conduitTheme.textPrimary,
            fontWeight: FontWeight.w600,
            fontSize: 18,
            height: 1.3,
          );

    // Keyboard visibility
    final keyboardVisible = MediaQuery.of(context).viewInsets.bottom > 0;
    // Whether the messages list can actually scroll (avoids showing button when not needed)
    final canScroll =
        _scrollController.hasClients &&
        _scrollController.position.maxScrollExtent > 0;

    // On keyboard open, if already near bottom, auto-scroll to bottom to keep input visible
    if (keyboardVisible && !_lastKeyboardVisible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final distanceFromBottom = _distanceFromBottom();
        if (distanceFromBottom <= 300) {
          _scrollToBottom(smooth: true);
        }
      });
    }

    _lastKeyboardVisible = keyboardVisible;

    // Auto-select model when in reviewer mode with no selection
    if (isReviewerMode && selectedModel == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _checkAndAutoSelectModel();
      });
    }

    // Focus composer on app startup once
    if (!_didStartupFocus) {
      _didStartupFocus = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Future.delayed(const Duration(milliseconds: 200), () {
          if (!mounted) return;
          final current = ref.read(inputFocusTriggerProvider);
          ref.read(inputFocusTriggerProvider.notifier).set(current + 1);
        });
      });
    }

    return ErrorBoundary(
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (bool didPop, Object? result) async {
          if (didPop) return;

          // First, if any input has focus, clear focus and consume back press
          final currentFocus = FocusManager.instance.primaryFocus;
          if (currentFocus != null && currentFocus.hasFocus) {
            currentFocus.unfocus();
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
        child: Builder(
          builder: (outerCtx) {
            final size = MediaQuery.of(outerCtx).size;
            final isTablet = size.shortestSide >= 600;
            final maxFraction = isTablet ? 0.42 : 0.84;
            final edgeFraction = isTablet ? 0.36 : 0.50; // large phone edge
            final scrim = Platform.isIOS
                ? context.colorTokens.scrimMedium
                : context.colorTokens.scrimStrong;

            return ResponsiveDrawerLayout(
              maxFraction: maxFraction,
              edgeFraction: edgeFraction,
              settleFraction: 0.06, // even gentler settle for instant open feel
              scrimColor: scrim,
              contentScaleDelta: 0.0,
              contentBlurSigma: 0.0,
              tabletDrawerWidth: 320.0,
              onOpenStart: () {
                // Suppress composer auto-focus once we unfocus for the drawer
                try {
                  ref
                      .read(composerAutofocusEnabledProvider.notifier)
                      .set(false);
                } catch (_) {}
              },
              drawer: Container(
                color: context.sidebarTheme.background,
                child: SafeArea(
                  top: true,
                  bottom: true,
                  left: false,
                  right: false,
                  child: const ChatsDrawer(),
                ),
              ),
              child: Scaffold(
                backgroundColor: context.conduitTheme.surfaceBackground,
                // Replace Scaffold drawer with a tunable slide drawer for gentler snap behavior.
                drawerEnableOpenDragGesture: false,
                drawerDragStartBehavior: DragStartBehavior.down,
                appBar: AppBar(
                  backgroundColor: context.conduitTheme.surfaceBackground,
                  elevation: Elevation.none,
                  surfaceTintColor: Colors.transparent,
                  shadowColor: Colors.transparent,
                  toolbarHeight: kToolbarHeight + 8,
                  centerTitle: true,
                  titleSpacing: 0.0,
                  leading: _isSelectionMode
                      ? IconButton(
                          icon: Icon(
                            Platform.isIOS ? CupertinoIcons.xmark : Icons.close,
                            color: context.conduitTheme.textPrimary,
                            size: IconSize.appBar,
                          ),
                          onPressed: _clearSelection,
                        )
                      : Builder(
                          builder: (ctx) => Padding(
                            padding: const EdgeInsets.only(
                              left: Spacing.inputPadding,
                            ),
                            child: IconButton(
                              onPressed: () {
                                // Suppress auto-focus and dismiss keyboard, then toggle drawer
                                try {
                                  ref
                                      .read(
                                        composerAutofocusEnabledProvider
                                            .notifier,
                                      )
                                      .set(false);
                                  FocusManager.instance.primaryFocus
                                      ?.unfocus();
                                  SystemChannels.textInput.invokeMethod(
                                    'TextInput.hide',
                                  );
                                } catch (_) {}
                                ResponsiveDrawerLayout.of(ctx)?.toggle();
                              },
                              icon: Icon(
                                Platform.isIOS
                                    ? CupertinoIcons.line_horizontal_3
                                    : Icons.menu,
                                color: context.conduitTheme.textPrimary,
                                size: IconSize.appBar,
                              ),
                            ),
                          ),
                        ),
                  title: _isSelectionMode
                      ? Text(
                          '${_selectedMessageIds.length} selected',
                          style: AppTypography.headlineSmallStyle.copyWith(
                            color: context.conduitTheme.textPrimary,
                            fontWeight: FontWeight.w500,
                          ),
                        )
                      : GestureDetector(
                          onTap: () async {
                            final modelsAsync = ref.read(modelsProvider);

                            // Handle all async states properly
                            if (modelsAsync.isLoading) {
                              // If still loading, wait for it to complete
                              try {
                                final models = await ref.read(
                                  modelsProvider.future,
                                );
                                // Check mounted and use context immediately together
                                if (!mounted) return;
                                // ignore: use_build_context_synchronously
                                _showModelDropdown(context, ref, models);
                              } catch (e) {
                                DebugLogger.error(
                                  'model-load-failed',
                                  scope: 'chat/model-selector',
                                  error: e,
                                );
                              }
                            } else if (modelsAsync.hasValue) {
                              // If we have data, show immediately (no async gap)
                              _showModelDropdown(
                                context,
                                ref,
                                modelsAsync.value!,
                              );
                            } else if (modelsAsync.hasError) {
                              // If there's an error, try to refresh and load
                              try {
                                ref.invalidate(modelsProvider);
                                final models = await ref.read(
                                  modelsProvider.future,
                                );
                                // Check mounted and use context immediately together
                                if (!mounted) return;
                                // ignore: use_build_context_synchronously
                                _showModelDropdown(context, ref, models);
                              } catch (e) {
                                DebugLogger.error(
                                  'model-refresh-failed',
                                  scope: 'chat/model-selector',
                                  error: e,
                                );
                              }
                            }
                          },
                          onLongPress: () {
                            final conversation = ref.read(
                              activeConversationProvider,
                            );
                            if (conversation == null) return;
                            showConversationContextMenu(
                              context: context,
                              ref: ref,
                              conversation: conversation,
                            );
                          },
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 250),
                                switchInCurve: Curves.easeOutCubic,
                                switchOutCurve: Curves.easeInCubic,
                                child: displayConversationTitle != null
                                    ? Column(
                                        key: ValueKey<String>(
                                          displayConversationTitle,
                                        ),
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          StreamingTitleText(
                                            title: displayConversationTitle,
                                            style: AppTypography
                                                .headlineSmallStyle
                                                .copyWith(
                                                  color: context
                                                      .conduitTheme
                                                      .textPrimary,
                                                  fontWeight: FontWeight.w600,
                                                  fontSize: 18,
                                                  height: 1.3,
                                                ),
                                            cursorColor: context
                                                .conduitTheme
                                                .textPrimary
                                                .withValues(alpha: 0.8),
                                          ),
                                          const SizedBox(height: Spacing.xs),
                                        ],
                                      )
                                    : const SizedBox.shrink(
                                        key: ValueKey<String>('empty-title'),
                                      ),
                              ),
                              Transform.translate(
                                offset: const Offset(0, 0),
                                child: () {
                                  final row = Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Opacity(
                                        opacity: 0.0,
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: Spacing.xs,
                                            vertical: Spacing.xxs,
                                          ),
                                          decoration: BoxDecoration(
                                            color: context
                                                .conduitTheme
                                                .surfaceBackground
                                                .withValues(alpha: 0.3),
                                            borderRadius: BorderRadius.circular(
                                              AppBorderRadius.badge,
                                            ),
                                            border: Border.all(
                                              color: context
                                                  .conduitTheme
                                                  .dividerColor,
                                              width: BorderWidth.thin,
                                            ),
                                          ),
                                          child: Icon(
                                            Platform.isIOS
                                                ? CupertinoIcons.chevron_down
                                                : Icons.keyboard_arrow_down,
                                            color: context
                                                .conduitTheme
                                                .iconSecondary,
                                            size: IconSize.small,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: Spacing.xs),
                                      Flexible(
                                        child: MiddleEllipsisText(
                                          modelLabel,
                                          style: modelTextStyle,
                                          textAlign: TextAlign.center,
                                          semanticsLabel: modelLabel,
                                        ),
                                      ),
                                      const SizedBox(width: Spacing.xs),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: Spacing.xs,
                                          vertical: Spacing.xxs,
                                        ),
                                        decoration: BoxDecoration(
                                          color: context
                                              .conduitTheme
                                              .surfaceBackground
                                              .withValues(alpha: 0.3),
                                          borderRadius: BorderRadius.circular(
                                            AppBorderRadius.badge,
                                          ),
                                          border: Border.all(
                                            color: context
                                                .conduitTheme
                                                .dividerColor,
                                            width: BorderWidth.thin,
                                          ),
                                        ),
                                        child: Icon(
                                          Platform.isIOS
                                              ? CupertinoIcons.chevron_down
                                              : Icons.keyboard_arrow_down,
                                          color: context
                                              .conduitTheme
                                              .iconSecondary,
                                          size: IconSize.small,
                                        ),
                                      ),
                                    ],
                                  );
                                  return hasConversationTitle
                                      ? SizedBox(height: 24, child: row)
                                      : row;
                                }(),
                              ),
                              if (isReviewerMode)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2.0),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: Spacing.sm,
                                      vertical: 1.0,
                                    ),
                                    decoration: BoxDecoration(
                                      color: context.conduitTheme.success
                                          .withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(
                                        AppBorderRadius.badge,
                                      ),
                                      border: Border.all(
                                        color: context.conduitTheme.success
                                            .withValues(alpha: 0.3),
                                        width: BorderWidth.thin,
                                      ),
                                    ),
                                    child: Text(
                                      'REVIEWER MODE',
                                      style: AppTypography.captionStyle
                                          .copyWith(
                                            color: context.conduitTheme.success,
                                            fontWeight: FontWeight.w600,
                                            fontSize: 9,
                                          ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                  actions: [
                    if (!_isSelectionMode) ...[
                      Padding(
                        padding: const EdgeInsets.only(
                          right: Spacing.inputPadding,
                        ),
                        child: IconButton(
                          icon: Icon(
                            Platform.isIOS
                                ? CupertinoIcons.create
                                : Icons.add_comment,
                            color: context.conduitTheme.textPrimary,
                            size: IconSize.appBar,
                          ),
                          onPressed: _handleNewChat,
                          tooltip: AppLocalizations.of(context)!.newChat,
                        ),
                      ),
                    ] else ...[
                      IconButton(
                        icon: Icon(
                          Platform.isIOS ? CupertinoIcons.delete : Icons.delete,
                          color: context.conduitTheme.error,
                          size: IconSize.appBar,
                        ),
                        onPressed: _deleteSelectedMessages,
                      ),
                    ],
                  ],
                ),
                body: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () {
                    FocusManager.instance.primaryFocus?.unfocus();
                    try {
                      SystemChannels.textInput.invokeMethod('TextInput.hide');
                    } catch (_) {}
                  },
                  child: Stack(
                    children: [
                      Column(
                        children: [
                          // Messages Area with pull-to-refresh
                          Expanded(
                            child: ConduitRefreshIndicator(
                              onRefresh: () async {
                                // Reload active conversation messages from server
                                final api = ref.read(apiServiceProvider);
                                final active = ref.read(
                                  activeConversationProvider,
                                );
                                if (api != null && active != null) {
                                  try {
                                    final full = await api.getConversation(
                                      active.id,
                                    );
                                    ref
                                        .read(
                                          activeConversationProvider.notifier,
                                        )
                                        .set(full);
                                  } catch (e) {
                                    DebugLogger.log(
                                      'Failed to refresh conversation: $e',
                                      scope: 'chat/page',
                                    );
                                  }
                                }

                                // Also refresh the conversations list to reconcile missed events
                                // and keep timestamps/order in sync with the server.
                                try {
                                  refreshConversationsCache(ref);
                                  // Best-effort await to stabilize UI; ignore errors.
                                  await ref.read(conversationsProvider.future);
                                } catch (_) {}

                                // Add small delay for better UX feedback
                                await Future.delayed(
                                  const Duration(milliseconds: 300),
                                );
                              },
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () {
                                  FocusManager.instance.primaryFocus?.unfocus();
                                  try {
                                    SystemChannels.textInput.invokeMethod(
                                      'TextInput.hide',
                                    );
                                  } catch (_) {}
                                },
                                child: RepaintBoundary(
                                  child: _buildMessagesList(theme),
                                ),
                              ),
                            ),
                          ),

                          // File attachments
                          const FileAttachmentWidget(),

                          // Modern Input (root matches input background including safe area)
                          RepaintBoundary(
                            child: MeasureSize(
                              onChange: (size) {
                                if (mounted) {
                                  setState(() {
                                    _inputHeight = size.height;
                                  });
                                }
                              },
                              child: ModernChatInput(
                                onSendMessage: (text) =>
                                    _handleMessageSend(text, selectedModel),
                                onVoiceInput: null,
                                onVoiceCall: _handleVoiceCall,
                                onFileAttachment: _handleFileAttachment,
                                onImageAttachment: _handleImageAttachment,
                                onCameraCapture: () =>
                                    _handleImageAttachment(fromCamera: true),
                              ),
                            ),
                          ),
                        ],
                      ),

                      // Floating Scroll to Bottom Button with smooth appear/disappear
                      Positioned(
                        bottom:
                            ((_inputHeight > 0)
                                ? _inputHeight
                                : (Spacing.xxl + Spacing.xxxl)) +
                            Spacing.sm,
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
                          child:
                              (_showScrollToBottom &&
                                  !keyboardVisible &&
                                  canScroll &&
                                  ref.watch(chatMessagesProvider).isNotEmpty)
                              ? Center(
                                  key: const ValueKey(
                                    'scroll_to_bottom_visible',
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(
                                      AppBorderRadius.floatingButton,
                                    ),
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: context
                                            .conduitTheme
                                            .surfaceContainerHighest
                                            .withValues(alpha: 0.75),
                                        border: Border.all(
                                          color: context.conduitTheme.cardBorder
                                              .withValues(alpha: 0.3),
                                          width: BorderWidth.regular,
                                        ),
                                        borderRadius: BorderRadius.circular(
                                          AppBorderRadius.floatingButton,
                                        ),
                                        boxShadow: ConduitShadows.button(
                                          context,
                                        ),
                                      ),
                                      child: SizedBox(
                                        width: TouchTarget.button,
                                        height: TouchTarget.button,
                                        child: IconButton(
                                          onPressed: _scrollToBottom,
                                          splashRadius: 24,
                                          icon: Icon(
                                            Platform.isIOS
                                                ? CupertinoIcons.arrow_down
                                                : Icons.keyboard_arrow_down,
                                            size: IconSize.lg,
                                            color: context
                                                .conduitTheme
                                                .iconPrimary
                                                .withValues(alpha: 0.9),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                )
                              : const SizedBox.shrink(
                                  key: ValueKey('scroll_to_bottom_hidden'),
                                ),
                        ),
                      ),
                      // Edge overlay removed; rely on native interactive drawer drag
                    ],
                  ),
                ),
              ), // Scaffold inside ResponsiveDrawerLayout
            );
          },
        ),
      ), // PopScope
    ); // ErrorBoundary
  }

  // Removed legacy save-before-leave hook; server manages chat state via background pipeline.

  void _showModelDropdown(
    BuildContext context,
    WidgetRef ref,
    List<Model> models,
  ) {
    // Ensure keyboard is closed before presenting modal
    final hadFocus = ref.read(composerHasFocusProvider);
    try {
      FocusManager.instance.primaryFocus?.unfocus();
      SystemChannels.textInput.invokeMethod('TextInput.hide');
    } catch (_) {}
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _ModelSelectorSheet(models: models, ref: ref),
    ).whenComplete(() {
      if (!mounted) return;
      if (hadFocus) {
        // Bump focus trigger to restore composer focus + IME
        final cur = ref.read(inputFocusTriggerProvider);
        ref.read(inputFocusTriggerProvider.notifier).set(cur + 1);
      }
    });
  }

  void _deleteSelectedMessages() {
    final selectedMessages = _getSelectedMessages();
    if (selectedMessages.isEmpty) return;

    final l10n = AppLocalizations.of(context)!;
    ThemedDialogs.confirm(
      context,
      title: l10n.deleteMessagesTitle,
      message: l10n.deleteMessagesMessage(selectedMessages.length),
      confirmText: l10n.delete,
      cancelText: l10n.cancel,
      isDestructive: true,
    ).then((confirmed) async {
      if (confirmed == true) {
        // for (final selectedMessage in selectedMessages) {
        //   ref.read(chatMessagesProvider.notifier).removeMessage(selectedMessage.id);
        // }
        _clearSelection();
        if (mounted) {}
      }
    });
  }
}

class _ModelSelectorSheet extends ConsumerStatefulWidget {
  final List<Model> models;
  final WidgetRef ref;

  const _ModelSelectorSheet({required this.models, required this.ref});

  @override
  ConsumerState<_ModelSelectorSheet> createState() =>
      _ModelSelectorSheetState();
}

class _ModelSelectorSheetState extends ConsumerState<_ModelSelectorSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  List<Model> _filteredModels = [];
  Timer? _searchDebounce;
  // No capability filters
  // Grid view removed

  Widget _capabilityChip({required IconData icon, required String label}) {
    return Container(
      margin: const EdgeInsets.only(right: Spacing.xs),
      padding: const EdgeInsets.symmetric(horizontal: Spacing.xs, vertical: 2),
      decoration: BoxDecoration(
        color: context.conduitTheme.buttonPrimary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppBorderRadius.chip),
        border: Border.all(
          color: context.conduitTheme.buttonPrimary.withValues(alpha: 0.3),
          width: BorderWidth.thin,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: context.conduitTheme.buttonPrimary),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: AppTypography.labelSmall,
              color: context.conduitTheme.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  // Removed filter toggle UI and logic

  @override
  void initState() {
    super.initState();
    _filteredModels = widget.models;
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  void _filterModels(String query) {
    setState(() => _searchQuery = query);

    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 160), () {
      if (!mounted) return;

      final normalized = query.trim().toLowerCase();
      Iterable<Model> list = widget.models;

      if (normalized.isNotEmpty) {
        list = list.where((model) {
          final name = model.name.toLowerCase();
          final id = model.id.toLowerCase();
          return name.contains(normalized) || id.contains(normalized);
        });
      }

      setState(() {
        _filteredModels = list.toList();
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.of(context).maybePop(),
            child: const SizedBox.shrink(),
          ),
        ),
        DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.75,
          maxChildSize: 0.92,
          minChildSize: 0.45,
          builder: (context, scrollController) {
            return Container(
              decoration: BoxDecoration(
                color: context.conduitTheme.surfaceBackground,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(AppBorderRadius.bottomSheet),
                ),
                border: Border.all(
                  color: context.conduitTheme.dividerColor,
                  width: BorderWidth.regular,
                ),
                boxShadow: ConduitShadows.modal(context),
              ),
              child: ModalSheetSafeArea(
                padding: const EdgeInsets.symmetric(
                  horizontal: Spacing.modalPadding,
                  vertical: Spacing.modalPadding,
                ),
                child: Column(
                  children: [
                    // Handle bar (standardized)
                    const SheetHandle(),

                    // Search field
                    Padding(
                      padding: const EdgeInsets.only(bottom: Spacing.md),
                      child: TextField(
                        controller: _searchController,
                        style: AppTypography.standard.copyWith(
                          color: context.conduitTheme.textPrimary,
                        ),
                        onChanged: _filterModels,
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: AppLocalizations.of(context)!.searchModels,
                          hintStyle: AppTypography.standard.copyWith(
                            color: context.conduitTheme.inputPlaceholder,
                          ),
                          prefixIcon: Icon(
                            Platform.isIOS
                                ? CupertinoIcons.search
                                : Icons.search,
                            color: context.conduitTheme.iconSecondary,
                            size: IconSize.input,
                          ),
                          prefixIconConstraints: const BoxConstraints(
                            minWidth: TouchTarget.minimum,
                            minHeight: TouchTarget.minimum,
                          ),
                          suffixIcon: _searchQuery.isNotEmpty
                              ? IconButton(
                                  onPressed: () {
                                    _searchController.clear();
                                    _filterModels('');
                                  },
                                  icon: Icon(
                                    Platform.isIOS
                                        ? CupertinoIcons.clear_circled_solid
                                        : Icons.clear,
                                    color: context.conduitTheme.iconSecondary,
                                    size: IconSize.input,
                                  ),
                                )
                              : null,
                          suffixIconConstraints: const BoxConstraints(
                            minWidth: TouchTarget.minimum,
                            minHeight: TouchTarget.minimum,
                          ),
                          filled: true,
                          fillColor: context.conduitTheme.inputBackground,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(
                              AppBorderRadius.md,
                            ),
                            borderSide: BorderSide.none,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(
                              AppBorderRadius.md,
                            ),
                            borderSide: BorderSide(
                              color: context.conduitTheme.inputBorder,
                              width: 1,
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(
                              AppBorderRadius.md,
                            ),
                            borderSide: BorderSide(
                              color: context.conduitTheme.buttonPrimary,
                              width: 1,
                            ),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: Spacing.md,
                            vertical: Spacing.xs,
                          ),
                        ),
                      ),
                    ),

                    // Removed capability filters
                    const SizedBox(height: Spacing.sm),

                    // Models list
                    Expanded(
                      child: Scrollbar(
                        controller: scrollController,
                        child: _filteredModels.isEmpty
                            ? Center(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Platform.isIOS
                                          ? CupertinoIcons.search_circle
                                          : Icons.search_off,
                                      size: 48,
                                      color: context.conduitTheme.iconSecondary,
                                    ),
                                    const SizedBox(height: Spacing.md),
                                    Text(
                                      'No results',
                                      style: TextStyle(
                                        color:
                                            context.conduitTheme.textSecondary,
                                        fontSize: AppTypography.bodyLarge,
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            : ListView.builder(
                                controller: scrollController,
                                padding: EdgeInsets.zero,
                                cacheExtent: 400,
                                itemCount: _filteredModels.length,
                                itemBuilder: (context, index) {
                                  final model = _filteredModels[index];
                                  final isSelected =
                                      widget.ref
                                          .watch(selectedModelProvider)
                                          ?.id ==
                                      model.id;

                                  return _buildModelListTile(
                                    model: model,
                                    isSelected: isSelected,
                                    onTap: () {
                                      HapticFeedback.selectionClick();
                                      widget.ref
                                          .read(selectedModelProvider.notifier)
                                          .set(model);
                                      Navigator.pop(context);
                                    },
                                  );
                                },
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  // Layout toggle removed

  // Removed grid card renderer (grid view removed)

  bool _modelSupportsReasoning(Model model) {
    // Only rely on supported_parameters containing 'reasoning'
    final params = model.supportedParameters ?? const [];
    return params.any((p) => p.toLowerCase().contains('reasoning'));
  }

  // Removed: _capabilityBadge no longer used

  // Removed: _capabilityPlusBadge no longer used

  Widget _buildModelListTile({
    required Model model,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final api = ref.watch(apiServiceProvider);
    final iconUrl = resolveModelIconUrlForModel(api, model);
    return PressableScale(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppBorderRadius.small),
      child: Container(
        margin: const EdgeInsets.only(bottom: Spacing.sm),
        decoration: BoxDecoration(
          color: isSelected
              ? context.conduitTheme.buttonPrimary.withValues(alpha: 0.1)
              : context.conduitTheme.surfaceBackground.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(AppBorderRadius.small),
          border: Border.all(
            color: isSelected
                ? context.conduitTheme.buttonPrimary.withValues(alpha: 0.3)
                : context.conduitTheme.dividerColor.withValues(alpha: 0.5),
            width: BorderWidth.standard,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(Spacing.sm),
          child: Row(
            children: [
              ModelAvatar(size: 32, imageUrl: iconUrl, label: model.name),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      model.name,
                      style: TextStyle(
                        color: context.conduitTheme.textPrimary,
                        fontWeight: FontWeight.w600,
                        fontSize: AppTypography.bodyMedium,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (model.isMultimodal ||
                        _modelSupportsReasoning(model)) ...[
                      const SizedBox(height: Spacing.xs),
                      Row(
                        children: [
                          if (model.isMultimodal)
                            _capabilityChip(
                              icon: Platform.isIOS
                                  ? CupertinoIcons.photo
                                  : Icons.image,
                              label: AppLocalizations.of(
                                context,
                              )!.modelCapabilityMultimodal,
                            ),
                          if (_modelSupportsReasoning(model))
                            _capabilityChip(
                              icon: Platform.isIOS
                                  ? CupertinoIcons.lightbulb
                                  : Icons.psychology_alt,
                              label: AppLocalizations.of(
                                context,
                              )!.modelCapabilityReasoning,
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: Spacing.sm),
              if (isSelected)
                Icon(
                  Platform.isIOS ? CupertinoIcons.check_mark : Icons.check,
                  color: context.conduitTheme.buttonPrimary,
                  size: IconSize.small,
                ),
            ],
          ),
        ),
      ),
    );
  }

  // Intentionally left blank placeholder for nested helper; moved to top-level below
}

// Removed custom edge gesture in favor of native Drawer drag behavior.

class _VoiceInputSheet extends ConsumerStatefulWidget {
  final Function(String) onTextReceived;

  const _VoiceInputSheet({required this.onTextReceived});

  @override
  ConsumerState<_VoiceInputSheet> createState() => _VoiceInputSheetState();
}

class _VoiceInputSheetState extends ConsumerState<_VoiceInputSheet> {
  bool _isListening = false;
  String _recognizedText = '';
  late VoiceInputService _voiceService;
  StreamSubscription<int>? _intensitySub;
  int _intensity = 0;
  StreamSubscription<String>? _textSub;
  int _elapsedSeconds = 0;
  Timer? _elapsedTimer;
  // Removed server transcription; keep only on-device listening state
  String _languageTag = 'en';
  bool _holdToTalk = false;
  bool _autoSendFinal = false;

  @override
  void initState() {
    super.initState();
    _voiceService = ref.read(voiceInputServiceProvider);
    try {
      final preset = _voiceService.selectedLocaleId;
      if (preset != null && preset.isNotEmpty) {
        _languageTag = preset.split(RegExp('[-_]')).first.toLowerCase();
      } else {
        _languageTag = WidgetsBinding.instance.platformDispatcher.locale
            .toLanguageTag()
            .split(RegExp('[-_]'))
            .first
            .toLowerCase();
      }
    } catch (_) {
      _languageTag = 'en';
    }
    // Load voice settings from app settings
    final settings = ref.read(appSettingsProvider);
    _holdToTalk = settings.voiceHoldToTalk;
    _autoSendFinal = settings.voiceAutoSendFinal;
    if (settings.voiceLocaleId != null && settings.voiceLocaleId!.isNotEmpty) {
      _voiceService.setLocale(settings.voiceLocaleId);
      _languageTag = settings.voiceLocaleId!
          .split(RegExp('[-_]'))
          .first
          .toLowerCase();
    }
  }

  void _startListening() async {
    setState(() {
      _isListening = true;
      _recognizedText = '';
      _elapsedSeconds = 0;
    });
    // Haptic: indicate start listening
    final hapticEnabled = ref.read(hapticEnabledProvider);
    ps.PlatformService.hapticFeedbackWithSettings(
      type: ps.HapticType.medium,
      hapticEnabled: hapticEnabled,
    );

    try {
      // Ensure service is initialized
      final ok = await _voiceService.initialize();
      if (!ok) {
        throw Exception('Voice service unavailable');
      }

      // Start elapsed timer for UX
      _elapsedTimer?.cancel();
      _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted || !_isListening) {
          t.cancel();
          return;
        }
        setState(() => _elapsedSeconds += 1);
      });

      // Centralized permission + start
      final stream = await _voiceService.beginListening();
      _intensitySub = _voiceService.intensityStream.listen((value) {
        if (!mounted) return;
        setState(() => _intensity = value);
      });
      _textSub = stream.listen(
        (text) {
          setState(() {
            _recognizedText = text;
          });
        },
        onDone: () {
          DebugLogger.log('VoiceInputSheet stream done', scope: 'chat/page');
          setState(() {
            _isListening = false;
          });
          _elapsedTimer?.cancel();
          // Auto-send on final local result if enabled
          if (_autoSendFinal && _recognizedText.trim().isNotEmpty) {
            _sendText();
          }
        },
        onError: (error) {
          DebugLogger.log(
            'VoiceInputSheet stream error: $error',
            scope: 'chat/page',
          );
          setState(() {
            _isListening = false;
          });
          _elapsedTimer?.cancel();
          if (mounted) {
            final hapticEnabled = ref.read(hapticEnabledProvider);
            ps.PlatformService.hapticFeedbackWithSettings(
              type: ps.HapticType.warning,
              hapticEnabled: hapticEnabled,
            );
          }
        },
      );
    } catch (e) {
      setState(() {
        _isListening = false;
      });
      if (mounted) {}
    }
  }

  // When on-device STT is unavailable we fall back to server transcription.

  Future<void> _stopListening() async {
    _intensitySub?.cancel();
    _intensitySub = null;
    // Keep text subscription active to receive final audio path emission
    await _voiceService.stopListening();
    _elapsedTimer?.cancel();
    if (mounted) {
      setState(() {
        _isListening = false;
      });
    }
    // Haptic: subtle stop confirmation
    final hapticEnabled = ref.read(hapticEnabledProvider);
    ps.PlatformService.hapticFeedbackWithSettings(
      type: ps.HapticType.selection,
      hapticEnabled: hapticEnabled,
    );
  }

  void _sendText() {
    if (_recognizedText.isNotEmpty) {
      // Haptic: success send
      final hapticEnabled = ref.read(hapticEnabledProvider);
      ps.PlatformService.hapticFeedbackWithSettings(
        type: ps.HapticType.success,
        hapticEnabled: hapticEnabled,
      );
      widget.onTextReceived(_recognizedText);
      Navigator.pop(context);
    }
  }

  String _formatSeconds(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(1, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  void _pickLanguage() async {
    // Only for local STT
    if (!_voiceService.hasLocalStt) return;
    final locales = _voiceService.locales;
    if (locales.isEmpty) return;
    if (!mounted) return;
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final l10n = AppLocalizations.of(context)!;
        return Container(
          decoration: BoxDecoration(
            color: context.conduitTheme.surfaceBackground,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(AppBorderRadius.bottomSheet),
            ),
            border: Border.all(
              color: context.conduitTheme.dividerColor,
              width: BorderWidth.regular,
            ),
            boxShadow: ConduitShadows.modal(context),
          ),
          padding: const EdgeInsets.all(Spacing.bottomSheetPadding),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SheetHandle(),
                const SizedBox(height: Spacing.md),
                Text(
                  l10n.selectLanguage,
                  style: TextStyle(
                    fontSize: AppTypography.headlineSmall,
                    color: context.conduitTheme.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: Spacing.sm),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: locales.length,
                    separatorBuilder: (_, sep) => Divider(
                      height: 1,
                      color: context.conduitTheme.dividerColor,
                    ),
                    itemBuilder: (ctx, i) {
                      final l = locales[i];
                      final isSelected =
                          l.localeId == _voiceService.selectedLocaleId;
                      return ListTile(
                        title: Text(
                          l.name,
                          style: TextStyle(
                            color: context.conduitTheme.textPrimary,
                          ),
                        ),
                        subtitle: Text(
                          l.localeId,
                          style: TextStyle(
                            color: context.conduitTheme.textSecondary,
                          ),
                        ),
                        trailing: isSelected
                            ? Icon(
                                Icons.check,
                                color: context.conduitTheme.buttonPrimary,
                              )
                            : null,
                        onTap: () => Navigator.pop(ctx, l.localeId),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (selected != null && mounted) {
      setState(() {
        _voiceService.setLocale(selected);
        _languageTag = selected.split(RegExp('[-_]')).first.toLowerCase();
      });
      // Persist preferred locale
      await ref.read(appSettingsProvider.notifier).setVoiceLocaleId(selected);
      if (_isListening) {
        // Restart listening to apply new language
        await _voiceService.stopListening();
        _startListening();
      }
    }
  }

  Widget _buildThemedSwitch({
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final theme = context.conduitTheme;
    return ps.PlatformService.getPlatformSwitch(
      value: value,
      onChanged: onChanged,
      activeColor: theme.buttonPrimary,
    );
  }

  @override
  void dispose() {
    _intensitySub?.cancel();
    _textSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final isCompact = media.size.height < 680;
    final l10n = AppLocalizations.of(context)!;
    final statusText = _isListening
        ? (_voiceService.hasLocalStt
              ? l10n.voiceStatusListening
              : l10n.voiceStatusRecording)
        : l10n.voice;
    return Container(
      height: media.size.height * (isCompact ? 0.45 : 0.6),
      decoration: BoxDecoration(
        color: context.conduitTheme.surfaceBackground,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppBorderRadius.bottomSheet),
        ),
        border: Border.all(color: context.conduitTheme.dividerColor, width: 1),
        boxShadow: ConduitShadows.modal(context),
      ),
      child: SafeArea(
        top: false,
        bottom: true,
        child: Padding(
          padding: const EdgeInsets.all(Spacing.bottomSheetPadding),
          child: Column(
            children: [
              // Handle bar
              const SheetHandle(),

              // Header: Title + timer + language chip
              Padding(
                padding: const EdgeInsets.only(
                  top: Spacing.md,
                  bottom: Spacing.md,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      statusText,
                      style: TextStyle(
                        fontSize: AppTypography.headlineMedium,
                        fontWeight: FontWeight.w600,
                        color: context.conduitTheme.textPrimary,
                      ),
                    ),
                    Row(
                      children: [
                        // Language chip
                        GestureDetector(
                          onTap: _voiceService.hasLocalStt
                              ? _pickLanguage
                              : null,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: Spacing.xs,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: context.conduitTheme.surfaceBackground
                                  .withValues(alpha: 0.4),
                              borderRadius: BorderRadius.circular(
                                AppBorderRadius.badge,
                              ),
                              border: Border.all(
                                color: context.conduitTheme.dividerColor,
                                width: BorderWidth.thin,
                              ),
                            ),
                            child: Row(
                              children: [
                                Text(
                                  _languageTag.toUpperCase(),
                                  style: TextStyle(
                                    fontSize: AppTypography.labelSmall,
                                    color: context.conduitTheme.textSecondary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                if (_voiceService.hasLocalStt) ...[
                                  const SizedBox(width: 4),
                                  Icon(
                                    Icons.arrow_drop_down,
                                    size: 16,
                                    color: context.conduitTheme.iconSecondary,
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: Spacing.sm),
                        // Timer
                        AnimatedOpacity(
                          opacity: _isListening ? 1 : 0.6,
                          duration: AnimationDuration.fast,
                          child: Text(
                            _formatSeconds(_elapsedSeconds),
                            style: TextStyle(
                              color: context.conduitTheme.textSecondary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: Spacing.sm),
                        // Close sheet
                        ConduitIconButton(
                          icon: Platform.isIOS
                              ? CupertinoIcons.xmark
                              : Icons.close,
                          tooltip: AppLocalizations.of(
                            context,
                          )!.closeButtonSemantic,
                          isCompact: true,
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // Toggles row: Hold to talk, Auto-send
              Padding(
                padding: const EdgeInsets.only(bottom: Spacing.sm),
                child: Row(
                  children: [
                    Expanded(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildThemedSwitch(
                            value: _holdToTalk,
                            onChanged: (v) async {
                              setState(() => _holdToTalk = v);
                              await ref
                                  .read(appSettingsProvider.notifier)
                                  .setVoiceHoldToTalk(v);
                            },
                          ),
                          const SizedBox(width: Spacing.xs),
                          Text(
                            l10n.voiceHoldToTalk,
                            style: TextStyle(
                              color: context.conduitTheme.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          _buildThemedSwitch(
                            value: _autoSendFinal,
                            onChanged: (v) async {
                              setState(() => _autoSendFinal = v);
                              await ref
                                  .read(appSettingsProvider.notifier)
                                  .setVoiceAutoSendFinal(v);
                            },
                          ),
                          const SizedBox(width: Spacing.xs),
                          Text(
                            l10n.voiceAutoSend,
                            style: TextStyle(
                              color: context.conduitTheme.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // Microphone + waveform
              Expanded(
                child: LayoutBuilder(
                  builder: (context, viewport) {
                    final isUltra = media.size.height < 560;
                    final double micSize = isUltra
                        ? 64
                        : (isCompact ? 80 : 100);
                    final double micIconSize = isUltra
                        ? 26
                        : (isCompact ? 32 : 40);
                    // Extra top padding so scale animation (up to 1.2x) never clips
                    final double topPaddingForScale =
                        ((micSize * 1.2) - micSize) / 2 + 8;

                    final content = Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // Top spacer (baseline); additional padding handled by scroll view
                          SizedBox(height: isUltra ? Spacing.sm : Spacing.md),
                          // Microphone control
                          GestureDetector(
                                onTapDown: _holdToTalk
                                    ? (_) {
                                        if (!_isListening) _startListening();
                                      }
                                    : null,
                                onTapUp: _holdToTalk
                                    ? (_) {
                                        if (_isListening) _stopListening();
                                      }
                                    : null,
                                onTapCancel: _holdToTalk
                                    ? () {
                                        if (_isListening) _stopListening();
                                      }
                                    : null,
                                onTap: () => _holdToTalk
                                    ? null
                                    : (_isListening
                                          ? _stopListening()
                                          : _startListening()),
                                child: Container(
                                  width: micSize,
                                  height: micSize,
                                  decoration: BoxDecoration(
                                    color: _isListening
                                        ? context.conduitTheme.error.withValues(
                                            alpha: 0.2,
                                          )
                                        : context.conduitTheme.surfaceBackground
                                              .withValues(alpha: Alpha.subtle),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: _isListening
                                          ? context.conduitTheme.error
                                                .withValues(alpha: 0.5)
                                          : context.conduitTheme.dividerColor,
                                      width: 2,
                                    ),
                                  ),
                                  child: Icon(
                                    _isListening
                                        ? (Platform.isIOS
                                              ? CupertinoIcons.mic_fill
                                              : Icons.mic)
                                        : (Platform.isIOS
                                              ? CupertinoIcons.mic_off
                                              : Icons.mic_off),
                                    size: micIconSize,
                                    color: _isListening
                                        ? context.conduitTheme.error
                                        : context.conduitTheme.iconSecondary,
                                  ),
                                ),
                              )
                              .animate(
                                onPlay: (controller) =>
                                    _isListening ? controller.repeat() : null,
                              )
                              .scale(
                                duration: const Duration(milliseconds: 1000),
                                begin: const Offset(1, 1),
                                end: const Offset(1.2, 1.2),
                              )
                              .then()
                              .scale(
                                duration: const Duration(milliseconds: 1000),
                                begin: const Offset(1.2, 1.2),
                                end: const Offset(1, 1),
                              ),

                          SizedBox(
                            height: isUltra
                                ? Spacing.xs
                                : (isCompact ? Spacing.sm : Spacing.md),
                          ),
                          // Simple animated bars waveform based on intensity proxy
                          SizedBox(
                            height: isUltra ? 18 : (isCompact ? 24 : 32),
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 150),
                              child: Row(
                                key: ValueKey<int>(_intensity),
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: List.generate(isUltra ? 10 : 12, (i) {
                                  final normalized =
                                      ((_intensity + i) % 10) / 10.0;
                                  final base = isUltra
                                      ? 4
                                      : (isCompact ? 6 : 8);
                                  final range = isUltra
                                      ? 14
                                      : (isCompact ? 18 : 24);
                                  final barHeight = base + (normalized * range);
                                  return Container(
                                    width: isUltra ? 2.5 : (isCompact ? 3 : 4),
                                    height: barHeight,
                                    margin: EdgeInsets.symmetric(
                                      horizontal: isUltra
                                          ? 1
                                          : (isCompact ? 1.5 : 2),
                                    ),
                                    decoration: BoxDecoration(
                                      color: context.conduitTheme.buttonPrimary
                                          .withValues(alpha: 0.7),
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  );
                                }),
                              ),
                            ),
                          ),
                          SizedBox(
                            height: isUltra
                                ? Spacing.sm
                                : (isCompact ? Spacing.md : Spacing.xl),
                          ),

                          // Recognized text / Transcribing state with Clear action
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight:
                                  media.size.height *
                                  (isUltra ? 0.13 : (isCompact ? 0.16 : 0.2)),
                              minHeight: isUltra ? 56 : (isCompact ? 64 : 80),
                            ),
                            child: ConduitCard(
                              isCompact: isCompact,
                              padding: EdgeInsets.all(
                                isCompact ? Spacing.md : Spacing.md,
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  // Inline clear action aligned to the end
                                  Row(
                                    children: [
                                      Text(
                                        l10n.voiceTranscript,
                                        style: TextStyle(
                                          fontSize: AppTypography.labelSmall,
                                          fontWeight: FontWeight.w600,
                                          color: context
                                              .conduitTheme
                                              .textSecondary,
                                        ),
                                      ),
                                      const Spacer(),
                                      ConduitIconButton(
                                        icon: Icons.close,
                                        isCompact: true,
                                        tooltip: AppLocalizations.of(
                                          context,
                                        )!.clear,
                                        onPressed: _recognizedText.isNotEmpty
                                            ? () {
                                                setState(
                                                  () => _recognizedText = '',
                                                );
                                              }
                                            : null,
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: Spacing.xs),
                                  Flexible(
                                    child: SingleChildScrollView(
                                      child: Text(
                                        _recognizedText.isEmpty
                                            ? (_isListening
                                                  ? (_voiceService.hasLocalStt
                                                        ? l10n.voicePromptSpeakNow
                                                        : l10n.voiceStatusRecording)
                                                  : l10n.voicePromptTapStart)
                                            : _recognizedText,
                                        style: TextStyle(
                                          fontSize: isUltra
                                              ? AppTypography.bodySmall
                                              : (isCompact
                                                    ? AppTypography.bodyMedium
                                                    : AppTypography.bodyLarge),
                                          color: _recognizedText.isEmpty
                                              ? context
                                                    .conduitTheme
                                                    .inputPlaceholder
                                              : context
                                                    .conduitTheme
                                                    .textPrimary,
                                          height: 1.4,
                                        ),
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    );

                    // Make scrollable if content exceeds available height
                    return SingleChildScrollView(
                      physics: const ClampingScrollPhysics(),
                      padding: EdgeInsets.only(top: topPaddingForScale),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: viewport.maxHeight,
                        ),
                        child: content,
                      ),
                    );
                  },
                ),
              ),

              // Action buttons
              Builder(
                builder: (context) {
                  final showStartStop = !_holdToTalk;
                  final showSend = !_autoSendFinal;
                  if (!showStartStop && !showSend) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: EdgeInsets.only(
                      top: isCompact ? Spacing.sm : Spacing.md,
                    ),
                    child: Row(
                      children: [
                        if (showStartStop) ...[
                          Expanded(
                            child: ConduitButton(
                              text: _isListening
                                  ? l10n.voiceActionStop
                                  : l10n.voiceActionStart,
                              isSecondary: true,
                              isCompact: isCompact,
                              onPressed: _isListening
                                  ? _stopListening
                                  : _startListening,
                            ),
                          ),
                        ],
                        if (showStartStop && showSend)
                          const SizedBox(width: Spacing.xs),
                        if (showSend) ...[
                          Expanded(
                            child: ConduitButton(
                              text: l10n.send,
                              isCompact: isCompact,
                              onPressed: _recognizedText.isNotEmpty
                                  ? _sendText
                                  : null,
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Wrapper widget for selectable messages with visual selection indicators
class _SelectableMessageWrapper extends StatelessWidget {
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Widget child;

  const _SelectableMessageWrapper({
    required this.isSelected,
    required this.onTap,
    this.onLongPress,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: Spacing.xs),
        decoration: BoxDecoration(
          color: isSelected
              ? context.conduitTheme.buttonPrimary.withValues(alpha: 0.1)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(AppBorderRadius.md),
          border: isSelected
              ? Border.all(
                  color: context.conduitTheme.buttonPrimary.withValues(
                    alpha: 0.3,
                  ),
                  width: 2,
                )
              : null,
        ),
        child: Stack(
          children: [
            child,
            if (isSelected)
              Positioned(
                top: Spacing.sm,
                right: Spacing.sm,
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: context.conduitTheme.buttonPrimary,
                    shape: BoxShape.circle,
                    boxShadow: ConduitShadows.medium(context),
                  ),
                  child: Icon(
                    Icons.check,
                    color: context.conduitTheme.textInverse,
                    size: 16,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// Extension on _ChatPageState for utility methods
extension on _ChatPageState {}
