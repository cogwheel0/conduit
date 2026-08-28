import 'dart:io' show Platform;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../../../shared/theme/theme_extensions.dart';

const double kConversationTileHorizontalGutter = Spacing.sm;
const EdgeInsets kConversationTileMargin = EdgeInsets.only(
  left: kConversationTileHorizontalGutter,
  right: kConversationTileHorizontalGutter,
  top: Spacing.xxs,
  bottom: Spacing.xxs,
);

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
        left: kConversationTileHorizontalGutter,
        right: kConversationTileHorizontalGutter,
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
/// Every row keeps the same 8pt structural gutter. Idle rows remain
/// transparent; pressed and selected states paint inside those row bounds.
class ChatStyleSidebarTile extends StatefulWidget {
  const ChatStyleSidebarTile({
    super.key,
    required this.selected,
    required this.onTap,
    required this.child,
    this.semanticLabel,
    this.tintKey,
    this.pressedKey,
    this.surfaceKey,
    this.enabled = true,
  });

  final bool selected;
  final VoidCallback? onTap;
  final Widget child;
  final String? semanticLabel;
  final Key? tintKey;
  final Key? pressedKey;
  final Key? surfaceKey;
  final bool enabled;

  @override
  State<ChatStyleSidebarTile> createState() => _ChatStyleSidebarTileState();
}

class _ChatStyleSidebarTileState extends State<ChatStyleSidebarTile> {
  bool _pressed = false;
  bool _hovered = false;
  bool _focused = false;

  void _setPressed(bool pressed) {
    if (_pressed == pressed) return;
    setState(() => _pressed = pressed);
  }

  @override
  void didUpdateWidget(covariant ChatStyleSidebarTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled || widget.onTap == null) {
      _pressed = false;
      _hovered = false;
      _focused = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final effectiveEnabled = widget.enabled && widget.onTap != null;
    final highlighted = _pressed || _hovered || _focused;
    return Semantics(
      button: true,
      selected: widget.selected,
      enabled: effectiveEnabled,
      label: widget.semanticLabel,
      child: Container(
        key: widget.surfaceKey,
        margin: kConversationTileMargin,
        child: ConversationTileSurface(
          theme: context.conduitTheme,
          selected: widget.selected,
          pressed: highlighted,
          tintKey: widget.tintKey,
          pressedKey: widget.pressedKey,
          child: FocusableActionDetector(
            enabled: effectiveEnabled,
            mouseCursor: effectiveEnabled
                ? SystemMouseCursors.click
                : MouseCursor.defer,
            shortcuts: const <ShortcutActivator, Intent>{
              SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
              SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
            },
            actions: <Type, Action<Intent>>{
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) {
                  widget.onTap?.call();
                  return null;
                },
              ),
            },
            onShowHoverHighlight: (value) {
              if (_hovered == value) return;
              setState(() => _hovered = value);
            },
            onShowFocusHighlight: (value) {
              if (_focused == value) return;
              setState(() => _focused = value);
            },
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: effectiveEnabled ? (_) => _setPressed(true) : null,
              onPointerUp: effectiveEnabled ? (_) => _setPressed(false) : null,
              onPointerCancel: effectiveEnabled
                  ? (_) => _setPressed(false)
                  : null,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: effectiveEnabled ? widget.onTap : null,
                child: widget.child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Inner layout for compact sidebar rows that may include supporting text.
///
/// This deliberately shares the conversation row's height, typography, and
/// horizontal rhythm instead of inheriting the smaller utility-row defaults.
class SidebarListTileContent extends StatelessWidget {
  const SidebarListTileContent({
    super.key,
    required this.title,
    required this.selected,
    this.subtitle,
    this.subtitleMaxLines = 1,
    this.leading,
    this.trailing,
    this.emphasizeTitle = false,
    this.titleFontWeight,
  });

  final String title;
  final bool selected;
  final String? subtitle;
  final int subtitleMaxLines;
  final Widget? leading;
  final Widget? trailing;
  final bool emphasizeTitle;
  final FontWeight? titleFontWeight;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final hasSubtitle = subtitle?.trim().isNotEmpty ?? false;
    final titleIsPrimary = selected || emphasizeTitle;

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: TouchTarget.listItem),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.md,
          vertical: Spacing.sm,
        ),
        child: Row(
          children: [
            if (leading != null) ...[
              leading!,
              const SizedBox(width: Spacing.md),
            ],
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.sidebarTitleStyle.copyWith(
                      color: titleIsPrimary
                          ? theme.textPrimary
                          : theme.textSecondary,
                      fontWeight:
                          titleFontWeight ??
                          (titleIsPrimary ? FontWeight.w600 : FontWeight.w400),
                      height: 1.4,
                    ),
                  ),
                  if (hasSubtitle) ...[
                    const SizedBox(height: Spacing.xxs),
                    Text(
                      subtitle!,
                      maxLines: subtitleMaxLines,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.sidebarSupportingStyle.copyWith(
                        color: theme.textSecondary,
                        height: 1.4,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: Spacing.sm),
              trailing!,
            ],
          ],
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
    return ChatStyleSidebarTile(
      selected: selected,
      enabled: !isLoading,
      onTap: onTap,
      tintKey: const ValueKey<String>('conversation-tile-active-tint'),
      pressedKey: const ValueKey<String>('conversation-tile-pressed-tint'),
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
    );
  }
}
