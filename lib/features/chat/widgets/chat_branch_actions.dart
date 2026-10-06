import 'dart:async';
import 'dart:io' show Platform;

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/widgets/adaptive_selection_sheet.dart';
import 'package:conduit/shared/widgets/chat_action_button.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/chat/services/chat_branch_service.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../shared/theme/theme_extensions.dart';

/// Whether the stored graph may hold other versions of [message], so that
/// asking it is worth a read.
///
/// An edited message that follows another keeps its versions as `versions`. A
/// first message has no parent to hang siblings from, so the transcript never
/// lists its edits: it is always worth asking, and the graph decides.
bool userMessageMayHaveVersions(ChatMessage message) =>
    message.versions.isNotEmpty ||
    (message.metadata?['parentId']?.toString().trim().isEmpty ?? true);

/// What the user is told when a branch operation did not happen.
String chatBranchFailureMessage(
  AppLocalizations l10n,
  ChatBranchFailure failure,
) {
  switch (failure) {
    case ChatBranchFailure.responseRunning:
    case ChatBranchFailure.forkConflict:
      return l10n.chatBranchWaitForResponse;
    case ChatBranchFailure.unavailable:
      return l10n.chatBranchUnavailable;
    case ChatBranchFailure.ownerChanged:
      return l10n.chatBranchOwnerChanged;
    case ChatBranchFailure.messageNotFound:
    case ChatBranchFailure.notAnAlternative:
      return l10n.chatBranchMessageMissing;
    case ChatBranchFailure.offline:
      return l10n.chatForkOffline;
    case ChatBranchFailure.forkForbidden:
      return l10n.chatForkForbidden;
    case ChatBranchFailure.forkSourceMissing:
      return l10n.chatForkSourceMissing;
    case ChatBranchFailure.forkUnsupported:
      return l10n.chatForkUnsupported;
    case ChatBranchFailure.forkFailed:
      return l10n.chatForkFailed;
  }
}

/// The chat, account and credentials a branch action was opened for, and what
/// is needed to report its outcome, captured in one synchronous step.
///
/// Anything that awaits the user (the version sheet) must capture before that
/// first await and carry this through: the active chat and account can change
/// while it is open, and chats forked from each other share message ids, so
/// reading either afterwards would aim the choice at the replacement chat.
///
/// The pager that asked is usually replaced the moment the transcript follows
/// the new branch, so nothing here keeps a widget `ref`: the result is reported
/// through the navigator's own context, which outlives the row.
class _ChatBranchOpening {
  const _ChatBranchOpening({
    required this.container,
    required this.conversation,
    required this.owner,
    required this.l10n,
    required this.report,
  });

  final ProviderContainer container;
  final Conversation conversation;
  final ChatMutationOwnerToken owner;
  final AppLocalizations l10n;
  final BuildContext report;

  static _ChatBranchOpening? capture(BuildContext context) {
    final container = ProviderScope.containerOf(context, listen: false);
    final conversation = container.read(activeConversationProvider);
    if (conversation == null) return null;
    return _ChatBranchOpening(
      container: container,
      conversation: conversation,
      owner: captureChatMutationOwner(container, conversation),
      l10n: AppLocalizations.of(context)!,
      report: Navigator.of(context, rootNavigator: true).context,
    );
  }
}

/// Makes [alternativeId] the active branch of the open chat, in place of the
/// displayed message [displayedMessageId], and reports the outcome.
///
/// The open chat is captured here, synchronously, which is only right for a
/// caller that acts on a tap. A caller that awaits first captures its own
/// [_ChatBranchOpening] before that await and uses [_continueFromOpening].
Future<void> continueFromChatBranch(
  BuildContext context, {
  required String displayedMessageId,
  required String alternativeId,
}) async {
  final opening = _ChatBranchOpening.capture(context);
  if (opening == null) return;
  await _continueFromOpening(
    opening,
    displayedMessageId: displayedMessageId,
    alternativeId: alternativeId,
  );
}

/// Applies the choice to [opening]'s chat, never to whichever chat is active by
/// now. A server, account or session change since the capture is refused by the
/// controller without writing.
Future<void> _continueFromOpening(
  _ChatBranchOpening opening, {
  required String displayedMessageId,
  required String alternativeId,
}) async {
  final container = opening.container;
  final conversation = opening.conversation;
  final l10n = opening.l10n;
  final report = opening.report;
  try {
    final siblings = await container.read(
      chatBranchSiblingsProvider((
        chatId: conversation.id,
        messageId: displayedMessageId,
      )).future,
    );
    await selectChatBranch(
      container,
      conversation: conversation,
      messageId: alternativeId,
      alternativeTo: displayedMessageId,
      owner: opening.owner,
    );
    final position = siblings?.ids.indexOf(alternativeId) ?? -1;
    if (siblings != null && position >= 0 && report.mounted) {
      AdaptiveSnackBar.show(
        report,
        message: l10n.chatBranchSelectedNotice(
          position + 1,
          siblings.ids.length,
        ),
        duration: const Duration(seconds: 3),
      );
    }
  } on ChatBranchException catch (error) {
    if (!report.mounted) return;
    AdaptiveSnackBar.show(
      report,
      message: chatBranchFailureMessage(l10n, error.reason),
      type: AdaptiveSnackBarType.error,
    );
  }
}

/// Forks the open chat at [messageId] on the server and opens the new chat,
/// reporting a refusal in plain words. Nothing is cloned on failure.
Future<void> forkChatFromMessage(
  BuildContext context, {
  required String messageId,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final conversation = container.read(activeConversationProvider);
  if (conversation == null) return;
  final l10n = AppLocalizations.of(context)!;
  final report = Navigator.of(context, rootNavigator: true).context;
  final owner = captureChatMutationOwner(container, conversation);
  try {
    await forkChatAtMessage(
      container,
      conversation: conversation,
      messageId: messageId,
      owner: owner,
    );
  } on ChatBranchException catch (error) {
    if (!report.mounted) return;
    AdaptiveSnackBar.show(
      report,
      message: chatBranchFailureMessage(l10n, error.reason),
      type: AdaptiveSnackBarType.error,
    );
  }
}

/// Lists a message's versions and continues from the one the user picks.
///
/// The choice belongs to the chat and account the sheet was opened for, however
/// long it stays open and wherever the user has gone by the time they pick.
Future<void> showChatBranchSheet(
  BuildContext context, {
  required ChatBranchSiblings siblings,
}) async {
  final opening = _ChatBranchOpening.capture(context);
  if (opening == null) return;
  final l10n = opening.l10n;
  final picked = await showAdaptiveSelectionSheet<String>(
    context: context,
    builder: (sheetContext) => AdaptiveSelectionSheet(
      title: l10n.chatBranchSheetTitle,
      description: l10n.chatBranchSheetDescription,
      itemCount: siblings.ids.length,
      initialChildSize: 0.42,
      minChildSize: 0.3,
      maxChildSize: 0.68,
      itemBuilder: (context, index) {
        final id = siblings.ids[index];
        final isCurrent = id == siblings.messageId;
        return AdaptiveSelectionTile(
          key: ValueKey<String>('chat-branch-version-$id'),
          title: l10n.chatBranchVersionTitle(index + 1),
          subtitle: isCurrent ? l10n.chatBranchVersionCurrent : null,
          selected: isCurrent,
          onTap: () => Navigator.of(sheetContext).pop(id),
        );
      },
    ),
  );
  if (picked == null || picked == siblings.messageId) return;
  await _continueFromOpening(
    opening,
    displayedMessageId: siblings.messageId,
    alternativeId: picked,
  );
}

/// `‹ 2/3 ›` under an edited user message: steps through its versions, and its
/// label opens the full list. Each step continues the chat from that version
/// with its own replies.
///
/// Nothing is shown unless the Advanced branch controls are on and the stored
/// graph really holds more than one version, so a message with no real
/// alternatives (or one the server never stored) offers nothing.
class ChatBranchSwitcher extends ConsumerStatefulWidget {
  const ChatBranchSwitcher({super.key, required this.messageId});

  /// The displayed message's real id.
  final String messageId;

  @override
  ConsumerState<ChatBranchSwitcher> createState() => _ChatBranchSwitcherState();
}

class _ChatBranchSwitcherState extends ConsumerState<ChatBranchSwitcher> {
  bool _busy = false;

  Future<void> _step(String alternativeId) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await continueFromChatBranch(
        context,
        displayedMessageId: widget.messageId,
        alternativeId: alternativeId,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(chatBranchControlsProvider)) return const SizedBox.shrink();
    final chatId = ref.watch(activeConversationProvider.select((c) => c?.id));
    if (chatId == null) return const SizedBox.shrink();
    final siblings = ref
        .watch(
          chatBranchSiblingsProvider((
            chatId: chatId,
            messageId: widget.messageId,
          )),
        )
        .asData
        ?.value;
    if (siblings == null || siblings.index < 0) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final position = siblings.index + 1;
    final total = siblings.ids.length;
    final previous = siblings.index > 0
        ? siblings.ids[siblings.index - 1]
        : null;
    final next = siblings.index < total - 1
        ? siblings.ids[siblings.index + 1]
        : null;

    return Align(
      alignment: Alignment.centerRight,
      child: Row(
        key: const ValueKey<String>('chat-branch-switcher'),
        mainAxisSize: MainAxisSize.min,
        children: [
          ChatActionButton(
            icon: Platform.isIOS
                ? CupertinoIcons.chevron_left
                : Icons.chevron_left,
            label: l10n.previousLabel,
            onTap: previous == null || _busy ? null : () => _step(previous),
          ),
          Semantics(
            button: true,
            label: l10n.chatBranchSwitcherSemantics(position, total),
            excludeSemantics: true,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _busy
                  ? null
                  : () => unawaited(
                      showChatBranchSheet(context, siblings: siblings),
                    ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
                child: Text(
                  '$position/$total',
                  style: AppTypography.small.copyWith(
                    color: theme.textPrimary.withValues(alpha: 0.8),
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          ),
          ChatActionButton(
            icon: Platform.isIOS
                ? CupertinoIcons.chevron_right
                : Icons.chevron_right,
            label: l10n.nextLabel,
            onTap: next == null || _busy ? null : () => _step(next),
          ),
        ],
      ),
    );
  }
}
