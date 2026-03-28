import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qonduit/l10n/app_localizations.dart';

import '../models/chat_context_attachment.dart';
import '../providers/context_attachments_provider.dart';

class ContextAttachmentWidget extends ConsumerWidget {
  const ContextAttachmentWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final attachments = ref.watch(contextAttachmentsProvider);
    if (attachments.isEmpty) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.attachments, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: attachments
                .map(
                  (attachment) => InputChip(
                    label: Text(
                      attachment.displayName,
                      overflow: TextOverflow.ellipsis,
                    ),
                    avatar: Icon(_iconForType(attachment.type), size: 18),
                    onDeleted: () => ref
                        .read(contextAttachmentsProvider.notifier)
                        .remove(attachment.id),
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }

  IconData _iconForType(ChatContextAttachmentType type) {
    switch (type) {
      case ChatContextAttachmentType.web:
        return Icons.public;
      case ChatContextAttachmentType.youtube:
        return Icons.play_circle_outline;
      case ChatContextAttachmentType.knowledge:
        return Icons.folder_outlined;
    }
  }
}
