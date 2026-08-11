import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/platform_service.dart';
import '../../core/services/settings_service.dart';
import '../theme/theme_extensions.dart';
import 'adaptive_route_shell.dart';
import 'adaptive_toolbar_components.dart';
import 'platform_ui/platform_ui.dart';

/// Standard shell for settings and other calm, grouped utility screens.
///
/// The native scaffold owns the navigation inset. Content therefore starts at
/// one standard page gap, avoiding a second status-bar and app-bar offset on
/// iOS.
class UtilityPageScaffold extends StatefulWidget {
  const UtilityPageScaffold({
    super.key,
    required this.title,
    required this.children,
    this.body,
    this.appBar,
    this.controller,
    this.maxWidth = 640,
    this.bottomAction,
    this.backgroundColor,
    this.physics,
    this.contentPadding,
    this.backLabel,
    this.backButtonKey,
    this.onBack,
    this.interactiveScrollbar = false,
    this.bottomActionPadding,
  }) : assert(body == null),
       assert(
         (backLabel == null && backButtonKey == null && onBack == null) ||
             (backLabel != null && backButtonKey != null && onBack != null),
         'Back label, key, and callback must be supplied together.',
       );

  const UtilityPageScaffold.auth({
    super.key,
    required this.title,
    required this.body,
    this.backLabel,
    this.backButtonKey,
    this.onBack,
    this.bottomAction,
    this.backgroundColor,
  }) : children = null,
       appBar = null,
       controller = null,
       maxWidth = 480,
       physics = const BouncingScrollPhysics(
         parent: AlwaysScrollableScrollPhysics(),
       ),
       contentPadding = const EdgeInsets.fromLTRB(
         Spacing.pagePadding,
         Spacing.lg,
         Spacing.pagePadding,
         Spacing.xl,
       ),
       interactiveScrollbar = true,
       bottomActionPadding = const EdgeInsets.fromLTRB(
         Spacing.pagePadding,
         Spacing.md,
         Spacing.pagePadding,
         Spacing.md,
       ),
       assert(
         (backLabel == null && backButtonKey == null && onBack == null) ||
             (backLabel != null && backButtonKey != null && onBack != null),
         'Back label, key, and callback must be supplied together.',
       );

  const UtilityPageScaffold.settings({
    super.key,
    required this.title,
    required this.children,
  }) : body = null,
       appBar = null,
       controller = null,
       maxWidth = 640,
       bottomAction = null,
       backgroundColor = null,
       physics = null,
       contentPadding = null,
       backLabel = null,
       backButtonKey = null,
       onBack = null,
       interactiveScrollbar = false,
       bottomActionPadding = null;

  final String title;
  final List<Widget>? children;
  final Widget? body;
  final AdaptiveAppBar? appBar;
  final ScrollController? controller;
  final double maxWidth;
  final Widget? bottomAction;
  final Color? backgroundColor;
  final ScrollPhysics? physics;
  final EdgeInsetsGeometry? contentPadding;
  final String? backLabel;
  final Key? backButtonKey;
  final VoidCallback? onBack;
  final bool interactiveScrollbar;
  final EdgeInsets? bottomActionPadding;

  @override
  State<UtilityPageScaffold> createState() => _UtilityPageScaffoldState();
}

class _UtilityPageScaffoldState extends State<UtilityPageScaffold> {
  ScrollController? _ownedController;

  ScrollController get _controller =>
      widget.controller ?? (_ownedController ??= ScrollController());

  @override
  void didUpdateWidget(covariant UtilityPageScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == null && widget.controller != null) {
      _ownedController?.dispose();
      _ownedController = null;
    }
  }

  @override
  void dispose() {
    _ownedController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final defaultPadding = EdgeInsets.fromLTRB(
      Spacing.pagePadding,
      Spacing.lg,
      Spacing.pagePadding,
      Spacing.pagePadding + mediaQuery.viewPadding.bottom,
    );
    final content = widget.body == null
        ? widget.children!
        : <Widget>[widget.body!];
    final list = ListView(
      controller: _controller,
      primary: false,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      physics:
          widget.physics ??
          const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
      padding: widget.contentPadding ?? defaultPadding,
      children: [
        for (final child in content)
          Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: widget.maxWidth),
              child: SizedBox(width: double.infinity, child: child),
            ),
          ),
      ],
    );
    final scrollable = context.usesCupertinoChrome
        ? CupertinoScrollbar(controller: _controller, child: list)
        : Scrollbar(
            controller: _controller,
            interactive: widget.interactiveScrollbar,
            child: list,
          );

    final backButton = widget.onBack == null
        ? null
        : AdaptiveTooltip(
            message: widget.backLabel!,
            child: Semantics(
              label: widget.backLabel,
              button: true,
              child: ConduitAdaptiveAppBarIconButton(
                key: widget.backButtonKey,
                icon: context.usesCupertinoChrome
                    ? CupertinoIcons.chevron_back
                    : Icons.arrow_back,
                onPressed: widget.onBack,
              ),
            ),
          );
    final leading = backButton == null
        ? null
        : context.usesCupertinoChrome
        ? backButton
        : Center(
            child: SizedBox.square(
              dimension: TouchTarget.minimum,
              child: backButton,
            ),
          );
    final appBar =
        widget.appBar ??
        AdaptiveAppBar(
          title: widget.title,
          tintColor: context.conduitTheme.textPrimary,
          leading: leading,
        );

    return AdaptiveRouteShell(
      backgroundColor:
          widget.backgroundColor ?? context.conduitTheme.surfaceBackground,
      appBar: appBar,
      body: PrimaryScrollController(
        controller: _controller,
        child: Column(
          children: [
            Expanded(child: scrollable),
            if (widget.bottomAction != null)
              SafeArea(
                top: false,
                minimum:
                    widget.bottomActionPadding ??
                    const EdgeInsets.fromLTRB(
                      Spacing.pagePadding,
                      Spacing.sm,
                      Spacing.pagePadding,
                      Spacing.sm,
                    ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: widget.maxWidth),
                    child: widget.bottomAction!,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Opaque inset-grouped surface with optional section guidance.
class InsetGroupedSection extends StatelessWidget {
  const InsetGroupedSection({
    super.key,
    required this.child,
    this.title,
    this.description,
    this.padding = const EdgeInsets.all(Spacing.md),
  });

  final String? title;
  final String? description;
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final hasTitle = title != null && title!.isNotEmpty;
    final hasDescription = description != null && description!.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hasTitle)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
            child: Text(
              title!,
              style: AppTypography.labelMediumStyle.copyWith(
                color: theme.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        if (hasDescription) ...[
          const SizedBox(height: Spacing.xs),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
            child: Text(
              description!,
              style: AppTypography.bodySmallStyle.copyWith(
                color: theme.textTertiary,
              ),
            ),
          ),
        ],
        if (hasTitle || hasDescription) const SizedBox(height: Spacing.sm),
        Container(
          clipBehavior: Clip.antiAlias,
          padding: padding,
          decoration: BoxDecoration(
            color: theme.surfaceContainer.withValues(alpha: 0.68),
            borderRadius: BorderRadius.circular(AppBorderRadius.card),
            border: Border.all(
              color: theme.cardBorder,
              width: BorderWidth.thin,
            ),
          ),
          child: Material(type: MaterialType.transparency, child: child),
        ),
      ],
    );
  }
}

/// A single grouped surface with quiet dividers between rows.
class InsetGroupedList extends StatelessWidget {
  const InsetGroupedList({
    super.key,
    required this.children,
    this.title,
    this.description,
    this.dividerIndent = Spacing.md,
  });

  final List<Widget> children;
  final String? title;
  final String? description;
  final double dividerIndent;

  @override
  Widget build(BuildContext context) {
    return InsetGroupedSection(
      title: title,
      description: description,
      padding: EdgeInsets.zero,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var index = 0; index < children.length; index++) ...[
            children[index],
            if (index != children.length - 1)
              Divider(
                height: BorderWidth.thin,
                thickness: BorderWidth.thin,
                indent: dividerIndent,
                endIndent: dividerIndent,
                color: context.conduitTheme.dividerColor,
              ),
          ],
        ],
      ),
    );
  }
}

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
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
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
                                        maxLines: widget.subtitleMaxLines,
                                        overflow: TextOverflow.ellipsis,
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
  final String subtitle;
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
      semanticLabel: '$title. $subtitle',
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
    this.showDivider = false,
  });

  final String label;
  final String value;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool monospace;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final row = UtilityRow(
      title: label,
      leading: leading,
      trailing: trailing,
      onTap: onTap,
      hapticType: onTap == null ? null : HapticType.selection,
      semanticLabel: '$label. $value',
      padding: const EdgeInsets.all(Spacing.md),
      // Selectable text is retained as a dedicated trailing value for rows
      // that expose connection identifiers and URLs.
      status: SelectableText(
        value,
        maxLines: 2,
        textAlign: TextAlign.end,
        style: AppTypography.bodySmallStyle.copyWith(
          color: theme.textSecondary,
          fontWeight: FontWeight.w600,
          fontFamily: monospace ? AppTypography.monospaceFontFamily : null,
        ),
      ),
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

class UtilityIdentityHeader extends StatelessWidget {
  const UtilityIdentityHeader({
    super.key,
    required this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final Widget leading;
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox.square(dimension: TouchTarget.comfortable, child: leading),
        const SizedBox(width: Spacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: AppTypography.titleLargeStyle.copyWith(
                  color: theme.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (subtitle != null && subtitle!.isNotEmpty) ...[
                const SizedBox(height: Spacing.xs),
                Text(
                  subtitle!,
                  style: AppTypography.bodySmallStyle.copyWith(
                    color: theme.textSecondary,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: Spacing.sm), trailing!],
      ],
    );
  }
}

class UtilityDisclosureSection extends StatelessWidget {
  const UtilityDisclosureSection({
    super.key,
    required this.title,
    required this.expanded,
    required this.onChanged,
    required this.child,
    this.subtitle,
    this.leading,
    this.contentPadding = const EdgeInsets.all(Spacing.md),
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final bool expanded;
  final ValueChanged<bool> onChanged;
  final Widget child;
  final EdgeInsetsGeometry contentPadding;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final duration = context.motionDuration(AnimationDuration.microInteraction);
    return InsetGroupedSection(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          UtilityRow(
            title: title,
            subtitle: subtitle,
            leading: leading,
            onTap: () => onChanged(!expanded),
            expanded: expanded,
            trailing: AnimatedRotation(
              turns: expanded ? 0.5 : 0,
              duration: duration,
              curve: Curves.easeOutCubic,
              child: Icon(
                context.usesCupertinoChrome
                    ? CupertinoIcons.chevron_down
                    : Icons.expand_more,
                color: theme.iconSecondary,
                size: IconSize.medium,
              ),
            ),
          ),
          if (context.reduceMotion)
            if (expanded) _content(theme) else const SizedBox.shrink()
          else
            ClipRect(
              child: AnimatedSize(
                duration: duration,
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: expanded ? _content(theme) : const SizedBox.shrink(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _content(ConduitThemeExtension theme) => Column(
    children: [
      Divider(
        height: BorderWidth.thin,
        thickness: BorderWidth.thin,
        color: theme.dividerColor,
      ),
      SizedBox(
        width: double.infinity,
        child: Padding(padding: contentPadding, child: child),
      ),
    ],
  );
}

enum UtilityStatusTone { neutral, info, success, warning, error }

class UtilityStatusBanner extends StatelessWidget {
  const UtilityStatusBanner({
    super.key,
    required this.message,
    this.tone = UtilityStatusTone.neutral,
    this.progress = false,
  });

  final String message;
  final UtilityStatusTone tone;
  final bool progress;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final color = switch (tone) {
      UtilityStatusTone.neutral => theme.textSecondary,
      UtilityStatusTone.info => theme.info,
      UtilityStatusTone.success => theme.success,
      UtilityStatusTone.warning => theme.warning,
      UtilityStatusTone.error => theme.error,
    };
    return Semantics(
      liveRegion: true,
      container: true,
      excludeSemantics: true,
      label: message,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.md,
          vertical: Spacing.sm,
        ),
        decoration: BoxDecoration(
          color: color.withValues(alpha: Alpha.subtle),
          borderRadius: BorderRadius.circular(AppBorderRadius.md),
        ),
        child: Row(
          children: [
            if (progress)
              SizedBox.square(
                dimension: IconSize.small,
                child: CircularProgressIndicator(strokeWidth: 2, color: color),
              )
            else
              Icon(
                switch (tone) {
                  UtilityStatusTone.success => Icons.check_circle_outline,
                  UtilityStatusTone.warning => Icons.warning_amber_rounded,
                  UtilityStatusTone.error => Icons.error_outline,
                  _ => Icons.info_outline,
                },
                size: IconSize.small,
                color: color,
              ),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Text(
                message,
                style: AppTypography.bodySmallStyle.copyWith(
                  color: theme.textPrimary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
