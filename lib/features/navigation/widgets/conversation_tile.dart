import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/gestures.dart' show PointerDeviceKind, kTouchSlop;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';

import '../../../shared/theme/theme_extensions.dart';

const double kConversationTileHorizontalGutter = Spacing.sm;
const EdgeInsets kConversationTileMargin = EdgeInsets.only(
  left: kConversationTileHorizontalGutter,
  right: kConversationTileHorizontalGutter,
  top: 1,
  bottom: 1,
);

/// The sidebar's leading content edge: where the toolbar's first button, the
/// large title and every section header start, 16 pt in as UIKit lays out a
/// list's margins. A row's leading column (its unread dot, folder symbol or
/// avatar) starts here too, and its trailing items end the same distance
/// from the other side.
const double kSidebarRowContentInset = Spacing.md;

/// Padding inside a row's highlight on either side, so its content starts on
/// [kSidebarRowContentInset].
const double kSidebarRowHorizontalPadding =
    kSidebarRowContentInset - kConversationTileHorizontalGutter;

/// The column a chat row keeps before its title for the unread dot, as Mail
/// keeps one for unread mail, so read and unread titles share one edge.
const double kSidebarRowStatusGutter = Spacing.md;

/// Where the title of a row without a symbol or avatar starts: after the
/// status column, one step in from the section headers.
const double kSidebarRowTitleInset =
    kSidebarRowContentInset + kSidebarRowStatusGutter;

/// Diameter of a chat row's unread dot.
const double kSidebarUnreadDotDiameter = 8;

/// Least height of a single-line chat row, inside [kConversationTileMargin].
const double kConversationTileMinHeight = TouchTarget.minimum;

/// How long a finger rests on a sidebar row before it highlights. Like a
/// UIKit list in a scroll view, a row the finger starts scrolling from never
/// flashes; a quicker tap still highlights briefly when it lifts.
const Duration kSidebarRowPressDelay = Duration(milliseconds: 80);

/// How long a tap shorter than [kSidebarRowPressDelay] keeps its highlight.
const Duration kSidebarRowTapFlash = Duration(milliseconds: 120);

/// The fill of a selected or pressed sidebar row: a wash of the text colour,
/// so it stays neutral in every palette and never borrows an accent. A press
/// reads darker than a selection, as in UIKit lists.
Color sidebarRowHighlightColor(
  ConduitThemeExtension theme, {
  required bool selected,
  bool pressed = false,
}) {
  if (!selected && !pressed) return theme.surfaceBackground;
  final alpha = pressed
      ? (theme.isDark ? 0.19 : 0.13)
      : (theme.isDark ? 0.13 : 0.08);
  return Color.alphaBlend(
    theme.textPrimary.withValues(alpha: alpha),
    theme.surfaceBackground,
  );
}

BoxDecoration conduitConversationTileDecoration(
  ConduitThemeExtension theme, {
  required bool selected,
  bool pressed = false,
}) {
  return BoxDecoration(
    color: sidebarRowHighlightColor(
      theme,
      selected: selected,
      pressed: pressed,
    ),
    borderRadius: BorderRadius.circular(AppBorderRadius.md),
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
  Timer? _pressTimer;
  Timer? _flashTimer;
  Offset? _downPosition;

  void _setPressed(bool pressed) {
    if (!mounted || _pressed == pressed) return;
    setState(() => _pressed = pressed);
  }

  void _handlePointerDown(PointerDownEvent event) {
    _cancelTimers();
    _downPosition = event.position;
    // A mouse never scrolls by dragging, so it highlights at once.
    if (event.kind == PointerDeviceKind.mouse) {
      _setPressed(true);
      return;
    }
    _pressTimer = Timer(kSidebarRowPressDelay, () => _setPressed(true));
  }

  void _handlePointerMove(PointerMoveEvent event) {
    final origin = _downPosition;
    if (origin == null) return;
    if ((event.position - origin).distance > kTouchSlop) {
      // The finger is scrolling the list, not choosing this row.
      _release();
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    final tappedBeforeHighlight = _pressTimer?.isActive ?? false;
    final stayedPut = _downPosition != null;
    _cancelTimers();
    _downPosition = null;
    if (tappedBeforeHighlight && stayedPut) {
      _setPressed(true);
      _flashTimer = Timer(kSidebarRowTapFlash, () => _setPressed(false));
      return;
    }
    _setPressed(false);
  }

  void _release() {
    _cancelTimers();
    _downPosition = null;
    _setPressed(false);
  }

  void _cancelTimers() {
    _pressTimer?.cancel();
    _pressTimer = null;
    _flashTimer?.cancel();
    _flashTimer = null;
  }

  @override
  void didUpdateWidget(covariant ChatStyleSidebarTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled || widget.onTap == null) {
      _cancelTimers();
      _downPosition = null;
      _pressed = false;
      _hovered = false;
      _focused = false;
    }
  }

  @override
  void dispose() {
    _cancelTimers();
    super.dispose();
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
              onPointerDown: effectiveEnabled ? _handlePointerDown : null,
              onPointerMove: effectiveEnabled ? _handlePointerMove : null,
              onPointerUp: effectiveEnabled ? _handlePointerUp : null,
              onPointerCancel: effectiveEnabled ? (_) => _release() : null,
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
      constraints: const BoxConstraints(minHeight: kConversationTileMinHeight),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: kSidebarRowHorizontalPadding,
          vertical: Spacing.sm,
        ),
        child: Row(
          children: [
            // A symbol or avatar takes the leading column; without one the
            // title starts where chat titles do, past their status column.
            if (leading != null) ...[
              leading!,
              const SizedBox(width: Spacing.md),
            ] else
              const SizedBox(width: kSidebarRowStatusGutter),
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
                      // Titles read in the label colour, as chat rows do;
                      // selection shows through the row highlight and weight.
                      color: theme.textPrimary,
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
        reserveStatusColumn: false,
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

  /// Whether a tool call in the conversation waits for the user to allow or
  /// deny it (Open WebUI 0.13 and later).
  final bool isAwaitingApproval;

  /// Optional compact provenance label, such as "On device".
  final String? badge;

  /// Whether the row should size itself to its contents instead of filling width.
  final bool shrinkWrap;

  /// Whether the title starts past the unread column. A list keeps it on
  /// every row so read and unread titles line up; a lone title, such as a
  /// row being dragged, has no column to line up with.
  final bool reserveStatusColumn;

  /// Creates the content layout for a conversation tile.
  const ConversationTileContent({
    super.key,
    required this.title,
    required this.pinned,
    required this.selected,
    this.unread = false,
    required this.isLoading,
    this.isGenerating = false,
    this.isAwaitingApproval = false,
    this.badge,
    this.shrinkWrap = false,
    this.reserveStatusColumn = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    // Every title uses primary ink at regular weight: the row fill marks
    // selection and the dot alone marks unread, so a list with many unread
    // chats does not turn into a wall of bold.
    final textStyle = AppTypography.sidebarTitleStyle.copyWith(
      color: theme.textPrimary,
      fontWeight: FontWeight.w400,
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
        Icon(
          Platform.isIOS ? CupertinoIcons.pin_fill : Icons.push_pin_rounded,
          key: const ValueKey<String>('conversation-pinned-indicator'),
          color: theme.textSecondary,
          size: IconSize.sm - 2,
        ),
      ]);
    }

    // A chat waiting for the user to approve a tool call is paused, not
    // working, so it shows a raised hand instead of the generation spinner.
    if (isAwaitingApproval && !isLoading) {
      final label = AppLocalizations.of(context)!.chatWaitingForApproval;
      trailingWidgets.addAll([
        const SizedBox(width: Spacing.sm),
        Tooltip(
          message: label,
          excludeFromSemantics: true,
          child: Semantics(
            label: label,
            child: Icon(
              Platform.isIOS
                  ? CupertinoIcons.hand_raised_fill
                  : Icons.back_hand_rounded,
              key: const ValueKey<String>('conversation-approval-indicator'),
              color: theme.warning,
              size: IconSize.sm,
            ),
          ),
        ),
      ]);
    } else if (isLoading || isGenerating) {
      // A server-side generation in progress shows the same spinner as a
      // tile that's loading on tap (the tap-load state takes precedence so we
      // never show two spinners).
      trailingWidgets.addAll([
        const SizedBox(width: Spacing.sm),
        SizedBox(
          key: isGenerating && !isLoading
              ? const ValueKey<String>('conversation-generating-indicator')
              : null,
          width: IconSize.sm,
          height: IconSize.sm,
          child: AdaptiveProgressIndicator(
            strokeWidth: BorderWidth.medium,
            color: theme.loadingIndicator,
          ),
        ),
      ]);
    }

    // VoiceOver reads the unread state after the title, as it announces
    // unread mail, although the dot is drawn before it.
    final unreadLabel = unread
        ? AppLocalizations.of(context)?.chatUnreadState
        : null;
    final titleWidget = Text(
      title,
      style: textStyle,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      semanticsLabel: unreadLabel == null ? title : '$title\n$unreadLabel',
    );

    // The unread dot sits in a column of its own before the title, as Mail
    // marks unread mail, so every title keeps one leading edge whether or
    // not its chat is read.
    final statusColumn = SizedBox(
      width: kSidebarRowStatusGutter,
      child: unread
          ? Align(
              alignment: AlignmentDirectional.centerStart,
              child: Container(
                key: const ValueKey<String>('conversation-unread-indicator'),
                width: kSidebarUnreadDotDiameter,
                height: kSidebarUnreadDotDiameter,
                decoration: BoxDecoration(
                  color: theme.textPrimary,
                  shape: BoxShape.circle,
                ),
              ),
            )
          : null,
    );

    return Row(
      mainAxisSize: shrinkWrap ? MainAxisSize.min : MainAxisSize.max,
      children: [
        if (reserveStatusColumn) statusColumn,
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

  /// Whether a tool call in the conversation waits for the user's approval.
  final bool isAwaitingApproval;

  /// Optional compact provenance label.
  final String? badge;

  /// Callback when the tile is tapped.
  final VoidCallback? onTap;

  /// Whether the title starts past the unread column; see
  /// [ConversationTileContent.reserveStatusColumn].
  final bool reserveStatusColumn;

  /// Creates a conversation tile widget.
  const ConversationTile({
    super.key,
    required this.title,
    required this.pinned,
    required this.selected,
    this.unread = false,
    required this.isLoading,
    this.isGenerating = false,
    this.isAwaitingApproval = false,
    this.badge,
    required this.onTap,
    this.reserveStatusColumn = true,
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
        constraints: const BoxConstraints(
          minHeight: kConversationTileMinHeight,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: kSidebarRowHorizontalPadding,
            vertical: Spacing.sm,
          ),
          child: ConversationTileContent(
            title: title,
            pinned: pinned,
            selected: selected,
            unread: unread,
            isLoading: isLoading,
            isGenerating: isGenerating,
            isAwaitingApproval: isAwaitingApproval,
            badge: badge,
            reserveStatusColumn: reserveStatusColumn,
          ),
        ),
      ),
    );
  }
}
