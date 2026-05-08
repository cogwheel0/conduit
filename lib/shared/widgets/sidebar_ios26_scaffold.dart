import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
// ignore: implementation_imports
import 'package:adaptive_platform_ui/src/widgets/ios26/ios26_scaffold.dart';
import 'package:flutter/widgets.dart';

/// iOS 26 sidebar scaffold workaround for `adaptive_platform_ui`.
///
/// `AdaptiveScaffold` currently rebuilds its internal `IOS26Scaffold` when the
/// active bottom-navigation index changes. For the sidebar this remounts the
/// entire tab body subtree, which resets scroll position and local widget state
/// on every tab switch.
///
/// Until the package exposes a stable public fix, the sidebar uses the lower-
/// level `IOS26Scaffold` directly while keeping the same adaptive bottom bar
/// configuration, leading content, and toolbar actions.
class SidebarIos26Scaffold extends StatelessWidget {
  const SidebarIos26Scaffold({
    super.key,
    required this.bottomNavigationBar,
    required this.body,
    this.leading,
    this.actions,
    this.minimizeBehavior = TabBarMinimizeBehavior.never,
  });

  final AdaptiveBottomNavigationBar bottomNavigationBar;
  final Widget body;
  final Widget? leading;
  final List<AdaptiveAppBarAction>? actions;
  final TabBarMinimizeBehavior minimizeBehavior;

  @override
  Widget build(BuildContext context) {
    return IOS26Scaffold(
      bottomNavigationBar: bottomNavigationBar,
      leading: leading,
      actions: actions,
      minimizeBehavior: minimizeBehavior,
      children: [body],
    );
  }
}
