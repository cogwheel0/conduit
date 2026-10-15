import 'dart:async';
import 'dart:developer' as developer;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit/l10n/app_localizations.dart';

import 'package:conduit_core/models/channel_message.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';

import '../../../core/utils/model_icon_utils.dart';

import 'package:conduit_core/utils/user_avatar_utils.dart'
    show resolveUserProfileImageUrl;

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/chrome_gradient_fade.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/measure_size.dart';
import '../../../shared/widgets/model_avatar.dart';
import '../../../shared/widgets/user_avatar.dart';
import '../../chat/widgets/modern_chat_input.dart';

import 'package:conduit_core/features/channels/providers/channel_app_replies.dart';
import 'package:conduit_core/features/channels/providers/channel_providers.dart';

import '../utils/channel_request_owner.dart';
import '../utils/mention_utils.dart';
import 'channel_app_content.dart';
import 'channel_message_content.dart';
import 'channel_message_reactions.dart';

/// Side panel (tablet) or bottom sheet (mobile) for
/// viewing and replying to a message thread.
class ThreadPanel extends ConsumerStatefulWidget {
  /// Creates a thread panel for the given channel and
  /// parent message.
  const ThreadPanel({
    super.key,
    required this.channelId,
    required this.parentMessage,
    required this.onClose,
    required this.onReactionTap,
    this.overflowButtonBuilder,
  });

  /// The channel containing the thread.
  final String channelId;

  /// The root message that started this thread.
  final ChannelMessage parentMessage;

  /// Called when the user closes the panel.
  final VoidCallback onClose;

  /// Toggles the signed-in user's [emoji] reaction on a reply.
  final void Function(ChannelMessage reply, String emoji) onReactionTap;

  /// Builder for the overflow (+) attachment button.
  final Widget Function(double size)? overflowButtonBuilder;

  @override
  ConsumerState<ThreadPanel> createState() => _ThreadPanelState();
}

class _ThreadPanelState extends ConsumerState<ThreadPanel> {
  double _composerHeight = 0;
  bool _isSending = false;

  Future<void> _sendReply(String text) async {
    final content = text.trim();
    if (content.isEmpty || _isSending) return;

    final api = ref.read(apiServiceProvider);
    if (api == null) return;
    final authSessionEpoch = ref.read(openWebUiAuthSessionEpochProvider);
    final channelId = widget.channelId;
    final parentMessageId = widget.parentMessage.id;

    setState(() => _isSending = true);
    try {
      final json = await api.postChannelMessage(
        channelId,
        content: content,
        parentId: parentMessageId,
      );
      if (!mounted ||
          !isChannelRequestOwnerCurrent(
            ref: ref,
            api: api,
            authSessionEpoch: authSessionEpoch,
          ) ||
          widget.channelId != channelId ||
          widget.parentMessage.id != parentMessageId) {
        return;
      }
      final me = ref.read(currentUserProvider).value;
      final posted = ChannelMessage.fromJson(json);
      final replies = ref.read(
        threadMessagesProvider(channelId, parentMessageId).notifier,
      );
      replies.prependMessage(
        me == null ? posted : posted.withSenderIfMissing(me),
      );
      if (me == null) {
        // The user is still loading. Do not hold the reply back for it.
        unawaited(
          ref.read(currentUserProvider.future).then<void>((user) {
            if (user == null ||
                !mounted ||
                !isChannelRequestOwnerCurrent(
                  ref: ref,
                  api: api,
                  authSessionEpoch: authSessionEpoch,
                ) ||
                widget.channelId != channelId ||
                widget.parentMessage.id != parentMessageId) {
              return;
            }
            try {
              replies.fillSender(posted.id, user);
            } on StateError {
              // The thread was disposed while the user loaded.
            }
          }, onError: (_) {}),
        );
      }
    } catch (e, st) {
      developer.log(
        'Failed to send thread reply',
        name: 'ThreadPanel',
        error: e,
        stackTrace: st,
      );
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final api = ref.read(apiServiceProvider);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final threadAsync = ref.watch(
      threadMessagesProvider(widget.channelId, widget.parentMessage.id),
    );
    // Private app replies in this thread, as Open WebUI's thread view keeps
    // them apart from the channel's.
    final appRepliesProvider = channelAppRepliesProvider(
      widget.channelId,
      widget.parentMessage.id,
    );
    final appReplies = ref.watch(appRepliesProvider);
    final appReplyActions = _AppReplyActions(
      channelId: widget.channelId,
      parentId: widget.parentMessage.id,
      replies: appReplies.values.toList(),
      onReply: ref.read(appRepliesProvider.notifier).add,
      onDismiss: ref.read(appRepliesProvider.notifier).dismiss,
    );

    // The phone sheet can be a native one with no Material behind it, and the
    // reaction chips need one.
    return Material(
      type: MaterialType.transparency,
      child: Container(
        decoration: BoxDecoration(
          color: theme.surfaceBackground,
          border: Border(left: BorderSide(color: theme.dividerColor)),
        ),
        child: Column(
          children: [
            _ThreadHeader(theme: theme, onClose: widget.onClose),
            const Divider(height: 1),
            _ParentMessageTile(
              message: widget.parentMessage,
              api: api,
              theme: theme,
              appReplies: appReplyActions,
            ),
            const Divider(height: 1),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: threadAsync.when(
                      data: (messages) => _ThreadReplies(
                        messages: messages
                            .where((m) => m.id != widget.parentMessage.id)
                            .toList(),
                        api: api,
                        theme: theme,
                        currentUserId: ref.watch(currentUserProvider).value?.id,
                        onReactionTap: widget.onReactionTap,
                        appReplies: appReplyActions,
                        bottomPadding: _composerHeight + bottomInset,
                      ),
                      loading: () =>
                          const Center(child: CircularProgressIndicator()),
                      error: (e, _) => Center(
                        child: Text(
                          e.toString(),
                          style: AppTypography.bodyMediumStyle.copyWith(
                            color: theme.error,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: bottomInset,
                    child: ConduitChromeGradientFade.bottom(
                      contentHeight: (_composerHeight - Spacing.xl).clamp(
                        0.0,
                        double.infinity,
                      ),
                      fadeHeight: Spacing.md,
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: bottomInset,
                    child: RepaintBoundary(
                      child: MeasureSize(
                        onChange: (size) {
                          if (!mounted) return;
                          setState(() => _composerHeight = size.height);
                        },
                        child: SafeArea(
                          top: false,
                          left: false,
                          right: false,
                          minimum: const EdgeInsets.only(bottom: Spacing.sm),
                          child: ModernChatInput(
                            onSendMessage: _sendReply,
                            placeholder: l10n.replyInputPlaceholder,
                            overflowButtonBuilder: widget.overflowButtonBuilder,
                            bottomPadding: 0,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The private app replies of a thread and how to add or dismiss one.
class _AppReplyActions {
  const _AppReplyActions({
    required this.channelId,
    required this.parentId,
    required this.replies,
    required this.onReply,
    required this.onDismiss,
  });

  final String channelId;
  final String parentId;
  final List<AppChannelReplyEvent> replies;
  final ValueChanged<AppChannelReplyEvent> onReply;
  final ValueChanged<String> onDismiss;

  /// The app cards of [message], when an app posted it.
  Widget cardsOf(ChannelMessage message) => message.isAppMessage
      ? ChannelAppMessageCards(
          // Rows are reused by position; a button's state stays with its
          // message.
          key: ValueKey(message.id),
          message: message,
          channelId: channelId,
          parentId: parentId,
          onReply: onReply,
        )
      : const SizedBox.shrink();

  /// The private replies shown under [message].
  List<Widget> repliesTo(ChannelMessage message, {double avatarSize = 28}) => [
    for (final reply in replies)
      if (reply.messageId == message.id)
        ChannelPrivateAppReply(
          key: ValueKey<String>('thread-app-reply-${reply.key}'),
          event: reply,
          avatarSize: avatarSize,
          onDismiss: () => onDismiss(reply.key),
        ),
  ];
}

/// The avatar of a thread message's sender: a model, an app or a user.
Widget _senderAvatar(ApiService? api, ChannelMessage message, double size) {
  if (isModelMessage(message)) {
    return ModelAvatar(
      size: size,
      imageUrl: buildModelAvatarUrl(api, message.meta?['model_id'] as String?),
      label: messageDisplayName(message),
    );
  }
  final imageUrl = resolveUserProfileImageUrl(
    api,
    message.user?.profileImageUrl,
  );
  if (message.isAppMessage) {
    return ChannelAppAvatar(size: size, imageUrl: imageUrl);
  }
  return UserAvatar(
    size: size,
    imageUrl: imageUrl,
    fallbackText: message.userName,
  );
}

/// The sender's name, with the "App" label for an app.
Widget _senderName(ConduitThemeExtension theme, ChannelMessage message) {
  final name = Text(
    messageDisplayName(message),
    style: AppTypography.bodySmallStyle.copyWith(
      color: theme.textSecondary,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.1,
    ),
  );
  if (!message.isAppMessage) return name;
  return Row(
    children: [
      Flexible(child: name),
      const SizedBox(width: Spacing.xs),
      const ChannelAppBadge(),
    ],
  );
}

/// Header row with "Thread" title and a close button.
class _ThreadHeader extends StatelessWidget {
  const _ThreadHeader({required this.theme, required this.onClose});

  final ConduitThemeExtension theme;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(Spacing.md),
      child: Row(
        children: [
          Text(
            AppLocalizations.of(context)!.thread,
            style: AppTypography.titleMediumStyle.copyWith(
              color: theme.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          ConduitIconButton(
            icon: Icons.close,
            iconColor: theme.textSecondary,
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            onPressed: onClose,
            isCompact: true,
          ),
        ],
      ),
    );
  }
}

/// Displays the parent (root) message at the top of the
/// thread panel.
class _ParentMessageTile extends StatelessWidget {
  const _ParentMessageTile({
    required this.message,
    this.api,
    required this.theme,
    required this.appReplies,
  });

  final ChannelMessage message;
  final ApiService? api;
  final ConduitThemeExtension theme;
  final _AppReplyActions appReplies;

  @override
  Widget build(BuildContext context) {
    final tile = Padding(
      padding: const EdgeInsets.all(Spacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _senderAvatar(api, message, 28),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _senderName(theme, message),
                const SizedBox(height: Spacing.xxs),
                ChannelMessageContent(
                  content: message.content,
                  stateScopeId: 'channel-thread-parent:${message.id}',
                ),
                ChannelMessageAttachments(files: message.data?['files']),
                appReplies.cardsOf(message),
              ],
            ),
          ),
        ],
      ),
    );
    final replies = appReplies.repliesTo(message);
    if (replies.isEmpty) return tile;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [tile, ...replies],
    );
  }
}

/// Scrollable list of thread replies.
class _ThreadReplies extends StatelessWidget {
  const _ThreadReplies({
    required this.messages,
    this.api,
    required this.theme,
    required this.currentUserId,
    required this.onReactionTap,
    required this.appReplies,
    this.bottomPadding = 0,
  });

  final List<ChannelMessage> messages;
  final ApiService? api;
  final ConduitThemeExtension theme;
  final String? currentUserId;
  final void Function(ChannelMessage reply, String emoji) onReactionTap;
  final _AppReplyActions appReplies;
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) {
      return Center(
        child: Text(
          'No replies yet',
          style: AppTypography.bodyMediumStyle.copyWith(
            color: theme.textSecondary,
          ),
        ),
      );
    }
    // Rows are keyed by message, so what a row holds moves with it.
    final indexById = {
      for (final (index, message) in messages.indexed) message.id: index,
    };
    return ListView.builder(
      reverse: false,
      padding: EdgeInsets.fromLTRB(
        0,
        Spacing.sm,
        0,
        Spacing.sm + bottomPadding,
      ),
      itemCount: messages.length,
      findChildIndexCallback: (key) =>
          key is ValueKey<String> ? indexById[key.value] : null,
      itemBuilder: (context, index) {
        final message = messages[index];
        final row = Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.md,
            vertical: Spacing.xs,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _senderAvatar(api, message, 24),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _senderName(theme, message),
                    const SizedBox(height: 2),
                    ChannelMessageContent(
                      content: message.content,
                      stateScopeId: 'channel-thread:${message.id}',
                    ),
                    ChannelMessageAttachments(files: message.data?['files']),
                    appReplies.cardsOf(message),
                    if (message.reactions.isNotEmpty)
                      ChannelMessageReactions(
                        reactions: message.reactions,
                        currentUserId: currentUserId,
                        onReactionTap: (emoji) => onReactionTap(message, emoji),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
        final replies = appReplies.repliesTo(message, avatarSize: 24);
        return KeyedSubtree(
          key: ValueKey<String>(message.id),
          child: replies.isEmpty
              ? row
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [row, ...replies],
                ),
        );
      },
    );
  }
}
