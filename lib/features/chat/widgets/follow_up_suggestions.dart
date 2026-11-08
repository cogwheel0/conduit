import 'package:conduit/l10n/app_localizations.dart';
import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
import 'package:material_ui/material_ui.dart';

import '../../../core/services/haptic_service.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/chat_action_button.dart' show NativeSymbolGlyph;
import 'chat_send_motion.dart';

/// Suggested next prompts under a finished reply.
///
/// A small "Suggestions" heading leads a short stack of rounded buttons on a
/// quiet fill, each as wide as its words and led by a follow-up arrow. The
/// 15 pt text, the fill and the glyph set them apart from the 17 pt answer
/// above, so they read as choices rather than more of the reply. A suggestion
/// is never cut short: what a tap sends is what the button shows.
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

/// One suggestion: a rounded button as wide as its words, led by a
/// follow-up arrow, that darkens the moment a finger lands.
///
/// It hugs its text rather than spanning the column, so it reads as a
/// control and not as a quoted message, and it shows the whole prompt,
/// wrapping as needed: a tap sends all of it, so all of it is shown.
@visibleForTesting
class FollowUpSuggestionRow extends StatefulWidget {
  const FollowUpSuggestionRow({super.key, required this.label, this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  static const double minHeight = 44;

  /// Inner padding: one 15 pt line (20 pt leading) plus 12 pt above and
  /// below makes 44 pt; the leading inset clears the glyph's curve.
  static const EdgeInsetsDirectional padding = EdgeInsetsDirectional.fromSTEB(
    12,
    12,
    16,
    12,
  );

  /// Half the one-line height, so a one-line suggestion is a capsule and a
  /// longer one a softly rounded block.
  static const double cornerRadius = minHeight / 2;

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
    // Monochrome fills, like the system's gray button: the label colour at a
    // low opacity, a step stronger while pressed.
    final restFill = theme.textPrimary.withValues(alpha: isDark ? 0.12 : 0.05);
    final pressedFill = theme.textPrimary.withValues(
      alpha: isDark ? 0.22 : 0.12,
    );
    final foreground = _enabled
        ? theme.textPrimary
        : theme.textPrimary.withValues(alpha: 0.38);
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

    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Semantics(
        container: true,
        button: true,
        enabled: _enabled,
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
            padding: FollowUpSuggestionRow.padding,
            decoration: ShapeDecoration(
              color: _isPressed ? pressedFill : restFill,
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(
                  FollowUpSuggestionRow.cornerRadius,
                ),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: firstLineHeight,
                  child: Center(child: glyph),
                ),
                const SizedBox(width: FollowUpSuggestionRow.glyphGap),
                Flexible(
                  child: Text(
                    widget.label,
                    key: _textKey,
                    style: textStyle,
                    // The whole prompt: a tap sends all of it.
                    softWrap: true,
                    textWidthBasis: TextWidthBasis.longestLine,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
