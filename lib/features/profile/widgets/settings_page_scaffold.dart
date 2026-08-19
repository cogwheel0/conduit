import 'package:material_ui/material_ui.dart';

import '../../../shared/theme/theme_extensions.dart';

const settingsSectionGap = SizedBox(height: Spacing.lg);

/// Standalone section header for sections that cannot pass their title to
/// [InsetGroupedSection] (e.g. a header paired with an action button). Renders
/// identically to that widget's `title`, including its horizontal inset, so
/// standalone headers and section titles line up on the same page.
class SettingsSectionHeader extends StatelessWidget {
  const SettingsSectionHeader({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final native = context.usesCupertinoChrome;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
      child: Text(
        title,
        style:
            (native
                    ? AppTypography.bodySmallStyle
                    : AppTypography.labelMediumStyle)
                .copyWith(
                  color: context.conduitTheme.textSecondary,
                  fontWeight: native ? FontWeight.w400 : FontWeight.w600,
                ),
      ),
    );
  }
}

class SettingsIconBadge extends StatelessWidget {
  const SettingsIconBadge({super.key, required this.icon, required this.color});

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
