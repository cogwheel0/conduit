import 'dart:async';

import 'package:flutter/foundation.dart';

import 'display_boost.dart';

/// Process-wide signal that the user is actively interacting with a scroll
/// surface, so deferrable background work can stay off the UI isolate until
/// the motion rests.
///
/// Frame-cadence profiling showed chat drags dropping from ~97% on-cadence to
/// bimodal 120 Hz/22 ms+ the moment conversation warmup, sync pulls, and
/// deletion reconciles ran mid-drag: their orchestration, database writes,
/// and provider rebuild storms share the UI isolate with frame production.
/// None of that work is urgent on a sub-second scale, so it yields.
///
/// Scroll surfaces call [beginInteraction]/[endInteraction] (the chat
/// timeline wires these to its drag-start/rest notifications). Background
/// tasks await [whenIdle] before starting. Idle includes a short cool-down
/// after rest so consecutive fling segments (drag, fling, catch, fling)
/// don't let a task slip in between them.
class InteractionActivity {
  InteractionActivity._();

  static final InteractionActivity instance = InteractionActivity._();

  /// How long after the last interaction ends before waiters run. Long
  /// enough to bridge the gap between catch-and-refling gestures, short
  /// enough that deferred work is imperceptible.
  static const Duration idleCooldown = Duration(milliseconds: 350);

  /// Upper bound on deferral so a pathological interaction stream (or an
  /// unbalanced begin call) can only delay background work, never starve it.
  static const Duration maxDeferral = Duration(seconds: 8);

  /// How long a touch-down boost outlives a touch that never becomes a
  /// scroll (a tap). Long enough to cover slop + gesture arena resolution.
  static const Duration touchBoostGrace = Duration(seconds: 2);

  int _activeInteractions = 0;
  Timer? _cooldownTimer;
  Timer? _touchBoostTimer;
  bool _coolingDown = false;
  final List<Completer<void>> _idleWaiters = <Completer<void>>[];

  bool get isInteracting => _activeInteractions > 0 || _coolingDown;

  /// Ramps the display the instant a finger lands on a scroll surface.
  ///
  /// The panel takes a few frames to reach peak rate; waiting for drag-start
  /// (after touch slop) means the first stretch of every fling renders at
  /// the idle rate. Boosting at pointer-down mirrors UIKit's own behavior.
  /// If no interaction follows (a tap), the boost auto-releases after
  /// [touchBoostGrace].
  void notifyTouchDown() {
    DisplayBoost.begin();
    if (_activeInteractions > 0) return;
    _touchBoostTimer?.cancel();
    _touchBoostTimer = Timer(touchBoostGrace, () {
      _touchBoostTimer = null;
      if (_activeInteractions == 0 && !_coolingDown) DisplayBoost.end();
    });
  }

  void beginInteraction() {
    _touchBoostTimer?.cancel();
    _touchBoostTimer = null;
    _cooldownTimer?.cancel();
    _cooldownTimer = null;
    _coolingDown = false;
    _activeInteractions += 1;
    // Idempotent: pointer-down usually boosted already, but interactions can
    // also start from pointer-signal scrolling with no touch-down.
    DisplayBoost.begin();
  }

  void endInteraction() {
    if (_activeInteractions > 0) {
      _activeInteractions -= 1;
    }
    if (_activeInteractions > 0) return;
    _coolingDown = true;
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer(idleCooldown, () {
      _coolingDown = false;
      _cooldownTimer = null;
      // The cool-down doubles as the boost tail: an immediate re-fling
      // never sees the panel mid-ramp-down.
      DisplayBoost.end();
      _releaseWaiters();
    });
  }

  /// Completes immediately when idle; otherwise when the current interaction
  /// (plus cool-down) ends, or after [maxDeferral], whichever comes first.
  Future<void> get whenIdle {
    if (!isInteracting) return Future<void>.value();
    final completer = Completer<void>();
    _idleWaiters.add(completer);
    Timer(maxDeferral, () {
      if (!completer.isCompleted) {
        _idleWaiters.remove(completer);
        completer.complete();
      }
    });
    return completer.future;
  }

  void _releaseWaiters() {
    if (_idleWaiters.isEmpty) return;
    final waiters = List<Completer<void>>.of(_idleWaiters);
    _idleWaiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
  }

  @visibleForTesting
  void debugReset() {
    _cooldownTimer?.cancel();
    _cooldownTimer = null;
    _touchBoostTimer?.cancel();
    _touchBoostTimer = null;
    _coolingDown = false;
    _activeInteractions = 0;
    _releaseWaiters();
  }
}
