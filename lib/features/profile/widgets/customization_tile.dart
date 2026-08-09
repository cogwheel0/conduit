import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../shared/widgets/utility_components.dart';

/// A tile widget used in customization settings pages, showing a leading
/// icon, title, subtitle, and optional trailing widget or chevron.
class CustomizationTile extends StatelessWidget {
  const CustomizationTile({
    super.key,
    this.leading,
    required this.title,
    required this.subtitle,
    this.subtitleTrailing,
    this.trailing,
    this.onTap,
    this.showChevron = true,
    this.subtitleMaxLines = 2,
  });

  final Widget? leading;
  final String title;
  final String subtitle;

  /// Optional widget shown inline after the subtitle (e.g. compact loader).
  final Widget? subtitleTrailing;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool showChevron;
  final int subtitleMaxLines;

  @override
  Widget build(BuildContext context) {
    return InsetGroupedSection(
      padding: EdgeInsets.zero,
      child: UtilityRow(
        title: title,
        subtitle: subtitle,
        leading: leading,
        trailing: trailing ?? subtitleTrailing,
        onTap: onTap,
        showChevron: showChevron,
      ),
    );
  }
}
