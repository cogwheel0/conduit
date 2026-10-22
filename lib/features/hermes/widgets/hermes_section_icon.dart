import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../shared/theme/theme_extensions.dart';

/// Matches Hermes desktop's section and subsection Tabler outline icons.
/// The surrounding row supplies the accessible label.
class HermesSectionIcon extends StatelessWidget {
  const HermesSectionIcon(this.section, {super.key});
  final String section;
  @override
  Widget build(BuildContext context) => SvgPicture.asset(
    'assets/icons/hermes-section-${hermesSectionIconName(section)}.svg',
    width: 24,
    height: 24,
    excludeFromSemantics: true,
    colorFilter: ColorFilter.mode(
      context.conduitTheme.textPrimary,
      BlendMode.srcIn,
    ),
  );
}

String hermesSectionIconName(String section) => switch (section) {
  'Models' => 'box',
  'Chat' => 'message-circle',
  'Memory' => 'brain',
  'Context' => 'file-text',
  'Safety' => 'lock',
  'Browser' => 'globe',
  'Workspace' || 'Connection' => 'device-desktop',
  'Execution' || 'Tools' => 'tool',
  'Delegation' => 'users',
  'Speech output' => 'volume-2',
  'Speech input' => 'microphone',
  _ => 'tool',
};
