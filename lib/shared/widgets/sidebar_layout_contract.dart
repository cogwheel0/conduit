import 'package:flutter/material.dart';

import '../theme/theme_extensions.dart';
import 'sidebar_layout_constants.dart';

/// Commands exposed by the active sidebar drawer without leaking its concrete
/// navigation implementation into feature code.
abstract interface class SidebarDrawerController {
  bool get isOpen;

  void open({double velocity = 0.0});

  void close({double velocity = 0.0});

  void toggle();
}

/// Publishes the active drawer command surface to descendant features.
class SidebarDrawerControllerScope extends InheritedWidget {
  const SidebarDrawerControllerScope({
    super.key,
    required this.controller,
    required super.child,
  });

  final SidebarDrawerController controller;

  static SidebarDrawerController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<SidebarDrawerControllerScope>()
      ?.controller;

  @override
  bool updateShouldNotify(SidebarDrawerControllerScope oldWidget) =>
      !identical(controller, oldWidget.controller);
}

/// Shared breakpoint for the persistent tablet sidebar presentation.
bool usesPersistentTabletSidebar(BuildContext context) =>
    (MediaQuery.maybeSizeOf(context)?.shortestSide ?? 0) >= 600;

/// Closes the sidebar only when it is presented as a mobile overlay.
void closeSidebarDrawerIfOverlay(BuildContext context) {
  if (usesPersistentTabletSidebar(context)) return;
  SidebarDrawerControllerScope.maybeOf(context)?.close();
}

/// Describes which surrounding chrome has already been reserved for sidebar
/// tab content.
class SidebarTabLayoutScope extends InheritedWidget {
  const SidebarTabLayoutScope({
    super.key,
    required this.parentOwnsHeaderInset,
    required this.bottomNavigationVisible,
    required super.child,
  });

  final bool parentOwnsHeaderInset;
  final bool bottomNavigationVisible;

  static SidebarTabLayoutScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SidebarTabLayoutScope>();

  @override
  bool updateShouldNotify(SidebarTabLayoutScope oldWidget) =>
      parentOwnsHeaderInset != oldWidget.parentOwnsHeaderInset ||
      bottomNavigationVisible != oldWidget.bottomNavigationVisible;
}

/// Marks sidebar content mounted in the persistent tablet pane.
class PersistentTabletSidebarScope extends InheritedWidget {
  const PersistentTabletSidebarScope({
    super.key,
    required this.active,
    required super.child,
  });

  final bool active;

  static bool isActive(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<PersistentTabletSidebarScope>()
          ?.active ??
      false;

  @override
  bool updateShouldNotify(PersistentTabletSidebarScope oldWidget) =>
      active != oldWidget.active;
}

/// Controls whether native sidebar chrome is composed by the current drawer.
class DrawerChromeCompositionScope extends InheritedWidget {
  const DrawerChromeCompositionScope({
    super.key,
    required this.composeNativeChrome,
    required super.child,
  });

  final bool composeNativeChrome;

  static bool shouldCompose(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<DrawerChromeCompositionScope>()
          ?.composeNativeChrome ??
      true;

  @override
  bool updateShouldNotify(DrawerChromeCompositionScope oldWidget) =>
      composeNativeChrome != oldWidget.composeNativeChrome;
}

bool _usesNativeSidebarChrome(BuildContext context) =>
    Theme.of(context).platform == TargetPlatform.iOS;

/// Top inset so sidebar tab content starts below native sidebar chrome.
double sidebarTabContentTopPadding(BuildContext context) {
  final layout = SidebarTabLayoutScope.maybeOf(context);
  if (layout?.parentOwnsHeaderInset ?? false) return Spacing.sm;
  if (!_usesNativeSidebarChrome(context)) return Spacing.sm;
  return MediaQuery.viewPaddingOf(context).top + kTextTabBarHeight + Spacing.sm;
}

/// Edge offset so pull-to-refresh indicators appear below sidebar chrome.
double sidebarRefreshIndicatorEdgeOffset(BuildContext context) {
  final layout = SidebarTabLayoutScope.maybeOf(context);
  if (layout?.parentOwnsHeaderInset ?? false) return 0.0;
  if (!_usesNativeSidebarChrome(context)) return 0.0;
  return MediaQuery.viewPaddingOf(context).top + kTextTabBarHeight;
}

/// Bottom inset so sidebar tab content clears native sidebar chrome.
double sidebarTabContentBottomPadding(
  BuildContext context, {
  bool includeNativeBottomBar = true,
}) {
  if (!_usesNativeSidebarChrome(context)) return Spacing.md;

  final bottomPadding = MediaQuery.viewPaddingOf(context).bottom;
  final layout = SidebarTabLayoutScope.maybeOf(context);
  final bottomNavigationVisible =
      layout?.bottomNavigationVisible ?? includeNativeBottomBar;
  final navigationBarHeight = includeNativeBottomBar && bottomNavigationVisible
      ? sidebarNativeBottomBarContentHeight
      : 0.0;
  return bottomPadding + navigationBarHeight + Spacing.md;
}

/// Height excluded from drawer drag gestures above the native sidebar tab bar.
double sidebarBottomBarGestureExclusionHeight(BuildContext context) {
  if (!_usesNativeSidebarChrome(context)) return 0.0;
  return sidebarTabContentBottomPadding(context);
}
