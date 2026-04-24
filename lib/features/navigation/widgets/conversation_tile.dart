import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/middle_ellipsis_text.dart';

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

    return Material(
      color: Colors.transparent,
      elevation: Elevation.low,
      borderRadius: borderRadius,
      child: Container(
        constraints: const BoxConstraints(minHeight: TouchTarget.listItem),
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.md,
          vertical: Spacing.xs,
        ),
        decoration: BoxDecoration(
          color: theme.surfaceContainer,
          borderRadius: borderRadius,
          border: Border.all(color: borderColor, width: BorderWidth.thin),
        ),
        child: ConversationTileContent(
          title: title,
          pinned: pinned,
          selected: false,
          isLoading: false,
        ),
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

  /// Creates the content layout for a conversation tile.
  const ConversationTileContent({
    super.key,
    required this.title,
    required this.pinned,
    required this.selected,
    required this.isLoading,
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

    return LayoutBuilder(
      builder: (context, constraints) {
        final hasFiniteWidth = constraints.maxWidth.isFinite;
        final textFit = hasFiniteWidth ? FlexFit.tight : FlexFit.loose;

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
                Platform.isIOS
                    ? CupertinoIcons.pin_fill
                    : Icons.push_pin_rounded,
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
                valueColor: AlwaysStoppedAnimation<Color>(
                  theme.loadingIndicator,
                ),
              ),
            ),
          ]);
        }

        return Row(
          mainAxisSize: hasFiniteWidth ? MainAxisSize.max : MainAxisSize.min,
          children: [
            Flexible(
              fit: textFit,
              child: MiddleEllipsisText(
                title,
                style: textStyle,
                semanticsLabel: title,
              ),
            ),
            ...trailingWidgets,
          ],
        );
      },
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
  State<ConversationTile> createState() => _ConversationTileState();
}

class _ConversationTileState extends State<ConversationTile> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final sidebarTheme = context.sidebarTheme;
    final borderRadius = BorderRadius.circular(AppBorderRadius.card);

    // Use opaque backgrounds for proper context menu snapshot rendering
    final Color baseBackground = sidebarTheme.background;

    final Color background = widget.selected
        ? Color.alphaBlend(
            theme.buttonPrimary.withValues(alpha: 0.1),
            baseBackground,
          )
        : (_isHovered
              ? Color.alphaBlend(
                  theme.buttonPrimary.withValues(alpha: 0.05),
                  baseBackground,
                )
              : baseBackground);

    Color? overlayForStates(Set<WidgetState> states) {
      if (states.contains(WidgetState.pressed)) {
        return theme.buttonPrimary.withValues(alpha: Alpha.buttonPressed);
      }
      return Colors.transparent;
    }

    return Semantics(
      selected: widget.selected,
      button: true,
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          margin: const EdgeInsets.symmetric(
            horizontal: Spacing.xs,
            vertical: Spacing.xxs,
          ),
          decoration: BoxDecoration(
            color: background,
            borderRadius: borderRadius,
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: borderRadius,
            child: InkWell(
              borderRadius: borderRadius,
              onTap: widget.isLoading ? null : widget.onTap,
              overlayColor: WidgetStateProperty.resolveWith(overlayForStates),
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
                    isLoading: widget.isLoading,
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
