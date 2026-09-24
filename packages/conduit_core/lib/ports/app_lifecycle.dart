/// Which phase the host application is in.
///
/// The values mirror Flutter's `AppLifecycleState` one for one, deliberately:
/// the mobile adapter is then a pure rename, and the desktop adapter has an
/// unambiguous target to map Electron's focus/blur/suspend/resume events onto.
/// Reusing the names also means the switch statements that
/// move into the core keep the same shape and stay reviewable as diffs.
enum AppLifecyclePhase {
  /// Visible and receiving input.
  resumed,

  /// Visible but not focused — a system overlay is up, or the window lost
  /// focus. Sockets stay open; this is still "foreground" for most callers.
  inactive,

  /// Not visible but still running. Android's onStop, a minimized window.
  hidden,

  /// Suspended. On mobile the OS may reclaim resources at any point.
  paused,

  /// The host is tearing down.
  detached,
}

/// The host's application lifecycle.
///
/// The core cares about this for three things: keeping the socket open only
/// while it can be useful, pulling on foreground, and pausing periodic work.
/// None of those should know whether "background" means an Android onStop or
/// an Electron window blur.
abstract interface class AppLifecyclePort {
  /// The phase right now, or null before the host has observed one.
  ///
  /// Flutter does not re-deliver the current state to a freshly added
  /// observer (flutter/flutter#73947), so a service that starts after launch
  /// has to seed itself from here rather than wait for a transition.
  AppLifecyclePhase? get current;

  /// Phase transitions.
  ///
  /// Must be a broadcast stream: the socket, connectivity, sync and chat
  /// engines all observe it independently.
  Stream<AppLifecyclePhase> get changes;
}

/// Convenience predicates, defined once so "foreground" cannot come to mean
/// two different things in two engines.
extension AppLifecyclePhaseX on AppLifecyclePhase {
  /// Visible enough to be worth holding a socket open for.
  ///
  /// [AppLifecyclePhase.inactive] counts: it is what a pulled-down
  /// notification shade or an unfocused desktop window reports, and dropping
  /// the connection there would reconnect constantly.
  bool get isForeground =>
      this == AppLifecyclePhase.resumed || this == AppLifecyclePhase.inactive;

  /// Backgrounded far enough that periodic work should stop.
  bool get isBackground =>
      this == AppLifecyclePhase.paused ||
      this == AppLifecyclePhase.hidden ||
      this == AppLifecyclePhase.detached;
}

/// An [AppLifecyclePort] for hosts that do not report lifecycle at all.
///
/// Not a placeholder: "this host has no foreground/background notion" is a
/// real configuration. A headless `conduitd` started for a CLI probe, and
/// every unit test that is not specifically exercising lifecycle, both want
/// exactly this — behave as though permanently visible, and never transition.
///
/// It exists as a named type rather than a nullable port because the two are
/// the same statement, and having both invites each caller to answer "what
/// does absent mean?" differently. There is one answer, and it lives here.
class StaticAppLifecycle implements AppLifecyclePort {
  const StaticAppLifecycle([this.phase = AppLifecyclePhase.resumed]);

  final AppLifecyclePhase phase;

  @override
  AppLifecyclePhase? get current => phase;

  /// Never emits, and never closes. A host that cannot change phase has
  /// nothing to announce, and closing would make listeners think teardown
  /// had begun.
  @override
  Stream<AppLifecyclePhase> get changes =>
      const Stream<AppLifecyclePhase>.empty();
}
