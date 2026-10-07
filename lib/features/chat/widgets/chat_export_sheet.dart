import 'dart:async';

import 'package:conduit/features/chat/services/chat_backup_files.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
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

/// An export read from the chat's stored copy, ready to hand to the share
/// sheet.
typedef _PreparedChatExport = ({
  String fileName,
  String text,
  String mimeType,
  bool hasUnsyncedChanges,
});

/// The export could not be read.
final class _ChatExportFailed {
  const _ChatExportFailed();
}

/// Lets the user export [conversation] and hands the file to the share sheet.
///
/// The chat, server and account are captured now, before the choice sheet
/// opens, so a different chat or account selected meanwhile cannot change what
/// is exported. The JSON is the chat's complete stored graph, off-window
/// branches and unsent edits included; the Markdown is the active branch only
/// and says so.
///
/// The sheet stays open, showing progress on the chosen row, while the export
/// is read; closing it then drops the export.
Future<void> showChatExportSheet(
  BuildContext context,
  WidgetRef ref,
  Conversation conversation,
) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final owner = captureChatMutationOwner(container, conversation);
  final files = container.read(chatBackupFilesProvider);

  Future<_PreparedChatExport> prepare(ChatExportKind kind) async {
    final now = DateTime.now();
    switch (kind) {
      case ChatExportKind.backup:
        final export = await exportOpenWebUiChat(
          container,
          conversation: conversation,
          owner: owner,
        );
        return (
          fileName: chatExportFileName(
            export.title.isEmpty ? conversation.title : export.title,
            now,
            'json',
          ),
          text: export.toJson(),
          mimeType: 'application/json',
          hasUnsyncedChanges: export.hasUnsyncedChanges,
        );
      case ChatExportKind.transcript:
        final markdown = await exportOpenWebUiChatTranscript(
          container,
          conversation: conversation,
          owner: owner,
        );
        return (
          fileName: chatExportFileName(conversation.title, now, 'md'),
          text: markdown,
          mimeType: 'text/markdown',
          hasUnsyncedChanges: false,
        );
    }
  }

  final outcome = await ThemedSheets.showCustom<Object>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (_) => _ChatExportSheet(prepare: prepare),
  );
  if (outcome == null || !context.mounted) return;
  final l10n = AppLocalizations.of(context)!;
  final renderObject = context.findRenderObject();
  final origin = renderObject is RenderBox && renderObject.hasSize
      ? renderObject.localToGlobal(Offset.zero) & renderObject.size
      : null;
  // Reported through the navigator, which outlives the page if the user has
  // moved on by the time the file is staged.
  final report = Navigator.of(context, rootNavigator: true).context;

  void fail() {
    if (!report.mounted) return;
    AdaptiveSnackBar.show(
      report,
      message: l10n.chatExportFailed,
      type: AdaptiveSnackBarType.error,
    );
  }

  if (outcome is! _PreparedChatExport) {
    fail();
    return;
  }

  // Run by the file adapter once the file is staged, right before the share
  // sheet opens: a different account or server by then gets nothing.
  void stillTheSameOwner() => requireOpenWebUiChatExportOwner(container, owner);

  try {
    await files.deliverText(
      outcome.fileName,
      outcome.text,
      mimeType: outcome.mimeType,
      origin: origin,
      checkpoint: stillTheSameOwner,
    );
    if (outcome.hasUnsyncedChanges && report.mounted) {
      AdaptiveSnackBar.show(report, message: l10n.chatExportUnsentNote);
    }
  } catch (_) {
    fail();
  }
}

class _ChatExportSheet extends StatefulWidget {
  const _ChatExportSheet({required this.prepare});

  final Future<_PreparedChatExport> Function(ChatExportKind kind) prepare;

  @override
  State<_ChatExportSheet> createState() => _ChatExportSheetState();
}

class _ChatExportSheetState extends State<_ChatExportSheet> {
  /// The export being read, while it is.
  ChatExportKind? _preparing;

  Future<void> _choose(ChatExportKind kind) async {
    if (_preparing != null) return;
    setState(() => _preparing = kind);
    Object outcome;
    try {
      outcome = await widget.prepare(kind);
    } catch (_) {
      outcome = const _ChatExportFailed();
    }
    if (!mounted) return;
    Navigator.of(context).pop(outcome);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;

    Widget row({
      required Key key,
      required ChatExportKind kind,
      required String title,
      required String subtitle,
    }) {
      final preparing = _preparing == kind;
      return UtilityRow(
        key: key,
        title: title,
        subtitle: preparing ? l10n.chatExportPreparing : subtitle,
        enabled: _preparing == null || preparing,
        trailing: preparing
            ? const ConduitLoadingIndicator(
                size: IconSize.small,
                isCompact: true,
              )
            : null,
        onTap: _preparing == null ? () => unawaited(_choose(kind)) : null,
      );
    }

    return ConduitModalSheetSurface(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    l10n.chatExportAction,
                    style: theme.headingSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              SheetCloseButton(
                tooltip: l10n.close,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: Spacing.md),
          InsetGroupedList(
            children: [
              row(
                key: const Key('chat-export-backup'),
                kind: ChatExportKind.backup,
                title: l10n.chatExportJson,
                subtitle: l10n.chatExportJsonDescription,
              ),
              row(
                key: const Key('chat-export-transcript'),
                kind: ChatExportKind.transcript,
                title: l10n.chatExportMarkdown,
                subtitle: l10n.chatExportMarkdownDescription,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
