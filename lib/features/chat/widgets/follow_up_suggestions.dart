import 'package:conduit/l10n/app_localizations.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/services/haptic_service.dart';
import '../../../shared/theme/theme_extensions.dart';
import 'chat_send_motion.dart';

/// Suggested next prompts under a finished reply.
///
/// A small "Suggestions" heading leads a short stack of rounded buttons on a
/// quiet fill. The 15 pt text and the fill set them apart from the 17 pt
/// answer above, so they read as choices rather than more of the reply, and
/// each one is clearly something to tap. A long suggestion stops after two
/// lines; VoiceOver still reads all of it, and a tap sends all of it.
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
  /// 44 pt targets already leave air under its glyphs, so this only tops it
  /// up to the gap the heading keeps from the first suggestion.
  static const double headingTopGap = Spacing.sm;

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
          child: Semantics(
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

/// One suggestion: a full-width rounded button on a quiet fill, at most two
/// lines of text, that darkens the moment a finger lands.
@visibleForTesting
class FollowUpSuggestionRow extends StatefulWidget {
  const FollowUpSuggestionRow({super.key, required this.label, this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  static const double minHeight = 44;

  /// Inner padding: one 15 pt line plus this above and below makes 44 pt.
  static const EdgeInsets padding = EdgeInsets.symmetric(
    horizontal: 12,
    vertical: 12,
  );

  static const double cornerRadius = 12;

  /// Lines shown before the text is cut with an ellipsis.
  static const int maxLines = 2;

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

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Monochrome fills, like the system's gray button: the label colour at a
    // low opacity, a step stronger while pressed.
    final restFill = theme.textPrimary.withValues(alpha: isDark ? 0.10 : 0.05);
    final pressedFill = theme.textPrimary.withValues(
      alpha: isDark ? 0.18 : 0.11,
    );
    final textStyle = AppTypography.titleMediumStyle.copyWith(
      color: _enabled
          ? theme.textPrimary
          : theme.textPrimary.withValues(alpha: 0.38),
    );

    return Semantics(
      container: true,
      button: true,
      enabled: _enabled,
      // The whole suggestion, even when the row shows only two lines of it.
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
        // A colour change rather than a fade: the row never runs an opacity
        // transition, so it can't read as entrance motion.
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
          alignment: AlignmentDirectional.centerStart,
          decoration: ShapeDecoration(
            color: _isPressed ? pressedFill : restFill,
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(
                FollowUpSuggestionRow.cornerRadius,
              ),
            ),
          ),
          child: Text(
            widget.label,
            style: textStyle,
            maxLines: FollowUpSuggestionRow.maxLines,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}
