import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../theme/theme_extensions.dart';
import 'utility_grouped_surfaces.dart';
import 'utility_rows.dart';

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
