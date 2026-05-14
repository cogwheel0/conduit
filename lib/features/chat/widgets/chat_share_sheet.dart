import 'dart:io' show Platform;

import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/haptic_service.dart';
import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart' as chat;
import 'package:conduit/features/chat/utils/chat_share_url.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/sheet_handle.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

Future<void> showChatShareSheet({
  required BuildContext context,
  required Conversation conversation,
}) async {
  if (Platform.isIOS) {
    try {
      return await _showNativeChatShareSheet(
        context: context,
        conversation: conversation,
      );
    } catch (_) {
      if (!context.mounted) {
        return;
      }
    }
  }
  return ThemedSheets.showCustom<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (_) => ChatShareSheet(conversation: conversation),
  );
}

Future<void> _showNativeChatShareSheet({
  required BuildContext context,
  required Conversation conversation,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final l10n = AppLocalizations.of(context)!;

  void showMessage(String message) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<String> ensureShareUrl() async {
    final api = container.read(apiServiceProvider);
    if (api == null) {
      throw StateError('API service not available');
    }

    final shareId = await api.shareConversation(conversation.id);
    if (shareId == null || shareId.isEmpty) {
      throw StateError('Share id missing');
    }
    container
        .read(conversationsProvider.notifier)
        .updateConversationFromRemote(
          conversation.id,
          (current) =>
              current.copyWith(shareId: shareId, updatedAt: DateTime.now()),
        );
    refreshConversationsCache(container);
    final activeConversation = container.read(activeConversationProvider);
    if (activeConversation?.id == conversation.id) {
      container
          .read(activeConversationProvider.notifier)
          .set(activeConversation!.copyWith(shareId: shareId));
    }
    return buildChatShareUrl(serverUrl: api.baseUrl, shareId: shareId);
  }

  Future<void> copyLink() async {
    try {
      final url = await ensureShareUrl();
      await Clipboard.setData(ClipboardData(text: url));
      ConduitHaptics.success();
      showMessage(l10n.sharedChatCopied);
    } catch (_) {
      showMessage(l10n.chatShareFailed);
    }
  }

  Future<void> shareLink() async {
    try {
      final url = await ensureShareUrl();
      await SharePlus.instance.share(ShareParams(text: url));
    } catch (_) {
      showMessage(l10n.chatShareFailed);
    }
  }

  Future<void> deleteLink() async {
    try {
      final api = container.read(apiServiceProvider);
      if (api == null) {
        throw StateError('API service not available');
      }
      await api.deleteSharedConversation(conversation.id);
      container
          .read(conversationsProvider.notifier)
          .updateConversationFromRemote(
            conversation.id,
            (current) =>
                current.copyWith(shareId: null, updatedAt: DateTime.now()),
          );
      refreshConversationsCache(container);
      final activeConversation = container.read(activeConversationProvider);
      if (activeConversation?.id == conversation.id) {
        container
            .read(activeConversationProvider.notifier)
            .set(activeConversation!.copyWith(shareId: null));
      }
      ConduitHaptics.success();
      showMessage(l10n.sharedLinkDeleted);
    } catch (_) {
      showMessage(l10n.deleteSharedLinkFailed);
    }
  }

  final hasExistingShare = conversation.shareId?.isNotEmpty == true;
  final result = await NativeSheetBridge.instance.presentSheet(
    root: NativeSheetDetailConfig(
      id: 'chat-share',
      title: l10n.shareChat,
      subtitle: hasExistingShare
          ? l10n.shareChatExisting
          : l10n.shareChatDescription,
      items: [
        NativeSheetItemConfig(
          id: 'copy-link',
          title: hasExistingShare ? l10n.updateAndCopyLink : l10n.copyLink,
          subtitle: l10n.sharedChatCopied,
          sfSymbol: 'doc.on.doc',
        ),
        NativeSheetItemConfig(
          id: 'share-link',
          title: l10n.shareSystemSheet,
          subtitle: l10n.shareChatDescription,
          sfSymbol: 'square.and.arrow.up',
        ),
        if (hasExistingShare)
          NativeSheetItemConfig(
            id: 'delete-link',
            title: l10n.shareChatDeleteLink,
            subtitle: l10n.shareChatDeleteAndCreate,
            sfSymbol: 'trash',
            destructive: true,
          ),
      ],
    ),
    rethrowErrors: true,
  );

  switch (result?.actionId) {
    case 'copy-link':
      await copyLink();
      break;
    case 'share-link':
      await shareLink();
      break;
    case 'delete-link':
      await deleteLink();
      break;
  }
}

class ChatShareSheet extends ConsumerStatefulWidget {
  ChatShareSheet({
    super.key,
    required this.conversation,
    Future<ShareResult> Function(ShareParams params)? share,
  }) : share = share ?? SharePlus.instance.share;

  final Conversation conversation;
  final Future<ShareResult> Function(ShareParams params) share;

  @override
  ConsumerState<ChatShareSheet> createState() => _ChatShareSheetState();
}

class _ChatShareSheetState extends ConsumerState<ChatShareSheet> {
  String? _shareId;
  bool _isSharing = false;
  bool _isDeleting = false;

  @override
  void initState() {
    super.initState();
    _shareId = widget.conversation.shareId;
  }

  Future<String> _ensureShareUrl() async {
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      throw StateError('API service not available');
    }

    // Open WebUI re-snapshots an existing share each time the user copies the
    // link, so the URL points at the latest persisted conversation state.
    var shareId = await chat.shareConversation(ref, widget.conversation.id);
    if (shareId == null || shareId.isEmpty) {
      throw StateError('Server did not return a share ID');
    }
    if (mounted) {
      setState(() => _shareId = shareId);
    }

    return buildChatShareUrl(serverUrl: api.baseUrl, shareId: shareId);
  }

  Future<void> _copyLink() async {
    if (_isSharing || _isDeleting) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() => _isSharing = true);
    try {
      final url = await _ensureShareUrl();
      await Clipboard.setData(ClipboardData(text: url));
      ConduitHaptics.success();
      _showSnack(l10n.sharedChatCopied);
    } catch (_) {
      _showSnack(l10n.chatShareFailed);
    } finally {
      if (mounted) {
        setState(() => _isSharing = false);
      }
    }
  }

  Future<void> _shareLink() async {
    if (_isSharing || _isDeleting) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() => _isSharing = true);
    try {
      final url = await _ensureShareUrl();
      await widget.share(ShareParams(text: url));
    } catch (_) {
      _showSnack(l10n.chatShareFailed);
    } finally {
      if (mounted) {
        setState(() => _isSharing = false);
      }
    }
  }

  Future<void> _deleteLink() async {
    if (_isDeleting || _isSharing) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() => _isDeleting = true);
    try {
      await chat.deleteSharedConversation(ref, widget.conversation.id);
      if (mounted) {
        setState(() => _shareId = null);
      }
      ConduitHaptics.success();
      _showSnack(l10n.sharedLinkDeleted);
    } catch (_) {
      _showSnack(l10n.deleteSharedLinkFailed);
    } finally {
      if (mounted) {
        setState(() => _isDeleting = false);
      }
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final shareId = _shareId;
    final hasExistingShare = shareId != null && shareId.isNotEmpty;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.surfaceBackground,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppBorderRadius.xl),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Spacing.lg,
          0,
          Spacing.lg,
          Spacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHandle(),
            Row(
              children: [
                Icon(
                  CupertinoIcons.link,
                  color: theme.iconPrimary,
                  size: IconSize.lg,
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Text(
                    l10n.shareChat,
                    style: AppTypography.headlineSmallStyle.copyWith(
                      color: theme.textPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: l10n.closeButtonSemantic,
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: Icon(
                    CupertinoIcons.xmark,
                    color: theme.iconSecondary,
                    size: IconSize.md,
                  ),
                ),
              ],
            ),
            const SizedBox(height: Spacing.md),
            Text(
              hasExistingShare
                  ? l10n.shareChatExisting
                  : l10n.shareChatDescription,
              style: AppTypography.bodyMediumStyle.copyWith(
                color: theme.textSecondary,
                height: 1.35,
              ),
            ),
            if (hasExistingShare) ...[
              const SizedBox(height: Spacing.md),
              TextButton(
                onPressed: _isDeleting || _isSharing ? null : _deleteLink,
                child: Text(
                  '${l10n.shareChatDeleteLink} '
                  '${l10n.shareChatDeleteAndCreate}',
                ),
              ),
            ],
            const SizedBox(height: Spacing.lg),
            ConduitButton(
              text: hasExistingShare ? l10n.updateAndCopyLink : l10n.copyLink,
              onPressed: _isDeleting ? null : _copyLink,
              isLoading: _isSharing,
              icon: CupertinoIcons.doc_on_clipboard,
              isFullWidth: true,
            ),
            const SizedBox(height: Spacing.sm),
            ConduitButton(
              text: l10n.shareSystemSheet,
              onPressed: _isDeleting ? null : _shareLink,
              isSecondary: true,
              icon: CupertinoIcons.share,
              isFullWidth: true,
            ),
          ],
        ),
      ),
    );
  }
}
