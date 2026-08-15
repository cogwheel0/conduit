import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/utility_components.dart';

/// Expandable card widget for collapsible settings sections.
class ExpandableCard extends StatefulWidget {
  const ExpandableCard({
    super.key,
    required this.title,
    required this.subtitle,
    this.subtitleWidget,
    required this.icon,
    required this.child,
  });

  final String title;
  final String subtitle;

  /// When set, shown instead of [subtitle] text (e.g. a compact progress row).
  final Widget? subtitleWidget;
  final IconData icon;
  final Widget child;

  @override
  State<ExpandableCard> createState() => ExpandableCardState();
}

class ExpandableCardState extends State<ExpandableCard> {
  bool _isExpanded = false;

  void _toggle() {
    setState(() => _isExpanded = !_isExpanded);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return UtilityDisclosureSection(
      title: widget.title,
      subtitle: widget.subtitle,
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: theme.buttonPrimary.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(AppBorderRadius.small),
        ),
        alignment: Alignment.center,
        child: Icon(
          widget.icon,
          color: theme.buttonPrimary,
          size: IconSize.medium,
        ),
      ),
      expanded: _isExpanded,
      onChanged: (_) => _toggle(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.subtitleWidget != null) ...[
            widget.subtitleWidget!,
            const SizedBox(height: Spacing.sm),
          ],
          widget.child,
        ],
      ),
    );
  }
}
