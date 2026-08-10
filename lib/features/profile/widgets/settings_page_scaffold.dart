import 'package:flutter/material.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/utility_components.dart';

const settingsSectionGap = SizedBox(height: Spacing.lg);

class SettingsPageScaffold extends StatelessWidget {
  const SettingsPageScaffold({
    super.key,
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return UtilityPageScaffold(title: title, children: children);
  }
}

class SettingsSectionHeader extends StatelessWidget {
  const SettingsSectionHeader({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: context.conduitTheme.headingSmall?.copyWith(
        color: context.conduitTheme.sidebarForeground,
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
