import 'dart:async';
import 'dart:io' show Platform;

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models/conversation.dart';
import '../../../core/models/folder.dart';
import '../../../core/models/model.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/haptic_service.dart';
import '../../../core/services/navigation_service.dart';
import '../../../core/services/settings_service.dart';
import '../../../core/widgets/error_boundary.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/conduit_input_styles.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/conversation_context_menu.dart';
import '../../../shared/services/tasks/task_queue.dart';
import '../../../shared/widgets/adaptive_route_shell.dart';
import '../../../shared/widgets/adaptive_toolbar_components.dart';
import '../../../shared/widgets/chrome_gradient_fade.dart';
import '../../../shared/widgets/conduit_loading.dart';
import '../../../shared/widgets/measure_size.dart';
import '../../../shared/widgets/middle_ellipsis_text.dart';
import '../../../shared/widgets/responsive_drawer_layout.dart';
import '../../../shared/widgets/sheet_handle.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../shared/widgets/themed_sheets.dart';
import '../../chat/providers/chat_providers.dart' as chat;
import '../../chat/providers/context_attachments_provider.dart';
import '../../chat/services/file_attachment_service.dart';
import '../../chat/widgets/model_selector_sheet.dart';
import '../../chat/widgets/context_attachment_widget.dart';
import '../../chat/widgets/file_attachment_widget.dart';
import '../../chat/widgets/modern_chat_input.dart';
import '../../chat/widgets/server_file_picker_sheet.dart';
import '../../chat/voice_call/presentation/voice_call_launcher.dart';
import '../../tools/providers/tools_providers.dart';
import '../widgets/conversation_tile.dart';
import '../widgets/folder_icon.dart';

/// Displays a folder-focused page with its direct child folders and chats.
class FolderPage extends ConsumerStatefulWidget {
  const FolderPage({super.key, required this.folderId});

  final String folderId;

  @override
  ConsumerState<FolderPage> createState() => _FolderPageState();
}

class _FolderPageState extends ConsumerState<FolderPage> {
  bool _isLoadingConversation = false;
  bool _isSendingComposerMessage = false;
  double _inputHeight = 0;
  int _composerResetNonce = 0;
  String? _pendingConversationId;

  @override
  void initState() {
    super.initState();
    _scheduleFolderDraftPriming(widget.folderId);
  }

  @override
  void didUpdateWidget(covariant FolderPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.folderId != widget.folderId) {
      _scheduleFolderDraftPriming(widget.folderId);
    }
  }

  void _scheduleFolderDraftPriming(String folderId) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.folderId != folderId) {
        return;
      }
      _primeFolderDraftState(resetComposer: true);
    });
  }

  void _primeFolderDraftState({bool resetComposer = false}) {
    ref.read(pendingFolderIdProvider.notifier).set(widget.folderId);
    ref.read(chat.chatMessagesProvider.notifier).clearMessages();
    ref.read(activeConversationProvider.notifier).clear();
    ref.read(contextAttachmentsProvider.notifier).clear();
    ref.read(attachedFilesProvider.notifier).clearAll();
    try {
      ref.read(chat.prefilledInputTextProvider.notifier).clear();
    } catch (_) {}

    final settings = ref.read(appSettingsProvider);
    ref
        .read(temporaryChatEnabledProvider.notifier)
        .set(settings.temporaryChatByDefault);

    if (resetComposer && mounted) {
      setState(() => _composerResetNonce++);
    }

    unawaited(chat.restoreDefaultModel(ref));
  }

  String _formatModelDisplayName(String name) => name.trim();

  AdaptiveAppBar _buildAdaptiveAppBar(
    BuildContext context,
    AppLocalizations l10n,
    Folder? folder,
  ) {
    final tintColor = context.conduitTheme.textPrimary;
    final hasOverflowMenu = folder != null;
    final leading = _buildFolderToolbarLeading(
      context: context,
      l10n: l10n,
      hasOverflowMenu: hasOverflowMenu,
      tintColor: tintColor,
    );
    final actions = _buildFolderToolbarActionWidgets(context, folder);
    final leadingWidth = resolveConduitAdaptiveLeadingPillWidth(
      context,
      trailingActionCount: hasOverflowMenu ? 3 : 2,
      maxWidth: 200,
    );

    return AdaptiveAppBar(
      useNativeToolbar: false,
      tintColor: tintColor,
      cupertinoNavigationBar: CupertinoNavigationBar(
        automaticallyImplyLeading: false,
        border: null,
        backgroundColor: Colors.transparent,
        enableBackgroundFilterBlur: false,
        leading: leading,
        trailing: Row(mainAxisSize: MainAxisSize.min, children: actions),
      ),
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: Elevation.none,
        scrolledUnderElevation: Elevation.none,
        leadingWidth:
            TouchTarget.minimum + Spacing.xs + leadingWidth + Spacing.md,
        leading: leading,
        actions: actions,
      ),
    );
  }

  Widget _buildFolderToolbarLeading({
    required BuildContext context,
    required AppLocalizations l10n,
    required bool hasOverflowMenu,
    required Color tintColor,
  }) {
    final maxPillWidth = resolveConduitAdaptiveLeadingPillWidth(
      context,
      trailingActionCount: hasOverflowMenu ? 3 : 2,
      maxWidth: 200,
    );
    final label = _formatModelDisplayName(
      ref.watch(selectedModelProvider)?.name ?? l10n.chooseModel,
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ConduitAdaptiveAppBarIconButton(
          key: const ValueKey<String>('folder-page-drawer-button'),
          icon: Platform.isIOS ? CupertinoIcons.line_horizontal_3 : Icons.menu,
          onPressed: _toggleDrawer,
          iconColor: tintColor,
        ),
        const SizedBox(width: Spacing.xs),
        ConduitAdaptiveAppBarModelSelector(
          key: const ValueKey<String>('folder-page-model-selector'),
          label: label,
          maxWidth: maxPillWidth,
          onPressed: _showModelSelector,
        ),
      ],
    );
  }

  List<Widget> _buildFolderToolbarActionWidgets(
    BuildContext context,
    Folder? folder,
  ) {
    final isTemporary = ref.watch(temporaryChatEnabledProvider);
    final actions = <Widget>[
      ConduitAdaptiveAppBarIconButton(
        key: const ValueKey<String>('folder-page-temp-button'),
        icon: isTemporary
            ? (Platform.isIOS ? CupertinoIcons.eye_slash : Icons.visibility_off)
            : (Platform.isIOS ? CupertinoIcons.eye : Icons.visibility_outlined),
        iconColor: isTemporary ? Colors.blue : context.conduitTheme.textPrimary,
        onPressed: () {
          ConduitHaptics.selectionClick();
          final current = ref.read(temporaryChatEnabledProvider);
          ref.read(temporaryChatEnabledProvider.notifier).set(!current);
        },
      ),
      const SizedBox(width: Spacing.sm),
      ConduitAdaptiveAppBarIconButton(
        key: const ValueKey<String>('folder-page-new-chat-button'),
        icon: Platform.isIOS ? CupertinoIcons.create : Icons.add_comment,
        iconColor: context.conduitTheme.textPrimary,
        onPressed: _handleNewChat,
      ),
    ];

    if (folder != null) {
      actions
        ..add(const SizedBox(width: Spacing.sm))
        ..add(
          _FolderToolbarPopupButton(
            tintColor: context.conduitTheme.textPrimary,
            onSelected: (action) =>
                _handleFolderToolbarSelection(folder, action),
          ),
        );
    }

    return actions;
  }

  void _handleFolderToolbarSelection(Folder folder, String action) {
    ConduitHaptics.selectionClick();
    _dismissComposerFocus();

    switch (action) {
      case 'edit-folder':
        _showEditFolderSheet(folder);
        return;
      case 'system-prompt':
        _showSystemPromptSheet(folder);
        return;
    }
  }

  Future<void> _showModelSelector() async {
    final hadFocus = ref.read(chat.composerHasFocusProvider);
    _dismissComposerFocus();

    try {
      List<Model> models;
      final modelsAsync = ref.read(modelsProvider);

      if (modelsAsync.hasValue) {
        models = modelsAsync.value!;
      } else {
        if (modelsAsync.hasError) {
          ref.invalidate(modelsProvider);
        }
        models = await ref.read(modelsProvider.future);
      }

      if (!mounted) {
        return;
      }

      await ThemedSheets.showCustom<void>(
        context: context,
        isScrollControlled: true,
        builder: (sheetContext) => ModelSelectorSheet(models: models, ref: ref),
      );
    } catch (_) {
      return;
    } finally {
      if (mounted && hadFocus) {
        try {
          ref.read(chat.composerAutofocusEnabledProvider.notifier).set(true);
        } catch (_) {}
        final current = ref.read(chat.inputFocusTriggerProvider);
        ref.read(chat.inputFocusTriggerProvider.notifier).set(current + 1);
      }
    }
  }

  void _toggleDrawer() {
    final layout = ResponsiveDrawerLayout.of(context);
    if (layout == null) {
      return;
    }

    if (!layout.isOpen) {
      _dismissComposerFocus();
    }
    layout.toggle();
  }

  void _handleNewChat() {
    ConduitHaptics.selectionClick();
    _dismissComposerFocus();
    ref.read(attachedFilesProvider.notifier).clearAll();
    try {
      ref.read(chat.prefilledInputTextProvider.notifier).clear();
    } catch (_) {}

    chat.startNewChat(ref);

    final settings = ref.read(appSettingsProvider);
    ref
        .read(temporaryChatEnabledProvider.notifier)
        .set(settings.temporaryChatByDefault);

    unawaited(NavigationService.navigateToChat());
  }

  String? _normalizeParentId(String? parentId) {
    if (parentId == null || parentId.isEmpty) {
      return null;
    }
    return parentId;
  }

  Folder? _folderById(List<Folder> folders, String folderId) {
    for (final folder in folders) {
      if (folder.id == folderId) {
        return folder;
      }
    }
    return null;
  }

  Map<String?, List<Folder>> _childFoldersByParentId(List<Folder> folders) {
    final foldersById = <String, Folder>{
      for (final folder in folders) folder.id: folder,
    };
    final childFoldersByParentId = <String?, List<Folder>>{};

    for (final folder in folders) {
      final parentId = _normalizeParentId(folder.parentId);
      final resolvedParentId =
          parentId != null && foldersById.containsKey(parentId)
          ? parentId
          : null;
      childFoldersByParentId
          .putIfAbsent(resolvedParentId, () => <Folder>[])
          .add(folder);
    }

    for (final childFolders in childFoldersByParentId.values) {
      childFolders.sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
    }

    return childFoldersByParentId;
  }

  Future<void> _refreshFolderContents() async {
    refreshConversationsCache(ref, includeFolders: true);
    try {
      await ref.read(foldersProvider.future);
    } catch (_) {}
    try {
      await ref.read(
        folderConversationSummariesProvider(widget.folderId).future,
      );
    } catch (_) {}
  }

  Future<bool> _ensureSelectedModel(ProviderContainer container) async {
    if (container.read(selectedModelProvider) != null) {
      return true;
    }

    try {
      List<Model> models;
      final modelsAsync = container.read(modelsProvider);
      if (modelsAsync.hasValue) {
        models = modelsAsync.value!;
      } else {
        models = await container.read(modelsProvider.future);
      }
      if (models.isEmpty) {
        return false;
      }
      container.read(selectedModelProvider.notifier).set(models.first);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _handleComposerSend(String text) async {
    if (_isSendingComposerMessage || _isLoadingConversation) {
      return;
    }

    setState(() => _isSendingComposerMessage = true);
    final container = ProviderScope.containerOf(context, listen: false);

    try {
      final hasModel = await _ensureSelectedModel(container);
      if (!hasModel) {
        return;
      }

      final attachedFiles = container.read(attachedFilesProvider);
      final uploadedFileIds = attachedFiles
          .where(
            (file) =>
                file.status == FileUploadStatus.completed &&
                file.fileId != null,
          )
          .map((file) => file.fileId!)
          .toList(growable: false);
      final toolIds = container.read(selectedToolIdsProvider);

      ConduitHaptics.selectionClick();
      final settings = container.read(appSettingsProvider);
      container
          .read(temporaryChatEnabledProvider.notifier)
          .set(settings.temporaryChatByDefault);
      container.read(pendingFolderIdProvider.notifier).set(widget.folderId);
      container.read(activeConversationProvider.notifier).clear();
      container.read(chat.chatMessagesProvider.notifier).clearMessages();

      NavigationService.router.go(Routes.chat);

      await container
          .read(taskQueueProvider.notifier)
          .enqueueSendText(
            conversationId: null,
            pendingFolderId: widget.folderId,
            text: text,
            attachments: uploadedFileIds.isNotEmpty ? uploadedFileIds : null,
            toolIds: toolIds.isNotEmpty ? toolIds : null,
          );

      container.read(attachedFilesProvider.notifier).clearAll();
    } finally {
      if (mounted) {
        setState(() => _isSendingComposerMessage = false);
      }
    }
  }

  Future<void> _handleFileAttachment() async {
    final fileUploadCapableModels = ref.read(
      chat.fileUploadCapableModelsProvider,
    );
    if (fileUploadCapableModels.isEmpty) {
      return;
    }

    final fileService = ref.read(fileAttachmentServiceProvider);
    if (fileService == null) {
      return;
    }

    try {
      final attachments = await fileService.pickFiles();
      if (attachments.isEmpty) {
        return;
      }

      for (final attachment in attachments) {
        final fileSize = await attachment.file.length();
        if (!chat.validateFileSize(fileSize, 20)) {
          return;
        }
      }

      ref.read(attachedFilesProvider.notifier).addFiles(attachments);
      for (final attachment in attachments) {
        await ref
            .read(taskQueueProvider.notifier)
            .enqueueUploadMedia(
              conversationId: null,
              filePath: attachment.file.path,
              fileName: attachment.displayName,
              fileSize: await attachment.file.length(),
            );
      }
    } catch (_) {}
  }

  void _handleServerFileAttachment() {
    final fileUploadCapableModels = ref.read(
      chat.fileUploadCapableModelsProvider,
    );
    if (fileUploadCapableModels.isEmpty || !mounted) {
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

  Future<void> _handleImageAttachment({bool fromCamera = false}) async {
    final visionCapableModels = ref.read(chat.visionCapableModelsProvider);
    if (visionCapableModels.isEmpty) {
      return;
    }

    final fileService = ref.read(fileAttachmentServiceProvider);
    if (fileService == null) {
      return;
    }

    try {
      final attachment = fromCamera
          ? await fileService.takePhoto()
          : await fileService.pickImage();
      if (attachment == null) {
        return;
      }

      final imageSize = await attachment.file.length();
      if (!chat.validateFileSize(imageSize, 20)) {
        return;
      }

      ref.read(attachedFilesProvider.notifier).addFiles([attachment]);
      await ref
          .read(taskQueueProvider.notifier)
          .enqueueUploadMedia(
            conversationId: null,
            filePath: attachment.file.path,
            fileName: attachment.displayName,
            fileSize: imageSize,
          );
    } catch (_) {}
  }

  Future<void> _handlePastedAttachments(
    List<LocalAttachment> attachments,
  ) async {
    if (attachments.isEmpty) {
      return;
    }

    ref.read(attachedFilesProvider.notifier).addFiles(attachments);
    for (final attachment in attachments) {
      try {
        await ref
            .read(taskQueueProvider.notifier)
            .enqueueUploadMedia(
              conversationId: null,
              filePath: attachment.file.path,
              fileName: attachment.displayName,
              fileSize: await attachment.file.length(),
            );
      } catch (_) {}
    }
  }

  void _handleVoiceCall() {
    unawaited(
      ref.read(voiceCallLauncherProvider).launch(startNewConversation: false),
    );
  }

  void _dismissComposerFocus() {
    try {
      ref.read(chat.composerAutofocusEnabledProvider.notifier).set(false);
    } catch (_) {}
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      SystemChannels.textInput.invokeMethod('TextInput.hide');
    } catch (_) {}
  }

  bool _isYoutubeUrl(String url) {
    return url.startsWith('https://www.youtube.com') ||
        url.startsWith('https://youtu.be') ||
        url.startsWith('https://youtube.com') ||
        url.startsWith('https://m.youtube.com');
  }

  Future<void> _promptAttachWebpage() async {
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      return;
    }

    final l10n = AppLocalizations.of(context)!;
    String url = '';
    bool submitting = false;
    await ThemedDialogs.showCustom<void>(
      context: context,
      builder: (dialogContext) {
        String? errorText;
        return StatefulBuilder(
          builder: (innerContext, setState) {
            void setError(String? message) {
              setState(() {
                errorText = message;
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
                        if (errorText != null) {
                          setError(null);
                        }
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

  Future<void> _showEditFolderSheet(Folder folder) async {
    final updatedFolder = await ThemedSheets.showCustom<Folder>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => _FolderEditSheet(folder: folder),
    );

    if (updatedFolder == null) {
      return;
    }

    ref.read(foldersProvider.notifier).upsertFolder(updatedFolder);
  }

  Future<void> _showSystemPromptSheet(Folder folder) async {
    final updatedFolder = await ThemedSheets.showCustom<Folder>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => _FolderSystemPromptSheet(folder: folder),
    );

    if (updatedFolder == null) {
      return;
    }

    ref.read(foldersProvider.notifier).upsertFolder(updatedFolder);
  }

  void _openFolder(String folderId) {
    if (folderId == widget.folderId) {
      return;
    }

    ConduitHaptics.selectionClick();
    ref.read(pendingFolderIdProvider.notifier).clear();
    context.goNamed(RouteNames.folder, pathParameters: {'id': folderId});
  }

  Future<void> _selectConversation(String conversationId) async {
    if (_isLoadingConversation) {
      return;
    }

    setState(() => _isLoadingConversation = true);
    final container = ProviderScope.containerOf(context, listen: false);

    container.read(temporaryChatEnabledProvider.notifier).set(false);

    try {
      container.read(chat.isLoadingConversationProvider.notifier).set(true);
      _pendingConversationId = conversationId;

      container.read(activeConversationProvider.notifier).clear();
      container.read(chat.chatMessagesProvider.notifier).clearMessages();
      container.read(pendingFolderIdProvider.notifier).clear();

      NavigationService.router.go(Routes.chat);

      final api = container.read(apiServiceProvider);
      if (api != null) {
        final fullConversation = await api.getConversation(conversationId);
        container
            .read(activeConversationProvider.notifier)
            .set(fullConversation);
      } else {
        final conversation = (await container.read(
          conversationsProvider.future,
        )).firstWhere((item) => item.id == conversationId);
        container.read(activeConversationProvider.notifier).set(conversation);
      }

      container.read(chat.isLoadingConversationProvider.notifier).set(false);
      _pendingConversationId = null;
    } catch (_) {
      container.read(chat.isLoadingConversationProvider.notifier).set(false);
      _pendingConversationId = null;
    } finally {
      if (mounted) {
        setState(() => _isLoadingConversation = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final foldersAsync = ref.watch(foldersProvider);
    final folder = foldersAsync.maybeWhen(
      data: (folders) => _folderById(folders, widget.folderId),
      orElse: () => null,
    );

    return ErrorBoundary(
      child: AdaptiveRouteShell(
        backgroundColor: context.conduitTheme.surfaceBackground,
        extendBodyBehindAppBar: true,
        appBar: _buildAdaptiveAppBar(context, l10n, folder),
        body: _buildBody(context, foldersAsync),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    AsyncValue<List<Folder>> foldersAsync,
  ) {
    return foldersAsync.when(
      data: (folders) => _buildFolderContents(context, folders),
      loading: () => Center(
        child: ConduitLoading.primary(
          message: AppLocalizations.of(context)!.folders,
        ),
      ),
      error: (_, _) => _buildMessageState(
        context,
        AppLocalizations.of(context)!.unableToLoadFolder,
      ),
    );
  }

  Widget _buildComposerOverlay(BuildContext context, Folder folder) {
    final theme = Theme.of(context);
    final folderName = folder.name.trim();
    final placeholder = folderName.isEmpty ? null : 'Message $folderName';

    return RepaintBoundary(
      child: MeasureSize(
        onChange: (size) {
          if (!mounted) {
            return;
          }
          setState(() {
            _inputHeight = size.height;
          });
        },
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: const [0.0, 0.4, 1.0],
              colors: [
                theme.scaffoldBackgroundColor.withValues(alpha: 0.0),
                theme.scaffoldBackgroundColor.withValues(alpha: 0.85),
                theme.scaffoldBackgroundColor,
              ],
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: Spacing.xl),
              const FileAttachmentWidget(),
              const ContextAttachmentWidget(),
              RepaintBoundary(
                child: ModernChatInput(
                  key: ValueKey<String>(
                    'folder-page-composer-${widget.folderId}-$_composerResetNonce',
                  ),
                  onSendMessage: _handleComposerSend,
                  enabled:
                      !_isLoadingConversation && !_isSendingComposerMessage,
                  onVoiceCall: _handleVoiceCall,
                  onFileAttachment: _handleFileAttachment,
                  onServerFileAttachment: _handleServerFileAttachment,
                  onImageAttachment: _handleImageAttachment,
                  onCameraCapture: () =>
                      _handleImageAttachment(fromCamera: true),
                  onWebAttachment: _promptAttachWebpage,
                  onPastedAttachments: _handlePastedAttachments,
                  placeholder: placeholder,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFolderContents(BuildContext context, List<Folder> folders) {
    final l10n = AppLocalizations.of(context)!;
    final folder = _folderById(folders, widget.folderId);

    if (folder == null) {
      return _buildMessageState(context, l10n.unableToLoadFolder);
    }

    final childFoldersByParentId = _childFoldersByParentId(folders);
    final childFolders =
        childFoldersByParentId[folder.id]?.toList(growable: false) ??
        const <Folder>[];

    final cachedConversations = ref
        .watch(conversationsProvider)
        .maybeWhen(
          data: (conversations) => conversations
              .where((conversation) => conversation.folderId == folder.id)
              .toList(growable: false),
          orElse: () => const <Conversation>[],
        );

    final folderConversationsAsync = ref.watch(
      folderConversationSummariesProvider(folder.id),
    );
    final folderConversations = folderConversationsAsync.maybeWhen(
      data: (conversations) => conversations,
      orElse: () => cachedConversations,
    );
    final sortedConversations = [...folderConversations]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final isLoadingConversations =
        folderConversationsAsync.isLoading && sortedConversations.isEmpty;

    final topPadding =
        MediaQuery.of(context).padding.top + kTextTabBarHeight + Spacing.md;
    final slivers = <Widget>[
      SliverToBoxAdapter(child: SizedBox(height: topPadding)),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
        sliver: SliverToBoxAdapter(child: _FolderPageHeader(folder: folder)),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: Spacing.lg)),
      if (childFolders.isNotEmpty) ...[
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
          sliver: SliverToBoxAdapter(
            child: _SectionHeader(label: l10n.folders),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: Spacing.xs)),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate((context, index) {
              final childFolder = childFolders[index];

              return _FolderListTile(
                key: ValueKey<String>('folder-page-row-${childFolder.id}'),
                name: childFolder.name,
                iconAlias: childFolder.meta?['icon']?.toString(),
                onTap: () => _openFolder(childFolder.id),
              );
            }, childCount: childFolders.length),
          ),
        ),
      ],
      if (childFolders.isNotEmpty &&
          (sortedConversations.isNotEmpty || isLoadingConversations))
        const SliverToBoxAdapter(child: SizedBox(height: Spacing.md)),
      if (isLoadingConversations)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Spacing.xl),
            child: Center(child: ConduitLoading.inline(context: context)),
          ),
        )
      else if (sortedConversations.isNotEmpty) ...[
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
          sliver: SliverToBoxAdapter(
            child: _SectionHeader(
              label: l10n.recent,
              count: sortedConversations.length,
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: Spacing.xs)),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate((context, index) {
              final conversation = sortedConversations[index];
              final isLoadingSelected =
                  (_pendingConversationId == conversation.id) &&
                  ref.watch(chat.isLoadingConversationProvider);

              return ConduitContextMenu(
                actions: buildConversationActionsWithFolders(
                  context: context,
                  ref: ref,
                  conversation: conversation,
                  foldersEnabled: true,
                  folders: folders,
                ),
                child: ConversationTile(
                  key: ValueKey<String>('folder-chat-${conversation.id}'),
                  title: conversation.title.isEmpty
                      ? 'Chat'
                      : conversation.title,
                  pinned: conversation.pinned,
                  selected: false,
                  isLoading: isLoadingSelected,
                  onTap: _isLoadingConversation
                      ? null
                      : () => _selectConversation(conversation.id),
                ),
              );
            }, childCount: sortedConversations.length),
          ),
        ),
      ] else
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.lg,
              vertical: Spacing.xl,
            ),
            child: Center(
              child: Text(
                l10n.noConversationsYet,
                textAlign: TextAlign.center,
                style: AppTypography.bodyMediumStyle.copyWith(
                  color: context.conduitTheme.textSecondary,
                ),
              ),
            ),
          ),
        ),
      SliverToBoxAdapter(
        child: SizedBox(
          height: _inputHeight > 0 ? _inputHeight : (Spacing.xxxl * 2),
        ),
      ),
    ];

    final scrollView = ConduitRefreshIndicator(
      onRefresh: _refreshFolderContents,
      child: CustomScrollView(
        key: ValueKey<String>('folder-page-${widget.folderId}'),
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: slivers,
      ),
    );

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _dismissComposerFocus,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _dismissComposerFocus,
              child: scrollView,
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
            left: 0,
            right: 0,
            bottom: 0,
            child: _buildComposerOverlay(context, folder),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageState(BuildContext context, String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.lg),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: AppTypography.bodyMediumStyle.copyWith(
            color: context.conduitTheme.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _FolderPageHeader extends StatelessWidget {
  const _FolderPageHeader({required this.folder});

  final Folder folder;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    return Container(
      key: const ValueKey<String>('folder-page-header'),
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.md,
      ),
      decoration: BoxDecoration(
        color: theme.surfaceContainer,
        borderRadius: BorderRadius.circular(AppBorderRadius.card),
        border: Border.all(color: theme.cardBorder, width: BorderWidth.thin),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: theme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(AppBorderRadius.medium),
            ),
            child: FolderIconGlyph(
              iconAlias: folder.meta?['icon']?.toString(),
              size: 22,
              color: theme.textPrimary,
            ),
          ),
          const SizedBox(width: Spacing.md),
          Expanded(
            child: MiddleEllipsisText(
              folder.name,
              style: AppTypography.headlineSmallStyle.copyWith(
                color: theme.textPrimary,
                fontWeight: FontWeight.w700,
              ),
              semanticsLabel: folder.name,
            ),
          ),
        ],
      ),
    );
  }
}

String _extractFolderSystemPrompt(Folder folder) {
  final value = folder.data?['system_prompt'];
  return value is String ? value : '';
}

InputDecoration _buildFolderFieldDecoration({
  required BuildContext context,
  required String label,
  String? hint,
}) {
  final theme = context.conduitTheme;
  return InputDecoration(
    labelText: label,
    hintText: hint,
    filled: true,
    fillColor: theme.cardBackground.withValues(alpha: 0.72),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppBorderRadius.medium),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppBorderRadius.medium),
      borderSide: BorderSide(
        color: theme.cardBorder.withValues(alpha: 0.6),
        width: BorderWidth.thin,
      ),
    ),
  );
}

class _FolderSheetFrame extends StatelessWidget {
  const _FolderSheetFrame({
    required this.title,
    required this.description,
    required this.isBusy,
    required this.onClose,
    required this.child,
  });

  final String title;
  final String description;
  final bool isBusy;
  final VoidCallback onClose;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final titleStyle = AppTypography.headlineSmallStyle.copyWith(
      color: theme.sidebarForeground,
      fontWeight: FontWeight.w700,
    );
    final subtitleStyle = AppTypography.bodySmallStyle.copyWith(
      color: theme.sidebarForeground.withValues(alpha: 0.72),
    );

    return AnimatedPadding(
      duration: AnimationDuration.microInteraction,
      curve: AnimationCurves.microInteraction,
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        decoration: BoxDecoration(
          color: theme.sidebarBackground,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppBorderRadius.modal),
          ),
          boxShadow: ConduitShadows.modal(context),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              Spacing.lg,
              Spacing.xs,
              Spacing.lg,
              Spacing.lg,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(child: SheetHandle()),
                const SizedBox(height: Spacing.sm),
                Row(
                  children: [
                    Expanded(child: Text(title, style: titleStyle)),
                    IconButton(
                      onPressed: isBusy ? null : onClose,
                      icon: Icon(
                        Platform.isIOS ? CupertinoIcons.xmark : Icons.close,
                        color: theme.iconPrimary,
                      ),
                    ),
                  ],
                ),
                Text(description, style: subtitleStyle),
                const SizedBox(height: Spacing.lg),
                child,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FolderEditSheet extends ConsumerStatefulWidget {
  const _FolderEditSheet({required this.folder});

  final Folder folder;

  @override
  ConsumerState<_FolderEditSheet> createState() => _FolderEditSheetState();
}

class _FolderEditSheetState extends ConsumerState<_FolderEditSheet> {
  late final TextEditingController _nameController;
  late Folder _folder;
  String? _selectedIconAlias;
  bool _isLoadingDetails = false;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _folder = widget.folder;
    _nameController = TextEditingController(text: _folder.name);
    _selectedIconAlias = normalizeFolderIconAlias(
      _folder.meta?['icon']?.toString(),
    );
    _loadLatestFolder();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _loadLatestFolder() async {
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      return;
    }

    setState(() => _isLoadingDetails = true);
    try {
      final detail = await api.getFolderById(widget.folder.id);
      if (!mounted || detail == null) {
        return;
      }

      final latestFolder = Folder.fromJson(detail);
      _folder = latestFolder;
      _nameController.text = latestFolder.name;
      _nameController.selection = TextSelection.collapsed(
        offset: _nameController.text.length,
      );
      _selectedIconAlias = normalizeFolderIconAlias(
        latestFolder.meta?['icon']?.toString(),
      );
    } catch (_) {
      if (!mounted) {
        return;
      }
      _showSnackBar(AppLocalizations.of(context)!.unableToLoadFolder);
    } finally {
      if (mounted) {
        setState(() => _isLoadingDetails = false);
      }
    }
  }

  Future<void> _save() async {
    if (_isSaving) {
      return;
    }

    final l10n = AppLocalizations.of(context)!;
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      _showSnackBar(l10n.errorMessage);
      return;
    }

    final trimmedName = _nameController.text.trim();
    if (trimmedName.isEmpty) {
      _showSnackBar(l10n.validationMissingRequired);
      return;
    }

    setState(() => _isSaving = true);
    final messenger = ScaffoldMessenger.maybeOf(context);

    final nextMeta = Map<String, dynamic>.from(_folder.meta ?? const {});
    nextMeta['icon'] = _selectedIconAlias ?? '';

    try {
      await api.updateFolder(_folder.id, name: trimmedName, meta: nextMeta);

      final detail = await api.getFolderById(_folder.id);
      final updatedFolder = detail == null
          ? _folder.copyWith(
              name: trimmedName,
              meta: nextMeta,
              updatedAt: DateTime.now(),
            )
          : Folder.fromJson(detail);

      if (!mounted) {
        return;
      }

      Navigator.of(context).pop(updatedFolder);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (messenger?.mounted ?? false) {
          messenger!.showSnackBar(SnackBar(content: Text(l10n.saved)));
        }
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _isSaving = false);
      _showSnackBar(l10n.errorMessage);
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final titleStyle = AppTypography.headlineSmallStyle.copyWith(
      color: theme.sidebarForeground,
      fontWeight: FontWeight.w700,
    );
    return _FolderSheetFrame(
      title: 'Edit Folder',
      description: 'Update the folder name and icon on the server.',
      isBusy: _isSaving,
      onClose: () => Navigator.of(context).pop(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 56,
                height: 56,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: theme.surfaceContainer,
                  borderRadius: BorderRadius.circular(AppBorderRadius.medium),
                  border: Border.all(
                    color: theme.cardBorder.withValues(alpha: 0.5),
                    width: BorderWidth.thin,
                  ),
                ),
                child: FolderIconGlyph(
                  iconAlias: _selectedIconAlias,
                  size: 28,
                  color: theme.textPrimary,
                ),
              ),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: TextField(
                  key: const ValueKey<String>('folder-edit-name-field'),
                  controller: _nameController,
                  enabled: !_isSaving,
                  textInputAction: TextInputAction.next,
                  decoration: _buildFolderFieldDecoration(
                    context: context,
                    label: l10n.folderName,
                    hint: l10n.folderName,
                  ),
                ),
              ),
            ],
          ),
          if (_isLoadingDetails) ...[
            const SizedBox(height: Spacing.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: ConduitLoading.inline(context: context),
            ),
          ],
          const SizedBox(height: Spacing.lg),
          Text('Icon', style: titleStyle.copyWith(fontSize: 16)),
          const SizedBox(height: Spacing.sm),
          Wrap(
            spacing: Spacing.xs,
            runSpacing: Spacing.xs,
            children: [
              ChoiceChip(
                label: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FolderIconGlyph(
                      iconAlias: null,
                      size: 18,
                      color: theme.textPrimary,
                    ),
                    const SizedBox(width: Spacing.xs),
                    const Text('Default'),
                  ],
                ),
                selected: _selectedIconAlias == null,
                onSelected: _isSaving
                    ? null
                    : (_) => setState(() => _selectedIconAlias = null),
              ),
              for (final option in folderIconOptions)
                ChoiceChip(
                  label: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FolderIconGlyph(
                        iconAlias: option.alias,
                        size: 18,
                        color: theme.textPrimary,
                      ),
                      const SizedBox(width: Spacing.xs),
                      Text(option.semanticLabel),
                    ],
                  ),
                  selected: _selectedIconAlias == option.alias,
                  onSelected: _isSaving
                      ? null
                      : (_) =>
                            setState(() => _selectedIconAlias = option.alias),
                ),
            ],
          ),
          const SizedBox(height: Spacing.lg),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
                child: Text(l10n.cancel),
              ),
              const SizedBox(width: Spacing.sm),
              FilledButton(
                onPressed: _isSaving ? null : _save,
                child: _isSaving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(l10n.save),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FolderSystemPromptSheet extends ConsumerStatefulWidget {
  const _FolderSystemPromptSheet({required this.folder});

  final Folder folder;

  @override
  ConsumerState<_FolderSystemPromptSheet> createState() =>
      _FolderSystemPromptSheetState();
}

class _FolderSystemPromptSheetState
    extends ConsumerState<_FolderSystemPromptSheet> {
  late final TextEditingController _systemPromptController;
  late Folder _folder;
  bool _isLoadingDetails = false;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _folder = widget.folder;
    _systemPromptController = TextEditingController(
      text: _extractFolderSystemPrompt(_folder),
    );
    _loadLatestFolder();
  }

  @override
  void dispose() {
    _systemPromptController.dispose();
    super.dispose();
  }

  Future<void> _loadLatestFolder() async {
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      return;
    }

    setState(() => _isLoadingDetails = true);
    try {
      final detail = await api.getFolderById(widget.folder.id);
      if (!mounted || detail == null) {
        return;
      }

      final latestFolder = Folder.fromJson(detail);
      _folder = latestFolder;
      _systemPromptController.text = _extractFolderSystemPrompt(latestFolder);
      _systemPromptController.selection = TextSelection.collapsed(
        offset: _systemPromptController.text.length,
      );
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.unableToLoadFolder),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isLoadingDetails = false);
      }
    }
  }

  Future<void> _save() async {
    if (_isSaving) {
      return;
    }

    final l10n = AppLocalizations.of(context)!;
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(l10n.errorMessage)));
      return;
    }

    setState(() => _isSaving = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final nextData = Map<String, dynamic>.from(_folder.data ?? const {});
    nextData['system_prompt'] = _systemPromptController.text.trim();

    try {
      await api.updateFolder(_folder.id, data: nextData);

      final detail = await api.getFolderById(_folder.id);
      final updatedFolder = detail == null
          ? _folder.copyWith(data: nextData, updatedAt: DateTime.now())
          : Folder.fromJson(detail);

      if (!mounted) {
        return;
      }

      Navigator.of(context).pop(updatedFolder);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (messenger?.mounted ?? false) {
          messenger!.showSnackBar(SnackBar(content: Text(l10n.saved)));
        }
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _isSaving = false);
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(l10n.errorMessage)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return _FolderSheetFrame(
      title: l10n.folderSystemPromptTitle(_folder.name),
      description: l10n.folderSystemPromptEditorDescription,
      isBusy: _isSaving,
      onClose: () => Navigator.of(context).pop(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_isLoadingDetails) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: ConduitLoading.inline(context: context),
            ),
            const SizedBox(height: Spacing.md),
          ],
          TextField(
            key: const ValueKey<String>('folder-system-prompt-field'),
            controller: _systemPromptController,
            readOnly: _isSaving,
            minLines: 6,
            maxLines: 10,
            textInputAction: TextInputAction.newline,
            decoration: _buildFolderFieldDecoration(
              context: context,
              label: 'System Prompt',
              hint: l10n.enterSystemPrompt,
            ),
          ),
          const SizedBox(height: Spacing.lg),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
                child: Text(l10n.cancel),
              ),
              const SizedBox(width: Spacing.sm),
              FilledButton(
                onPressed: _isSaving ? null : _save,
                child: _isSaving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(l10n.save),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label, this.count});

  final String label;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    return Row(
      children: [
        Text(
          label,
          style: AppTypography.labelStyle.copyWith(color: theme.textSecondary),
        ),
        if (count != null) ...[
          const SizedBox(width: Spacing.xs),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: context.sidebarTheme.accent.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(AppBorderRadius.xs),
              border: Border.all(
                color: context.sidebarTheme.border.withValues(alpha: 0.35),
                width: BorderWidth.micro,
              ),
            ),
            child: Text(
              '$count',
              style: AppTypography.sidebarBadgeStyle.copyWith(
                color: context.sidebarTheme.foreground.withValues(alpha: 0.8),
                decoration: TextDecoration.none,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _FolderToolbarPopupButton extends StatelessWidget {
  const _FolderToolbarPopupButton({
    required this.tintColor,
    required this.onSelected,
  });

  final Color tintColor;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: const ValueKey<String>('folder-page-overflow-button'),
      child: AdaptivePopupMenuButton.icon<String>(
        icon: _buttonIcon(),
        tint: tintColor,
        size: TouchTarget.minimum,
        buttonStyle: PopupButtonStyle.glass,
        items: [
          AdaptivePopupMenuItem<String>(
            value: 'edit-folder',
            label: 'Edit Folder',
            icon: _itemIcon(
              iosSymbol: 'pencil',
              materialIcon: Icons.edit_outlined,
            ),
          ),
          AdaptivePopupMenuItem<String>(
            value: 'system-prompt',
            label: 'System Prompt',
            icon: _itemIcon(
              iosSymbol: 'text.bubble',
              materialIcon: Icons.notes_outlined,
            ),
          ),
        ],
        onSelected: (_, entry) {
          final value = entry.value;
          if (value == null) {
            return;
          }

          onSelected(value);
        },
      ),
    );
  }

  dynamic _buttonIcon() {
    return Platform.isIOS ? 'ellipsis' : Icons.more_vert_rounded;
  }

  dynamic _itemIcon({
    required String iosSymbol,
    required IconData materialIcon,
  }) {
    return Platform.isIOS ? iosSymbol : materialIcon;
  }
}

class _FolderListTile extends StatelessWidget {
  const _FolderListTile({
    super.key,
    required this.name,
    required this.iconAlias,
    required this.onTap,
  });

  final String name;
  final String? iconAlias;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final borderRadius = BorderRadius.circular(AppBorderRadius.card);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: Spacing.xxs),
      decoration: BoxDecoration(
        color: theme.surfaceContainer,
        borderRadius: borderRadius,
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: TouchTarget.listItem),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.md,
              vertical: Spacing.sm,
            ),
            child: Row(
              children: [
                FolderIconGlyph(
                  iconAlias: iconAlias,
                  size: IconSize.listItem,
                  color: theme.iconPrimary,
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.sidebarTitleStyle.copyWith(
                      color: theme.textPrimary,
                    ),
                    semanticsLabel: name,
                  ),
                ),
                Icon(
                  Platform.isIOS
                      ? CupertinoIcons.chevron_right
                      : Icons.chevron_right_rounded,
                  color: theme.iconSecondary,
                  size: IconSize.listItem,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
