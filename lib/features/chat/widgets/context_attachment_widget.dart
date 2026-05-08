import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:conduit/l10n/app_localizations.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../models/chat_context_attachment.dart';
import '../providers/context_attachments_provider.dart';

class ContextAttachmentWidget extends ConsumerWidget {
  const ContextAttachmentWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final attachments = ref.watch(contextAttachmentsProvider);
    if (attachments.isEmpty) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context)!;
    final attachmentsNotifier = ref.read(contextAttachmentsProvider.notifier);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.sm, Spacing.md, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.attachments, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: Spacing.sm),
          Wrap(
            spacing: Spacing.sm,
            runSpacing: Spacing.sm,
            children: [
              for (final attachment in attachments)
                _ContextAttachmentChip(
                  label: attachment.displayName,
                  icon: _iconForType(attachment.type),
                  onDeleted: () => attachmentsNotifier.remove(attachment.id),
                ),
            ],
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
      case ChatContextAttachmentType.note:
        return Icons.sticky_note_2_outlined;
    }
  }
}

class _ContextAttachmentChip extends StatelessWidget {
  const _ContextAttachmentChip({
    required this.label,
    required this.icon,
    required this.onDeleted,
  });

  final String label;
  final IconData icon;
  final VoidCallback onDeleted;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final deleteTooltip = MaterialLocalizations.of(context).deleteButtonTooltip;

    return Container(
      constraints: const BoxConstraints(maxWidth: 260),
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.sm,
        vertical: Spacing.xs,
      ),
      decoration: BoxDecoration(
        color: theme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppBorderRadius.round),
        border: Border.all(color: theme.cardBorder, width: BorderWidth.thin),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: theme.textSecondary),
          const SizedBox(width: Spacing.xs),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: theme.textPrimary),
            ),
          ),
          const SizedBox(width: Spacing.xs),
          Semantics(
            button: true,
            label: deleteTooltip,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onDeleted,
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(Icons.close, size: 16, color: theme.textSecondary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
