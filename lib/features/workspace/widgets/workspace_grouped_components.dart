import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/theme_extensions.dart';

/// Calm, inset-grouped surface shared by Workspace collections and editors.
class WorkspaceGroupedSection extends StatelessWidget {
  const WorkspaceGroupedSection({
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null && title!.isNotEmpty)
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
        if (description != null && description!.isNotEmpty) ...[
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
        if (title != null || description != null)
          const SizedBox(height: Spacing.sm),
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

/// A grouped surface whose children are separated by quiet hairline dividers.
class WorkspaceGroupedList extends StatelessWidget {
  const WorkspaceGroupedList({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final divider = context.conduitTheme.dividerColor;
    return WorkspaceGroupedSection(
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
                indent: Spacing.md,
                endIndent: Spacing.md,
                color: divider,
              ),
          ],
        ],
      ),
    );
  }
}

class WorkspaceIdentityHeader extends StatelessWidget {
  const WorkspaceIdentityHeader({
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

enum WorkspaceStatusTone { neutral, success, warning, info }

class WorkspaceStatusPill extends StatelessWidget {
  const WorkspaceStatusPill({
    super.key,
    required this.label,
    this.tone = WorkspaceStatusTone.neutral,
  });

  final String label;
  final WorkspaceStatusTone tone;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final color = switch (tone) {
      WorkspaceStatusTone.neutral => theme.textSecondary,
      WorkspaceStatusTone.success => theme.success,
      WorkspaceStatusTone.warning => theme.warning,
      WorkspaceStatusTone.info => theme.info,
    };
    return Semantics(
      label: label,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.sm,
          vertical: Spacing.xxs,
        ),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(AppBorderRadius.pill),
        ),
        child: Text(
          label,
          maxLines: 1,
          style: AppTypography.captionStyle.copyWith(
            color: color,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class WorkspaceValueRow extends StatelessWidget {
  const WorkspaceValueRow({
    super.key,
    required this.label,
    required this.value,
    this.onTap,
    this.showDivider = false,
  });

  final String label;
  final String value;
  final VoidCallback? onTap;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: TouchTarget.minimum),
        padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
        decoration: showDivider
            ? BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: theme.dividerColor,
                    width: BorderWidth.thin,
                  ),
                ),
              )
            : null,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 2,
              child: Text(
                label,
                style: AppTypography.bodyMediumStyle.copyWith(
                  color: theme.textPrimary,
                ),
              ),
            ),
            const SizedBox(width: Spacing.md),
            Expanded(
              flex: 3,
              child: SelectableText(
                value,
                textAlign: TextAlign.end,
                style: AppTypography.bodyMediumStyle.copyWith(
                  color: theme.textSecondary,
                ),
              ),
            ),
            if (onTap != null) ...[
              const SizedBox(width: Spacing.sm),
              Icon(
                context.usesCupertinoChrome
                    ? CupertinoIcons.chevron_right
                    : Icons.chevron_right,
                size: IconSize.small,
                color: theme.iconSecondary,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class WorkspaceDisclosureSection extends StatelessWidget {
  const WorkspaceDisclosureSection({
    super.key,
    required this.title,
    required this.expanded,
    required this.onChanged,
    required this.child,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final bool expanded;
  final ValueChanged<bool> onChanged;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final duration = context.motionDuration(AnimationDuration.fast);
    return WorkspaceGroupedSection(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          Semantics(
            button: true,
            expanded: expanded,
            child: InkWell(
              onTap: () => onChanged(!expanded),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: TouchTarget.comfortable,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(Spacing.md),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: AppTypography.bodyMediumStyle.copyWith(
                                color: theme.textPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (subtitle != null && subtitle!.isNotEmpty) ...[
                              const SizedBox(height: Spacing.xxs),
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
                      AnimatedRotation(
                        turns: expanded ? 0.5 : 0,
                        duration: duration,
                        curve: Curves.easeOutCubic,
                        child: Icon(
                          context.usesCupertinoChrome
                              ? CupertinoIcons.chevron_down
                              : Icons.expand_more,
                          size: IconSize.medium,
                          color: theme.iconSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          ClipRect(
            child: AnimatedSize(
              duration: duration,
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: expanded
                  ? Column(
                      children: [
                        Divider(
                          height: BorderWidth.thin,
                          thickness: BorderWidth.thin,
                          color: theme.dividerColor,
                        ),
                        Padding(
                          padding: const EdgeInsets.all(Spacing.md),
                          child: child,
                        ),
                      ],
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ],
      ),
    );
  }
}
