import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/channel_message.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/api_service.dart';
import '../../../core/utils/model_icon_utils.dart';
import '../../../core/utils/user_avatar_utils.dart'
    show resolveUserProfileImageUrl;
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/model_avatar.dart';
import '../../../shared/widgets/user_avatar.dart';
import '../../chat/widgets/modern_chat_input.dart';
import '../providers/channel_providers.dart';
import '../utils/mention_utils.dart';

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
    this.overflowButtonBuilder,
  });

  /// The channel containing the thread.
  final String channelId;

  /// The root message that started this thread.
  final ChannelMessage parentMessage;

  /// Called when the user closes the panel.
  final VoidCallback onClose;

  /// Builder for the overflow (+) attachment button.
  final Widget Function(double size)? overflowButtonBuilder;

  @override
  ConsumerState<ThreadPanel> createState() => _ThreadPanelState();
}

class _ThreadPanelState extends ConsumerState<ThreadPanel> {
  bool _isSending = false;

  Future<void> _sendReply(String text) async {
    final content = text.trim();
    if (content.isEmpty || _isSending) return;

    final api = ref.read(apiServiceProvider);
    if (api == null) return;

    setState(() => _isSending = true);
    try {
      final json = await api.postChannelMessage(
        widget.channelId,
        content: content,
        parentId: widget.parentMessage.id,
      );
      if (!mounted) return;
      final message = ChannelMessage.fromJson(json);
      ref
          .read(
            threadMessagesProvider(
              widget.channelId,
              widget.parentMessage.id,
            ).notifier,
          )
          .prependMessage(message);
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
    final api = ref.read(apiServiceProvider);
    final threadAsync = ref.watch(
      threadMessagesProvider(widget.channelId, widget.parentMessage.id),
    );

    return Container(
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
          ),
          const Divider(height: 1),
          Expanded(
            child: threadAsync.when(
              data: (messages) => _ThreadReplies(
                messages: messages
                    .where((m) => m.id != widget.parentMessage.id)
                    .toList(),
                api: api,
                theme: theme,
              ),
              loading: () => const Center(child: CircularProgressIndicator()),
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
          RepaintBoundary(
            child: Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
              ),
              child: ModernChatInput(
                onSendMessage: _sendReply,
                placeholder: 'Reply...',
                overflowButtonBuilder: widget.overflowButtonBuilder,
              ),
            ),
          ),
        ],
      ),
    );
  }
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
            'Thread',
            style: AppTypography.titleMediumStyle.copyWith(
              color: theme.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          IconButton(
            icon: Icon(Icons.close, color: theme.textSecondary, size: 20),
            onPressed: onClose,
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
  });

  final ChannelMessage message;
  final ApiService? api;
  final ConduitThemeExtension theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(Spacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildAvatar(),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  messageDisplayName(message),
                  style: AppTypography.bodySmallStyle.copyWith(
                    color: theme.textSecondary,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.1,
                  ),
                ),
                const SizedBox(height: Spacing.xxs),
                RichText(
                  text: buildMentionSpan(
                    content: message.content,
                    baseStyle: AppTypography.chatMessageStyle.copyWith(
                      color: theme.textPrimary,
                    ),
                    mentionColor: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatar() {
    if (isModelMessage(message)) {
      final modelId = message.meta!['model_id'] as String?;
      return ModelAvatar(
        size: 28,
        imageUrl: buildModelAvatarUrl(api, modelId),
        label: messageDisplayName(message),
      );
    }
    return UserAvatar(
      size: 28,
      imageUrl: resolveUserProfileImageUrl(api, message.user?.profileImageUrl),
      fallbackText: message.userName,
    );
  }
}

/// Scrollable list of thread replies.
class _ThreadReplies extends StatelessWidget {
  const _ThreadReplies({required this.messages, this.api, required this.theme});

  final List<ChannelMessage> messages;
  final ApiService? api;
  final ConduitThemeExtension theme;

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
    return ListView.builder(
      reverse: false,
      padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final message = messages[index];
        return Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.md,
            vertical: Spacing.xs,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isModelMessage(message))
                ModelAvatar(
                  size: 24,
                  imageUrl: buildModelAvatarUrl(
                    api,
                    message.meta?['model_id'] as String?,
                  ),
                  label: messageDisplayName(message),
                )
              else
                UserAvatar(
                  size: 24,
                  imageUrl: resolveUserProfileImageUrl(
                    api,
                    message.user?.profileImageUrl,
                  ),
                  fallbackText: message.userName,
                ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      messageDisplayName(message),
                      style: AppTypography.bodySmallStyle.copyWith(
                        color: theme.textSecondary,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.1,
                      ),
                    ),
                    const SizedBox(height: 2),
                    RichText(
                      text: buildMentionSpan(
                        content: message.content,
                        baseStyle: AppTypography.chatMessageStyle.copyWith(
                          color: theme.textPrimary,
                        ),
                        mentionColor: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
