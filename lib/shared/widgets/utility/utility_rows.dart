import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/platform_service.dart';
import '../../../core/services/settings_service.dart';
import '../../theme/theme_extensions.dart';

/// Shared utility row with full-row semantics and immediate press feedback.
class UtilityRow extends ConsumerStatefulWidget {
  const UtilityRow({
    super.key,
    required this.title,
    this.subtitle,
    this.subtitleTrailing,
    this.subtitleMaxLines = 3,
    this.leading,
    this.trailing,
    this.preserveTrailingSemantics = false,
    this.status,
    this.onTap,
    this.selected = false,
    this.expanded,
    this.enabled = true,
    this.destructive = false,
    this.showChevron = false,
    this.semanticLabel,
    this.padding = const EdgeInsets.symmetric(
      horizontal: Spacing.md,
      vertical: Spacing.sm,
    ),
    this.hapticType = HapticType.selection,
  });

  final String title;
  final String? subtitle;
  final Widget? subtitleTrailing;
  final int subtitleMaxLines;
  final Widget? leading;
  final Widget? trailing;

  /// Keeps an interactive trailing control as its own accessibility node.
  final bool preserveTrailingSemantics;
  final Widget? status;
  final VoidCallback? onTap;
  final bool selected;
  final bool? expanded;
  final bool enabled;
  final bool destructive;
  final bool showChevron;
  final String? semanticLabel;
  final EdgeInsetsGeometry padding;
  final HapticType? hapticType;

  @override
  ConsumerState<UtilityRow> createState() => _UtilityRowState();
}

class _UtilityRowState extends ConsumerState<UtilityRow> {
  bool _pressed = false;

  bool get _interactive => widget.enabled && widget.onTap != null;

  void _setPressed(bool value) {
    if (_pressed == value || !_interactive) return;
    setState(() => _pressed = value);
  }

  void _handleTap() {
    if (!_interactive) return;
    final type = widget.hapticType;
    if (type != null) {
      PlatformService.hapticFeedbackWithSettings(
        type: type,
        hapticEnabled: ref.read(hapticEnabledProvider),
      );
    }
    widget.onTap!();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final usesLargeText = MediaQuery.textScalerOf(context).scale(1) > 1.3;
    final foreground = widget.destructive ? theme.error : theme.textPrimary;
    final opacity = widget.enabled ? 1.0 : 0.45;
    final semantics =
        widget.semanticLabel ??
        [
          widget.title,
          if (widget.subtitle?.isNotEmpty ?? false) widget.subtitle,
        ].join('. ');

    return Semantics(
      button: _interactive,
      enabled: widget.enabled,
      selected: widget.selected,
      expanded: widget.expanded,
      label: semantics,
      onTap: _interactive ? _handleTap : null,
      excludeSemantics: !widget.preserveTrailingSemantics,
      explicitChildNodes: widget.preserveTrailingSemantics,
      child: FocusableActionDetector(
        enabled: _interactive,
        mouseCursor: _interactive
            ? SystemMouseCursors.click
            : MouseCursor.defer,
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _handleTap();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: _interactive ? (_) => _setPressed(true) : null,
          onTapUp: _interactive ? (_) => _setPressed(false) : null,
          onTapCancel: _interactive ? () => _setPressed(false) : null,
          onTap: _interactive ? _handleTap : null,
          child: AnimatedScale(
            scale: _pressed && !context.reduceMotion ? 0.98 : 1,
            duration: context.motionDuration(AnimationDuration.buttonPress),
            curve: Curves.easeOutCubic,
            child: Opacity(
              opacity: opacity,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: TouchTarget.minimum,
                ),
                child: Padding(
                  padding: widget.padding,
                  child: Row(
                    children: [
                      if (widget.leading != null) ...[
                        if (widget.preserveTrailingSemantics)
                          ExcludeSemantics(child: widget.leading!)
                        else
                          widget.leading!,
                        const SizedBox(width: Spacing.md),
                      ],
                      Expanded(
                        child: ExcludeSemantics(
                          excluding: widget.preserveTrailingSemantics,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                widget.title,
                                maxLines: usesLargeText ? null : 2,
                                overflow: usesLargeText
                                    ? TextOverflow.visible
                                    : TextOverflow.ellipsis,
                                style: AppTypography.bodyMediumStyle.copyWith(
                                  color: foreground,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (widget.subtitle != null &&
                                  widget.subtitle!.isNotEmpty) ...[
                                const SizedBox(height: Spacing.xxs),
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Flexible(
                                      child: Text(
                                        widget.subtitle!,
                                        maxLines: usesLargeText
                                            ? null
                                            : widget.subtitleMaxLines,
                                        overflow: usesLargeText
                                            ? TextOverflow.visible
                                            : TextOverflow.ellipsis,
                                        style: AppTypography.bodySmallStyle
                                            .copyWith(
                                              color: theme.textSecondary,
                                            ),
                                      ),
                                    ),
                                    if (widget.subtitleTrailing != null) ...[
                                      const SizedBox(width: Spacing.xs),
                                      widget.subtitleTrailing!,
                                    ],
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      if (widget.status != null) ...[
                        const SizedBox(width: Spacing.sm),
                        Flexible(
                          child: widget.preserveTrailingSemantics
                              ? widget.status!
                              : ExcludeSemantics(child: widget.status!),
                        ),
                      ],
                      if (widget.trailing != null) ...[
                        const SizedBox(width: Spacing.sm),
                        widget.trailing!,
                      ] else if (widget.showChevron && _interactive) ...[
                        const SizedBox(width: Spacing.sm),
                        Icon(
                          context.usesCupertinoChrome
                              ? CupertinoIcons.chevron_right
                              : Icons.chevron_right,
                          color: theme.iconSecondary,
                          size: IconSize.small,
                        ),
                      ],
                    ],
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

/// A selectable [UtilityRow] with the standard animated selection affordance.
///
/// Keeping selection presentation here lets provider pickers share the same
/// haptics, pressed state, semantics, and typography as every utility row.
class UtilitySelectionRow extends StatelessWidget {
  const UtilitySelectionRow({
    super.key,
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.showDivider = false,
    this.showSelectionIndicator = true,
    this.trailing,
  });

  final Widget leading;
  final String title;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;
  final bool showDivider;
  final bool showSelectionIndicator;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final row = UtilityRow(
      leading: leading,
      title: title,
      subtitle: subtitle,
      selected: selected,
      onTap: onTap,
      semanticLabel: [
        title,
        if (subtitle?.isNotEmpty ?? false) subtitle,
      ].join('. '),
      padding: const EdgeInsets.symmetric(vertical: Spacing.md),
      trailing:
          trailing ??
          (showSelectionIndicator
              ? AnimatedSwitcher(
                  duration: context.motionDuration(
                    AnimationDuration.microInteraction,
                  ),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeOutCubic,
                  child: selected
                      ? Icon(
                          context.usesCupertinoChrome
                              ? CupertinoIcons.check_mark_circled_solid
                              : Icons.check_circle,
                          key: const ValueKey<String>('selected'),
                          color: theme.buttonPrimary,
                          size: IconSize.medium,
                        )
                      : const SizedBox.square(
                          key: ValueKey<String>('unselected'),
                          dimension: IconSize.medium,
                        ),
                )
              : null),
    );
    if (!showDivider) return row;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: theme.dividerColor,
            width: BorderWidth.thin,
          ),
        ),
      ),
      child: row,
    );
  }
}

class UtilityValueRow extends StatelessWidget {
  const UtilityValueRow({
    super.key,
    required this.label,
    required this.value,
    this.leading,
    this.trailing,
    this.onTap,
    this.monospace = false,
    this.stacked = false,
    this.showDivider = false,
  });

  final String label;
  final String value;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool monospace;
  final bool stacked;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final valueText = SelectableText(
      value,
      maxLines: 2,
      textAlign: stacked ? TextAlign.start : TextAlign.end,
      style: AppTypography.bodySmallStyle.copyWith(
        color: theme.textSecondary,
        fontWeight: FontWeight.w600,
        fontFamily: monospace ? AppTypography.monospaceFontFamily : null,
      ),
    );
    final row = UtilityRow(
      title: label,
      subtitle: stacked ? value : null,
      leading: leading,
      trailing: trailing,
      onTap: onTap,
      hapticType: onTap == null ? null : HapticType.selection,
      semanticLabel: '$label. $value',
      padding: const EdgeInsets.all(Spacing.md),
      status: stacked ? null : valueText,
    );
    if (!showDivider) return row;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: theme.dividerColor,
            width: BorderWidth.thin,
          ),
        ),
      ),
      child: row,
    );
  }
}
