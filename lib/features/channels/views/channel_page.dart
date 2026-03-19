import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit/l10n/app_localizations.dart';

import '../../../core/models/channel.dart';
import '../../../core/models/channel_message.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/navigation_service.dart';
import '../../../shared/theme/conduit_input_styles.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/responsive_drawer_layout.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../navigation/widgets/sidebar_page.dart';
import '../providers/channel_providers.dart';
import '../providers/channel_socket_handler.dart';

/// Full-screen view for a single channel with messaging,
/// reactions, and channel management actions.
class ChannelPage extends ConsumerStatefulWidget {
  /// Creates a channel page for the given [channelId].
  const ChannelPage({super.key, required this.channelId});

  /// The identifier of the channel to display.
  final String channelId;

  @override
  ConsumerState<ChannelPage> createState() => _ChannelPageState();
}

class _ChannelPageState extends ConsumerState<ChannelPage> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _messageController =
      TextEditingController();
  final FocusNode _inputFocusNode = FocusNode();
  bool _isSending = false;
  bool _isLoadingMore = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadChannel();
    ref
        .read(channelSocketHandlerProvider.notifier)
        .subscribe(widget.channelId);
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    _messageController.dispose();
    _inputFocusNode.dispose();
    ref.read(channelSocketHandlerProvider.notifier).unsubscribe();
    super.dispose();
  }

  /// Fetches the channel details and sets it as active.
  Future<void> _loadChannel() async {
    final api = ref.read(apiServiceProvider);
    if (api == null) return;
    try {
      final json = await api.getChannel(widget.channelId);
      if (!mounted) return;
      final channel = Channel.fromJson(json);
      ref.read(activeChannelProvider.notifier).set(channel);
    } catch (_) {
      // Channel details will fall back to provider state.
    }
  }

  /// Triggers pagination when the user scrolls near the top
  /// of the reversed list (which corresponds to older messages).
  void _onScroll() {
    if (_isLoadingMore) return;
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 200) {
      _loadMoreMessages();
    }
  }

  Future<void> _loadMoreMessages() async {
    final notifier = ref.read(
      channelMessagesProvider(widget.channelId).notifier,
    );
    if (!notifier.hasMore) return;
    setState(() => _isLoadingMore = true);
    try {
      await notifier.loadMore();
    } finally {
      if (mounted) setState(() => _isLoadingMore = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Sending messages
  // ---------------------------------------------------------------------------

  Future<void> _sendMessage() async {
    final content = _messageController.text.trim();
    if (content.isEmpty || _isSending) return;

    final api = ref.read(apiServiceProvider);
    if (api == null) return;

    setState(() => _isSending = true);
    try {
      final json = await api.postChannelMessage(
        widget.channelId,
        content: content,
      );
      if (!mounted) return;
      final message = ChannelMessage.fromJson(json);
      ref
          .read(channelMessagesProvider(widget.channelId).notifier)
          .prependMessage(message);
      _messageController.clear();
    } catch (_) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      if (l10n != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.channelSendError)),
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Reactions
  // ---------------------------------------------------------------------------

  Future<void> _toggleReaction(
    ChannelMessage message,
    String emoji,
  ) async {
    final api = ref.read(apiServiceProvider);
    if (api == null) return;
    final currentUserId =
        ref.read(currentUserProvider).value?.id;
    if (currentUserId == null) return;

    final existing = message.reactions.any(
      (r) => r.emoji == emoji && r.userId == currentUserId,
    );

    try {
      if (existing) {
        await api.removeMessageReaction(
          widget.channelId,
          message.id,
          emoji,
        );
        if (!mounted) return;
        final updated = message.copyWith(
          reactions: message.reactions
              .where(
                (r) =>
                    !(r.emoji == emoji &&
                        r.userId == currentUserId),
              )
              .toList(),
        );
        ref
            .read(
              channelMessagesProvider(widget.channelId)
                  .notifier,
            )
            .updateMessage(updated);
      } else {
        final json = await api.addMessageReaction(
          widget.channelId,
          message.id,
          emoji,
        );
        if (!mounted) return;
        final reaction = MessageReaction.fromJson(json);
        final updated = message.copyWith(
          reactions: [...message.reactions, reaction],
        );
        ref
            .read(
              channelMessagesProvider(widget.channelId)
                  .notifier,
            )
            .updateMessage(updated);
      }
    } catch (_) {
      // Silently ignore reaction failures.
    }
  }

  Future<void> _deleteMessage(ChannelMessage message) async {
    final api = ref.read(apiServiceProvider);
    if (api == null) return;
    try {
      await api.deleteChannelMessage(
        widget.channelId,
        message.id,
      );
      if (!mounted) return;
      ref
          .read(
            channelMessagesProvider(widget.channelId).notifier,
          )
          .removeMessage(message.id);
    } catch (_) {
      // Silently ignore deletion failures.
    }
  }

  // ---------------------------------------------------------------------------
  // Bottom sheets
  // ---------------------------------------------------------------------------

  void _showMessageActions(ChannelMessage message) {
    final l10n = AppLocalizations.of(context);
    final theme = context.conduitTheme;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: theme.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppBorderRadius.bottomSheet),
        ),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.emoji_emotions_outlined),
              title: Text(l10n?.channelMessageReact ?? 'React'),
              onTap: () {
                Navigator.pop(ctx);
                _showEmojiPicker(message);
              },
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: theme.error,
              ),
              title: Text(
                l10n?.channelMessageDelete ?? 'Delete',
                style: TextStyle(color: theme.error),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _deleteMessage(message);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showEmojiPicker(ChannelMessage message) {
    final theme = context.conduitTheme;
    const emojis = ['👍', '❤️', '😂', '🎉', '🤔', '👀'];

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: theme.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppBorderRadius.bottomSheet),
        ),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(
            vertical: Spacing.md,
            horizontal: Spacing.lg,
          ),
          child: Wrap(
            spacing: Spacing.md,
            runSpacing: Spacing.md,
            alignment: WrapAlignment.center,
            children: emojis.map((emoji) {
              return InkWell(
                borderRadius: BorderRadius.circular(
                  AppBorderRadius.round,
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _toggleReaction(message, emoji);
                },
                child: Padding(
                  padding: const EdgeInsets.all(Spacing.sm),
                  child: Text(
                    emoji,
                    style: const TextStyle(fontSize: 28),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Channel menu actions
  // ---------------------------------------------------------------------------

  Future<void> _editChannel(Channel channel) async {
    final l10n = AppLocalizations.of(context);
    final theme = context.conduitTheme;

    final nameController =
        TextEditingController(text: channel.name);
    final descController =
        TextEditingController(text: channel.description);

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => ThemedDialogs.buildBase(
        context: ctx,
        title: l10n?.channelEdit ?? 'Edit Channel',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              style: TextStyle(color: theme.textPrimary),
              decoration: context.conduitInputStyles.underline(
                hint: l10n?.channelName ?? 'Channel Name',
              ),
            ),
            const SizedBox(height: Spacing.md),
            TextField(
              controller: descController,
              style: TextStyle(color: theme.textPrimary),
              decoration: context.conduitInputStyles.underline(
                hint: l10n?.channelDescription ??
                    'Description',
              ),
              maxLines: 3,
              minLines: 1,
            ),
          ],
        ),
        actions: [
          ConduitTextButton(
            text: l10n?.cancel ?? 'Cancel',
            onPressed: () => Navigator.of(ctx).pop(false),
          ),
          ConduitTextButton(
            text: l10n?.save ?? 'Save',
            onPressed: () => Navigator.of(ctx).pop(true),
            isPrimary: true,
          ),
        ],
      ),
    );

    final newName = nameController.text.trim();
    final newDesc = descController.text.trim();

    nameController.dispose();
    descController.dispose();

    if (saved != true) return;

    if (newName.isEmpty) return;
    if (newName == channel.name &&
        newDesc == channel.description) {
      return;
    }

    final api = ref.read(apiServiceProvider);
    if (api == null) return;

    try {
      final json = await api.updateChannel(
        channel.id,
        name: newName,
        description: newDesc,
      );
      if (!mounted) return;
      final updated = Channel.fromJson(json);
      ref.read(activeChannelProvider.notifier).set(updated);
      ref
          .read(channelsListProvider.notifier)
          .updateChannel(updated);
    } catch (_) {
      // Silently ignore update failures.
    }
  }

  Future<void> _leaveChannel() async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n?.channelLeave ?? 'Leave Channel',
      message: l10n?.channelLeaveConfirm ??
          'Leave this channel?',
    );
    if (!confirmed || !mounted) return;

    final api = ref.read(apiServiceProvider);
    if (api == null) return;

    try {
      await api.leaveChannel(widget.channelId);
      if (!mounted) return;
      ref
          .read(channelsListProvider.notifier)
          .removeChannel(widget.channelId);
      ref.read(activeChannelProvider.notifier).clear();
      NavigationService.router.go(Routes.chat);
    } catch (_) {
      // Silently ignore leave failures.
    }
  }

  Future<void> _deleteChannel() async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n?.channelDelete ?? 'Delete Channel',
      message: l10n?.channelDeleteConfirm ??
          'Delete this channel? This cannot be undone.',
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;

    final api = ref.read(apiServiceProvider);
    if (api == null) return;

    try {
      await api.deleteChannel(widget.channelId);
      if (!mounted) return;
      ref
          .read(channelsListProvider.notifier)
          .removeChannel(widget.channelId);
      ref.read(activeChannelProvider.notifier).clear();
      NavigationService.router.go(Routes.chat);
    } catch (_) {
      // Silently ignore delete failures.
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final isTablet =
        MediaQuery.of(context).size.shortestSide >= 600;

    return ResponsiveDrawerLayout(
      maxFraction: isTablet ? 0.42 : 1.0,
      edgeFraction: isTablet ? 0.36 : 0.50,
      settleFraction: 0.06,
      pushContent: isTablet,
      contentScaleDelta: 0.0,
      tabletDrawerWidth: 320.0,
      drawer: Container(
        color: theme.surfaceBackground,
        child: const SafeArea(
          top: true,
          bottom: true,
          left: false,
          right: false,
          child: SidebarPage(),
        ),
      ),
      child: _buildScaffold(context, theme),
    );
  }

  Widget _buildScaffold(
    BuildContext context,
    ConduitThemeExtension theme,
  ) {
    final l10n = AppLocalizations.of(context);
    final channel = ref.watch(activeChannelProvider);
    final messagesAsync =
        ref.watch(channelMessagesProvider(widget.channelId));

    return Scaffold(
      backgroundColor: theme.surfaceBackground,
      appBar: AppBar(
        backgroundColor: theme.surfaceBackground,
        elevation: Elevation.none,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: Icon(
            Platform.isIOS
                ? Icons.arrow_back_ios_new
                : Icons.arrow_back,
            color: theme.textPrimary,
          ),
          onPressed: () {
            ref.read(activeChannelProvider.notifier).clear();
            NavigationService.router.go(Routes.chat);
          },
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              channel?.name ?? '',
              style: TextStyle(
                color: theme.textPrimary,
                fontWeight: FontWeight.w600,
                fontSize: 16,
              ),
              overflow: TextOverflow.ellipsis,
            ),
            if (channel != null &&
                channel.description.isNotEmpty)
              Text(
                channel.description,
                style: TextStyle(
                  color: theme.textSecondary,
                  fontSize: 12,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            icon: Icon(
              Icons.more_vert,
              color: theme.textPrimary,
            ),
            color: theme.surfaceContainer,
            onSelected: (value) {
              switch (value) {
                case 'edit':
                  if (channel != null) _editChannel(channel);
                case 'leave':
                  _leaveChannel();
                case 'delete':
                  _deleteChannel();
              }
            },
            itemBuilder: (ctx) => [
              PopupMenuItem(
                value: 'edit',
                child:
                    Text(l10n?.channelEdit ?? 'Edit Channel'),
              ),
              PopupMenuItem(
                value: 'leave',
                child: Text(
                  l10n?.channelLeave ?? 'Leave Channel',
                ),
              ),
              PopupMenuItem(
                value: 'delete',
                child: Text(
                  l10n?.channelDelete ?? 'Delete Channel',
                  style: TextStyle(color: theme.error),
                ),
              ),
            ],
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(
            height: 1,
            thickness: 1,
            color: theme.dividerColor,
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: messagesAsync.when(
              data: (messages) => _buildMessageList(
                messages,
                theme,
                l10n,
              ),
              loading: () => const Center(
                child: CircularProgressIndicator(),
              ),
              error: (error, _) => Center(
                child: Text(
                  error.toString(),
                  style: TextStyle(color: theme.error),
                ),
              ),
            ),
          ),
          _buildInputBar(theme),
        ],
      ),
    );
  }

  Widget _buildMessageList(
    List<ChannelMessage> messages,
    ConduitThemeExtension theme,
    AppLocalizations? l10n,
  ) {
    if (messages.isEmpty) {
      return Center(
        child: Text(
          l10n?.channelNoMessages ??
              'No messages yet. Start the conversation!',
          style: TextStyle(color: theme.textSecondary),
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      reverse: true,
      padding: const EdgeInsets.symmetric(
        vertical: Spacing.sm,
      ),
      itemCount: messages.length + (_isLoadingMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (_isLoadingMore && index == messages.length) {
          return const Padding(
            padding: EdgeInsets.all(Spacing.md),
            child: Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                ),
              ),
            ),
          );
        }
        final message = messages[index];
        final currentUserId =
            ref.read(currentUserProvider).value?.id;
        return _MessageBubble(
          message: message,
          currentUserId: currentUserId,
          onLongPress: () => _showMessageActions(message),
          onReactionTap: (emoji) =>
              _toggleReaction(message, emoji),
        );
      },
    );
  }

  Widget _buildInputBar(ConduitThemeExtension theme) {
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: theme.surfaceBackground,
          border: Border(
            top: BorderSide(
              color: theme.dividerColor,
              width: 1,
            ),
          ),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.sm,
          vertical: Spacing.sm,
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _messageController,
                focusNode: _inputFocusNode,
                style: TextStyle(color: theme.textPrimary),
                decoration:
                    context.conduitInputStyles.standard(
                  hint: 'Message...',
                ),
                textCapitalization:
                    TextCapitalization.sentences,
                textInputAction: TextInputAction.send,
                minLines: 1,
                maxLines: 4,
                onSubmitted: (_) => _sendMessage(),
              ),
            ),
            const SizedBox(width: Spacing.sm),
            IconButton(
              onPressed: _isSending ? null : _sendMessage,
              icon: Icon(
                Icons.send,
                color: _isSending
                    ? theme.textDisabled
                    : Theme.of(context).colorScheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Message bubble
// ---------------------------------------------------------------------------

/// Renders a single channel message with avatar, metadata,
/// content, and reaction chips.
class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.currentUserId,
    required this.onLongPress,
    required this.onReactionTap,
  });

  final ChannelMessage message;
  final String? currentUserId;
  final VoidCallback onLongPress;
  final ValueChanged<String> onReactionTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final timestamp =
        _formatTimestamp(message.createdDateTime);

    return InkWell(
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.md,
          vertical: Spacing.xs,
        ),
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
                  _buildHeader(theme, timestamp),
                  const SizedBox(height: Spacing.xxs),
                  Text(
                    message.content,
                    style: TextStyle(
                      color: theme.textPrimary,
                      fontSize: 14,
                      height: 1.4,
                    ),
                  ),
                  if (message.reactions.isNotEmpty)
                    _buildReactions(context, theme),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAvatar(ConduitThemeExtension theme) {
    final profileImage = message.userProfileImage;
    final initial = message.userName.isNotEmpty
        ? message.userName[0].toUpperCase()
        : '?';

    if (profileImage != null && profileImage.isNotEmpty) {
      return CircleAvatar(
        radius: 18,
        backgroundImage: NetworkImage(profileImage),
        onBackgroundImageError: (e, s) {},
      );
    }

    return CircleAvatar(
      radius: 18,
      backgroundColor: theme.buttonSecondary,
      child: Text(
        initial,
        style: TextStyle(
          color: theme.textPrimary,
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
      ),
    );
  }

  Widget _buildHeader(
    ConduitThemeExtension theme,
    String timestamp,
  ) {
    return Row(
      children: [
        Flexible(
          child: Text(
            message.userName,
            style: TextStyle(
              color: theme.textPrimary,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: Spacing.sm),
        Text(
          timestamp,
          style: TextStyle(
            color: theme.textSecondary,
            fontSize: 11,
          ),
        ),
      ],
    );
  }

  Widget _buildReactions(
    BuildContext context,
    ConduitThemeExtension theme,
  ) {
    final grouped = <String, int>{};
    final userReacted = <String, bool>{};

    for (final reaction in message.reactions) {
      grouped[reaction.emoji] =
          (grouped[reaction.emoji] ?? 0) + 1;
      if (reaction.userId == currentUserId) {
        userReacted[reaction.emoji] = true;
      }
    }

    final primaryColor =
        Theme.of(context).colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.only(top: Spacing.xs),
      child: Wrap(
        spacing: Spacing.xs,
        runSpacing: Spacing.xs,
        children: grouped.entries.map((entry) {
          final isActive =
              userReacted[entry.key] == true;
          return ActionChip(
            label: Text(
              '${entry.key} ${entry.value}',
              style: const TextStyle(fontSize: 12),
            ),
            backgroundColor: isActive
                ? primaryColor.withValues(alpha: 0.15)
                : theme.surfaceContainer,
            side: BorderSide(
              color: isActive
                  ? primaryColor.withValues(alpha: 0.4)
                  : theme.dividerColor,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(
                AppBorderRadius.chip,
              ),
            ),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize:
                MaterialTapTargetSize.shrinkWrap,
            onPressed: () => onReactionTap(entry.key),
          );
        }).toList(),
      ),
    );
  }

  String _formatTimestamp(DateTime? dateTime) {
    if (dateTime == null) return '';
    final now = DateTime.now();
    final diff = now.difference(dateTime);

    if (diff.inMinutes < 1) return 'now';
    if (diff.inHours < 1) return '${diff.inMinutes}m';
    if (diff.inDays < 1) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';

    return '${dateTime.month}/${dateTime.day}';
  }
}
