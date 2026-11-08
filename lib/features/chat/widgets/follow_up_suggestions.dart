import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:material_ui/material_ui.dart';

import '../../../core/services/haptic_service.dart';
import '../../../shared/theme/theme_extensions.dart';
import 'chat_send_motion.dart';

/// Suggested next prompts under a finished reply, as a short list of rows.
///
/// Each row is a full-width, at least 44 pt tall button in the label colour,
/// led by a reply arrow on its first line and separated from its neighbours
/// by hairlines, so the group reads as choices rather than as more of the
/// answer. Suggestions wrap instead of truncating: the whole prompt is what
/// gets sent, so the whole prompt is shown.
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

    final theme = context.conduitTheme;
    final separator = Padding(
      // Inset to the text, as iOS list separators are.
      padding: const EdgeInsetsDirectional.only(
        start: FollowUpSuggestionRow.textInset,
      ),
      child: Container(
        height: 1 / MediaQuery.devicePixelRatioOf(context),
        color: theme.dividerColor,
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < trimmedSuggestions.length; index++) ...[
          if (index > 0) separator,
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

/// One suggestion: a reply arrow aligned to the first line of its text, the
/// text wrapping in full, and a highlight that appears the moment a finger
/// lands.
@visibleForTesting
class FollowUpSuggestionRow extends StatefulWidget {
  const FollowUpSuggestionRow({super.key, required this.label, this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  /// The glyph column's width plus its gap; the text, and the separators
  /// between rows, start here.
  static const double textInset = 28;

  /// The pressed highlight extends past the text column by this much on each
  /// side, so it reads as the row's shape rather than a tight box around the
  /// words.
  static const double highlightOutset = 8;

  static const double minHeight = 44;

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
    // The sent message rises from the row that was tapped.
    ChatSendOrigin.recordFrom(context);
    onPressed();
  }

  TextStyle? _measuredStyle;
  TextScaler? _measuredScaler;
  double _measuredLineHeight = 0;

  /// One laid-out line of [style], cached until the style or text size
  /// changes.
  double _lineHeight(TextStyle style, TextScaler scaler) {
    if (style == _measuredStyle && scaler == _measuredScaler) {
      return _measuredLineHeight;
    }
    final painter = TextPainter(
      text: TextSpan(text: 'Ag', style: style),
      textScaler: scaler,
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    _measuredStyle = style;
    _measuredScaler = scaler;
    _measuredLineHeight = painter.height;
    painter.dispose();
    return _measuredLineHeight;
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textStyle = AppTypography.chatMessageStyle.copyWith(
      color: _enabled
          ? theme.textPrimary
          : theme.textPrimary.withValues(alpha: 0.38),
    );
    final glyphColor = _enabled
        ? theme.textPrimary.withValues(alpha: 0.5)
        : theme.textPrimary.withValues(alpha: 0.25);
    // The glyph sits in a box exactly one text line tall, so it centres on the
    // first line however many lines the suggestion wraps to.
    final textScaler = MediaQuery.textScalerOf(context);
    final firstLineHeight = _lineHeight(textStyle, textScaler);
    final glyphSize = textScaler.scale((textStyle.fontSize ?? 17) - 2);
    final highlight = theme.textPrimary.withValues(alpha: isDark ? 0.12 : 0.06);

    return Semantics(
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
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: -FollowUpSuggestionRow.highlightOutset,
              right: -FollowUpSuggestionRow.highlightOutset,
              top: 2,
              bottom: 2,
              // A colour change rather than a fade: the row never runs an
              // opacity transition, so it can't read as entrance motion.
              child: AnimatedContainer(
                key: ValueKey<String>('follow-up-highlight:${widget.label}'),
                // Instant on touch-down; a short fade back on release.
                duration: _isPressed
                    ? Duration.zero
                    : context.motionDuration(const Duration(milliseconds: 180)),
                curve: Curves.easeOut,
                decoration: BoxDecoration(
                  color: _isPressed
                      ? highlight
                      : highlight.withValues(alpha: 0),
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: FollowUpSuggestionRow.minHeight,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: FollowUpSuggestionRow.textInset,
                      height: firstLineHeight,
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Icon(
                          Platform.isIOS
                              ? CupertinoIcons.arrow_turn_down_right
                              : Icons.subdirectory_arrow_right_rounded,
                          size: glyphSize,
                          color: glyphColor,
                        ),
                      ),
                    ),
                    Expanded(child: Text(widget.label, style: textStyle)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
