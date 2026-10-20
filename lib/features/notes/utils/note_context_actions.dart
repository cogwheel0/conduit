import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit/features/workspace/widgets/resource_sharing_sheet.dart';
import 'package:conduit/features/workspace/widgets/workspace_access_grants.dart'
    show WorkspaceAccessOwner;
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/notes/utils/note_access.dart';
import 'package:conduit_core/features/sharing/models/resource_access.dart';
import 'package:conduit_core/models/note.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/utils/user_avatar_utils.dart';
import 'package:conduit/core/services/haptic_service.dart';
import 'package:conduit/features/notes/providers/notes_providers.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/utils/conversation_context_menu.dart';
import 'package:conduit/shared/utils/ui_utils.dart';
import 'package:conduit/shared/widgets/themed_dialogs.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the note's access sheet is offered: for a server note the account
/// may edit, when the server lets it share notes. Reading and read-only
/// enforcement do not depend on this.
bool canShareNote(WidgetRef ref, Note note) {
  // A `local:` note is not on the server yet, so it has no access to edit.
  if (note.id.startsWith('local:')) return false;
  final access = noteWriteAccess(
    note,
    accountId: ref.read(currentUserProvider2)?.id,
  );
  if (access != NoteWriteAccess.allowed) return false;
  return ref.read(workspaceCapabilitiesProvider).value?.notes.section.share ==
      true;
}

/// Whether the signed-in account may change [note]. A note it may only read,
/// or whose access the server has not confirmed yet, is opened rather than
/// edited and offers no Delete (the delete route takes the same people as an
/// edit).
bool canEditNote(WidgetRef ref, Note note) =>
    noteWriteAccess(note, accountId: ref.read(currentUserProvider2)?.id) ==
    NoteWriteAccess.allowed;

/// The note's owner when it is someone other than the signed-in account, or
/// null for the account's own notes and notes whose owner is not known.
NoteUser? noteSharedOwner(Note note, {required String? accountId}) {
  if (note.id.startsWith('local:')) return null;
  final ownerId = note.userId ?? note.user?.id;
  if (ownerId == null || ownerId.isEmpty || ownerId == accountId) return null;
  final name = note.user?.name?.trim();
  if (name == null || name.isEmpty) return null;
  return note.user;
}

/// Opens the access sheet for [note]. The session is captured here, when the
/// user asks, and the sheet fixes the note id with it.
Future<ResourceAccessSnapshot?> shareNote(
  BuildContext context,
  WidgetRef ref,
  Note note,
) {
  final l10n = AppLocalizations.of(context)!;
  final accountId = ref.read(currentUserProvider2)?.id;
  final ownerId = note.userId ?? note.user?.id;
  final isYours = ownerId == null || ownerId.isEmpty || ownerId == accountId;
  final owner = isYours ? null : note.user;
  return ResourceSharingSheet.show(
    context,
    ref,
    kind: ResourceKind.note,
    resourceId: note.id,
    resourceName: note.title.trim().isEmpty ? l10n.untitled : note.title,
    owner: isYours
        ? const WorkspaceAccessOwner(isYou: true)
        : WorkspaceAccessOwner(
            name: owner?.name,
            email: owner?.email,
            imageUrl: resolveUserProfileImageUrl(
              ref.read(apiServiceProvider),
              owner?.profileImageUrl,
            ),
          ),
  );
}

/// Builds the shared note context-menu actions.
List<ConduitContextMenuAction> buildNoteContextMenuActions({
  required BuildContext context,
  required WidgetRef ref,
  required Note note,
  required Future<void> Function(Note note) onEdit,
  required Future<void> Function(Note note) onTogglePin,
  required Future<void> Function(Note note) onDelete,
}) {
  final l10n = AppLocalizations.of(context)!;
  final canEdit = canEditNote(ref, note);

  return [
    ConduitContextMenuAction(
      cupertinoIcon: canEdit ? CupertinoIcons.pencil : CupertinoIcons.doc_text,
      materialIcon: canEdit ? Icons.edit_rounded : Icons.description_outlined,
      label: canEdit ? l10n.edit : l10n.libraryNoteOpen,
      onBeforeClose: () => ConduitHaptics.selectionClick(),
      onSelected: () async => onEdit(note),
    ),
    ConduitContextMenuAction(
      cupertinoIcon: CupertinoIcons.doc_on_clipboard,
      materialIcon: Icons.copy_rounded,
      label: l10n.copy,
      onBeforeClose: () => ConduitHaptics.selectionClick(),
      onSelected: () async => copyNoteMarkdown(context, ref, note),
    ),
    ConduitContextMenuAction(
      cupertinoIcon: note.isPinned
          ? CupertinoIcons.pin_slash
          : CupertinoIcons.pin,
      materialIcon: note.isPinned ? UiUtils.unpinIcon : UiUtils.pinIcon,
      label: note.isPinned ? l10n.unpin : l10n.pin,
      onBeforeClose: () => ConduitHaptics.selectionClick(),
      onSelected: () async => onTogglePin(note),
    ),
    if (canShareNote(ref, note))
      ConduitContextMenuAction(
        cupertinoIcon: CupertinoIcons.person_2,
        materialIcon: Icons.group_outlined,
        label: l10n.noteShare,
        onBeforeClose: () => ConduitHaptics.selectionClick(),
        onSelected: () async {
          await shareNote(context, ref, note);
        },
      ),
    if (canEdit)
      ConduitContextMenuAction(
        cupertinoIcon: CupertinoIcons.delete,
        materialIcon: Icons.delete_rounded,
        label: l10n.delete,
        destructive: true,
        onBeforeClose: () => ConduitHaptics.mediumImpact(),
        onSelected: () async => onDelete(note),
      ),
  ];
}

/// Copies a note's Markdown content and shows the shared success feedback.
Future<void> copyNoteMarkdown(
  BuildContext context,
  WidgetRef ref,
  Note note,
) async {
  final l10n = AppLocalizations.of(context)!;
  var markdown = note.markdownContent;
  if (note.hasListPreviewOnly) {
    try {
      final fullNote = await ref.read(noteByIdProvider(note.id).future);
      markdown = fullNote?.markdownContent ?? markdown;
    } catch (_) {
      // Keep the previous copy behavior for transient detail-load failures.
    }
  }

  await Clipboard.setData(ClipboardData(text: markdown));
  if (!context.mounted) return;

  AdaptiveSnackBar.show(
    context,
    message: l10n.noteCopiedToClipboard,
    type: AdaptiveSnackBarType.success,
    duration: const Duration(seconds: 2),
  );
}

/// Confirms and deletes a note through the shared notes provider.
Future<void> confirmAndDeleteNote(
  BuildContext context,
  WidgetRef ref,
  Note note,
) async {
  final l10n = AppLocalizations.of(context)!;
  final confirmed = await ThemedDialogs.confirm(
    context,
    title: l10n.deleteNoteTitle,
    message: l10n.deleteNoteMessage(
      note.title.isEmpty ? l10n.untitled : note.title,
    ),
    confirmText: l10n.delete,
    isDestructive: true,
  );
  if (!confirmed || !context.mounted) return;

  ConduitHaptics.mediumImpact();
  await ref.read(noteDeleterProvider.notifier).deleteNote(note.id);
}

/// Toggles pin state through the shared notes provider.
Future<void> toggleNotePin(
  BuildContext context,
  WidgetRef ref,
  Note note,
) async {
  final updated = await ref
      .read(notePinTogglerProvider.notifier)
      .togglePin(note);
  if (updated == null || !context.mounted) {
    return;
  }

  ConduitHaptics.selectionClick();
}
