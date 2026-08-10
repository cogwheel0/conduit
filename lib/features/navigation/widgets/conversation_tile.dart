import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/theme_extensions.dart';

const EdgeInsets kConversationTileMargin = EdgeInsets.only(
  right: Spacing.xs,
  top: Spacing.xxs,
  bottom: Spacing.xxs,
);
const double kConversationTileTintInset = Spacing.sm;

BoxDecoration conduitConversationTileDecoration(
  ConduitThemeExtension theme, {
  required bool selected,
  bool pressed = false,
}) {
  final background = selected
      ? Color.alphaBlend(
          theme.buttonPrimary.withValues(alpha: 0.1),
          theme.surfaceBackground,
        )
      : pressed
      ? theme.surfaceContainer
      : theme.surfaceBackground;

  return BoxDecoration(
    color: background,
    borderRadius: BorderRadius.circular(AppBorderRadius.card),
  );
}

class ConversationTileSurface extends StatelessWidget {
  const ConversationTileSurface({
    super.key,
    required this.theme,
    required this.selected,
    required this.child,
    this.pressed = false,
    this.tintKey,
    this.pressedKey,
  });

  final ConduitThemeExtension theme;
  final bool selected;
  final Widget child;
  final bool pressed;
  final Key? tintKey;
  final Key? pressedKey;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        if (selected || pressed)
          Positioned.fill(
            left: kConversationTileTintInset,
            // The outer tile preserves its historical 4pt trailing margin.
            // Compensate here so the painted tint has the same physical inset
            // on both sides without moving the row contents.
            right: kConversationTileTintInset - kConversationTileMargin.right,
            child: DecoratedBox(
              key: selected ? tintKey : pressedKey,
              decoration: conduitConversationTileDecoration(
                theme,
                selected: selected,
                pressed: pressed,
              ),
            ),
          ),
        child,
      ],
    );
  }
}

/// Adds the quiet grouped surface used while a chat-style row is lifted by an
/// iOS context menu. The physical insets match the selected tile tint.
Widget buildConversationTileContextPreview(BuildContext context, Widget child) {
  final theme = context.conduitTheme;
  return Stack(
    children: [
      Positioned.fill(
        left: kConversationTileTintInset,
        right: kConversationTileTintInset,
        top: kConversationTileMargin.top,
        bottom: kConversationTileMargin.bottom,
        child: DecoratedBox(
          key: const ValueKey<String>(
            'conversation-tile-context-preview-background',
          ),
          decoration: conduitConversationTileDecoration(
            theme,
            selected: false,
            pressed: true,
          ),
        ),
      ),
      child,
    ],
  );
}

/// Flat pressable row frame shared by high-frequency sidebar lists.
///
/// Idle rows remain transparent. Only pressed and selected states paint the
/// same quiet inset surface used by conversation tiles.
class ChatStyleSidebarTile extends StatefulWidget {
  const ChatStyleSidebarTile({
    super.key,
    required this.selected,
    required this.onTap,
    required this.child,
    this.semanticLabel,
    this.tintKey,
    this.pressedKey,
  });

  final bool selected;
  final VoidCallback onTap;
  final Widget child;
  final String? semanticLabel;
  final Key? tintKey;
  final Key? pressedKey;

  @override
  State<ChatStyleSidebarTile> createState() => _ChatStyleSidebarTileState();
}

class _ChatStyleSidebarTileState extends State<ChatStyleSidebarTile> {
  bool _pressed = false;

  void _setPressed(bool pressed) {
    if (_pressed == pressed) return;
    setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.semanticLabel,
      child: Container(
        margin: kConversationTileMargin,
        child: ConversationTileSurface(
          theme: context.conduitTheme,
          selected: widget.selected,
          pressed: _pressed,
          tintKey: widget.tintKey,
          pressedKey: widget.pressedKey,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (_) => _setPressed(true),
            onPointerUp: (_) => _setPressed(false),
            onPointerCancel: (_) => _setPressed(false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap,
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

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
class ConversationTile extends StatefulWidget {
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
  State<ConversationTile> createState() => _ConversationTileState();
}

class _ConversationTileState extends State<ConversationTile> {
  bool _pressed = false;

  void _setPressed(bool pressed) {
    if (_pressed == pressed) return;
    setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final enabled = !widget.isLoading && widget.onTap != null;

    return Semantics(
      selected: widget.selected,
      button: true,
      child: Container(
        margin: kConversationTileMargin,
        child: ConversationTileSurface(
          theme: theme,
          selected: widget.selected,
          pressed: _pressed,
          tintKey: const ValueKey<String>('conversation-tile-active-tint'),
          pressedKey: const ValueKey<String>('conversation-tile-pressed-tint'),
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: enabled ? (_) => _setPressed(true) : null,
            onPointerUp: enabled ? (_) => _setPressed(false) : null,
            onPointerCancel: enabled ? (_) => _setPressed(false) : null,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: enabled ? widget.onTap : null,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: TouchTarget.listItem,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Spacing.md,
                    vertical: Spacing.sm,
                  ),
                  child: ConversationTileContent(
                    title: widget.title,
                    pinned: widget.pinned,
                    selected: widget.selected,
                    unread: widget.unread,
                    isLoading: widget.isLoading,
                    isGenerating: widget.isGenerating,
                    badge: widget.badge,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
