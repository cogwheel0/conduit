import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/theme_extensions.dart';

/// Drag feedback widget shown while dragging a conversation tile.
class ConversationDragFeedback extends StatelessWidget {
  /// The conversation title.
  final String title;

  /// Whether the conversation is pinned.
  final bool pinned;

  /// The theme extension for styling.
  final ConduitThemeExtension theme;

  /// Creates a drag feedback widget for a conversation.
  const ConversationDragFeedback({
    super.key,
    required this.title,
    required this.pinned,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(AppBorderRadius.small);
    final borderColor = theme.surfaceContainerHighest.withValues(alpha: 0.40);

    return Container(
      constraints: const BoxConstraints(minHeight: TouchTarget.listItem),
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.xs,
      ),
      decoration: BoxDecoration(
        color: theme.surfaceContainer,
        borderRadius: borderRadius,
        border: Border.all(color: borderColor, width: BorderWidth.thin),
        boxShadow: [
          BoxShadow(
            color: theme.cardShadow.withValues(alpha: 0.12),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ConversationTileContent(
        title: title,
        pinned: pinned,
        selected: false,
        unread: false,
        isLoading: false,
        shrinkWrap: true,
      ),
    );
  }
}

/// The inner content layout of a conversation tile (title + icons).
class ConversationTileContent extends StatelessWidget {
  /// The conversation title.
  final String title;

  /// Whether the conversation is pinned.
  final bool pinned;

  /// Whether this tile is currently selected.
  final bool selected;

  /// Whether this conversation has unread updates.
  final bool unread;

  /// Whether the conversation is loading.
  final bool isLoading;

  /// Whether the conversation has an active generation running on the server.
  final bool isGenerating;

  /// Optional compact provenance label, such as "On device".
  final String? badge;

  /// Whether the row should size itself to its contents instead of filling width.
  final bool shrinkWrap;

  /// Creates the content layout for a conversation tile.
  const ConversationTileContent({
    super.key,
    required this.title,
    required this.pinned,
    required this.selected,
    this.unread = false,
    required this.isLoading,
    this.isGenerating = false,
    this.badge,
    this.shrinkWrap = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    // Enhanced typography with better visual hierarchy
    final textStyle = AppTypography.sidebarTitleStyle.copyWith(
      color: (selected || unread) ? theme.textPrimary : theme.textSecondary,
      fontWeight: (selected || unread) ? FontWeight.w600 : FontWeight.w400,
      height: 1.4,
    );

    final trailingWidgets = <Widget>[];

    if (badge != null && badge!.trim().isNotEmpty) {
      trailingWidgets.addAll([
        const SizedBox(width: Spacing.sm),
        Container(
          constraints: const BoxConstraints(maxWidth: 104),
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.xs,
            vertical: Spacing.xxs,
          ),
          decoration: BoxDecoration(
            color: theme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(AppBorderRadius.xs),
          ),
          child: Text(
            badge!,
            style: AppTypography.labelStyle.copyWith(
              color: theme.textSecondary,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ]);
    }

    if (pinned) {
      trailingWidgets.addAll([
        const SizedBox(width: Spacing.sm),
        Container(
          padding: const EdgeInsets.all(Spacing.xxs),
          decoration: BoxDecoration(
            color: theme.buttonPrimary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(AppBorderRadius.xs),
          ),
          child: Icon(
            Platform.isIOS ? CupertinoIcons.pin_fill : Icons.push_pin_rounded,
            color: theme.buttonPrimary.withValues(alpha: 0.7),
            size: IconSize.xs,
          ),
        ),
      ]);
    }

    // A server-side generation in progress shows the same spinner as a tile
    // that's loading on tap (the tap-load state takes precedence so we never
    // show two spinners).
    if (isLoading || isGenerating) {
      trailingWidgets.addAll([
        const SizedBox(width: Spacing.sm),
        SizedBox(
          key: isGenerating && !isLoading
              ? const ValueKey<String>('conversation-generating-indicator')
              : null,
          width: IconSize.sm,
          height: IconSize.sm,
          child: CircularProgressIndicator(
            strokeWidth: BorderWidth.medium,
            valueColor: AlwaysStoppedAnimation<Color>(theme.loadingIndicator),
          ),
        ),
      ]);
    }

    final titleWidget = Text(
      title,
      style: textStyle,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      semanticsLabel: title,
    );

    return Row(
      mainAxisSize: shrinkWrap ? MainAxisSize.min : MainAxisSize.max,
      children: [
        if (unread) ...[
          Container(
            key: const ValueKey<String>('conversation-unread-indicator'),
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: theme.buttonPrimary,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: Spacing.sm),
        ],
        if (shrinkWrap)
          Flexible(fit: FlexFit.loose, child: titleWidget)
        else
          Expanded(child: titleWidget),
        ...trailingWidgets,
      ],
    );
  }
}

/// A tappable conversation tile with hover and selection states.
class ConversationTile extends StatelessWidget {
  /// The conversation title.
  final String title;

  /// Whether the conversation is pinned.
  final bool pinned;

  /// Whether this tile is currently selected.
  final bool selected;

  /// Whether this conversation has unread updates.
  final bool unread;

  /// Whether the conversation is loading.
  final bool isLoading;

  /// Whether the conversation has an active generation running on the server.
  final bool isGenerating;

  /// Optional compact provenance label.
  final String? badge;

  /// Callback when the tile is tapped.
  final VoidCallback? onTap;

  /// Creates a conversation tile widget.
  const ConversationTile({
    super.key,
    required this.title,
    required this.pinned,
    required this.selected,
    this.unread = false,
    required this.isLoading,
    this.isGenerating = false,
    this.badge,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final borderRadius = BorderRadius.circular(AppBorderRadius.card);

    // Match the chats drawer scroll surface (surfaceBackground), not
    // sidebarTheme.background, so tiles align in light and dark.
    final Color baseBackground = theme.surfaceBackground;

    final Color background = selected
        ? Color.alphaBlend(
            theme.buttonPrimary.withValues(alpha: 0.1),
            baseBackground,
          )
        : baseBackground;

    return Semantics(
      selected: selected,
      button: true,
      child: Container(
        margin: const EdgeInsets.only(
          left: 0,
          right: Spacing.xs,
          top: Spacing.xxs,
          bottom: Spacing.xxs,
        ),
        decoration: BoxDecoration(
          color: background,
          borderRadius: borderRadius,
        ),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: isLoading ? null : onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: TouchTarget.listItem),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.md,
                vertical: Spacing.sm,
              ),
              child: ConversationTileContent(
                title: title,
                pinned: pinned,
                selected: selected,
                unread: unread,
                isLoading: isLoading,
                isGenerating: isGenerating,
                badge: badge,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
