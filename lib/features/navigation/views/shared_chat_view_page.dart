import 'dart:io' show Platform;

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/chat_message.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/adaptive_route_shell.dart';
import '../../../shared/widgets/conduit_loading.dart';
import '../../../shared/widgets/markdown/streaming_markdown_widget.dart';
import '../providers/shared_folders_providers.dart' show sharedChatDetailProvider;

/// Read-only transcript viewer for a chat reached through the "Shared"
/// drawer section (a folder another user shared with the current one).
///
/// Every chat opened from a shared folder belongs to its owner, not the
/// viewer, and the backend only exposes read access for it (see
/// `sharedChatDetailProvider`) — so unlike the normal chat page, this view
/// has no composer, no message actions, and no sync/offline plumbing. It
/// exists specifically so shared-folder chats don't get routed through the
/// owned-chat editing flow, where sending a message would simply fail
/// server-side (the update-chat endpoint requires ownership).
class SharedChatViewPage extends ConsumerWidget {
  const SharedChatViewPage({
    super.key,
    required this.chatId,
    required this.title,
    required this.ownerName,
  });

  final String chatId;
  final String title;
  final String ownerName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = context.conduitTheme;
    final conversationAsync = ref.watch(sharedChatDetailProvider(chatId));
    final l10n = AppLocalizations.of(context)!;

    return AdaptiveRouteShell(
      appBar: AdaptiveAppBar(title: title),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.md,
              vertical: Spacing.sm,
            ),
            color: theme.surfaceContainer,
            child: Row(
              children: [
                Icon(
                  Platform.isIOS
                      ? CupertinoIcons.lock
                      : Icons.lock_outline_rounded,
                  size: IconSize.sm,
                  color: theme.textSecondary,
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Text(
                    l10n.sharedChatReadOnlyNotice(ownerName),
                    style: AppTypography.labelSmallStyle.copyWith(
                      color: theme.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: conversationAsync.when(
              data: (conversation) => ListView.builder(
                padding: const EdgeInsets.all(Spacing.md),
                itemCount: conversation.messages.length,
                itemBuilder: (context, index) =>
                    _MessageBubble(message: conversation.messages[index]),
              ),
              loading: () => ConduitLoading.primary(),
              error: (error, _) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(Spacing.md),
                  child: Text(
                    l10n.failedToLoadChats,
                    style: AppTypography.bodyMediumStyle.copyWith(
                      color: theme.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final isUser = message.role == 'user';

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: Spacing.xs),
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.md,
          vertical: Spacing.sm,
        ),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.8,
        ),
        decoration: BoxDecoration(
          color: isUser
              ? theme.buttonPrimary.withValues(alpha: 0.12)
              : theme.surfaceContainer,
          borderRadius: BorderRadius.circular(AppBorderRadius.md),
        ),
        child: MarkdownWithLoading(content: message.content, isLoading: false),
      ),
    );
  }
}
