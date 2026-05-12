import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/conduit_components.dart';
import 'profile_text_styles.dart';

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

class ExpandableCardState extends State<ExpandableCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _rotationAnimation;
  bool _isExpanded = false;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _rotationAnimation = Tween<double>(begin: 0, end: 0.5).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() {
      _isExpanded = !_isExpanded;
    });
    if (_isExpanded) {
      _animationController.forward();
    } else {
      _animationController.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    return ConduitCard(
      padding: EdgeInsets.zero,
      onTap: _toggle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(Spacing.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: theme.buttonPrimary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(AppBorderRadius.small),
                    border: Border.all(
                      color: theme.buttonPrimary.withValues(alpha: 0.2),
                      width: BorderWidth.thin,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    widget.icon,
                    color: theme.buttonPrimary,
                    size: IconSize.medium,
                  ),
                ),
                const SizedBox(width: Spacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        style: profileTitleTextStyle(context),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: Spacing.xs),
                      widget.subtitleWidget ??
                          Text(
                            widget.subtitle,
                            style: profileSubtitleTextStyle(context),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                    ],
                  ),
                ),
                const SizedBox(width: Spacing.sm),
                RotationTransition(
                  turns: _rotationAnimation,
                  child: Icon(
                    UiUtils.platformIcon(
                      ios: CupertinoIcons.chevron_down,
                      android: Icons.expand_more,
                    ),
                    color: theme.iconSecondary,
                    size: IconSize.small,
                  ),
                ),
              ],
            ),
          ),
          if (_isExpanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(Spacing.md),
              child: widget.child,
            ),
          ],
        ],
      ),
    );
  }
}
