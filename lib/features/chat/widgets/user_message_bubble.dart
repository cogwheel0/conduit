import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:conduit/core/services/haptic_service.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/services/navigation_service.dart';
import '../../../shared/services/tasks/task_queue.dart';
import '../../../shared/theme/conduit_input_styles.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/conversation_context_menu.dart';
import '../../tools/providers/tools_providers.dart';
import '../providers/chat_providers.dart';
import '../utils/file_utils.dart';
import '../utils/message_targeting.dart';
import 'enhanced_attachment.dart';
import 'enhanced_image_attachment.dart';

// Pre-compiled regex for extracting file IDs from URLs (performance optimization)
// Handles both /api/v1/files/{id} and /api/v1/files/{id}/content formats
final _fileIdPattern = RegExp(r'/api/v1/files/([^/]+)(?:/content)?$');

class _UserFilePartitions {
  const _UserFilePartitions({
    required this.imageFiles,
    required this.noteFiles,
    required this.nonImageFiles,
  });

  final List<dynamic> imageFiles;
  final List<dynamic> noteFiles;
  final List<dynamic> nonImageFiles;

  bool get hasRenderableFiles =>
      imageFiles.isNotEmpty || noteFiles.isNotEmpty || nonImageFiles.isNotEmpty;
}

class UserMessageBubble extends ConsumerStatefulWidget {
  final dynamic message;
  final bool isUser;
  final bool isStreaming;
  final String? modelName;
  final VoidCallback? onCopy;
  final VoidCallback onDelete;
  final VoidCallback? onEdit;
  final VoidCallback? onRegenerate;
  final VoidCallback? onLike;
  final VoidCallback? onDislike;

  const UserMessageBubble({
    super.key,
    required this.message,
    required this.isUser,
    this.isStreaming = false,
    this.modelName,
    this.onCopy,
    required this.onDelete,
    this.onEdit,
    this.onRegenerate,
    this.onLike,
    this.onDislike,
  });

  @override
  ConsumerState<UserMessageBubble> createState() => _UserMessageBubbleState();
}

class _UserMessageBubbleState extends ConsumerState<UserMessageBubble> {
  bool _isEditing = false;
  late final TextEditingController _editController;
  final FocusNode _editFocusNode = FocusNode();
  List<dynamic>? _lastPartitionedFiles;
  _UserFilePartitions? _lastFilePartitions;

  @override
  void initState() {
    super.initState();
    _editController = TextEditingController(
      text: widget.message?.content ?? '',
    );
  }

  Widget _buildUserAttachmentImages() {
    if (widget.message.attachmentIds == null ||
        widget.message.attachmentIds!.isEmpty) {
      return const SizedBox.shrink();
    }

    final imageCount = widget.message.attachmentIds!.length;

    // iMessage-style image layout with AnimatedSwitcher for smooth transitions
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      switchInCurve: Curves.easeInOut,
      child: _buildImageLayout(imageCount),
    );
  }

  Widget _buildUserFileImages(_UserFilePartitions partitions) {
    final imageFiles = partitions.imageFiles;
    final noteFiles = partitions.noteFiles;
    final nonImageFiles = partitions.nonImageFiles;

    final widgets = <Widget>[];

    // Add images first
    if (imageFiles.isNotEmpty) {
      widgets.add(
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          switchInCurve: Curves.easeInOut,
          child: _buildFileImageLayout(imageFiles, imageFiles.length),
        ),
      );
    }

    // Add non-image files
    if (noteFiles.isNotEmpty) {
      if (widgets.isNotEmpty) {
        widgets.add(const SizedBox(height: Spacing.xs));
      }
      widgets.add(_buildUserNoteFiles(noteFiles));
    }

    if (nonImageFiles.isNotEmpty) {
      if (widgets.isNotEmpty) {
        widgets.add(const SizedBox(height: Spacing.xs));
      }
      widgets.add(_buildUserNonImageFiles(nonImageFiles));
    }

    if (widgets.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: widgets,
    );
  }

  bool _isRenderableNoteAttachment(dynamic file) {
    if (file is! Map) {
      return false;
    }
    return file['type'] == 'note';
  }

  _UserFilePartitions? _currentFilePartitions() {
    final files = widget.message.files;
    if (files is! List || files.isEmpty) {
      return null;
    }
    return _partitionUserFiles(files);
  }

  _UserFilePartitions _partitionUserFiles(List<dynamic> files) {
    if (identical(_lastPartitionedFiles, files) &&
        _lastFilePartitions != null) {
      return _lastFilePartitions!;
    }

    final imageFiles = <dynamic>[];
    final noteFiles = <dynamic>[];
    final nonImageFiles = <dynamic>[];

    for (final file in files) {
      if (file is! Map) {
        continue;
      }
      if (_isRenderableNoteAttachment(file)) {
        noteFiles.add(file);
        continue;
      }

      final fileUrl = getFileUrl(file);
      if (fileUrl == null) {
        continue;
      }
      if (isImageFile(file)) {
        imageFiles.add(file);
      } else {
        nonImageFiles.add(file);
      }
    }

    final partitions = _UserFilePartitions(
      imageFiles: imageFiles,
      noteFiles: noteFiles,
      nonImageFiles: nonImageFiles,
    );
    _lastPartitionedFiles = files;
    _lastFilePartitions = partitions;
    return partitions;
  }

  Widget _buildFileImageLayout(List<dynamic> imageFiles, int imageCount) {
    if (imageCount == 1) {
      final file = imageFiles[0];
      final imageUrl = getFileUrl(file);
      if (imageUrl == null) return const SizedBox.shrink();
      return Row(
        key: ValueKey('user_file_single_$imageUrl'),
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(
                AppBorderRadius.messageBubble,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(
                AppBorderRadius.messageBubble,
              ),
              child: EnhancedImageAttachment(
                attachmentId: imageUrl,
                isUserMessage: true,
                isMarkdownFormat: false,
                constraints: const BoxConstraints(
                  maxWidth: 280,
                  maxHeight: 350,
                ),
                disableAnimation: widget.isStreaming,
                httpHeaders: _headersForFile(file),
              ),
            ),
          ),
        ],
      );
    } else if (imageCount == 2) {
      return Row(
        key: ValueKey(
          'user_file_double_${imageFiles.map((e) => e['url']).join('_')}',
        ),
        mainAxisAlignment: MainAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: imageFiles.asMap().entries.map((entry) {
                final index = entry.key;
                final file = entry.value;
                final imageUrl = getFileUrl(file);
                if (imageUrl == null) return const SizedBox.shrink();
                return Padding(
                  padding: EdgeInsets.only(left: index == 0 ? 0 : Spacing.xs),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(
                        AppBorderRadius.messageBubble,
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(
                        AppBorderRadius.messageBubble,
                      ),
                      child: EnhancedImageAttachment(
                        key: ValueKey('user_file_attachment_$imageUrl'),
                        attachmentId: imageUrl,
                        isUserMessage: true,
                        isMarkdownFormat: false,
                        constraints: const BoxConstraints(
                          maxWidth: 135,
                          maxHeight: 180,
                        ),
                        disableAnimation: widget.isStreaming,
                        httpHeaders: _headersForFile(file),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      );
    } else {
      return Row(
        key: ValueKey(
          'user_file_grid_${imageFiles.map((e) => e['url']).join('_')}',
        ),
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Flexible(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 280),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: Spacing.xs,
                runSpacing: Spacing.xs,
                children: imageFiles.map((file) {
                  final imageUrl = getFileUrl(file);
                  if (imageUrl == null) return const SizedBox.shrink();
                  return Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(AppBorderRadius.md),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(AppBorderRadius.md),
                      child: EnhancedImageAttachment(
                        key: ValueKey('user_file_grid_attachment_$imageUrl'),
                        attachmentId: imageUrl,
                        isUserMessage: true,
                        isMarkdownFormat: false,
                        constraints: BoxConstraints(
                          maxWidth: imageCount == 3 ? 135 : 90,
                          maxHeight: imageCount == 3 ? 135 : 90,
                        ),
                        disableAnimation: widget.isStreaming,
                        httpHeaders: _headersForFile(file),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
        ],
      );
    }
  }

  Widget _buildImageLayout(int imageCount) {
    if (imageCount == 1) {
      // Single image - larger display
      return Row(
        key: ValueKey('user_single_${widget.message.attachmentIds![0]}'),
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(
                AppBorderRadius.messageBubble,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(
                AppBorderRadius.messageBubble,
              ),
              child: EnhancedAttachment(
                attachmentId: widget.message.attachmentIds![0],
                isUserMessage: true,
                constraints: const BoxConstraints(
                  maxWidth: 280,
                  maxHeight: 350,
                ),
                disableAnimation: widget.isStreaming,
              ),
            ),
          ),
        ],
      );
    } else if (imageCount == 2) {
      // Two images side by side
      return Row(
        key: ValueKey('user_double_${widget.message.attachmentIds!.join('_')}'),
        mainAxisAlignment: MainAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: widget.message.attachmentIds!.asMap().entries.map((
                entry,
              ) {
                final index = entry.key;
                final attachmentId = entry.value;
                return Padding(
                  padding: EdgeInsets.only(left: index == 0 ? 0 : Spacing.xs),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(
                        AppBorderRadius.messageBubble,
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(
                        AppBorderRadius.messageBubble,
                      ),
                      child: EnhancedAttachment(
                        key: ValueKey('user_attachment_$attachmentId'),
                        attachmentId: attachmentId,
                        isUserMessage: true,
                        constraints: const BoxConstraints(
                          maxWidth: 135,
                          maxHeight: 180,
                        ),
                        disableAnimation: widget.isStreaming,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      );
    } else {
      // Grid layout for 3+ images
      return Row(
        key: ValueKey('user_grid_${widget.message.attachmentIds!.join('_')}'),
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Flexible(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 280),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: Spacing.xs,
                runSpacing: Spacing.xs,
                children: widget.message.attachmentIds!.map((attachmentId) {
                  return Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(AppBorderRadius.md),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(AppBorderRadius.md),
                      child: EnhancedAttachment(
                        key: ValueKey('user_grid_attachment_$attachmentId'),
                        attachmentId: attachmentId,
                        isUserMessage: true,
                        constraints: BoxConstraints(
                          maxWidth: imageCount == 3 ? 135 : 90,
                          maxHeight: imageCount == 3 ? 135 : 90,
                        ),
                        disableAnimation: widget.isStreaming,
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
        ],
      );
    }
  }

  Widget _buildUserNonImageFiles(List<dynamic> nonImageFiles) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Flexible(
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: Spacing.xs,
            runSpacing: Spacing.xs,
            children: nonImageFiles.map<Widget>((file) {
              final fileUrl = file['url'] as String?;

              if (fileUrl == null) return const SizedBox.shrink();

              // Extract file ID from URL - handle both formats:
              // /api/v1/files/{id} and /api/v1/files/{id}/content
              String attachmentId = fileUrl;
              if (fileUrl.contains('/api/v1/files/')) {
                final fileIdMatch = _fileIdPattern.firstMatch(fileUrl);
                if (fileIdMatch != null) {
                  attachmentId = fileIdMatch.group(1)!;
                }
              }

              return EnhancedAttachment(
                key: ValueKey('user_file_attachment_$attachmentId'),
                attachmentId: attachmentId,
                isMarkdownFormat: false,
                isUserMessage: true,
                constraints: const BoxConstraints(maxWidth: 280, maxHeight: 80),
                disableAnimation: widget.isStreaming,
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildUserNoteFiles(List<dynamic> noteFiles) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Flexible(
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: Spacing.xs,
            runSpacing: Spacing.xs,
            children: noteFiles.map<Widget>(_buildNoteAttachmentCard).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildNoteAttachmentCard(dynamic file) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final noteId = file is Map ? file['id']?.toString() : null;
    final rawTitle = file is Map
        ? (file['name'] ?? file['title'])?.toString().trim() ?? ''
        : '';
    final title = rawTitle.isEmpty ? l10n.untitled : rawTitle;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 280),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: noteId == null || noteId.isEmpty
            ? null
            : () {
                ConduitHaptics.selectionClick();
                NavigationService.router.go('/notes/$noteId');
              },
        child: Container(
          padding: const EdgeInsets.all(Spacing.md),
          decoration: BoxDecoration(
            color: theme.cardBackground,
            borderRadius: BorderRadius.circular(AppBorderRadius.md),
            border: Border.all(
              color: theme.textPrimary.withValues(alpha: 0.12),
              width: BorderWidth.regular,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: theme.buttonPrimary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(AppBorderRadius.small),
                ),
                alignment: Alignment.center,
                child: Icon(
                  Platform.isIOS
                      ? CupertinoIcons.doc_text
                      : Icons.sticky_note_2_outlined,
                  color: theme.buttonPrimary,
                  size: IconSize.medium,
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Flexible(
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.bodySmallStyle.copyWith(
                    color: theme.textPrimary,
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                  ),
                ),
              ),
            ],
          ),
        ),
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

  // Assistant-only helpers removed; this widget renders only user bubbles.

  @override
  void dispose() {
    _editController.dispose();
    _editFocusNode.dispose();
    super.dispose();
  }

  List<ConduitContextMenuAction> _buildMessageActions(BuildContext context) {
    // Don't show menu while editing - return empty list
    if (_isEditing) return [];

    final l10n = AppLocalizations.of(context)!;

    return [
      ConduitContextMenuAction(
        cupertinoIcon: CupertinoIcons.pencil,
        materialIcon: Icons.edit_outlined,
        label: l10n.edit,
        onBeforeClose: () => ConduitHaptics.selectionClick(),
        onSelected: () async => _startInlineEdit(),
      ),
      ConduitContextMenuAction(
        cupertinoIcon: CupertinoIcons.doc_on_clipboard,
        materialIcon: Icons.content_copy,
        label: l10n.copy,
        onBeforeClose: () => ConduitHaptics.selectionClick(),
        onSelected: () async {
          if (widget.onCopy != null) {
            widget.onCopy!();
          }
        },
      ),
      ConduitContextMenuAction(
        cupertinoIcon: CupertinoIcons.delete,
        materialIcon: Icons.delete_outline,
        label: l10n.delete,
        destructive: true,
        onBeforeClose: () => ConduitHaptics.mediumImpact(),
        onSelected: () async {
          widget.onDelete();
        },
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return _buildUserMessage();
  }

  Widget _buildUserMessage() {
    final theme = context.conduitTheme;
    final hasImages =
        widget.message.attachmentIds != null &&
        widget.message.attachmentIds!.isNotEmpty;
    final hasText = widget.message.content.isNotEmpty;
    final filePartitions = _currentFilePartitions();
    final hasFilesFromArray = filePartitions?.hasRenderableFiles ?? false;
    // Prefer input/textPrimary colors during inline editing to avoid low contrast
    final inlineEditTextColor = theme.textPrimary;
    final inlineEditFill = theme.surfaceContainer.withValues(alpha: 0.92);
    final bubbleMaxWidth = math.min(
      MediaQuery.sizeOf(context).width * 0.78,
      640.0,
    );
    final bubbleBorderColor = theme.chatBubbleUserText.withValues(
      alpha: theme.isDark ? 0.16 : 0.08,
    );
    const bubbleBorderRadius = BorderRadius.only(
      topLeft: Radius.circular(AppBorderRadius.chatBubble),
      topRight: Radius.circular(AppBorderRadius.chatBubble),
      bottomLeft: Radius.circular(AppBorderRadius.chatBubble),
      bottomRight: Radius.circular(AppBorderRadius.md),
    );
    final actions = _buildMessageActions(context);
    final attachmentContent = hasFilesFromArray
        ? _buildUserFileImages(filePartitions!)
        : hasImages
        ? _buildUserAttachmentImages()
        : null;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: Spacing.md, left: Spacing.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // Display images outside and above the text bubble (iMessage style)
          // Prioritize files array over attachmentIds to avoid duplication
          if (attachmentContent != null)
            ConduitContextMenu(actions: actions, child: attachmentContent),

          // Display text bubble if there's text content
          if (hasText) const SizedBox(height: Spacing.xs),
          if (hasText)
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Flexible(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: bubbleMaxWidth),
                    child: ConduitContextMenu(
                      actions: actions,
                      child: Container(
                        key: const Key('user-message-bubble-surface'),
                        padding: const EdgeInsets.all(Spacing.sm + Spacing.xs),
                        decoration: BoxDecoration(
                          color: theme.chatBubbleUser,
                          borderRadius: bubbleBorderRadius,
                          border: Border.all(
                            color: bubbleBorderColor,
                            width: BorderWidth.thin,
                          ),
                        ),
                        child: _isEditing
                            ? Focus(
                                focusNode: _editFocusNode,
                                autofocus: true,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: inlineEditFill,
                                    borderRadius: BorderRadius.circular(
                                      AppBorderRadius.small,
                                    ),
                                    border: Border.all(
                                      color: theme.inputBorderFocused
                                          .withValues(alpha: 0.5),
                                      width: BorderWidth.thin,
                                    ),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: Spacing.xs,
                                      vertical: Spacing.xxs,
                                    ),
                                    child: AdaptiveTextField(
                                      controller: _editController,
                                      maxLines: null,
                                      style: AppTypography.chatMessageStyle
                                          .copyWith(color: inlineEditTextColor),
                                      onSubmitted: (_) => _saveInlineEdit(),
                                      padding: EdgeInsets.zero,
                                      cupertinoDecoration:
                                          const BoxDecoration(),
                                      decoration: context.conduitInputStyles
                                          .borderless()
                                          .copyWith(
                                            isCollapsed: true,
                                            contentPadding: EdgeInsets.zero,
                                          ),
                                    ),
                                  ),
                                ),
                              )
                            : Text(
                                widget.message.content,
                                style: AppTypography.chatMessageStyle.copyWith(
                                  color: theme.chatBubbleUserText,
                                ),
                                softWrap: true,
                                textAlign: TextAlign.left,
                                textWidthBasis: TextWidthBasis.longestLine,
                                textHeightBehavior: const TextHeightBehavior(
                                  applyHeightToFirstAscent: false,
                                  applyHeightToLastDescent: false,
                                  leadingDistribution:
                                      TextLeadingDistribution.even,
                                ),
                              ),
                      ),
                    ),
                  ),
                ),
              ],
            ),

          // Edit action buttons - show Save/Cancel when editing
          if (_isEditing) ...[
            const SizedBox(height: Spacing.sm),
            _buildEditActionButtons(),
          ],
        ],
      ),
    );
  }

  Widget _buildEditActionButtons() {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;

    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        // Cancel button
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _cancelInlineEdit,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.md,
              vertical: Spacing.xs,
            ),
            decoration: BoxDecoration(
              color: theme.surfaceContainer,
              borderRadius: BorderRadius.circular(AppBorderRadius.small),
              border: Border.all(
                color: theme.cardBorder,
                width: BorderWidth.thin,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Platform.isIOS ? CupertinoIcons.xmark : Icons.close,
                  size: IconSize.xs,
                  color: theme.textSecondary,
                ),
                const SizedBox(width: Spacing.xs),
                Text(
                  l10n.cancel,
                  style: AppTypography.standard.copyWith(
                    color: theme.textSecondary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: Spacing.sm),
        // Save button
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _saveInlineEdit,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.md,
              vertical: Spacing.xs,
            ),
            decoration: BoxDecoration(
              color: theme.buttonPrimary,
              borderRadius: BorderRadius.circular(AppBorderRadius.small),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Platform.isIOS ? CupertinoIcons.check_mark : Icons.check,
                  size: IconSize.xs,
                  color: theme.buttonPrimaryText,
                ),
                const SizedBox(width: Spacing.xs),
                Text(
                  l10n.save,
                  style: AppTypography.standard.copyWith(
                    color: theme.buttonPrimaryText,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // Assistant-only message renderer removed.

  void _startInlineEdit() {
    if (_isEditing) return;
    setState(() {
      _isEditing = true;
      _editController.text = widget.message.content ?? '';
    });
    // Request focus after frame to show keyboard
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _editFocusNode.requestFocus();
      }
    });
  }

  void _cancelInlineEdit() {
    if (!_isEditing) return;
    setState(() {
      _isEditing = false;
      _editController.text = widget.message.content ?? '';
    });
    _editFocusNode.unfocus();
  }

  Future<void> _saveInlineEdit() async {
    final newText = _editController.text.trim();
    final oldText = (widget.message.content ?? '').toString();
    if (newText.isEmpty || newText == oldText) {
      _cancelInlineEdit();
      return;
    }

    try {
      final messageId = widget.message.id?.toString();
      if (messageId == null || messageId.isEmpty) {
        return;
      }

      final messages = ref.read(chatMessagesProvider);
      final idx = indexOfMessageId(messages, messageId);
      if (idx >= 0) {
        final keep = truncateMessagesAfterId(
          messages,
          messageId,
          includeTarget: false,
        );
        ref.read(chatMessagesProvider.notifier).setMessages(keep);

        // Enqueue edited text as a new message
        final activeConv = ref.read(activeConversationProvider);
        final List<String>? attachments =
            (widget.message.attachmentIds != null &&
                (widget.message.attachmentIds as List).isNotEmpty)
            ? List<String>.from(widget.message.attachmentIds as List)
            : null;
        final toolIds = ref.read(selectedToolIdsProvider);
        await ref
            .read(taskQueueProvider.notifier)
            .enqueueSendText(
              conversationId: activeConv?.id,
              text: newText,
              attachments: attachments,
              toolIds: toolIds.isNotEmpty ? toolIds : null,
            );
      }
    } catch (_) {
      // Swallow errors; upstream error handling will surface if needed
    } finally {
      if (mounted) {
        setState(() {
          _isEditing = false;
        });
        _editFocusNode.unfocus();
      }
    }
  }
}
