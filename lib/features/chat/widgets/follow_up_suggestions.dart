import 'package:conduit/l10n/app_localizations.dart';
import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
import 'package:material_ui/material_ui.dart';

import '../../../core/services/haptic_service.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/chat_action_button.dart' show NativeSymbolGlyph;
import 'chat_send_motion.dart';

/// Suggested next prompts under a finished reply.
///
/// A small "Suggestions" heading leads a short stack of full-width rounded
/// rows, 8 pt apart, each led by a secondary follow-up arrow. A row is an
/// outline with no fill, so it reads as an option to tap rather than as a
/// message already sent (sent messages sit on a fill); its text is in the
/// label colour, at 15 pt under the 17 pt answer, and one shared width keeps
/// the edges even. A suggestion shows in full, however many lines it takes,
/// so what a tap sends is what the row says.
class FollowUpSuggestionBar extends StatelessWidget {
  const FollowUpSuggestionBar({
    super.key,
    required this.suggestions,
    required this.onSelected,
    required this.isBusy,
  });

  final List<String> suggestions;
  final ValueChanged<String> onSelected;
  final bool isBusy;

  /// Space between the action row above and the heading. The action row's
  /// 44 pt targets already leave about 12 pt of air under its glyphs, so this
  /// stays small: the heading should sit visibly closer to the suggestions it
  /// names than to the actions above it.
  static const double headingTopGap = Spacing.xxs;

  /// Space between the heading and the first suggestion.
  static const double headingBottomGap = Spacing.sm;

  /// Space between suggestions.
  static const double rowGap = Spacing.sm;

  @override
  Widget build(BuildContext context) {
    final trimmedSuggestions = suggestions
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .take(3)
        .toList(growable: false);

    if (trimmedSuggestions.isEmpty) {
      return const SizedBox.shrink();
    }

    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            top: headingTopGap,
            bottom: headingBottomGap,
          ),
          // Its own node, so VoiceOver reads it as a heading rather than as
          // the last line of the reply it follows.
          child: Semantics(
            container: true,
            header: true,
            child: Text(
              l10n.followUpSuggestionsHeading,
              key: const ValueKey<String>('follow-up-heading'),
              style: AppTypography.labelMediumStyle.copyWith(
                color: theme.textSecondary,
              ),
            ),
          ),
        ),
        for (var index = 0; index < trimmedSuggestions.length; index++) ...[
          if (index > 0) const SizedBox(height: rowGap),
          FollowUpSuggestionRow(
            label: trimmedSuggestions[index],
            onPressed: isBusy
                ? null
                : () => onSelected(trimmedSuggestions[index]),
          ),
        ],
      ],
    );
  }
}

/// One suggestion: a full-width outlined row led by a follow-up arrow, that
/// fills the moment a finger lands. It shows, reads to VoiceOver and sends
/// the whole prompt.
@visibleForTesting
class FollowUpSuggestionRow extends StatefulWidget {
  const FollowUpSuggestionRow({super.key, required this.label, this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  static const double minHeight = 44;

  /// The outline's width: a full point, so the edge holds up against the
  /// page as clearly as a fill would, without being one.
  static const double outlineWidth = 1;

  /// Inner padding: one 15 pt line (20 pt leading) plus 10 pt above and
  /// below, centred in the 44 pt minimum; the leading inset clears the
  /// glyph's curve.
  static const EdgeInsetsDirectional padding = EdgeInsetsDirectional.fromSTEB(
    12,
    10,
    14,
    10,
  );

  /// One radius for rows of any height, so the stack reads as a set.
  static const double cornerRadius = 14;

  /// The leading arrow, at the 15 pt text's optical size.
  static const String sfSymbol = 'arrow.turn.down.right';
  static const double glyphSize = 14;
  static const double glyphGap = 8;

  @override
  State<FollowUpSuggestionRow> createState() => _FollowUpSuggestionRowState();
}

class _FollowUpSuggestionRowState extends State<FollowUpSuggestionRow> {
  bool _isPressed = false;

  /// The suggestion's words, where the sent message rises from.
  final GlobalKey _textKey = GlobalKey(debugLabel: 'follow-up-text');

  bool get _enabled => widget.onPressed != null;

  @override
  void didUpdateWidget(FollowUpSuggestionRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_enabled && _isPressed) {
      _isPressed = false;
    }
  }

  void _setPressed(bool value) {
    if (_isPressed == value || !_enabled) return;
    setState(() => _isPressed = value);
  }

  void _handleTap() {
    final onPressed = widget.onPressed;
    if (onPressed == null) return;
    ConduitHaptics.selectionClick();
    // The sent message rises from the words that were tapped.
    ChatSendOrigin.recordFrom(_textKey.currentContext ?? context);
    onPressed();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // A monochrome outline at rest, the label colour at a low opacity; a
    // touch fills the row as a list row highlights. Busy (a reply is
    // running), the outline fades with the text.
    final outline = theme.textPrimary.withValues(
      alpha: (isDark ? 0.24 : 0.16) * (_enabled ? 1 : 0.5),
    );
    final restFill = theme.textPrimary.withValues(alpha: 0);
    final pressedFill = theme.textPrimary.withValues(
      alpha: isDark ? 0.14 : 0.07,
    );
    // Label-colour text, so the row reads as a live choice rather than as
    // disabled; the arrow stays secondary. Busy, both dim together.
    final foreground = _enabled
        ? theme.textPrimary
        : theme.textPrimary.withValues(alpha: 0.3);
    final glyphColor = _enabled
        ? theme.textSecondary
        : theme.textSecondary.withValues(alpha: 0.38);
    final textStyle = AppTypography.titleMediumStyle.copyWith(
      color: foreground,
    );
    final textScaler = MediaQuery.textScalerOf(context);
    final glyphSize = textScaler.scale(FollowUpSuggestionRow.glyphSize);
    // Centre the glyph on the first line, so it stays with the start of a
    // suggestion that wraps.
    final firstLineHeight = textScaler.scale(
      (textStyle.fontSize ?? 15) * (textStyle.height ?? 1.3),
    );
    final glyph = NativeSymbolGlyph.isAvailable
        ? NativeSymbolGlyph(
            symbol: FollowUpSuggestionRow.sfSymbol,
            fallbackIcon: CupertinoIcons.arrow_turn_down_right,
            pointSize: glyphSize,
            color: glyphColor,
          )
        : Icon(
            Theme.of(context).platform == TargetPlatform.iOS
                ? CupertinoIcons.arrow_turn_down_right
                : Icons.subdirectory_arrow_right_rounded,
            size: glyphSize,
            color: glyphColor,
          );

    return Semantics(
      container: true,
      button: true,
      enabled: _enabled,
      // The whole prompt, however much of it the row shows.
      label: widget.label,
      onTap: _enabled ? _handleTap : null,
      excludeSemantics: true,
      child: GestureDetector(
        key: ValueKey<String>('follow-up-row:${widget.label}'),
        behavior: HitTestBehavior.opaque,
        onTapDown: _enabled ? (_) => _setPressed(true) : null,
        onTapUp: _enabled ? (_) => _setPressed(false) : null,
        onTapCancel: _enabled ? () => _setPressed(false) : null,
        onTap: _enabled ? _handleTap : null,
        // A colour change rather than a fade: the row never runs an
        // opacity transition, so it can't read as entrance motion.
        child: AnimatedContainer(
          key: ValueKey<String>('follow-up-highlight:${widget.label}'),
          // Instant on touch-down; a short ease back on release.
          duration: _isPressed
              ? Duration.zero
              : context.motionDuration(const Duration(milliseconds: 180)),
          curve: Curves.easeOut,
          constraints: const BoxConstraints(
            minHeight: FollowUpSuggestionRow.minHeight,
          ),
          alignment: AlignmentDirectional.centerStart,
          padding: FollowUpSuggestionRow.padding,
          decoration: ShapeDecoration(
            color: _isPressed ? pressedFill : restFill,
            shape: RoundedSuperellipseBorder(
              side: BorderSide(
                color: outline,
                width: FollowUpSuggestionRow.outlineWidth,
              ),
              borderRadius: BorderRadius.circular(
                FollowUpSuggestionRow.cornerRadius,
              ),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: firstLineHeight,
                child: Center(child: glyph),
              ),
              const SizedBox(width: FollowUpSuggestionRow.glyphGap),
              Expanded(
                child: Text(widget.label, key: _textKey, style: textStyle),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
