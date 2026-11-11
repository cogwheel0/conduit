import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/features/sharing/models/resource_access.dart';
import 'package:conduit_core/features/sharing/providers/resource_access_controller.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit/features/workspace/widgets/resource_sharing_sheet.dart';
import 'package:conduit/core/services/haptic_service.dart';
import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    as chat;
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
  // A LibreChat link opens for whoever has it (signed in to the server,
  // unless it allows anonymous viewing); there is no audience to choose.
  if (isLibreChatConversation(conversation)) return null;
  return ResourceAccessController.open(
    ref,
    kind: ResourceKind.chat,
    resourceId: conversation.id,
  );
}

/// How long the share sheet waits to learn whether a LibreChat chat has a
/// link before it shows what the chat itself knows.
const Duration _libreChatLinkLookupTimeout = Duration(seconds: 5);

/// Asks LibreChat for chat [conversationId]'s link for as long as the sheet
/// waits. An answer that comes later is dropped, not recorded on the chat,
/// so copying never updates a link the sheet did not show.
Future<String?> _lookUpLibreChatLinkInTime(
  dynamic ref,
  String conversationId,
) => chat.lookUpLibreChatShareLink(
  ref,
  conversationId,
  timeout: _libreChatLinkLookupTimeout,
);

/// The share id of LibreChat chat [conversationId]'s link as its server
/// knows it, empty when it has none; null when the server could not say.
/// LibreChat's conversation does not carry its link, so one made in its web
/// app or on another device is only known once looked up.
Future<String?> _lookUpLibreChatLink(
  dynamic ref,
  String conversationId, {
  Future<String?> Function(dynamic ref, String conversationId) lookUp =
      _lookUpLibreChatLinkInTime,
}) async {
  try {
    return await lookUp(ref, conversationId) ?? '';
  } catch (_) {
    return null;
  }
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
  if (isLibreChatConversation(conversation)) {
    // The native sheet cannot change once shown: find out first whether the
    // chat has a link made elsewhere, so it offers to update or delete it.
    final askedFor = container.read(activeLibreChatAccountProvider)?.id;
    final found = await _lookUpLibreChatLink(container, conversationId);
    if (found != null) hasExistingShare = found.isNotEmpty;
    if (!context.mounted) return;
    // Another account in use now would share or delete through its own
    // server, which can hold a chat with the same id: no sheet.
    if (container.read(activeLibreChatAccountProvider)?.id != askedFor) {
      return;
    }
  }
  // LibreChat asks its role's permission to make or update a link, not to
  // delete one: a chat with a link and no permission offers only the delete.
  // Read once the link is looked up, which gives permissions still loading
  // as long to arrive: the sheet cannot change once shown.
  final canPublish =
      !isLibreChatConversation(conversation) ||
      (container
              .read(libreChatCapabilitiesProvider)
              .asData
              ?.value
              .sharedLinks ??
          false);

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
    final link = await chat.shareConversationLink(container, conversationId);
    hasExistingShare = true;
    return link.url;
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
      // The delete reaches the chat's own server (Open WebUI or LibreChat)
      // and checks for its client itself.
      await chat.deleteConversationShareLink(container, conversationId);
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
          if (canPublish)
            NativeSheetSectionConfig(
              items: [
                NativeSheetItemConfig(
                  id: 'copy-link',
                  title: hasExistingShare
                      ? l10n.updateAndCopyLink
                      : l10n.copyLink,
                  sfSymbol: 'square.on.square',
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
    Future<String?> Function(dynamic ref, String conversationId)?
    lookUpLibreChatLink,
  }) : share = share ?? SharePlus.instance.share,
       lookUpLibreChatLink =
           lookUpLibreChatLink ?? _lookUpLibreChatLinkInTime;

  final Conversation conversation;
  final Future<ShareResult> Function(ShareParams params) share;

  /// Asks LibreChat for a LibreChat chat's link without publishing it.
  final Future<String?> Function(dynamic ref, String conversationId)
  lookUpLibreChatLink;

  @override
  ConsumerState<ChatShareSheet> createState() => _ChatShareSheetState();
}

class _ChatShareSheetState extends ConsumerState<ChatShareSheet> {
  late final String _conversationSelectionId;

  /// The app's container, which outlives the sheet: a request still out when
  /// the sheet closes records its answer through it.
  late final ProviderContainer _container;
  ResourceAccessController? _audience;
  String? _shareId;
  bool _isSharing = false;
  bool _isDeleting = false;
  bool _isLookingUp = false;

  @override
  void initState() {
    super.initState();
    _conversationSelectionId = conversationScopedId(widget.conversation);
    _container = ProviderScope.containerOf(context, listen: false);
    _shareId = widget.conversation.shareId;
    // Captured as the share flow opens, before any request or confirmation.
    _audience = _openAudience(ref, widget.conversation);
    if (isLibreChatConversation(widget.conversation)) {
      _isLookingUp = true;
      _lookUpLink();
    }
  }

  /// Finds a link the LibreChat chat got elsewhere before anything can be
  /// copied, so copying never updates a link the sheet did not show.
  Future<void> _lookUpLink() async {
    final found = await _lookUpLibreChatLink(
      _container,
      _conversationSelectionId,
      lookUp: widget.lookUpLibreChatLink,
    );
    if (!mounted) return;
    setState(() {
      if (found != null) _shareId = found.isEmpty ? null : found;
      _isLookingUp = false;
    });
  }

  Future<String> _ensureShareUrl() async {
    // An existing share is snapshotted again each time the user copies the
    // link, so the URL points at the latest persisted conversation state.
    final link = await chat.shareConversationLink(
      _container,
      _conversationSelectionId,
    );
    if (mounted) {
      setState(() => _shareId = link.shareId);
    }
    return link.url;
  }

  Future<void> _copyLink() async {
    if (_isSharing || _isDeleting || _isLookingUp) return;
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
    if (_isSharing || _isDeleting || _isLookingUp) return;
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
      await chat.deleteConversationShareLink(
        _container,
        _conversationSelectionId,
      );
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
    // LibreChat asks its role's permission to make or update a link, not to
    // delete one: a chat with a link and no permission offers only the
    // delete.
    final canPublish =
        !isLibreChatConversation(widget.conversation) ||
        ref.watch(
          libreChatCapabilitiesProvider.select(
            (capabilities) => capabilities.asData?.value.sharedLinks ?? false,
          ),
        );

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
            if (canPublish) ...[
              const SizedBox(height: Spacing.lg),
              ConduitButton(
                key: const Key('chat-share-copy'),
                text: hasExistingShare
                    ? l10n.updateAndCopyLink
                    : l10n.copyLink,
                onPressed: _isDeleting || _isLookingUp ? null : _copyLink,
                isLoading: _isSharing || _isLookingUp,
                icon: CupertinoIcons.square_on_square,
                isFullWidth: true,
              ),
              const SizedBox(height: Spacing.sm),
              ConduitButton(
                key: const Key('chat-share-system'),
                text: l10n.shareSystemSheet,
                onPressed: _isDeleting || _isLookingUp ? null : _shareLink,
                isSecondary: true,
                icon: CupertinoIcons.share,
                isFullWidth: true,
              ),
            ],
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
                    // Like the native sheet: the action, then what it means.
                    title: l10n.shareChatDeleteLink,
                    subtitle: l10n.shareChatDeleteAndCreate,
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
