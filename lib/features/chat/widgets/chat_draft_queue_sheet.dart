import 'dart:async';
import 'dart:io' show Platform;

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:conduit_core/features/chat/providers/attached_files_provider.dart';
import 'package:conduit_core/features/chat/services/chat_draft_queue.dart';
import 'package:conduit/core/services/haptic_service.dart';
import 'package:conduit/core/services/media_upload_controller.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';

/// The one-line summary of the messages queued behind the running response.
///
/// It stays visible whatever the Advanced setting says: drafts that exist can
/// always be seen, edited, removed or sent from the sheet it opens.
class ChatDraftQueueRow extends ConsumerWidget {
  const ChatDraftQueueRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(activeChatDraftQueueProvider);
    if (queue == null || queue.drafts.isEmpty) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final sending = queue.phase != ChatDraftQueuePhase.idle;
    final failed = queue.admissionFailed && !sending;
    final preview = queue.drafts.first.text.replaceAll(RegExp(r'\s+'), ' ');
    final title = l10n.queuedDraftsCount(queue.drafts.length);
    final detail = sending
        ? l10n.queuedDraftsSending
        : failed
        ? l10n.queuedDraftsSendFailed
        : preview;

    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.xs),
      child: Semantics(
        button: true,
        label: '$title. $detail',
        excludeSemantics: true,
        child: GestureDetector(
          key: const Key('chat-draft-queue-row'),
          behavior: HitTestBehavior.opaque,
          onTap: () {
            ConduitHaptics.selectionClick();
            showChatDraftQueueSheet(context);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.md,
              vertical: Spacing.sm,
            ),
            decoration: BoxDecoration(
              color: theme.surfaceContainer,
              borderRadius: BorderRadius.circular(AppBorderRadius.card),
              border: Border.all(
                color: failed ? theme.error : theme.cardBorder,
                width: BorderWidth.thin,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Platform.isIOS ? CupertinoIcons.list_bullet : Icons.queue,
                  size: IconSize.sm,
                  color: failed ? theme.error : theme.iconSecondary,
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: theme.bodySmall?.copyWith(
                          color: theme.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        detail,
                        style: theme.bodySmall?.copyWith(
                          color: failed ? theme.error : theme.textSecondary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: Spacing.sm),
                Icon(
                  Platform.isIOS
                      ? CupertinoIcons.chevron_forward
                      : Icons.chevron_right,
                  size: IconSize.small,
                  color: theme.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> showChatDraftQueueSheet(BuildContext context) {
  return ThemedSheets.showCustom<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const ChatDraftQueueSheet(),
  );
}

/// Lists the queued drafts of the visible conversation and acts on each by id.
class ChatDraftQueueSheet extends ConsumerStatefulWidget {
  const ChatDraftQueueSheet({super.key});

  @override
  ConsumerState<ChatDraftQueueSheet> createState() =>
      _ChatDraftQueueSheetState();
}

class _ChatDraftQueueSheetState extends ConsumerState<ChatDraftQueueSheet> {
  final TextEditingController _editController = TextEditingController();
  String? _editingId;
  bool _closing = false;

  @override
  void dispose() {
    _editController.dispose();
    super.dispose();
  }

  ChatDraftQueueController get _queue =>
      ref.read(chatDraftQueueProvider.notifier);

  void _close() {
    if (_closing || !mounted) return;
    _closing = true;
    Navigator.of(context).maybePop();
  }

  void _startEdit(QueuedChatDraft draft) {
    _editController.text = draft.text;
    setState(() => _editingId = draft.id);
  }

  void _saveEdit(String draftId) {
    _queue.editDraft(draftId, _editController.text);
    setState(() => _editingId = null);
  }

  Future<void> _sendNow(QueuedChatDraft draft) async {
    final l10n = AppLocalizations.of(context)!;
    ConduitHaptics.mediumImpact();
    final outcome = await _queue.sendNow(draft.id);
    if (!mounted) return;
    switch (outcome) {
      case ChatDraftSendNowOutcome.admitted:
        _close();
      case ChatDraftSendNowOutcome.blockedByUpload:
        AdaptiveSnackBar.show(
          context,
          message: l10n.queuedDraftUploading,
          type: AdaptiveSnackBarType.warning,
        );
      case ChatDraftSendNowOutcome.stopFailed:
      case ChatDraftSendNowOutcome.admissionFailed:
        AdaptiveSnackBar.show(
          context,
          message: l10n.queuedDraftsSendFailed,
          type: AdaptiveSnackBarType.error,
        );
      case ChatDraftSendNowOutcome.unavailable:
      case ChatDraftSendNowOutcome.changed:
        break;
    }
  }

  /// Uploads a failed file again as its own upload. A failure leaves the file
  /// failed and visible, so the error is not surfaced a second time here.
  void _retryUpload(QueuedDraftAttachment held) {
    unawaited(
      ref
          .read(mediaUploadControllerProvider)
          .retryQueuedAttachment(queueId: held.queueId, id: held.id)
          .catchError((Object _) {}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final queue = ref.watch(activeChatDraftQueueProvider);
    final attachments = ref.watch(queuedDraftAttachmentsProvider);
    if (queue == null || queue.drafts.isEmpty) {
      // Everything was sent or removed, or another chat is on screen.
      WidgetsBinding.instance.addPostFrameCallback((_) => _close());
      return const SizedBox.shrink();
    }
    final busy = queue.phase != ChatDraftQueuePhase.idle;

    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ConduitModalSheetSurface(
        child: Column(
          key: const Key('chat-draft-queue-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.queuedDraftsTitle,
                    style: theme.headingSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                SheetCloseButton(
                  tooltip: l10n.close,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: Spacing.xs),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final draft in queue.drafts)
                      _draftCard(
                        context,
                        l10n: l10n,
                        queue: queue,
                        draft: draft,
                        attachments: attachments,
                        busy: busy,
                      ),
                  ],
                ),
              ),
            ),
            if (queue.admissionFailed && !busy) ...[
              const SizedBox(height: Spacing.sm),
              Text(
                l10n.queuedDraftsSendFailed,
                key: const Key('chat-draft-queue-failed'),
                style: theme.bodySmall?.copyWith(color: theme.error),
              ),
              const SizedBox(height: Spacing.xs),
              ConduitButton(
                key: const Key('chat-draft-queue-retry'),
                text: l10n.retry,
                isCompact: true,
                onPressed: _queue.retryAdmission,
              ),
            ],
            const SizedBox(height: Spacing.sm),
            Text(
              l10n.queuedDraftsSessionNote,
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _draftCard(
    BuildContext context, {
    required AppLocalizations l10n,
    required ChatDraftQueue queue,
    required QueuedChatDraft draft,
    required List<QueuedDraftAttachment> attachments,
    required bool busy,
  }) {
    final theme = context.conduitTheme;
    final frozen = queue.isFrozen(draft.id);
    final editing = _editingId == draft.id && !frozen;
    final readiness = chatDraftReadiness(queue, draft, attachments);

    return Container(
      key: Key('chat-draft-${draft.id}'),
      margin: const EdgeInsets.only(bottom: Spacing.sm),
      padding: const EdgeInsets.all(Spacing.sm),
      decoration: BoxDecoration(
        color: theme.surfaceContainer,
        borderRadius: BorderRadius.circular(AppBorderRadius.card),
        border: Border.all(color: theme.cardBorder, width: BorderWidth.thin),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (editing)
            AdaptiveTextField(
              key: Key('chat-draft-edit-${draft.id}'),
              controller: _editController,
              autofocus: true,
              minLines: 1,
              maxLines: 6,
            )
          else
            Text(
              draft.text,
              style: theme.bodyMedium,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
          for (final (index, file)
              in chatDraftFiles(queue, draft, attachments).indexed)
            _attachmentRow(
              context,
              draft: draft,
              attachmentId: draft.attachmentIds[index],
              held: file,
              locked: frozen,
            ),
          if (readiness == ChatDraftReadiness.uploading)
            Padding(
              padding: const EdgeInsets.only(top: Spacing.xs),
              child: Text(
                l10n.queuedDraftUploading,
                style: theme.bodySmall?.copyWith(color: theme.textSecondary),
              ),
            ),
          if (readiness == ChatDraftReadiness.failed)
            Padding(
              padding: const EdgeInsets.only(top: Spacing.xs),
              child: Text(
                l10n.queuedDraftFileFailed,
                style: theme.bodySmall?.copyWith(color: theme.error),
              ),
            ),
          const SizedBox(height: Spacing.xs),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: editing
                ? [
                    ConduitButton(
                      text: l10n.cancel,
                      isSecondary: true,
                      isCompact: true,
                      onPressed: () => setState(() => _editingId = null),
                    ),
                    const SizedBox(width: Spacing.xs),
                    ConduitButton(
                      key: Key('chat-draft-save-${draft.id}'),
                      text: l10n.save,
                      isCompact: true,
                      onPressed: () => _saveEdit(draft.id),
                    ),
                  ]
                : [
                    ConduitIconButton(
                      key: Key('chat-draft-edit-action-${draft.id}'),
                      tooltip: l10n.edit,
                      isCompact: true,
                      icon: Platform.isIOS
                          ? CupertinoIcons.pencil
                          : Icons.edit_outlined,
                      onPressed: frozen ? null : () => _startEdit(draft),
                    ),
                    ConduitIconButton(
                      key: Key('chat-draft-delete-${draft.id}'),
                      tooltip: l10n.delete,
                      isCompact: true,
                      icon: Platform.isIOS
                          ? CupertinoIcons.trash
                          : Icons.delete_outline,
                      onPressed: frozen
                          ? null
                          : () {
                              ConduitHaptics.lightImpact();
                              _queue.removeDraft(draft.id);
                            },
                    ),
                    const SizedBox(width: Spacing.xs),
                    ConduitButton(
                      key: Key('chat-draft-send-now-${draft.id}'),
                      text: l10n.queuedDraftSendNow,
                      isCompact: true,
                      onPressed:
                          busy || readiness != ChatDraftReadiness.ready
                          ? null
                          : () => _sendNow(draft),
                    ),
                  ],
          ),
        ],
      ),
    );
  }

  Widget _attachmentRow(
    BuildContext context, {
    required QueuedChatDraft draft,
    required String attachmentId,
    required QueuedDraftAttachment? held,
    required bool locked,
  }) {
    final theme = context.conduitTheme;
    final file = held?.upload;
    final failed = file == null || file.status == FileUploadStatus.failed;
    final uploading =
        file != null &&
        (file.status == FileUploadStatus.pending ||
            file.status == FileUploadStatus.uploading);
    return Padding(
      padding: const EdgeInsets.only(top: Spacing.xs),
      child: Row(
        children: [
          Icon(
            failed
                ? (Platform.isIOS
                      ? CupertinoIcons.exclamationmark_circle
                      : Icons.error_outline)
                : uploading
                ? (Platform.isIOS ? CupertinoIcons.clock : Icons.schedule)
                : (Platform.isIOS ? CupertinoIcons.doc : Icons.attach_file),
            size: IconSize.sm,
            color: failed ? theme.error : theme.iconSecondary,
          ),
          const SizedBox(width: Spacing.xs),
          Expanded(
            child: Text(
              file?.fileName ?? AppLocalizations.of(context)!.fileRemoved,
              style: theme.bodySmall?.copyWith(
                color: failed ? theme.error : theme.textSecondary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (held != null && file!.status == FileUploadStatus.failed)
            ConduitIconButton(
              key: Key('chat-draft-retry-file-${draft.id}-$attachmentId'),
              tooltip: AppLocalizations.of(context)!.retry,
              isCompact: true,
              icon: Platform.isIOS ? CupertinoIcons.refresh : Icons.refresh,
              onPressed: locked ? null : () => _retryUpload(held),
            ),
          ConduitIconButton(
            key: Key('chat-draft-remove-file-${draft.id}-$attachmentId'),
            tooltip: MaterialLocalizations.of(context).deleteButtonTooltip,
            isCompact: true,
            icon: Platform.isIOS ? CupertinoIcons.xmark : Icons.close,
            onPressed: locked
                ? null
                : () => _queue.removeDraftAttachment(draft.id, attachmentId),
          ),
        ],
      ),
    );
  }
}
