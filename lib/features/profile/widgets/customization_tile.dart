import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/conduit_components.dart';
import 'profile_text_styles.dart';

/// A tile widget used in customization settings pages, showing a leading
/// icon, title, subtitle, and optional trailing widget or chevron.
class CustomizationTile extends StatelessWidget {
  const CustomizationTile({
    super.key,
    required this.leading,
    required this.title,
    required this.subtitle,
    this.subtitleTrailing,
    this.trailing,
    this.onTap,
    this.showChevron = true,
  });

  final Widget leading;
  final String title;
  final String subtitle;

  /// Optional widget shown inline after the subtitle (e.g. compact loader).
  final Widget? subtitleTrailing;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    return ConduitCard(
      padding: const EdgeInsets.all(Spacing.md),
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          leading,
          const SizedBox(width: Spacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: profileTitleTextStyle(context),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: Spacing.xs),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Text(
                        subtitle,
                        style: profileSubtitleTextStyle(context),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (subtitleTrailing != null) ...[
                      const SizedBox(width: Spacing.sm),
                      subtitleTrailing!,
                    ],
                  ],
                ),
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: Spacing.sm),
            trailing!,
          ] else if (showChevron && onTap != null) ...[
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
