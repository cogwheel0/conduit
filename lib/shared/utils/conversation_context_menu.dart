import 'dart:io';

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:conduit/core/models/folder.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/measure_size.dart';
import 'package:conduit/shared/widgets/themed_dialogs.dart';
import 'package:cupertino_context_menu_plus/cupertino_context_menu_plus.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:conduit/core/services/haptic_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit/features/chat/providers/chat_providers.dart' as chat;
import 'package:conduit/features/chat/widgets/chat_share_sheet.dart';

/// Defines an action for use in Conduit context menus.
class ConduitContextMenuAction {
  final IconData cupertinoIcon;
  final IconData materialIcon;
  final String label;
  final Future<void> Function() onSelected;
  final VoidCallback? onBeforeClose;
  final bool destructive;

  const ConduitContextMenuAction({
    required this.cupertinoIcon,
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
/// icons while the menu presentation follows the current platform.
class ConduitContextMenu extends StatefulWidget {
  final List<ConduitContextMenuAction> actions;
  final Widget child;
  final Widget? topWidget;
  final WidgetBuilder? topWidgetBuilder;
  final bool keepChildVisibleDuringPress;

  const ConduitContextMenu({
    super.key,
    required this.actions,
    required this.child,
    this.topWidget,
    this.topWidgetBuilder,
    this.keepChildVisibleDuringPress = false,
  });

  @override
  State<ConduitContextMenu> createState() => _ConduitContextMenuState();
}

class _ConduitContextMenuState extends State<ConduitContextMenu> {
  bool _isPressing = false;
  Size? _childSize;

  @override
  Widget build(BuildContext context) {
    if (widget.actions.isEmpty) {
      return widget.child;
    }

    if (Platform.isIOS) {
      return _buildCupertinoContextMenu(context);
    }

    final menu = GestureDetector(
      behavior: HitTestBehavior.translucent,
      onLongPressStart: (details) {
        _showMenu(context, details.globalPosition);
      },
      onSecondaryTapDown: (details) {
        _showMenu(context, details.globalPosition);
      },
      child: widget.child,
    );

    if (!widget.keepChildVisibleDuringPress) {
      return menu;
    }

    return Listener(
      onPointerDown: (_) => setState(() => _isPressing = true),
      onPointerUp: (_) => setState(() => _isPressing = false),
      onPointerCancel: (_) => setState(() => _isPressing = false),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (_isPressing) IgnorePointer(child: widget.child),
          menu,
        ],
      ),
    );
  }

  Widget _buildCupertinoContextMenu(BuildContext context) {
    final theme = context.conduitTheme;
    final contextMenu = CupertinoContextMenuPlus.builder(
      showGrowAnimation: false,
      previewLongPressTimeout: const Duration(milliseconds: 450),
      modalReverseTransitionDuration: const Duration(milliseconds: 180),
      barrierColor: const Color(0x3304040F),
      backdropBlurSigma: 8,
      actionsBackgroundColor: theme.surfaces.popover,
      actionsBorderRadius: BorderRadius.circular(AppBorderRadius.lg),
      topWidget: _buildDeferredTopWidget(),
      actions: [
        for (final action in widget.actions)
          CupertinoContextMenuAction(
            isDestructiveAction: action.destructive,
            onPressed: () {
              Navigator.of(context, rootNavigator: true).pop();
              Future.microtask(() => _selectAction(action));
            },
            child: _CupertinoContextMenuItem(action: action),
          ),
      ],
      builder: (context, animation) {
        final isMenuPreview = animation.value > 0;
        final previewChild = Material(
          type: MaterialType.transparency,
          child: IgnorePointer(ignoring: isMenuPreview, child: widget.child),
        );
        final size = _childSize;
        if (isMenuPreview && size != null) {
          return SizedBox(
            width: size.width,
            height: size.height,
            child: previewChild,
          );
        }
        return previewChild;
      },
    );

    return MeasureSize(onChange: _handleChildSizeChanged, child: contextMenu);
  }

  Widget? _buildDeferredTopWidget() {
    final builder = widget.topWidgetBuilder;
    if (builder != null) {
      return _DeferredContextMenuTopWidget(builder: builder);
    }
    final topWidget = widget.topWidget;
    if (topWidget == null) {
      return null;
    }
    return _DeferredContextMenuTopWidget(builder: (_) => topWidget);
  }

  Future<void> _showMenu(BuildContext context, Offset globalPosition) async {
    setState(() => _isPressing = false);

    final overlay = Navigator.of(context).overlay?.context.findRenderObject();
    if (overlay is! RenderBox) {
      return;
    }

    final selected = await showMenu<int>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(globalPosition, globalPosition),
        Offset.zero & overlay.size,
      ),
      items: [
        for (var index = 0; index < widget.actions.length; index++)
          PopupMenuItem<int>(
            value: index,
            child: _MaterialContextMenuItem(action: widget.actions[index]),
          ),
      ],
    );
    if (selected != null) {
      _selectAction(widget.actions[selected]);
    }
  }

  void _selectAction(ConduitContextMenuAction action) {
    ConduitHaptics.selectionClick();
    action.onBeforeClose?.call();
    action.onSelected();
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

class _DeferredContextMenuTopWidget extends StatelessWidget {
  const _DeferredContextMenuTopWidget({required this.builder});

  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) => builder(context);
}

class _CupertinoContextMenuItem extends StatelessWidget {
  const _CupertinoContextMenuItem({required this.action});

  final ConduitContextMenuAction action;

  @override
  Widget build(BuildContext context) {
    final color = action.destructive
        ? CupertinoColors.destructiveRed.resolveFrom(context)
        : CupertinoColors.label.resolveFrom(context);

    return Row(
      children: [
        Icon(action.cupertinoIcon, color: color, size: IconSize.medium),
        const SizedBox(width: Spacing.md),
        Expanded(
          child: Text(action.label, style: TextStyle(color: color)),
        ),
      ],
    );
  }
}

class _MaterialContextMenuItem extends StatelessWidget {
  const _MaterialContextMenuItem({required this.action});

  final ConduitContextMenuAction action;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final color = action.destructive ? theme.error : theme.textPrimary;
    return Row(
      children: [
        Icon(action.materialIcon, color: color, size: IconSize.medium),
        const SizedBox(width: Spacing.md),
        Expanded(
          child: Text(
            action.label,
            style: AppTypography.bodyMediumStyle.copyWith(color: color),
          ),
        ),
      ],
    );
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
  if (conversation == null) {
    return [];
  }

  final l10n = AppLocalizations.of(context)!;
  final bool isPinned = conversation.pinned == true;
  final bool isArchived = conversation.archived == true;
  final currentFolderId = _conversationFolderId(conversation);
  final foldersEnabled = ref.watch(foldersFeatureEnabledProvider);
  final folders = foldersEnabled
      ? ref
            .watch(foldersProvider)
            .maybeWhen(
              data: (folders) => folders,
              orElse: () => const <Folder>[],
            )
      : const <Folder>[];
  final canMove =
      foldersEnabled &&
      (folders.any((folder) => folder.id != currentFolderId) ||
          currentFolderId != null);

  Future<void> togglePin() async {
    final errorMessage = l10n.failedToUpdatePin;
    try {
      await chat.pinConversation(ref, conversation.id, !isPinned);
    } catch (_) {
      if (!context.mounted) return;
      await _showConversationError(context, errorMessage);
    }
  }

  Future<void> toggleArchive() async {
    final errorMessage = l10n.failedToUpdateArchive;
    try {
      await chat.archiveConversation(ref, conversation.id, !isArchived);
    } catch (_) {
      if (!context.mounted) return;
      await _showConversationError(context, errorMessage);
    }
  }

  Future<void> rename() async {
    await _renameConversation(
      context,
      ref,
      conversation.id,
      conversation.title ?? '',
    );
  }

  Future<void> deleteConversation() async {
    await _confirmAndDeleteConversation(context, ref, conversation.id);
  }

  Future<void> shareConversation() async {
    if (!context.mounted) return;
    await showChatShareSheet(context: context, conversation: conversation);
  }

  Future<void> moveConversation() async {
    await _moveConversation(
      context,
      ref,
      conversation.id,
      currentFolderId: currentFolderId,
      folders: folders,
    );
  }

  return [
    ConduitContextMenuAction(
      cupertinoIcon: isPinned
          ? CupertinoIcons.pin_slash
          : CupertinoIcons.pin_fill,
      materialIcon: isPinned ? Icons.push_pin_outlined : Icons.push_pin_rounded,
      label: isPinned ? l10n.unpin : l10n.pin,
      onBeforeClose: () => ConduitHaptics.lightImpact(),
      onSelected: togglePin,
    ),
    ConduitContextMenuAction(
      cupertinoIcon: isArchived
          ? CupertinoIcons.archivebox_fill
          : CupertinoIcons.archivebox,
      materialIcon: isArchived
          ? Icons.unarchive_rounded
          : Icons.archive_rounded,
      label: isArchived ? l10n.unarchive : l10n.archive,
      onBeforeClose: () => ConduitHaptics.lightImpact(),
      onSelected: toggleArchive,
    ),
    ConduitContextMenuAction(
      cupertinoIcon: CupertinoIcons.share,
      materialIcon: Icons.ios_share_rounded,
      label: l10n.shareChat,
      onBeforeClose: () => ConduitHaptics.selectionClick(),
      onSelected: shareConversation,
    ),
    ConduitContextMenuAction(
      cupertinoIcon: CupertinoIcons.pencil,
      materialIcon: Icons.edit_rounded,
      label: l10n.rename,
      onBeforeClose: () => ConduitHaptics.selectionClick(),
      onSelected: rename,
    ),
    if (canMove)
      ConduitContextMenuAction(
        cupertinoIcon: CupertinoIcons.folder,
        materialIcon: Icons.drive_file_move_outline,
        label: 'Move',
        onBeforeClose: () => ConduitHaptics.selectionClick(),
        onSelected: moveConversation,
      ),
    ConduitContextMenuAction(
      cupertinoIcon: CupertinoIcons.delete,
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
  const _ConversationMoveTarget({required this.folderId});

  final String? folderId;
}

Future<void> _moveConversation(
  BuildContext context,
  WidgetRef ref,
  String conversationId, {
  required String? currentFolderId,
  required List<Folder> folders,
}) async {
  final target = await _showConversationMoveSheet(
    context,
    folders: folders,
    currentFolderId: currentFolderId,
  );
  if (!context.mounted || target == null) return;
  if (target.folderId == currentFolderId) return;

  final l10n = AppLocalizations.of(context)!;
  try {
    final api = ref.read(apiServiceProvider);
    if (api == null) throw Exception('No API service');
    await api.moveConversationToFolder(conversationId, target.folderId);
    if (!context.mounted) return;

    ConduitHaptics.selectionClick();
    ref
        .read(conversationsProvider.notifier)
        .updateConversation(
          conversationId,
          (conversation) => conversation.copyWith(
            folderId: target.folderId,
            updatedAt: DateTime.now(),
          ),
        );

    final activeConversation = ref.read(activeConversationProvider);
    if (activeConversation?.id == conversationId) {
      ref
          .read(activeConversationProvider.notifier)
          .set(
            activeConversation!.copyWith(
              folderId: target.folderId,
              updatedAt: DateTime.now(),
            ),
          );
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
}) {
  final theme = context.conduitTheme;
  final sortedFolders = [...folders]
    ..sort((a, b) {
      final updatedA = a.updatedAt;
      final updatedB = b.updatedAt;
      if (updatedA != null && updatedB != null) {
        return updatedB.compareTo(updatedA);
      }
      if (updatedA != null) return -1;
      if (updatedB != null) return 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  final folderTargets = sortedFolders
      .where((folder) => folder.id != currentFolderId)
      .toList(growable: false);

  return showModalBottomSheet<_ConversationMoveTarget>(
    context: context,
    backgroundColor: theme.surfaceContainer,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(AppBorderRadius.bottomSheet),
      ),
    ),
    builder: (sheetContext) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.md,
            Spacing.md,
            Spacing.md,
            Spacing.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
                child: Text(
                  'Move to folder',
                  style: AppTypography.titleMediumStyle.copyWith(
                    color: theme.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: Spacing.sm),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    if (currentFolderId != null)
                      _MoveTargetTile(
                        icon: Platform.isIOS
                            ? CupertinoIcons.folder_badge_minus
                            : Icons.folder_off_outlined,
                        label: 'No folder',
                        onTap: () => Navigator.of(
                          sheetContext,
                        ).pop(const _ConversationMoveTarget(folderId: null)),
                      ),
                    for (final folder in folderTargets)
                      _MoveTargetTile(
                        icon: Platform.isIOS
                            ? CupertinoIcons.folder
                            : Icons.folder_outlined,
                        label: folder.name,
                        onTap: () => Navigator.of(
                          sheetContext,
                        ).pop(_ConversationMoveTarget(folderId: folder.id)),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
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
    return ListTile(
      leading: Icon(icon, color: theme.iconPrimary, size: IconSize.medium),
      title: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTypography.bodyMediumStyle.copyWith(color: theme.textPrimary),
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppBorderRadius.md),
      ),
      onTap: onTap,
    );
  }
}

Future<void> _renameConversation(
  BuildContext context,
  WidgetRef ref,
  String conversationId,
  String currentTitle,
) async {
  final l10n = AppLocalizations.of(context)!;
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

  final renameError = l10n.failedToRenameChat;
  try {
    final api = ref.read(apiServiceProvider);
    if (api == null) throw Exception('No API service');
    await api.updateConversation(conversationId, title: newName);
    ConduitHaptics.selectionClick();
    ref
        .read(conversationsProvider.notifier)
        .updateConversation(
          conversationId,
          (conversation) =>
              conversation.copyWith(title: newName, updatedAt: DateTime.now()),
        );
    refreshConversationsCache(ref);
    final active = ref.read(activeConversationProvider);
    if (active?.id == conversationId) {
      ref
          .read(activeConversationProvider.notifier)
          .set(active!.copyWith(title: newName));
    }
  } catch (_) {
    if (!context.mounted) return;
    await _showConversationError(context, renameError);
  }
}

Future<void> _confirmAndDeleteConversation(
  BuildContext context,
  WidgetRef ref,
  String conversationId,
) async {
  final l10n = AppLocalizations.of(context)!;
  final confirmed = await ThemedDialogs.confirm(
    context,
    title: l10n.deleteChatTitle,
    message: l10n.deleteChatMessage,
    confirmText: l10n.delete,
    isDestructive: true,
  );

  if (!context.mounted) return;
  if (!confirmed) return;

  final deleteError = l10n.failedToDeleteChat;
  try {
    final api = ref.read(apiServiceProvider);
    if (api == null) throw Exception('No API service');
    await api.deleteConversation(conversationId);
    ConduitHaptics.mediumImpact();
    ref.read(conversationsProvider.notifier).removeConversation(conversationId);
    final active = ref.read(activeConversationProvider);
    if (active?.id == conversationId) {
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
        onPressed: () => Navigator.of(context).pop(),
        label: l10n.ok,
        style: AdaptiveButtonStyle.plain,
      ),
    ],
  );
}
