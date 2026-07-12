import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:conduit/features/profile/widgets/profile_text_styles.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/utils/ui_utils.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';

/// 40x40 tinted icon badge matching the settings/profile icon-badge pattern
/// (see `SettingsIconBadge`): 10% fill, 20% hairline border, medium icon.
class WorkspaceIconBadge extends StatelessWidget {
  const WorkspaceIconBadge({
    super.key,
    required this.icon,
    required this.color,
  });

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppBorderRadius.small),
        border: Border.all(
          color: color.withValues(alpha: 0.2),
          width: BorderWidth.thin,
        ),
      ),
      alignment: Alignment.center,
      child: Icon(icon, color: color, size: IconSize.medium),
    );
  }
}

/// ConduitCard-based list tile matching the profile/settings tile anatomy:
/// Spacing.md padding, 40x40 leading icon badge, single-line title, optional
/// two-line subtitle, optional trailing widget, and a platform chevron when
/// tappable. Used for workspace collection rows, relationship rows, access
/// rows, file rows, and history entries so the whole feature reads as one
/// system with the rest of the app.
class WorkspaceResourceTile extends StatelessWidget {
  const WorkspaceResourceTile({
    super.key,
    this.icon,
    this.iconColor,
    this.leading,
    required this.title,
    this.subtitle,
    this.titleTrailing,
    this.trailing,
    this.onTap,
    this.selected = false,
    this.showChevron = true,
  });

  /// Icon rendered inside a [WorkspaceIconBadge]; ignored when [leading] is
  /// provided.
  final IconData? icon;

  /// Badge tint; defaults to the theme's primary button color.
  final Color? iconColor;

  /// Fully custom leading widget (overrides [icon]).
  final Widget? leading;

  final String title;
  final String? subtitle;

  /// Optional inline widget after the title (e.g. a status badge).
  final Widget? titleTrailing;

  /// Optional trailing widget rendered before the chevron.
  final Widget? trailing;

  final VoidCallback? onTap;
  final bool selected;
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final badgeColor = iconColor ?? theme.buttonPrimary;
    final resolvedLeading =
        leading ??
        (icon == null
            ? null
            : WorkspaceIconBadge(icon: icon!, color: badgeColor));
    final hasSubtitle = subtitle != null && subtitle!.isNotEmpty;

    return ConduitCard(
      padding: const EdgeInsets.all(Spacing.md),
      onTap: onTap,
      isSelected: selected,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (resolvedLeading != null) ...[
            resolvedLeading,
            const SizedBox(width: Spacing.md),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        style: profileTitleTextStyle(context),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (titleTrailing != null) ...[
                      const SizedBox(width: Spacing.sm),
                      titleTrailing!,
                    ],
                  ],
                ),
                if (hasSubtitle) ...[
                  const SizedBox(height: Spacing.xs),
                  Text(
                    subtitle!,
                    style: profileSubtitleTextStyle(context),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: Spacing.sm),
            trailing!,
          ],
          if (showChevron && onTap != null) ...[
            const SizedBox(width: Spacing.sm),
            Icon(
              UiUtils.platformIcon(
                ios: CupertinoIcons.chevron_right,
                android: Icons.chevron_right,
              ),
              color: theme.iconSecondary,
              size: IconSize.small,
            ),
          ],
        ],
      ),
    );
  }
}

/// Section header matching the settings rhythm: `headingSmall` title, optional
/// `bodySmall` secondary description (Spacing.xs below), and Spacing.sm before
/// the section content. Callers add Spacing.xl between sections.
class WorkspaceSectionHeader extends StatelessWidget {
  const WorkspaceSectionHeader({
    super.key,
    required this.title,
    this.description,
  });

  final String title;
  final String? description;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.headingSmall),
          if (description != null && description!.isNotEmpty) ...[
            const SizedBox(height: Spacing.xs),
            Text(
              description!,
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            ),
          ],
        ],
      ),
    );
  }
}
