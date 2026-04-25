import 'package:flutter/material.dart';
import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:conduit/l10n/app_localizations.dart';
import '../../../core/widgets/error_boundary.dart';
import '../../../shared/widgets/optimized_list.dart';
import '../../../shared/theme/conduit_input_styles.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/glass_colors.dart';
import 'package:flutter/services.dart';
import 'package:conduit/core/services/haptic_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:super_sliver_list/super_sliver_list.dart';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show kIsWeb;

import '../../../shared/widgets/responsive_drawer_layout.dart';
import 'dart:async';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/settings_service.dart';
import '../../auth/providers/unified_auth_providers.dart';
import '../providers/chat_providers.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../core/utils/user_display_name.dart';
import '../../../core/utils/model_icon_utils.dart';
import '../../../shared/widgets/markdown/markdown_preprocessor.dart';
import '../../../core/utils/android_assistant_handler.dart';
import '../widgets/model_selector_sheet.dart';
import '../widgets/modern_chat_input.dart';
import '../widgets/selectable_message_wrapper.dart';
import '../widgets/user_message_bubble.dart';
import '../widgets/assistant_message_widget.dart' as assistant;
import '../widgets/file_attachment_widget.dart';
import '../widgets/context_attachment_widget.dart';
import '../widgets/server_file_picker_sheet.dart';
import '../services/file_attachment_service.dart';
import '../services/historical_message_regeneration.dart';
import '../voice_call/presentation/voice_call_launcher.dart';
import '../../../shared/services/tasks/task_queue.dart';
import '../../tools/providers/tools_providers.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/folder.dart';
import '../../../core/models/model.dart';
import '../providers/context_attachments_provider.dart';
import '../../../shared/widgets/conduit_loading.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../shared/widgets/measure_size.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/middle_ellipsis_text.dart';
import 'package:flutter/gestures.dart' show DragStartBehavior;

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key});

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final ScrollController _scrollController = ScrollController();
  final ListController _messageListController = ListController();
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
  final Map<String, double> _savedScrollOffsets = {};
  bool _pendingScrollRestore = false;
  double _restoreScrollOffset = 0;
  bool _userPausedAutoScroll = false; // user scrolled away during generation
  bool _isUserInteractingWithScroll = false;
  // Pin-to-top: scroll user message to top of viewport when sending
  bool _wantsPinToTop = false;
  GlobalKey _pinnedUserMessageKey = GlobalKey();
  String? _pinnedStreamingId; // tracks which streaming msg triggered pin
  String? _cachedGreetingName;
  bool _greetingReady = false;
  final _extentPrecalculationPolicy = _ChatExtentPrecalculationPolicy();

  String _formatModelDisplayName(String name) {
    return name.trim();
  }

  ({String? displayName, Model? matchedModel}) _resolveModelPresentation({
    required String? rawModel,
    required List<Model>? models,
  }) {
    final trimmedModel = rawModel?.trim();
    if (trimmedModel == null || trimmedModel.isEmpty) {
      return (displayName: null, matchedModel: null);
    }

    if (models != null) {
      for (final model in models) {
        if (model.id == trimmedModel || model.name == trimmedModel) {
          return (
            displayName: _formatModelDisplayName(model.name),
            matchedModel: model,
          );
        }
      }
    }

    return (
      displayName: _formatModelDisplayName(trimmedModel),
      matchedModel: null,
    );
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

    _shouldAutoScrollToBottom = true;
    _pendingScrollRestore = false;
    _restoreScrollOffset = 0;
    _userPausedAutoScroll = false;
    _wantsPinToTop = false;
    _pinnedStreamingId = null;
    _endPinToTopInFlight = false;
    _scheduleAutoScrollToBottom();

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
    // Listen for screen context from Android Assistant
    final screenContext = ref.watch(screenContextProvider);
    if (screenContext != null && screenContext.isNotEmpty) {
      // Clear the context so we don't process it again
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(screenContextProvider.notifier).setContext(null);
        final currentModel = ref.read(selectedModelProvider);
        _handleMessageSend(
          "Here is the content of my screen:\n\n$screenContext\n\nCan you summarize this?",
          currentModel,
        );
      });
    }
  }

  @override
  void dispose() {
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

  void _handleMessageSend(String text, dynamic selectedModel) async {
    if (ref.read(isLoadingConversationProvider)) {
      return;
    }

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

      // Reset auto-scroll pause when user sends a new message
      _userPausedAutoScroll = false;

      // Pin-to-top: the detection in _buildActualMessagesList will handle
      // scrolling to the user message once the streaming placeholder appears.
      // Set _shouldAutoScrollToBottom = false so it doesn't fight with pin.
      _shouldAutoScrollToBottom = false;
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

  void _handleServerFileAttachment() {
    final fileUploadCapableModels = ref.read(fileUploadCapableModelsProvider);
    if (fileUploadCapableModels.isEmpty || !mounted) {
      return;
    }

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
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

    // Enqueue uploads via task queue for unified retry/progress
    final activeConv = ref.read(activeConversationProvider);
    for (final attachment in attachments) {
      try {
        final fileSize = await attachment.file.length();
        DebugLogger.log(
          'Pasted file: ${attachment.displayName}, size: $fileSize bytes',
          scope: 'chat/page',
        );
        await ref
            .read(taskQueueProvider.notifier)
            .enqueueUploadMedia(
              conversationId: activeConv?.id,
              filePath: attachment.file.path,
              fileName: attachment.displayName,
              fileSize: fileSize,
            );
      } catch (e) {
        DebugLogger.log('Enqueue pasted upload failed: $e', scope: 'chat/page');
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
    await showDialog<void>(
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
                      'Paste a URL to ingest its content into the chat.',
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
                          .copyWith(labelText: 'Webpage URL'),
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
                            setError('Enter a valid http(s) URL.');
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
                                    ? 'Could not fetch YouTube transcript.'
                                    : 'The page had no readable content.',
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
                            setError('Failed to attach content.');
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
                      : const Text('Attach'),
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

  void _handleVoiceCall() {
    unawaited(
      ref.read(voiceCallLauncherProvider).launch(startNewConversation: false),
    );
  }

  // Replaced bottom-sheet chat list with left drawer (see ChatsDrawer)

  void _onScroll() {
    if (!_scrollController.hasClients) return;

    // Debounce scroll handling to reduce rebuilds
    if (_scrollDebounceTimer?.isActive == true) return;

    _scrollDebounceTimer = Timer(const Duration(milliseconds: 80), () {
      _updateScrollToBottomVisibility();
    });
  }

  void _updateScrollToBottomVisibility() {
    if (!mounted || _isDeactivated || !_scrollController.hasClients) return;

    final maxScroll = _scrollController.position.maxScrollExtent;
    final distanceFromBottom = _distanceFromBottom();
    final isStreaming = ref.read(isChatStreamingProvider);

    const double showThreshold = 300.0;
    const double hideThreshold = 150.0;

    final bool farFromBottom = distanceFromBottom > showThreshold;
    final bool nearBottom = distanceFromBottom <= hideThreshold;
    final bool hasScrollableContent =
        maxScroll.isFinite && maxScroll > showThreshold;

    final bool showButton;
    if (isStreaming && _userPausedAutoScroll) {
      showButton = hasScrollableContent && !_wantsPinToTop;
    } else {
      showButton = _showScrollToBottom
          ? !nearBottom && hasScrollableContent
          : farFromBottom && hasScrollableContent;
    }

    if (showButton != _showScrollToBottom) {
      setState(() {
        _showScrollToBottom = showButton;
      });
    }
  }

  void _invalidateStreamingMessageExtent() {
    if (!_messageListController.isAttached) {
      return;
    }
    if (_messageListController.isLocked) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _invalidateStreamingMessageExtent();
        }
      });
      return;
    }

    final messages = ref.read(chatMessagesProvider);
    if (messages.isEmpty) {
      return;
    }

    final lastIndex = messages.length - 1;
    final lastMessage = messages[lastIndex];
    if (lastMessage.role != 'assistant' || !lastMessage.isStreaming) {
      return;
    }

    _messageListController.invalidateExtent(lastIndex);
  }

  void _pauseStreamingFollow() {
    if (_userPausedAutoScroll) {
      return;
    }
    setState(() {
      _userPausedAutoScroll = true;
    });
    if (_wantsPinToTop) {
      _dismissPinToTop(preserveStreamingId: true);
    }
    _updateScrollToBottomVisibility();
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

  /// User-initiated scroll to bottom (e.g. button tap).
  /// Resets auto-scroll pause and ends pin-to-top so streaming
  /// continues to follow from the bottom.
  void _userScrollToBottom() {
    if (_wantsPinToTop) {
      _endPinToTop(instant: true, preserveStreamingId: true);
    }
    if (_userPausedAutoScroll) {
      _userPausedAutoScroll = false;
    }
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToBottom();
    });
  }

  void _scrollToBottom({bool smooth = true}) {
    if (_isUserInteractingWithScroll || !_scrollController.hasClients) return;
    final position = _scrollController.position;
    var maxScroll = position.maxScrollExtent;
    if (!maxScroll.isFinite || maxScroll <= 0) return;

    // During pin-to-top, subtract the phantom sliver so we scroll
    // to the actual content bottom, not into empty space.
    if (_wantsPinToTop) {
      final phantomHeight = MediaQuery.of(context).size.height;
      maxScroll = (maxScroll - phantomHeight).clamp(0.0, maxScroll);
    }

    if (smooth) {
      _scrollController.animateTo(
        maxScroll,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
      );
    } else {
      _scrollController.jumpTo(maxScroll);
    }
  }

  /// Scrolls the pending user message near the top of the viewport.
  ///
  /// Uses the sliver list controller so the target item can be positioned even
  /// when it has not been built yet.
  void _scrollToUserMessage() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) {
        return;
      }

      final messages = ref.read(chatMessagesProvider);
      final targetIndex = messages.length - 2;
      if (targetIndex < 0 || targetIndex >= messages.length) {
        return;
      }

      final topPadding =
          MediaQuery.of(context).padding.top + kTextTabBarHeight + Spacing.md;
      final viewportHeight = MediaQuery.of(context).size.height;
      final alignment = viewportHeight > 0
          ? (topPadding / viewportHeight)
          : 0.0;
      if (_messageListController.isAttached) {
        _messageListController.jumpToItem(
          index: targetIndex,
          scrollController: _scrollController,
          alignment: alignment.clamp(0.0, 1.0),
        );
        return;
      }

      final ctx = _pinnedUserMessageKey.currentContext;
      if (ctx == null) {
        _scrollToBottom(smooth: false);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _scrollToUserMessage();
          }
        });
        return;
      }

      Scrollable.ensureVisible(
        ctx,
        alignment: alignment.clamp(0.0, 1.0),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  bool _endPinToTopInFlight = false;

  void _dismissPinToTop({bool preserveStreamingId = false}) {
    if (!_wantsPinToTop || !mounted) {
      return;
    }
    setState(() {
      _wantsPinToTop = false;
      if (!preserveStreamingId) {
        _pinnedStreamingId = null;
      }
    });
  }

  /// Transitions out of pin-to-top mode.
  ///
  /// When [instant] is true (e.g. during streaming), uses jumpTo to
  /// avoid competing with per-chunk scroll updates. When false (e.g.
  /// streaming just completed), animates smoothly.
  void _endPinToTop({bool instant = false, bool preserveStreamingId = false}) {
    if (!_wantsPinToTop || !mounted || _endPinToTopInFlight) return;
    if (_isUserInteractingWithScroll) {
      _dismissPinToTop(preserveStreamingId: preserveStreamingId);
      return;
    }
    if (!_scrollController.hasClients) {
      setState(() {
        _wantsPinToTop = false;
        if (!preserveStreamingId) {
          _pinnedStreamingId = null;
        }
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
        _wantsPinToTop = false;
        if (!preserveStreamingId) {
          _pinnedStreamingId = null;
        }
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
                _wantsPinToTop = false;
                if (!preserveStreamingId) {
                  _pinnedStreamingId = null;
                }
              });
            }
          });
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

  /// Builds a styled container with high-contrast background for app bar
  /// widgets, matching the floating chat input styling.
  Widget _buildScrollToBottomButton(
    BuildContext context, {
    required bool isResuming,
  }) {
    final icon = isResuming
        ? (Platform.isIOS ? CupertinoIcons.play_fill : Icons.play_arrow)
        : (Platform.isIOS
              ? CupertinoIcons.chevron_down
              : Icons.keyboard_arrow_down);

    if (!kIsWeb && Platform.isIOS) {
      return AdaptiveButton.child(
        onPressed: _userScrollToBottom,
        style: AdaptiveButtonStyle.glass,
        size: AdaptiveButtonSize.large,
        minSize: const Size(TouchTarget.minimum, TouchTarget.minimum),
        padding: EdgeInsets.zero,
        borderRadius: BorderRadius.circular(TouchTarget.minimum),
        useSmoothRectangleBorder: false,
        child: Icon(
          icon,
          size: IconSize.large,
          color: GlassColors.label(context),
        ),
      );
    }

    final theme = context.conduitTheme;
    return SizedBox(
      width: TouchTarget.minimum,
      height: TouchTarget.minimum,
      child: Material(
        color: theme.surfaceContainerHighest,
        shape: CircleBorder(
          side: BorderSide(color: theme.cardBorder, width: BorderWidth.thin),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _userScrollToBottom,
          customBorder: const CircleBorder(),
          child: Center(
            child: Icon(icon, size: IconSize.large, color: theme.textPrimary),
          ),
        ),
      ),
    );
  }

  Widget _buildAppBarPill({
    required BuildContext context,
    required Widget child,
    bool isCircular = false,
  }) {
    return FloatingAppBarPill(isCircular: isCircular, child: child);
  }

  Widget _buildAppBarIconButton({
    required BuildContext context,
    required VoidCallback onPressed,
    required IconData fallbackIcon,
    required String sfSymbol,
    required Color color,
  }) {
    if (PlatformInfo.isIOS26OrHigher()) {
      return AdaptiveButton.child(
        onPressed: onPressed,
        style: AdaptiveButtonStyle.glass,
        size: AdaptiveButtonSize.large,
        minSize: const Size(TouchTarget.minimum, TouchTarget.minimum),
        useSmoothRectangleBorder: false,
        child: Icon(fallbackIcon, size: IconSize.appBar, color: color),
      );
    }

    return GestureDetector(
      onTap: onPressed,
      child: _buildAppBarPill(
        context: context,
        isCircular: true,
        child: Icon(fallbackIcon, color: color, size: IconSize.appBar),
      ),
    );
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
          children: <Widget>[...previousChildren, ?currentChild],
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
    // Add top padding for floating app bar, bottom padding for floating input.
    final topPadding =
        MediaQuery.of(context).padding.top + kTextTabBarHeight + Spacing.md;
    final bottomPadding = Spacing.lg + _inputHeight;
    return CustomScrollView(
      key: const ValueKey('loading_messages'),
      controller: null,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      physics: const AlwaysScrollableScrollPhysics(),
      cacheExtent: 300,
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

  /// Walks the message list once (O(n)) to pre-compute, for each index,
  /// whether the next user or assistant bubble appears below it.
  ///
  /// System messages are skipped, matching the original per-item scan
  /// behavior.
  List<({bool hasUserBelow, bool hasAssistantBelow})> _computeBubbleAdjacency(
    List<ChatMessage> messages,
  ) {
    final result = List.filled(messages.length, (
      hasUserBelow: false,
      hasAssistantBelow: false,
    ));

    // Track the role of the nearest user/assistant message seen
    // so far while walking backwards.
    String? nextRelevantRole;

    for (var i = messages.length - 1; i >= 0; i--) {
      // Record what's below *this* index before updating.
      result[i] = (
        hasUserBelow: nextRelevantRole == 'user',
        hasAssistantBelow: nextRelevantRole == 'assistant',
      );

      // Update the tracked role if this message is user or assistant.
      final role = messages[i].role;
      if (role == 'user' || role == 'assistant') {
        nextRelevantRole = role;
      }
    }

    return result;
  }

  Widget _buildActualMessagesList(List<ChatMessage> messages) {
    if (messages.isEmpty) {
      return _buildEmptyState(Theme.of(context));
    }

    final apiService = ref.watch(apiServiceProvider);

    if (_pendingScrollRestore) {
      _pendingScrollRestore = false;
      final targetOffset = _restoreScrollOffset;
      if (!_scrollController.hasClients) {
        // Scroll controller not attached yet — retry once after frame
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_scrollController.hasClients) return;
          _scrollController.jumpTo(
            targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
          );
        });
      } else {
        _scrollController.jumpTo(
          targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
        );
      }
    }

    if (_shouldAutoScrollToBottom) {
      _scheduleAutoScrollToBottom();
    } else if (!_userPausedAutoScroll) {
      // Only keep-pinned to bottom if user hasn't paused auto-scroll
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // Skip if user has paused auto-scroll (double-check in callback)
        if (_userPausedAutoScroll) return;
        const double keepPinnedThreshold = 60.0;
        final distanceFromBottom = _distanceFromBottom();
        if (distanceFromBottom > 0 &&
            distanceFromBottom <= keepPinnedThreshold) {
          _scrollToBottom(smooth: false);
        }
      });
    }

    // Add top padding for floating app bar, bottom padding for floating input.
    final topPadding =
        MediaQuery.of(context).padding.top + kTextTabBarHeight + Spacing.md;
    final bottomPadding = Spacing.lg + _inputHeight;

    // Check if any message is currently streaming
    final isStreaming = messages.any((msg) => msg.isStreaming);

    // Pin-to-top: detect new streaming response and scroll user message to top
    if (isStreaming && !_userPausedAutoScroll && messages.length >= 2) {
      final lastMsg = messages.last;
      // Only trigger pin-to-top when the message before the streaming
      // assistant is a user message (excludes regeneration where an
      // archived assistant sits at length-2).
      final prevMsg = messages[messages.length - 2];
      if (lastMsg.role == 'assistant' &&
          lastMsg.isStreaming &&
          prevMsg.role == 'user' &&
          _pinnedStreamingId != lastMsg.id) {
        // New streaming response detected
        _pinnedStreamingId = lastMsg.id;
        _wantsPinToTop = true;
        _pinnedUserMessageKey = GlobalKey();
        _shouldAutoScrollToBottom = false;
        _scrollToUserMessage();
      }
    }
    // Don't end pin-to-top when streaming completes. For long responses,
    // pin-to-top was already ended mid-stream by the viewport-fill
    // transition in the streamingContentProvider listener. If it's still
    // active here, the response was short -- keep the phantom sliver so
    // the view doesn't jump down. It dismisses on user scroll, new
    // message, or conversation switch.
    //
    // Clear the pinned ID so the next message can activate pin-to-top.
    if (!isStreaming && _pinnedStreamingId != null) {
      _pinnedStreamingId = null;
    }

    // Pre-compute bubble adjacency in O(n) instead of O(n^2) per-item scan
    final bubbleAdjacency = _computeBubbleAdjacency(messages);

    // Watch models once here instead of per-message in the item builder
    final modelsAsync = ref.watch(modelsProvider);
    final models = modelsAsync.hasValue ? modelsAsync.value : null;

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

        // Detect user-initiated scrolling early enough to stop the streaming
        // follow path before the next chunk snaps the viewport back down.
        if (isTouchDragStart || isTouchDragUpdate || isUserDirectionalScroll) {
          _isUserInteractingWithScroll = true;
          // Dismiss native platform keyboard on drag (mirrors
          // keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag
          // which only affects Flutter's text input system).
          try {
            ref.read(composerAutofocusEnabledProvider.notifier).set(false);
          } catch (_) {}
          if (isStreaming) {
            _pauseStreamingFollow();
          } else if (!isStreaming && _wantsPinToTop) {
            // User scrolled after streaming ended with a short response.
            // Drop the phantom sliver without changing the scroll activity.
            _dismissPinToTop();
          }
        }
        // Re-enable auto-scroll when user scrolls to bottom
        if (notification is ScrollEndNotification || isUserScrollIdle) {
          _isUserInteractingWithScroll = false;
          final distanceFromBottom = _distanceFromBottom();
          if (!isStreaming &&
              distanceFromBottom <= 5 &&
              _userPausedAutoScroll) {
            setState(() {
              _userPausedAutoScroll = false;
            });
          }
        }
        return false; // Allow notification to continue bubbling
      },
      child: CustomScrollView(
        key: const ValueKey('actual_messages'),
        controller: _scrollController,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        physics: const AlwaysScrollableScrollPhysics(),
        cacheExtent: 600,
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              Spacing.inputPadding,
              topPadding,
              Spacing.inputPadding,
              bottomPadding,
            ),
            sliver: OptimizedSliverList<ChatMessage>(
              items: messages,
              listController: _messageListController,
              extentEstimation: (index, crossAxisExtent) {
                if (index == null || index >= messages.length) {
                  return _estimateChatMessageExtent(
                    null,
                    crossAxisExtent,
                    countAsPagination:
                        index != null && index >= messages.length,
                  );
                }
                return _estimateChatMessageExtent(
                  messages[index],
                  crossAxisExtent,
                );
              },
              extentPrecalculationPolicy: _extentPrecalculationPolicy,
              itemBuilder: (context, message, index) {
                final isUser = message.role == 'user';
                final isStreaming = message.isStreaming;

                final isSelected = _selectedMessageIds.contains(message.id);

                // Resolve a friendly model display name for message headers
                final modelPresentation = _resolveModelPresentation(
                  rawModel: message.model,
                  models: models,
                );
                final displayModelName = modelPresentation.displayName;
                final matchedModel = modelPresentation.matchedModel;

                final modelIconUrl = resolveModelIconUrlForModel(
                  apiService,
                  matchedModel,
                );
                final versionModelNames = <String?>[];
                final versionModelIconUrls = <String?>[];
                for (final version in message.versions) {
                  final versionPresentation = _resolveModelPresentation(
                    rawModel: version.model,
                    models: models,
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
                final hasUserBubbleBelow = adjacency.hasUserBelow;
                final hasAssistantBubbleBelow = adjacency.hasAssistantBelow;
                final replacesArchivedAssistant =
                    !isUser &&
                    index > 0 &&
                    messages[index - 1].role == 'assistant' &&
                    (messages[index - 1].metadata?['archivedVariant'] == true);

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
                  final isPinTarget =
                      _wantsPinToTop &&
                      message.role == 'user' &&
                      index == messages.length - 2 &&
                      messages.last.isStreaming;
                  messageWidget = KeyedSubtree(
                    key: isPinTarget
                        ? _pinnedUserMessageKey
                        : ValueKey('user-${message.id}'),
                    child: UserMessageBubble(
                      message: message,
                      isUser: isUser,
                      isStreaming: isStreaming,
                      modelName: displayModelName,
                      onCopy: () => _copyMessage(message.content),
                      onRegenerate: () => _regenerateMessage(message.id),
                    ),
                  );
                } else {
                  messageWidget = assistant.AssistantMessageWidget(
                    key: ValueKey('assistant-${message.id}'),
                    message: message,
                    isStreaming: isStreaming,
                    showFollowUps: showFollowUps,
                    animateOnMount: !replacesArchivedAssistant,
                    modelName: displayModelName,
                    modelIconUrl: modelIconUrl,
                    versionModelNames: versionModelNames,
                    versionModelIconUrls: versionModelIconUrls,
                    onCopy: () => _copyMessage(message.content),
                    onRegenerate: () => _regenerateMessage(message.id),
                  );
                }

                // Add selection functionality if in selection mode
                if (_isSelectionMode) {
                  return SelectableMessageWrapper(
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

  void _copyMessage(String content) {
    // Strip reasoning blocks and annotations from copied content
    final cleanedContent = ConduitMarkdownPreprocessor.sanitize(content);
    Clipboard.setData(ClipboardData(text: cleanedContent));
  }

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
    final greetingHeight =
        (greetingStyle.fontSize ?? 24) * (greetingStyle.height ?? 1.1);
    final String? resolvedGreetingName = hasGreeting ? greetingName : null;
    final greetingText = resolvedGreetingName != null
        ? l10n.greetingTitle(resolvedGreetingName)
        : null;

    // Check if there's a pending folder for the new chat
    final pendingFolderId = ref.watch(pendingFolderIdProvider);
    final folders = ref
        .watch(foldersProvider)
        .maybeWhen(data: (list) => list, orElse: () => <Folder>[]);
    final pendingFolder = pendingFolderId != null
        ? folders.where((f) => f.id == pendingFolderId).firstOrNull
        : null;

    // Add top padding for floating app bar, bottom padding for floating input.
    final topPadding =
        MediaQuery.of(context).padding.top + kTextTabBarHeight + Spacing.md;
    final bottomPadding = _inputHeight;
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
                ],
              ),
            ),
          ),
        );
      },
    );
  }

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
      // Save outgoing conversation's scroll position
      final outgoingId = _lastConversationId;
      if (outgoingId != null && _scrollController.hasClients) {
        _savedScrollOffsets[outgoingId] = _scrollController.position.pixels;
      }

      _lastConversationId = conversationId;
      _userPausedAutoScroll = false; // Reset pause on conversation change
      _wantsPinToTop = false;
      _pinnedStreamingId = null;
      _endPinToTopInFlight = false;
      if (conversationId == null) {
        _shouldAutoScrollToBottom = true;
        _pendingScrollRestore = false;
        _scheduleAutoScrollToBottom();
      } else if (_savedScrollOffsets.containsKey(conversationId)) {
        // Restore saved scroll position for this conversation
        _pendingScrollRestore = true;
        _restoreScrollOffset = _savedScrollOffsets[conversationId]!;
        _shouldAutoScrollToBottom = false;
      } else {
        // First open in this session — scroll to bottom (latest message)
        _shouldAutoScrollToBottom = true;
        _pendingScrollRestore = false;
        _scheduleAutoScrollToBottom();
      }
    }
    // Watch loading state for app bar skeleton
    final isLoadingConversation = ref.watch(isLoadingConversationProvider);
    final formattedModelName = selectedModel != null
        ? _formatModelDisplayName(selectedModel.name)
        : null;
    final modelLabel = formattedModelName ?? l10n.chooseModel;
    final TextStyle modelTextStyle = AppTypography.standard.copyWith(
      color: context.conduitTheme.textPrimary,
      fontWeight: FontWeight.w600,
    );

    // Keyboard visibility - use viewInsetsOf for more efficient partial subscription
    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    // Whether the messages list can actually scroll (avoids showing button when not needed)
    final canScroll =
        _scrollController.hasClients &&
        _scrollController.position.maxScrollExtent > 0;
    // Use dedicated streaming provider to avoid iterating all messages on rebuild
    final isStreamingAnyMessage = ref.watch(isChatStreamingProvider);

    // Per-chunk scroll following: keep the view scrolled to the bottom as
    // streaming content grows. The chatMessagesProvider only syncs every 500ms,
    // but streamingContentProvider updates per-chunk, so listening here
    // ensures smooth scroll tracking during streaming.
    ref.listen(streamingContentProvider, (_, _) {
      _invalidateStreamingMessageExtent();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;

        if (_wantsPinToTop) {
          // End pin-to-top on the first real streamed update. Keeping the
          // phantom sliver around longer causes blank space and fights with
          // manual scrolling during streaming.
          _endPinToTop(instant: true, preserveStreamingId: true);
          if (!_userPausedAutoScroll) {
            _scrollToBottom(smooth: false);
          }
          _updateScrollToBottomVisibility();
          return;
        }

        if (!_userPausedAutoScroll) {
          _scrollToBottom(smooth: false);
        }
        _updateScrollToBottomVisibility();
      });
    });

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

    // Focus composer on app startup once (minimal delay for layout to settle)
    if (!_didStartupFocus) {
      _didStartupFocus = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(inputFocusTriggerProvider.notifier).increment();
      });
    }

    return ErrorBoundary(
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (bool didPop, Object? result) async {
          if (didPop) return;

          // First, if any input has focus, clear focus and consume back press.
          // Also covers native platform inputs which don't participate in
          // Flutter's focus tree (composerHasFocusProvider tracks them).
          final hasNativeFocus = ref.read(composerHasFocusProvider);
          final currentFocus = FocusManager.instance.primaryFocus;
          if (hasNativeFocus ||
              (currentFocus != null && currentFocus.hasFocus)) {
            try {
              ref.read(composerAutofocusEnabledProvider.notifier).set(false);
            } catch (_) {}
            currentFocus?.unfocus();
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
        child: Scaffold(
          backgroundColor: context.conduitTheme.surfaceBackground,
          // Replace Scaffold drawer with a tunable slide drawer for gentler snap behavior.
          drawerEnableOpenDragGesture: false,
          drawerDragStartBehavior: DragStartBehavior.down,
          extendBodyBehindAppBar: true,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: Elevation.none,
            surfaceTintColor: Colors.transparent,
            shadowColor: Colors.transparent,
            toolbarHeight: kTextTabBarHeight,
            centerTitle: false,
            titleSpacing: Spacing.sm,
            leadingWidth: 44 + Spacing.inputPadding + Spacing.xs,
            leading: _isSelectionMode
                ? Padding(
                    padding: const EdgeInsets.only(left: Spacing.inputPadding),
                    child: Center(
                      child: _buildAppBarIconButton(
                        context: context,
                        onPressed: _clearSelection,
                        fallbackIcon: Platform.isIOS
                            ? CupertinoIcons.xmark
                            : Icons.close,
                        sfSymbol: 'xmark',
                        color: context.conduitTheme.textPrimary,
                      ),
                    ),
                  )
                : Builder(
                    builder: (ctx) => Padding(
                      padding: const EdgeInsets.only(
                        left: Spacing.inputPadding,
                      ),
                      child: Center(
                        child: _buildAppBarIconButton(
                          context: ctx,
                          onPressed: () {
                            final layout = ResponsiveDrawerLayout.of(ctx);
                            if (layout == null) return;

                            final isDrawerOpen = layout.isOpen;
                            if (!isDrawerOpen) {
                              try {
                                ref
                                    .read(
                                      composerAutofocusEnabledProvider.notifier,
                                    )
                                    .set(false);
                                FocusManager.instance.primaryFocus?.unfocus();
                                SystemChannels.textInput.invokeMethod(
                                  'TextInput.hide',
                                );
                              } catch (_) {}
                            }
                            layout.toggle();
                          },
                          fallbackIcon: Platform.isIOS
                              ? CupertinoIcons.line_horizontal_3
                              : Icons.menu,
                          sfSymbol: 'line.3.horizontal',
                          color: context.conduitTheme.textPrimary,
                        ),
                      ),
                    ),
                  ),
            title: _isSelectionMode
                ? _buildAppBarPill(
                    context: context,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: Spacing.md,
                        vertical: Spacing.sm,
                      ),
                      child: Text(
                        '${_selectedMessageIds.length} selected',
                        style: AppTypography.headlineSmallStyle.copyWith(
                          color: context.conduitTheme.textPrimary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      // Build model selector pill
                      // Show skeleton when loading, actual model selector otherwise
                      final Widget modelPill;
                      if (isLoadingConversation) {
                        // Show skeleton pill while loading conversation
                        modelPill = _buildAppBarPill(
                          context: context,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 44),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: Spacing.sm,
                              ),
                              child: Center(
                                widthFactor: 1,
                                child: ConduitLoading.skeleton(
                                  width: 80,
                                  height: 14,
                                  borderRadius: BorderRadius.circular(
                                    AppBorderRadius.sm,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      } else {
                        Future<void> openModelSelector() async {
                          final modelsAsync = ref.read(modelsProvider);

                          if (modelsAsync.isLoading) {
                            try {
                              final models = await ref.read(
                                modelsProvider.future,
                              );
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
                            _showModelDropdown(
                              context,
                              ref,
                              modelsAsync.value!,
                            );
                          } else if (modelsAsync.hasError) {
                            try {
                              ref.invalidate(modelsProvider);
                              final models = await ref.read(
                                modelsProvider.future,
                              );
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
                        }

                        final maxPillWidth =
                            (constraints.maxWidth - Spacing.xxl)
                                .clamp(140.0, 300.0)
                                .toDouble();

                        if (PlatformInfo.isIOS26OrHigher()) {
                          final textPainter = TextPainter(
                            text: TextSpan(
                              text: modelLabel,
                              style: modelTextStyle,
                            ),
                            maxLines: 1,
                            textScaler: MediaQuery.textScalerOf(context),
                            textDirection: Directionality.of(context),
                          )..layout(maxWidth: maxPillWidth);

                          final targetPillWidth =
                              (textPainter.width +
                                      10 +
                                      Spacing.xs +
                                      IconSize.xs +
                                      Spacing.xs +
                                      12)
                                  .clamp(0.0, maxPillWidth)
                                  .toDouble();

                          modelPill = AdaptiveButton.child(
                            onPressed: () {
                              openModelSelector();
                            },
                            style: AdaptiveButtonStyle.glass,
                            size: AdaptiveButtonSize.large,
                            minSize: Size(targetPillWidth, 44),
                            useSmoothRectangleBorder: false,
                            child: Padding(
                              padding: const EdgeInsets.only(
                                left: 10,
                                right: Spacing.xs,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Flexible(
                                    child: MiddleEllipsisText(
                                      modelLabel,
                                      style: modelTextStyle,
                                      textAlign: TextAlign.center,
                                      semanticsLabel: modelLabel,
                                    ),
                                  ),
                                  const SizedBox(width: Spacing.xs),
                                  Icon(
                                    CupertinoIcons.chevron_down,
                                    color: context.conduitTheme.iconSecondary,
                                    size: IconSize.small,
                                  ),
                                ],
                              ),
                            ),
                          );
                        } else {
                          modelPill = GestureDetector(
                            onTap: openModelSelector,
                            child: _buildAppBarPill(
                              context: context,
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  minHeight: 44,
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.only(
                                    left: 12.0,
                                    right: Spacing.sm,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      ConstrainedBox(
                                        constraints: BoxConstraints(
                                          maxWidth:
                                              constraints.maxWidth -
                                              Spacing.xxl,
                                        ),
                                        child: MiddleEllipsisText(
                                          modelLabel,
                                          style: modelTextStyle,
                                          textAlign: TextAlign.center,
                                          semanticsLabel: modelLabel,
                                        ),
                                      ),
                                      const SizedBox(width: Spacing.xs),
                                      Icon(
                                        Platform.isIOS
                                            ? CupertinoIcons.chevron_down
                                            : Icons.keyboard_arrow_down,
                                        color:
                                            context.conduitTheme.iconSecondary,
                                        size: IconSize.medium,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        }
                      }

                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 200),
                            switchInCurve: Curves.easeOut,
                            switchOutCurve: Curves.easeIn,
                            child: KeyedSubtree(
                              key: ValueKey(
                                isLoadingConversation
                                    ? 'model-loading'
                                    : 'model-$modelLabel',
                              ),
                              child: modelPill,
                            ),
                          ),
                          if (isReviewerMode)
                            Padding(
                              padding: const EdgeInsets.only(top: Spacing.xs),
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
                                  style: AppTypography.labelSmallStyle.copyWith(
                                    color: context.conduitTheme.success,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
            actions: [
              if (!_isSelectionMode) ...[
                // Temporary chat toggle / Save chat button
                // Shows save when temporary + has messages,
                // otherwise shows the toggle
                Consumer(
                  builder: (context, ref, _) {
                    final isTemporary = ref.watch(temporaryChatEnabledProvider);
                    final activeConversation = ref.watch(
                      activeConversationProvider,
                    );
                    final hasMessages = ref
                        .watch(chatMessagesProvider)
                        .isNotEmpty;

                    final showToggle =
                        activeConversation == null ||
                        isTemporaryChat(activeConversation.id);

                    if (!showToggle) {
                      return const SizedBox.shrink();
                    }

                    // Show save button when temporary
                    // chat has messages
                    if (isTemporary &&
                        hasMessages &&
                        activeConversation != null) {
                      return AdaptiveTooltip(
                        message: AppLocalizations.of(context)!.saveChat,
                        child: _buildAppBarIconButton(
                          context: context,
                          onPressed: _saveTemporaryChat,
                          fallbackIcon: Platform.isIOS
                              ? CupertinoIcons.arrow_down_doc
                              : Icons.save_alt,
                          sfSymbol: 'square.and.arrow.down',
                          color: context.conduitTheme.textPrimary,
                        ),
                      );
                    }

                    // Show toggle button
                    return AdaptiveTooltip(
                      message: isTemporary
                          ? AppLocalizations.of(context)!.temporaryChatTooltip
                          : AppLocalizations.of(context)!.temporaryChat,
                      child: _buildAppBarIconButton(
                        context: context,
                        onPressed: () {
                          ConduitHaptics.selectionClick();
                          final current = ref.read(
                            temporaryChatEnabledProvider,
                          );
                          ref
                              .read(temporaryChatEnabledProvider.notifier)
                              .set(!current);
                        },
                        fallbackIcon: isTemporary
                            ? (Platform.isIOS
                                  ? CupertinoIcons.eye_slash
                                  : Icons.visibility_off)
                            : (Platform.isIOS
                                  ? CupertinoIcons.eye
                                  : Icons.visibility_outlined),
                        sfSymbol: isTemporary ? 'eye.slash' : 'eye',
                        color: isTemporary
                            ? Colors.blue
                            : context.conduitTheme.textPrimary,
                      ),
                    );
                  },
                ),
                const SizedBox(width: Spacing.sm),
                Padding(
                  padding: const EdgeInsets.only(right: Spacing.inputPadding),
                  child: AdaptiveTooltip(
                    message: AppLocalizations.of(context)!.newChat,
                    child: _buildAppBarIconButton(
                      context: context,
                      onPressed: _handleNewChat,
                      fallbackIcon: Platform.isIOS
                          ? CupertinoIcons.create
                          : Icons.add_comment,
                      sfSymbol: 'square.and.pencil',
                      color: context.conduitTheme.textPrimary,
                    ),
                  ),
                ),
              ] else ...[
                Padding(
                  padding: const EdgeInsets.only(right: Spacing.inputPadding),
                  child: _buildAppBarIconButton(
                    context: context,
                    onPressed: _deleteSelectedMessages,
                    fallbackIcon: Platform.isIOS
                        ? CupertinoIcons.delete
                        : Icons.delete,
                    sfSymbol: 'trash',
                    color: context.conduitTheme.error,
                  ),
                ),
              ],
            ],
          ),
          body: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () {
              try {
                ref.read(composerAutofocusEnabledProvider.notifier).set(false);
              } catch (_) {}
              FocusManager.instance.primaryFocus?.unfocus();
              try {
                SystemChannels.textInput.invokeMethod('TextInput.hide');
              } catch (_) {}
            },
            child: Stack(
              children: [
                // Messages Area fills entire space with pull-to-refresh
                Positioned.fill(
                  child: ConduitRefreshIndicator(
                    // Position indicator below the floating app bar
                    edgeOffset:
                        MediaQuery.of(context).padding.top + kTextTabBarHeight,
                    onRefresh: () async {
                      // Reload active conversation messages from server
                      final api = ref.read(apiServiceProvider);
                      final active = ref.read(activeConversationProvider);
                      if (api != null && active != null) {
                        try {
                          final full = await api.getConversation(active.id);
                          ref
                              .read(activeConversationProvider.notifier)
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
                      await Future.delayed(const Duration(milliseconds: 300));
                    },
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        try {
                          ref
                              .read(composerAutofocusEnabledProvider.notifier)
                              .set(false);
                        } catch (_) {}
                        FocusManager.instance.primaryFocus?.unfocus();
                        try {
                          SystemChannels.textInput.invokeMethod(
                            'TextInput.hide',
                          );
                        } catch (_) {}
                      },
                      child: RepaintBoundary(child: _buildMessagesList(theme)),
                    ),
                  ),
                ),

                // Floating input area with attachments and blur background
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: RepaintBoundary(
                    child: MeasureSize(
                      onChange: (size) {
                        if (mounted) {
                          setState(() {
                            _inputHeight = size.height;
                          });
                        }
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          // Gradient fade from transparent to solid background
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            stops: const [0.0, 0.4, 1.0],
                            colors: [
                              theme.scaffoldBackgroundColor.withValues(
                                alpha: 0.0,
                              ),
                              theme.scaffoldBackgroundColor.withValues(
                                alpha: 0.85,
                              ),
                              theme.scaffoldBackgroundColor,
                            ],
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Top padding for gradient fade area
                            const SizedBox(height: Spacing.xl),
                            // File attachments
                            const FileAttachmentWidget(),
                            const ContextAttachmentWidget(),
                            // RepaintBoundary prevents BackdropFilter
                            // (AdaptiveBlurView) from going blank when
                            // a modal sheet scrolls over it.
                            RepaintBoundary(
                              child: ModernChatInput(
                                onSendMessage: (text) =>
                                    _handleMessageSend(text, selectedModel),
                                enabled: !isLoadingConversation,
                                onVoiceInput: null,
                                onVoiceCall: _handleVoiceCall,
                                onFileAttachment: _handleFileAttachment,
                                onServerFileAttachment:
                                    _handleServerFileAttachment,
                                onImageAttachment: _handleImageAttachment,
                                onCameraCapture: () =>
                                    _handleImageAttachment(fromCamera: true),
                                onWebAttachment: _promptAttachWebpage,
                                onPastedAttachments: _handlePastedAttachments,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

                // Floating app bar gradient overlay
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    child: Container(
                      height:
                          MediaQuery.of(context).padding.top +
                          kTextTabBarHeight +
                          Spacing.xl,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          stops: const [0.0, 0.4, 1.0],
                          colors: [
                            theme.scaffoldBackgroundColor,
                            theme.scaffoldBackgroundColor.withValues(
                              alpha: 0.85,
                            ),
                            theme.scaffoldBackgroundColor.withValues(
                              alpha: 0.0,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

                // Floating Scroll to Bottom Button with smooth appear/disappear
                Positioned(
                  bottom: (_inputHeight > 0)
                      ? _inputHeight
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
                    child:
                        (_showScrollToBottom &&
                            !_wantsPinToTop &&
                            !keyboardVisible &&
                            canScroll &&
                            ref.watch(chatMessagesProvider).isNotEmpty)
                        ? Center(
                            key: const ValueKey('scroll_to_bottom_visible'),
                            child: AdaptiveTooltip(
                              message:
                                  _userPausedAutoScroll && isStreamingAnyMessage
                                  ? 'Resume auto-scroll'
                                  : 'Scroll to bottom',
                              child: _buildScrollToBottomButton(
                                context,
                                isResuming:
                                    _userPausedAutoScroll &&
                                    isStreamingAnyMessage,
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
        ), // Scaffold
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
      ref.read(composerAutofocusEnabledProvider.notifier).set(false);
      FocusManager.instance.primaryFocus?.unfocus();
      SystemChannels.textInput.invokeMethod('TextInput.hide');
    } catch (_) {}
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ModelSelectorSheet(models: models, ref: ref),
    ).whenComplete(() {
      if (!mounted) return;
      if (hadFocus) {
        // Re-enable autofocus and bump trigger to restore composer focus + IME
        try {
          ref.read(composerAutofocusEnabledProvider.notifier).set(true);
        } catch (_) {}
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
        _clearSelection();
      }
    });
  }
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

  if (message.isStreaming) {
    estimate += 56.0;
  }
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

class _ChatExtentPrecalculationPolicy extends ExtentPrecalculationPolicy {
  @override
  bool shouldPrecalculateExtents(ExtentPrecalculationContext context) {
    if (context.numberOfItems == 0 ||
        context.numberOfItemsWithEstimatedExtent == 0) {
      return false;
    }

    if (context.numberOfItems <= 48) {
      return true;
    }

    if (context.numberOfItems <= 120) {
      final remainingFraction =
          context.numberOfItemsWithEstimatedExtent / context.numberOfItems;
      return remainingFraction >= 0.25;
    }

    return false;
  }
}

// Extension on _ChatPageState for utility methods
extension on _ChatPageState {}
