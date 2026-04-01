import 'package:flutter/material.dart';
import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:qonduit/l10n/app_localizations.dart';
import '../../../core/widgets/error_boundary.dart';
import '../../../shared/widgets/optimized_list.dart';
import '../../../shared/theme/qonduit_input_styles.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/glass_colors.dart';
import 'package:flutter/services.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;

import '../../../shared/widgets/responsive_drawer_layout.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
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
import '../services/file_attachment_service.dart';
import '../voice_call/presentation/voice_call_launcher.dart';
import '../../../shared/services/tasks/task_queue.dart';
import '../../tools/providers/tools_providers.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/folder.dart';
import '../../../core/models/model.dart';
import '../providers/context_attachments_provider.dart';
import '../../../shared/widgets/qonduit_loading.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../shared/widgets/measure_size.dart';
import '../../../shared/widgets/qonduit_components.dart';
import '../../../shared/widgets/middle_ellipsis_text.dart';
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:qonduit/features/rag/providers/rag_collections_providers.dart';
import 'package:file_picker/file_picker.dart';


class _UnifiedDiffHunk {
  final int oldStart;
  final int oldCount;
  final int newStart;
  final int newCount;
  final List<String> lines;

  const _UnifiedDiffHunk({
    required this.oldStart,
    required this.oldCount,
    required this.newStart,
    required this.newCount,
    required this.lines,
  });
}

class _ParsedUnifiedDiff {
  final String fileName;
  final String rawPatch;
  final List<_UnifiedDiffHunk> hunks;

  const _ParsedUnifiedDiff({
    required this.fileName,
    required this.rawPatch,
    required this.hunks,
  });

  int get addedLines =>
      hunks.fold<int>(0, (sum, h) => sum + h.lines.where((line) => line.startsWith('+')).length);

  int get removedLines =>
      hunks.fold<int>(0, (sum, h) => sum + h.lines.where((line) => line.startsWith('-')).length);

  String get signature => '$fileName::$rawPatch';
}


class _CodeEditArtifactPreview {
  final String fileName;
  final String savedPath;
  final List<String> executiveSummary;
  final List<String> changeSummary;
  final String patchConfidence;

  const _CodeEditArtifactPreview({
    required this.fileName,
    required this.savedPath,
    required this.executiveSummary,
    required this.changeSummary,
    required this.patchConfidence,
  });
}

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
  final Map<String, double> _savedScrollOffsets = {};
  bool _pendingScrollRestore = false;
  double _restoreScrollOffset = 0;
  bool _userPausedAutoScroll = false; // user scrolled away during generation
  // Pin-to-top: scroll user message to top of viewport when sending
  bool _wantsPinToTop = false;
  // Code edit attachment state
  String? _pendingCodeEditFileName;
  String? _pendingCodeEditFilePath;
  String? _pendingCodeEditContent;
  String? _lastCodeEditFileName;
  String? _lastCodeEditFilePath;
  String? _dismissedPatchSignature;
  GlobalKey _pinnedUserMessageKey = GlobalKey();
  String? _pinnedStreamingId; // tracks which streaming msg triggered pin
  String? _cachedGreetingName;
  bool _greetingReady = false;

  String _formatModelDisplayName(String name) {
    return name.trim();
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

      final pendingCodeFileName = _pendingCodeEditFileName;
      final pendingCodeFilePath = _pendingCodeEditFilePath;
      final pendingCodeContent = _pendingCodeEditContent;
      String visibleText = text;
      String outgoingText = text;
      final attachmentIds = <String>[...uploadedFileIds];

      if (pendingCodeFileName != null &&
          pendingCodeFileName.trim().isNotEmpty &&
          pendingCodeFilePath != null &&
          pendingCodeFilePath.trim().isNotEmpty) {
        final api = ref.read(apiServiceProvider);
        if (api != null) {
          final uploadedCodeFileId = await api.uploadFile(
            pendingCodeFilePath,
            pendingCodeFileName,
            contentType: 'text/plain',
          );
          attachmentIds.add(uploadedCodeFileId);
        }

        if (pendingCodeContent != null && pendingCodeContent.isNotEmpty) {
          outgoingText = _buildCodeEditPrompt(
            fileName: pendingCodeFileName,
            instruction: text,
            fileContent: pendingCodeContent,
          );
        } else {
          outgoingText = _buildCodeEditInstruction(
            fileName: pendingCodeFileName,
            instruction: text,
          );
        }
      } else if (pendingCodeFileName != null &&
          pendingCodeFileName.trim().isNotEmpty &&
          pendingCodeContent != null &&
          pendingCodeContent.isNotEmpty) {
        outgoingText = _buildCodeEditPrompt(
          fileName: pendingCodeFileName,
          instruction: text,
          fileContent: pendingCodeContent,
        );
      }

      final queuedText =
      outgoingText == visibleText
          ? visibleText
          : packQueuedSendPayload(
        visibleText: visibleText,
        payloadText: outgoingText,
      );

      // Get selected tools
      final toolIds = ref.read(selectedToolIdsProvider);

      // Enqueue task-based send to unify flow across text, images, and tools
      final activeConv = ref.read(activeConversationProvider);
      await ref
          .read(taskQueueProvider.notifier)
          .enqueueSendText(
        conversationId: activeConv?.id,
        text: queuedText,
        attachments: attachmentIds.isNotEmpty ? attachmentIds : null,
        toolIds: toolIds.isNotEmpty ? toolIds : null,
      );

      // Clear attachments after successful send
      ref.read(attachedFilesProvider.notifier).clearAll();
      if (mounted) {
        setState(() {
          if (pendingCodeFileName != null && pendingCodeFileName.trim().isNotEmpty) {
            _lastCodeEditFileName = pendingCodeFileName;
          }
          if (pendingCodeFilePath != null && pendingCodeFilePath.trim().isNotEmpty) {
            _lastCodeEditFilePath = pendingCodeFilePath;
          }
          _pendingCodeEditFileName = null;
          _pendingCodeEditFilePath = null;
          _pendingCodeEditContent = null;
          _dismissedPatchSignature = null;
        });
      }

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
                      decoration: innerContext.qonduitInputStyles
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

  /// User-initiated scroll to bottom (e.g. button tap).
  /// Resets auto-scroll pause and ends pin-to-top so streaming
  /// continues to follow from the bottom.
  void _userScrollToBottom() {
    if (_wantsPinToTop) {
      final streamingId = _pinnedStreamingId;
      _endPinToTop(instant: true);
      _pinnedStreamingId = streamingId;
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
    if (!_scrollController.hasClients) return;
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

  /// Scrolls the pinned user message to the top of the visible viewport
  /// (just below the floating app bar). Uses an instant jump to avoid
  /// competing with per-chunk scroll updates during streaming.
  ///
  /// If the target widget isn't built yet (off-screen due to lazy list),
  /// scrolls to the bottom first to trigger its layout, then retries.
  void _scrollToUserMessage([int retries = 0]) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _pinnedUserMessageKey.currentContext;
      if (ctx == null) {
        if (retries < 3 && _scrollController.hasClients) {
          // Widget not built yet (off-screen). Jump to bottom to
          // trigger layout of the target message, then retry with
          // smooth ensureVisible on the next frame.
          _scrollToBottom(smooth: false);
          _scrollToUserMessage(retries + 1);
        }
        return;
      }
      final topPadding =
          MediaQuery.of(context).padding.top + kTextTabBarHeight + Spacing.md;
      final viewportHeight = MediaQuery.of(context).size.height;
      // alignment places the widget at (alignment * viewport) from the top
      final alignment = viewportHeight > 0
          ? (topPadding / viewportHeight)
          : 0.0;
      Scrollable.ensureVisible(
        ctx,
        alignment: alignment,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  bool _endPinToTopInFlight = false;

  /// Transitions out of pin-to-top mode.
  ///
  /// When [instant] is true (e.g. during streaming), uses jumpTo to
  /// avoid competing with per-chunk scroll updates. When false (e.g.
  /// streaming just completed), animates smoothly.
  void _endPinToTop({bool instant = false}) {
    if (!_wantsPinToTop || !mounted || _endPinToTopInFlight) return;
    if (!_scrollController.hasClients) {
      setState(() {
        _wantsPinToTop = false;
        _pinnedStreamingId = null;
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
        _pinnedStreamingId = null;
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
            _pinnedStreamingId = null;
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

    final theme = context.qonduitTheme;
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
                        ? context.qonduitTheme.buttonPrimary.withValues(
                      alpha: 0.15,
                    )
                        : context.qonduitTheme.cardBackground,
                    borderRadius: BorderRadius.circular(
                      AppBorderRadius.messageBubble,
                    ),
                    border: Border.all(
                      color: context.qonduitTheme.cardBorder,
                      width: BorderWidth.regular,
                    ),
                    boxShadow: QonduitShadows.messageBubble(context),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        height: 14,
                        width: index % 3 == 0 ? 140 : 220,
                        decoration: BoxDecoration(
                          color: context.qonduitTheme.shimmerBase,
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
                          color: context.qonduitTheme.shimmerBase,
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
                            color: context.qonduitTheme.shimmerBase,
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
    if (isStreaming && messages.length >= 2) {
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
        // Detect user-initiated scroll (drag gesture)
        if (notification is ScrollStartNotification &&
            notification.dragDetails != null) {
          // Dismiss native platform keyboard on drag (mirrors
          // keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag
          // which only affects Flutter's text input system).
          try {
            ref.read(composerAutofocusEnabledProvider.notifier).set(false);
          } catch (_) {}
          // User started dragging - pause auto-scroll during generation
          if (isStreaming && !_userPausedAutoScroll) {
            setState(() {
              _userPausedAutoScroll = true;
            });
            // End pin-to-top when user scrolls away during streaming
            if (_wantsPinToTop) {
              _endPinToTop(instant: true);
            }
          } else if (!isStreaming && _wantsPinToTop) {
            // User scrolled after streaming ended with a short response;
            // smoothly remove the phantom sliver.
            _endPinToTop();
          }
        }
        // Re-enable auto-scroll when user scrolls to bottom
        if (notification is ScrollEndNotification) {
          final distanceFromBottom = _distanceFromBottom();
          if (distanceFromBottom <= 5 && _userPausedAutoScroll) {
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
              itemBuilder: (context, message, index) {
                final isUser = message.role == 'user';
                final isStreaming = message.isStreaming;

                final isSelected = _selectedMessageIds.contains(message.id);

                // Resolve a friendly model display name for message headers
                String? displayModelName;
                Model? matchedModel;
                final rawModel = message.model;
                if (rawModel != null && rawModel.isNotEmpty) {
                  if (models != null) {
                    try {
                      // Prefer exact ID match; fall back to exact name match
                      final match = models.firstWhere(
                            (m) => m.id == rawModel || m.name == rawModel,
                      );
                      matchedModel = match;
                      displayModelName = _formatModelDisplayName(match.name);
                    } catch (_) {
                      // As a fallback, format the raw value to be readable
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

                final adjacency = bubbleAdjacency[index];
                final hasUserBubbleBelow = adjacency.hasUserBelow;
                final hasAssistantBubbleBelow = adjacency.hasAssistantBelow;

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
                  // Wrap the pinned user message with a key for
                  // Scrollable.ensureVisible to target.
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
                      onRegenerate: () => _regenerateMessage(message),
                    ),
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
    final cleanedContent = QonduitMarkdownPreprocessor.sanitize(content);
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
      // use image-only regenerate flow instead of text streaming regeneration
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
    final greetingStyle = theme.textTheme.headlineSmall?.copyWith(
      fontWeight: FontWeight.w600,
      color: context.qonduitTheme.textPrimary,
    );
    final greetingHeight =
        (greetingStyle?.fontSize ?? 24) * (greetingStyle?.height ?? 1.1);
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
                              color: context.qonduitTheme.textSecondary,
                            ),
                            const SizedBox(width: Spacing.xs),
                            Text(
                              pendingFolder.name,
                              style: AppTypography.small.copyWith(
                                color: context.qonduitTheme.textSecondary,
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

  void _showRagCollectionActionsSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.create_new_folder_outlined),
                title: const Text('Create collection'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _promptCreateRagCollection();
                },
              ),
              ListTile(
                leading: const Icon(Icons.note_add_outlined),
                title: const Text('Add text'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _promptAddTextToSelectedRagCollection();
                },
              ),
              ListTile(
                leading: const Icon(Icons.upload_file_outlined),
                title: const Text('Upload document'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _promptUploadDocumentToSelectedRagCollection();
                },
              ),
              ListTile(
                leading: const Icon(Icons.refresh),
                title: const Text('Refresh collections'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  ref.invalidate(ragCollectionsProvider);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _promptCreateRagCollection() async {
    final controller = TextEditingController();

    final createdName = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Create collection'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Collection name',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(controller.text.trim());
              },
              child: const Text('Create'),
            ),
          ],
        );
      },
    );

    if (createdName == null || createdName.isEmpty) return;

    try {
      final api = ref.read(apiServiceProvider);
      if (api == null) return;

      await api.createRagCollection(createdName);
      ref.invalidate(ragCollectionsProvider);
      ref
          .read(selectedRagCollectionProvider.notifier)
          .setCollection(createdName);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Created collection "$createdName"')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to create collection: $e')),
      );
    }
  }

  Future<void> _promptAddTextToSelectedRagCollection() async {
    final selectedCollection = ref.read(selectedRagCollectionProvider);

    if (selectedCollection == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a collection first')),
      );
      return;
    }

    final controller = TextEditingController();

    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text('Add text to $selectedCollection'),
          content: TextField(
            controller: controller,
            maxLines: 10,
            decoration: const InputDecoration(
              hintText: 'Paste notes here...',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(controller.text);
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );

    if (text == null || text.trim().isEmpty) return;

    try {
      final api = ref.read(apiServiceProvider);
      if (api == null) return;

      await api.addTextToRagCollection(
        text: text,
        collection: selectedCollection,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Text added to collection')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to add text: $e')),
      );
    }
  }

  Future<void> _promptUploadDocumentToSelectedRagCollection() async {
    final selectedCollection = ref.read(selectedRagCollectionProvider);

    if (selectedCollection == null || selectedCollection.trim().isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a collection first')),
      );
      return;
    }

    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      withData: false,
      withReadStream: false,
      type: FileType.custom,
      allowedExtensions: const [
        'pdf',
        'docx',
        'xlsx',
        'xls',
        'csv',
        'txt',
        'md',
        'json',
        'cpp',
        'c',
        'h',
        'hpp',
        'py',
        'java',
        'kt',
        'kts',
        'xml',
        'html',
        'css',
        'js',
        'ts',
        'sql',
        'yaml',
        'yml',
        'toml',
        'ini',
        'sh',
        'go',
        'rs',
        'swift',
        'php',
        'rb',
        'pl',
        'lua',
        'vhdl',
        'vhd',
        'v',
        'dart',
        'cs',
        'scala',
        'groovy',
        'm',
        'mm',
        'jl',
        'zig',
        'nim',
        'gradle',
        'cmake',
        'make',
        'mk',
        'bazel',
        'bzl',
        'env',
        'properties',
        'conf',
        'cfg',
        'rst',
        'adoc',
        'tex',
        'tsv',
        'log',
        'dat',
      ],
    );

    if (result == null || result.files.isEmpty) {
      return;
    }

    final picked = result.files.first;
    final filePath = picked.path;
    if (filePath == null || filePath.trim().isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not access selected file')),
      );
      return;
    }

    try {
      final api = ref.read(apiServiceProvider);
      if (api == null) return;

      final uploadResult = await api.uploadDocumentToRagCollection(
        file: File(filePath),
        collection: selectedCollection,
      );

      ref.invalidate(ragCollectionsProvider);
      ref
          .read(selectedRagCollectionProvider.notifier)
          .setCollection(selectedCollection);

      if (!mounted) return;
      final docName =
          uploadResult['document_name']?.toString() ?? picked.name;
      final chunksAdded = uploadResult['chunks_added']?.toString() ?? '?';

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Uploaded "$docName" to $selectedCollection ($chunksAdded chunks)',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to upload document: $e')),
      );
    }
  }



  String _buildCodeEditInstruction({
    required String fileName,
    required String instruction,
  }) {
    return '''
Code edit request for file: $fileName

Please apply the requested change to the attached file.

Requested change:
$instruction
''';
  }

  Future<void> _promptCodeEditTool() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: [
        'cpp','c','h','hpp','py','java','kt','kts','xml','html','css','js','ts',
        'sql','yaml','yml','toml','ini','sh','go','rs','swift','php','rb','pl',
        'lua','vhdl','vhd','v','dart','json','md','txt'
      ],
    );

    if (result == null) return;

    final file = result.files.single;
    final path = file.path;
    if (path == null) return;

    final content = await File(path).readAsString();

    setState(() {
      _pendingCodeEditFileName = file.name;
      _pendingCodeEditFilePath = path;
      _pendingCodeEditContent = content;
    });
  }

  String _buildCodeEditPrompt({
    required String fileName,
    required String instruction,
    required String fileContent,
  }) {
    return '''
Code edit request for file: $fileName

Please apply the requested change to this file.

Requested change:
$instruction

Current file contents:
<<<FILE
$fileContent
FILE
''';
  }

  Widget _buildPendingCodeEditAttachment() {
    final fileName = _pendingCodeEditFileName;
    final content = _pendingCodeEditContent;
    if (fileName == null ||
        fileName.trim().isEmpty ||
        content == null ||
        content.isEmpty) {
      return const SizedBox.shrink();
    }

    final lineCount = '\n'.allMatches(content).length + 1;
    final theme = context.qonduitTheme;
    final Color chipBackground = theme.surfaceContainerHighest;
    final Color chipBorder = theme.cardBorder;
    final Color iconBackground = theme.buttonPrimary.withValues(alpha: 0.10);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.screenPadding,
        0,
        Spacing.screenPadding,
        Spacing.sm,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.md,
              vertical: Spacing.sm,
            ),
            decoration: BoxDecoration(
              color: chipBackground,
              borderRadius: BorderRadius.circular(AppBorderRadius.card),
              border: Border.all(
                color: chipBorder,
                width: BorderWidth.thin,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: iconBackground,
                    borderRadius: BorderRadius.circular(AppBorderRadius.sm),
                  ),
                  child: Icon(
                    Platform.isIOS
                        ? CupertinoIcons.doc_text
                        : Icons.code_outlined,
                    size: IconSize.medium,
                    color: theme.buttonPrimary,
                  ),
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        fileName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.labelStyle.copyWith(
                          color: theme.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Code file • $lineCount lines',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.captionStyle.copyWith(
                          color: theme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: Spacing.xs),
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(AppBorderRadius.round),
                    onTap: () {
                      setState(() {
                        _pendingCodeEditFileName = null;
                        _pendingCodeEditFilePath = null;
                        _pendingCodeEditContent = null;
                      });
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(Spacing.xs),
                      child: Icon(
                        Platform.isIOS ? CupertinoIcons.xmark : Icons.close,
                        size: IconSize.small,
                        color: theme.textSecondary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }


  String _normalizeDiffPath(String rawPath) {
    var normalized = rawPath.trim();
    if (normalized.startsWith('a/')) {
      normalized = normalized.substring(2);
    } else if (normalized.startsWith('b/')) {
      normalized = normalized.substring(2);
    }
    return normalized;
  }

  List<String> _splitNormalizedLines(String input) {
    final normalized = input.replaceAll('\r\n', '\n');
    final lines = normalized.split('\n');
    if (normalized.endsWith('\n') && lines.isNotEmpty) {
      lines.removeLast();
    }
    return lines;
  }

  _ParsedUnifiedDiff? _parseUnifiedDiffFromContent(
      String content, {
        String? expectedFileName,
      }) {
    if (content.trim().isEmpty) return null;
    final sanitized = content
        .replaceAll('```diff', '')
        .replaceAll('```patch', '')
        .replaceAll('```', '')
        .trim();

    final lines = sanitized.replaceAll('\r\n', '\n').split('\n');
    final startIndex = lines.indexWhere((line) => line.startsWith('--- '));
    if (startIndex < 0 || startIndex + 1 >= lines.length) {
      return null;
    }

    final oldPath = lines[startIndex].substring(4).trim();
    final newHeader = lines[startIndex + 1];
    if (!newHeader.startsWith('+++ ')) {
      return null;
    }
    final newPath = newHeader.substring(4).trim();

    final normalizedOld = _normalizeDiffPath(oldPath);
    final normalizedNew = _normalizeDiffPath(newPath);
    if (normalizedOld.isEmpty || normalizedNew.isEmpty) {
      return null;
    }
    if (normalizedOld != normalizedNew) {
      return null;
    }
    if (expectedFileName != null &&
        expectedFileName.trim().isNotEmpty &&
        normalizedNew != expectedFileName.trim()) {
      return null;
    }

    final hunks = <_UnifiedDiffHunk>[];
    final headerRegExp = RegExp(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@');
    var index = startIndex + 2;
    while (index < lines.length) {
      while (index < lines.length && lines[index].trim().isEmpty) {
        index++;
      }
      if (index >= lines.length) break;
      final headerLine = lines[index];
      final match = headerRegExp.firstMatch(headerLine);
      if (match == null) {
        index++;
        continue;
      }

      final oldStart = int.parse(match.group(1)!);
      final oldCount = int.parse(match.group(2) ?? '1');
      final newStart = int.parse(match.group(3)!);
      final newCount = int.parse(match.group(4) ?? '1');

      index++;
      final hunkLines = <String>[];
      while (index < lines.length && !lines[index].startsWith('@@ ')) {
        final line = lines[index];
        if (line.startsWith('--- ') && hunkLines.isEmpty) {
          break;
        }
        if (line.isNotEmpty &&
            !(line.startsWith(' ') ||
                line.startsWith('+') ||
                line.startsWith('-') ||
                line.startsWith(r'\'))) {
          break;
        }
        hunkLines.add(line);
        index++;
      }

      if (hunkLines.isNotEmpty) {
        hunks.add(
          _UnifiedDiffHunk(
            oldStart: oldStart,
            oldCount: oldCount,
            newStart: newStart,
            newCount: newCount,
            lines: hunkLines,
          ),
        );
      }
    }

    if (hunks.isEmpty) return null;

    final patchLines = <String>['--- $normalizedOld', '+++ $normalizedNew'];
    for (final h in hunks) {
      patchLines.add('@@ -${h.oldStart},${h.oldCount} +${h.newStart},${h.newCount} @@');
      patchLines.addAll(h.lines);
    }

    return _ParsedUnifiedDiff(
      fileName: normalizedNew,
      rawPatch: patchLines.join('\n'),
      hunks: hunks,
    );
  }

  _ParsedUnifiedDiff? _findLatestUnifiedDiff(List<ChatMessage> messages) {
    final expectedFile = _lastCodeEditFileName;
    if (expectedFile == null || expectedFile.trim().isEmpty) {
      return null;
    }

    for (final message in messages.reversed) {
      if (message.role != 'assistant') continue;
      final parsed = _parseUnifiedDiffFromContent(
        message.content,
        expectedFileName: expectedFile,
      );
      if (parsed != null) {
        if (_dismissedPatchSignature == parsed.signature) {
          return null;
        }
        return parsed;
      }
    }
    return null;
  }

  String _normalizePatchComparableLine(String line) {
    return line.replaceAll('\t', '    ').replaceAll(RegExp(r'[ \t]+$'), '');
  }

  int _lineMatchStrength(String source, String expected) {
    if (source == expected) return 3;

    final normalizedSource = _normalizePatchComparableLine(source);
    final normalizedExpected = _normalizePatchComparableLine(expected);
    if (normalizedSource == normalizedExpected) return 2;
    if (normalizedSource.trimLeft() == normalizedExpected.trimLeft()) return 1;
    return 0;
  }

  ({List<String> outputLines, int consumed, int score})? _evaluateUnifiedDiffHunkAt(
      List<String> sourceLines,
      _UnifiedDiffHunk hunk,
      int startIndex,
      ) {
    final outputLines = <String>[];
    var cursor = startIndex;
    var score = 0;

    for (final line in hunk.lines) {
      if (line.isEmpty) {
        return null;
      }

      final marker = line[0];
      final value = line.length > 1 ? line.substring(1) : '';

      if (marker == ' ' || marker == '-') {
        if (cursor >= sourceLines.length) {
          return null;
        }

        final sourceLine = sourceLines[cursor];
        final matchStrength = _lineMatchStrength(sourceLine, value);
        if (matchStrength == 0) {
          return null;
        }

        score += matchStrength;
        if (marker == ' ') {
          // Preserve the local file's exact line when context matches fuzzily.
          outputLines.add(sourceLine);
        }
        cursor++;
      } else if (marker == '+') {
        outputLines.add(value);
        score += 2;
      } else if (marker == r'\') {
        // Ignore "\ No newline at end of file"
      } else {
        return null;
      }
    }

    return (outputLines: outputLines, consumed: cursor - startIndex, score: score);
  }

  ({int startIndex, List<String> outputLines, int consumed})? _findBestUnifiedDiffHunkApplication(
      List<String> sourceLines,
      _UnifiedDiffHunk hunk,
      int minStartIndex,
      int targetIndex,
      ) {
    final normalizedTarget = math.max(minStartIndex, targetIndex);
    final searchStart = math.max(minStartIndex, normalizedTarget - 80);
    final searchEnd = math.min(sourceLines.length, normalizedTarget + 80);

    ({int startIndex, List<String> outputLines, int consumed, int score})? bestMatch;

    for (var candidate = searchStart; candidate <= searchEnd; candidate++) {
      final evaluated = _evaluateUnifiedDiffHunkAt(sourceLines, hunk, candidate);
      if (evaluated == null) {
        continue;
      }

      final currentMatch = (
      startIndex: candidate,
      outputLines: evaluated.outputLines,
      consumed: evaluated.consumed,
      score: evaluated.score,
      );

      if (bestMatch == null) {
        bestMatch = currentMatch;
        continue;
      }

      final isBetterScore = currentMatch.score > bestMatch.score;
      final sameScore = currentMatch.score == bestMatch.score;
      final currentDistance = (candidate - normalizedTarget).abs();
      final bestDistance = (bestMatch.startIndex - normalizedTarget).abs();
      final isCloser = currentDistance < bestDistance;

      if (isBetterScore || (sameScore && isCloser)) {
        bestMatch = currentMatch;
      }
    }

    if (bestMatch == null) {
      return null;
    }

    return (
    startIndex: bestMatch.startIndex,
    outputLines: bestMatch.outputLines,
    consumed: bestMatch.consumed,
    );
  }


  List<String> _extractRemovedBlockLines(_UnifiedDiffHunk hunk) {
    final lines = <String>[];
    for (final line in hunk.lines) {
      if (line.isEmpty) continue;
      if (line[0] == '-') {
        lines.add(line.length > 1 ? line.substring(1) : '');
      }
    }
    return lines;
  }

  List<String> _extractAddedBlockLines(_UnifiedDiffHunk hunk) {
    final lines = <String>[];
    for (final line in hunk.lines) {
      if (line.isEmpty) continue;
      if (line[0] == '+') {
        lines.add(line.length > 1 ? line.substring(1) : '');
      }
    }
    return lines;
  }


  bool _lineMatchesLoosely(String source, String expected) {
    if (source == expected) return true;

    final normalizedSource = source.trim().replaceAll(RegExp(r'\s+'), ' ');
    final normalizedExpected = expected.trim().replaceAll(RegExp(r'\s+'), ' ');

    if (normalizedSource == normalizedExpected) return true;
    if (normalizedSource.isEmpty || normalizedExpected.isEmpty) return false;

    return normalizedSource.contains(normalizedExpected) ||
        normalizedExpected.contains(normalizedSource);
  }

  ({int startIndex, List<String> outputLines, int consumed})? _findRemovedBlockReplacement(
      List<String> sourceLines,
      _UnifiedDiffHunk hunk,
      int minStartIndex,
      ) {
    final removedLines = _extractRemovedBlockLines(hunk);
    final addedLines = _extractAddedBlockLines(hunk);
    if (removedLines.isEmpty) {
      return null;
    }

    final maxStart = sourceLines.length - removedLines.length;
    for (var candidate = math.max(0, minStartIndex); candidate <= maxStart; candidate++) {
      var matches = true;
      for (var i = 0; i < removedLines.length; i++) {
        if (!_lineMatchesLoosely(sourceLines[candidate + i], removedLines[i])) {
          matches = false;
          break;
        }
      }
      if (matches) {
        return (
        startIndex: candidate,
        outputLines: addedLines,
        consumed: removedLines.length,
        );
      }
    }
    return null;
  }

  String? _applyUnifiedDiffToContent(String originalContent, _ParsedUnifiedDiff diff) {
    final originalHadTrailingNewline = originalContent.replaceAll('\r\n', '\n').endsWith('\n');
    final sourceLines = _splitNormalizedLines(originalContent);
    final result = <String>[];
    var cursor = 0;

    for (final hunk in diff.hunks) {
      final targetIndex = (hunk.oldStart <= 0) ? 0 : hunk.oldStart - 1;
      final resolvedHunk = _findBestUnifiedDiffHunkApplication(
        sourceLines,
        hunk,
        cursor,
        targetIndex,
      );
      final appliedHunk = resolvedHunk ?? _findRemovedBlockReplacement(
        sourceLines,
        hunk,
        cursor,
      );
      if (appliedHunk == null) {
        return null;
      }

      result.addAll(sourceLines.sublist(cursor, appliedHunk.startIndex));
      result.addAll(appliedHunk.outputLines);
      cursor = appliedHunk.startIndex + appliedHunk.consumed;
    }

    if (cursor > sourceLines.length) {
      return null;
    }
    result.addAll(sourceLines.sublist(cursor));

    final output = result.join('\n');
    return originalHadTrailingNewline ? '$output\n' : output;
  }


  String _truncateDiffSnippet(String value, {int maxLength = 84}) {
    final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= maxLength) {
      return normalized;
    }
    return '${normalized.substring(0, maxLength - 1).trimRight()}…';
  }

  bool _isMeaningfulDiffSnippet(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return false;
    if (trimmed.startsWith('@@') ||
        trimmed.startsWith('--- ') ||
        trimmed.startsWith('+++ ')) {
      return false;
    }
    if (RegExp(r'^[{}\[\]();,]+$').hasMatch(trimmed)) {
      return false;
    }
    return true;
  }

  String? _firstMeaningfulDiffLine(
      Iterable<String> lines,
      String prefix,
      ) {
    for (final line in lines) {
      if (!line.startsWith(prefix)) continue;
      final raw = line.length > 1 ? line.substring(1).trim() : '';
      if (!_isMeaningfulDiffSnippet(raw)) continue;
      return raw;
    }
    return null;
  }

  List<String> _extractTouchedDiffSymbols(_ParsedUnifiedDiff diff) {
    final symbols = <String>[];
    final seen = <String>{};
    final blocked = <String>{
      'if',
      'for',
      'while',
      'switch',
      'return',
      'catch',
      'else',
      'await',
      'setState',
      'Text',
      'Icon',
      'Row',
      'Column',
      'Container',
      'Padding',
    };
    final patterns = <RegExp>[
      RegExp(r'\b(?:class|enum|mixin|extension|typedef)\s+([A-Za-z_]\w*)'),
      RegExp(
        r'\b([A-Za-z_]\w*)\s*\([^)]*\)\s*(?:async\s*)?(?:\{|=>)',
      ),
      RegExp(r'\b([A-Za-z_]\w*)\s*=\s*'),
    ];

    for (final hunk in diff.hunks) {
      for (final line in hunk.lines) {
        if (!(line.startsWith('+') || line.startsWith('-'))) continue;
        final source = line.length > 1 ? line.substring(1).trim() : '';
        if (source.isEmpty) continue;
        for (final pattern in patterns) {
          final match = pattern.firstMatch(source);
          if (match == null) continue;
          final symbol = match.group(1)?.trim();
          if (symbol == null ||
              symbol.isEmpty ||
              blocked.contains(symbol) ||
              seen.contains(symbol)) {
            continue;
          }
          seen.add(symbol);
          symbols.add(symbol);
          if (symbols.length >= 4) {
            return symbols;
          }
        }
      }
    }
    return symbols;
  }

  List<String> _buildUnifiedDiffSummary(_ParsedUnifiedDiff diff) {
    final summary = <String>[];
    summary.add(
      'Adds ${diff.addedLines} line${diff.addedLines == 1 ? '' : 's'} and removes '
          '${diff.removedLines} line${diff.removedLines == 1 ? '' : 's'}.',
    );

    final touchedSymbols = _extractTouchedDiffSymbols(diff);
    if (touchedSymbols.isNotEmpty) {
      summary.add('Touches: ${touchedSymbols.join(', ')}.');
    }

    for (final hunk in diff.hunks) {
      final removed = _firstMeaningfulDiffLine(hunk.lines, '-');
      final added = _firstMeaningfulDiffLine(hunk.lines, '+');

      if (removed != null && added != null) {
        summary.add(
          'Replaces "${_truncateDiffSnippet(removed)}" with '
              '"${_truncateDiffSnippet(added)}".',
        );
      } else if (added != null) {
        summary.add('Adds "${_truncateDiffSnippet(added)}".');
      } else if (removed != null) {
        summary.add('Removes "${_truncateDiffSnippet(removed)}".');
      }

      if (summary.length >= 4) {
        break;
      }
    }

    return summary.take(4).toList(growable: false);
  }

  Future<void> _copyUnifiedDiffPatch(_ParsedUnifiedDiff diff) async {
    await Clipboard.setData(ClipboardData(text: diff.rawPatch));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Patch copied to clipboard')),
    );
  }

  Future<void> _applyUnifiedDiffPatch(_ParsedUnifiedDiff diff) async {
    final filePath = _lastCodeEditFilePath;
    if (filePath == null || filePath.trim().isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Original local file path is not available')),
      );
      return;
    }

    try {
      final file = File(filePath);
      if (!await file.exists()) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('File not found: $filePath')),
        );
        return;
      }

      final original = await file.readAsString();
      final updated = _applyUnifiedDiffToContent(original, diff);
      if (updated == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Patch could not be applied cleanly')),
        );
        return;
      }

      await file.writeAsString(updated);
      if (!mounted) return;
      setState(() {
        _dismissedPatchSignature = diff.signature;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Applied patch to ${diff.fileName}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to apply patch: $e')),
      );
    }
  }

  Widget _buildUnifiedDiffReviewCard(List<ChatMessage> messages) {
    final diff = _findLatestUnifiedDiff(messages);
    if (diff == null) {
      return const SizedBox.shrink();
    }

    final theme = context.qonduitTheme;
    final summaryLines = _buildUnifiedDiffSummary(diff);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.screenPadding,
        0,
        Spacing.screenPadding,
        Spacing.sm,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Container(
            padding: const EdgeInsets.all(Spacing.md),
            decoration: BoxDecoration(
              color: theme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(AppBorderRadius.card),
              border: Border.all(
                color: theme.cardBorder,
                width: BorderWidth.thin,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: theme.buttonPrimary.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(AppBorderRadius.sm),
                      ),
                      child: Icon(
                        Platform.isIOS
                            ? CupertinoIcons.doc_plaintext
                            : Icons.alt_route,
                        size: IconSize.medium,
                        color: theme.buttonPrimary,
                      ),
                    ),
                    const SizedBox(width: Spacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Patch ready for ${diff.fileName}',
                            style: AppTypography.labelStyle.copyWith(
                              color: theme.textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '+${diff.addedLines}  -${diff.removedLines}  • unified diff',
                            style: AppTypography.captionStyle.copyWith(
                              color: theme.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(AppBorderRadius.round),
                        onTap: () {
                          setState(() {
                            _dismissedPatchSignature = diff.signature;
                          });
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(Spacing.xs),
                          child: Icon(
                            Platform.isIOS ? CupertinoIcons.xmark : Icons.close,
                            size: IconSize.small,
                            color: theme.textSecondary,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                if (summaryLines.isNotEmpty) ...[
                  const SizedBox(height: Spacing.sm),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(Spacing.sm),
                    decoration: BoxDecoration(
                      color: theme.surfaceBackground.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(AppBorderRadius.sm),
                      border: Border.all(
                        color: theme.cardBorder.withValues(alpha: 0.7),
                        width: BorderWidth.thin,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Quick summary',
                          style: AppTypography.captionStyle.copyWith(
                            color: theme.textSecondary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: Spacing.xs),
                        for (final line in summaryLines)
                          Padding(
                            padding: const EdgeInsets.only(bottom: Spacing.xs),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Container(
                                    width: 5,
                                    height: 5,
                                    decoration: BoxDecoration(
                                      color: theme.buttonPrimary,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: Spacing.xs),
                                Expanded(
                                  child: Text(
                                    line,
                                    style: AppTypography.captionStyle.copyWith(
                                      color: theme.textPrimary,
                                      height: 1.35,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: Spacing.sm),
                Wrap(
                  spacing: Spacing.xs,
                  runSpacing: Spacing.xs,
                  children: [
                    AdaptiveButton.child(
                      onPressed: () => _applyUnifiedDiffPatch(diff),
                      style: AdaptiveButtonStyle.filled,
                      child: const Text('Apply patch'),
                    ),
                    AdaptiveButton.child(
                      onPressed: () => _copyUnifiedDiffPatch(diff),
                      style: AdaptiveButtonStyle.plain,
                      child: const Text('Copy patch'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }


  List<String> _extractSummaryBullets(String sectionBody) {
    final lines = sectionBody
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .map((line) => line.replaceFirst(RegExp(r'^[-•*]\s*'), '').trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    return lines;
  }

  _CodeEditArtifactPreview? _findLatestCodeEditArtifactPreview(List<ChatMessage> messages) {
    final preparedFileRegExp = RegExp(r'^Prepared File:\s*(.+)$', multiLine: true);
    final savedPathRegExp = RegExp(r'^Saved Path:\s*(.+)$', multiLine: true);
    final confidenceRegExp = RegExp(r'^Patch Confidence:\s*(HIGH|MEDIUM|LOW)\s*$', multiLine: true);

    for (final message in messages.reversed) {
      if (message.role != 'assistant') continue;
      final content = message.content;
      if (content.trim().isEmpty) continue;

      final preparedMatch = preparedFileRegExp.firstMatch(content);
      final pathMatch = savedPathRegExp.firstMatch(content);
      if (preparedMatch == null || pathMatch == null) {
        continue;
      }

      final fileName = preparedMatch.group(1)?.trim() ?? '';
      final savedPath = pathMatch.group(1)?.trim() ?? '';
      if (fileName.isEmpty || savedPath.isEmpty) {
        continue;
      }

      final executiveSection = RegExp(
        r'Executive Summary\s*(.*?)\s*(?:Change Summary|Patch Confidence:|Prepared File:|$)',
        dotAll: true,
      ).firstMatch(content)?.group(1) ?? '';
      final changeSection = RegExp(
        r'Change Summary\s*(.*?)\s*(?:Patch Confidence:|Prepared File:|$)',
        dotAll: true,
      ).firstMatch(content)?.group(1) ?? '';
      final confidence = confidenceRegExp.firstMatch(content)?.group(1)?.toLowerCase() ?? 'low';

      return _CodeEditArtifactPreview(
        fileName: fileName,
        savedPath: savedPath,
        executiveSummary: _extractSummaryBullets(executiveSection),
        changeSummary: _extractSummaryBullets(changeSection),
        patchConfidence: confidence,
      );
    }

    return null;
  }

  Future<void> _copyCodeEditArtifactPath(_CodeEditArtifactPreview artifact) async {
    await Clipboard.setData(ClipboardData(text: artifact.savedPath));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Saved file path copied to clipboard')),
    );
  }

  Widget _buildCodeEditArtifactCard(List<ChatMessage> messages) {
    final artifact = _findLatestCodeEditArtifactPreview(messages);
    if (artifact == null) {
      return const SizedBox.shrink();
    }

    final theme = context.qonduitTheme;
    final confidenceLabel = artifact.patchConfidence.toUpperCase();

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.screenPadding,
        0,
        Spacing.screenPadding,
        Spacing.sm,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Container(
            padding: const EdgeInsets.all(Spacing.md),
            decoration: BoxDecoration(
              color: theme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(AppBorderRadius.card),
              border: Border.all(
                color: theme.cardBorder,
                width: BorderWidth.thin,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: theme.buttonPrimary.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(AppBorderRadius.sm),
                      ),
                      child: Icon(
                        Platform.isIOS
                            ? CupertinoIcons.doc_text
                            : Icons.insert_drive_file_outlined,
                        size: IconSize.medium,
                        color: theme.buttonPrimary,
                      ),
                    ),
                    const SizedBox(width: Spacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            artifact.fileName,
                            style: AppTypography.labelStyle.copyWith(
                              color: theme.textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Modified file ready • Patch confidence: $confidenceLabel',
                            style: AppTypography.captionStyle.copyWith(
                              color: theme.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (artifact.executiveSummary.isNotEmpty) ...[
                  const SizedBox(height: Spacing.sm),
                  Text(
                    'Executive Summary',
                    style: AppTypography.captionStyle.copyWith(
                      color: theme.textSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: Spacing.xs),
                  for (final item in artifact.executiveSummary)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Spacing.xs),
                      child: Text(
                        '• $item',
                        style: AppTypography.captionStyle.copyWith(
                          color: theme.textPrimary,
                          height: 1.35,
                        ),
                      ),
                    ),
                ],
                if (artifact.changeSummary.isNotEmpty) ...[
                  const SizedBox(height: Spacing.xs),
                  Text(
                    'Change Summary',
                    style: AppTypography.captionStyle.copyWith(
                      color: theme.textSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: Spacing.xs),
                  for (final item in artifact.changeSummary)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Spacing.xs),
                      child: Text(
                        '• $item',
                        style: AppTypography.captionStyle.copyWith(
                          color: theme.textPrimary,
                          height: 1.35,
                        ),
                      ),
                    ),
                ],
                const SizedBox(height: Spacing.sm),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(Spacing.sm),
                  decoration: BoxDecoration(
                    color: theme.surfaceBackground.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(AppBorderRadius.sm),
                    border: Border.all(
                      color: theme.cardBorder.withValues(alpha: 0.7),
                      width: BorderWidth.thin,
                    ),
                  ),
                  child: Text(
                    artifact.savedPath,
                    style: AppTypography.captionStyle.copyWith(
                      color: theme.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(height: Spacing.sm),
                Wrap(
                  spacing: Spacing.xs,
                  runSpacing: Spacing.xs,
                  children: [
                    AdaptiveButton.child(
                      onPressed: () => _copyCodeEditArtifactPath(artifact),
                      style: AdaptiveButtonStyle.filled,
                      child: const Text('Copy path'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showKnowledgeToolSheet() async {
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
      builder: (sheetContext) => KnowledgeToolSheet(
        onSelectCollection: _promptSelectRagCollection,
        onCreateCollection: _promptCreateRagCollection,
        onAddText: _promptAddTextToSelectedRagCollection,
        onUploadDocument: _promptUploadDocumentToSelectedRagCollection,
        onDeleteCollection: _promptDeleteRagCollection,
      ),
    ).whenComplete(() {
      if (!mounted) return;
      if (hadFocus) {
        try {
          ref.read(composerAutofocusEnabledProvider.notifier).set(true);
        } catch (_) {}
        final cur = ref.read(inputFocusTriggerProvider);
        ref.read(inputFocusTriggerProvider.notifier).set(cur + 1);
      }
    });
  }

  Future<void> _promptSelectRagCollection() async {
    final collectionsValue = ref.read(ragCollectionsProvider);
    final collections = collectionsValue.asData?.value ?? <String>[];
    final currentCollection = ref.read(selectedRagCollectionProvider);

    if (collections.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No collections available')),
      );
      return;
    }

    final selected = await showDialog<String?>(
      context: context,
      builder: (dialogContext) {
        return SimpleDialog(
          title: const Text('Select collection'),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(null),
              child: const Text('No collection'),
            ),
            ...collections.map(
                  (name) => SimpleDialogOption(
                onPressed: () => Navigator.of(dialogContext).pop(name),
                child: Row(
                  children: [
                    Expanded(child: Text(name)),
                    if (name == currentCollection)
                      const Icon(Icons.check, size: 18),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );

    ref.read(selectedRagCollectionProvider.notifier).setCollection(selected);
  }

  Future<void> _promptDeleteRagCollection() async {
    final selectedCollection = ref.read(selectedRagCollectionProvider);

    if (selectedCollection == null || selectedCollection.trim().isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a collection first')),
      );
      return;
    }

    final confirmed = await ThemedDialogs.confirm(
      context,
      title: 'Delete collection',
      message:
      'Delete collection "$selectedCollection"? This will remove its indexed chunks and uploaded files.',
      confirmText: 'Delete',
      cancelText: 'Cancel',
      isDestructive: true,
    );

    if (confirmed != true) return;

    try {
      final api = ref.read(apiServiceProvider);
      if (api == null) return;

      final result = await api.deleteRagCollection(selectedCollection);

      ref.invalidate(ragCollectionsProvider);
      ref.read(selectedRagCollectionProvider.notifier).setCollection(null);

      if (!mounted) return;
      final deletedPoints = result['deleted_points']?.toString() ?? '0';
      final deletedFiles = result['deleted_files']?.toString() ?? '0';

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Deleted "$selectedCollection" ($deletedPoints chunks, $deletedFiles files)',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to delete collection: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;

    // Use select to watch only the selected model to reduce rebuilds
    final selectedModel = ref.watch(
      selectedModelProvider.select((model) => model),
    );
    final currentMessages = ref.watch(
      chatMessagesProvider.select((messages) => messages),
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
      color: context.qonduitTheme.textPrimary,
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
      if (_userPausedAutoScroll) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;
        if (_userPausedAutoScroll) return;

        if (_wantsPinToTop) {
          // During pin-to-top, end it once the actual content (excluding
          // the phantom sliver) has grown past the viewport so the view
          // transitions to scroll-following like ChatGPT.
          final position = _scrollController.position;
          final phantomHeight = MediaQuery.of(context).size.height;
          final actualMaxExtent = position.maxScrollExtent - phantomHeight;
          if (actualMaxExtent > 0) {
            // Preserve _pinnedStreamingId so the pin-to-top detection
            // guard at line ~1244 doesn't re-trigger on the next rebuild.
            final streamingId = _pinnedStreamingId;
            _endPinToTop(instant: true);
            _pinnedStreamingId = streamingId;
            _scrollToBottom(smooth: false);
          }
          return;
        }

        const keepPinnedThreshold = 60.0;
        final dist = _distanceFromBottom();
        if (dist > 0 && dist <= keepPinnedThreshold) {
          _scrollToBottom(smooth: false);
        }
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
          backgroundColor: context.qonduitTheme.surfaceBackground,
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
                  color: context.qonduitTheme.textPrimary,
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
                    color: context.qonduitTheme.textPrimary,
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
                    color: context.qonduitTheme.textPrimary,
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
                          child: QonduitLoading.skeleton(
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
                              color: context.qonduitTheme.iconSecondary,
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
                                  context.qonduitTheme.iconSecondary,
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
                            color: context.qonduitTheme.success
                                .withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(
                              AppBorderRadius.badge,
                            ),
                            border: Border.all(
                              color: context.qonduitTheme.success
                                  .withValues(alpha: 0.3),
                              width: BorderWidth.thin,
                            ),
                          ),
                          child: Text(
                            'REVIEWER MODE',
                            style: AppTypography.captionStyle.copyWith(
                              color: context.qonduitTheme.success,
                              fontWeight: FontWeight.w600,
                              fontSize: 9,
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
                          color: context.qonduitTheme.textPrimary,
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
                          HapticFeedback.selectionClick();
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
                            : context.qonduitTheme.textPrimary,
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
                      color: context.qonduitTheme.textPrimary,
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
                    color: context.qonduitTheme.error,
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
                  child: QonduitRefreshIndicator(
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
                            _buildCodeEditArtifactCard(currentMessages),
                            _buildPendingCodeEditAttachment(),
                            // RepaintBoundary prevents BackdropFilter
                            // (AdaptiveBlurView) from going blank when
                            // a modal sheet scrolls over it.
                            RepaintBoundary(
                              child: ModernChatInput(
                                onSendMessage: (text) =>
                                    _handleMessageSend(text, selectedModel),
                                onVoiceInput: null,
                                onVoiceCall: _handleVoiceCall,
                                onFileAttachment: _handleFileAttachment,
                                onImageAttachment: _handleImageAttachment,
                                onCameraCapture: () =>
                                    _handleImageAttachment(fromCamera: true),
                                onWebAttachment: _promptAttachWebpage,
                                onKnowledgeTool: _showKnowledgeToolSheet,
                                onCodeEditTool: _promptCodeEditTool,
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
                        currentMessages.isNotEmpty)
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

class KnowledgeToolSheet extends ConsumerWidget {
  const KnowledgeToolSheet({
    super.key,
    required this.onSelectCollection,
    required this.onCreateCollection,
    required this.onAddText,
    required this.onUploadDocument,
    required this.onDeleteCollection,
  });

  final Future<void> Function() onSelectCollection;
  final Future<void> Function() onCreateCollection;
  final Future<void> Function() onAddText;
  final Future<void> Function() onUploadDocument;
  final Future<void> Function() onDeleteCollection;

  @override
  Widget build(BuildContext context, WidgetRef widgetRef) {
    final collectionsValue = widgetRef.watch(ragCollectionsProvider);
    final currentCollection = widgetRef.watch(selectedRagCollectionProvider);

    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: collectionsValue.when(
            data: (collections) {
              return SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Knowledge',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      currentCollection == null || currentCollection.trim().isEmpty
                          ? 'Current collection: none'
                          : 'Current collection: $currentCollection',
                    ),
                    const SizedBox(height: 16),
                    ListTile(
                      leading: const Icon(Icons.folder_open_outlined),
                      title: const Text('Select collection'),
                      subtitle: Text(
                        collections.isEmpty
                            ? 'No collections available'
                            : 'Choose from ${collections.length} collections',
                      ),
                      onTap: () async {
                        Navigator.of(context).pop();
                        await onSelectCollection();
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.create_new_folder_outlined),
                      title: const Text('Create collection'),
                      onTap: () async {
                        Navigator.of(context).pop();
                        await onCreateCollection();
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.note_add_outlined),
                      title: const Text('Add text'),
                      onTap: () async {
                        Navigator.of(context).pop();
                        await onAddText();
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.upload_file_outlined),
                      title: const Text('Upload document'),
                      onTap: () async {
                        Navigator.of(context).pop();
                        await onUploadDocument();
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.delete_outline),
                      title: const Text('Delete collection'),
                      onTap: () async {
                        Navigator.of(context).pop();
                        await onDeleteCollection();
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.refresh),
                      title: const Text('Refresh collections'),
                      onTap: () {
                        widgetRef.invalidate(ragCollectionsProvider);
                        Navigator.of(context).pop();
                      },
                    ),
                  ],
                ),
              );
            },
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (error, stack) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text('Failed to load collections: $error'),
            ),
          ),
        ),
      ),
    );
  }
}

// Extension on _ChatPageState for utility methods
extension on _ChatPageState {}