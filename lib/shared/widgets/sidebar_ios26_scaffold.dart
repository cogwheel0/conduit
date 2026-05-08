import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
// ignore: implementation_imports
import 'package:adaptive_platform_ui/src/widgets/ios26/ios26_scaffold.dart';
import 'package:flutter/widgets.dart';

/// iOS 26 sidebar scaffold workaround for `adaptive_platform_ui`.
///
/// `AdaptiveScaffold` currently turns a single tab body into one child per
/// bottom-tab item before handing off to `IOS26Scaffold`. The sidebar already
/// owns tab body switching through `_SidebarTabStack`, so that extra
/// `IndexedStack` layer can switch between duplicate sidebar body trees and
/// reset tab-local state.
///
/// Until the package exposes a public single-body tab scaffold path, the
/// sidebar uses the lower-level iOS 26 scaffold directly while keeping the same
/// native toolbar and bottom-tab configuration.
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
