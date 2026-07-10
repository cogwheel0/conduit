import 'package:flutter/material.dart';

import '../../../shared/theme/theme_extensions.dart';

/// A bar displaying follow-up suggestion buttons for the user to continue
/// a conversation with pre-suggested prompts.
class FollowUpSuggestionBar extends StatefulWidget {
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
  State<FollowUpSuggestionBar> createState() => _FollowUpSuggestionBarState();
}

class _FollowUpSuggestionBarState extends State<FollowUpSuggestionBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entranceController;
  bool _hasStartedEntrance = false;
  bool _disableEntranceMotion = false;

  @override
  void initState() {
    super.initState();
    _entranceController = AnimationController(
      vsync: this,
      duration: AnimationDuration.fast,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disableEntranceMotion =
        MediaQuery.maybeDisableAnimationsOf(context) ??
        WidgetsBinding
            .instance
            .platformDispatcher
            .accessibilityFeatures
            .disableAnimations;
    if (_hasStartedEntrance) {
      _disableEntranceMotion = disableEntranceMotion;
      return;
    }
    _hasStartedEntrance = true;
    _disableEntranceMotion = disableEntranceMotion;
    _entranceController.forward();
  }

  @override
  void dispose() {
    _entranceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final trimmedSuggestions = widget.suggestions
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .take(3)
        .toList(growable: false);

    if (trimmedSuggestions.isEmpty) {
      return const SizedBox.shrink();
    }

    return Wrap(
      spacing: Spacing.xs,
      runSpacing: Spacing.xs,
      children: [
        for (var index = 0; index < trimmedSuggestions.length; index++)
          _buildAnimatedSuggestion(trimmedSuggestions[index], index),
      ],
    );
  }

  Widget _buildAnimatedSuggestion(String suggestion, int index) {
    final start = index * 0.18;
    final animation = CurvedAnimation(
      parent: _entranceController,
      curve: Interval(
        start,
        (0.78 + start).clamp(0.0, 1.0).toDouble(),
        curve: AnimationCurves.messageSlide,
      ),
    );

    return FadeTransition(
      opacity: animation,
      alwaysIncludeSemantics: true,
      child: SlideTransition(
        position: _disableEntranceMotion
            ? const AlwaysStoppedAnimation<Offset>(Offset.zero)
            : Tween<Offset>(
                begin: const Offset(0, 0.12),
                end: Offset.zero,
              ).animate(animation),
        child: _MinimalFollowUpButton(
          label: suggestion,
          onPressed: widget.isBusy ? null : () => widget.onSelected(suggestion),
          enabled: !widget.isBusy,
        ),
      ),
    );
  }
}

class _MinimalFollowUpButton extends StatelessWidget {
  const _MinimalFollowUpButton({
    required this.label,
    this.onPressed,
    this.enabled = true,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final textStyle = AppTypography.chatMessageStyle.copyWith(
      color: enabled
          ? theme.buttonPrimary.withValues(alpha: 0.75)
          : theme.textSecondary.withValues(alpha: 0.45),
    );
    final iconSize =
        (textStyle.fontSize ?? AppTypography.chatMessageStyle.fontSize ?? 16) +
        1;

    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onPressed : null,
        child: ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.subdirectory_arrow_right_rounded,
                  size: iconSize,
                  color: enabled
                      ? theme.buttonPrimary.withValues(alpha: 0.7)
                      : theme.textSecondary.withValues(alpha: 0.4),
                ),
                const SizedBox(width: Spacing.xs),
                Flexible(
                  child: Text(
                    label,
                    style: textStyle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
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
