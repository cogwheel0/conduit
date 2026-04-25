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
import '../../../core/services/api_service.dart';
import '../../../core/services/navigation_service.dart';
import '../../../core/utils/model_icon_utils.dart';
import '../../../core/utils/user_avatar_utils.dart';
import '../../../shared/theme/conduit_input_styles.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/model_avatar.dart';
import '../../../shared/widgets/responsive_drawer_layout.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../shared/widgets/user_avatar.dart';
import '../../chat/services/file_attachment_service.dart';
import '../../chat/widgets/modern_chat_input.dart';
import '../providers/channel_providers.dart';
import '../providers/channel_socket_handler.dart';
import '../utils/mention_utils.dart';
import '../widgets/thread_panel.dart';

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
  String? _editingMessageId;
  final TextEditingController _editController = TextEditingController();
  Timer? _typingTimer;
  ChannelMessage? _replyToMessage;
  ChannelMessage? _threadParent;

  void _setReplyTo(ChannelMessage message) {
    setState(() => _replyToMessage = message);
  }

  void _clearReplyTo() {
    setState(() => _replyToMessage = null);
  }

  void _openThread(ChannelMessage message) {
    final isTablet = MediaQuery.of(context).size.shortestSide >= 600;
    if (isTablet) {
      setState(() => _threadParent = message);
    } else {
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (ctx) => SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.85,
          child: ThreadPanel(
            channelId: widget.channelId,
            parentMessage: message,
            onClose: () => Navigator.pop(ctx),
            overflowButtonBuilder: _buildAttachmentButton,
          ),
        ),
      );
    }
  }

  @override
  void didUpdateWidget(covariant ChannelPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.channelId != oldWidget.channelId) {
      _threadParent = null;
      _replyToMessage = null;
      _loadChannel();
      // Defer subscribe — unsubscribe clears ChannelTypingUsers
      // state which is not allowed during the build phase.
      Future(() {
        if (!mounted) return;
        ref
            .read(channelSocketHandlerProvider.notifier)
            .subscribe(widget.channelId);
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadChannel();
    // Defer subscribe to after the build phase — unsubscribe
    // clears ChannelTypingUsers state which is not allowed
    // during initState.
    Future(() {
      if (!mounted) return;
      ref
          .read(channelSocketHandlerProvider.notifier)
          .subscribe(widget.channelId);
    });
  }

  @override
  void dispose() {
    _typingTimer?.cancel();
    _editController.dispose();
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
      ref
          .read(channelSocketHandlerProvider.notifier)
          .emitLastReadAt(widget.channelId);
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
      final tempId = DateTime.now().microsecondsSinceEpoch.toString();
      final json = await api.postChannelMessage(
        widget.channelId,
        content: content,
        tempId: tempId,
        replyToId: _replyToMessage?.id,
      );
      if (!mounted) return;
      final message = ChannelMessage.fromJson(json);
      ref
          .read(channelMessagesProvider(widget.channelId).notifier)
          .prependMessage(message);
      _clearReplyTo();
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.channelSendError)));
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
          icon: Platform.isIOS ? CupertinoIcons.doc : Icons.attach_file,
        ),
        AdaptivePopupMenuItem<String>(
          value: 'photo',
          label: l10n?.photo ?? 'Photo',
          icon: Platform.isIOS ? CupertinoIcons.photo : Icons.image,
        ),
        AdaptivePopupMenuItem<String>(
          value: 'camera',
          label: l10n?.camera ?? 'Camera',
          icon: Platform.isIOS ? CupertinoIcons.camera : Icons.camera_alt,
        ),
      ],
      onSelected: (index, entry) =>
          _handleAttachmentAction(entry.value as String),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: theme.surfaceContainerHighest,
          border: Border.all(color: theme.cardBorder, width: BorderWidth.thin),
        ),
        child: Icon(
          Platform.isIOS ? CupertinoIcons.add : Icons.add,
          size: IconSize.large,
          color: theme.textPrimary.withValues(alpha: Alpha.strong),
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

  Future<void> _toggleReaction(ChannelMessage message, String emoji) async {
    final api = ref.read(apiServiceProvider);
    if (api == null) return;
    final currentUserId = ref.read(currentUserProvider).value?.id;
    if (currentUserId == null) return;

    final existing = message.reactions.any(
      (r) =>
          r.name == emoji &&
          r.users.any(
            (u) => u['user_id'] == currentUserId || u['id'] == currentUserId,
          ),
    );

    try {
      // The API returns bool; the socket handler will
      // re-fetch the message with updated reactions.
      if (existing) {
        await api.removeMessageReaction(widget.channelId, message.id, emoji);
      } else {
        await api.addMessageReaction(widget.channelId, message.id, emoji);
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
      await api.deleteChannelMessage(widget.channelId, message.id);
      if (!mounted) return;
      ref
          .read(channelMessagesProvider(widget.channelId).notifier)
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
  // Message editing
  // ---------------------------------------------------------------------------

  void _startEditingMessage(ChannelMessage message) {
    setState(() {
      _editingMessageId = message.id;
      _editController.text = message.content;
    });
  }

  void _cancelEditing() {
    setState(() {
      _editingMessageId = null;
      _editController.clear();
    });
  }

  Future<void> _submitEdit(ChannelMessage message) async {
    final newContent = _editController.text.trim();
    if (newContent.isEmpty || newContent == message.content) {
      _cancelEditing();
      return;
    }

    final api = ref.read(apiServiceProvider);
    if (api == null) return;

    try {
      final json = await api.updateChannelMessage(
        widget.channelId,
        message.id,
        content: newContent,
      );
      if (!mounted) return;
      final updated = ChannelMessage.fromJson(json);
      ref
          .read(channelMessagesProvider(widget.channelId).notifier)
          .updateMessage(updated);
    } catch (e, st) {
      developer.log(
        'Failed to edit message',
        name: 'ChannelPage',
        error: e,
        stackTrace: st,
      );
    }
    if (mounted) _cancelEditing();
  }

  // ---------------------------------------------------------------------------
  // Pin / unpin
  // ---------------------------------------------------------------------------

  Future<void> _togglePin(ChannelMessage message) async {
    final api = ref.read(apiServiceProvider);
    if (api == null) return;

    try {
      final json = await api.pinMessage(
        widget.channelId,
        message.id,
        isPinned: !message.isPinned,
      );
      if (json == null || !mounted) return;
      final updated = ChannelMessage.fromJson(json);
      ref
          .read(channelMessagesProvider(widget.channelId).notifier)
          .updateMessage(updated);
    } catch (e, st) {
      developer.log(
        'Failed to toggle pin',
        name: 'ChannelPage',
        error: e,
        stackTrace: st,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Bottom sheets
  // ---------------------------------------------------------------------------

  void _showMessageActions(ChannelMessage message) {
    final l10n = AppLocalizations.of(context);
    final theme = context.conduitTheme;
    final currentUserId = ref.read(currentUserProvider).value?.id;
    final isOwn = message.userId == currentUserId;

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
              leading: const Icon(Icons.reply_outlined),
              title: Text(l10n?.channelMessageReply ?? 'Reply'),
              onTap: () {
                Navigator.pop(ctx);
                _setReplyTo(message);
              },
            ),
            if (message.parentId == null)
              ListTile(
                leading: const Icon(Icons.forum_outlined),
                title: Text(
                  'Thread'
                  '${message.replyCount > 0 ? " (${message.replyCount})" : ""}',
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _openThread(message);
                },
              ),
            ListTile(
              leading: const Icon(Icons.push_pin_outlined),
              title: Text(message.isPinned ? 'Unpin' : 'Pin'),
              onTap: () {
                Navigator.pop(ctx);
                _togglePin(message);
              },
            ),
            if (isOwn)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: Text(l10n?.channelMessageEdit ?? 'Edit'),
                onTap: () {
                  Navigator.pop(ctx);
                  _startEditingMessage(message);
                },
              ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: theme.error),
              title: Text(
                l10n?.channelMessageDelete ?? 'Delete',
                style: AppTypography.bodyMediumStyle.copyWith(
                  color: theme.error,
                ),
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
                borderRadius: BorderRadius.circular(AppBorderRadius.round),
                onTap: () {
                  Navigator.pop(ctx);
                  _toggleReaction(message, emoji);
                },
                child: Padding(
                  padding: const EdgeInsets.all(Spacing.sm),
                  child: Text(emoji, style: const TextStyle(fontSize: 28)),
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

    final nameController = TextEditingController(text: channel.name);
    final descController = TextEditingController(text: channel.description);

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
              style: AppTypography.bodyMediumStyle.copyWith(
                color: theme.textPrimary,
              ),
              decoration: context.conduitInputStyles.underline(
                hint: l10n?.channelName ?? 'Channel Name',
              ),
            ),
            const SizedBox(height: Spacing.md),
            TextField(
              controller: descController,
              style: AppTypography.bodyMediumStyle.copyWith(
                color: theme.textPrimary,
              ),
              decoration: context.conduitInputStyles.underline(
                hint: l10n?.channelDescription ?? 'Description',
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
    if (newName == channel.name && newDesc == channel.description) {
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
      ref.read(channelsListProvider.notifier).updateChannel(updated);
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
      message: l10n?.channelLeaveConfirm ?? 'Leave this channel?',
    );
    if (!confirmed || !mounted) return;

    final api = ref.read(apiServiceProvider);
    if (api == null) return;

    try {
      await api.updateMemberActiveStatus(widget.channelId, isActive: false);
      if (!mounted) return;
      ref.read(channelsListProvider.notifier).removeChannel(widget.channelId);
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
      message:
          l10n?.channelDeleteConfirm ??
          'Delete this channel? This cannot be undone.',
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;

    final api = ref.read(apiServiceProvider);
    if (api == null) return;

    try {
      await api.deleteChannel(widget.channelId);
      if (!mounted) return;
      ref.read(channelsListProvider.notifier).removeChannel(widget.channelId);
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
    return _buildScaffold(context, theme);
  }

  Widget _buildScaffold(BuildContext context, ConduitThemeExtension theme) {
    final l10n = AppLocalizations.of(context);
    final channel = ref.watch(activeChannelProvider);
    final messagesAsync = ref.watch(channelMessagesProvider(widget.channelId));

    return Scaffold(
      backgroundColor: theme.surfaceBackground,
      extendBodyBehindAppBar: true,
      appBar: FloatingAppBar(
        balanceLeading: false,
        leading: Builder(
          builder: (ctx) => FloatingAppBarIconButton(
            icon: Platform.isIOS
                ? CupertinoIcons.line_horizontal_3
                : Icons.menu,
            onTap: () => ResponsiveDrawerLayout.of(ctx)?.toggle(),
          ),
        ),
        title: Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: Spacing.sm),
            child: FloatingAppBarPill(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Spacing.md,
                  vertical: Spacing.sm,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      channel?.isPrivate == true
                          ? Icons.lock_outlined
                          : Icons.tag,
                      size: IconSize.appBar,
                      color: theme.textPrimary,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        channel?.name ?? '',
                        style: AppTypography.bodyMediumStyle.copyWith(
                          color: theme.textPrimary,
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        actions: [
          if (channel?.userCount != null)
            Padding(
              padding: const EdgeInsets.only(right: Spacing.xs),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _showMemberList,
                child: FloatingAppBarPill(
                  isCircular: true,
                  child: Icon(
                    Icons.people_outline,
                    size: IconSize.appBar,
                    color: theme.textPrimary,
                  ),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(right: Spacing.inputPadding),
            child: _buildMoreMenuButton(channel, theme, l10n),
          ),
        ],
      ),
      body: Row(
        children: [
          Expanded(
            child: Column(
              children: [
                Expanded(
                  child: messagesAsync.when(
                    data: (messages) =>
                        _buildMessageList(messages, theme, l10n),
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (error, _) => Center(
                      child: Text(
                        error.toString(),
                        style: AppTypography.bodyMediumStyle.copyWith(
                          color: theme.error,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: Spacing.sm),
                Consumer(
                  builder: (context, ref, _) {
                    final typingUsers = ref.watch(channelTypingUsersProvider);
                    if (typingUsers.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    final names = typingUsers.values.toList();
                    final text = names.length == 1
                        ? '${names.first} '
                              'is typing...'
                        : '${names.join(", ")} '
                              'are typing...';
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: Spacing.md,
                        vertical: Spacing.xxs,
                      ),
                      child: Text(
                        text,
                        style: AppTypography.bodySmallStyle.copyWith(
                          color: theme.textSecondary,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    );
                  },
                ),
                if (_replyToMessage != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Spacing.md,
                      vertical: Spacing.sm,
                    ),
                    color: theme.surfaceContainer,
                    child: Row(
                      children: [
                        Icon(Icons.reply, size: 16, color: theme.textSecondary),
                        const SizedBox(width: Spacing.sm),
                        Expanded(
                          child: Text(
                            'Replying to '
                            '${_replyToMessage!.userName}',
                            style: AppTypography.bodySmallStyle.copyWith(
                              color: theme.textSecondary,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          icon: Icon(
                            Icons.close,
                            size: 16,
                            color: theme.textSecondary,
                          ),
                          onPressed: _clearReplyTo,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ],
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
          ),
          if (_threadParent != null)
            SizedBox(
              width: 320,
              child: Padding(
                padding: EdgeInsets.only(
                  top: MediaQuery.of(context).padding.top + kTextTabBarHeight,
                ),
                child: ThreadPanel(
                  channelId: widget.channelId,
                  parentMessage: _threadParent!,
                  onClose: () => setState(() => _threadParent = null),
                  overflowButtonBuilder: _buildAttachmentButton,
                ),
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
          l10n?.channelNoMessages ?? 'No messages yet. Start the conversation!',
          style: AppTypography.bodyMediumStyle.copyWith(
            color: theme.textSecondary,
          ),
        ),
      );
    }

    final currentUserId = ref.watch(currentUserProvider).value?.id;
    final api = ref.read(apiServiceProvider);

    return ListView.builder(
      controller: _scrollController,
      reverse: true,
      padding: const EdgeInsets.only(top: Spacing.md, bottom: Spacing.sm),
      itemCount: messages.length + (_isLoadingMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (_isLoadingMore && index == messages.length) {
          return const Padding(
            padding: EdgeInsets.all(Spacing.md),
            child: Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final message = messages[index];
        final avatarUrl = _resolveAvatarUrl(api, message);

        // Determine the effective sender ID for
        // grouping consecutive messages. Model
        // messages use meta.model_id as the key.
        String? senderOf(ChannelMessage m) {
          if (isModelMessage(m)) {
            return m.meta?['model_id'] as String?;
          }
          return m.userId;
        }

        // In a reversed list, index+1 is the
        // message visually above. Show profile
        // only on the first message of a group.
        final prevIndex = index + 1;
        final showProfile =
            prevIndex >= messages.length ||
            senderOf(messages[prevIndex]) != senderOf(message);

        return _MessageBubble(
          message: message,
          avatarUrl: avatarUrl,
          showProfile: showProfile,
          currentUserId: currentUserId,
          isEditing: _editingMessageId == message.id,
          editController: _editController,
          onSubmitEdit: () => _submitEdit(message),
          onCancelEdit: _cancelEditing,
          onLongPress: () => _showMessageActions(message),
          onReactionTap: (emoji) => _toggleReaction(message, emoji),
          onThreadTap: message.parentId == null
              ? () => _openThread(message)
              : null,
        );
      },
    );
  }

  /// Resolves the avatar URL for a channel message.
  ///
  /// For model responses, builds the model profile image
  /// URL. For user messages, resolves the user's profile
  /// image URL.
  String? _resolveAvatarUrl(ApiService? api, ChannelMessage message) {
    if (isModelMessage(message)) {
      final modelId = message.meta!['model_id'] as String?;
      return buildModelAvatarUrl(api, modelId);
    }
    return resolveUserProfileImageUrl(api, message.user?.profileImageUrl);
  }

  Future<void> _showMemberList() async {
    final api = ref.read(apiServiceProvider);
    if (api == null) return;
    final theme = context.conduitTheme;

    try {
      final result = await api.getChannelMembers(widget.channelId);
      if (!mounted) return;
      final users = (result['users'] as List<dynamic>?) ?? [];
      final total = (result['total'] as int?) ?? users.length;

      showModalBottomSheet<void>(
        context: context,
        backgroundColor: theme.surfaceContainer,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppBorderRadius.bottomSheet),
          ),
        ),
        builder: (ctx) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.6,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(Spacing.md),
                  child: Text(
                    'Members ($total)',
                    style: AppTypography.titleMediumStyle.copyWith(
                      color: theme.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const Divider(height: 1),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: users.length,
                    itemBuilder: (ctx, index) {
                      final u = users[index] as Map<String, dynamic>;
                      final name = u['name'] as String? ?? 'Unknown';
                      final role = u['role'] as String? ?? '';
                      return ListTile(
                        leading: CircleAvatar(
                          radius: 16,
                          child: Text(
                            name[0].toUpperCase(),
                            style: AppTypography.labelMediumStyle,
                          ),
                        ),
                        title: Text(
                          name,
                          style: AppTypography.bodyMediumStyle.copyWith(
                            color: theme.textPrimary,
                          ),
                        ),
                        subtitle: role.isNotEmpty
                            ? Text(
                                role,
                                style: AppTypography.bodySmallStyle.copyWith(
                                  color: theme.textSecondary,
                                ),
                              )
                            : null,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } catch (e, st) {
      developer.log(
        'Failed to load members',
        name: 'ChannelPage',
        error: e,
        stackTrace: st,
      );
    }
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
          child: Text(l10n?.channelEdit ?? 'Edit Channel'),
        ),
        PopupMenuItem(
          value: 'leave',
          child: Text(l10n?.channelLeave ?? 'Leave Channel'),
        ),
        PopupMenuItem(
          value: 'delete',
          child: Text(
            l10n?.channelDelete ?? 'Delete Channel',
            style: AppTypography.bodyMediumStyle.copyWith(color: theme.error),
          ),
        ),
      ],
      child: FloatingAppBarPill(
        isCircular: true,
        child: Icon(
          Platform.isIOS ? CupertinoIcons.ellipsis_vertical : Icons.more_vert,
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
    this.avatarUrl,
    this.showProfile = true,
    required this.currentUserId,
    required this.isEditing,
    this.editController,
    this.onSubmitEdit,
    this.onCancelEdit,
    required this.onLongPress,
    required this.onReactionTap,
    this.onThreadTap,
  });

  final ChannelMessage message;
  final String? avatarUrl;

  /// Whether to show the avatar and sender name.
  /// False for consecutive messages from the same
  /// sender.
  final bool showProfile;
  final String? currentUserId;
  final bool isEditing;
  final TextEditingController? editController;
  final VoidCallback? onSubmitEdit;
  final VoidCallback? onCancelEdit;
  final VoidCallback onLongPress;
  final ValueChanged<String> onReactionTap;
  final VoidCallback? onThreadTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final timestamp = _formatTimestamp(message.createdDateTime);

    return InkWell(
      onLongPress: onLongPress,
      child: Padding(
        padding: EdgeInsets.only(
          left: Spacing.md,
          right: Spacing.md,
          top: showProfile ? Spacing.sm : 1,
          bottom: 1,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showProfile)
              _buildAvatar(theme)
            else
              SizedBox(width: _avatarSize),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (showProfile) ...[
                    _buildHeader(theme, timestamp),
                    const SizedBox(height: Spacing.xxs),
                  ],
                  if (message.replyToMessage != null)
                    Container(
                      margin: const EdgeInsets.only(bottom: Spacing.xxs),
                      padding: const EdgeInsets.only(left: Spacing.sm),
                      decoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(
                            color: Theme.of(context).colorScheme.primary,
                            width: 2,
                          ),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            message.replyToMessage!.userName,
                            style: AppTypography.labelMediumStyle.copyWith(
                              color: Theme.of(context).colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            message.replyToMessage!.content,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.bodySmallStyle.copyWith(
                              color: theme.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    )
                  else if (message.replyToId != null)
                    Container(
                      margin: const EdgeInsets.only(bottom: Spacing.xxs),
                      padding: const EdgeInsets.only(left: Spacing.sm),
                      decoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(
                            color: Theme.of(context).colorScheme.primary,
                            width: 2,
                          ),
                        ),
                      ),
                      child: Text(
                        'Reply',
                        style: AppTypography.bodySmallStyle.copyWith(
                          color: theme.textSecondary,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                  if (message.isPinned)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Spacing.xxs),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.push_pin_outlined,
                            size: 14,
                            color: theme.textPrimary.withValues(alpha: 0.6),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Pinned',
                            style: AppTypography.bodySmallStyle.copyWith(
                              color: theme.textPrimary.withValues(alpha: 0.6),
                              height: 1.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (isEditing)
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: editController,
                            autofocus: true,
                            style: AppTypography.chatMessageStyle.copyWith(
                              color: theme.textPrimary,
                            ),
                            decoration: InputDecoration(
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: Spacing.sm,
                                vertical: Spacing.xs,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            onSubmitted: (_) => onSubmitEdit?.call(),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.check, size: 18),
                          onPressed: onSubmitEdit,
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: onCancelEdit,
                        ),
                      ],
                    )
                  else
                    RichText(
                      text: buildMentionSpan(
                        content: message.content,
                        baseStyle: AppTypography.chatMessageStyle.copyWith(
                          color: theme.textPrimary,
                        ),
                        mentionColor: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  if (message.replyCount > 0 && onThreadTap != null)
                    Padding(
                      padding: const EdgeInsets.only(top: Spacing.xxs),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: onThreadTap,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '${message.replyCount} '
                              '${message.replyCount == 1 ? "reply" : "replies"}',
                              style: AppTypography.bodySmallStyle.copyWith(
                                color: theme.textPrimary.withValues(alpha: 0.6),
                                height: 1.3,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              Icons.chevron_right_rounded,
                              size: 16,
                              color: theme.textPrimary.withValues(alpha: 0.6),
                            ),
                          ],
                        ),
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

  static const double _avatarSize = 28;

  Widget _buildAvatar(ConduitThemeExtension theme) {
    if (isModelMessage(message)) {
      return ModelAvatar(
        size: _avatarSize,
        imageUrl: avatarUrl,
        label: messageDisplayName(message),
      );
    }
    return UserAvatar(
      size: _avatarSize,
      imageUrl: avatarUrl,
      fallbackText: message.userName,
    );
  }

  Widget _buildHeader(ConduitThemeExtension theme, String timestamp) {
    return Row(
      children: [
        Flexible(
          child: Text(
            messageDisplayName(message),
            style: AppTypography.bodySmallStyle.copyWith(
              color: theme.textSecondary,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.1,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: Spacing.sm),
        Text(
          timestamp,
          style: AppTypography.labelSmallStyle.copyWith(
            color: theme.textSecondary,
          ),
        ),
      ],
    );
  }

  Widget _buildReactions(BuildContext context, ConduitThemeExtension theme) {
    final primaryColor = Theme.of(context).colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.only(top: Spacing.xs),
      child: Wrap(
        spacing: Spacing.xs,
        runSpacing: Spacing.xs,
        children: message.reactions.map((reaction) {
          final isActive = reaction.users.any(
            (u) => u['user_id'] == currentUserId || u['id'] == currentUserId,
          );
          return ActionChip(
            label: Text(
              '${reaction.name} ${reaction.count}',
              style: AppTypography.labelMediumStyle,
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
              borderRadius: BorderRadius.circular(AppBorderRadius.chip),
            ),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onPressed: () => onReactionTap(reaction.name),
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
