import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:conduit/l10n/app_localizations.dart';

import '../../../shared/theme/theme_extensions.dart';

/// A widget that displays a file attachment in a note.
///
/// Supports different file types with appropriate icons and actions.
class NoteFileAttachment extends StatelessWidget {
  /// The file data from the note.
  final Map<String, dynamic> file;

  /// Called when the file is tapped.
  final VoidCallback? onTap;

  /// Called when the delete button is pressed.
  final VoidCallback? onDelete;

  /// Whether the file is currently loading.
  final bool isLoading;

  /// Whether to show the delete button.
  final bool showDelete;

  const NoteFileAttachment({
    super.key,
    required this.file,
    this.onTap,
    this.onDelete,
    this.isLoading = false,
    this.showDelete = true,
  });

  String get _fileName => file['name']?.toString() ?? 'Unknown file';
  String get _fileType => file['type']?.toString() ?? 'file';
  int? get _fileSize => file['size'] as int?;

  bool get _isAudio =>
      _fileType == 'audio' ||
      _fileName.endsWith('.m4a') ||
      _fileName.endsWith('.mp3') ||
      _fileName.endsWith('.wav') ||
      _fileName.endsWith('.aac');

  bool get _isImage => _fileType == 'image';

  IconData get _icon {
    if (_isAudio) {
      return Platform.isIOS
          ? CupertinoIcons.waveform
          : Icons.audio_file_rounded;
    }
    if (_isImage) {
      return Platform.isIOS ? CupertinoIcons.photo : Icons.image_rounded;
    }
    return Platform.isIOS
        ? CupertinoIcons.doc_fill
        : Icons.insert_drive_file_rounded;
  }

  Color _iconColor(ConduitThemeExtension theme) {
    if (_isAudio) return Colors.orange;
    if (_isImage) return Colors.blue;
    return theme.textSecondary;
  }

  String _formatFileSize(int? bytes) {
    if (bytes == null) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppBorderRadius.md),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.sm,
            vertical: Spacing.sm,
          ),
          decoration: BoxDecoration(
            color: theme.surfaceContainer.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(AppBorderRadius.md),
            border: Border.all(
              color: theme.cardBorder.withValues(alpha: 0.3),
              width: BorderWidth.thin,
            ),
          ),
          child: Row(
            children: [
              // File icon
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: _iconColor(theme).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(AppBorderRadius.sm),
                ),
                child: isLoading
                    ? Center(
                        child: SizedBox(
                          width: IconSize.sm,
                          height: IconSize.sm,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation(
                              _iconColor(theme),
                            ),
                          ),
                        ),
                      )
                    : Icon(
                        _icon,
                        color: _iconColor(theme),
                        size: IconSize.md,
                      ),
              ),

              const SizedBox(width: Spacing.sm),

              // File info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _fileName,
                      style: AppTypography.bodySmallStyle.copyWith(
                        color: theme.textPrimary,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Text(
                          _isAudio
                              ? l10n.audioFileType
                              : _isImage
                                  ? l10n.imageFileType
                                  : l10n.file,
                          style: AppTypography.captionStyle.copyWith(
                            color: theme.textSecondary,
                          ),
                        ),
                        if (_fileSize != null) ...[
                          Text(
                            ' · ',
                            style: AppTypography.captionStyle.copyWith(
                              color: theme.textSecondary,
                            ),
                          ),
                          Text(
                            _formatFileSize(_fileSize),
                            style: AppTypography.captionStyle.copyWith(
                              color: theme.textSecondary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),

              // Play button for audio
              if (_isAudio && !isLoading)
                IconButton(
                  icon: Icon(
                    Platform.isIOS
                        ? CupertinoIcons.play_circle_fill
                        : Icons.play_circle_filled_rounded,
                    color: _iconColor(theme),
                    size: IconSize.lg,
                  ),
                  onPressed: onTap,
                  tooltip: l10n.playAudio,
                ),

              // Delete button
              if (showDelete && !isLoading)
                IconButton(
                  icon: Icon(
                    Platform.isIOS
                        ? CupertinoIcons.xmark_circle_fill
                        : Icons.cancel_rounded,
                    color: theme.textSecondary.withValues(alpha: 0.5),
                    size: IconSize.md,
                  ),
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    onDelete?.call();
                  },
                  tooltip: l10n.removeFile,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A section that displays all file attachments for a note.
class NoteFilesSection extends StatelessWidget {
  /// The list of files attached to the note.
  final List<Map<String, dynamic>> files;

  /// Called when a file should be played (for audio).
  final void Function(Map<String, dynamic> file)? onPlayFile;

  /// Called when a file should be deleted.
  final void Function(Map<String, dynamic> file)? onDeleteFile;

  /// Whether files can be deleted.
  final bool canDelete;

  const NoteFilesSection({
    super.key,
    required this.files,
    this.onPlayFile,
    this.onDeleteFile,
    this.canDelete = true,
  });

  @override
  Widget build(BuildContext context) {
    if (files.isEmpty) return const SizedBox.shrink();

    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section header
        Padding(
          padding: const EdgeInsets.only(
            left: Spacing.xs,
            bottom: Spacing.xs,
          ),
          child: Row(
            children: [
              Icon(
                Platform.isIOS
                    ? CupertinoIcons.paperclip
                    : Icons.attach_file_rounded,
                size: IconSize.sm,
                color: theme.textSecondary,
              ),
              const SizedBox(width: Spacing.xs),
              Text(
                l10n.attachments,
                style: AppTypography.labelStyle.copyWith(
                  color: theme.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: Spacing.xs),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: Spacing.xs,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: theme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(AppBorderRadius.xs),
                ),
                child: Text(
                  '${files.length}',
                  style: AppTypography.captionStyle.copyWith(
                    color: theme.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),

        // Files list
        ...files.map(
          (file) => Padding(
            padding: const EdgeInsets.only(bottom: Spacing.xs),
            child: NoteFileAttachment(
              file: file,
              showDelete: canDelete,
              onTap: () => onPlayFile?.call(file),
              onDelete: () => onDeleteFile?.call(file),
            ),
          ),
        ),
      ],
    );
  }
}

