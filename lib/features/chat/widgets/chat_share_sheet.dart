import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/haptic_service.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart' as chat;
import 'package:conduit/features/chat/utils/chat_share_url.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/sheet_handle.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

Future<void> showChatShareSheet({
  required BuildContext context,
  required Conversation conversation,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => ChatShareSheet(conversation: conversation),
  );
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
