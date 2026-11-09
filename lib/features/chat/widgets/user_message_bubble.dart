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
/// menus, so it can land on the real row and hand over without a seam. It
/// is a bubble from the frame it leaves in: its fill, at full tone, already
/// sits around the words where they were written, and fill and words travel
/// as one.
///
/// With [typed] (the lines as the composer wrapped them, which is wider than
/// a bubble), it starts as exactly those lines, first line on the bubble's
/// first line, inside a fill sized to them, and changes shape as [morph]
/// (how far it has travelled) runs: the fill first takes in the bubble's
/// own lines while the typed ones dissolve into them, then narrows to the
/// bubble. The words never re-wrap where they were written, nothing reflows
/// in a jump, and nothing is ever drawn outside the fill. The words both
/// wraps begin with stay solid through the dissolve.
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
/// them, its fill at full tone in every frame. Without [typed] it is the
/// finished bubble throughout. With [typed], the words start as those lines
/// in a fill sized to them (see [UserMessageFlightBubble]) and become the
/// bubble as [morph] runs.
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

/// One word of a sent message: where the typed lines set it and where the
/// bubble's own wrap does, each the word's box in its own layout, and
/// whether both put it on the same line (counted from the first).
typedef _FlightWord = ({Rect typed, Rect bubble, bool sameLine});

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

  /// Words that flow one by one into the bubble's wrap; a longer message
  /// dissolves from one wrap into the other instead.
  static const int _maxFlowingWords = 160;

  // The re-flow, over [morph] (which reaches 1 well before the message
  // lands): words the narrower wrap moves to another line first fade out
  // where they were typed, the words that keep their line then slide along
  // it to their places, and the moved words fade in at theirs once the way
  // is clear. No word ever travels across another, and none is drawn twice.

  /// Words leaving their typed line fade out where they were.
  static const Interval reflowOut = Interval(0, 0.2, curve: Curves.easeOut);

  /// Words keeping their line slide along it; the fill's edges that close in
  /// move with them, so every word stays inside it.
  static const Interval reflowSlide = Interval(
    0.1,
    0.5,
    curve: Curves.easeInOut,
  );

  /// The fill's edges that open out (a line more below) do so first, ahead
  /// of the words that will need the room.
  static const Interval reflowOpen = Interval(
    0.2,
    0.45,
    curve: Curves.easeInOut,
  );

  /// Words arriving on a new line fade in there, once the way is clear.
  static const Interval reflowIn = Interval(0.45, 0.75, curve: Curves.easeOut);

  /// The stretch of [morph] over which the fill grows from the typed lines
  /// to take in the bubble's own lines too, ahead of their dissolving in
  /// (when the words cannot flow one by one).
  static const Interval grow = Interval(0, 0.2, curve: Curves.easeOut);

  /// The stretch of [morph] over which the typed lines dissolve into the
  /// bubble's wrap: early, while the message is rising fastest.
  static const Interval dissolve = Interval(
    0.15,
    0.45,
    curve: Curves.easeInOut,
  );

  /// The stretch of [morph] over which the fill, holding the bubble's words
  /// alone by then, narrows to the bubble.
  static const Interval narrow = Interval(0.45, 1, curve: Curves.easeInOut);

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

  /// The typed lines, set as their field set them (in the bubble's text
  /// colour, so the words hand over to the row without a change of tone),
  /// and where they sit in this box: [_typedOffset] lays their first line of
  /// letters on the bubble's first line; [_typedGlyphTop] is that line's top
  /// inside the painter.
  TextPainter? _typedPainter;
  Offset _typedOffset = Offset.zero;
  double _typedGlyphTop = 0;

  /// The words, matched one to one between the two wraps, or null when they
  /// cannot flow (the texts differ, a word breaks across lines, too many).
  List<_FlightWord>? _words;

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

  /// The bubble's own words: the paragraph inside [root], if laid out.
  static RenderParagraph? _paragraphIn(RenderObject root) {
    RenderParagraph? found;
    void visit(RenderObject node) {
      if (found != null) return;
      if (node is RenderParagraph) {
        found = node;
        return;
      }
      node.visitChildren(visit);
    }

    visit(root);
    final paragraph = found;
    return paragraph != null && paragraph.hasSize ? paragraph : null;
  }

  /// Lays the typed lines out with their first line of letters on the
  /// bubble's first line, as the flight lines the bubble up on the field's,
  /// and matches their words with the bubble's.
  void _layoutTyped(RenderBox child) {
    final typed = _typed;
    _words = null;
    if (typed == null) {
      _typedPainter?.dispose();
      _typedPainter = null;
      return;
    }
    final paragraph = _paragraphIn(child);
    final painter = _typedPainter ??= TextPainter(
      text: TextSpan(
        text: typed.lines.join('\n'),
        style: typed.style.copyWith(
          color: paragraph?.text.style?.color ?? typed.style.color,
        ),
      ),
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
    _typedGlyphTop = boxes.isEmpty ? 0 : boxes.first.top;
    final dy = boxes.isEmpty || bubbleLine == null
        ? 0.0
        : bubbleLine.top - boxes.first.top;
    _typedOffset = _userBubblePadding.topLeft + Offset(0, dy);
    if (paragraph != null) _words = _matchWords(painter, paragraph, child);
  }

  /// Each word's box in the typed lines and in the bubble's paragraph (in
  /// this box's coordinates), when the two hold the same words in the same
  /// order and no word breaks across lines in either.
  List<_FlightWord>? _matchWords(
    TextPainter typed,
    RenderParagraph paragraph,
    RenderBox child,
  ) {
    final words = RegExp(r'\S+');
    final typedWords = words.allMatches(typed.plainText).toList();
    final bubbleText = paragraph.text.toPlainText(
      includeSemanticsLabels: false,
    );
    final bubbleWords = words.allMatches(bubbleText).toList();
    if (typedWords.isEmpty ||
        typedWords.length != bubbleWords.length ||
        typedWords.length > _maxFlowingWords) {
      return null;
    }
    Rect? wordBox(List<TextBox> boxes) {
      if (boxes.isEmpty) return null;
      var rect = boxes.first.toRect();
      for (final box in boxes.skip(1)) {
        // A word on two lines cannot move as one.
        if ((box.top - boxes.first.top).abs() > 1) return null;
        rect = rect.expandToInclude(box.toRect());
      }
      return rect;
    }

    final paragraphOffset = MatrixUtils.transformPoint(
      paragraph.getTransformTo(this),
      Offset.zero,
    );
    final pairs = <(Rect, Rect)>[];
    for (var i = 0; i < typedWords.length; i++) {
      final a = typedWords[i];
      final b = bubbleWords[i];
      if (a.group(0) != b.group(0)) return null;
      final from = wordBox(
        typed.getBoxesForSelection(
          TextSelection(baseOffset: a.start, extentOffset: a.end),
        ),
      );
      final to = wordBox(
        paragraph.getBoxesForSelection(
          TextSelection(baseOffset: b.start, extentOffset: b.end),
        ),
      );
      if (from == null || to == null) return null;
      pairs.add((from, to.shift(paragraphOffset)));
    }
    // Lines counted from the top of each layout.
    List<int> linesOf(Iterable<Rect> boxes) {
      final tops = <double>[];
      return [
        for (final box in boxes)
          () {
            final index = tops.indexWhere((top) => (top - box.top).abs() < 1);
            if (index >= 0) return index;
            tops.add(box.top);
            return tops.length - 1;
          }(),
      ];
    }

    final typedLines = linesOf(pairs.map((pair) => pair.$1));
    final bubbleLines = linesOf(pairs.map((pair) => pair.$2));
    return [
      for (var i = 0; i < pairs.length; i++)
        (
          typed: pairs[i].$1,
          bubble: pairs[i].$2,
          sameLine: typedLines[i] == bubbleLines[i],
        ),
    ];
  }

  /// Where the typed lines' text starts in this box: their own column when
  /// the flight keeps the bubble in its own (the typed words then start on
  /// screen where the field had them), else the bubble's.
  Offset _typedOrigin() {
    final left = _typed?.left;
    if (left == null || !attached) return _typedOffset;
    final globalLeft = localToGlobal(Offset.zero).dx;
    if (!globalLeft.isFinite) return _typedOffset;
    return Offset(left - globalLeft, _typedOffset.dy);
  }

  /// The fill around the typed lines where they were written: the bubble's
  /// padding around them, kept inside the composer they are still in.
  Rect _typedFill(Offset origin) {
    final painter = _typedPainter!;
    final words = origin & painter.size;
    final fill = _userBubblePadding.inflateRect(words);
    final room = _typed?.room;
    if (room == null) return fill;
    final inside = room
        .shift(Offset(origin.dx, origin.dy + _typedGlyphTop))
        .expandToInclude(words);
    return fill.intersect(inside);
  }

  /// The fill at [progress] of the morph, in this box's coordinates, while
  /// typed lines are drawn. Words that flow one by one move inside a fill
  /// that goes from around the typed lines to the bubble on the same
  /// progress, so every word stays inside it. Lines that dissolve instead
  /// are held in a fill around the typed lines at 0, then around both wraps
  /// (so neither ever shows outside it while they dissolve), then the
  /// bubble alone.
  Rect fillRect(double progress) {
    final bubble = Offset.zero & size;
    final typed = _typedPainter;
    if (typed == null) return bubble;
    final origin = _typedOrigin();
    final start = _typedFill(origin);
    if (_words != null) {
      final t = progress.clamp(0.0, 1.0);
      final open = reflowOpen.transform(t);
      final close = reflowSlide.transform(t);
      double edge(double from, double to, {required bool opens}) =>
          from + (to - from) * (opens ? open : close);
      return Rect.fromLTRB(
        edge(start.left, bubble.left, opens: bubble.left < start.left),
        edge(start.top, bubble.top, opens: bubble.top < start.top),
        edge(start.right, bubble.right, opens: bubble.right > start.right),
        edge(start.bottom, bubble.bottom, opens: bubble.bottom > start.bottom),
      );
    }
    final both = start.expandToInclude(bubble);
    if (progress <= grow.end) {
      return Rect.lerp(start, both, grow.transform(progress))!;
    }
    return Rect.lerp(both, bubble, narrow.transform(progress))!;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    final progress = _morph.value.clamp(0.0, 1.0);
    final childOffset = (child.parentData! as BoxParentData).offset;
    final typed = _typedPainter;
    final bubble = Offset.zero & size;
    final rect = typed == null || progress >= 1 ? bubble : fillRect(progress);
    context.canvas.drawRRect(
      RRect.fromRectAndRadius(
        rect.shift(offset),
        Radius.circular(math.min(_radius, rect.shortestSide / 2)),
      ),
      Paint()..color = _color,
    );
    if (typed == null || progress >= 1) {
      context.paintChild(child, offset + childOffset);
      return;
    }
    final origin = _typedOrigin();
    final words = _words;
    if (words != null) {
      if (progress <= 0) {
        typed.paint(context.canvas, offset + origin);
        return;
      }
      // The lines re-flow into the bubble's wrap word by word (see
      // [reflowOut]): no frame snaps from one wrap to the other.
      final canvas = context.canvas;
      final slide = reflowSlide.transform(progress);
      final out = 1 - reflowOut.transform(progress);
      final arrive = reflowIn.transform(progress);
      void drawWord(Rect from, Offset at, double opacity) {
        if (opacity <= 0.002) return;
        final clip = Rect.fromLTRB(
          from.left - 1.5,
          from.top - 0.5,
          from.right + 1.5,
          from.bottom + 0.5,
        );
        canvas
          ..save()
          ..translate(
            offset.dx + at.dx - from.left,
            offset.dy + at.dy - from.top,
          );
        if (opacity < 1) {
          canvas.saveLayer(
            clip,
            Paint()..color = Color.fromRGBO(0, 0, 0, opacity),
          );
        }
        canvas.clipRect(clip);
        typed.paint(canvas, origin);
        if (opacity < 1) canvas.restore();
        canvas.restore();
      }

      for (final word in words) {
        final from = word.typed.shift(origin);
        if (word.sameLine) {
          drawWord(
            from,
            Offset.lerp(from.topLeft, word.bubble.topLeft, slide)!,
            1,
          );
        } else {
          drawWord(from, from.topLeft, out);
          drawWord(from, word.bubble.topLeft, arrive);
        }
      }
      return;
    }
    final mix = dissolve.transform(progress);
    if (mix <= 0) {
      typed.paint(context.canvas, offset + origin);
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
        .expandToInclude(origin & typed.size)
        .inflate(lineHeight)
        .shift(offset);
    canvas.saveLayer(bounds, Paint());
    canvas.saveLayer(bounds, Paint()..color = Color.fromRGBO(0, 0, 0, 1 - mix));
    typed.paint(canvas, offset + origin);
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
