import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/material.dart';

import '../theme/theme_extensions.dart';

const double _kSidebarNativeBottomBarContentHeight = 50.0;

/// Describes whether the sidebar scaffold overlays its toolbar and tab bar.
///
/// Sidebar tab content uses this inherited layout signal to decide how much
/// manual inset it needs beyond the scaffold-managed chrome.
class SidebarTabScaffoldLayout extends InheritedWidget {
  const SidebarTabScaffoldLayout({
    super.key,
    required this.usesToolbarOverlay,
    required this.usesBottomBarOverlay,
    required super.child,
  });

  /// Whether the top toolbar is visually overlaid on the tab content.
  final bool usesToolbarOverlay;

  /// Whether the bottom tab bar is visually overlaid on the tab content.
  final bool usesBottomBarOverlay;

  static SidebarTabScaffoldLayout? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<SidebarTabScaffoldLayout>();
  }

  @override
  bool updateShouldNotify(covariant SidebarTabScaffoldLayout oldWidget) {
    return usesToolbarOverlay != oldWidget.usesToolbarOverlay ||
        usesBottomBarOverlay != oldWidget.usesBottomBarOverlay;
  }
}

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

/// Top inset so sidebar tab content starts below the native iOS 26 toolbar.
double sidebarTabContentTopPadding(BuildContext context) {
  final layout = SidebarTabScaffoldLayout.maybeOf(context);
  final usesToolbarOverlay =
      layout?.usesToolbarOverlay ?? PlatformInfo.isIOS26OrHigher();
  if (!usesToolbarOverlay) {
    return Spacing.sm;
  }

  return MediaQuery.viewPaddingOf(context).top + kTextTabBarHeight + Spacing.sm;
}

/// Bottom inset so sidebar tab content clears the native iOS 26 tab bar.
double sidebarTabContentBottomPadding(BuildContext context) {
  final layout = SidebarTabScaffoldLayout.maybeOf(context);
  final usesBottomBarOverlay =
      layout?.usesBottomBarOverlay ?? PlatformInfo.isIOS26OrHigher();
  if (!usesBottomBarOverlay) {
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
