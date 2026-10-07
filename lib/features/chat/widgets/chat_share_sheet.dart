import 'package:conduit_core/features/sharing/models/resource_access.dart';
import 'package:conduit_core/features/sharing/providers/resource_access_controller.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit/features/workspace/widgets/resource_sharing_sheet.dart';
import 'package:conduit/core/services/haptic_service.dart';
import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    as chat;
import 'package:conduit_core/features/chat/utils/chat_share_url.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/sheet_handle.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';
import 'package:conduit/shared/widgets/utility_components.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

/// Opens the Audience session for [conversation], or returns null when there
/// is no signed-in session to open it in. The key is the chat's own id: the
/// link's `share_id` names a snapshot, and the grants hang off the chat.
ResourceAccessController? _openAudience(
  dynamic ref,
  Conversation conversation,
) {
  return ResourceAccessController.open(
    ref,
    kind: ResourceKind.chat,
    resourceId: conversation.id,
  );
}

Future<void> showChatShareSheet({
  required BuildContext context,
  required Conversation conversation,
}) async {
  if (PlatformUiCapabilities.isIOS) {
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
  final conversationId = conversationScopedId(conversation);
  var hasExistingShare = conversation.shareId?.isNotEmpty == true;

  void showMessage(
    String message, {
    AdaptiveSnackBarType type = AdaptiveSnackBarType.info,
  }) {
    if (!context.mounted) return;
    AdaptiveSnackBar.show(context, message: message, type: type);
  }

  Rect? shareOriginForContext() {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      return null;
    }
    return renderObject.localToGlobal(Offset.zero) & renderObject.size;
  }

  Future<String> ensureShareUrl() async {
    final api = container.read(apiServiceProvider);
    if (api == null) {
      throw StateError('API service not available');
    }

    final shareId = await chat.shareConversation(container, conversationId);
    if (shareId == null || shareId.isEmpty) {
      throw StateError('Share id missing');
    }
    hasExistingShare = true;
    return buildChatShareUrl(serverUrl: api.baseUrl, shareId: shareId);
  }

  /// Copies the link; [announce] is false when the sheet comes straight back
  /// and says so itself, since a toast would sit behind it.
  Future<void> copyLink({required bool announce}) async {
    try {
      final url = await ensureShareUrl();
      await Clipboard.setData(ClipboardData(text: url));
      ConduitHaptics.success();
      if (announce) {
        showMessage(
          l10n.sharedChatCopied,
          type: AdaptiveSnackBarType.success,
        );
      }
    } catch (_) {
      showMessage(l10n.chatShareFailed, type: AdaptiveSnackBarType.error);
    }
  }

  Future<void> shareLink() async {
    try {
      final url = await ensureShareUrl();
      await SharePlus.instance.share(
        ShareParams(text: url, sharePositionOrigin: shareOriginForContext()),
      );
    } catch (_) {
      showMessage(l10n.chatShareFailed, type: AdaptiveSnackBarType.error);
    }
  }

  Future<void> deleteLink() async {
    try {
      final api = container.read(apiServiceProvider);
      if (api == null) {
        throw StateError('API service not available');
      }
      await chat.deleteSharedConversation(container, conversationId);
      hasExistingShare = false;
      ConduitHaptics.success();
      showMessage(l10n.sharedLinkDeleted, type: AdaptiveSnackBarType.success);
    } catch (_) {
      showMessage(
        l10n.deleteSharedLinkFailed,
        type: AdaptiveSnackBarType.error,
      );
    }
  }

  // Captured once, when the share flow opens, not when Who has access is
  // chosen. The row itself only shows while the chat has a link.
  final audience = _openAudience(container, conversation);

  // The native sheet closes on every action. A link created from it brings
  // the sheet straight back, so who has access can be chosen right away.
  var linkJustCopied = false;
  for (var pass = 0; pass < 2; pass++) {
    final reopened = pass > 0;
    final hadLink = hasExistingShare;
    final result = await NativeSheetBridge.instance.presentSheet(
      root: NativeSheetDetailConfig(
        id: 'chat-share',
        title: l10n.shareChat,
        subtitle: linkJustCopied
            ? l10n.sharedChatCopied
            : hasExistingShare
            ? l10n.shareChatExisting
            : l10n.shareChatDescription,
        sections: [
          NativeSheetSectionConfig(
            items: [
              NativeSheetItemConfig(
                id: 'copy-link',
                title: hasExistingShare
                    ? l10n.updateAndCopyLink
                    : l10n.copyLink,
                sfSymbol: 'doc.on.doc',
              ),
              NativeSheetItemConfig(
                id: 'share-link',
                title: l10n.shareSystemSheet,
                sfSymbol: 'square.and.arrow.up',
              ),
            ],
          ),
          if (hasExistingShare && audience != null)
            NativeSheetSectionConfig(
              items: [
                NativeSheetItemConfig(
                  id: 'audience',
                  title: l10n.chatShareAudience,
                  subtitle: l10n.chatShareAudienceDescription,
                  sfSymbol: 'person.2',
                  showsDisclosure: true,
                ),
              ],
            ),
          if (hasExistingShare)
            NativeSheetSectionConfig(
              items: [
                NativeSheetItemConfig(
                  id: 'delete-link',
                  title: l10n.shareChatDeleteLink,
                  subtitle: l10n.shareChatDeleteAndCreate,
                  sfSymbol: 'trash',
                  destructive: true,
                ),
              ],
            ),
        ],
      ),
      // The first presentation falls back to the Flutter sheet on failure;
      // a failed return trip just ends the flow.
      rethrowErrors: !reopened,
    );

    final actionId = result?.actionId;
    final reopenAfterLink =
        !hadLink &&
        audience != null &&
        (actionId == 'copy-link' || actionId == 'share-link');
    linkJustCopied = false;
    switch (actionId) {
      case 'copy-link':
        await copyLink(announce: !reopenAfterLink);
        linkJustCopied = hasExistingShare;
        break;
      case 'share-link':
        await shareLink();
        break;
      case 'delete-link':
        await deleteLink();
        break;
      case 'audience':
        if (audience != null && context.mounted) {
          await ResourceSharingSheet.showWith(
            context,
            audience,
            resourceName: conversation.title,
          );
        }
        break;
    }

    if (!reopenAfterLink || !hasExistingShare || !context.mounted) break;
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
  late final String _conversationSelectionId;
  ResourceAccessController? _audience;
  String? _shareId;
  bool _isSharing = false;
  bool _isDeleting = false;

  @override
  void initState() {
    super.initState();
    _conversationSelectionId = conversationScopedId(widget.conversation);
    _shareId = widget.conversation.shareId;
    // Captured as the share flow opens, before any request or confirmation.
    _audience = _openAudience(ref, widget.conversation);
  }

  Future<String> _ensureShareUrl() async {
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      throw StateError('API service not available');
    }

    // Open WebUI re-snapshots an existing share each time the user copies the
    // link, so the URL points at the latest persisted conversation state.
    var shareId = await chat.shareConversation(ref, _conversationSelectionId);
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
      _showSnack(
        l10n.sharedChatCopied,
        type: AdaptiveSnackBarType.success,
      );
    } catch (_) {
      _showSnack(l10n.chatShareFailed, type: AdaptiveSnackBarType.error);
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
      _showSnack(l10n.chatShareFailed, type: AdaptiveSnackBarType.error);
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
      await chat.deleteSharedConversation(ref, _conversationSelectionId);
      if (mounted) {
        setState(() => _shareId = null);
      }
      ConduitHaptics.success();
      _showSnack(
        l10n.sharedLinkDeleted,
        type: AdaptiveSnackBarType.success,
      );
    } catch (_) {
      _showSnack(
        l10n.deleteSharedLinkFailed,
        type: AdaptiveSnackBarType.error,
      );
    } finally {
      if (mounted) {
        setState(() => _isDeleting = false);
      }
    }
  }

  void _showSnack(
    String message, {
    AdaptiveSnackBarType type = AdaptiveSnackBarType.info,
  }) {
    if (!mounted) return;
    AdaptiveSnackBar.show(context, message: message, type: type);
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
                SheetCloseButton(
                  tooltip: l10n.closeButtonSemantic,
                  onPressed: () => Navigator.of(context).maybePop(),
                  color: theme.iconSecondary,
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
            const SizedBox(height: Spacing.lg),
            ConduitButton(
              key: const Key('chat-share-copy'),
              text: hasExistingShare ? l10n.updateAndCopyLink : l10n.copyLink,
              onPressed: _isDeleting ? null : _copyLink,
              isLoading: _isSharing,
              icon: CupertinoIcons.doc_on_clipboard,
              isFullWidth: true,
            ),
            const SizedBox(height: Spacing.sm),
            ConduitButton(
              key: const Key('chat-share-system'),
              text: l10n.shareSystemSheet,
              onPressed: _isDeleting ? null : _shareLink,
              isSecondary: true,
              icon: CupertinoIcons.share,
              isFullWidth: true,
            ),
            if (hasExistingShare && _audience != null) ...[
              const SizedBox(height: Spacing.lg),
              InsetGroupedList(
                children: [
                  UtilityRow(
                    key: const Key('chat-share-audience'),
                    title: l10n.chatShareAudience,
                    subtitle: l10n.chatShareAudienceDescription,
                    leading: Icon(
                      CupertinoIcons.person_2,
                      color: theme.iconPrimary,
                      size: IconSize.medium,
                    ),
                    showChevron: true,
                    onTap: () => ResourceSharingSheet.showWith(
                      context,
                      _audience!,
                      resourceName: widget.conversation.title,
                    ),
                  ),
                ],
              ),
            ],
            if (hasExistingShare) ...[
              const SizedBox(height: Spacing.md),
              InsetGroupedList(
                children: [
                  UtilityRow(
                    key: const Key('chat-share-delete'),
                    title:
                        '${l10n.shareChatDeleteLink} '
                        '${l10n.shareChatDeleteAndCreate}',
                    leading: Icon(
                      CupertinoIcons.trash,
                      color: theme.error,
                      size: IconSize.medium,
                    ),
                    destructive: true,
                    enabled: !_isSharing,
                    trailing: _isDeleting
                        ? const ConduitLoadingIndicator(
                            size: IconSize.small,
                            isCompact: true,
                          )
                        : null,
                    onTap: _isDeleting || _isSharing ? null : _deleteLink,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
