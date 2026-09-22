import 'package:flutter/widgets.dart';

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

  bool _handleMetrics(ScrollMetrics metrics) {
    if (metrics.axis != Axis.horizontal) return false;
    // Sub-pixel remainders survive a settled scroll view, so only treat a
    // visible remainder as overflow.
    final next = metrics.extentAfter > 0.5;
    if (next != _hasTrailingOverflow && mounted) {
      setState(() => _hasTrailingOverflow = next);
    }
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
    final fadeStart = bounds.width <= widget.width
        ? 0.0
        : 1 - (widget.width / bounds.width);
    return LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: const [Color(0xFFFFFFFF), Color(0x1AFFFFFF)],
      stops: [fadeStart, 1.0],
    ).createShader(bounds);
  }
}
