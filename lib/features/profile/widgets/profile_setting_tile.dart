import 'package:flutter/widgets.dart';

import 'customization_tile.dart';

/// A setting tile widget used in the profile page, showing a leading
/// icon, title, subtitle, and optional trailing widget or chevron.
class ProfileSettingTile extends StatelessWidget {
  const ProfileSettingTile({
    super.key,
    required this.leading,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.trailing,
    this.showChevron = true,
  });

  final Widget leading;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    return CustomizationTile(
      leading: leading,
      title: title,
      subtitle: subtitle,
      trailing: trailing,
      onTap: onTap,
      showChevron: showChevron,
    );
  }
}
