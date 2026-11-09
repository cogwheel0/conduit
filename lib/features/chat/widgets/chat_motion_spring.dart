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

/// The time a send's motions run on: a ticker's elapsed time, except that
/// one frame never advances it by more than [maxStep].
///
/// A frame the app takes long to draw (a new chat's transcript mounting, a
/// first run of some code) would otherwise spend that much of a spring in a
/// single step, and a 0.4 s motion shows as a jump. On this clock the motion
/// picks up after such a frame where it left off and plays out in full; at
/// the display's own frame rate it is the ticker's time exactly. Every part
/// of a send (the rising message, the transcript bringing its turn up, the
/// composer closing) runs on one, so a slow frame delays them alike and they
/// stay one motion.
class ChatMotionClock {
  ChatMotionClock({this.maxStep = maxFrameStep});

  /// The most one frame may advance the motion: two frames at 60 Hz, so a
  /// display that drops a frame now and then keeps time, and a long stall
  /// costs no more than that.
  static const double maxFrameStep = 2 / 60;

  final double maxStep;

  double _lastWall = 0;
  double _seconds = 0;

  /// Seconds of motion so far.
  double get seconds => _seconds;

  /// Moves the clock to the ticker reading [wallSeconds] (seconds since the
  /// ticker started, as [Ticker] and [AnimationController] count them) and
  /// returns how far the motion advanced: the time since the last reading,
  /// at most [maxStep].
  double advanceTo(double wallSeconds) {
    final dt = wallSeconds - _lastWall;
    _lastWall = wallSeconds;
    if (dt <= 0) return 0;
    final step = math.min(dt, maxStep);
    _seconds += step;
    return step;
  }

  /// Keeps the motion's time but reads a new ticker from its start, for a
  /// motion handed over to another ticker mid-way. With a [lead], the first
  /// reading already advances it that far, so the hand-over frame keeps
  /// moving rather than holding still.
  void restartTicker({double lead = 0}) => _lastWall = -lead;

  /// Starts again from zero, for a ticker started again.
  void reset() {
    _lastWall = 0;
    _seconds = 0;
  }
}
