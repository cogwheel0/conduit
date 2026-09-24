/// Asks the platform to hold the display at its peak refresh rate.
///
/// ProMotion idles the panel down to 10-40 Hz and only ramps back up
/// reactively once frames start arriving, so a drag after an idle gap can
/// render every frame on time and still look streaky, because it is running
/// at a third of the panel's rate. Holding a boost for the duration of an
/// interaction is what avoids that.
///
/// A port because only one platform both needs this and can do it: iOS pins
/// an idle CADisplayLink, Android requests its peak mode once at startup and
/// needs no calls at all, and the daemon has no display. The core knows when
/// an interaction is happening; it should not also know which of those is
/// true.
abstract interface class DisplayBoostPort {
  /// Asks for peak refresh until a matching [end].
  ///
  /// Deliberately not latched: every begin is expected to pass through so a
  /// host can re-arm its own leak-guard timeout. A long continuous scroll
  /// sends repeated begins, which is what keeps the boost alive past that
  /// window — a host that collapsed them would let the guard expire
  /// mid-interaction.
  void begin();

  void end();

  /// The host's implementation, installed once at startup.
  static DisplayBoostPort hostDefault = const NullDisplayBoost();
}

/// Does nothing, which is the correct answer nearly everywhere.
///
/// Android already runs at its peak mode, desktop panels do not idle their
/// refresh rate this way, and the daemon has no display at all. Only the iOS
/// host installs something else.
class NullDisplayBoost implements DisplayBoostPort {
  const NullDisplayBoost();

  @override
  void begin() {}

  @override
  void end() {}
}
