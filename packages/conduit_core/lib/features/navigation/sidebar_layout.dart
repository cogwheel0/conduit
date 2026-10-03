import 'dart:math' as math;

/// Geometry of the persistent tablet sidebar: when it pins, how wide it is
/// and how a resize drag moves it.
///
/// Pure: the app passes the window size it reads from its `MediaQuery`.

/// Width of a freshly installed sidebar, and what a reset returns to.
const double defaultSidebarTabletWidth = 320.0;

/// Narrowest width a resize can reach.
const double minimumSidebarTabletWidth = 320.0;

/// Widest width a resize can reach.
const double maximumSidebarTabletWidth = 480.0;

/// Windows whose shortest side reaches this pin the sidebar beside the
/// content; smaller ones use the slide-in drawer.
const double persistentSidebarBreakpoint = 600.0;

/// How far one accessibility or keyboard step moves the sidebar's edge.
const double sidebarTabletResizeStep = 20.0;

/// Whether a window of [width] by [height] pins the sidebar.
///
/// By the shortest side, so an iPad pins it in both orientations, a phone
/// in landscape keeps the drawer, and an iPad Split View or Slide Over
/// window narrower than the breakpoint falls back to the drawer.
bool usesPersistentTabletSidebarFor({
  required double width,
  required double height,
}) => math.min(width, height) >= persistentSidebarBreakpoint;

/// The widths a pinned sidebar may take.
final class SidebarTabletWidthRange {
  const SidebarTabletWidthRange({
    this.minimum = minimumSidebarTabletWidth,
    this.maximum = maximumSidebarTabletWidth,
    this.minimumContentWidth = defaultSidebarTabletWidth,
  }) : assert(minimum > 0),
       assert(maximum >= minimum),
       assert(minimumContentWidth >= 0);

  /// The range the app uses.
  static const standard = SidebarTabletWidthRange();

  final double minimum;
  final double maximum;

  /// Width the content beside the sidebar keeps before the sidebar stops
  /// growing into it.
  final double minimumContentWidth;

  /// [width] clamped to what a user can choose, as it is stored.
  double clampPreferred(double width) =>
      width.clamp(minimum, maximum).toDouble();

  /// The widest the sidebar may be in a window [viewportWidth] wide: the
  /// maximum, less what the content needs, never under the minimum.
  double maximumFor(double viewportWidth) {
    // The range's own minimum is the floor (the clamp below), not the
    // standard sidebar width: a range that allows a narrower sidebar must be
    // able to give the content its room.
    return math
        .min(maximum, viewportWidth - minimumContentWidth)
        .clamp(minimum, maximum)
        .toDouble();
  }

  /// The width shown for [preferredWidth] in a window [viewportWidth] wide.
  ///
  /// The preference itself is kept, so rotating back or widening a Split
  /// View window restores it.
  double effectiveWidth({
    required double preferredWidth,
    required double viewportWidth,
  }) => preferredWidth.clamp(minimum, maximumFor(viewportWidth)).toDouble();

  /// Where one step of [delta] from [currentWidth] on screen lands.
  double stepped({
    required double currentWidth,
    required double delta,
    required double viewportWidth,
  }) => (currentWidth + delta)
      .clamp(minimum, maximumFor(viewportWidth))
      .toDouble();
}

/// One drag of the sidebar's resize handle.
///
/// Deltas accumulate against the width on screen when the drag began and
/// are clamped to the window's range, so dragging past an end and back does
/// not build up slack.
final class SidebarTabletResizeDrag {
  SidebarTabletResizeDrag({
    required this.startPreferredWidth,
    required double viewportWidth,
    this.range = SidebarTabletWidthRange.standard,
  }) : anchorWidth = range.effectiveWidth(
         preferredWidth: startPreferredWidth,
         viewportWidth: viewportWidth,
       );

  final SidebarTabletWidthRange range;

  /// The stored preference when the drag began; a cancel returns to it.
  final double startPreferredWidth;

  /// The width on screen when the drag began.
  final double anchorWidth;

  double _cumulativeDelta = 0;

  /// The width the drag has reached.
  double get width => anchorWidth + _cumulativeDelta;

  /// Adds [delta] points (towards the content is positive) and returns the
  /// new width.
  double update(double delta, {required double viewportWidth}) {
    _cumulativeDelta = (_cumulativeDelta + delta)
        .clamp(
          range.minimum - anchorWidth,
          range.maximumFor(viewportWidth) - anchorWidth,
        )
        .toDouble();
    return width;
  }
}
