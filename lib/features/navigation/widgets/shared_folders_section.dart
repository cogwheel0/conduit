import 'dart:io' show Platform;

import 'package:conduit/core/services/haptic_service.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/folder.dart';
import '../../../core/models/shared_folder_chat.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/conversation_context_menu.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../providers/shared_folders_providers.dart';
import 'conversation_tile.dart'
    show ChatStyleSidebarTile, kConversationTileHorizontalGutter;
import 'create_folder_dialog.dart';
import 'folder_icon.dart';
import 'folder_tree_guides.dart';
import 'drawer_section_notifiers.dart';
import '../views/shared_chat_view_page.dart';

/// Local copy of `chats_drawer.dart`'s disclosure-chevron helper — kept
/// separate to avoid a circular import between the two files over one
/// trivial function.
IconData _disclosureIcon(bool isExpanded) {
  if (Platform.isIOS) {
    return isExpanded
        ? CupertinoIcons.chevron_down
        : CupertinoIcons.chevron_right;
  }
  return isExpanded ? Icons.expand_more : Icons.chevron_right_rounded;
}

/// The "Shared" drawer section: folders another user shared with the
/// current one (`GET /api/v1/folders/shared`). Kept deliberately separate
/// from the owned-folders tree in `chats_drawer.dart` — every chat reached
/// through here belongs to someone else and is read-only (see
/// `SharedFolderChat`), so there's no drag/move/rename/delete affordance
/// and no local persistence, unlike the owned "Folders" section above it.
class SharedFoldersSection extends ConsumerWidget {
  const SharedFoldersSection({super.key, required this.folders});

  final List<Folder> folders;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (folders.isEmpty) {
      return const SizedBox.shrink();
    }

    final theme = context.conduitTheme;
    final isExpanded = ref.watch(showSharedFoldersProvider);
    final entries = folderTreeEntriesForTargets(folders: folders);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            ConduitHaptics.selectionClick();
            ref.read(showSharedFoldersProvider.notifier).toggle();
          },
          // Matches every other section header's height (Folders, Recent,
          // Pinned all now constrain to TouchTarget.minimum — see
          // `_buildSectionHeader` and `_buildFoldersSectionHeader` in
          // chats_drawer.dart) so the gaps on both sides of each header
          // look visually even regardless of which ones carry a trailing
          // button.
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: TouchTarget.minimum),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.md,
                vertical: Spacing.xxs,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _disclosureIcon(isExpanded),
                    color: theme.iconSecondary,
                    size: IconSize.listItem,
                  ),
                  const SizedBox(width: Spacing.xxs),
                  Text(
                    AppLocalizations.of(context)!.sharedFolders,
                    style: AppTypography.labelStyle.copyWith(
                      color: theme.textSecondary,
                      fontWeight: FontWeight.w700,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (isExpanded) ...[
          const SizedBox(height: Spacing.xs),
          for (final entry in entries) _SharedFolderRow(entry: entry),
        ],
        // Matches the owned "Folders" section's trailing gap in
        // chats_drawer.dart, which is unconditional (not just while
        // expanded) so the "Recent" header below always has breathing room.
        const SizedBox(height: Spacing.md),
      ],
    );
  }
}

class _SharedFolderRow extends ConsumerWidget {
  const _SharedFolderRow({required this.entry});

  final FolderTreeListEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folder = entry.folder;
    final depth = entry.ancestorHasMoreSiblings.length;
    final theme = context.conduitTheme;
    final isExpanded = ref.watch(expandedFoldersProvider)[folder.id] ?? false;

    final header = ChatStyleSidebarTile(
      selected: false,
      onTap: () {
        ConduitHaptics.selectionClick();
        final current = {...ref.read(expandedFoldersProvider)};
        current[folder.id] = !isExpanded;
        ref.read(expandedFoldersProvider.notifier).set(current);
      },
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: TouchTarget.listItem),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.md,
            vertical: Spacing.xxs,
          ),
          child: Row(
            children: [
              FolderIconGlyph(
                iconAlias: folder.meta?['icon']?.toString(),
                isOpen: isExpanded,
                size: IconSize.listItem,
                color: theme.iconSecondary,
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      folder.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.sidebarTitleStyle.copyWith(
                        color: theme.textSecondary,
                        height: 1.4,
                      ),
                    ),
                    if (depth == 0 && folder.ownerName != null)
                      Text(
                        AppLocalizations.of(
                          context,
                        )!.sharedFolderOwnedBy(folder.ownerName!),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.labelSmallStyle.copyWith(
                          color: theme.textSecondary.withValues(alpha: 0.7),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Icon(
                _disclosureIcon(isExpanded),
                color: theme.iconSecondary,
                size: IconSize.listItem,
              ),
            ],
          ),
        ),
      ),
    );

    final canWrite = folder.sharedPermission == 'write';
    final headerWithMenu = canWrite
        ? ConduitContextMenu(
            actions: _writeActions(context, ref, folder),
            child: header,
          )
        : header;

    final wrapped = depth == 0
        ? headerWithMenu
        : FolderTreeHierarchyNode(
            ancestorHasMoreSiblings: entry.ancestorHasMoreSiblings,
            showBranch: true,
            hasMoreSiblings: entry.hasMoreSiblings,
            guideInset: kConversationTileHorizontalGutter,
            child: headerWithMenu,
          );

    if (!isExpanded) {
      return wrapped;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        wrapped,
        _SharedFolderChats(
          folderId: folder.id,
          ancestorHasMoreSiblings: [
            ...entry.ancestorHasMoreSiblings,
            entry.hasMoreSiblings,
          ],
        ),
      ],
    );
  }

  /// Folder-tree actions available when the owner granted write access.
  /// Both operations are already permitted server-side for a write-granted
  /// non-owner (see `create_folder` / `update_folder_name_by_id` in
  /// `open_webui`'s folders router) — the new/renamed folder is still owned
  /// by [folder]'s owner, not the current user, so results are written back
  /// through `sharedFoldersProvider`, not the owned `foldersProvider`.
  List<ConduitContextMenuAction> _writeActions(
    BuildContext context,
    WidgetRef ref,
    Folder folder,
  ) {
    final l10n = AppLocalizations.of(context)!;
    return [
      ConduitContextMenuAction(
        cupertinoIcon: CupertinoIcons.folder_badge_plus,
        materialIcon: Icons.create_new_folder_outlined,
        label: l10n.newFolder,
        onBeforeClose: () => ConduitHaptics.selectionClick(),
        onSelected: () async {
          await CreateFolderDialog.show(
            context,
            ref,
            parentId: folder.id,
            onError: (message) => _showError(context, message),
            onCreated: (_) =>
                ref.read(sharedFoldersProvider.notifier).refresh(),
          );
        },
      ),
      ConduitContextMenuAction(
        cupertinoIcon: CupertinoIcons.pencil,
        materialIcon: Icons.edit_rounded,
        label: l10n.rename,
        onBeforeClose: () => ConduitHaptics.selectionClick(),
        onSelected: () async {
          await _renameSharedFolder(context, ref, folder);
        },
      ),
    ];
  }

  Future<void> _renameSharedFolder(
    BuildContext context,
    WidgetRef ref,
    Folder folder,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final newName = await ThemedDialogs.promptTextInput(
      context,
      title: l10n.rename,
      hintText: l10n.folderName,
      initialValue: folder.name,
      confirmText: l10n.save,
      cancelText: l10n.cancel,
    );
    if (newName == null) return;
    final trimmed = newName.trim();
    if (trimmed.isEmpty || trimmed == folder.name) return;

    try {
      final api = ref.read(apiServiceProvider);
      if (api == null) throw Exception('No API service');
      await api.updateFolder(folder.id, name: trimmed);
      ConduitHaptics.selectionClick();
      await ref.read(sharedFoldersProvider.notifier).refresh();
    } catch (e, stackTrace) {
      DebugLogger.error(
        'rename-shared-folder-failed',
        scope: 'drawer/shared',
        error: e,
        stackTrace: stackTrace,
      );
      if (context.mounted) {
        await _showError(context, l10n.failedToRenameFolder);
      }
    }
  }

  Future<void> _showError(BuildContext context, String message) async {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    await ThemedDialogs.show<void>(
      context,
      title: l10n.errorMessage,
      content: Text(
        message,
        style: AppTypography.bodyMediumStyle.copyWith(
          color: theme.textSecondary,
        ),
      ),
      actions: [
        AdaptiveButton(
          onPressed: () => Navigator.of(context).pop(),
          label: l10n.ok,
          style: AdaptiveButtonStyle.plain,
        ),
      ],
    );
  }
}

class _SharedFolderChats extends ConsumerWidget {
  const _SharedFolderChats({
    required this.folderId,
    required this.ancestorHasMoreSiblings,
  });

  final String folderId;
  final List<bool> ancestorHasMoreSiblings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chatsAsync = ref.watch(sharedFolderChatsProvider(folderId));
    final theme = context.conduitTheme;

    return chatsAsync.when(
      data: (chats) {
        if (chats.isEmpty) {
          return const SizedBox.shrink();
        }
        return Column(
          children: [
            for (var i = 0; i < chats.length; i++)
              FolderTreeHierarchyNode(
                ancestorHasMoreSiblings: ancestorHasMoreSiblings,
                showBranch: true,
                hasMoreSiblings: i < chats.length - 1,
                guideInset: kConversationTileHorizontalGutter,
                child: _SharedChatRow(chat: chats[i]),
              ),
          ],
        );
      },
      loading: () => Padding(
        padding: EdgeInsets.only(
          left:
              (ancestorHasMoreSiblings.length + 1) *
              FolderTreeHierarchyNode.segmentWidth,
          top: Spacing.sm,
          bottom: Spacing.sm,
        ),
        child: SizedBox(
          width: IconSize.sm,
          height: IconSize.sm,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(theme.loadingIndicator),
          ),
        ),
      ),
      error: (e, _) => const SizedBox.shrink(),
    );
  }
}

class _SharedChatRow extends StatelessWidget {
  const _SharedChatRow({required this.chat});

  final SharedFolderChat chat;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return ChatStyleSidebarTile(
      selected: false,
      onTap: () {
        ConduitHaptics.selectionClick();
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => SharedChatViewPage(
              chatId: chat.id,
              title: chat.title,
              ownerName: chat.ownerName,
            ),
          ),
        );
      },
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: TouchTarget.listItem),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.md,
            vertical: Spacing.xxs,
          ),
          child: Row(
            children: [
              Icon(
                Platform.isIOS
                    ? CupertinoIcons.chat_bubble
                    : Icons.chat_bubble_outline_rounded,
                color: theme.iconSecondary,
                size: IconSize.listItem,
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  chat.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.sidebarTitleStyle.copyWith(
                    color: theme.textSecondary,
                    height: 1.4,
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
