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
/// rows on a quiet fill, 8 pt apart, each led by a secondary follow-up
/// arrow. Their text is in the label colour, like a system gray button's, so
/// they read as live choices; the 15 pt size, the fill and the arrow keep
/// them apart from the 17 pt answer, and one shared width keeps their edges
/// even. A long suggestion shows its first two lines, ending on a whole word
/// and an ellipsis; VoiceOver reads, and a tap sends, all of it.
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

/// One suggestion: a full-width rounded row led by a follow-up arrow, that
/// darkens the moment a finger lands.
///
/// It shows at most [maxLines] lines of the prompt, cut at a word boundary
/// with an ellipsis, never mid-word; its accessibility label and what a tap
/// sends are always the whole prompt.
@visibleForTesting
class FollowUpSuggestionRow extends StatefulWidget {
  const FollowUpSuggestionRow({super.key, required this.label, this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  static const double minHeight = 44;

  /// Lines of the prompt a row shows.
  static const int maxLines = 2;

  /// Inner padding: one 15 pt line (20 pt leading) plus 10 pt above and
  /// below, centred in the 44 pt minimum; the leading inset clears the
  /// glyph's curve.
  static const EdgeInsetsDirectional padding = EdgeInsetsDirectional.fromSTEB(
    12,
    10,
    14,
    10,
  );

  /// One radius for one- and two-line rows alike, so the stack reads as a
  /// set of equal cards.
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
    // Monochrome fills, like the system's gray button: the label colour at a
    // low opacity, a step stronger while pressed.
    final restFill = theme.textPrimary.withValues(alpha: isDark ? 0.12 : 0.05);
    final pressedFill = theme.textPrimary.withValues(
      alpha: isDark ? 0.22 : 0.12,
    );
    // Label-colour text on the quiet fill, so the row reads as a button
    // rather than as disabled; the arrow stays secondary. Busy (a reply is
    // running), both dim together.
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
                child: LayoutBuilder(
                  builder: (context, constraints) => Text(
                    followUpSuggestionClampedText(
                      widget.label,
                      style: textStyle,
                      maxWidth: constraints.maxWidth,
                      maxLines: FollowUpSuggestionRow.maxLines,
                      textScaler: textScaler,
                      textDirection: Directionality.of(context),
                      locale: Localizations.maybeLocaleOf(context),
                    ),
                    key: _textKey,
                    style: textStyle,
                    maxLines: FollowUpSuggestionRow.maxLines,
                    // Only for a single word longer than two lines; any
                    // other cut is made on a word boundary above.
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Characters a shortened suggestion should not end on before its ellipsis.
final RegExp _danglingTail = RegExp(r'[\s,;:.\-–—/(\[{"“‘]+$');

/// [text] as it fits in [maxLines] lines of [maxWidth]: whole, or cut after
/// the last whole word that leaves room for an ellipsis (and without a
/// dangling comma, dash or opening bracket before it). Words are found the
/// way the text engine breaks them, so languages written without spaces cut
/// cleanly too. A single word too long for the lines comes back whole, for
/// the text's own ellipsis.
@visibleForTesting
String followUpSuggestionClampedText(
  String text, {
  required TextStyle style,
  required double maxWidth,
  required int maxLines,
  TextScaler textScaler = TextScaler.noScaling,
  TextDirection textDirection = TextDirection.ltr,
  Locale? locale,
}) {
  if (!maxWidth.isFinite || maxWidth <= 0 || text.isEmpty) return text;
  TextPainter painterFor(String value, {int? lines}) => TextPainter(
    text: TextSpan(text: value, style: style),
    textDirection: textDirection,
    textScaler: textScaler,
    locale: locale,
    maxLines: lines,
  )..layout(maxWidth: maxWidth);

  bool fits(String value) {
    final painter = painterFor(value, lines: maxLines);
    final fits = !painter.didExceedMaxLines;
    painter.dispose();
    return fits;
  }

  if (fits(text)) return text;

  final full = painterFor(text);
  try {
    final lines = full.computeLineMetrics();
    if (lines.length <= maxLines) return text;
    final lastShown = lines[maxLines - 1];
    // Where the last shown line ends in the text.
    final lineEnd = full
        .getLineBoundary(
          full.getPositionForOffset(
            Offset(lastShown.left + lastShown.width / 2, lastShown.baseline),
          ),
        )
        .end;
    var cut = lineEnd;
    while (cut > 0) {
      // The word (or run of spaces) just before the cut.
      final word = full.getWordBoundary(TextPosition(offset: cut - 1));
      final wordStart = word.start < cut ? word.start : cut - 1;
      if (word.end == cut) {
        final kept = text.substring(0, cut).replaceFirst(_danglingTail, '');
        if (kept.isNotEmpty && fits('$kept…')) return '$kept…';
      }
      // Mid-word, or no room for the ellipsis: drop that word and retry.
      cut = wordStart;
    }
    return text;
  } finally {
    full.dispose();
  }
}
