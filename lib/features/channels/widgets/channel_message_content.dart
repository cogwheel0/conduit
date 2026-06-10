import 'package:flutter/material.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/external_link_launcher.dart';
import '../../../shared/widgets/markdown/markdown_config.dart';
import '../../../shared/widgets/markdown/markdown_preprocessor.dart';
import '../../../shared/widgets/markdown/renderer/conduit_markdown_widget.dart';
import '../../chat/utils/file_utils.dart';
import '../../chat/widgets/enhanced_attachment.dart';
import '../../chat/widgets/enhanced_image_attachment.dart';

/// Renders channel message text with the same Markdown pipeline used by chat.
class ChannelMessageContent extends StatelessWidget {
  /// Creates a Markdown-rendered channel message body.
  const ChannelMessageContent({
    super.key,
    required this.content,
    this.stateScopeId,
    this.onTapLink,
  });

  /// Raw channel message content from OpenWebUI.
  final String content;

  /// Stable identifier used to preserve Markdown block state for this message.
  final String? stateScopeId;

  /// Optional override used by tests or embedders that want custom link taps.
  final MarkdownLinkTapCallback? onTapLink;

  @override
  Widget build(BuildContext context) {
    final normalized = ConduitMarkdownPreprocessor.normalize(content);
    if (normalized.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    return ConduitMarkdownWidget(
      data: normalized,
      dataIsPrepared: true,
      stateScopeId: stateScopeId,
      onLinkTap: onTapLink ??
          (url, _) => launchExternalLink(url, scope: 'channels/markdown'),
    );
  }
}

/// Renders channel message attachments stored in `message.data.files`.
class ChannelMessageAttachments extends StatelessWidget {
  const ChannelMessageAttachments({super.key, required this.files});

  final Object? files;

  @override
  Widget build(BuildContext context) {
    final rawFiles = files;
    if (rawFiles is! List || rawFiles.isEmpty) {
      return const SizedBox.shrink();
    }

    final attachmentFiles = rawFiles
        .where((file) => getFileUrl(file) != null)
        .toList(growable: false);
    if (attachmentFiles.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(top: Spacing.xs),
      child: Wrap(
        spacing: Spacing.sm,
        runSpacing: Spacing.sm,
        children: attachmentFiles.map(_buildAttachment).toList(),
      ),
    );
  }

  Widget _buildAttachment(dynamic file) {
    final attachmentId = getFileUrl(file)!;
    final isImage = isImageFile(file);
    final constraints = BoxConstraints(
      maxWidth: isImage ? 260 : 280,
      maxHeight: isImage ? 260 : 120,
    );

    if (isImage) {
      return EnhancedImageAttachment(
        attachmentId: attachmentId,
        isMarkdownFormat: true,
        constraints: constraints,
      );
    }

    return EnhancedAttachment(
      attachmentId: attachmentId,
      isMarkdownFormat: true,
      constraints: constraints,
    );
  }
}
