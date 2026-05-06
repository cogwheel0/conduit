import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:conduit/core/models/note.dart';
import 'package:conduit/core/services/haptic_service.dart';
import 'package:conduit/features/notes/providers/notes_providers.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/utils/conversation_context_menu.dart';
import 'package:conduit/shared/utils/ui_utils.dart';
import 'package:conduit/shared/widgets/themed_dialogs.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Builds the shared note context-menu actions.
List<ConduitContextMenuAction> buildNoteContextMenuActions({
  required BuildContext context,
  required Note note,
  required Future<void> Function(Note note) onEdit,
  required Future<void> Function(Note note) onTogglePin,
  required Future<void> Function(Note note) onDelete,
}) {
  final l10n = AppLocalizations.of(context)!;

  return [
    ConduitContextMenuAction(
      cupertinoIcon: CupertinoIcons.pencil,
      materialIcon: Icons.edit_rounded,
      label: l10n.edit,
      onBeforeClose: () => ConduitHaptics.selectionClick(),
      onSelected: () async => onEdit(note),
    ),
    ConduitContextMenuAction(
      cupertinoIcon: CupertinoIcons.doc_on_clipboard,
      materialIcon: Icons.copy_rounded,
      label: l10n.copy,
      onBeforeClose: () => ConduitHaptics.selectionClick(),
      onSelected: () async => copyNoteMarkdown(context, note),
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
Future<void> copyNoteMarkdown(BuildContext context, Note note) async {
  final l10n = AppLocalizations.of(context)!;
  await Clipboard.setData(ClipboardData(text: note.markdownContent));
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
