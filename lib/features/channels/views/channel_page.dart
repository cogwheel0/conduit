import 'dart:async';
import 'dart:io' show Platform;

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit/l10n/app_localizations.dart';

import '../../../core/models/channel.dart';
import '../../../core/models/channel_message.dart';
import '../../../core/models/prompt.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/navigation_service.dart';
import '../../../shared/theme/conduit_input_styles.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/responsive_drawer_layout.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../chat/widgets/composer_overflow_menu.dart';
import '../../chat/widgets/prompt_suggestion_overlay.dart';
import '../../prompts/providers/prompts_providers.dart';
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
  static final _promptBoundary = RegExp(r'\s');

  final ScrollController _scrollController = ScrollController();
  final TextEditingController _messageController =
      TextEditingController();
  final FocusNode _inputFocusNode = FocusNode();
  bool _isSending = false;
  bool _isLoadingMore = false;

  // Prompt command overlay state (@, /, #)
  bool _showPromptOverlay = false;
  String _currentPromptCommand = '';
  TextRange _currentPromptRange = TextRange.empty;
  int _promptSelectionIndex = 0;

  @override
  void initState() {
    super.initState();
    _messageController.addListener(_handleComposerChanged);
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
    _messageController
      ..removeListener(_handleComposerChanged)
      ..dispose();
    _inputFocusNode.dispose();
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

    final scrim = Platform.isIOS
        ? context.colorTokens.scrimMedium
        : context.colorTokens.scrimStrong;

    return ResponsiveDrawerLayout(
      maxFraction: isTablet ? 0.42 : 1.0,
      edgeFraction: isTablet ? 0.36 : 0.50,
      settleFraction: 0.06,
      scrimColor: scrim,
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
      extendBodyBehindAppBar: true,
      appBar: FloatingAppBar(
        leading: FloatingAppBarBackButton(
          onTap: () {
            ref.read(activeChannelProvider.notifier).clear();
            NavigationService.router.go(Routes.chat);
          },
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

  // ---------------------------------------------------------------------------
  // Prompt command detection (@, /, #)
  // ---------------------------------------------------------------------------

  void _handleComposerChanged() {
    final text = _messageController.text;
    final selection = _messageController.selection;
    setState(() {}); // rebuild for hasText

    if (!selection.isValid || !selection.isCollapsed) {
      if (_showPromptOverlay) {
        setState(() => _showPromptOverlay = false);
      }
      return;
    }

    final match = _resolvePromptCommand(text, selection);
    if (match != null) {
      final (command, start, end) = match;
      if (command != _currentPromptCommand) {
        setState(() {
          _showPromptOverlay = true;
          _currentPromptCommand = command;
          _currentPromptRange = TextRange(start: start, end: end);
          _promptSelectionIndex = 0;
        });
        // Lazy-load prompts list when '/' typed.
        if (command.startsWith('/')) {
          ref.read(promptsListProvider.future);
        }
      } else {
        _currentPromptRange = TextRange(start: start, end: end);
      }
    } else if (_showPromptOverlay) {
      setState(() {
        _showPromptOverlay = false;
        _currentPromptCommand = '';
        _currentPromptRange = TextRange.empty;
      });
    }
  }

  (String, int, int)? _resolvePromptCommand(
    String text,
    TextSelection selection,
  ) {
    final cursor = selection.baseOffset;
    if (cursor <= 0 || cursor > text.length) return null;

    var start = cursor - 1;
    while (start >= 0 && !_promptBoundary.hasMatch(text[start])) {
      start--;
    }
    start++;

    if (start >= cursor) return null;
    final candidate = text.substring(start, cursor);
    if (candidate.isEmpty) return null;
    final trigger = candidate[0];
    if (trigger != '/' && trigger != '#') return null;

    return (candidate, start, cursor);
  }

  void _applyPrompt(Prompt prompt) {
    final content = prompt.content;
    final text = _messageController.text;
    final range = _currentPromptRange;

    final before = text.substring(0, range.start);
    final after = text.substring(range.end);
    final newText = '$before$content$after';
    final newCursor = before.length + content.length;

    _messageController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newCursor),
    );

    setState(() {
      _showPromptOverlay = false;
      _currentPromptCommand = '';
      _currentPromptRange = TextRange.empty;
    });
  }

  List<Prompt> _filterPrompts(List<Prompt> prompts) {
    if (_currentPromptCommand.length <= 1) return prompts;
    final query = _currentPromptCommand.substring(1).toLowerCase();
    return prompts
        .where(
          (p) =>
              p.command.toLowerCase().contains(query) ||
              p.title.toLowerCase().contains(query),
        )
        .toList();
  }

  void _movePromptSelection(int delta) {
    setState(() {
      _promptSelectionIndex =
          (_promptSelectionIndex + delta).clamp(0, 99);
    });
  }

  void _hidePromptOverlay() {
    setState(() {
      _showPromptOverlay = false;
      _currentPromptCommand = '';
      _currentPromptRange = TextRange.empty;
    });
  }

  void _handleOverlayKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _movePromptSelection(1);
    } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _movePromptSelection(-1);
    } else if (event.logicalKey == LogicalKeyboardKey.escape) {
      _hidePromptOverlay();
    }
  }

  // ---------------------------------------------------------------------------
  // Overflow sheet (plus button)
  // ---------------------------------------------------------------------------

  void _showOverflowSheet() {
    HapticFeedback.selectionClick();
    final prevCanRequest = _inputFocusNode.canRequestFocus;
    final wasFocused = _inputFocusNode.hasFocus;
    _inputFocusNode.canRequestFocus = false;
    try {
      FocusScope.of(context).unfocus();
      SystemChannels.textInput.invokeMethod('TextInput.hide');
    } catch (_) {}

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => const ComposerOverflowSheet(),
    ).whenComplete(() {
      if (mounted) {
        _inputFocusNode.canRequestFocus = prevCanRequest;
        if (wasFocused) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _inputFocusNode.requestFocus();
          });
        }
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Input bar
  // ---------------------------------------------------------------------------

  Widget _buildInputBar(ConduitThemeExtension theme) {
    final bottomPadding =
        MediaQuery.of(context).viewPadding.bottom;
    final hasText = _messageController.text.trim().isNotEmpty;
    final sendEnabled = hasText && !_isSending;
    final shellRadius = BorderRadius.circular(
      AppBorderRadius.round,
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(
        Spacing.screenPadding,
        0,
        Spacing.screenPadding,
        bottomPadding + Spacing.md,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Prompt suggestion overlay
          if (_showPromptOverlay &&
              _currentPromptCommand.startsWith('/'))
            Padding(
              padding: const EdgeInsets.only(bottom: Spacing.xs),
              child: PromptSuggestionOverlay(
                filteredPrompts: _filterPrompts,
                selectionIndex: _promptSelectionIndex,
                onPromptSelected: _applyPrompt,
              ),
            ),
          // Composer shell
          _buildComposerShell(
            theme: theme,
            borderRadius: shellRadius,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // Plus / overflow button
                Padding(
                  padding: const EdgeInsets.only(
                    bottom: Spacing.xs,
                  ),
                  child: _buildComposerIconButton(
                    theme: theme,
                    onPressed: _showOverflowSheet,
                    size: 36.0,
                    child: Icon(
                      Platform.isIOS
                          ? CupertinoIcons.add
                          : Icons.add,
                      size: IconSize.large,
                      color: theme.textPrimary.withValues(
                        alpha: Alpha.strong,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: Spacing.xs),
                // Text field
                Expanded(
                  child: KeyboardListener(
                    focusNode: FocusNode(skipTraversal: true),
                    onKeyEvent: _showPromptOverlay
                        ? _handleOverlayKeyEvent
                        : null,
                    child: _buildComposerTextField(theme),
                  ),
                ),
                const SizedBox(width: Spacing.xs),
                // Send button
                Padding(
                  padding: const EdgeInsets.only(
                    bottom: Spacing.xs,
                  ),
                  child: _buildSendButton(
                    theme,
                    enabled: sendEnabled,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildComposerShell({
    required ConduitThemeExtension theme,
    required BorderRadius borderRadius,
    required Widget child,
  }) {
    if (!kIsWeb && Platform.isIOS) {
      return AdaptiveBlurView(
        blurStyle: BlurStyle.systemUltraThinMaterial,
        borderRadius: borderRadius,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.md, 0, Spacing.md, 0,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: TouchTarget.input,
            ),
            child: Center(child: child),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: theme.surfaceContainerHighest,
        borderRadius: borderRadius,
        border: Border.all(
          color: theme.cardBorder,
          width: BorderWidth.thin,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(
        Spacing.md, 0, Spacing.md, 0,
      ),
      constraints: const BoxConstraints(
        minHeight: TouchTarget.input,
      ),
      alignment: Alignment.center,
      child: child,
    );
  }

  Widget _buildComposerTextField(ConduitThemeExtension theme) {
    final textStyle = AppTypography.chatMessageStyle.copyWith(
      color: theme.inputText,
    );
    const contentPadding = EdgeInsets.symmetric(
      vertical: Spacing.xs,
    );
    const hint = 'Message...';

    if (!kIsWeb && Platform.isIOS) {
      return CupertinoTextField(
        controller: _messageController,
        focusNode: _inputFocusNode,
        style: textStyle,
        placeholder: hint,
        placeholderStyle: textStyle.copyWith(
          color: theme.inputPlaceholder,
        ),
        decoration: const BoxDecoration(),
        padding: contentPadding,
        textCapitalization: TextCapitalization.sentences,
        textInputAction: TextInputAction.newline,
        keyboardType: TextInputType.multiline,
        minLines: 1,
        maxLines: null,
        keyboardAppearance:
            Theme.of(context).brightness,
        onSubmitted: (_) => _sendMessage(),
      );
    }

    return TextField(
      controller: _messageController,
      focusNode: _inputFocusNode,
      style: textStyle,
      decoration: context.conduitInputStyles.borderless(
        hint: hint,
      ).copyWith(
        contentPadding: contentPadding,
        isDense: true,
      ),
      textCapitalization: TextCapitalization.sentences,
      textInputAction: TextInputAction.newline,
      keyboardType: TextInputType.multiline,
      minLines: 1,
      maxLines: null,
      onSubmitted: (_) => _sendMessage(),
    );
  }

  Widget _buildComposerIconButton({
    required ConduitThemeExtension theme,
    required VoidCallback? onPressed,
    required Widget child,
    required double size,
    bool isProminent = false,
    Color? color,
  }) {
    final effectiveColor = color ?? theme.buttonPrimary;

    if (!kIsWeb && Platform.isIOS) {
      return AdaptiveButton.child(
        onPressed: onPressed,
        enabled: onPressed != null,
        style: isProminent
            ? AdaptiveButtonStyle.prominentGlass
            : AdaptiveButtonStyle.glass,
        color: effectiveColor,
        size: size > 40
            ? AdaptiveButtonSize.large
            : AdaptiveButtonSize.medium,
        minSize: Size(size, size),
        padding: EdgeInsets.zero,
        borderRadius: BorderRadius.circular(size),
        useSmoothRectangleBorder: false,
        child: child,
      );
    }

    final bgColor = isProminent
        ? effectiveColor
        : theme.surfaceContainerHighest;
    final borderColor = isProminent
        ? effectiveColor
        : theme.cardBorder;

    return SizedBox(
      width: size,
      height: size,
      child: Material(
        color: bgColor,
        shape: CircleBorder(
          side: BorderSide(
            color: borderColor,
            width: BorderWidth.thin,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: Center(child: child),
        ),
      ),
    );
  }

  Widget _buildSendButton(
    ConduitThemeExtension theme, {
    required bool enabled,
  }) {
    const double size = 36.0;
    final iconColor = enabled
        ? theme.buttonPrimaryText
        : theme.textPrimary.withValues(alpha: Alpha.disabled);

    return _buildComposerIconButton(
      theme: theme,
      onPressed: enabled ? _sendMessage : null,
      size: size,
      isProminent: true,
      child: Icon(
        CupertinoIcons.arrow_up,
        size: IconSize.large,
        color: iconColor,
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
