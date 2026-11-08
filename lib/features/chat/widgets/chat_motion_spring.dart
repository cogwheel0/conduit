import 'dart:math' as math;

/// A critically damped spring (damping ratio 1.0, so it never overshoots)
/// with a [response] in seconds: the motion of a sent message and of the
/// transcript bringing its turn into place, so the two can move as one.
class CriticallyDampedSpring {
  const CriticallyDampedSpring(this.response);

  /// Seconds for one period of the undamped spring; a full-screen travel
  /// settles within half a point in about 1.6 × [response].
  final double response;

  double get _omega => 2 * math.pi / response;

  /// Displacement left at [t] seconds for the spring released at rest, as a
  /// fraction of the starting distance.
  double remainingAt(double t) {
    if (t <= 0) return 1;
    final omega = _omega;
    return (1 + omega * t) * math.exp(-omega * t);
  }

  /// Advances the spring [dt] seconds from [displacement] (points from its
  /// target) moving at [velocity] (points per second).
  ({double displacement, double velocity}) step({
    required double displacement,
    required double velocity,
    required double dt,
  }) {
    if (dt <= 0) return (displacement: displacement, velocity: velocity);
    final omega = _omega;
    final decay = math.exp(-omega * dt);
    final b = velocity + omega * displacement;
    return (
      displacement: (displacement + b * dt) * decay,
      velocity: (velocity - omega * b * dt) * decay,
    );
  }
}
