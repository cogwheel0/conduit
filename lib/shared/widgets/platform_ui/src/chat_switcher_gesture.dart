import 'dart:math' as math;

/// Maps lower-screen thumb travel onto the visible recent-chat list.
///
/// -1 means releasing cancels. The nearest chat has a broad landing area;
/// the remaining rows accelerate toward the first chat at mid-screen.
int chatSwitcherIndex({
  required double x,
  required double y,
  required double centerX,
  required double centerY,
  required double midpoint,
  required int count,
  bool alignLeft = false,
}) {
  final dx = x - centerX;
  final dy = y - centerY;
  final outward = dx * (alignLeft ? -1 : 1);
  if (count < 1 || outward >= 28 || math.sqrt(dx * dx + dy * dy) <= 44) {
    return -1;
  }
  final reach = math.max(40.0, centerY - midpoint - 44);
  final bottomAllowance = math.min(reach * .4, math.max(48.0, reach * .28));
  final progress =
      ((centerY - y - 44 - bottomAllowance) /
              math.max(20.0, reach - bottomAllowance))
          .clamp(0.0, 1.0);
  final accelerated = 1 - math.pow(1 - progress, 1.45);
  return count - 1 - (accelerated * (count - 1)).round();
}
