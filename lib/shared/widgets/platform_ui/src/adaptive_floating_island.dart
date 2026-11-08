import 'dart:async';

import 'package:cupertino_native_better/cupertino_native_better.dart';
import 'package:flutter/widgets.dart';

import '../../../theme/theme_extensions.dart' show ConduitMotionContext;

/// Room above the expanded glass in the native view.
///
/// The package's SwiftUI view puts the glass at the bottom of the view under
/// a `Spacer`, which keeps a minimum length of its own. In a view only as
/// tall as the glass, that length pushes the glass below the view and off
/// its content.
const double _nativeHeadroom = 16;

/// A floating island that morphs between a compact pill and an expanded
/// panel, anchored at its bottom edge so that it grows upwards.
///
/// On iOS 26 and later the island is native Liquid Glass with this widget's
/// Flutter content drawn above it; elsewhere the package draws it in Flutter.
/// Callers that keep their own design below iOS 26 check
/// `PlatformUiCapabilities.usesNativeIOS26` first.
///
/// The native glass reads its sizes once, when its view is created
/// (https://github.com/gunumdogdu/cupertino_native_better/issues/128), so the
/// island has one fixed size per state, and [collapsedSize] fits within
/// [expandedSize]. The content is laid out in that size less
/// [collapsedPadding] or [expandedPadding], which keeps it on the glass. A
/// new size creates a new native view, so derive the sizes from the
/// available width and the text size, not from content that changes while
/// the island is shown.
///
/// A change of [isExpanded] morphs the glass with a spring, or at once under
/// Reduce Motion, and crossfades the content. Taps on the glass outside the
/// content go to [onTap] and never reach what is behind the island.
class AdaptiveFloatingIsland extends StatefulWidget {
  const AdaptiveFloatingIsland({
    super.key,
    required this.collapsed,
    required this.expanded,
    required this.isExpanded,
    required this.collapsedSize,
    required this.expandedSize,
    this.onTap,
  });

  /// The glass around [collapsed]. It is a pill, so the content keeps clear
  /// of its rounded ends.
  static const EdgeInsets collapsedPadding = EdgeInsets.symmetric(
    horizontal: 16,
  );

  /// The glass around [expanded].
  static const EdgeInsets expandedPadding = EdgeInsets.all(16);

  /// The compact content.
  final Widget collapsed;

  /// The full content.
  final Widget expanded;

  /// Whether [expanded] is shown.
  final bool isExpanded;

  /// The size of the compact pill, glass included.
  final Size collapsedSize;

  /// The size of the expanded panel, glass included.
  final Size expandedSize;

  /// Called for a tap on the glass outside the content.
  final VoidCallback? onTap;

  @override
  State<AdaptiveFloatingIsland> createState() => _AdaptiveFloatingIslandState();
}

class _AdaptiveFloatingIslandState extends State<AdaptiveFloatingIsland> {
  final _controller = CNFloatingIslandController();
  bool _animate = true;

  @override
  void didUpdateWidget(AdaptiveFloatingIsland oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The package's `isExpanded` swaps only the Flutter content; the native
    // glass changes its shape when the controller tells it to.
    if (widget.isExpanded != oldWidget.isExpanded) {
      final change = widget.isExpanded
          ? _controller.expand(animated: _animate)
          : _controller.collapse(animated: _animate);
      // The view may be gone, e.g. while it is created again.
      unawaited(change.catchError((Object _) {}));
    }
  }

  @override
  Widget build(BuildContext context) {
    _animate = !context.reduceMotion;
    final collapsedSize = widget.collapsedSize;
    final expandedSize = widget.expandedSize;
    final size = widget.isExpanded ? expandedSize : collapsedSize;
    // The native view is sized by the content and keeps one size in both
    // states. SwiftUI animates the glass within the view, so a view that
    // changed size with the content would first move the glass with its
    // origin and then grow it from there.
    final viewSize = Size(
      expandedSize.width,
      expandedSize.height + _nativeHeadroom,
    );

    // The island takes only its own size; the rest of the native view
    // overhangs it, where it is transparent.
    return SizedOverflowBox(
      size: size,
      alignment: Alignment.bottomCenter,
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          GestureDetector(
            key: const ValueKey('adaptive-floating-island-glass'),
            behavior: HitTestBehavior.opaque,
            excludeFromSemantics: true,
            onTap: widget.onTap,
            child: SizedBox.fromSize(size: size),
          ),
          CNFloatingIsland(
            // The native view keeps the sizes it was created with.
            key: ValueKey((collapsedSize, expandedSize)),
            controller: _controller,
            isExpanded: widget.isExpanded,
            position: CNFloatingIslandPosition.bottom,
            margin: EdgeInsets.zero,
            collapsedWidth: collapsedSize.width,
            collapsedHeight: collapsedSize.height,
            expandedWidth: expandedSize.width,
            expandedHeight: expandedSize.height,
            // Callers remove the island while a sheet covers it; under other
            // modals the package clips its glow instead of dropping its
            // content.
            autoHideOnModal: false,
            collapsed: _content(
              view: AdaptiveFloatingIsland.collapsedPadding.deflateSize(
                viewSize,
              ),
              size: AdaptiveFloatingIsland.collapsedPadding.deflateSize(
                collapsedSize,
              ),
              child: widget.collapsed,
            ),
            expanded: _content(
              view: AdaptiveFloatingIsland.expandedPadding.deflateSize(
                viewSize,
              ),
              size: AdaptiveFloatingIsland.expandedPadding.deflateSize(
                expandedSize,
              ),
              child: widget.expanded,
            ),
          ),
        ],
      ),
    );
  }

  /// Lays [child] out at [size] at the bottom centre of [view], the native
  /// view's size less the glass padding. While the Flutter-drawn glass is
  /// between sizes, what lies beyond it is clipped.
  Widget _content({
    required Size view,
    required Size size,
    required Widget child,
  }) {
    return UnconstrainedBox(
      alignment: Alignment.bottomCenter,
      clipBehavior: Clip.hardEdge,
      child: SizedBox.fromSize(
        size: view,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox.fromSize(size: size, child: child),
        ),
      ),
    );
  }
}
