import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/material.dart';

import '../theme/theme_extensions.dart';

const double _kSidebarNativeBottomBarContentHeight = 50.0;

/// Circular filled primary action for sidebar tab stacks and matching routes.
///
/// Uses [AdaptiveButtonStyle.filled] so appearance adapts per platform.
class SidebarPrimaryCircleButton extends StatelessWidget {
  const SidebarPrimaryCircleButton({
    super.key,
    required this.onPressed,
    required this.icon,
    required this.tooltip,
  });

  final VoidCallback onPressed;
  final IconData icon;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    // [TouchTarget.minimum] — smallest compliant tap target for this control.
    const diameter = TouchTarget.minimum;

    return Tooltip(
      message: tooltip,
      child: AdaptiveButton.child(
        onPressed: onPressed,
        color: theme.buttonPrimary,
        style: AdaptiveButtonStyle.filled,
        size: AdaptiveButtonSize.medium,
        minSize: const Size.square(diameter),
        padding: EdgeInsets.zero,
        borderRadius: BorderRadius.circular(diameter / 2),
        useSmoothRectangleBorder: false,
        child: Icon(icon, color: theme.buttonPrimaryText, size: IconSize.lg),
      ),
    );
  }
}

/// Bottom inset so sidebar tab content clears the native iOS 26 tab bar.
double sidebarTabContentBottomPadding(BuildContext context) {
  if (!PlatformInfo.isIOS26OrHigher()) {
    return Spacing.md;
  }

  final bottomPadding = MediaQuery.viewPaddingOf(context).bottom;
  return bottomPadding + _kSidebarNativeBottomBarContentHeight + Spacing.md;
}

/// Height excluded from drawer drag gestures above the native sidebar tab bar.
double sidebarBottomBarGestureExclusionHeight(BuildContext context) {
  if (!PlatformInfo.isIOS26OrHigher()) {
    return 0.0;
  }

  return sidebarTabContentBottomPadding(context);
}

/// Bottom inset so scrollable content clears [SidebarPrimaryCircleButton].
double sidebarPrimaryCircleButtonScrollPadding(BuildContext context) {
  final bottomPadding = MediaQuery.viewPaddingOf(context).bottom;
  return bottomPadding + Spacing.md + TouchTarget.minimum + Spacing.md;
}
