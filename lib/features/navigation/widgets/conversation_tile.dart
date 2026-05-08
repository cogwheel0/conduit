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

  /// Whether the conversation is loading.
  final bool isLoading;

  /// Whether the row should size itself to its contents instead of filling width.
  final bool shrinkWrap;

  /// Creates the content layout for a conversation tile.
  const ConversationTileContent({
    super.key,
    required this.title,
    required this.pinned,
    required this.selected,
    required this.isLoading,
    this.shrinkWrap = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    // Enhanced typography with better visual hierarchy
    final textStyle = AppTypography.sidebarTitleStyle.copyWith(
      color: selected ? theme.textPrimary : theme.textSecondary,
      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
      height: 1.4,
    );

    final trailingWidgets = <Widget>[];

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

    if (isLoading) {
      trailingWidgets.addAll([
        const SizedBox(width: Spacing.sm),
        SizedBox(
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

  /// Whether the conversation is loading.
  final bool isLoading;

  /// Callback when the tile is tapped.
  final VoidCallback? onTap;

  /// Creates a conversation tile widget.
  const ConversationTile({
    super.key,
    required this.title,
    required this.pinned,
    required this.selected,
    required this.isLoading,
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
                isLoading: isLoading,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
