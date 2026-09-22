import 'package:flutter/widgets.dart';

/// The cue's gradient for a row that paints [extent] pixels wide and fades
/// [width] of them at the end of [axisDirection].
///
/// A right-to-left or reversed row scrolls towards the physical left, so its
/// clipped content sits there and the fade has to start from the right.
@visibleForTesting
LinearGradient horizontalOverflowFadeGradient({
  required double extent,
  required double width,
  required AxisDirection axisDirection,
}) {
  final fadeStart = extent <= width ? 0.0 : 1 - (width / extent);
  final fadesLeft = axisDirection == AxisDirection.left;
  return LinearGradient(
    begin: fadesLeft ? Alignment.centerRight : Alignment.centerLeft,
    end: fadesLeft ? Alignment.centerLeft : Alignment.centerRight,
    colors: const [Color(0xFFFFFFFF), Color(0x1AFFFFFF)],
    stops: [fadeStart, 1.0],
  );
}

/// A restrained trailing edge cue for horizontally scrollable utility rows.
///
/// The cue only appears while the row actually has content past its trailing
/// edge. It fades the row's own pixels instead of painting a surface-colored
/// gradient over them, so it reads correctly on opaque cards and on the native
/// glass composer alike.
class HorizontalOverflowFade extends StatefulWidget {
  const HorizontalOverflowFade({
    super.key,
    required this.child,
    this.width = 28,
  });

  final Widget child;
  final double width;

  @override
  State<HorizontalOverflowFade> createState() =>
      _HorizontalOverflowFadeState();
}

class _HorizontalOverflowFadeState extends State<HorizontalOverflowFade> {
  // Toggling the mask reparents the row, so the scrollable keeps its identity
  // through the move. Without it, reaching the trailing edge would drop the
  // mask, rebuild the row from scratch, and snap it back to its start.
  final GlobalKey _rowKey = GlobalKey();
  bool _hasTrailingOverflow = false;
  AxisDirection _axisDirection = AxisDirection.right;

  bool _handleMetrics(ScrollMetrics metrics) {
    if (metrics.axis != Axis.horizontal) return false;
    // Sub-pixel remainders survive a settled scroll view, so only treat a
    // visible remainder as overflow.
    final next = metrics.extentAfter > 0.5;
    // A right-to-left row, or a reversed one, clips its remaining content at
    // the physical left, so the mask has to follow the scroll axis.
    if (!mounted ||
        (next == _hasTrailingOverflow &&
            metrics.axisDirection == _axisDirection)) {
      return false;
    }
    setState(() {
      _hasTrailingOverflow = next;
      _axisDirection = metrics.axisDirection;
    });
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final row = KeyedSubtree(key: _rowKey, child: widget.child);
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) => notification.depth == 0
          ? _handleMetrics(notification.metrics)
          : false,
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) => notification.depth == 0
            ? _handleMetrics(notification.metrics)
            : false,
        child: _hasTrailingOverflow
            ? ShaderMask(
                shaderCallback: _createFadeShader,
                blendMode: BlendMode.dstIn,
                child: row,
              )
            : row,
      ),
    );
  }

  Shader _createFadeShader(Rect bounds) {
    return horizontalOverflowFadeGradient(
      extent: bounds.width,
      width: widget.width,
      axisDirection: _axisDirection,
    ).createShader(bounds);
  }
}
