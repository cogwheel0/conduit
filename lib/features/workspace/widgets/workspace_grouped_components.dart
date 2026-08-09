import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/utility_components.dart';

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
    return InsetGroupedSection(
      title: title,
      description: description,
      padding: padding,
      child: child,
    );
  }
}

/// A grouped surface whose children are separated by quiet hairline dividers.
class WorkspaceGroupedList extends StatelessWidget {
  const WorkspaceGroupedList({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return InsetGroupedList(children: children);
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
    return UtilityIdentityHeader(
      leading: leading,
      title: title,
      subtitle: subtitle,
      trailing: trailing,
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
    final row = UtilityValueRow(label: label, value: value, onTap: onTap);
    if (!showDivider) return row;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: context.conduitTheme.dividerColor,
            width: BorderWidth.thin,
          ),
        ),
      ),
      child: row,
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
    return UtilityDisclosureSection(
      title: title,
      subtitle: subtitle,
      expanded: expanded,
      onChanged: onChanged,
      child: child,
    );
  }
}
