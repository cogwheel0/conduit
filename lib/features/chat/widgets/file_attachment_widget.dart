import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/material.dart';
import '../../../shared/theme/theme_extensions.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:io' show File, Platform;
import 'package:conduit/l10n/app_localizations.dart';
import '../services/file_attachment_service.dart';
import '../../../shared/services/tasks/task_queue.dart';
import '../../../shared/widgets/conduit_loading.dart';

const Set<String> _previewableImageExtensions = <String>{
  '.jpg',
  '.jpeg',
  '.png',
  '.gif',
  '.webp',
  '.bmp',
};

class FileAttachmentWidget extends ConsumerWidget {
  const FileAttachmentWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final attachedFiles = ref.watch(attachedFilesProvider);

    if (attachedFiles.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.sm, Spacing.md, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppLocalizations.of(context)!.attachments,
            style: AppTypography.labelMediumStyle.copyWith(
              color: context.conduitTheme.textSecondary.withValues(alpha: 0.7),
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: Spacing.sm),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: attachedFiles
                  .map(
                    (fileState) => Padding(
                      padding: const EdgeInsets.only(right: Spacing.sm),
                      child: _FileAttachmentCard(fileState: fileState),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }
}

class _FileAttachmentCard extends ConsumerWidget {
  final FileUploadState fileState;

  const _FileAttachmentCard({required this.fileState});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool canPreview = _canPreviewImage();
    final Widget removeButton = _buildRemoveButton(context, ref);

    return Container(
      width: 140,
      padding: const EdgeInsets.all(Spacing.sm),
      decoration: BoxDecoration(
        color: context.conduitTheme.cardBackground,
        borderRadius: BorderRadius.circular(AppBorderRadius.small),
        border: Border.all(
          color: _getBorderColor(fileState.status, context),
          width: BorderWidth.standard,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (canPreview) ...[
            _buildImagePreview(context, removeButton),
            const SizedBox(height: Spacing.sm),
          ] else ...[
            Row(
              children: [
                _buildStatusIcon(context),
                const Spacer(),
                removeButton,
              ],
            ),
            const SizedBox(height: Spacing.xs),
          ],
          Text(
            fileState.fileName,
            style: AppTypography.labelMediumStyle.copyWith(
              color: context.conduitTheme.textPrimary,
              fontWeight: FontWeight.w500,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            fileState.formattedSize,
            style: AppTypography.labelSmallStyle.copyWith(
              color: context.conduitTheme.textSecondary.withValues(alpha: 0.6),
            ),
          ),
          if (fileState.status == FileUploadStatus.uploading) ...[
            const SizedBox(height: Spacing.xs),
            _buildProgressBar(context),
          ],
          if (fileState.error != null) ...[
            const SizedBox(height: Spacing.xs),
            Text(
              'Failed to upload',
              style: AppTypography.labelSmallStyle.copyWith(
                color: context.conduitTheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatusIcon(BuildContext context) {
    switch (fileState.status) {
      case FileUploadStatus.pending:
        return Icon(
          Platform.isIOS ? CupertinoIcons.clock : Icons.schedule,
          size: IconSize.sm,
          color: context.conduitTheme.iconDisabled,
        );
      case FileUploadStatus.uploading:
        return ConduitLoading.inline(
          size: IconSize.sm,
          color: context.conduitTheme.iconSecondary,
        );
      case FileUploadStatus.completed:
        return Icon(
          Platform.isIOS
              ? CupertinoIcons.checkmark_circle_fill
              : Icons.check_circle,
          size: IconSize.sm,
          color: context.conduitTheme.success,
        );
      case FileUploadStatus.failed:
        return GestureDetector(
          onTap: () {
            // Retry upload
          },
          child: Icon(
            Platform.isIOS
                ? CupertinoIcons.exclamationmark_circle_fill
                : Icons.error,
            size: IconSize.sm,
            color: context.conduitTheme.error,
          ),
        );
    }
  }

  Widget _buildRemoveButton(BuildContext context, WidgetRef ref) {
    final String tooltip = MaterialLocalizations.of(
      context,
    ).deleteButtonTooltip;
    return AdaptiveTooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _removeAttachment(ref),
          child: Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: context.conduitTheme.cardBackground.withValues(
                alpha: 0.85,
              ),
              shape: BoxShape.circle,
              border: Border.all(
                color: context.conduitTheme.cardBorder.withValues(alpha: 0.6),
                width: BorderWidth.thin,
              ),
            ),
            child: Icon(
              Platform.isIOS ? CupertinoIcons.xmark : Icons.close,
              size: 14,
              color: context.conduitTheme.textPrimary.withValues(alpha: 0.8),
            ),
          ),
        ),
      ),
    );
  }

  void _removeAttachment(WidgetRef ref) {
    ref.read(attachedFilesProvider.notifier).removeFile(fileState.file.path);
    if (!fileState.isRemote) {
      ref
          .read(taskQueueProvider.notifier)
          .cancelUploadsForFile(fileState.file.path);
    }
  }

  Widget _buildProgressBar(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppBorderRadius.xs),
      child: LinearProgressIndicator(
        value: fileState.progress,
        backgroundColor: context.conduitTheme.textPrimary.withValues(
          alpha: 0.1,
        ),
        valueColor: AlwaysStoppedAnimation<Color>(
          context.conduitTheme.buttonPrimary,
        ),
        minHeight: 4,
      ),
    );
  }

  Color _getBorderColor(FileUploadStatus status, BuildContext context) {
    switch (status) {
      case FileUploadStatus.pending:
        return context.conduitTheme.textPrimary.withValues(alpha: 0.2);
      case FileUploadStatus.uploading:
        return context.conduitTheme.buttonPrimary.withValues(alpha: 0.5);
      case FileUploadStatus.completed:
        return context.conduitTheme.success.withValues(alpha: 0.3);
      case FileUploadStatus.failed:
        return context.conduitTheme.error.withValues(alpha: 0.3);
    }
  }

  bool _canPreviewImage() {
    if (fileState.isRemote) {
      return false;
    }
    if (fileState.isImage != null) {
      return fileState.isImage!;
    }
    final String lowerName = fileState.fileName.toLowerCase();
    return _previewableImageExtensions.any(lowerName.endsWith);
  }

  Widget _buildImagePreview(BuildContext context, Widget removeButton) {
    final File file = fileState.file;
    final bool fileExists = file.existsSync();
    final Widget basePreview = fileExists
        ? Image.file(
            file,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
            errorBuilder: (context, error, stackTrace) =>
                _buildPreviewPlaceholderContent(context),
          )
        : _buildPreviewPlaceholderContent(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppBorderRadius.xs),
        border: Border.all(
          color: context.conduitTheme.cardBorder,
          width: BorderWidth.thin,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppBorderRadius.xs),
        child: AspectRatio(
          aspectRatio: 4 / 3,
          child: Stack(
            children: [
              Positioned.fill(child: basePreview),
              if (fileState.status == FileUploadStatus.uploading)
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: context.conduitTheme.cardBackground.withValues(
                        alpha: 0.35,
                      ),
                    ),
                  ),
                ),
              Positioned(
                top: Spacing.xs,
                right: Spacing.xs,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: context.conduitTheme.cardBackground.withValues(
                      alpha: 0.85,
                    ),
                    borderRadius: BorderRadius.circular(AppBorderRadius.xs),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: _buildStatusIcon(context),
                  ),
                ),
              ),
              Positioned(
                top: Spacing.xs,
                left: Spacing.xs,
                child: removeButton,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPreviewPlaceholderContent(BuildContext context) {
    return Container(
      color: context.conduitTheme.textPrimary.withValues(alpha: 0.08),
      alignment: Alignment.center,
      child: Text(fileState.fileIcon, style: const TextStyle(fontSize: 26)),
    );
  }
}

// Attachment preview for messages
class MessageAttachmentPreview extends StatelessWidget {
  final List<String> fileIds;

  const MessageAttachmentPreview({super.key, required this.fileIds});

  @override
  Widget build(BuildContext context) {
    if (fileIds.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(top: Spacing.sm),
      child: Wrap(
        spacing: Spacing.xs,
        runSpacing: Spacing.xs,
        children: fileIds
            .map(
              (fileId) => Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: Spacing.sm,
                  vertical: Spacing.xs,
                ),
                decoration: BoxDecoration(
                  color: context.conduitTheme.textPrimary.withValues(
                    alpha: 0.08,
                  ),
                  borderRadius: BorderRadius.circular(AppBorderRadius.small),
                  border: Border.all(
                    color: context.conduitTheme.textPrimary.withValues(
                      alpha: 0.15,
                    ),
                    width: BorderWidth.thin,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('📎', style: TextStyle(fontSize: 14)),
                    const SizedBox(width: Spacing.xs),
                    Text(
                      AppLocalizations.of(context)!.attachmentLabel,
                      style: AppTypography.labelSmallStyle.copyWith(
                        color: context.conduitTheme.textPrimary.withValues(
                          alpha: 0.8,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )
            .toList(),
      ),
    );
  }
}
