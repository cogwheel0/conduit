import 'dart:async';

import 'package:conduit/features/chat/services/chat_backup_files.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/sheet_handle.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';
import 'package:conduit/shared/widgets/utility_components.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

/// What the user wants the open chat exported as.
enum ChatExportKind {
  /// The whole chat, every branch, as the JSON Open WebUI imports.
  backup,

  /// The active branch as readable Markdown. Never a backup.
  transcript,
}

/// Lets the user export [conversation] and hands the file to the share sheet.
///
/// The chat, server and account are captured now, before the choice sheet
/// opens, so a different chat or account selected meanwhile cannot change what
/// is exported. The JSON is the chat's complete stored graph, off-window
/// branches and unsent edits included; the Markdown is the active branch only
/// and says so.
Future<void> showChatExportSheet(
  BuildContext context,
  WidgetRef ref,
  Conversation conversation,
) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final owner = captureChatMutationOwner(container, conversation);
  final files = container.read(chatBackupFilesProvider);

  final kind = await ThemedSheets.showCustom<ChatExportKind>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (_) => const _ChatExportSheet(),
  );
  if (kind == null || !context.mounted) return;
  final l10n = AppLocalizations.of(context)!;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final renderObject = context.findRenderObject();
  final origin = renderObject is RenderBox && renderObject.hasSize
      ? renderObject.localToGlobal(Offset.zero) & renderObject.size
      : null;

  void say(String message) {
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  }

  // Run by the file adapter once the file is staged, right before the share
  // sheet opens: a different account or server by then gets nothing.
  void stillTheSameOwner() => requireOpenWebUiChatExportOwner(container, owner);

  try {
    final now = DateTime.now();
    switch (kind) {
      case ChatExportKind.backup:
        final export = await exportOpenWebUiChat(
          container,
          conversation: conversation,
          owner: owner,
        );
        await files.deliverText(
          chatExportFileName(
            export.title.isEmpty ? conversation.title : export.title,
            now,
            'json',
          ),
          export.toJson(),
          mimeType: 'application/json',
          origin: origin,
          checkpoint: stillTheSameOwner,
        );
        if (export.hasUnsyncedChanges) say(l10n.chatExportUnsentNote);
      case ChatExportKind.transcript:
        final markdown = await exportOpenWebUiChatTranscript(
          container,
          conversation: conversation,
          owner: owner,
        );
        await files.deliverText(
          chatExportFileName(conversation.title, now, 'md'),
          markdown,
          mimeType: 'text/markdown',
          origin: origin,
          checkpoint: stillTheSameOwner,
        );
    }
  } catch (_) {
    say(l10n.chatExportFailed);
  }
}

class _ChatExportSheet extends StatelessWidget {
  const _ChatExportSheet();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.surfaceBackground,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppBorderRadius.xl),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Spacing.lg,
          0,
          Spacing.lg,
          Spacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHandle(),
            Text(
              l10n.chatExportAction,
              style: AppTypography.headlineSmallStyle.copyWith(
                color: theme.textPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: Spacing.md),
            InsetGroupedList(
              children: [
                UtilityRow(
                  key: const Key('chat-export-backup'),
                  title: l10n.chatExportJson,
                  subtitle: l10n.chatExportJsonDescription,
                  onTap: () => Navigator.of(context).pop(ChatExportKind.backup),
                ),
                UtilityRow(
                  key: const Key('chat-export-transcript'),
                  title: l10n.chatExportMarkdown,
                  subtitle: l10n.chatExportMarkdownDescription,
                  onTap: () =>
                      Navigator.of(context).pop(ChatExportKind.transcript),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
