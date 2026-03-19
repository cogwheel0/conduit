import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io' show Platform;

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/cupertino.dart';
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
import '../../chat/services/file_attachment_service.dart';
import '../../chat/widgets/modern_chat_input.dart';
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
    try {
      ref.read(channelSocketHandlerProvider.notifier).unsubscribe();
    } catch (_) {
      // Provider may already be disposed during hot reload or
      // container teardown — the keepAlive notifier's own
      // ref.onDispose will clean up in that case.
    }
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
    } catch (e, s) {
      developer.log(
        'Failed to load channel details',
        name: 'ChannelPage',
        error: e,
        stackTrace: s,
      );
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

  Future<void> _sendMessage(String text) async {
    final content = text.trim();
    if (content.isEmpty || _isSending) return;

    final api = ref.read(apiServiceProvider);
    if (api == null) return;

    setState(() => _isSending = true);
    try {
      final tempId = DateTime.now()
          .microsecondsSinceEpoch
          .toString();
      final json = await api.postChannelMessage(
        widget.channelId,
        content: content,
        tempId: tempId,
      );
      if (!mounted) return;
      final message = ChannelMessage.fromJson(json);
      ref
          .read(
            channelMessagesProvider(widget.channelId)
                .notifier,
          )
          .prependMessage(message);
    } catch (e, s) {
      developer.log(
        'Failed to send channel message',
        name: 'ChannelPage',
        error: e,
        stackTrace: s,
      );
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      if (l10n != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.channelSendError),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Attachment popup (plus button)
  // ---------------------------------------------------------------------------

  /// Builds the overflow (+) button as an [AdaptivePopupMenuButton]
  /// with file, photo, and camera actions.
  Widget _buildAttachmentButton(double size) {
    final l10n = AppLocalizations.of(context);
    final theme = context.conduitTheme;

    return AdaptivePopupMenuButton.widget<String>(
      items: [
        AdaptivePopupMenuItem<String>(
          value: 'file',
          label: l10n?.file ?? 'File',
          icon: Platform.isIOS
              ? CupertinoIcons.doc
              : Icons.attach_file,
        ),
        AdaptivePopupMenuItem<String>(
          value: 'photo',
          label: l10n?.photo ?? 'Photo',
          icon: Platform.isIOS
              ? CupertinoIcons.photo
              : Icons.image,
        ),
        AdaptivePopupMenuItem<String>(
          value: 'camera',
          label: l10n?.camera ?? 'Camera',
          icon: Platform.isIOS
              ? CupertinoIcons.camera
              : Icons.camera_alt,
        ),
      ],
      onSelected: (index, entry) => _handleAttachmentAction(
        entry.value as String,
      ),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: theme.surfaceContainerHighest,
          border: Border.all(
            color: theme.cardBorder,
            width: BorderWidth.thin,
          ),
        ),
        child: Icon(
          Platform.isIOS ? CupertinoIcons.add : Icons.add,
          size: IconSize.large,
          color: theme.textPrimary.withValues(
            alpha: Alpha.strong,
          ),
        ),
      ),
    );
  }

  Future<void> _handleAttachmentAction(String action) async {
    final fileService = ref.read(fileAttachmentServiceProvider);
    if (fileService == null || fileService is! FileAttachmentService) {
      return;
    }

    switch (action) {
      case 'file':
        await fileService.pickFiles();
      case 'photo':
        await fileService.pickImage();
      case 'camera':
        await fileService.takePhoto();
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
      (r) =>
          r.name == emoji &&
          r.users.any(
            (u) =>
                u['user_id'] == currentUserId ||
                u['id'] == currentUserId,
          ),
    );

    try {
      // The API returns bool; the socket handler will
      // re-fetch the message with updated reactions.
      if (existing) {
        await api.removeMessageReaction(
          widget.channelId,
          message.id,
          emoji,
        );
      } else {
        await api.addMessageReaction(
          widget.channelId,
          message.id,
          emoji,
        );
      }
    } catch (e, s) {
      developer.log(
        'Failed to toggle reaction',
        name: 'ChannelPage',
        error: e,
        stackTrace: s,
      );
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
    } catch (e, s) {
      developer.log(
        'Failed to delete message',
        name: 'ChannelPage',
        error: e,
        stackTrace: s,
      );
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

    // Don't dispose controllers here — the dialog's exit animation
    // may still reference them. They'll be GC'd with the dialog tree.
    final newName = nameController.text.trim();
    final newDesc = descController.text.trim();

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
    } catch (e, s) {
      developer.log(
        'Failed to update channel',
        name: 'ChannelPage',
        error: e,
        stackTrace: s,
      );
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
      await api.updateMemberActiveStatus(
        widget.channelId,
        isActive: false,
      );
      if (!mounted) return;
      ref
          .read(channelsListProvider.notifier)
          .removeChannel(widget.channelId);
      ref.read(activeChannelProvider.notifier).clear();
      NavigationService.router.go(Routes.chat);
    } catch (e, s) {
      developer.log(
        'Failed to leave channel',
        name: 'ChannelPage',
        error: e,
        stackTrace: s,
      );
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
    } catch (e, s) {
      developer.log(
        'Failed to delete channel',
        name: 'ChannelPage',
        error: e,
        stackTrace: s,
      );
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

    final scrim = Platform.isIOS
        ? context.colorTokens.scrimMedium
        : context.colorTokens.scrimStrong;

    return ResponsiveDrawerLayout(
      maxFraction: isTablet ? 0.42 : 1.0,
      edgeFraction: isTablet ? 0.36 : 0.50,
      settleFraction: 0.06,
      scrimColor: scrim,
      pushContent: true,
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
      extendBodyBehindAppBar: true,
      appBar: FloatingAppBar(
        leading: Builder(
          builder: (ctx) => FloatingAppBarIconButton(
            icon: Platform.isIOS
                ? CupertinoIcons.line_horizontal_3
                : Icons.menu,
            onTap: () =>
                ResponsiveDrawerLayout.of(ctx)?.toggle(),
          ),
        ),
        title: FloatingAppBarTitle(
          text: channel?.name ?? '',
          icon: channel?.isPrivate == true
              ? Icons.lock_outlined
              : Icons.tag,
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(
              right: Spacing.inputPadding,
            ),
            child: _buildMoreMenuButton(channel, theme, l10n),
          ),
        ],
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
          RepaintBoundary(
            child: ModernChatInput(
              onSendMessage: _sendMessage,
              placeholder: 'Type here...',
              overflowButtonBuilder: _buildAttachmentButton,
            ),
          ),
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

    final currentUserId = ref.watch(currentUserProvider).value?.id;

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

  Widget _buildMoreMenuButton(
    Channel? channel,
    ConduitThemeExtension theme,
    AppLocalizations? l10n,
  ) {
    return PopupMenuButton<String>(
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
          child: Text(
            l10n?.channelEdit ?? 'Edit Channel',
          ),
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
      child: FloatingAppBarPill(
        isCircular: true,
        child: Icon(
          Platform.isIOS
              ? CupertinoIcons.ellipsis_vertical
              : Icons.more_vert,
          color: theme.textPrimary,
          size: IconSize.appBar,
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
    final primaryColor =
        Theme.of(context).colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.only(top: Spacing.xs),
      child: Wrap(
        spacing: Spacing.xs,
        runSpacing: Spacing.xs,
        children: message.reactions.map((reaction) {
          final isActive = reaction.users.any(
            (u) =>
                u['user_id'] == currentUserId ||
                u['id'] == currentUserId,
          );
          return ActionChip(
            label: Text(
              '${reaction.name} ${reaction.count}',
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
            onPressed: () =>
                onReactionTap(reaction.name),
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
