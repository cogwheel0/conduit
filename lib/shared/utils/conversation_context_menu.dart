import 'dart:io';

import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/themed_dialogs.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:super_context_menu/super_context_menu.dart';
// ignore: implementation_imports
import 'package:super_context_menu/src/scaffold/mobile/menu_widget_builder.dart'
    as mobile;

import 'package:conduit/features/chat/providers/chat_providers.dart' as chat;

/// Re-export super_context_menu types for convenience.
export 'package:super_context_menu/super_context_menu.dart'
    show ContextMenuWidget, Menu, MenuAction, MenuSeparator;

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

/// A context menu widget that provides native iOS appearance and a beautiful
/// Material 3 styled menu on Android.
///
/// On iOS, this uses the native context menu provided by super_context_menu.
/// On Android, it displays a custom Material 3 styled menu that matches the
/// app's theme.
class ConduitContextMenu extends StatelessWidget {
  final List<ConduitContextMenuAction> actions;
  final Widget child;

  const ConduitContextMenu({
    super.key,
    required this.actions,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    // iOS: Use native context menu
    if (Platform.isIOS) {
      return ContextMenuWidget(
        menuProvider: (_) => buildConduitMenu(actions),
        child: child,
      );
    }

    // Android: Use ContextMenuWidget with custom Material 3 styling
    return ContextMenuWidget(
      menuProvider: (_) => buildConduitMenu(actions),
      mobileMenuWidgetBuilder: _ConduitMobileMenuBuilder(
        theme: context.conduitTheme,
      ),
      child: child,
    );
  }
}

/// Custom Material 3 styled menu builder for super_context_menu on Android.
class _ConduitMobileMenuBuilder extends mobile.MobileMenuWidgetBuilder {
  final ConduitThemeExtension theme;

  const _ConduitMobileMenuBuilder({required this.theme});

  @override
  Widget buildMenuContainer(
    BuildContext context,
    mobile.MobileMenuInfo menuInfo,
    Widget child,
  ) {
    // Use pre-blended shadow color for Impeller compatibility
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppBorderRadius.lg),
        boxShadow: theme.popoverShadows,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppBorderRadius.lg),
        child: child,
      ),
    );
  }

  @override
  Widget buildMenuContainerInner(
    BuildContext context,
    mobile.MobileMenuInfo menuInfo,
    Widget child,
  ) {
    // Use pre-blended border color for Impeller compatibility
    final borderColor = Color.lerp(
      theme.surfaces.popover,
      theme.surfaces.border,
      0.15,
    )!;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.surfaces.popover,
        borderRadius: BorderRadius.circular(AppBorderRadius.lg),
        border: Border.all(color: borderColor, width: 0.5),
      ),
      child: child,
    );
  }

  @override
  Widget buildMenu(
    BuildContext context,
    mobile.MobileMenuInfo menuInfo,
    Widget child,
  ) {
    return child;
  }

  @override
  Widget buildMenuItemsContainer(
    BuildContext context,
    mobile.MobileMenuInfo menuInfo,
    Widget child,
  ) {
    return child;
  }

  @override
  Widget buildMenuHeader(
    BuildContext context,
    mobile.MobileMenuInfo menuInfo,
    mobile.MobileMenuButtonState state,
  ) {
    // No header needed for simple menus
    return const SizedBox.shrink();
  }

  @override
  Widget buildInactiveMenuVeil(
    BuildContext context,
    mobile.MobileMenuInfo menuInfo,
  ) {
    // Use pre-blended solid color for Impeller compatibility
    final veilColor = theme.isDark
        ? const Color(0x4D000000) // ~30% black
        : const Color(0x4D424242); // ~30% grey
    return SizedBox.expand(child: ColoredBox(color: veilColor));
  }

  @override
  Widget buildMenuItem(
    BuildContext context,
    mobile.MobileMenuInfo menuInfo,
    mobile.MobileMenuButtonState state,
    MenuElement element,
  ) {
    if (element is MenuAction) {
      final isDestructive = element.attributes.destructive;
      final textColor = isDestructive ? theme.error : theme.textPrimary;
      final iconColor = isDestructive ? theme.error : theme.iconPrimary;
      final imageWidget = element.image?.asWidget(menuInfo.iconTheme);

      // Use ColoredBox for pressed state to avoid Impeller opacity issues
      Widget content = Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.md,
          vertical: Spacing.sm + 2,
        ),
        child: Row(
          children: [
            if (imageWidget != null)
              Padding(
                padding: const EdgeInsets.only(right: Spacing.md),
                child: IconTheme(
                  data: IconThemeData(color: iconColor, size: IconSize.medium),
                  child: imageWidget,
                ),
              ),
            Expanded(
              child: Text(
                element.title ?? '',
                style: TextStyle(
                  fontSize: AppTypography.bodyMedium,
                  fontWeight: FontWeight.w500,
                  color: textColor,
                  decoration: TextDecoration.none,
                  fontFamily: theme.typography.primaryFont.isEmpty
                      ? null
                      : theme.typography.primaryFont,
                  fontFamilyFallback: theme.typography.primaryFallback.isEmpty
                      ? null
                      : theme.typography.primaryFallback,
                ),
              ),
            ),
          ],
        ),
      );

      if (state.pressed) {
        content = ColoredBox(color: theme.surfaceContainer, child: content);
      }

      return content;
    }

    if (element is MenuSeparator) {
      // Use pre-blended color for Impeller compatibility
      final separatorColor = Color.lerp(
        theme.surfaces.popover,
        theme.dividerColor,
        0.4,
      )!;
      return Divider(
        height: 1,
        thickness: 0.5,
        indent: Spacing.md,
        endIndent: Spacing.md,
        color: separatorColor,
      );
    }

    // For submenus or other elements, show a simple row
    if (element is Menu) {
      return Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.md,
          vertical: Spacing.sm + 2,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                element.title ?? '',
                style: TextStyle(
                  fontSize: AppTypography.bodyMedium,
                  fontWeight: FontWeight.w500,
                  color: theme.textPrimary,
                  decoration: TextDecoration.none,
                  fontFamily: theme.typography.primaryFont.isEmpty
                      ? null
                      : theme.typography.primaryFont,
                  fontFamilyFallback: theme.typography.primaryFallback.isEmpty
                      ? null
                      : theme.typography.primaryFallback,
                ),
              ),
            ),
            Icon(
              Icons.chevron_right,
              size: IconSize.small,
              color: theme.iconSecondary,
            ),
          ],
        ),
      );
    }

    return const SizedBox.shrink();
  }

  @override
  Widget buildOverlayBackground(BuildContext context, double opacity) {
    // Use pre-computed hex colors for Impeller compatibility
    // These are solid colors at different opacities (0x80 = 50%, 0x66 = 40%)
    final overlayColor = Color.lerp(
      const Color(0x00000000),
      theme.isDark ? const Color(0x80000000) : const Color(0x66000000),
      opacity,
    )!;
    // GestureDetector with opaque behavior ensures hit testing works
    // even when the overlay is visually transparent
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      child: SizedBox.expand(child: ColoredBox(color: overlayColor)),
    );
  }

  @override
  Widget buildMenuPreviewContainer(BuildContext context, Widget child) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppBorderRadius.md),
        boxShadow: theme.popoverShadows,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppBorderRadius.md),
        child: child,
      ),
    );
  }
}

/// Builds a [Menu] from a list of [ConduitContextMenuAction]s.
///
/// Use this with [ContextMenuWidget.menuProvider]:
/// ```dart
/// ContextMenuWidget(
///   menuProvider: (_) => buildConduitMenu(actions),
///   child: MyWidget(),
/// )
/// ```
Menu buildConduitMenu(List<ConduitContextMenuAction> actions) {
  return Menu(
    children: actions.map((action) {
      return MenuAction(
        title: action.label,
        callback: () {
          HapticFeedback.selectionClick();
          action.onBeforeClose?.call();
          action.onSelected();
        },
        attributes: MenuActionAttributes(destructive: action.destructive),
      );
    }).toList(),
  );
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

  return [
    ConduitContextMenuAction(
      cupertinoIcon: isPinned
          ? CupertinoIcons.pin_slash
          : CupertinoIcons.pin_fill,
      materialIcon: isPinned ? Icons.push_pin_outlined : Icons.push_pin_rounded,
      label: isPinned ? l10n.unpin : l10n.pin,
      onBeforeClose: () => HapticFeedback.lightImpact(),
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
      onBeforeClose: () => HapticFeedback.lightImpact(),
      onSelected: toggleArchive,
    ),
    ConduitContextMenuAction(
      cupertinoIcon: CupertinoIcons.pencil,
      materialIcon: Icons.edit_rounded,
      label: l10n.rename,
      onBeforeClose: () => HapticFeedback.selectionClick(),
      onSelected: rename,
    ),
    ConduitContextMenuAction(
      cupertinoIcon: CupertinoIcons.delete,
      materialIcon: Icons.delete_rounded,
      label: l10n.delete,
      destructive: true,
      onBeforeClose: () => HapticFeedback.mediumImpact(),
      onSelected: deleteConversation,
    ),
  ];
}

/// Builds a [Menu] for conversation context actions.
///
/// Use with [ContextMenuWidget.menuProvider].
Menu buildConversationMenu({
  required BuildContext context,
  required WidgetRef ref,
  required dynamic conversation,
}) {
  return buildConduitMenu(
    buildConversationActions(
      context: context,
      ref: ref,
      conversation: conversation,
    ),
  );
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
    HapticFeedback.selectionClick();
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
    HapticFeedback.mediumImpact();
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
    content: Text(message, style: TextStyle(color: theme.textSecondary)),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(l10n.ok),
      ),
    ],
  );
}
