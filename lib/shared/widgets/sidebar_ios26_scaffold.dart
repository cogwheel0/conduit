import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
// ignore: implementation_imports
import 'package:adaptive_platform_ui/src/widgets/ios26/ios26_native_toolbar.dart';
import 'package:flutter/cupertino.dart';

/// iOS 26 sidebar scaffold workaround for `adaptive_platform_ui`.
///
/// The sidebar owns tab body switching and keeps one body tree mounted. This
/// local scaffold also lets a fully closed mobile drawer omit the underlying
/// UIKit toolbar and tab-bar views without removing their Flutter geometry.
class SidebarIos26Scaffold extends StatelessWidget {
  const SidebarIos26Scaffold({
    super.key,
    this.bottomNavigationBar,
    required this.body,
    this.leading,
    this.actions,
    this.minimizeBehavior = TabBarMinimizeBehavior.never,
    this.showNativeView = true,
  });

  final AdaptiveBottomNavigationBar? bottomNavigationBar;
  final Widget body;
  final Widget? leading;
  final List<AdaptiveAppBarAction>? actions;
  final TabBarMinimizeBehavior minimizeBehavior;
  final bool showNativeView;

  @override
  Widget build(BuildContext context) {
    final route = ModalRoute.of(context);
    final routeAllowsNativeView =
        (route?.isCurrent ?? true) ||
        route?.animation?.status == AnimationStatus.reverse;
    final shouldShowNativeView = showNativeView && routeAllowsNativeView;
    final hasToolbarContent =
        leading != null || (actions != null && actions!.isNotEmpty);
    final hasBottomNavigation =
        bottomNavigationBar?.items != null &&
        bottomNavigationBar!.items!.isNotEmpty &&
        bottomNavigationBar!.selectedIndex != null &&
        bottomNavigationBar!.onTap != null;
    final brightness = MediaQuery.platformBrightnessOf(context);
    final textColor = brightness == Brightness.dark
        ? CupertinoColors.white
        : CupertinoColors.black;

    return CupertinoPageScaffold(
      resizeToAvoidBottomInset: !hasBottomNavigation,
      child: Stack(
        children: [
          DefaultTextStyle(
            style: TextStyle(color: textColor, fontSize: 17),
            child: body,
          ),
          if (hasToolbarContent)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: IOS26NativeToolbar(
                leading: leading,
                actions: actions,
                showNativeView: shouldShowNativeView,
                onActionTap: (index) {
                  final currentActions = actions;
                  if (currentActions != null &&
                      index >= 0 &&
                      index < currentActions.length) {
                    currentActions[index].onPressed();
                  }
                },
              ),
            ),
          if (hasBottomNavigation)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: IOS26NativeTabBar(
                destinations: bottomNavigationBar!.items!,
                selectedIndex: bottomNavigationBar!.selectedIndex!,
                onTap: bottomNavigationBar!.onTap!,
                tint: CupertinoTheme.of(context).primaryColor,
                minimizeBehavior: minimizeBehavior,
                showNativeView: shouldShowNativeView,
              ),
            ),
        ],
      ),
    );
  }
}
