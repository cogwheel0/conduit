import 'package:flutter/material.dart';
import '../../../shared/theme/theme_extensions.dart';
import 'enhanced_image_attachment.dart';
import 'enhanced_attachment.dart';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:io' show Platform;
import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/services.dart';
import '../../../core/providers/app_providers.dart';
import '../providers/chat_providers.dart';
import '../../../shared/services/tasks/task_queue.dart';
import '../../../shared/utils/conversation_context_menu.dart';
import '../../tools/providers/tools_providers.dart';

// Pre-compiled regex for extracting file IDs from URLs (performance optimization)
// Handles both /api/v1/files/{id} and /api/v1/files/{id}/content formats
final _fileIdPattern = RegExp(r'/api/v1/files/([^/]+)(?:/content)?$');

class UserMessageBubble extends ConsumerStatefulWidget {
  final dynamic message;
  final bool isUser;
  final bool isStreaming;
  final String? modelName;
  final VoidCallback? onCopy;
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
  final GlobalKey _bubbleKey = GlobalKey();

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

  Widget _buildUserFileImages() {
    if (widget.message.files == null || widget.message.files!.isEmpty) {
      return const SizedBox.shrink();
    }

    final allFiles = widget.message.files!;

    // Separate images and non-image files
    final imageFiles = allFiles
        .where(
          (file) =>
              file is Map && file['type'] == 'image' && file['url'] != null,
        )
        .toList();
    final nonImageFiles = allFiles
        .where(
          (file) =>
              file is Map && file['type'] != 'image' && file['url'] != null,
        )
        .toList();

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

  Widget _buildFileImageLayout(List<dynamic> imageFiles, int imageCount) {
    if (imageCount == 1) {
      final file = imageFiles[0];
      final String imageUrl = file['url'] as String;
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
                final String imageUrl = file['url'] as String;
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
                  final String imageUrl = file['url'] as String;
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
        onBeforeClose: () => HapticFeedback.selectionClick(),
        onSelected: () async => _startInlineEdit(),
      ),
      ConduitContextMenuAction(
        cupertinoIcon: CupertinoIcons.doc_on_clipboard,
        materialIcon: Icons.content_copy,
        label: l10n.copy,
        onBeforeClose: () => HapticFeedback.selectionClick(),
        onSelected: () async {
          if (widget.onCopy != null) {
            widget.onCopy!();
          }
        },
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return _buildUserMessage();
  }

  Widget _buildUserMessage() {
    final hasImages =
        widget.message.attachmentIds != null &&
        widget.message.attachmentIds!.isNotEmpty;
    final hasText = widget.message.content.isNotEmpty;
    final hasFilesFromArray =
        widget.message.files != null &&
        (widget.message.files as List).any((f) => f is Map && f['url'] != null);
    // Prefer input/textPrimary colors during inline editing to avoid low contrast
    final inlineEditTextColor = context.conduitTheme.textPrimary;
    final inlineEditFill = context.conduitTheme.surfaceContainer.withValues(
      alpha: 0.92,
    );
    // Use rounded rectangle for multiline, pill for single-line (like chat input)
    // Consider multiline if text exceeds ~50 chars or contains newlines
    // Check length first (O(1)) to short-circuit before scanning for newlines
    final content = widget.message.content;
    final isMultiline = content.length > 50 || content.contains('\n');
    final bubbleRadius = isMultiline ? AppBorderRadius.xl : AppBorderRadius.pill;

    return ConduitContextMenu(
      actions: _buildMessageActions(context),
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(
          bottom: Spacing.md,
          left: Spacing.xxxl,
          right: Spacing.xs,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Display images outside and above the text bubble (iMessage style)
            // Prioritize files array over attachmentIds to avoid duplication
            if (hasFilesFromArray) ...[
              _buildUserFileImages(),
            ] else if (hasImages) ...[
              _buildUserAttachmentImages(),
            ],

            // Display text bubble if there's text content
            if (hasText) const SizedBox(height: Spacing.xs),
            if (hasText)
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Flexible(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(context).size.width * 0.82,
                      ),
                      child: Container(
                        key: _bubbleKey,
                        padding: const EdgeInsets.symmetric(
                          horizontal: Spacing.chatBubblePadding,
                          vertical: Spacing.sm,
                        ),
                        decoration: BoxDecoration(
                          color: context.conduitTheme.chatBubbleUser,
                          borderRadius: BorderRadius.circular(bubbleRadius),
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
                                      color: context
                                          .conduitTheme
                                          .inputBorderFocused
                                          .withValues(alpha: 0.5),
                                      width: BorderWidth.thin,
                                    ),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: Spacing.xs,
                                      vertical: Spacing.xxs,
                                    ),
                                    child: Platform.isIOS
                                        ? CupertinoTextField(
                                            controller: _editController,
                                            maxLines: null,
                                            padding: EdgeInsets.zero,
                                            autofillHints: const <String>[],
                                            style: AppTypography
                                                .chatMessageStyle
                                                .copyWith(
                                                  color: inlineEditTextColor,
                                                ),
                                            decoration: const BoxDecoration(),
                                            cursorColor: context
                                                .conduitTheme
                                                .buttonPrimary,
                                            onSubmitted: (_) =>
                                                _saveInlineEdit(),
                                          )
                                        : TextField(
                                            controller: _editController,
                                            maxLines: null,
                                            autofillHints: const <String>[],
                                            style: AppTypography
                                                .chatMessageStyle
                                                .copyWith(
                                                  color: inlineEditTextColor,
                                                ),
                                            decoration: const InputDecoration(
                                              isCollapsed: true,
                                              border: InputBorder.none,
                                              contentPadding: EdgeInsets.zero,
                                            ),
                                            cursorColor: context
                                                .conduitTheme
                                                .buttonPrimary,
                                            onSubmitted: (_) =>
                                                _saveInlineEdit(),
                                          ),
                                  ),
                                ),
                              )
                            : Text(
                                widget.message.content,
                                style: AppTypography.chatMessageStyle.copyWith(
                                  color:
                                      context.conduitTheme.chatBubbleUserText,
                                ),
                                softWrap: true,
                                textAlign: TextAlign.left,
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
                ],
              ),

            // Edit action buttons - show Save/Cancel when editing
            if (_isEditing) ...[
              const SizedBox(height: Spacing.sm),
              _buildEditActionButtons(),
            ],
          ],
        ),
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
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: _cancelInlineEdit,
            borderRadius: BorderRadius.circular(AppBorderRadius.small),
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
        ),
        const SizedBox(width: Spacing.sm),
        // Save button
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: _saveInlineEdit,
            borderRadius: BorderRadius.circular(AppBorderRadius.small),
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
      // Remove messages after this one
      final messages = ref.read(chatMessagesProvider);
      final idx = messages.indexOf(widget.message);
      if (idx >= 0) {
        final keep = messages.take(idx).toList(growable: false);
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
