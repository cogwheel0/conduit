import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/widgets.dart';

/// Shared adaptive page shell for routes that only need common scaffold
/// configuration.
///
/// Pages with custom drawer behavior, native tab bars, or route-specific
/// overlays should continue using `AdaptiveScaffold` directly.
class AdaptiveRouteShell extends StatelessWidget {
  /// Creates a route shell with shared adaptive scaffold defaults.
  const AdaptiveRouteShell({
    super.key,
    this.appBar,
    required this.body,
    this.backgroundColor,
    this.extendBodyBehindAppBar = false,
    this.floatingActionButton,
    this.bodySafeArea = false,
    this.safeAreaTop = true,
    this.safeAreaBottom = true,
    this.safeAreaLeft = true,
    this.safeAreaRight = true,
  });

  /// App bar configuration for the route.
  final AdaptiveAppBar? appBar;

  /// Body content shown inside the scaffold.
  final Widget body;

  /// Optional solid background for the route body.
  final Color? backgroundColor;

  /// Whether the body should extend behind the app bar.
  final bool extendBodyBehindAppBar;

  /// Optional floating action button.
  final Widget? floatingActionButton;

  /// Whether to wrap the body with a `SafeArea`.
  final bool bodySafeArea;

  /// Whether to apply top safe-area padding when [bodySafeArea] is true.
  final bool safeAreaTop;

  /// Whether to apply bottom safe-area padding when [bodySafeArea] is true.
  final bool safeAreaBottom;

  /// Whether to apply left safe-area padding when [bodySafeArea] is true.
  final bool safeAreaLeft;

  /// Whether to apply right safe-area padding when [bodySafeArea] is true.
  final bool safeAreaRight;

  @override
  Widget build(BuildContext context) {
    Widget content = body;

    if (bodySafeArea) {
      content = SafeArea(
        top: safeAreaTop,
        bottom: safeAreaBottom,
        left: safeAreaLeft,
        right: safeAreaRight,
        child: content,
      );
    }

    if (backgroundColor case final color?) {
      content = ColoredBox(color: color, child: content);
    }

    return AdaptiveScaffold(
      appBar: appBar,
      body: content,
      extendBodyBehindAppBar: extendBodyBehindAppBar,
      floatingActionButton: floatingActionButton,
    );
  }
}
