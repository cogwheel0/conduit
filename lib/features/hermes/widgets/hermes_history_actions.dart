import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show chatMessagesProvider, isChatStreamingProvider;
import 'package:conduit_core/features/chat/services/chat_message_actions.dart'
    show undoLastHermesTurn;
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit_core/providers/app_providers.dart'
    show activeConversationProvider;
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/utils/ui_utils.dart';
import 'hermes_session_tile.dart' show openHermesSession;

/// What a Hermes reply's menu may offer for the chat's history.
typedef HermesReplyHistoryActions = ({bool branch, bool undo});

/// Whether reply [messageId] of the active chat can start a branch, and
/// whether it can undo the chat's last turn (only the last reply, and only
/// on the Desktop Gateway, whose session keeps the transcript). Neither
/// while a reply is streaming.
HermesReplyHistoryActions watchHermesReplyHistoryActions(
  WidgetRef ref,
  String messageId,
) {
  final hermesChat = ref.watch(
    activeConversationProvider.select(
      (conversation) =>
          isNativeHermesConversation(conversation) &&
          conversation!.metadata['hermesSessionId'] is String,
    ),
  );
  if (!hermesChat || messageId.isEmpty || ref.watch(isChatStreamingProvider)) {
    return (branch: false, undo: false);
  }
  final isLast = ref.watch(
    chatMessagesProvider.select(
      (messages) => messages.lastOrNull?.id == messageId,
    ),
  );
  final desktop =
      ref.watch(hermesApiServiceProvider) is HermesDesktopApiService;
  return (branch: true, undo: isLast && desktop);
}

/// Opens a new chat that continues the active Hermes chat from reply
/// [messageId]: everything up to the end of that reply's turn.
Future<void> branchHermesChatFromMessage(
  BuildContext context,
  WidgetRef ref,
  String messageId,
) async {
  final l10n = AppLocalizations.of(context)!;
  final report = Navigator.of(context, rootNavigator: true).context;
  final conversation = ref.read(activeConversationProvider);
  final sessionId = conversation?.metadata['hermesSessionId'];
  if (conversation == null || sessionId is! String) return;
  final messages = ref.read(chatMessagesProvider);
  final index = messages.indexWhere((message) => message.id == messageId);
  if (index < 0) return;
  try {
    final branch = await ref
        .read(hermesSessionsProvider.notifier)
        .branchFromMessage(
          sessionId: sessionId,
          title: conversation.title,
          messages: messages,
          index: index,
        );
    if (branch == null || !context.mounted) return;
    await openHermesSession(
      context,
      ref,
      branch.session,
      transcript: branch.transcript,
    );
  } catch (error) {
    DebugLogger.error(
      'branch-from-message-failed',
      scope: 'hermes/sessions',
      data: {'errorType': error.runtimeType.toString()},
    );
    if (report.mounted) {
      UiUtils.showMessage(report, l10n.hermesBranchFailed, isError: true);
    }
  }
}

/// Undoes the active Hermes chat's last turn, in the chat and on the server.
Future<void> undoLastHermesTurnInChat(
  BuildContext context,
  WidgetRef ref,
) async {
  final l10n = AppLocalizations.of(context)!;
  // The reply this was chosen from leaves the chat with the turn.
  final report = Navigator.of(context, rootNavigator: true).context;
  try {
    final undone = await undoLastHermesTurn(ref);
    if (undone && report.mounted) {
      UiUtils.showMessage(report, l10n.hermesUndoLastTurnDone);
    }
  } catch (error) {
    DebugLogger.error(
      'undo-last-turn-failed',
      scope: 'hermes/sessions',
      data: {'errorType': error.runtimeType.toString()},
    );
    if (report.mounted) {
      UiUtils.showMessage(
        report,
        l10n.hermesUndoLastTurnFailed,
        isError: true,
      );
    }
  }
}
