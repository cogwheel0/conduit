import 'package:conduit/shared/widgets/platform_ui/vocabulary.dart';
import 'package:flutter/widgets.dart';

import '../../../core/services/haptic_service.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/chat_action_button.dart' show NativeSymbolGlyph;

/// Suggested next prompts under a finished reply.
///
/// A short list of plain rows under the reply's actions, each led by a
/// secondary follow-up arrow on the reply's leading edge: no heading and no
/// card, so they read as next steps of the conversation rather than as
/// another block of content. The text is regular weight in a lighter tone
/// of the button colour, so it reads as an offer rather than as more of the
/// reply. A suggestion shows up to
/// [FollowUpSuggestionRow.maxLines] lines, which most server suggestions
/// fit, and ends a longer one with an ellipsis, so three of them stay a
/// short list under the reply rather than outweighing it; a tap still
/// sends, and VoiceOver still reads, the whole prompt.
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

    // Each row's own padding spaces the list, so the rows' 44 pt targets
    // meet without a gap between them.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final suggestion in trimmedSuggestions)
          FollowUpSuggestionRow(
            label: suggestion,
            onPressed: isBusy ? null : () => onSelected(suggestion),
          ),
      ],
    );
  }
}

/// One suggestion: a plain full-width row led by a follow-up arrow, whose
/// text dims the moment a finger lands, as a plain iOS button does. It shows
/// up to [maxLines] lines of the prompt, with an ellipsis after a longer
/// one, and reads to VoiceOver and sends the whole prompt.
@visibleForTesting
class FollowUpSuggestionRow extends StatefulWidget {
  const FollowUpSuggestionRow({super.key, required this.label, this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  static const double minHeight = 44;

  /// Lines a suggestion shows before it ends in an ellipsis: enough for
  /// most suggestions to read in full, few enough that three stay lighter
  /// than the reply. Never cut mid-word: the ellipsis follows the last word
  /// that fits.
  static const int maxLines = 3;

  /// Space above and below a suggestion's text: a one-line suggestion (a
  /// 20 pt line) sits centred in the 44 pt minimum, and the text of one
  /// suggestion is about 20 pt from the next. No leading or trailing inset:
  /// the arrow starts on the reply's own edge.
  static const EdgeInsetsDirectional padding = EdgeInsetsDirectional.symmetric(
    vertical: 10,
  );

  /// The leading arrow, a little under the text's size.
  static const String sfSymbol = 'arrow.turn.down.right';
  static const double glyphSize = 14;
  static const double glyphGap = 8;

  /// How much of its colour the text and arrow keep while pressed.
  static const double pressedOpacity = 0.35;

  /// The button colour's share in the text, and in the arrow, at rest.
  static const double textTone = 0.75;
  static const double glyphTone = 0.7;

  @override
  State<FollowUpSuggestionRow> createState() => _FollowUpSuggestionRowState();
}

class _FollowUpSuggestionRowState extends State<FollowUpSuggestionRow> {
  bool _isPressed = false;

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
    onPressed();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final textScaler = MediaQuery.textScalerOf(context);
    final glyphSize = textScaler.scale(FollowUpSuggestionRow.glyphSize);
    // A step under the reply's size, at regular weight.
    final baseStyle = AppTypography.titleMediumStyle.copyWith(
      fontWeight: FontWeight.w400,
    );
    // Centre the glyph on the first line, so it stays with the start of a
    // suggestion that wraps.
    final firstLineHeight = textScaler.scale(
      (baseStyle.fontSize ?? 15) * (baseStyle.height ?? 1.3),
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
        // A colour change rather than a fade of the row: it never runs an
        // opacity transition, so it can't read as entrance motion. Instant
        // on touch-down; a short ease back on release.
        child: TweenAnimationBuilder<double>(
          key: ValueKey<String>('follow-up-highlight:${widget.label}'),
          tween: Tween<double>(end: _isPressed ? 1 : 0),
          duration: _isPressed
              ? Duration.zero
              : context.motionDuration(const Duration(milliseconds: 180)),
          curve: Curves.easeOut,
          builder: (context, pressed, _) {
            final keep =
                1 - pressed * (1 - FollowUpSuggestionRow.pressedOpacity);
            // A lighter tone of the button colour, so the row reads as an
            // offer beside the reply's own text. Busy (a reply is running),
            // both fade further.
            final foreground = _enabled
                ? theme.buttonPrimary.withValues(
                    alpha:
                        theme.buttonPrimary.a *
                        FollowUpSuggestionRow.textTone *
                        keep,
                  )
                : theme.textSecondary.withValues(alpha: 0.45);
            final glyphColor = _enabled
                ? theme.buttonPrimary.withValues(
                    alpha:
                        theme.buttonPrimary.a *
                        FollowUpSuggestionRow.glyphTone *
                        keep,
                  )
                : theme.textSecondary.withValues(alpha: 0.4);
            final textStyle = baseStyle.copyWith(color: foreground);
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
            return ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: FollowUpSuggestionRow.minHeight,
              ),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Padding(
                  padding: FollowUpSuggestionRow.padding,
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
                            style: textStyle,
                            maxLines: FollowUpSuggestionRow.maxLines,
                            // Only for a single word longer than the lines;
                            // any other cut is made on a word boundary above.
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
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
