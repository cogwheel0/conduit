import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/core/services/haptic_service.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/services/navigation_service.dart';

import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/utils/debug_logger.dart';

import '../../../shared/theme/conduit_input_styles.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/conversation_context_menu.dart';
import '../../../shared/utils/file_type_utils.dart';
import '../../../shared/utils/locale_display_formatters.dart';

import 'package:conduit_core/features/chat/services/chat_message_actions.dart';
import 'package:conduit_core/features/chat/utils/file_utils.dart';

import 'chat_send_motion.dart';
import 'enhanced_attachment.dart';
import 'enhanced_image_attachment.dart';
import 'image_gallery_scope.dart';

// Pre-compiled regex for extracting file IDs from URLs (performance optimization)
// Handles both /api/v1/files/{id} and /api/v1/files/{id}/content formats
final _fileIdPattern = RegExp(r'/api/v1/files/([^/]+)(?:/content)?$');

class _UserFilePartitions {
  const _UserFilePartitions({
    required this.imageFiles,
    required this.noteFiles,
    required this.localReferenceFiles,
    required this.nonImageFiles,
  });

  final List<dynamic> imageFiles;
  final List<dynamic> noteFiles;
  final List<dynamic> localReferenceFiles;
  final List<dynamic> nonImageFiles;

  bool get hasRenderableFiles =>
      imageFiles.isNotEmpty ||
      noteFiles.isNotEmpty ||
      localReferenceFiles.isNotEmpty ||
      nonImageFiles.isNotEmpty;
}

class UserMessageBubble extends ConsumerStatefulWidget {
  final dynamic message;
  final bool isUser;
  final bool isStreaming;
  final String? modelName;
  final VoidCallback? onCopy;
  final VoidCallback onDelete;

  /// Another user's chat (shared folder): only copy is offered.
  final bool readOnly;
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
    this.readOnly = false,
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

    return _buildImageLayout(imageCount);
  }

  Widget _buildUserFileImages(_UserFilePartitions partitions) {
    final imageFiles = partitions.imageFiles;
    final noteFiles = partitions.noteFiles;
    final localReferenceFiles = partitions.localReferenceFiles;
    final nonImageFiles = partitions.nonImageFiles;

    final widgets = <Widget>[];

    // Add images first
    if (imageFiles.isNotEmpty) {
      widgets.add(
        ImageGalleryScope(
          items: _imageViewerItems(imageFiles),
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

    if (localReferenceFiles.isNotEmpty) {
      if (widgets.isNotEmpty) {
        widgets.add(const SizedBox(height: Spacing.xs));
      }
      widgets.add(_buildHermesLocalReferenceFiles(localReferenceFiles));
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

  bool _isHermesLocalFileReference(dynamic file) {
    return file is Map && file['source'] == 'hermes_local';
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
    final localReferenceFiles = <dynamic>[];
    final nonImageFiles = <dynamic>[];

    for (final file in files) {
      if (file is! Map) {
        continue;
      }
      if (_isRenderableNoteAttachment(file)) {
        noteFiles.add(file);
        continue;
      }
      // These descriptors intentionally contain metadata only. Classify them
      // before MIME/URL handling so even an image content type or malformed URL
      // can never reach a network-backed attachment widget.
      if (_isHermesLocalFileReference(file)) {
        localReferenceFiles.add(file);
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
      localReferenceFiles: localReferenceFiles,
      nonImageFiles: nonImageFiles,
    );
    _lastPartitionedFiles = files;
    _lastFilePartitions = partitions;
    return partitions;
  }

  /// Lets the full-screen viewer page through this message's images.
  List<ImageViewerItem> _imageViewerItems(List<dynamic> imageFiles) => [
    for (final file in imageFiles)
      if (getFileUrl(file) case final url?)
        ImageViewerItem(attachmentId: url, httpHeaders: _headersForFile(file)),
  ];

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
              child: RepaintBoundary(
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
                      child: RepaintBoundary(
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
                      child: RepaintBoundary(
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
    // [message] is dynamic for legacy hydration compatibility. Normalize the
    // ids before iterating so collection transforms produce List<Widget>
    // instead of a runtime List<dynamic>.
    final attachmentIds = List<String>.from(
      widget.message.attachmentIds as Iterable,
    );

    if (imageCount == 1) {
      // Single image - larger display
      return Row(
        key: ValueKey('user_single_${attachmentIds[0]}'),
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
                attachmentId: attachmentIds[0],
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
        key: ValueKey('user_double_${attachmentIds.join('_')}'),
        mainAxisAlignment: MainAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: attachmentIds.asMap().entries.map<Widget>((entry) {
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
        key: ValueKey('user_grid_${attachmentIds.join('_')}'),
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Flexible(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 280),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: Spacing.xs,
                runSpacing: Spacing.xs,
                children: attachmentIds.map<Widget>((attachmentId) {
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

  Widget _buildHermesLocalReferenceFiles(List<dynamic> files) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Flexible(
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: Spacing.xs,
            runSpacing: Spacing.xs,
            children: files
                .map<Widget>(_buildHermesLocalReferenceCard)
                .toList(growable: false),
          ),
        ),
      ],
    );
  }

  Widget _buildHermesLocalReferenceCard(dynamic file) {
    final theme = context.conduitTheme;
    final rawName = file is Map
        ? (file['name'] ?? file['filename'])?.toString().trim() ?? ''
        : '';
    final filename = rawName.isEmpty
        ? AppLocalizations.of(context)!.file
        : rawName;
    final rawSize = file is Map ? file['size'] : null;
    final size = rawSize is num ? rawSize.toInt() : int.tryParse('$rawSize');
    final sizeLabel = size == null
        ? ''
        : LocaleDisplayFormatters.bytes(context, size);
    final extension = FileTypeUtils.extensionFromName(filename);
    final id = file is Map ? file['id']?.toString() ?? '' : '';

    return Semantics(
      container: true,
      label: sizeLabel.isEmpty ? filename : '$filename, $sizeLabel',
      child: ExcludeSemantics(
        child: Container(
          key: ValueKey('hermes-local-file-$id'),
          constraints: const BoxConstraints(maxWidth: 280),
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.sm,
            vertical: Spacing.sm,
          ),
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
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: theme.buttonPrimary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(AppBorderRadius.small),
                ),
                alignment: Alignment.center,
                child: Icon(
                  FileTypeUtils.iconForExtension(extension),
                  color: theme.buttonPrimary,
                  size: IconSize.medium,
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      filename,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.labelStyle.copyWith(
                        color: theme.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (sizeLabel.isNotEmpty)
                      Text(
                        sizeLabel,
                        style: AppTypography.labelMediumStyle.copyWith(
                          color: theme.textSecondary.withValues(alpha: 0.7),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
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
      if (!widget.readOnly)
        ConduitContextMenuAction(
          cupertinoIcon: CupertinoIcons.pencil,
          sfSymbol: 'pencil',
          materialIcon: Icons.edit_outlined,
          label: l10n.edit,
          onBeforeClose: () => ConduitHaptics.selectionClick(),
          onSelected: () async => _startInlineEdit(),
        ),
      ConduitContextMenuAction(
        cupertinoIcon: CupertinoIcons.square_on_square,
        sfSymbol: 'square.on.square',
        materialIcon: Icons.content_copy,
        label: l10n.copy,
        onBeforeClose: () => ConduitHaptics.selectionClick(),
        onSelected: () async {
          if (widget.onCopy != null) {
            widget.onCopy!();
          }
        },
      ),
      if (!widget.readOnly)
        ConduitContextMenuAction(
          cupertinoIcon: CupertinoIcons.delete,
          sfSymbol: 'trash',
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
    final message = widget.message;
    if (message is! ChatMessage) return _buildUserMessage();
    // A plain text message leaves from the typed words themselves: a
    // stand-in of its bubble flies up from them above the composer.
    final textOnly =
        message.content.isNotEmpty &&
        !_isEditing &&
        (message.attachmentIds?.isEmpty ?? true) &&
        !(_currentFilePartitions()?.hasRenderableFiles ?? false);
    final text = message.content;
    // A message just sent rises from the composer into place, once.
    return ChatSendEntrance(
      messageId: message.id,
      timestamp: message.timestamp,
      flightBuilder: textOnly
          ? (context, morph, typed) =>
                UserMessageFlightBubble(text: text, morph: morph, typed: typed)
          : null,
      child: _buildUserMessage(),
    );
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
    final bubbleMaxWidth = _userBubbleMaxWidth(context);
    // Tail-less, borderless fill: the neutral tone alone separates the turn.
    const bubbleBorderRadius = BorderRadius.all(
      Radius.circular(AppBorderRadius.chatBubble),
    );
    final actions = _buildMessageActions(context);
    final attachmentContent = hasFilesFromArray
        ? _buildUserFileImages(filePartitions!)
        : hasImages
        ? _buildUserAttachmentImages()
        : null;

    return Container(
      width: double.infinity,
      margin: _userMessageRowMargin,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // Display images outside and above the text bubble (iMessage style)
          // Prioritize files array over attachmentIds to avoid duplication
          if (attachmentContent != null)
            ConduitContextMenu(
              key: ValueKey(widget.message.id),
              actions: actions,
              useNativeMenu: true,
              child: attachmentContent,
            ),

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
                      key: ValueKey(widget.message.id),
                      actions: actions,
                      useNativeMenu: true,
                      child: Container(
                        key: const Key('user-message-bubble-surface'),
                        padding: _userBubblePadding,
                        decoration: BoxDecoration(
                          color: theme.chatBubbleUser,
                          borderRadius: bubbleBorderRadius,
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
                            : _UserMessageText(widget.message.content),
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

    // Resending drops this message from the transcript, which disposes this
    // bubble while the send is still running. A WidgetRef read after that
    // fails; the ownership helpers turn the failure into "no database", so the
    // send skipped its outbox drain and the reply waited for the next
    // five-minute sync. The scope's container outlives the bubble.
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      final messageId = widget.message.id?.toString();
      if (messageId == null || messageId.isEmpty) {
        return;
      }
      // Core re-sends the edit: Hermes replays it, anything else truncates
      // after the message and sends the new text as a new turn.
      await resendEditedUserMessage(
        container,
        messageId: messageId,
        newText: newText,
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'inline-edit-failed',
        scope: 'chat/edit',
        error: error,
        stackTrace: stackTrace,
        data: {'messageId': widget.message.id?.toString()},
      );
      if (mounted) {
        AdaptiveSnackBar.show(
          context,
          message: AppLocalizations.of(context)!.errorMessage,
        );
      }
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

/// The row around a user message: full width, inset from the leading edge so
/// it reads as the user's side, and a gap before the reply.
const EdgeInsets _userMessageRowMargin = EdgeInsets.only(
  bottom: Spacing.lg,
  left: Spacing.xxl,
);

/// Inside a user text bubble, around its words.
const EdgeInsets _userBubblePadding = EdgeInsets.symmetric(
  horizontal: Spacing.md,
  vertical: Spacing.sm + Spacing.xxs,
);

double _userBubbleMaxWidth(BuildContext context) =>
    math.min(MediaQuery.sizeOf(context).width * 0.78, 640.0);

/// How a user bubble sets its lines: no extra space above the first line or
/// below the last.
const TextHeightBehavior _userMessageTextHeightBehavior = TextHeightBehavior(
  applyHeightToFirstAscent: false,
  applyHeightToLastDescent: false,
  leadingDistribution: TextLeadingDistribution.even,
);

/// A user message's words, as its bubble sets them.
class _UserMessageText extends StatelessWidget {
  const _UserMessageText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: AppTypography.chatMessageStyle.copyWith(
        color: context.conduitTheme.chatBubbleUserText,
      ),
      softWrap: true,
      textAlign: TextAlign.left,
      textWidthBasis: TextWidthBasis.longestLine,
      textHeightBehavior: _userMessageTextHeightBehavior,
    );
  }
}

/// A sent text message on its way up from the composer.
///
/// It lays out exactly like [UserMessageBubble]'s text bubble, without the
/// menus, so it can land on the real row and hand over without a seam. As
/// [morph] runs from 0 to 1 its fill grows out from around the words (from
/// the words' own frame to the bubble's, its corners rounding as it goes),
/// so the typed text becomes the bubble rather than a bubble fading in.
///
/// With [typed] (the lines as the composer wrapped them, which is wider than
/// a bubble), it starts as exactly those lines, first line on the bubble's
/// first line, and dissolves into the bubble's own wrap early in its rise:
/// the words never re-wrap where they were written, and nothing reflows in
/// a jump. The words both wraps begin with stay solid through the dissolve.
class UserMessageFlightBubble extends StatelessWidget {
  const UserMessageFlightBubble({
    super.key,
    required this.text,
    required this.morph,
    this.typed,
  });

  final String text;
  final Animation<double> morph;
  final ChatSendTypedText? typed;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: _userMessageRowMargin,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          const SizedBox(height: Spacing.xs),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Flexible(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: _userBubbleMaxWidth(context),
                  ),
                  child: _FlightBubble(
                    key: const Key('user-message-flight-bubble'),
                    morph: morph,
                    color: context.conduitTheme.chatBubbleUser,
                    typed: typed,
                    child: _UserMessageText(text),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The flying bubble: its words inside [_userBubblePadding] and, under
/// them, its fill, growing from the words' own frame at [morph] 0 to the
/// whole bubble at 1. The fill is there from the first frame, already a soft
/// tone around the words, and its tone comes in ahead of its size, so the
/// message leaves the composer as a bubble rather than as bare text that
/// gains one on the way. With [typed], the words start as those lines.
class _FlightBubble extends SingleChildRenderObjectWidget {
  const _FlightBubble({
    super.key,
    required this.morph,
    required this.color,
    required this.typed,
    required super.child,
  });

  final Animation<double> morph;
  final Color color;
  final ChatSendTypedText? typed;

  @override
  _RenderFlightBubble createRenderObject(BuildContext context) =>
      _RenderFlightBubble(morph: morph, color: color, typed: typed);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderFlightBubble renderObject,
  ) {
    renderObject
      ..morph = morph
      ..color = color
      ..typed = typed;
  }
}

class _RenderFlightBubble extends RenderShiftedBox {
  _RenderFlightBubble({
    required Animation<double> morph,
    required Color color,
    required ChatSendTypedText? typed,
  }) : _morph = morph,
       _color = color,
       _typed = typed,
       super(null);

  static const double _radius = AppBorderRadius.chatBubble;

  /// The fill's share of its full tone in the frame of the send.
  static const double initialTone = 0.6;

  /// The stretch of [morph] over which the typed lines dissolve into the
  /// bubble's wrap: early, while the message is rising fastest.
  static const Interval dissolve = Interval(
    0.15,
    0.45,
    curve: Curves.easeInOut,
  );

  Animation<double> _morph;
  set morph(Animation<double> value) {
    if (identical(value, _morph)) return;
    if (attached) _morph.removeListener(markNeedsPaint);
    _morph = value;
    if (attached) _morph.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  Color _color;
  set color(Color value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  ChatSendTypedText? _typed;
  set typed(ChatSendTypedText? value) {
    if (identical(value, _typed)) return;
    _typed = value;
    _typedPainter?.dispose();
    _typedPainter = null;
    markNeedsLayout();
  }

  /// The typed lines, set as their field set them, and where they sit.
  TextPainter? _typedPainter;
  Offset _typedOffset = Offset.zero;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _morph.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _morph.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void dispose() {
    _typedPainter?.dispose();
    super.dispose();
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      (child?.getMinIntrinsicWidth(
            math.max(0, height - _userBubblePadding.vertical),
          ) ??
          0) +
      _userBubblePadding.horizontal;

  @override
  double computeMaxIntrinsicWidth(double height) =>
      (child?.getMaxIntrinsicWidth(
            math.max(0, height - _userBubblePadding.vertical),
          ) ??
          0) +
      _userBubblePadding.horizontal;

  @override
  double computeMinIntrinsicHeight(double width) =>
      (child?.getMinIntrinsicHeight(
            math.max(0, width - _userBubblePadding.horizontal),
          ) ??
          0) +
      _userBubblePadding.vertical;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      (child?.getMaxIntrinsicHeight(
            math.max(0, width - _userBubblePadding.horizontal),
          ) ??
          0) +
      _userBubblePadding.vertical;

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final inner = constraints.deflate(_userBubblePadding);
    final childSize = child?.getDryLayout(inner) ?? Size.zero;
    return constraints.constrain(_userBubblePadding.inflateSize(childSize));
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.constrain(_userBubblePadding.inflateSize(Size.zero));
      return;
    }
    child.layout(constraints.deflate(_userBubblePadding), parentUsesSize: true);
    (child.parentData! as BoxParentData).offset = _userBubblePadding.topLeft;
    size = constraints.constrain(_userBubblePadding.inflateSize(child.size));
    _layoutTyped(child);
  }

  /// Lays the typed lines out with their first line of letters on the
  /// bubble's first line, as the flight lines the bubble up on the field's.
  void _layoutTyped(RenderBox child) {
    final typed = _typed;
    if (typed == null) {
      _typedPainter?.dispose();
      _typedPainter = null;
      return;
    }
    final painter = _typedPainter ??= TextPainter(
      text: TextSpan(text: typed.lines.join('\n'), style: typed.style),
      textDirection: TextDirection.ltr,
      textScaler: typed.textScaler,
      textHeightBehavior: _userMessageTextHeightBehavior,
    );
    painter.layout();
    final plain = painter.plainText;
    var first = 0;
    while (first < plain.length && plain[first].trim().isEmpty) {
      first++;
    }
    final boxes = first >= plain.length
        ? const <TextBox>[]
        : painter.getBoxesForSelection(
            TextSelection(baseOffset: first, extentOffset: first + 1),
          );
    final bubbleLine = chatTextLineExtent(child, last: false);
    final dy = boxes.isEmpty || bubbleLine == null
        ? 0.0
        : bubbleLine.top - boxes.first.top;
    _typedOffset = _userBubblePadding.topLeft + Offset(0, dy);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    final progress = _morph.value.clamp(0.0, 1.0);
    final childOffset = (child.parentData! as BoxParentData).offset;
    final typed = _typedPainter;
    final words = typed == null
        ? childOffset & child.size
        : _typedOffset & typed.size;
    final bubble = Offset.zero & size;
    final rect = Rect.lerp(words, bubble, progress)!;
    final radius = _radius * (0.4 + 0.6 * progress);
    final tone =
        initialTone +
        (1 - initialTone) *
            Curves.easeOut.transform((progress * 2).clamp(0.0, 1.0));
    context.canvas.drawRRect(
      RRect.fromRectAndRadius(rect.shift(offset), Radius.circular(radius)),
      Paint()..color = _color.withValues(alpha: _color.a * tone),
    );
    if (typed == null) {
      context.paintChild(child, offset + childOffset);
      return;
    }
    final mix = dissolve.transform(progress);
    if (mix <= 0) {
      typed.paint(context.canvas, offset + _typedOffset);
      return;
    }
    if (mix >= 1 || child.needsCompositing) {
      context.paintChild(child, offset + childOffset);
      return;
    }
    // A true dissolve: each wrap at its share, added together, so a glyph
    // both wraps draw in the same place stays at full strength throughout.
    final canvas = context.canvas;
    final lineHeight = typed.preferredLineHeight;
    final bounds = bubble
        .expandToInclude(_typedOffset & typed.size)
        .inflate(lineHeight)
        .shift(offset);
    canvas.saveLayer(bounds, Paint());
    canvas.saveLayer(bounds, Paint()..color = Color.fromRGBO(0, 0, 0, 1 - mix));
    typed.paint(canvas, offset + _typedOffset);
    canvas.restore();
    canvas.saveLayer(
      bounds,
      Paint()
        ..color = Color.fromRGBO(0, 0, 0, mix)
        ..blendMode = BlendMode.plus,
    );
    context.paintChild(child, offset + childOffset);
    canvas.restore();
    canvas.restore();
  }
}
