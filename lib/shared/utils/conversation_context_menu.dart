import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/primary_account_providers.dart';
import 'package:conduit_core/services/connectivity_service.dart' show isOnlineProvider;
import 'package:conduit_core/sync/chat_locks.dart';
import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/measure_size.dart';
import 'package:conduit/shared/widgets/themed_dialogs.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:conduit/core/services/haptic_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';

import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    as chat;
import 'package:conduit_core/features/chat/services/chat_title_generation.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit/features/chat/widgets/chat_share_sheet.dart';
import 'package:conduit/features/navigation/widgets/create_folder_dialog.dart';
import 'package:conduit/features/navigation/widgets/folder_tree_guides.dart';
import 'package:conduit/features/navigation/providers/conversation_selection_provider.dart';
import 'package:conduit/shared/services/navigation_service.dart';

/// Defines an action for use in Conduit context menus.
class ConduitContextMenuAction {
  final IconData cupertinoIcon;
  final String? sfSymbol;
  final IconData materialIcon;
  final String label;
  final Future<void> Function() onSelected;
  final VoidCallback? onBeforeClose;
  final bool destructive;

  const ConduitContextMenuAction({
    required this.cupertinoIcon,
    this.sfSymbol,
    required this.materialIcon,
    required this.label,
    required this.onSelected,
    this.onBeforeClose,
    this.destructive = false,
  });
}

/// A long-press context menu widget with platform-specific presentation.
///
/// The app keeps its own action model so call sites can share haptics and
/// icons while the menu presentation follows the current platform. On iOS we
/// keep the child size stable during preview because stock
/// [CupertinoContextMenu] can assert when the child is laid out by flex-based
/// parents.
class ConduitContextMenu extends StatefulWidget {
  final List<ConduitContextMenuAction> actions;
  final Widget child;
  final WidgetBuilder? topWidgetBuilder;

  /// Custom Flutter preview decoration. These menus retain the Flutter
  /// presentation; native menus lift the existing child without rebuilding it.
  final Widget Function(BuildContext context, Widget child)? previewBuilder;
  final bool stabilizePreviewSize;
  final bool useNativeMenu;

  const ConduitContextMenu({
    super.key,
    required this.actions,
    required this.child,
    this.topWidgetBuilder,
    this.previewBuilder,
    this.stabilizePreviewSize = true,
    this.useNativeMenu = true,
  });

  @override
  State<ConduitContextMenu> createState() => _ConduitContextMenuState();
}

class _ConduitContextMenuState extends State<ConduitContextMenu> {
  Size? _childSize;

  @override
  Widget build(BuildContext context) {
    if (widget.actions.isEmpty) {
      return widget.child;
    }

    final adaptiveActions = [
      for (final action in widget.actions)
        AdaptiveContextMenuAction(
          title: action.label,
          icon: action.materialIcon,
          iosSymbol: action.sfSymbol,
          isDestructive: action.destructive,
          onPressed: () {
            ConduitHaptics.selectionClick();
            action.onBeforeClose?.call();
            action.onSelected();
          },
        ),
    ];

    if (PlatformInfo.isIOS) {
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onSecondaryTapDown: (details) => showAdaptiveContextMenu(
          context: context,
          actions: adaptiveActions,
          globalAnchor: Rect.fromLTWH(
            details.globalPosition.dx,
            details.globalPosition.dy,
            0,
            0,
          ),
        ),
        child:
            widget.useNativeMenu &&
                widget.previewBuilder == null &&
                widget.topWidgetBuilder == null &&
                widget.actions.every((action) => action.sfSymbol != null) &&
                PlatformUiCapabilities.usesNativeIOS26
            ? NativeContextMenu(
                actions: adaptiveActions,
                fallbackBuilder: _buildCupertinoContextMenu,
                child: widget.child,
              )
            : _buildCupertinoContextMenu(context),
      );
    }

    return AdaptiveContextMenu(actions: adaptiveActions, child: widget.child);
  }

  Widget _buildCupertinoContextMenu(BuildContext context) {
    final contextMenu = CupertinoContextMenu.builder(
      actions: [
        for (final action in widget.actions)
          CupertinoContextMenuAction(
            isDestructiveAction: action.destructive,
            trailingIcon: action.cupertinoIcon,
            onPressed: () {
              Navigator.of(context, rootNavigator: true).pop();
              Future.microtask(() {
                ConduitHaptics.selectionClick();
                action.onBeforeClose?.call();
                action.onSelected();
              });
            },
            child: Text(action.label),
          ),
      ],
      builder: (context, animation) {
        final previewChild = IgnorePointer(
          ignoring: animation.value > 0,
          child: widget.child,
        );
        final size = widget.stabilizePreviewSize ? _childSize : null;
        Widget preview = previewChild;
        if (animation.value > 0 && size != null) {
          final mediaQuery = MediaQuery.of(context);
          // Only constrain the open preview, keeping the source layout stable.
          final maxHeight =
              animation.value > CupertinoContextMenu.animationOpensAt
              ? (mediaQuery.size.height - mediaQuery.padding.vertical) / 2
              : size.height;
          preview = SizedBox(
            width: size.width,
            height: size.height.clamp(0.0, maxHeight),
            child: ClipRect(
              child: OverflowBox(
                alignment: Alignment.topCenter,
                minHeight: size.height,
                maxHeight: size.height,
                child: previewChild,
              ),
            ),
          );
        }

        final previewBuilder = widget.previewBuilder;
        if (animation.value > 0 && previewBuilder != null) {
          preview = previewBuilder(context, preview);
        }

        final topWidgetBuilder = widget.topWidgetBuilder;
        if (animation.value > 0 && topWidgetBuilder != null) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              topWidgetBuilder(context),
              const SizedBox(height: Spacing.sm),
              preview,
            ],
          );
        }

        return preview;
      },
    );

    if (!widget.stabilizePreviewSize) {
      return contextMenu;
    }

    return MeasureSize(onChange: _handleChildSizeChanged, child: contextMenu);
  }

  void _handleChildSizeChanged(Size size) {
    if (!size.width.isFinite ||
        !size.height.isFinite ||
        size.width <= 0 ||
        size.height <= 0 ||
        _childSize == size) {
      return;
    }
    _childSize = size;
  }
}

/// Builds a list of actions for conversation context menus.
///
/// Use with [ConduitContextMenu]:
/// ```dart
/// ConduitContextMenu(
///   actions: buildConversationActions(context: context, ref: ref, conversation: conv),
///   child: MyWidget(),
/// )
/// ```
List<ConduitContextMenuAction> buildConversationActions({
  required BuildContext context,
  required WidgetRef ref,
  required dynamic conversation,
}) {
  final foldersEnabled = ref.watch(foldersAvailableProvider);
  final folders = foldersEnabled
      ? ref
            .watch(foldersProvider)
            .maybeWhen(
              data: (folders) => folders,
              orElse: () => const <Folder>[],
            )
      : const <Folder>[];

  return buildConversationActionsWithFolders(
    context: context,
    ref: ref,
    conversation: conversation,
    foldersEnabled: foldersEnabled,
    folders: folders,
  );
}

/// [canMarkUnread] offers "Mark as unread" for an Open WebUI chat. Callers
/// pass it only where an unread dot shows and the chat is read and not open;
/// the server version still gates it.
List<ConduitContextMenuAction> buildConversationActionsWithFolders({
  required BuildContext context,
  required WidgetRef ref,
  required dynamic conversation,
  required bool foldersEnabled,
  required List<Folder> folders,
  bool canMarkUnread = false,
}) {
  if (conversation == null) {
    return [];
  }

  final l10n = AppLocalizations.of(context)!;
  final bool isPinned = conversation.pinned == true;
  final bool isArchived = conversation.archived == true;
  final bool isOnDevice = isDirectLocalConversation(conversation);
  // LibreChat has no folders. It shares through its own server when the
  // server allows links, and copies chats there too. A link the chat already
  // has can be deleted without that, so its sheet stays reachable.
  final bool isLibreChat = isLibreChatConversation(conversation);
  final String? shareId = conversation.shareId as String?;
  // Watched: the actions are built with the menu, and capabilities that load
  // (or a connection that comes back) afterwards must show in it.
  final bool canShare =
      !isOnDevice &&
      (!isLibreChat ||
          (shareId != null && shareId.isNotEmpty) ||
          ref.watch(
            libreChatCapabilitiesProvider.select(
              (capabilities) => capabilities.asData?.value.sharedLinks ?? false,
            ),
          ));
  final bool canDuplicate = isLibreChat && ref.watch(isOnlineProvider);
  final selectionId = conversationScopedId(conversation);
  final currentFolderId = _conversationFolderId(conversation);
  // Move is offered even with no folder to move to: its sheet starts with
  // New Folder, which is also how the first folder gets made once the
  // sidebar hides an empty Folders group. LibreChat chats have no folders.
  final canMove = !isOnDevice && !isLibreChat && foldersEnabled;
  final showMarkUnread =
      canMarkUnread &&
      !isOnDevice &&
      !isLibreChat &&
      ref.watch(chatMarkUnreadSupportedProvider);
  // The server titles a chat it holds; on-device and temporary chats have
  // nothing there to read.
  final canGenerateTitle =
      !isOnDevice &&
      !isLibreChat &&
      !isTemporaryChat(conversation.id as String?) &&
      !isNativeHermesConversation(conversation as Conversation?) &&
      ref.watch(apiServiceProvider) != null;

  Future<void> togglePin() async {
    final errorMessage = l10n.failedToUpdatePin;
    try {
      await chat.pinConversation(ref, selectionId, !isPinned);
    } catch (_) {
      if (!context.mounted) return;
      await _showConversationError(context, errorMessage);
    }
  }

  Future<void> toggleArchive() async {
    final errorMessage = l10n.failedToUpdateArchive;
    try {
      await chat.archiveConversation(ref, selectionId, !isArchived);
    } catch (_) {
      if (!context.mounted) return;
      await _showConversationError(context, errorMessage);
    }
  }

  Future<void> markUnread() async {
    final errorMessage = l10n.failedToMarkChatUnread;
    try {
      await chat.markConversationUnread(ref, selectionId);
    } catch (_) {
      if (!context.mounted) return;
      await _showConversationError(context, errorMessage);
    }
  }

  Future<void> generateTitle() async {
    await _generateConversationTitle(context, ref, selectionId);
  }

  Future<void> rename() async {
    await _renameConversation(
      context,
      ref,
      selectionId,
      conversation.title ?? '',
      isOnDevice: isOnDevice,
      isLibreChat: isLibreChat,
    );
  }

  Future<void> deleteConversation() async {
    await _confirmAndDeleteConversation(
      context,
      ref,
      conversation,
      isOnDevice: isOnDevice,
      isLibreChat: isLibreChat,
    );
  }

  Future<void> shareConversation() async {
    if (!context.mounted) return;
    await showChatShareSheet(context: context, conversation: conversation);
  }

  Future<void> duplicateConversation() async {
    final failed = l10n.libreChatCopyFailed;
    // The copy opens unless the user has moved on (another chat, another
    // account, or a chat still opening) while it was made: it is then only
    // listed.
    final startedSelection = ref.read(conversationSelectionProvider).generation;
    final startedFor = ref.read(primaryAccountProvider);
    try {
      final copy = await chat.copyLibreChatConversation(ref, selectionId);
      if (!context.mounted) return;
      if (ref.read(conversationSelectionProvider).generation !=
              startedSelection ||
          ref.read(primaryAccountProvider) != startedFor) {
        return;
      }
      final result = await ref
          .read(conversationSelectionProvider.notifier)
          .select(copy);
      switch (result.disposition) {
        case ConversationSelectionDisposition.committed:
          NavigationService.router.go(Routes.chat);
        case ConversationSelectionDisposition.failed:
          // The copy was made but could not be opened.
          if (!context.mounted) return;
          await _showConversationError(context, failed);
        case ConversationSelectionDisposition.canceled:
          // Another chat was chosen meanwhile: nothing to report.
          break;
      }
    } catch (_) {
      if (!context.mounted) return;
      await _showConversationError(context, failed);
    }
  }

  Future<void> moveConversation() async {
    await _moveConversation(
      context,
      ref,
      selectionId,
      currentFolderId: currentFolderId,
      folders: folders,
    );
  }

  return [
    ConduitContextMenuAction(
      cupertinoIcon: isPinned
          ? CupertinoIcons.pin_slash
          : CupertinoIcons.pin_fill,
      sfSymbol: isPinned ? 'pin.slash' : 'pin.fill',
      materialIcon: isPinned ? Icons.push_pin_outlined : Icons.push_pin_rounded,
      label: isPinned ? l10n.unpin : l10n.pin,
      onBeforeClose: () => ConduitHaptics.lightImpact(),
      onSelected: togglePin,
    ),
    ConduitContextMenuAction(
      cupertinoIcon: isArchived
          ? CupertinoIcons.archivebox_fill
          : CupertinoIcons.archivebox,
      sfSymbol: isArchived ? 'archivebox.fill' : 'archivebox',
      materialIcon: isArchived
          ? Icons.unarchive_rounded
          : Icons.archive_rounded,
      label: isArchived ? l10n.unarchive : l10n.archive,
      onBeforeClose: () => ConduitHaptics.lightImpact(),
      onSelected: toggleArchive,
    ),
    if (canShare)
      ConduitContextMenuAction(
        cupertinoIcon: CupertinoIcons.share,
        sfSymbol: 'square.and.arrow.up',
        materialIcon: Icons.ios_share_rounded,
        label: l10n.shareChat,
        onBeforeClose: () => ConduitHaptics.selectionClick(),
        onSelected: shareConversation,
      ),
    ConduitContextMenuAction(
      cupertinoIcon: CupertinoIcons.pencil,
      sfSymbol: 'pencil',
      materialIcon: Icons.edit_rounded,
      label: l10n.rename,
      onBeforeClose: () => ConduitHaptics.selectionClick(),
      onSelected: rename,
    ),
    if (canGenerateTitle)
      ConduitContextMenuAction(
        cupertinoIcon: CupertinoIcons.sparkles,
        sfSymbol: 'sparkles',
        materialIcon: Icons.auto_awesome_rounded,
        label: l10n.generateTitle,
        onBeforeClose: () => ConduitHaptics.selectionClick(),
        onSelected: generateTitle,
      ),
    if (showMarkUnread)
      ConduitContextMenuAction(
        cupertinoIcon: CupertinoIcons.envelope_badge,
        sfSymbol: 'message.badge',
        materialIcon: Icons.mark_chat_unread_rounded,
        label: l10n.markAsUnread,
        onBeforeClose: () => ConduitHaptics.selectionClick(),
        onSelected: markUnread,
      ),
    if (canDuplicate)
      ConduitContextMenuAction(
        cupertinoIcon: CupertinoIcons.plus_square_on_square,
        sfSymbol: 'plus.square.on.square',
        materialIcon: Icons.copy_all_rounded,
        label: l10n.libreChatDuplicateChat,
        onBeforeClose: () => ConduitHaptics.selectionClick(),
        onSelected: duplicateConversation,
      ),
    if (canMove)
      ConduitContextMenuAction(
        cupertinoIcon: CupertinoIcons.folder,
        sfSymbol: 'folder',
        materialIcon: Icons.drive_file_move_outline,
        label: l10n.move,
        onBeforeClose: () => ConduitHaptics.selectionClick(),
        onSelected: moveConversation,
      ),
    ConduitContextMenuAction(
      cupertinoIcon: CupertinoIcons.delete,
      sfSymbol: 'trash',
      materialIcon: Icons.delete_rounded,
      label: l10n.delete,
      destructive: true,
      onBeforeClose: () => ConduitHaptics.mediumImpact(),
      onSelected: deleteConversation,
    ),
  ];
}

String? _conversationFolderId(dynamic conversation) {
  try {
    final value = conversation.folderId;
    if (value is String && value.isNotEmpty) {
      return value;
    }
  } catch (_) {}
  return null;
}

class _ConversationMoveTarget {
  const _ConversationMoveTarget({required this.folderId})
    : createsFolder = false;

  /// Into a folder the user names next.
  const _ConversationMoveTarget.newFolder()
    : folderId = null,
      createsFolder = true;

  final String? folderId;
  final bool createsFolder;
}

Future<void> _moveConversation(
  BuildContext context,
  WidgetRef ref,
  String conversationId, {
  required String? currentFolderId,
  required List<Folder> folders,
}) async {
  final rawConversationId = ChatStorageIdentity.parse(conversationId).rawId;
  final target = await _showConversationMoveSheet(
    context,
    folders: folders,
    currentFolderId: currentFolderId,
  );
  if (!context.mounted || target == null) return;
  var folderId = target.folderId;
  if (target.createsFolder) {
    final created = await CreateFolderDialog.show(
      context,
      ref,
      onError: (message) => _showConversationError(context, message),
    );
    if (!context.mounted || created == null) return;
    folderId = created.id;
  }
  if (folderId == currentFolderId) return;
  final destination = folderId;

  final l10n = AppLocalizations.of(context)!;
  try {
    final api = ref.read(apiServiceProvider);
    if (api == null) throw Exception('No API service');
    await api.moveConversationToFolder(rawConversationId, destination);
    if (!context.mounted) return;

    ConduitHaptics.selectionClick();
    ref
        .read(conversationsProvider.notifier)
        .updateConversation(
          conversationId,
          // The move keeps the chat's last activity: Open WebUI 0.12.5 leaves
          // its date alone, and the refresh below brings the date of an older
          // server, which still moves it.
          (conversation) => conversation.copyWith(folderId: destination),
          trustFolderConversation:
              destination != null && destination.isNotEmpty,
        );

    final activeConversation = ref.read(activeConversationProvider);
    if (activeConversation != null &&
        conversationMatchesScopedId(activeConversation, conversationId)) {
      ref
          .read(activeConversationProvider.notifier)
          .set(activeConversation.copyWith(folderId: destination));
    }
    refreshConversationsCache(ref, includeFolders: true);
  } catch (_) {
    if (!context.mounted) return;
    await _showConversationError(context, l10n.failedToMoveChat);
  }
}

Future<_ConversationMoveTarget?> _showConversationMoveSheet(
  BuildContext context, {
  required List<Folder> folders,
  required String? currentFolderId,
}) async {
  final l10n = AppLocalizations.of(context)!;
  // A shared folder is a valid destination only with a write grant.
  final treeEntries = folderTreeEntriesForTargets(
    folders: folders.where((folder) => folder.canWrite).toList(),
    omitFolderId: currentFolderId,
  );

  if (Theme.of(context).platform == TargetPlatform.iOS) {
    const noFolderId = '__no_folder__';
    const newFolderId = '__new_folder__';
    try {
      final selectedId = await NativeSheetBridge.instance
          .presentOptionsSelector(
            title: l10n.moveToFolder,
            options: [
              NativeSheetOptionConfig(
                id: newFolderId,
                label: l10n.newFolder,
                sfSymbol: 'folder.badge.plus',
              ),
              if (currentFolderId != null)
                NativeSheetOptionConfig(
                  id: noFolderId,
                  label: l10n.noFolder,
                  sfSymbol: 'folder.badge.minus',
                ),
              for (final entry in treeEntries)
                NativeSheetOptionConfig(
                  id: entry.folder.id,
                  label: entry.folder.name,
                  sfSymbol: 'folder',
                  ancestorHasMoreSiblings: entry.ancestorHasMoreSiblings,
                  showBranch: true,
                  hasMoreSiblings: entry.hasMoreSiblings,
                ),
            ],
            rethrowErrors: true,
          );
      if (selectedId == null) {
        return null;
      }
      if (selectedId == noFolderId) {
        return const _ConversationMoveTarget(folderId: null);
      }
      if (selectedId == newFolderId) {
        // The name editor can be asked for at once: the native side waits
        // for this sheet to finish closing before presenting it.
        return const _ConversationMoveTarget.newFolder();
      }
      return _ConversationMoveTarget(folderId: selectedId);
    } catch (_) {
      if (!context.mounted) {
        return null;
      }
    }
  }

  if (!context.mounted) {
    return null;
  }

  return ThemedSheets.showSurface<_ConversationMoveTarget>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) {
      final theme = sheetContext.conduitTheme;
      final maxListHeight = MediaQuery.sizeOf(sheetContext).height * 0.62;

      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.moveToFolder,
            style: AppTypography.headlineSmallStyle.copyWith(
              color: theme.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: Spacing.md),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxListHeight),
            child: ListView(
              shrinkWrap: true,
              physics: const ClampingScrollPhysics(),
              padding: EdgeInsets.zero,
              children: [
                _MoveTargetTile(
                  icon: PlatformInfo.isIOS
                      ? CupertinoIcons.folder_badge_plus
                      : Icons.create_new_folder_outlined,
                  label: l10n.newFolder,
                  onTap: () =>
                      Navigator.of(sheetContext)
                          .pop(const _ConversationMoveTarget.newFolder()),
                ),
                if (currentFolderId != null)
                  _MoveTargetTile(
                    icon: PlatformInfo.isIOS
                        ? CupertinoIcons.folder_badge_minus
                        : Icons.folder_off_outlined,
                    label: l10n.noFolder,
                    onTap: () =>
                        Navigator.of(sheetContext)
                            .pop(const _ConversationMoveTarget(folderId: null)),
                  ),
                for (final entry in treeEntries)
                  FolderTreeHierarchyNode(
                    key: ValueKey<String>('move-chat-tree-${entry.folder.id}'),
                    ancestorHasMoreSiblings: entry.ancestorHasMoreSiblings,
                    showBranch: true,
                    hasMoreSiblings: entry.hasMoreSiblings,
                    child: _MoveTargetTile(
                      icon: PlatformInfo.isIOS
                          ? CupertinoIcons.folder
                          : Icons.folder_outlined,
                      label: entry.folder.name,
                      onTap: () => Navigator.of(
                        sheetContext,
                      ).pop(_ConversationMoveTarget(folderId: entry.folder.id)),
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
    },
  );
}

class _MoveTargetTile extends StatelessWidget {
  const _MoveTargetTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: TouchTarget.listItem),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.sm,
            vertical: Spacing.sm,
          ),
          child: Row(
            children: [
              Icon(icon, color: theme.iconPrimary, size: IconSize.listItem),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.sidebarTitleStyle.copyWith(
                    color: theme.textPrimary,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> _renameConversation(
  BuildContext context,
  WidgetRef ref,
  String conversationId,
  String currentTitle, {
  required bool isOnDevice,
  bool isLibreChat = false,
}) async {
  final l10n = AppLocalizations.of(context)!;
  // The answer is for the LibreChat account the dialog opened under; another
  // one can hold a chat with the same id.
  final openedFor = ref.read(activeLibreChatAccountProvider)?.id;
  final newName = await ThemedDialogs.promptTextInput(
    context,
    title: l10n.renameChat,
    hintText: l10n.enterChatName,
    initialValue: currentTitle,
    confirmText: l10n.save,
    cancelText: l10n.cancel,
  );

  if (!context.mounted) return;
  if (newName == null) return;
  if (newName.isEmpty || newName == currentTitle) return;
  if (isLibreChat &&
      ref.read(activeLibreChatAccountProvider)?.id != openedFor) {
    return;
  }

  final renameError = l10n.failedToRenameChat;
  try {
    if (isOnDevice) {
      await chat.renameDirectLocalConversation(ref, conversationId, newName);
      ConduitHaptics.selectionClick();
      return;
    }
    if (isLibreChat) {
      await chat.renameLibreChatConversation(ref, conversationId, newName);
      ConduitHaptics.selectionClick();
      return;
    }
    await _saveConversationTitle(ref, conversationId, newName);
    ConduitHaptics.selectionClick();
  } catch (_) {
    if (!context.mounted) return;
    await _showConversationError(context, renameError);
  }
}

/// Saves [title] as the Open WebUI chat [conversationId]'s title, and shows
/// it in the chat list and the open chat.
Future<void> _saveConversationTitle(
  WidgetRef ref,
  String conversationId,
  String title,
) async {
  final rawConversationId = ChatStorageIdentity.parse(conversationId).rawId;
  final api = ref.read(apiServiceProvider);
  if (api == null) throw Exception('No API service');
  // A title being generated for this chat waits for the rename, and keeps
  // it.
  await ref
      .read(chatTitleLocksProvider)
      .runExclusive(
        rawConversationId,
        () => api.updateConversation(rawConversationId, title: title),
      );
  _showConversationTitle(ref, conversationId, title);
}

/// Shows [title] for the chat [conversationId] in the chat list and the
/// open chat, once the server holds it.
void _showConversationTitle(
  WidgetRef ref,
  String conversationId,
  String title,
) {
  ref
      .read(conversationsProvider.notifier)
      .updateConversationFromRemote(
        conversationId,
        (conversation) =>
            conversation.copyWith(title: title, updatedAt: DateTime.now()),
      );
  refreshConversationsCache(ref);
  final active = ref.read(activeConversationProvider);
  if (active != null && conversationMatchesScopedId(active, conversationId)) {
    ref
        .read(activeConversationProvider.notifier)
        .set(active.copyWith(title: title));
  }
}

/// Chats whose title is being generated: a second tap waits for the first.
final Set<String> _titlesBeingGenerated = <String>{};

/// Asks the server for a title made from the Open WebUI chat
/// [conversationId] and saves it straight away, as the Generate button of
/// Open WebUI 0.13's chat title does.
///
/// Every request goes out as the account that asked, and the title is saved
/// only while the chat still has the title it had then: a rename made while
/// the model wrote one is kept.
Future<void> _generateConversationTitle(
  BuildContext context,
  WidgetRef ref,
  String conversationId,
) async {
  if (!_titlesBeingGenerated.add(conversationId)) return;
  try {
    await _generateConversationTitleOnce(context, ref, conversationId);
  } finally {
    _titlesBeingGenerated.remove(conversationId);
  }
}

Future<void> _generateConversationTitleOnce(
  BuildContext context,
  WidgetRef ref,
  String conversationId,
) async {
  final l10n = AppLocalizations.of(context)!;
  // The menu can close while the title is written; the app's container
  // outlives it.
  final container = ProviderScope.containerOf(context, listen: false);
  final rawConversationId = ChatStorageIdentity.parse(conversationId).rawId;
  final api = container.read(apiServiceProvider);
  final authSnapshot = api?.captureAuthSnapshot();
  String? selectedModelId;
  final active = container.read(activeConversationProvider);
  if (active != null && conversationMatchesScopedId(active, conversationId)) {
    selectedModelId = container.read(selectedModelProvider)?.id;
  }
  String? message;
  try {
    if (api == null) throw Exception('No API service');
    // Only the server's own models can title a chat: not a Direct or Hermes
    // model, which turns of an Open WebUI chat may have used. The model list
    // leaves out models hidden from the picker, which are still the
    // server's, so only a model it lists as Direct or Hermes is passed over.
    final directModels = container.read(directModelRegistryProvider);
    List<Model>? knownModels;
    try {
      knownModels = await container
          .read(modelsProvider.future)
          .timeout(const Duration(seconds: 5));
    } catch (_) {}
    bool isServerModel(String id) {
      for (final model in knownModels ?? const <Model>[]) {
        if (model.id != id) continue;
        return !isHermesModel(model) && directModels.resolve(model) == null;
      }
      return true;
    }

    final chatJson = await api.getChatRaw(
      rawConversationId,
      authSnapshot: authSnapshot,
    );
    // A chat the server does not hold has nothing to title there.
    if (chatJson == null) throw Exception('Chat not found');
    final titleAsked = chatJson['title'];
    final request = chatTitleRequest(
      chatJson,
      selectedModelId: selectedModelId,
      isServerModel: isServerModel,
    );
    final title = request == null
        ? null
        : (await api.generateChatTitle(
            model: request.model,
            messages: request.messages,
            authSnapshot: authSnapshot,
          ))?.trim();
    if (title == null || title.isEmpty) {
      message = l10n.generateTitleNone;
    } else if (title != titleAsked) {
      // Told apart from the title the server stored, not the chat list's
      // copy, which can lag it or show an empty title as "Chat".
      var saved = false;
      final database = container.read(appDatabaseProvider);
      await container.read(chatTitleLocksProvider).runExclusive(
        rawConversationId,
        // In the chat's own lock too: a full save of the chat sends the
        // title it read, so one under way finishes before this one is
        // written, and one after it reads the new title from the database.
        () => container.read(chatLocksProvider).runExclusive(
          rawConversationId,
          () async {
            // Compared as the server stores it, as it was when the title was
            // asked for: a rename made meanwhile is kept.
            final stored = await api.getChatRaw(
              rawConversationId,
              authSnapshot: authSnapshot,
            );
            if (stored == null || stored['title'] != titleAsked) return;
            await api.updateConversation(
              rawConversationId,
              title: title,
              authSnapshot: authSnapshot,
            );
            saved = true;
            await database?.chatsDao.updateServerGeneratedTitle(
              rawConversationId,
              title,
            );
          },
        ),
      );
      if (saved && identical(container.read(apiServiceProvider), api)) {
        // Stored as a server-made title, so a later save of the chat does
        // not send the old one back.
        container
            .read(conversationsProvider.notifier)
            .applyServerGeneratedTitle(rawConversationId, title);
        final open = container.read(activeConversationProvider);
        if (open != null && conversationMatchesScopedId(open, conversationId)) {
          container
              .read(activeConversationProvider.notifier)
              .set(open.copyWith(title: title));
        }
        ConduitHaptics.success();
      }
    } else {
      ConduitHaptics.success();
    }
  } catch (_) {
    message = l10n.generateTitleFailed;
  }
  if (message == null || !context.mounted) return;
  await _showConversationError(context, message);
}

Future<void> _confirmAndDeleteConversation(
  BuildContext context,
  WidgetRef ref,
  Conversation conversation, {
  required bool isOnDevice,
  bool isLibreChat = false,
}) async {
  final conversationId = conversationScopedId(conversation);
  final rawConversationId = ChatStorageIdentity.parse(conversationId).rawId;
  final l10n = AppLocalizations.of(context)!;
  // The answer is for the LibreChat account the dialog opened under; another
  // one can hold a chat with the same id.
  final openedFor = ref.read(activeLibreChatAccountProvider)?.id;
  final confirmed = await ThemedDialogs.confirm(
    context,
    title: l10n.deleteChatTitle,
    message: l10n.deleteChatMessage,
    confirmText: l10n.delete,
    isDestructive: true,
  );

  if (!context.mounted) return;
  if (!confirmed) return;
  if (isLibreChat &&
      ref.read(activeLibreChatAccountProvider)?.id != openedFor) {
    return;
  }

  final deleteError = l10n.failedToDeleteChat;
  // Read before deleting: the LibreChat delete closes the chat itself, which
  // would hide that it was the open one.
  final initiallyActive = ref.read(activeConversationProvider);
  final wasActive =
      initiallyActive != null &&
      conversationMatchesScopedId(initiallyActive, conversationId);
  try {
    if (isOnDevice) {
      await chat.deleteDirectLocalConversation(ref, conversationId);
    } else if (isLibreChat) {
      await chat.deleteLibreChatConversation(ref, conversationId);
    } else {
      final api = ref.read(apiServiceProvider);
      if (api == null) throw Exception('No API service');
      // Revoke first: a thrown DELETE can still mean the server committed and
      // only its response was lost. A crash must not leave replayable proof for
      // a remotely deleted conversation. Do not restore proof based on an HTTP
      // status: 404 already means the chat is absent, while an auth-looking
      // response may come from an intermediary after an ambiguous upstream
      // outcome. Losing safe continuity is preferable to authorizing replay
      // against a deleted or later-reused conversation id.
      await chat.forgetMixedHermesConversationProvenance(
        ref,
        conversation: conversation,
      );
      await api.deleteConversation(rawConversationId);
      ref
          .read(conversationsProvider.notifier)
          .removeConversation(conversationId);
    }
    // The account may have changed while the delete ran: another account's
    // chat with the same id is not the one deleted.
    if (isLibreChat &&
        ref.read(activeLibreChatAccountProvider)?.id != openedFor) {
      return;
    }
    ConduitHaptics.mediumImpact();
    // Reset only while the deleted chat is still the one shown, or nothing
    // is after the delete closed it: another chat opened while the delete
    // ran keeps its messages and model.
    final active = ref.read(activeConversationProvider);
    if ((wasActive && active == null) ||
        (active != null && conversationMatchesScopedId(active, conversationId))) {
      chat.clearSelectedFiltersForConversationBoundary(ref);
      ref.read(activeConversationProvider.notifier).clear();
      ref.read(chat.chatMessagesProvider.notifier).clearMessages();
      // Reset to default model for new conversations (fixes #296)
      chat.restoreDefaultModel(ref);
    }
    refreshConversationsCache(ref);
  } catch (_) {
    if (!context.mounted) return;
    await _showConversationError(context, deleteError);
  }
}

Future<void> _showConversationError(
  BuildContext context,
  String message,
) async {
  if (!context.mounted) return;
  final l10n = AppLocalizations.of(context)!;
  final theme = context.conduitTheme;
  await ThemedDialogs.show<void>(
    context,
    title: l10n.errorMessage,
    content: Text(
      message,
      style: AppTypography.bodyMediumStyle.copyWith(color: theme.textSecondary),
    ),
    actions: [
      AdaptiveButton(
        // The dialog is on the root navigator; the chat list can sit in a
        // nested one, whose page this would close instead.
        onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
        label: l10n.ok,
        style: AdaptiveButtonStyle.plain,
      ),
    ],
  );
}
