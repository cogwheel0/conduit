import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/platform_service.dart';
import '../../core/services/settings_service.dart';
import '../theme/theme_extensions.dart';
import 'adaptive_route_shell.dart';
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
    this.appBar,
    this.controller,
    this.maxWidth = 640,
    this.bottomAction,
    this.backgroundColor,
    this.physics,
    this.contentPadding,
  });

  final String title;
  final List<Widget> children;
  final AdaptiveAppBar? appBar;
  final ScrollController? controller;
  final double maxWidth;
  final Widget? bottomAction;
  final Color? backgroundColor;
  final ScrollPhysics? physics;
  final EdgeInsetsGeometry? contentPadding;

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
    final list = ListView(
      controller: _controller,
      primary: false,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      physics:
          widget.physics ??
          const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
      padding: widget.contentPadding ?? defaultPadding,
      children: [
        for (final child in widget.children)
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
        : Scrollbar(controller: _controller, child: list);

    return AdaptiveRouteShell(
      backgroundColor:
          widget.backgroundColor ?? context.conduitTheme.surfaceBackground,
      appBar: widget.appBar ?? AdaptiveAppBar(title: widget.title),
      body: PrimaryScrollController(
        controller: _controller,
        child: Column(
          children: [
            Expanded(child: scrollable),
            if (widget.bottomAction != null)
              SafeArea(
                top: false,
                minimum: const EdgeInsets.fromLTRB(
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

@immutable
class UtilityRowPresentation {
  const UtilityRowPresentation({
    required this.title,
    this.subtitle,
    this.leading,
    this.status,
    this.selected = false,
    this.expanded,
    this.enabled = true,
    this.trailing,
    this.semanticLabel,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? status;
  final bool selected;
  final bool? expanded;
  final bool enabled;
  final Widget? trailing;
  final String? semanticLabel;
}

/// Shared utility row with full-row semantics and immediate press feedback.
class UtilityRow extends ConsumerStatefulWidget {
  const UtilityRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
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
  final Widget? leading;
  final Widget? trailing;
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
      excludeSemantics: true,
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
              constraints: const BoxConstraints(minHeight: TouchTarget.minimum),
              child: Padding(
                padding: widget.padding,
                child: Row(
                  children: [
                    if (widget.leading != null) ...[
                      widget.leading!,
                      const SizedBox(width: Spacing.md),
                    ],
                    Expanded(
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
                            Text(
                              widget.subtitle!,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: AppTypography.bodySmallStyle.copyWith(
                                color: theme.textSecondary,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (widget.status != null) ...[
                      const SizedBox(width: Spacing.sm),
                      widget.status!,
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
  });

  final String label;
  final String value;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return UtilityRow(
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
