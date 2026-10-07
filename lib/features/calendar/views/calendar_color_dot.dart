import 'package:material_ui/material_ui.dart';

import '../../../shared/theme/theme_extensions.dart';

/// The small filled circle that marks a calendar's colour beside its events
/// and in its rows. A calendar without a colour gets the secondary text colour.
class CalendarColorDot extends StatelessWidget {
  const CalendarColorDot({super.key, required this.color});

  final Color? color;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: IconSize.xs,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color ?? context.conduitTheme.textSecondary,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}
