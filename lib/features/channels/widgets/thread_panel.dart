import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/channel_message.dart';
import '../../../core/providers/app_providers.dart';
import '../../../shared/theme/theme_extensions.dart';
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
  });

  /// The channel containing the thread.
  final String channelId;

  /// The root message that started this thread.
  final ChannelMessage parentMessage;

  /// Called when the user closes the panel.
  final VoidCallback onClose;

  @override
  ConsumerState<ThreadPanel> createState() =>
      _ThreadPanelState();
}

class _ThreadPanelState
    extends ConsumerState<ThreadPanel> {
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
    final threadAsync = ref.watch(
      threadMessagesProvider(
        widget.channelId,
        widget.parentMessage.id,
      ),
    );

    return Container(
      decoration: BoxDecoration(
        color: theme.surfaceBackground,
        border: Border(
          left: BorderSide(color: theme.dividerColor),
        ),
      ),
      child: Column(
        children: [
          _ThreadHeader(
            theme: theme,
            onClose: widget.onClose,
          ),
          const Divider(height: 1),
          _ParentMessageTile(
            message: widget.parentMessage,
            theme: theme,
          ),
          const Divider(height: 1),
          Expanded(
            child: threadAsync.when(
              data: (messages) => _ThreadReplies(
                messages: messages
                    .where(
                      (m) =>
                          m.id !=
                          widget.parentMessage.id,
                    )
                    .toList(),
                theme: theme,
              ),
              loading: () => const Center(
                child: CircularProgressIndicator(),
              ),
              error: (e, _) => Center(
                child: Text(
                  e.toString(),
                  style: TextStyle(
                    color: theme.error,
                  ),
                ),
              ),
            ),
          ),
          RepaintBoundary(
            child: ModernChatInput(
              onSendMessage: _sendReply,
              placeholder: 'Reply...',
            ),
          ),
        ],
      ),
    );
  }
}

/// Header row with "Thread" title and a close button.
class _ThreadHeader extends StatelessWidget {
  const _ThreadHeader({
    required this.theme,
    required this.onClose,
  });

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
            style: TextStyle(
              color: theme.textPrimary,
              fontWeight: FontWeight.w600,
              fontSize: 16,
            ),
          ),
          const Spacer(),
          IconButton(
            icon: Icon(
              Icons.close,
              color: theme.textSecondary,
              size: 20,
            ),
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
    required this.theme,
  });

  final ChannelMessage message;
  final ConduitThemeExtension theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(Spacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildAvatar(theme),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Text(
                  messageDisplayName(message),
                  style: TextStyle(
                    color: theme.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: Spacing.xxs),
                RichText(
                  text: buildMentionSpan(
                    content: message.content,
                    baseStyle: TextStyle(
                      color: theme.textPrimary,
                      fontSize: 14,
                    ),
                    mentionColor:
                        Theme.of(context)
                            .colorScheme
                            .primary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatar(ConduitThemeExtension theme) {
    if (isModelMessage(message)) {
      return CircleAvatar(
        radius: 16,
        backgroundColor: theme.buttonSecondary,
        child: Icon(
          Icons.smart_toy_outlined,
          size: 16,
          color: theme.textPrimary,
        ),
      );
    }
    final initial = message.userName.isNotEmpty
        ? message.userName[0].toUpperCase()
        : '?';
    return CircleAvatar(
      radius: 16,
      backgroundColor: theme.buttonSecondary,
      child: Text(
        initial,
        style: TextStyle(
          color: theme.textPrimary,
          fontWeight: FontWeight.w600,
          fontSize: 12,
        ),
      ),
    );
  }
}

/// Scrollable list of thread replies.
class _ThreadReplies extends StatelessWidget {
  const _ThreadReplies({
    required this.messages,
    required this.theme,
  });

  final List<ChannelMessage> messages;
  final ConduitThemeExtension theme;

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) {
      return Center(
        child: Text(
          'No replies yet',
          style: TextStyle(
            color: theme.textSecondary,
          ),
        ),
      );
    }
    return ListView.builder(
      reverse: false,
      padding: const EdgeInsets.symmetric(
        vertical: Spacing.sm,
      ),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final message = messages[index];
        final isModel = isModelMessage(message);
        return Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.md,
            vertical: Spacing.xs,
          ),
          child: Row(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              if (isModel)
                CircleAvatar(
                  radius: 14,
                  backgroundColor:
                      theme.buttonSecondary,
                  child: Icon(
                    Icons.smart_toy_outlined,
                    size: 14,
                    color: theme.textPrimary,
                  ),
                )
              else
                CircleAvatar(
                  radius: 14,
                  backgroundColor:
                      theme.buttonSecondary,
                  child: Text(
                    message.userName.isNotEmpty
                        ? message.userName[0]
                            .toUpperCase()
                        : '?',
                    style: TextStyle(
                      color: theme.textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 10,
                    ),
                  ),
                ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    Text(
                      messageDisplayName(message),
                      style: TextStyle(
                        color: theme.textPrimary,
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 2),
                    RichText(
                      text: buildMentionSpan(
                        content: message.content,
                        baseStyle: TextStyle(
                          color: theme.textPrimary,
                          fontSize: 13,
                        ),
                        mentionColor:
                            Theme.of(context)
                                .colorScheme
                                .primary,
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
