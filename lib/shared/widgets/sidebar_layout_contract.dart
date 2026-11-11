import 'package:material_ui/material_ui.dart';

import '../theme/theme_extensions.dart';
import 'adaptive_toolbar_components.dart' show kConduitCupertinoToolbarHeight;
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
bool usesPersistentTabletSidebar(BuildContext context) {
  final size = MediaQuery.maybeSizeOf(context);
  return size != null &&
      usesPersistentTabletSidebarFor(width: size.width, height: size.height);
}

/// Whether the sidebar is fully open over the main pane, as on a phone,
/// rather than docked beside it. Status bar taps then belong to the sidebar.
bool sidebarCoversMainPane(BuildContext context) {
  if (usesPersistentTabletSidebar(context)) return false;
  return context
          .getInheritedWidgetOfExactType<SidebarDrawerControllerScope>()
          ?.controller
          .isOpen ??
      false;
}

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
    this.floatingChromeInsets,
    required super.child,
  });

  final bool parentOwnsHeaderInset;
  final bool bottomNavigationVisible;

  /// Extents of a header and bottom bar that float over the content on every
  /// platform. When set, content scrolls beneath them instead of beginning
  /// below platform-specific chrome.
  final EdgeInsets? floatingChromeInsets;

  static SidebarTabLayoutScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SidebarTabLayoutScope>();

  @override
  bool updateShouldNotify(SidebarTabLayoutScope oldWidget) =>
      parentOwnsHeaderInset != oldWidget.parentOwnsHeaderInset ||
      bottomNavigationVisible != oldWidget.bottomNavigationVisible ||
      floatingChromeInsets != oldWidget.floatingChromeInsets;
}

/// The scrollbar [builder] puts around sidebar tab content, with its track
/// between a header and bottom bar that float over the content instead of
/// beneath them.
///
/// Scrollbars inset their track by the media padding, so the scrollbar is
/// given the floating chrome's extents as its padding, and [child] keeps the
/// padding around this widget.
class SidebarTabScrollbar extends StatelessWidget {
  const SidebarTabScrollbar({
    super.key,
    required this.builder,
    required this.child,
  });

  /// Builds the scrollbar around the given scrollable.
  final Widget Function(Widget child) builder;

  /// The scrollable content.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final insets = SidebarTabLayoutScope.maybeOf(context)?.floatingChromeInsets;
    if (insets == null) return builder(child);
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(
        padding: media.padding.copyWith(top: insets.top, bottom: insets.bottom),
      ),
      child: builder(MediaQuery(data: media, child: child)),
    );
  }
}

/// Rows that scroll at the top of a sidebar history list, above its first
/// section.
class SidebarHistoryHeaderScope extends InheritedWidget {
  const SidebarHistoryHeaderScope({
    super.key,
    required this.header,
    required super.child,
  });

  final Widget header;

  static Widget? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<SidebarHistoryHeaderScope>()
      ?.header;

  @override
  bool updateShouldNotify(SidebarHistoryHeaderScope oldWidget) =>
      header != oldWidget.header;
}

/// The [SidebarHistoryHeaderScope] rows as slivers, or none.
List<Widget> sidebarHistoryHeaderSlivers(BuildContext context) => [
  if (SidebarHistoryHeaderScope.maybeOf(context) case final header?)
    SliverToBoxAdapter(child: header),
];

/// Keeps the [SidebarHistoryHeaderScope] rows above a loading, empty, or
/// error [state] that a history list shows in place of its scroll view.
Widget sidebarHistoryStateBelowHeader(BuildContext context, Widget state) {
  final header = SidebarHistoryHeaderScope.maybeOf(context);
  if (header == null) return state;
  return CustomScrollView(
    slivers: [
      SliverToBoxAdapter(
        child: SizedBox(height: sidebarTabContentTopPadding(context)),
      ),
      SliverToBoxAdapter(child: header),
      // Fills the rest of the viewport without scrolling further. The
      // sliver sizes itself from its child's intrinsic height, which a
      // positioned child does not report, so [state] may hold scroll views
      // and layout builders; the spacer keeps it visible below a tall
      // header.
      SliverFillRemaining(
        hasScrollBody: false,
        child: Stack(
          children: [
            const SizedBox(height: _kSidebarHistoryStateMinHeight),
            Positioned.fill(
              child: Padding(
                padding: EdgeInsets.only(
                  bottom: sidebarTabContentBottomPadding(context),
                ),
                child: state,
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

const double _kSidebarHistoryStateMinHeight = 160;

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
  if (layout?.floatingChromeInsets case final insets?) {
    return insets.top + Spacing.sm;
  }
  if (layout?.parentOwnsHeaderInset ?? false) return Spacing.sm;
  if (!_usesNativeSidebarChrome(context)) return Spacing.sm;
  return MediaQuery.viewPaddingOf(context).top +
      kConduitCupertinoToolbarHeight +
      Spacing.sm;
}

/// Edge offset so pull-to-refresh indicators appear below sidebar chrome.
double sidebarRefreshIndicatorEdgeOffset(BuildContext context) {
  final layout = SidebarTabLayoutScope.maybeOf(context);
  if (layout?.floatingChromeInsets case final insets?) return insets.top;
  if (layout?.parentOwnsHeaderInset ?? false) return 0.0;
  if (!_usesNativeSidebarChrome(context)) return 0.0;
  return MediaQuery.viewPaddingOf(context).top + kConduitCupertinoToolbarHeight;
}

/// Bottom inset so sidebar tab content clears native sidebar chrome.
double sidebarTabContentBottomPadding(
  BuildContext context, {
  bool includeNativeBottomBar = true,
}) {
  final layout = SidebarTabLayoutScope.maybeOf(context);
  if (layout?.floatingChromeInsets case final insets?) {
    return insets.bottom + Spacing.md;
  }
  if (!_usesNativeSidebarChrome(context)) return Spacing.md;

  final bottomPadding = MediaQuery.viewPaddingOf(context).bottom;
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
